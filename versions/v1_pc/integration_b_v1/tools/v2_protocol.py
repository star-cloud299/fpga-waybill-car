"""Independent PC framing for the six-mode board build (not the V1 protocol)."""
import argparse
import binascii
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from golden import Config, process


def crc16(data: bytes) -> int:
    return binascii.crc_hqx(data, 0xffff)


def output_size(width: int, height: int, mode: int) -> tuple[int, int]:
    crop = 0 if mode <= 2 else 2 if mode == 3 else 14
    return width - crop, height - crop


def make_request(pixels: list[int], cfg: Config) -> bytes:
    cfg.validate()
    if len(pixels) != cfg.width * cfg.height:
        raise ValueError("Incorrect pixel count")
    body = struct.pack("<HH9B", cfg.width, cfg.height, cfg.mode,
                       cfg.threshold, cfg.bias, cfg.t1, cfg.t2,
                       cfg.cflat, cfg.cmid, cfg.cedge, cfg.delta)
    body += b"".join(struct.pack(">H", pixel) for pixel in pixels)
    return b"\xa5\x5b" + body + struct.pack("<H", crc16(body))


def make_reference_response(pixels: list[int], cfg: Config) -> bytes:
    ow, oh = output_size(cfg.width, cfg.height, cfg.mode)
    body = struct.pack("<HHB", ow, oh, cfg.mode)
    for value, uncertain, *_ in process(pixels, cfg):
        body += bytes((value, uncertain))
    return b"\x5b\xa5" + body + struct.pack("<H", crc16(body))


def parse_response(packet: bytes, cfg: Config) -> list[tuple[int, int]]:
    ow, oh = output_size(cfg.width, cfg.height, cfg.mode)
    expected_length = 9 + 2 * ow * oh
    if len(packet) != expected_length or packet[:2] != b"\x5b\xa5":
        raise ValueError("Invalid V2 response length or magic")
    if struct.unpack_from("<HHB", packet, 2) != (ow, oh, cfg.mode):
        raise ValueError("Invalid V2 response dimensions or mode")
    if crc16(packet[2:-2]) != struct.unpack_from("<H", packet, len(packet)-2)[0]:
        raise ValueError("Invalid V2 response CRC")
    payload = packet[7:-2]
    if any(v not in (0, 1) for v in payload[1::2]):
        raise ValueError("Invalid uncertainty flag")
    return list(zip(payload[::2], payload[1::2]))


def pixels_from_v1_request(path: Path) -> tuple[int, int, list[int]]:
    packet = path.read_bytes()
    if len(packet) < 9 or packet[:2] != b"\xa5\x5a":
        raise ValueError("Input is not C's V1 request")
    width, height, _ = struct.unpack_from("<HHB", packet, 2)
    if len(packet) != 9 + width * height * 2:
        raise ValueError("Incorrect V1 request length")
    if crc16(packet[2:-2]) != struct.unpack_from("<H", packet, len(packet)-2)[0]:
        raise ValueError("Incorrect V1 request CRC")
    pixels = [struct.unpack_from(">H", packet, 7 + i*2)[0]
              for i in range(width*height)]
    return width, height, pixels


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--v1-request", type=Path, required=True,
                        help="C's prepared request.bin supplies RGB565 pixels only")
    parser.add_argument("--mode", type=int, required=True, choices=range(1, 7))
    parser.add_argument("--delta", type=int, default=8,
                        help="Mode 6 uncertainty margin threshold, 0..255")
    parser.add_argument("--port", help="Board serial port, for example COM10")
    parser.add_argument("--output", type=Path, help="Save raw board response")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=25)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    width, height, pixels = pixels_from_v1_request(args.v1_request)
    cfg = Config(width, height, args.mode, delta=args.delta)
    request = make_request(pixels, cfg)
    reference = make_reference_response(pixels, cfg)
    print(f"V2 mode={args.mode}, input={width}x{height}, "
          f"request={len(request)} bytes, reply={len(reference)} bytes")
    if args.dry_run:
        return
    if not args.port or not args.output:
        parser.error("--port and --output are required without --dry-run")
    if args.output.exists():
        parser.error(f"Refusing to overwrite {args.output}")
    import serial
    with serial.Serial(args.port, args.baud, timeout=0.5, write_timeout=5) as link:
        link.reset_input_buffer()
        sent = link.write(request)
        link.flush()
        if sent != len(request):
            raise RuntimeError(f"Sent only {sent}/{len(request)} bytes")
        import time
        deadline = time.monotonic() + args.timeout
        actual = bytearray()
        while len(actual) < len(reference) and time.monotonic() < deadline:
            actual.extend(link.read(len(reference) - len(actual)))
    if not actual:
        raise RuntimeError("No board response; no file was created")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(actual)
    print(f"Saved {len(actual)} actual board bytes to {args.output}")
    pixels_actual = parse_response(actual, cfg)
    pixels_expected = parse_response(reference, cfg)
    mismatches = sum(a != b for a, b in zip(pixels_actual, pixels_expected))
    print(f"Compared {len(pixels_actual)} pixels, mismatches={mismatches}")
    if mismatches:
        raise RuntimeError("Board output differs from PC golden model")


if __name__ == "__main__":
    main()
