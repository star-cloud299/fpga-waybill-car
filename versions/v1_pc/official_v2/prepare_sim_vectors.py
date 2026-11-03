"""Generate deterministic serial test bytes for the official V2 testbench."""
from pathlib import Path

from protocol import Config, make_request


def main() -> None:
    root = Path(__file__).resolve().parent
    vectors = root / "sim_vectors"
    vectors.mkdir(exist_ok=True)
    pixels = [((x * 3 + y * 11) & 31) << 11 |
              ((x * 5 + y * 7) & 63) << 5 |
              ((x * 13 + y * 2) & 31)
              for y in range(16) for x in range(16)]
    requests = [make_request(pixels, Config(sequence=100 + mode, mode=mode,
                                             width=16, height=16))
                for mode in range(1, 6)]
    bad_crc = bytearray(requests[0])
    bad_crc[-1] ^= 1
    requests.append(bytes(bad_crc))
    requests.append(requests[0])
    data = b"".join(requests)
    (vectors / "requests.hex").write_text("".join(f"{b:02x}\n" for b in data),
                                           encoding="ascii")
    (vectors / "request_lengths.txt").write_text(
        "\n".join(map(str, map(len, requests))) + "\n", encoding="ascii")
    print("frames", len(requests), "bytes", len(data))


if __name__ == "__main__":
    main()
