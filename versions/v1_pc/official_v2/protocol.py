"""Team-design-baseline V2 framing (distinct from the six-mode prototype).

All multi-byte fields are little-endian except RGB565 pixels, which are
transmitted high byte first. CRC covers version through the last payload byte.
"""
from __future__ import annotations

import argparse
import binascii
import json
import struct
import time
from dataclasses import dataclass
from pathlib import Path

REQUEST_MAGIC = b"\xa6\x6a"
RESPONSE_MAGIC = b"\x6a\xa6"
VERSION = 2
MAX_WIDTH = 256
MAX_HEIGHT = 128
MAX_PIXELS = MAX_WIDTH * MAX_HEIGHT


def crc16(data: bytes) -> int:
    return binascii.crc_hqx(data, 0xFFFF)


@dataclass(frozen=True)
class Config:
    sequence: int = 0
    mode: int = 4
    width: int = 64
    height: int = 64
    threshold: int = 128
    bias: int = 12
    t1: int = 24
    t2: int = 80
    cflat: int = 18
    cmid: int = 12
    cedge: int = 6

    def validate(self) -> None:
        if not 0 <= self.sequence <= 0xFFFF:
            raise ValueError("sequence must fit in 16 bits")
        if not 1 <= self.mode <= 5:
            raise ValueError("official V2 mode must be 1..5")
        minimum = 15 if self.mode >= 4 else 3
        if not minimum <= self.width <= MAX_WIDTH or not minimum <= self.height <= MAX_HEIGHT:
            raise ValueError("invalid dimensions for selected mode")
        params = (self.threshold, self.bias, self.t1, self.t2,
                  self.cflat, self.cmid, self.cedge)
        if any(not 0 <= value <= 255 for value in params) or self.t1 >= self.t2:
            raise ValueError("parameters must be bytes and T1 < T2")


def output_geometry(cfg: Config) -> tuple[int, int, int, int]:
    offset = 0 if cfg.mode <= 2 else 1 if cfg.mode == 3 else 7
    return cfg.width - 2 * offset, cfg.height - 2 * offset, offset, offset


def make_request(pixels: list[int], cfg: Config) -> bytes:
    cfg.validate()
    if len(pixels) != cfg.width * cfg.height:
        raise ValueError("pixel count does not match dimensions")
    if any(not 0 <= pixel <= 0xFFFF for pixel in pixels):
        raise ValueError("RGB565 pixel outside 16 bits")
    payload = b"".join(struct.pack(">H", pixel) for pixel in pixels)
    header = struct.pack("<BHBHH7BI", VERSION, cfg.sequence, cfg.mode,
                         cfg.width, cfg.height, cfg.threshold, cfg.bias,
                         cfg.t1, cfg.t2, cfg.cflat, cfg.cmid, cfg.cedge,
                         len(payload))
    body = header + payload
    return REQUEST_MAGIC + body + struct.pack("<H", crc16(body))


@dataclass(frozen=True)
class Response:
    sequence: int
    status: int
    mode: int
    width: int
    height: int
    offset_x: int
    offset_y: int
    processing_cycles: int
    payload: bytes


def parse_response(packet: bytes, request: Config | None = None) -> Response:
    if len(packet) < 23 or packet[:2] != RESPONSE_MAGIC:
        raise ValueError("invalid response length or magic")
    (version, sequence, status, mode, width, height, ox, oy,
     length, cycles) = struct.unpack_from("<BHBBHHBBII", packet, 2)
    if version != VERSION or status not in range(6):
        raise ValueError("invalid V2 version or status")
    if length > MAX_PIXELS or len(packet) != 23 + length:
        raise ValueError("invalid response payload length")
    if crc16(packet[2:-2]) != struct.unpack_from("<H", packet, len(packet)-2)[0]:
        raise ValueError("response CRC mismatch")
    payload = packet[21:-2]
    if status == 0:
        if width * height != length or mode not in range(1, 6):
            raise ValueError("success response geometry is inconsistent")
    elif any((width, height, ox, oy, length, cycles)):
        raise ValueError("failure response must have zero output fields")
    if request is not None:
        if sequence != request.sequence or mode != request.mode:
            raise ValueError("sequence or mode does not match request")
        if status == 0 and (width, height, ox, oy) != output_geometry(request):
            raise ValueError("response dimensions or offset are wrong")
    return Response(sequence, status, mode, width, height, ox, oy, cycles, payload)


