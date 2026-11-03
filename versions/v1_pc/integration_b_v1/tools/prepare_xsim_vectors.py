"""Prepare all six B modes from C's 64x64 RGB565 request for RTL simulation."""

import struct
from dataclasses import asdict
from pathlib import Path

from golden import Config, process


ROOT = Path(__file__).resolve().parents[2]
REQUEST = ROOT / "team_v1_20261022" / "c_data" / "20261022_213852_792873" / "request.bin"
OUT = ROOT / "integration_b_v1" / "evidence" / "c64_six_modes"


def main():
    packet = REQUEST.read_bytes()
    assert packet[:2] == b"\xA5\x5A" and len(packet) == 8201
    width, height, bias = struct.unpack_from("<HHB", packet, 2)
    assert (width, height, bias) == (64, 64, 6)
    pixels = [struct.unpack_from(">H", packet, 7 + 2 * i)[0] for i in range(4096)]
    OUT.mkdir(parents=True, exist_ok=True)
    configs = [Config(width, height, mode, bias=bias) for mode in range(1, 7)]
    with (OUT / "config.txt").open("w", encoding="ascii") as config_file, \
         (OUT / "input.txt").open("w", encoding="ascii") as input_file, \
         (OUT / "expected.txt").open("w", encoding="ascii") as expected_file:
        config_file.write(f"{len(configs)}\n")
        total = 0
        for config in configs:
            config_file.write(" ".join(map(str, asdict(config).values())) + "\n")
            input_file.writelines(f"{pixel:04x}\n" for pixel in pixels)
            expected = process(pixels, config)
            expected_file.writelines(" ".join(map(str, row)) + "\n" for row in expected)
            total += len(expected)
    print(f"Prepared {len(configs)} modes, {total} expected output pixels at {OUT}")


if __name__ == "__main__":
    main()
