"""Check B integration reference against the validated V1/C 64x64 frame."""

import binascii
import struct
from pathlib import Path

from golden import Config, gray565, process


ROOT = Path(__file__).resolve().parents[2]
C_DATA = ROOT / "team_v1_20261022" / "c_data" / "20261022_213852_792873"


def v1_gray(pixel):
    r = (pixel >> 11) & 31
    g = (pixel >> 5) & 63
    b = pixel & 31
    r = (r << 3) | (r >> 2)
    g = (g << 2) | (g >> 4)
    b = (b << 3) | (b >> 2)
    return (77 * r + 150 * g + 29 * b + 128) >> 8


def main():
    for pixel in range(65536):
        assert gray565(pixel) == v1_gray(pixel), f"gray mismatch at {pixel:04X}"

    request = (C_DATA / "request.bin").read_bytes()
    assert len(request) == 8201 and request[:2] == b"\xA5\x5A"
    width, height, bias = struct.unpack_from("<HHB", request, 2)
    assert (width, height, bias) == (64, 64, 6)
    assert struct.unpack_from("<H", request, len(request) - 2)[0] == binascii.crc_hqx(request[2:-2], 0xFFFF)
    pixels = [struct.unpack_from(">H", request, 7 + 2 * i)[0] for i in range(width * height)]
    reference = (C_DATA / "reference.pgm").read_bytes()
    assert reference[:13] == b"P5\n62 62\n255\n"
    expected = reference[13:]
    actual = bytes(row[0] for row in process(pixels, Config(width, height, 3, bias=bias)))
    mismatch = sum(a != b for a, b in zip(actual, expected))
    assert len(actual) == len(expected) == 3844
    assert mismatch == 0, f"B mode-3 reference differs at {mismatch} pixels"
    print("PASS: all 65,536 RGB565 grays match V1; mode-3/C image 3844/3844 pixels match")


if __name__ == "__main__":
    main()