def make_reference_response(pixels: list[int], cfg: Config) -> Response:
    # This model is independent of the board UART framing. B's arithmetic
    # reference is imported only for the image result.
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration_b_v1" / "tools"))
    from golden import Config as GoldenConfig, process
    golden_cfg = GoldenConfig(cfg.width, cfg.height, cfg.mode,
                              cfg.threshold, cfg.bias, cfg.t1, cfg.t2,
                              cfg.cflat, cfg.cmid, cfg.cedge)
    ow, oh, ox, oy = output_geometry(cfg)
    values = bytes(row[0] for row in process(pixels, golden_cfg))
    return Response(cfg.sequence, 0, cfg.mode, ow, oh, ox, oy, 0, values)


def pixels_from_v1_request(path: Path) -> tuple[int, int, list[int]]:
    packet = path.read_bytes()
    if len(packet) < 9 or packet[:2] != b"\xa5\x5a":
        raise ValueError("source is not C's V1 request.bin")
    width, height, _mode = struct.unpack_from("<HHB", packet, 2)
    if len(packet) != 9 + 2 * width * height:
        raise ValueError("V1 packet length mismatch")
    if crc16(packet[2:-2]) != struct.unpack_from("<H", packet, len(packet)-2)[0]:
        raise ValueError("V1 packet CRC mismatch")
    pixels = list(struct.unpack_from(f">{width*height}H", packet, 7))
    return width, height, pixels


def read_exact(link, count: int, deadline: float) -> bytes:
    data = bytearray()
    while len(data) < count:
        if time.monotonic() >= deadline:
            raise TimeoutError(f"only received {len(data)}/{count} bytes")
        part = link.read(count - len(data))
        if part:
            data.extend(part)
    return bytes(data)


def exchange(port: str, request: bytes, baud: int = 115200,
             deadline_seconds: float = 30) -> bytes:
    import serial
    with serial.Serial(port, baud, timeout=0.2, write_timeout=5) as link:
        link.reset_input_buffer()
        if link.write(request) != len(request):
            raise RuntimeError("short UART write")
        link.flush()
        deadline = time.monotonic() + deadline_seconds
        header = read_exact(link, 21, deadline)
        if header[:2] != RESPONSE_MAGIC:
            raise ValueError("response magic mismatch")
        length = struct.unpack_from("<I", header, 13)[0]
        if length > MAX_PIXELS:
            raise ValueError("response exceeds protocol maximum")
        return header + read_exact(link, length + 2, deadline)


def main() -> None:
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--v1-request", type=Path, required=True)
    cli.add_argument("--port", help="board port, e.g. COM10; omit for offline check")
    cli.add_argument("--output", type=Path, help="new evidence directory")
    cli.add_argument("--mode", type=int, default=4, choices=range(1, 6))
    cli.add_argument("--sequence", type=int, default=1)
    args = cli.parse_args()
    width, height, pixels = pixels_from_v1_request(args.v1_request)
    cfg = Config(sequence=args.sequence, mode=args.mode, width=width, height=height)
    request = make_request(pixels, cfg)
    reference = make_reference_response(pixels, cfg)
    print(f"official V2: {width}x{height}, mode {cfg.mode}, request {len(request)} bytes, "
          f"expected output {len(reference.payload)} bytes")
    if args.port is None:
        return
    if args.output is None or args.output.exists():
        cli.error("--output must name a new evidence directory for a board run")
    response_bytes = exchange(args.port, request)
    response = parse_response(response_bytes, cfg)
    args.output.mkdir(parents=True)
    (args.output / "request.bin").write_bytes(request)
    (args.output / "response.bin").write_bytes(response_bytes)
    (args.output / "reference.raw8").write_bytes(reference.payload)
    mismatches = (sum(a != b for a, b in zip(response.payload, reference.payload))
                  if response.status == 0 else None)
    report = {"sequence": response.sequence, "mode": response.mode,
              "status": response.status, "width": response.width,
              "height": response.height, "offset_x": response.offset_x,
              "offset_y": response.offset_y, "processing_cycles": response.processing_cycles,
              "received_pixels": len(response.payload), "mismatches": mismatches}
    (args.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    if response.status or mismatches:
        raise RuntimeError("board did not match the official V2 reference")


if __name__ == "__main__":
    main()
