"""Generate byte-for-byte 16x16 UART simulation vectors for all six modes."""
from pathlib import Path
from golden import Config
from v2_protocol import make_request, make_reference_response


def main() -> None:
    destination = Path(__file__).resolve().parents[1] / "evidence" / "uart_16"
    destination.mkdir(parents=True, exist_ok=True)
    pixels = [((x*7+y*13)&31)<<11 | (((x*11+y*5)&63)<<5) | ((x*3+y*17)&31)
              for y in range(16) for x in range(16)]
    requests = bytearray()
    replies = bytearray()
    lengths = []
    for mode in range(1, 7):
        cfg = Config(16, 16, mode, threshold=110, bias=9, t1=23, t2=91,
                     cflat=19, cmid=11, cedge=4, delta=12)
        request = make_request(pixels, cfg)
        response = make_reference_response(pixels, cfg)
        requests.extend(request)
        replies.extend(response)
        lengths.append((len(request), len(response)))
    (destination / "requests.hex").write_text(
        "".join(f"{value:02x}\n" for value in requests), encoding="ascii")
    (destination / "expected.hex").write_text(
        "".join(f"{value:02x}\n" for value in replies), encoding="ascii")
    (destination / "lengths.txt").write_text(
        "".join(f"mode={mode} request={request} response={response}\n"
                for mode, (request, response) in enumerate(lengths, 1)), encoding="ascii")
    print(destination)
    print(lengths)


if __name__ == "__main__":
    main()
