"""Two-leg straight-route wireless verification dashboard. Default: GUI; --headless: server."""
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import queue
import socket
import sys
import threading

import runtime  # noqa: F401
from backend import Server, load_tasks
from protocol import PHASE_NAMES, STATUS_ZH

HERE = Path(__file__).resolve().parent


def local_addresses():
    try:
        return ", ".join(sorted({v for v in socket.gethostbyname_ex(socket.gethostname())[2]
                                 if not v.startswith("127.")})) or "请查看电脑Wi-Fi的IPv4地址"
    except OSError:
        return "请查看电脑Wi-Fi的IPv4地址"


class Dashboard:
    def __init__(self, args):
        import tkinter as tk
        from tkinter import ttk
        self.tk, self.ttk = tk, ttk
        self.root = tk.Tk()
        self.root.title("两段直线 · 两站面单核验 · 无线后台")
        self.root.geometry("1120x880")
        self.root.minsize(1000, 740)
        self.root.configure(bg="#101923")
        self.root.option_add("*Font", ("Microsoft YaHei UI", 11))
        self.events, self.server, self.images, self.args = queue.Queue(), None, [], args
        self.tasks = load_tasks(args.tasks)
        self.task_count = len(self.tasks)
        self.completed = set()
        self.started = False
        self.display_size = (384, 288) if self.root.winfo_screenheight() >= 900 else (320, 240)
        self.link = tk.StringVar(value="后台未启动")
        self.station = tk.StringVar(value="当前站点 —")
        self.phase = tk.StringVar(value="等待小车连接")
        self.verdict = tk.StringVar(value="待核验")
        self.barcode = tk.StringVar(value="—")
        self.target = tk.StringVar(value="目标转运区 —")
        self.progress = tk.DoubleVar(value=0)
        self.detail = tk.StringVar(value="路线S→A→B，每段80厘米；相机朝左。连接2.4GHz Wi-Fi后启动后台，复位小车并按KEY1。")
        self.run_label = tk.StringVar(value=f"本轮完成 0 / {self.task_count}")

        def label(parent, text=None, variable=None, size=14, color="#e6edf3", bg="#101923"):
            kw = dict(font=("Microsoft YaHei UI", size), fg=color, bg=bg, anchor="w")
            return tk.Label(parent, text=text, textvariable=variable, **kw)

        header = tk.Frame(self.root, bg="#101923")
        header.pack(fill="x", padx=26, pady=(18, 8))
        label(header, "两段直线 · 两站面单核验", size=24).pack(side="left")
        tk.Button(header, text="启动无线后台", command=self.start, bg="#2f81f7", fg="white",
                  relief="flat", padx=18, pady=8).pack(side="right")
        label(self.root, f"电脑IPv4：{local_addresses()}    TCP端口：{args.port}    相机原生裁剪：256×192",
              size=11, color="#93a4b5").pack(fill="x", padx=26)
        label(self.root, variable=self.link, size=12, color="#7cc5ff").pack(fill="x", padx=26, pady=5)

        status = tk.Frame(self.root, bg="#1c2938")
        status.pack(fill="x", padx=26, pady=8)
        label(status, variable=self.station, size=24, bg="#1c2938").grid(row=0, column=0, sticky="w", padx=18, pady=8)
        self.verdict_widget = label(status, variable=self.verdict, size=25, color="#e3b341", bg="#1c2938")
        self.verdict_widget.grid(row=0, column=1, sticky="e", padx=18)
        label(status, variable=self.phase, size=13, color="#a9b6c5", bg="#1c2938").grid(row=1, column=0, sticky="w", padx=18, pady=(0, 10))
        label(status, variable=self.run_label, size=16, bg="#1c2938").grid(row=1, column=1, sticky="e", padx=18)
        status.grid_columnconfigure(1, weight=1)

        views = tk.Frame(self.root, bg="#101923")
        views.pack(fill="x", padx=26)
        self.left_image = tk.Label(views, text="等待同一帧原图", bg="#192330", fg="#93a4b5", width=56, height=15)
        self.right_image = tk.Label(views, text="等待FPGA处理图", bg="#192330", fg="#93a4b5", width=56, height=15)
        self.left_image.grid(row=1, column=0, padx=(0, 10), pady=4)
        self.right_image.grid(row=1, column=1, padx=(10, 0), pady=4)
        label(views, "车载原图（仅显示放大，解码不缩放）", size=12).grid(row=0, column=0, sticky="w")
        label(views, "FPGA 3×3自适应二值化", size=12).grid(row=0, column=1, sticky="w", padx=10)
        fields = tk.Frame(self.root, bg="#101923")
        fields.pack(fill="x", padx=26, pady=6)
        label(fields, "识别编号", size=12, color="#93a4b5").pack(side="left")
        label(fields, variable=self.barcode, size=23).pack(side="left", padx=14)
        label(fields, variable=self.target, size=18).pack(side="right")
        ttk.Progressbar(self.root, variable=self.progress, maximum=100).pack(fill="x", padx=26)
        label(self.root, variable=self.detail, size=11, color="#a9b6c5").pack(fill="x", padx=26, pady=6)
        table = ttk.Treeview(self.root, columns=("station", "code", "result"), show="headings", height=max(2, self.task_count))
        for col, title, width in (("station", "目标转运区", 160), ("code", "任务编号", 400), ("result", "本轮结果", 300)):
            table.heading(col, text=title)
            table.column(col, width=width, anchor="center")
        for code, task in self.tasks.items():
            table.insert("", "end", iid=code, values=("ABCD"[task["station_id"] - 1] + "区", code, "等待"))
        table.pack(fill="x", padx=26, pady=8)
        self.table = table
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(80, self.poll)
        if args.autostart:
            self.root.after(300, self.start)

    def start(self):
        if self.started:
            return
        self.started = True
        self.server = Server(self.args.tasks, self.args.output, self.args.bind, self.args.port, self.events.put)

        def run():
            try:
                self.server.serve()
            except Exception as exc:
                self.events.put(dict(type="error", error=f"{type(exc).__name__}: {exc}"))
                self.events.put(dict(type="server_stopped"))
        threading.Thread(target=run, daemon=True).start()
        self.link.set("正在启动TCP后台…")

    def update_image(self, directory):
        from PIL import Image, ImageTk
        images = []
        for name, widget in (("original.png", self.left_image), ("processed.png", self.right_image)):
            p = Path(directory) / name
            if p.is_file():
                with Image.open(p) as image:
                    photo = ImageTk.PhotoImage(image.resize(self.display_size, Image.Resampling.NEAREST))
                images.append(photo)
                widget.configure(image=photo, text="", width=self.display_size[0], height=self.display_size[1])
        self.images = images

    def poll(self):
        try:
            while True:
                event = self.events.get_nowait()
                kind = event["type"]
                if kind == "listening":
                    self.link.set(f"后台已监听TCP {event['port']}，等待ESP-01S连接")
                elif kind == "connected":
                    self.link.set(f"无线已连接：{event['address']}，等待小车运行握手")
                elif kind == "run":
                    self.completed.clear()
                    self.run_label.set(f"本轮完成 0 / {self.task_count}")
                    self.verdict.set("新一轮待命")
                    self.detail.set(f"本轮日志：{event['directory']}")
                    for code in self.table.get_children():
                        values = self.table.item(code, "values")
                        self.table.item(code, values=(*values[:2], "等待"))
                elif kind == "state":
                    station = event["station"]
                    if station in range(1, 5):
                        self.station.set("当前站点 " + "ABCD"[station - 1])
                    phase = event["phase"]
                    self.phase.set(PHASE_NAMES[phase] if phase < len(PHASE_NAMES) else f"状态{phase}")
                    if phase == 6:
                        self.phase.set("任务完成，已停车")
                        self.verdict.set("任务完成，已停车")
                        self.verdict_widget.configure(fg="#3fb950")
                    elif phase == 7:
                        self.verdict.set("故障停车")
                        self.verdict_widget.configure(fg="#f85149")
                elif kind in {"scan", "progress"}:
                    self.station.set("当前站点 " + "ABCD"[event["station"] - 1])
                    self.phase.set("接收同一帧原图与FPGA处理图")
                    self.progress.set(event["progress"] * 100)
                    if kind == "scan":
                        self.verdict.set("正在核验…")
                        self.barcode.set("—")
                        self.target.set("目标转运区 —")
                        self.verdict_widget.configure(fg="#e3b341")
                elif kind == "result":
                    r = event["report"]
                    status = r["status_code"]
                    self.verdict.set(STATUS_ZH[status])
                    self.verdict_widget.configure(fg="#3fb950" if status == 1 else "#f85149")
                    self.barcode.set(r["barcode_text"] or "—")
                    target = r["target_station"]
                    self.target.set("目标转运区 " + ("ABCD"[target - 1] if target else "—"))
                    self.detail.set(r["reason"])
                    self.completed = set(r["completed"])
                    self.run_label.set(f"本轮完成 {len(self.completed)} / {self.task_count}")
                    self.update_image(event["directory"])
                    if r["barcode_text"] in self.table.get_children():
                        code = r["barcode_text"]
                        values = self.table.item(code, "values")
                        self.table.item(code, values=(*values[:2], STATUS_ZH[status]))
                elif kind == "disconnected":
                    self.link.set("无线已断开；小车应由本地超时机制停车")
                elif kind == "error":
                    self.detail.set(event["error"])
                elif kind == "server_stopped":
                    self.started = False
                    self.link.set("后台启动失败，可修正端口/地址后再次启动")
        except queue.Empty:
            pass
        self.root.after(80, self.poll)

    def close(self):
        if self.server:
            self.server.close()
        self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8266)
    parser.add_argument("--tasks", type=Path, default=HERE / "tasks_straight.csv")
    parser.add_argument("--output", type=Path, default=HERE.parent / "runs")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--autostart", action="store_true")
    args = parser.parse_args()
    load_tasks(args.tasks)
    if args.headless:
        def notice(event):
            if event["type"] != "progress":
                print(json.dumps(event, ensure_ascii=False), flush=True)
        server = Server(args.tasks, args.output, args.bind, args.port, notice)
        try:
            server.serve()
        except KeyboardInterrupt:
            pass
        finally:
            server.close()
    else:
        gui = Dashboard(args)
        gui.root.mainloop()


if __name__ == "__main__":
    main()
