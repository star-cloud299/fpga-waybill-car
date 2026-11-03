"""Independently parse the UART waveform bytes and compare to B's golden model."""
import json
from pathlib import Path

from protocol import (Config, crc16, make_reference_response, make_request,
                      parse_response)


def main() -> None:
    root = Path(__file__).resolve().parent
    raw = bytes(int(line, 16) for line in
                (root / "sim_vectors" / "responses.hex").read_text().splitlines())
    assert crc16(b"123456789") == 0x29B1
    pixels = [((x * 3 + y * 11) & 31) << 11 |
              ((x * 5 + y * 7) & 63) << 5 |
              ((x * 13 + y * 2) & 31)
              for y in range(16) for x in range(16)]
    expected_bytes = (root / "sim_vectors" / "requests.hex").read_text().splitlines()
    assert len(expected_bytes) == 7 * 535
    first = make_request(pixels, Config(sequence=101, mode=1, width=16, height=16))
    assert first == bytes.fromhex("".join(expected_bytes[:535]))
    offset = 0
    report = []
    for frame_index in range(7):
        mode = frame_index + 1 if frame_index < 5 else 1
        cfg = Config(sequence=100 + mode, mode=mode, width=16, height=16)
        length = 0 if frame_index == 5 else len(make_reference_response(pixels, cfg).payload)
        packet = raw[offset:offset + 23 + length]
        result = parse_response(packet, cfg)
        expected = make_reference_response(pixels, cfg)
        assert result.status == (3 if frame_index == 5 else 0)
        if result.status == 0:
            assert result.payload == expected.payload
            assert result.processing_cycles > 0
        offset += len(packet)
        report.append({"frame": frame_index + 1, "sequence": result.sequence,
                       "status": result.status, "mode": result.mode,
                       "pixels": len(result.payload), "mismatches": 0,
                       "processing_cycles": result.processing_cycles})
    assert offset == len(raw)
    output = root / "sim_vectors" / "verified_report.json"
    output.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"OFFICIAL_V2_VERIFIED frames=7 bytes={len(raw)} pixels={sum(x['pixels'] for x in report)}")


if __name__ == "__main__":
    main()
