"""On-board protocol check: reject old magic and bad CRC, then accept a good frame."""
import argparse
import json
import time
from pathlib import Path

from golden import Config
from v2_protocol import (make_request, make_reference_response, parse_response,
                         pixels_from_v1_request)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--v1-request", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.report.exists():
        parser.error(f"Refusing to overwrite {args.report}")
    import serial
    width, height, pixels = pixels_from_v1_request(args.v1_request)
    cfg = Config(width, height, 3)
    valid = make_request(pixels, cfg)
    bad_crc = bytearray(valid)
    bad_crc[-1] ^= 1
    reference = make_reference_response(pixels, cfg)
    with serial.Serial(args.port, 115200, timeout=0.4, write_timeout=5) as link:
        link.reset_input_buffer()
        link.write(b"\xa5\x5a")
        link.flush()
        if link.read(1):
            raise RuntimeError("V1 magic unexpectedly produced a response")
        link.write(bad_crc)
        link.flush()
        if link.read(1):
            raise RuntimeError("Bad-CRC V2 frame unexpectedly produced a response")
        link.write(valid)
        link.flush()
        deadline = time.monotonic() + 20
        response = bytearray()
        while len(response) < len(reference) and time.monotonic() < deadline:
            response.extend(link.read(len(reference) - len(response)))
    actual = parse_response(response, cfg)
    expected = parse_response(reference, cfg)
    mismatches = sum(a != b for a, b in zip(actual, expected))
    result = {
        "v1_magic_rejected": True,
        "bad_crc_rejected": True,
        "following_good_frame_pixels": len(actual),
        "following_good_frame_mismatches": mismatches,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(result)
    if mismatches:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
