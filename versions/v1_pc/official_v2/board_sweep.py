"""Run official V2 modes 1..5 on real COM port at 64x64 and 192x96.

The larger image is a deterministic resize of C's 64x64 RGB565 data. It is
for transport/algorithm validation, not a formally labeled barcode sample.
"""
import argparse
import hashlib
import json
from pathlib import Path

from protocol import (Config, exchange, make_reference_response, make_request,
                      parse_response, pixels_from_v1_request)


def resize_nearest(pixels: list[int], sw: int, sh: int, w: int, h: int) -> list[int]:
    return [pixels[(y * sh // h) * sw + (x * sw // w)]
            for y in range(h) for x in range(w)]


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--v1-request", type=Path, required=True)
    p.add_argument("--port", required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    if args.output.exists():
        p.error("output directory exists; choose a fresh evidence directory")
    sw, sh, source = pixels_from_v1_request(args.v1_request)
    args.output.mkdir(parents=True)
    rows = []
    try:
        for width, height in ((sw, sh), (192, 96)):
            pixels = source if (width, height) == (sw, sh) else resize_nearest(
                source, sw, sh, width, height)
            for mode in range(1, 6):
                seq = 200 + (width == 192) * 10 + mode
                cfg = Config(sequence=seq, mode=mode, width=width, height=height)
                request = make_request(pixels, cfg)
                reference = make_reference_response(pixels, cfg)
                frame_dir = args.output / f"{width}x{height}_mode{mode}"
                frame_dir.mkdir()
                (frame_dir / "request.bin").write_bytes(request)
                (frame_dir / "reference.raw8").write_bytes(reference.payload)
                actual_bytes = exchange(args.port, request)
                (frame_dir / "response.bin").write_bytes(actual_bytes)
                actual = parse_response(actual_bytes, cfg)
                mismatches = (sum(a != b for a, b in zip(actual.payload, reference.payload))
                              if actual.status == 0 else None)
                if actual.status == 0 and len(actual.payload) != len(reference.payload):
                    mismatches = -1
                row = {"size": f"{width}x{height}", "mode": mode, "sequence": seq,
                       "status": actual.status, "output_pixels": len(actual.payload),
                       "mismatches": mismatches,
                       "processing_cycles": actual.processing_cycles,
                       "request_sha256": hashlib.sha256(request).hexdigest(),
                       "response_sha256": hashlib.sha256(actual_bytes).hexdigest()}
                rows.append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
                if actual.status or mismatches:
                    raise RuntimeError("board validation failed")
    finally:
        (args.output / "report.json").write_text(
            json.dumps({"source": str(args.v1_request),
                        "note": "192x96 is a functional resize, not a labeled barcode sample",
                        "frames": rows}, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
