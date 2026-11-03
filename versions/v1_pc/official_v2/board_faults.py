"""Exercise official V2 status codes and recovery on the real board."""
import argparse
import json
import struct
from pathlib import Path

from protocol import (Config, RESPONSE_MAGIC, crc16, exchange,
                      make_reference_response, make_request, parse_response,
                      pixels_from_v1_request, read_exact)


def replace_crc(packet: bytes) -> bytes:
    return packet[:-2] + struct.pack("<H", crc16(packet[2:-2]))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--v1-request", type=Path, required=True)
    p.add_argument("--port", required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    if args.output.exists():
        p.error("choose a fresh evidence directory")
    sw, sh, source = pixels_from_v1_request(args.v1_request)
    pixels = [source[y * sw + x] for y in range(16) for x in range(16)]
    cfg = Config(sequence=301, mode=3, width=16, height=16)
    good = make_request(pixels, cfg)
    bad_crc = good[:-1] + bytes((good[-1] ^ 1,))
    bad_mode = bytearray(good)
    bad_mode[5] = 6
    bad_mode = replace_crc(bytes(bad_mode))
    # Declared and sent length 510, versus required 512.
    shortened_body = good[2:17] + struct.pack("<I", 510) + good[21:21+510]
    bad_length = (b"\xa6\x6a" + shortened_body +
                  struct.pack("<H", crc16(shortened_body)))
    frames = [("bad_crc", bad_crc, 3), ("recover_crc", good, 0),
              ("bad_mode", bad_mode, 1), ("recover_mode", good, 0),
              ("bad_length", bad_length, 2), ("recover_length", good, 0)]
    args.output.mkdir(parents=True)
    rows = []
    try:
        for name, request, expected_status in frames:
            folder = args.output / name
            folder.mkdir()
            (folder / "request.bin").write_bytes(request)
            reply = exchange(args.port, request)
            (folder / "response.bin").write_bytes(reply)
            parsed = parse_response(reply, cfg if expected_status != 1 else None)
            assert reply[:2] == RESPONSE_MAGIC
            assert parsed.sequence == cfg.sequence and parsed.status == expected_status
            if expected_status == 0:
                assert parsed.payload == make_reference_response(pixels, cfg).payload
            row = {"test": name, "status": parsed.status,
                   "sequence": parsed.sequence, "payload_bytes": len(parsed.payload)}
            rows.append(row)
            print(json.dumps(row), flush=True)
        # A known sequence, then an interrupted header: after one second of
        # silence the device must return status 4 and recover for a good frame.
        import serial
        with serial.Serial(args.port, 115200, timeout=0.2, write_timeout=5) as link:
            link.reset_input_buffer()
            partial = good[:5]
            link.write(partial)
            link.flush()
            import time
            deadline = time.monotonic() + 5
            timeout_reply = read_exact(link, 23, deadline)
        (args.output / "timeout_response.bin").write_bytes(timeout_reply)
        parsed = parse_response(timeout_reply)
        assert parsed.sequence == cfg.sequence and parsed.status == 4
        rows.append({"test": "byte_gap_timeout", "status": parsed.status,
                     "sequence": parsed.sequence, "payload_bytes": 0})
        reply = exchange(args.port, good)
        (args.output / "recover_timeout_response.bin").write_bytes(reply)
        parsed = parse_response(reply, cfg)
        assert parsed.status == 0 and parsed.payload == make_reference_response(pixels, cfg).payload
        rows.append({"test": "recover_timeout", "status": 0,
                     "sequence": parsed.sequence, "payload_bytes": len(parsed.payload)})
    finally:
        (args.output / "report.json").write_text(
            json.dumps(rows, indent=2), encoding="utf-8")
    print("BOARD_FAULTS_PASS", len(rows), "cases")


if __name__ == "__main__":
    main()
