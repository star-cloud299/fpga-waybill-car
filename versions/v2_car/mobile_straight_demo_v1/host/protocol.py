"""WBQ1 framing. No serial ports, hardware commands, or replay substitution."""
from __future__ import annotations

import binascii
from dataclasses import dataclass
import struct

MAGIC = b"WBQ1"
VERSION = 1
HEADER = struct.Struct("<4sBBBBHH")
MAX_PAYLOAD = 516
HEARTBEAT, ACK, HELLO = 0x01, 0x02, 0x03
SCAN_BEGIN, ORIGINAL_CHUNK, BINARY_CHUNK, SCAN_END = 0x10, 0x11, 0x12, 0x13
RESULT, RETRY, STATE = 0x20, 0x21, 0x30
WAIT, MATCH, WRONG_REGION, UNKNOWN, DUPLICATE, UNREADABLE, COMM_ERROR = range(7)
STATUS_NAMES = ("WAIT", "MATCH", "WRONG_REGION", "UNKNOWN", "DUPLICATE", "UNREADABLE", "COMM_ERROR")
STATUS_ZH = ("等待核验", "区域匹配", "区域错误", "未知货物", "重复核验", "未能识别", "通信/图像校验异常")
PHASE_NAMES = ("待命", "停稳", "采图核验", "直行", "右转", "待复核", "完成", "故障停车", "换向暂停")


def crc16(data: bytes) -> int:
    return binascii.crc_hqx(data, 0xFFFF)


@dataclass(frozen=True)
class Packet:
    kind: int
    station: int = 0
    sequence: int = 0
    payload: bytes = b""
    flags: int = 0

    def encode(self) -> bytes:
        if not 0 <= self.kind <= 255 or not 0 <= self.station <= 255 or not 0 <= self.flags <= 255:
            raise ValueError("packet byte field outside range")
        if not 0 <= self.sequence <= 65535 or len(self.payload) > MAX_PAYLOAD:
            raise ValueError("sequence or payload length outside range")
        h = HEADER.pack(MAGIC, VERSION, self.kind, self.station, self.flags, self.sequence, len(self.payload))
        body = h[4:] + self.payload
        return MAGIC + body + struct.pack("<H", crc16(body))


class Parser:
    """Incremental TCP/UART parser; rejects bad CRC/length/version and resyncs."""
    def __init__(self):
        self.buffer = bytearray()
        self.crc_errors = 0
        self.header_errors = 0
        self.discarded_bytes = 0

    def feed(self, data: bytes) -> list[Packet]:
        self.buffer.extend(data)
        result = []
        while True:
            start = self.buffer.find(MAGIC)
            if start < 0:
                keep = min(len(self.buffer), len(MAGIC) - 1)
                self.discarded_bytes += len(self.buffer) - keep
                if keep:
                    self.buffer[:] = self.buffer[-keep:]
                else:
                    self.buffer.clear()
                break
            if start:
                self.discarded_bytes += start
                del self.buffer[:start]
            if len(self.buffer) < HEADER.size:
                break
            _, version, kind, station, flags, seq, length = HEADER.unpack_from(self.buffer)
            if version != VERSION or length > MAX_PAYLOAD:
                self.header_errors += 1
                del self.buffer[0]
                continue
            total = HEADER.size + length + 2
            if len(self.buffer) < total:
                break
            frame = self.buffer[:total]
            if crc16(frame[4:-2]) != struct.unpack_from("<H", frame, total - 2)[0]:
                self.crc_errors += 1
                del self.buffer[0]
                continue
            result.append(Packet(kind, station, seq, bytes(frame[HEADER.size:-2]), flags))
            del self.buffer[:total]
        return result


def acknowledgement(packet: Packet, offset: int = 0) -> Packet:
    return Packet(ACK, packet.station, packet.sequence, struct.pack("<BI", packet.kind, offset))


def result_packet(station: int, sequence: int, status: int, target: int = 0, text: str = "") -> Packet:
    if status not in range(1, 7) or target not in range(5):
        raise ValueError("invalid result status/target")
    raw = text.encode("ascii")
    if len(raw) > 24:
        raise ValueError("barcode text exceeds result capacity")
    return Packet(RESULT, station, sequence, bytes((status, target, len(raw))) + raw)
