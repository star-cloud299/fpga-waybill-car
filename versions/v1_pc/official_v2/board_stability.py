"""One-port, 100-frame official V2 stability check with no automatic retries."""
import argparse
import hashlib
import json
import struct
import time
from pathlib import Path

import serial

from protocol import (Config, MAX_PIXELS, RESPONSE_MAGIC, make_reference_response,
                      make_request, parse_response, pixels_from_v1_request,
                      read_exact)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--v1-request", type=Path, required=True)
    p.add_argument("--port", required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--count", type=int, default=100)
    args = p.parse_args()
    if args.output.exists() or not 1 <= args.count <= 1000:
        p.error("output must be new, and count must be 1..1000")
    width, height, pixels = pixels_from_v1_request(args.v1_request)
    if (width, height) != (64, 64):
        p.error("this stability fixture expects C's 64x64 image")
    references = {mode: make_reference_response(
        pixels, Config(mode=mode, width=width, height=height)).payload
        for mode in range(1, 6)}
    args.output.mkdir(parents=True)
    results = []
    try:
        with serial.Serial(args.port, 115200, timeout=0.2, write_timeout=5) as link:
            link.reset_input_buffer()
            for index in range(args.count):
                mode = index % 5 + 1
                cfg = Config(sequence=400 + index, mode=mode,
                             width=width, height=height)
                request = make_request(pixels, cfg)
                t0 = time.monotonic()
                if link.write(request) != len(request):
                    raise RuntimeError(f"short write at frame {index}")
                link.flush()
                deadline = time.monotonic() + 30
                header = read_exact(link, 21, deadline)
                if header[:2] != RESPONSE_MAGIC:
                    raise RuntimeError(f"bad response magic at frame {index}")
                length = struct.unpack_from("<I", header, 13)[0]
                if length > MAX_PIXELS:
                    raise RuntimeError(f"excess response length at frame {index}")
                response = header + read_exact(link, length + 2, deadline)
                parsed = parse_response(response, cfg)
                mismatches = sum(a != b for a, b in
                                 zip(parsed.payload, references[mode]))
                if len(parsed.payload) != len(references[mode]):
                    mismatches = -1
                frame_file = args.output / f"response_{index:03d}.bin"
                frame_file.write_bytes(response)
                row = {"frame": index + 1, "sequence": cfg.sequence,
                       "mode": mode, "status": parsed.status,
                       "crc_ok": True, "mismatches": mismatches,
                       "response_sha256": hashlib.sha256(response).hexdigest(),
                       "round_trip_s": round(time.monotonic() - t0, 3)}
                results.append(row)
                if parsed.status or mismatches:
                    raise RuntimeError(f"board mismatch at frame {index + 1}")
                if (index + 1) % 10 == 0:
                    print(f"PROGRESS {index+1}/{args.count}", flush=True)
    finally:
        (args.output / "report.json").write_text(json.dumps(
            {"source": str(args.v1_request), "continuous_port": True,
             "automatic_retries": False, "frames": results}, indent=2),
            encoding="utf-8")
    print(f"BOARD_STABILITY_PASS {len(results)} frames; 0 CRC or pixel errors")


if __name__ == "__main__":
    main()
