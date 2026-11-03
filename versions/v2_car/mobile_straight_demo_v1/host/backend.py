"""Real WBQ1 receiver, image verification and persistent waybill decisions."""
from __future__ import annotations

import csv
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import threading
import time

import runtime  # noqa: F401 -- selects installed local dependencies
import numpy as np
from PIL import Image

from protocol import (Packet, Parser, HEARTBEAT, HELLO, SCAN_BEGIN, ORIGINAL_CHUNK,
                      BINARY_CHUNK, SCAN_END, STATE, MATCH, WRONG_REGION, UNKNOWN,
                      DUPLICATE, UNREADABLE, COMM_ERROR, STATUS_NAMES,
                      acknowledgement, result_packet)

WIDTH, HEIGHT = 256, 192
ORIGINAL_SIZE, BINARY_SIZE = WIDTH * HEIGHT * 2, WIDTH * HEIGHT // 8


def utc_stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%f")


def dump_json(path: Path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def load_tasks(path: Path):
    result, task_ids = {}, set()
    with Path(path).open(encoding="utf-8-sig", newline="") as f:
        r = csv.DictReader(f)
        if not {"task_id", "station_id", "barcode_text"} <= set(r.fieldnames or ()):
            raise ValueError("任务表需要 task_id,station_id,barcode_text 列")
        for row in r:
            if row.get("enabled", "1").strip().lower() in {"0", "false", "no"}:
                continue
            code, task = row["barcode_text"].strip(), row["task_id"].strip()
            station = int(row["station_id"])
            if not code or not task or station not in range(1, 5) or not code.isascii():
                raise ValueError("任务表存在无效编号、任务或站点")
            if code in result or task in task_ids:
                raise ValueError("任务表存在重复编号或任务ID")
            result[code] = dict(task_id=task, station_id=station, barcode_text=code,
                                description=row.get("description", ""))
            task_ids.add(task)
    if not result:
        raise ValueError("启用任务表为空")
    return result


def images_from_payload(original: bytes, packed: bytes):
    if len(original) != ORIGINAL_SIZE or len(packed) != BINARY_SIZE:
        raise ValueError("原图或二值图长度不完整")
    pixels = np.frombuffer(original, dtype=">u2").astype(np.uint16).reshape(HEIGHT, WIDTH)
    r, g, b = (pixels >> 11) & 31, (pixels >> 5) & 63, pixels & 31
    r, g, b = (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)
    rgb = np.stack((r, g, b), axis=-1).astype(np.uint8)
    gray = ((77 * r.astype(np.uint32) + 150 * g.astype(np.uint32) +
             29 * b.astype(np.uint32) + 128) >> 8).astype(np.uint8)
    binary = (np.unpackbits(np.frombuffer(packed, dtype=np.uint8), bitorder="big")
              .reshape(HEIGHT, WIDTH) * 255).astype(np.uint8)
    return Image.fromarray(rgb), gray, binary


def reference_binary(gray):
    """Exact FPGA contract: integer gray, floor(sum9/9), bias12, white borders."""
    a = np.asarray(gray, dtype=np.uint32)
    if a.shape != (HEIGHT, WIDTH):
        raise ValueError("reference geometry mismatch")
    sums = sum(a[dy:dy + HEIGHT - 2, dx:dx + WIDTH - 2]
               for dy in range(3) for dx in range(3))
    out = np.full(a.shape, 255, dtype=np.uint8)
    out[1:-1, 1:-1] = np.where(a[1:-1, 1:-1] + 12 >= sums // 9, 255, 0)
    return out


def decode_code128(image):
    import zxingcpp
    found = zxingcpp.read_barcodes(np.ascontiguousarray(image, dtype=np.uint8),
                                  formats=zxingcpp.BarcodeFormat.Code128,
                                  try_rotate=False, try_downscale=False, try_invert=False)
    return sorted({r.text for r in found if r.valid})


def decide(tasks, completed: set[str], station: int, texts: list[str]):
    texts = sorted(set(texts))
    if len(texts) != 1:
        return UNREADABLE, 0, "", "没有唯一可信Code128结果"
    text = texts[0]
    task = tasks.get(text)
    if task is None:
        return UNKNOWN, 0, text, "编号不在启用任务表中"
    target = task["station_id"]
    if station != target:
        return WRONG_REGION, target, text, "当前路线站点与目标转运区不符"
    if text in completed:
        return DUPLICATE, target, text, "本轮该任务已经成功核验"
    return MATCH, target, text, "条码、任务和当前区域一致"


@dataclass
class Assembly:
    station: int
    sequence: int
    directory: Path
    begin_payload: bytes

    def __post_init__(self):
        self.original = bytearray(ORIGINAL_SIZE)
        self.binary = bytearray(BINARY_SIZE)
        self.original_coverage = bytearray(ORIGINAL_SIZE)
        self.binary_coverage = bytearray(BINARY_SIZE)
        self.wire = bytearray()
        self.started = time.monotonic()
        self.error = None

    def add(self, packet: Packet):
        if len(packet.payload) < 5:
            raise ValueError("空图像块或缺少偏移")
        offset = struct.unpack_from("<I", packet.payload)[0]
        values = packet.payload[4:]
        dest, coverage = ((self.original, self.original_coverage) if packet.kind == ORIGINAL_CHUNK
                          else (self.binary, self.binary_coverage))
        if len(values) > 512 or offset + len(values) > len(dest):
            raise ValueError("图像块越界")
        for i, value in enumerate(values, offset):
            if coverage[i] and dest[i] != value:
                raise ValueError("重传块与已收到内容不一致")
        dest[offset:offset + len(values)] = values
        coverage[offset:offset + len(values)] = b"\1" * len(values)
        self.wire.extend(packet.encode())
        return offset

    @property
    def complete(self):
        return all(self.original_coverage) and all(self.binary_coverage) and not self.error


class VerificationSession:
    """Single receiver/writer. Packet retransmission and business repeats differ."""
    def __init__(self, tasks_path: Path, output_root: Path, notify=lambda event: None,
                 evidence_type="wireless_current_run"):
        self.tasks_path, self.tasks = Path(tasks_path), load_tasks(tasks_path)
        self.output_root, self.notify = Path(output_root), notify
        self.completed = set()
        self.cache = {}
        self.active = None
        self.run_dir = None
        self.run_id = None
        self.last_hello = 0.0
        self.event_number = 0
        if evidence_type not in {"wireless_current_run", "software_simulation"}:
            raise ValueError("unsupported evidence type")
        self.evidence_type = evidence_type

    def _event(self, event):
        self.notify(event)

    def start_run(self, run_id):
        if self.active:
            self.fail_pending("收到新运行握手，旧采集未完成")
        self.run_id = run_id
        self.run_dir = self.output_root / f"run_{utc_stamp()}_id{run_id:04x}"
        self.run_dir.mkdir(parents=True, exist_ok=False)
        self.completed, self.cache, self.active = set(), {}, None
        self.event_number = 0
        dump_json(self.run_dir / "run.json", dict(run_id=run_id, protocol="WBQ1", evidence_type=self.evidence_type,
                  tasks=self.tasks, tasks_sha256=hashlib.sha256(self.tasks_path.read_bytes()).hexdigest(),
                  note="New HELLO creates a run; no replay data is accepted as live evidence."))
        self._event(dict(type="run", run_id=run_id, directory=str(self.run_dir), completed=[]))

    def handle(self, packet: Packet) -> list[Packet]:
        if packet.kind == HELLO:
            now = time.monotonic()
            # A very short immediate duplicate HELLO is a wire retry, not a new business run.
            if self.run_id != packet.sequence or now - self.last_hello > 1.0:
                self.start_run(packet.sequence)
            self.last_hello = now
            return []
        if packet.kind == STATE:
            if len(packet.payload) == 3:
                phase, verdict, mask = packet.payload
                self._event(dict(type="state", station=packet.station, phase=phase,
                                 verdict=verdict, completed_mask=mask))
            return []
        if packet.kind not in (SCAN_BEGIN, ORIGINAL_CHUNK, BINARY_CHUNK, SCAN_END):
            return []
        if packet.station not in range(1, 5):
            return []
        key = (packet.station, packet.sequence)
        if self.run_dir is None:
            # A retained TCP connection may deliver image data before HELLO; never silently match it.
            return [result_packet(*key, COMM_ERROR)]
        if key in self.cache:
            if packet.kind == SCAN_END:
                return [acknowledgement(packet), self.cache[key]]
            if packet.kind == SCAN_BEGIN:
                return [acknowledgement(packet)]
            if len(packet.payload) >= 4:
                return [acknowledgement(packet, struct.unpack_from("<I", packet.payload)[0])]
            return []
        if packet.kind == SCAN_BEGIN:
            if len(packet.payload) != 6 or struct.unpack("<HHBB", packet.payload) != (WIDTH, HEIGHT, 3, 1):
                return [result_packet(*key, COMM_ERROR)]
            if self.active and (self.active.station, self.active.sequence) == key:
                if self.active.begin_payload == packet.payload:
                    return [acknowledgement(packet)]
                self.active.error = "同一序号的BEGIN内容发生变化"
                return [result_packet(*key, COMM_ERROR)]
            if self.active:
                self.fail_pending("新序号替换未完成采集")
            attempt = self.run_dir / f"scan_{len(self.cache) + 1:03d}_{packet.station}_{packet.sequence:04x}"
            attempt.mkdir(exist_ok=False)
            self.active = Assembly(packet.station, packet.sequence, attempt, packet.payload)
            self.active.wire.extend(packet.encode())
            self._event(dict(type="scan", station=packet.station, sequence=packet.sequence,
                             progress=0.0, directory=str(attempt)))
            return [acknowledgement(packet)]
        if not self.active or (self.active.station, self.active.sequence) != key:
            return []  # stale or out-of-order image cannot change an active verdict
        if packet.kind in (ORIGINAL_CHUNK, BINARY_CHUNK):
            try:
                offset = self.active.add(packet)
            except ValueError as exc:
                self.active.error = str(exc)
                return [result_packet(*key, COMM_ERROR)]
            n = sum(self.active.original_coverage) + sum(self.active.binary_coverage)
            self._event(dict(type="progress", station=packet.station, sequence=packet.sequence,
                             progress=n / (ORIGINAL_SIZE + BINARY_SIZE)))
            return [acknowledgement(packet, offset)]
        self.active.wire.extend(packet.encode())
        response = self.finish(self.active)
        self.cache[key] = response
        self.active = None
        return [acknowledgement(packet), response]

    def finish(self, assembly: Assembly, forced_error=None):
        t = time.monotonic()
        directory = assembly.directory
        raw = bytes(assembly.original)
        packed = bytes(assembly.binary)
        (directory / "original_rgb565.bin").write_bytes(raw)
        (directory / "processed_bit1.bin").write_bytes(packed)
        (directory / "valid_packets.bin").write_bytes(assembly.wire)
        report = dict(evidence_type=self.evidence_type, station_id=assembly.station,
                      sequence=assembly.sequence, run_id=self.run_id,
                      received_original_bytes=sum(assembly.original_coverage),
                      received_binary_bytes=sum(assembly.binary_coverage),
                      width=WIDTH, height=HEIGHT, original_pixel_format="RGB565_BE", processed_format="BIT1_MSB_WHITE1",
                      crc_ok=True, complete=assembly.complete, error=forced_error or assembly.error,
                      hardware_preprocessing=(self.evidence_type == "wireless_current_run"),
                      preprocessing_mismatch_count=None,
                      raw_decoded_texts=[], processed_decoded_texts=[], decoded_texts=[],
                      original_sha256=hashlib.sha256(raw).hexdigest(),
                      binary_sha256=hashlib.sha256(packed).hexdigest())
        status, target, text, reason = COMM_ERROR, 0, "", "采集内容不完整"
        if assembly.complete and not report["error"]:
            try:
                rgb, gray, binary = images_from_payload(raw, packed)
                reference = reference_binary(gray)
                mismatches = int(np.count_nonzero(binary != reference))
                report["preprocessing_mismatch_count"] = mismatches
                rgb.save(directory / "original.png")
                Image.fromarray(gray).save(directory / "gray.png")
                Image.fromarray(binary).save(directory / "processed.png")
                Image.fromarray(reference).save(directory / "pc_reference.png")
                report["raw_decoded_texts"] = decode_code128(gray)
                report["processed_decoded_texts"] = decode_code128(binary)
                texts = sorted(set(report["raw_decoded_texts"] + report["processed_decoded_texts"]))
                report["decoded_texts"] = texts
                if mismatches:
                    report["error"] = f"FPGA二值图与整数参考有{mismatches}个像素不同"
                    reason = report["error"]
                else:
                    status, target, text, reason = decide(self.tasks, self.completed, assembly.station, texts)
            except Exception as exc:
                report["error"] = f"{type(exc).__name__}: {exc}"
                reason = report["error"]
        if status == MATCH:
            self.completed.add(text)
        report.update(status=STATUS_NAMES[status], status_code=status, target_station=target,
                      barcode_text=text, reason=reason, completed=sorted(self.completed),
                      receive_elapsed_s=round(t - assembly.started, 3),
                      processing_elapsed_s=round(time.monotonic() - t, 3))
        dump_json(directory / "report.json", report)
        self.event_number += 1
        event = dict(event_id=self.event_number, timestamp_utc=datetime.now(timezone.utc).isoformat(),
                     station_id=assembly.station, sequence=assembly.sequence,
                     barcode_text=text or None, target_station=target, status=STATUS_NAMES[status],
                     evidence_type=self.evidence_type, report=str(directory.relative_to(self.run_dir) / "report.json"))
        with (self.run_dir / "events.jsonl").open("a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(event, ensure_ascii=False) + "\n")
            f.flush()
            os.fsync(f.fileno())
        self._event(dict(type="result", report=report, directory=str(directory)))
        return result_packet(assembly.station, assembly.sequence, status, target, text)

    def fail_pending(self, message):
        if self.active:
            self.finish(self.active, forced_error=message)
            self.active = None


class Server:
    def __init__(self, tasks_path: Path, output: Path, host="0.0.0.0", port=8266,
                 notify=lambda event: None, evidence_type="wireless_current_run"):
        self.tasks_path, self.output, self.host, self.port = Path(tasks_path), Path(output), host, port
        self.notify = notify
        self.stop = threading.Event()
        self.listening = threading.Event()
        self.bound_port = None
        self.socket = None
        self.connection = None
        self.evidence_type = evidence_type

    def serve(self):
        self.output.mkdir(parents=True, exist_ok=True)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            self.socket = listener
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((self.host, self.port))
            self.bound_port = listener.getsockname()[1]
            listener.listen(1)
            listener.settimeout(0.25)
            self.listening.set()
            self.notify(dict(type="listening", host=self.host, port=self.bound_port))
            while not self.stop.is_set():
                try:
                    connection, address = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    if self.stop.is_set():
                        break
                    raise
                with connection:
                    self.connection = connection
                    self.handle_connection(connection, address)
                    self.connection = None

    def handle_connection(self, connection, address):
        connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        connection.settimeout(0.25)
        self.notify(dict(type="connected", address=str(address)))
        parser = Parser()
        session = VerificationSession(self.tasks_path, self.output, self.notify, self.evidence_type)
        disconnected, send_lock = threading.Event(), threading.Lock()
        wire_path = self.output / f"tcp_{utc_stamp()}.bin"

        def send(packet):
            with send_lock:
                connection.sendall(packet.encode())

        def heartbeat():
            while not self.stop.is_set() and not disconnected.is_set():
                try:
                    send(Packet(HEARTBEAT))
                except OSError:
                    disconnected.set()
                    break
                disconnected.wait(0.5)

        worker = threading.Thread(target=heartbeat, name="wbq-heartbeat", daemon=True)
        worker.start()
        try:
            with wire_path.open("wb") as wire:
                while not self.stop.is_set() and not disconnected.is_set():
                    try:
                        data = connection.recv(8192)
                    except socket.timeout:
                        continue
                    if not data:
                        break
                    wire.write(data)
                    wire.flush()
                    for packet in parser.feed(data):
                        for reply in session.handle(packet):
                            send(reply)
        except (OSError, ValueError) as exc:
            self.notify(dict(type="error", error=f"{type(exc).__name__}: {exc}"))
        finally:
            disconnected.set()
            worker.join(timeout=1)
            session.fail_pending("无线连接断开，采集未完成")
            dump_json(wire_path.with_suffix(".json"), dict(address=str(address), crc_errors=parser.crc_errors,
                      header_errors=parser.header_errors, discarded_bytes=parser.discarded_bytes,
                      raw_wire_sha256=hashlib.sha256(wire_path.read_bytes()).hexdigest()))
            self.notify(dict(type="disconnected", raw_wire=str(wire_path)))

    def close(self):
        self.stop.set()
        if self.connection:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        if self.socket:
            try:
                self.socket.close()
            except OSError:
                pass
