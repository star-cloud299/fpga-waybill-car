"""Recheck saved real board replies without opening the serial port."""
import hashlib
import json
from pathlib import Path

from golden import Config
from v2_protocol import (make_reference_response, parse_response,
                         pixels_from_v1_request)


ROOT = Path(__file__).resolve().parents[1]
V1_REQUEST = ROOT.parent / "team_v1_20261022" / "c_data" / "20261022_213852_792873" / "request.bin"


def main() -> None:
    width, height, pixels = pixels_from_v1_request(V1_REQUEST)
    records = []
    for mode in range(1, 7):
        cfg = Config(width, height, mode)
        path = ROOT / "evidence" / f"board_mode{mode}_20261023.bin"
        actual_packet = path.read_bytes()
        expected_packet = make_reference_response(pixels, cfg)
        actual = parse_response(actual_packet, cfg)
        expected = parse_response(expected_packet, cfg)
        differences = [index for index, pair in enumerate(zip(actual, expected))
                       if pair[0] != pair[1]]
        records.append({
            "mode": mode,
            "file": str(path),
            "bytes": len(actual_packet),
            "pixels": len(actual),
            "mismatches": len(differences),
            "first_mismatch": differences[0] if differences else None,
            "uncertain_pixels": sum(flag for _, flag in actual),
            "sha256": hashlib.sha256(actual_packet).hexdigest(),
            "crc_valid": True,
        })
    pgm = (V1_REQUEST.parent / "reference.pgm").read_bytes()
    pgm_header = b"P5\n62 62\n255\n"
    if not pgm.startswith(pgm_header) or len(pgm) != len(pgm_header) + 62*62:
        raise ValueError("Unexpected C reference.pgm format")
    board_mode3 = parse_response(
        (ROOT / "evidence" / "board_mode3_20261023.bin").read_bytes(),
        Config(width, height, 3))
    c_reference_mismatches = sum(value != expected for (value, _), expected
                                 in zip(board_mode3, pgm[len(pgm_header):]))
    extra_cfg = Config(width, height, 6, delta=255)
    extra_path = ROOT / "evidence" / "board_mode6_delta255_20261023.bin"
    extra_packet = extra_path.read_bytes()
    extra_actual = parse_response(extra_packet, extra_cfg)
    extra_expected = parse_response(make_reference_response(pixels, extra_cfg), extra_cfg)
    extra_mismatches = sum(a != b for a, b in zip(extra_actual, extra_expected))
    if not any(flag for _, flag in extra_actual):
        raise RuntimeError("High-delta mode 6 test did not exercise uncertainty flags")
    extra = {
        "mode": 6,
        "delta": 255,
        "file": str(extra_path),
        "bytes": len(extra_packet),
        "pixels": len(extra_actual),
        "mismatches": extra_mismatches,
        "uncertain_pixels": sum(flag for _, flag in extra_actual),
        "sha256": hashlib.sha256(extra_packet).hexdigest(),
        "crc_valid": True,
    }
    report = {
        "date": "2026-10-23",
        "board": "AX7035B xc7a35t",
        "input": str(V1_REQUEST),
        "input_size": [width, height],
        "protocol": "V2 A5 5B / 5B A5; RGB565 big-endian; CRC16-CCITT",
        "records": records,
        "extra_uncertainty_test": extra,
        "c_reference_mode3_mismatches": c_reference_mismatches,
        "total_pixels": sum(record["pixels"] for record in records),
        "total_mismatches": sum(record["mismatches"] for record in records)
                            + extra_mismatches + c_reference_mismatches,
    }
    output = ROOT / "evidence" / "board_six_mode_report_20261023.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Saved {output}")
    print(f"6 modes, {report['total_pixels']} pixels, "
          f"{report['total_mismatches']} mismatches")
    print("mode 6 high-delta uncertain pixels:", extra["uncertain_pixels"])
    print("C reference.pgm mode 3 mismatches:", c_reference_mismatches)
    if report["total_mismatches"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
