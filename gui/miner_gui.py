#!/usr/bin/env python3
"""BTCC Apple GPU Miner — graphical front-end (tkinter, stdlib only)."""
from __future__ import annotations

import json
import queue
import re
import signal
import socket
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import messagebox, scrolledtext, ttk
from typing import Any, Callable, Optional

from app_paths import (
    APP_SUPPORT,
    DEFAULT_POOL,
    SETTINGS_FILE,
    build_metal_helper,
    default_worker,
    ensure_app_support,
    gpu_binary,
    gpu_binary_ready,
    python_exe,
    repo_root,
    src_dir,
)


# ---------------------------------------------------------------------------
# Settings persistence
# ---------------------------------------------------------------------------

def default_settings() -> dict[str, Any]:
    return {
        "stratum": {
            "address": "",
            "worker": default_worker(),
            "pool_url": DEFAULT_POOL,
            "pass": "x",
            "proxy": "",
            "suggest_difficulty": "-1",
            "gpu_target_seconds": "1.0",
            "gpu_batch": "0",
            "gpu_per_dispatch": "0",
            "gpu_threadgroup": "0",
            "connect_timeout": "15",
            "prefer_ipv6": False,
            "cpu_batch": str(1 << 18),
        },
        "solo": {
            "rpchost": "127.0.0.1",
            "rpcport": "28476",
            "rpcuser": "user",
            "rpcpassword": "pass",
            "address": "",
            "wallet": "miner",
            "max_blocks": "0",
            "gpu_target_seconds": "2.0",
            "gpu_batch": "0",
            "gpu_per_dispatch": "0",
            "gpu_threadgroup": "0",
        },
    }


def load_settings() -> dict[str, Any]:
    ensure_app_support()
    if SETTINGS_FILE.is_file():
        try:
            with open(SETTINGS_FILE, encoding="utf-8") as f:
                data = json.load(f)
            base = default_settings()
            for section in base:
                if section in data and isinstance(data[section], dict):
                    base[section].update(data[section])
            return base
        except Exception:
            pass
    return default_settings()


def save_settings(data: dict[str, Any]) -> None:
    ensure_app_support()
    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


# ---------------------------------------------------------------------------
# Subprocess runner
# ---------------------------------------------------------------------------

class ProcessRunner:
    def __init__(self, on_line: Callable[[str], None], on_exit: Callable[[int], None]):
        self._on_line = on_line
        self._on_exit = on_exit
        self._proc: Optional[subprocess.Popen] = None
        self._thread: Optional[threading.Thread] = None

    @property
    def running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def start(self, argv: list[str], cwd: str) -> None:
        if self.running:
            raise RuntimeError("already running")
        self._proc = subprocess.Popen(
            argv,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        def reader() -> None:
            assert self._proc and self._proc.stdout
            rc = 0
            try:
                for line in self._proc.stdout:
                    self._on_line(line.rstrip("\n"))
                rc = self._proc.wait()
            except Exception:
                rc = self._proc.returncode if self._proc else -1
            self._on_exit(rc or 0)

        self._thread = threading.Thread(target=reader, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if not self._proc or self._proc.poll() is not None:
            return
        try:
            self._proc.send_signal(signal.SIGINT)
            try:
                self._proc.wait(timeout=8)
                return
            except subprocess.TimeoutExpired:
                pass
            self._proc.terminate()
            try:
                self._proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        except Exception:
            try:
                self._proc.kill()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Reusable widgets
# ---------------------------------------------------------------------------

class LabeledEntry(ttk.Frame):
    def __init__(self, master, label: str, textvariable: tk.StringVar, width: int = 48):
        super().__init__(master)
        ttk.Label(self, text=label, width=16, anchor="w").pack(side=tk.LEFT)
        ttk.Entry(self, textvariable=textvariable, width=width).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )


class GpuAdvancedFrame(ttk.LabelFrame):
    """Shared GPU tuning knobs (0 = auto)."""

    def __init__(self, master, prefix: str, vars: dict[str, tk.StringVar]):
        super().__init__(master, text="GPU 高级参数（0 = 自动）", padding=8)
        self._vars = vars
        rows = [
            ("gpu_target_seconds", "目标批次耗时 (秒)"),
            ("gpu_batch", "GPU batch"),
            ("gpu_per_dispatch", "per-dispatch"),
            ("gpu_threadgroup", "threadgroup"),
        ]
        for i, (key, label) in enumerate(rows):
            ttk.Label(self, text=label, width=18, anchor="w").grid(
                row=i, column=0, sticky="w", pady=2
            )
            ttk.Entry(self, textvariable=vars[key], width=12).grid(
                row=i, column=1, sticky="w", pady=2
            )

    def gpu_args(self) -> list[str]:
        return gpu_args_from_vars(self._vars)


def gpu_args_from_vars(vars: dict[str, tk.StringVar]) -> list[str]:
    args = ["--gpu", "--gpu-binary", str(gpu_binary())]
    for key in ("gpu_target_seconds", "gpu_batch", "gpu_per_dispatch", "gpu_threadgroup"):
        val = vars[key].get().strip()
        if not val:
            continue
        flag = "--" + key.replace("_", "-")
        args.extend([flag, val])
    return args


# ---------------------------------------------------------------------------
# Main application
# ---------------------------------------------------------------------------

class MinerGUI(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("BTCC Apple GPU Miner")
        self.minsize(820, 640)
        self.geometry("920x720")

        self.settings = load_settings()
        self._ui_queue: queue.Queue = queue.Queue()
        self._runner = ProcessRunner(self._enqueue_log, self._on_process_exit)
        self._hashrate = tk.StringVar(value="—")
        self._shares = tk.StringVar(value="0")
        self._status = tk.StringVar(value="就绪")

        self._build_ui()
        self._load_ui_from_settings()
        self.after(100, self._drain_queue)
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    # ----- UI construction -----

    def _build_ui(self) -> None:
        top = ttk.Frame(self, padding=8)
        top.pack(fill=tk.X)
        ttk.Label(top, text="状态:").pack(side=tk.LEFT)
        ttk.Label(top, textvariable=self._status, foreground="#006600").pack(
            side=tk.LEFT, padx=(4, 16)
        )
        ttk.Label(top, text="算力:").pack(side=tk.LEFT)
        ttk.Label(top, textvariable=self._hashrate).pack(side=tk.LEFT, padx=(4, 16))
        ttk.Label(top, text="Shares:").pack(side=tk.LEFT)
        ttk.Label(top, textvariable=self._shares).pack(side=tk.LEFT, padx=4)

        nb = ttk.Notebook(self)
        nb.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 4))

        self._stratum_tab = ttk.Frame(nb, padding=8)
        self._solo_tab = ttk.Frame(nb, padding=8)
        self._tools_tab = ttk.Frame(nb, padding=8)
        nb.add(self._stratum_tab, text="矿池挖矿")
        nb.add(self._solo_tab, text="Solo 挖矿")
        nb.add(self._tools_tab, text="工具")

        self._build_stratum_tab()
        self._build_solo_tab()
        self._build_tools_tab()

        log_frame = ttk.LabelFrame(self, text="运行日志", padding=4)
        log_frame.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)
        self._log = scrolledtext.ScrolledText(
            log_frame, height=12, state=tk.DISABLED, font=("Menlo", 11)
        )
        self._log.pack(fill=tk.BOTH, expand=True)
        btn_row = ttk.Frame(log_frame)
        btn_row.pack(fill=tk.X, pady=(4, 0))
        ttk.Button(btn_row, text="清空日志", command=self._clear_log).pack(side=tk.RIGHT)

    def _build_stratum_tab(self) -> None:
        s = self.settings["stratum"]
        self._st_addr = tk.StringVar(value=s.get("address", ""))
        self._st_worker = tk.StringVar(value=s.get("worker", default_worker()))
        self._st_pool = tk.StringVar(value=s.get("pool_url", DEFAULT_POOL))
        self._st_pass = tk.StringVar(value=s.get("pass", "x"))
        self._st_proxy = tk.StringVar(value=s.get("proxy", ""))
        self._st_suggest = tk.StringVar(value=s.get("suggest_difficulty", "-1"))
        self._st_timeout = tk.StringVar(value=s.get("connect_timeout", "15"))
        self._st_cpu_batch = tk.StringVar(value=s.get("cpu_batch", str(1 << 18)))
        self._st_ipv6 = tk.BooleanVar(value=bool(s.get("prefer_ipv6", False)))
        self._st_gpu = {
            "gpu_target_seconds": tk.StringVar(value=s.get("gpu_target_seconds", "1.0")),
            "gpu_batch": tk.StringVar(value=s.get("gpu_batch", "0")),
            "gpu_per_dispatch": tk.StringVar(value=s.get("gpu_per_dispatch", "0")),
            "gpu_threadgroup": tk.StringVar(value=s.get("gpu_threadgroup", "0")),
        }

        f = self._stratum_tab
        for widget in (
            LabeledEntry(f, "收款地址 (cc1...)", self._st_addr),
            LabeledEntry(f, "Worker 名称", self._st_worker),
            LabeledEntry(f, "矿池 URL", self._st_pool),
            LabeledEntry(f, "矿池密码", self._st_pass),
            LabeledEntry(f, "代理 (--proxy)", self._st_proxy),
            LabeledEntry(f, "建议难度 (-1自动)", self._st_suggest),
            LabeledEntry(f, "连接超时 (秒)", self._st_timeout),
        ):
            widget.pack(fill=tk.X, pady=3)

        ttk.Checkbutton(f, text="优先 IPv6 (--prefer-ipv6)", variable=self._st_ipv6).pack(
            anchor="w", pady=4
        )
        GpuAdvancedFrame(f, "stratum", self._st_gpu).pack(fill=tk.X, pady=8)

        row = ttk.Frame(f)
        row.pack(fill=tk.X, pady=8)
        self._st_start = ttk.Button(row, text="开始挖矿", command=self._start_stratum)
        self._st_start.pack(side=tk.LEFT, padx=(0, 8))
        self._st_stop = ttk.Button(row, text="停止", command=self._stop, state=tk.DISABLED)
        self._st_stop.pack(side=tk.LEFT)
        ttk.Label(
            f,
            text="用户名 = 地址.worker  |  规则模式下请填写代理，如 http://127.0.0.1:7890",
            foreground="#666",
        ).pack(anchor="w")

    def _build_solo_tab(self) -> None:
        s = self.settings["solo"]
        self._so_host = tk.StringVar(value=s.get("rpchost", "127.0.0.1"))
        self._so_port = tk.StringVar(value=s.get("rpcport", "28476"))
        self._so_user = tk.StringVar(value=s.get("rpcuser", "user"))
        self._so_pass = tk.StringVar(value=s.get("rpcpassword", "pass"))
        self._so_addr = tk.StringVar(value=s.get("address", ""))
        self._so_wallet = tk.StringVar(value=s.get("wallet", "miner"))
        self._so_maxblk = tk.StringVar(value=s.get("max_blocks", "0"))
        self._so_gpu = {
            "gpu_target_seconds": tk.StringVar(value=s.get("gpu_target_seconds", "2.0")),
            "gpu_batch": tk.StringVar(value=s.get("gpu_batch", "0")),
            "gpu_per_dispatch": tk.StringVar(value=s.get("gpu_per_dispatch", "0")),
            "gpu_threadgroup": tk.StringVar(value=s.get("gpu_threadgroup", "0")),
        }

        f = self._solo_tab
        for widget in (
            LabeledEntry(f, "RPC 主机", self._so_host),
            LabeledEntry(f, "RPC 端口", self._so_port),
            LabeledEntry(f, "RPC 用户", self._so_user),
            LabeledEntry(f, "RPC 密码", self._so_pass),
            LabeledEntry(f, "收款地址 (可选)", self._so_addr),
            LabeledEntry(f, "钱包名", self._so_wallet),
            LabeledEntry(f, "最大区块数 (0=∞)", self._so_maxblk),
        ):
            widget.pack(fill=tk.X, pady=3)

        GpuAdvancedFrame(f, "solo", self._so_gpu).pack(fill=tk.X, pady=8)

        row = ttk.Frame(f)
        row.pack(fill=tk.X, pady=8)
        self._so_start = ttk.Button(row, text="开始 Solo", command=self._start_solo)
        self._so_start.pack(side=tk.LEFT, padx=(0, 8))
        self._so_stop = ttk.Button(row, text="停止", command=self._stop, state=tk.DISABLED)
        self._so_stop.pack(side=tk.LEFT)

    def _build_tools_tab(self) -> None:
        f = self._tools_tab
        self._gpu_status = tk.StringVar()
        self._refresh_gpu_status()

        ttk.Label(f, textvariable=self._gpu_status, wraplength=700).pack(anchor="w", pady=4)
        ttk.Label(f, text=f"项目路径: {repo_root()}", foreground="#666").pack(anchor="w")

        row = ttk.Frame(f)
        row.pack(fill=tk.X, pady=12)
        ttk.Button(row, text="编译 Metal Helper", command=self._tool_build).pack(
            side=tk.LEFT, padx=(0, 8)
        )
        ttk.Button(row, text="GPU 冒烟测试", command=self._tool_smoke).pack(
            side=tk.LEFT, padx=(0, 8)
        )
        ttk.Button(row, text="测试代理连接", command=self._tool_proxy).pack(side=tk.LEFT)

        ttk.Label(
            f,
            text="首次使用请先点「编译 Metal Helper」。需要已安装 Xcode Command Line Tools。",
            wraplength=700,
        ).pack(anchor="w", pady=8)

    # ----- Settings sync -----

    def _load_ui_from_settings(self) -> None:
        pass  # vars initialized from settings in _build_*_tab

    def _collect_settings(self) -> dict[str, Any]:
        return {
            "stratum": {
                "address": self._st_addr.get().strip(),
                "worker": self._st_worker.get().strip(),
                "pool_url": self._st_pool.get().strip(),
                "pass": self._st_pass.get().strip(),
                "proxy": self._st_proxy.get().strip(),
                "suggest_difficulty": self._st_suggest.get().strip(),
                "connect_timeout": self._st_timeout.get().strip(),
                "prefer_ipv6": self._st_ipv6.get(),
                "cpu_batch": self._st_cpu_batch.get().strip(),
                **{k: v.get().strip() for k, v in self._st_gpu.items()},
            },
            "solo": {
                "rpchost": self._so_host.get().strip(),
                "rpcport": self._so_port.get().strip(),
                "rpcuser": self._so_user.get().strip(),
                "rpcpassword": self._so_pass.get().strip(),
                "address": self._so_addr.get().strip(),
                "wallet": self._so_wallet.get().strip(),
                "max_blocks": self._so_maxblk.get().strip(),
                **{k: v.get().strip() for k, v in self._so_gpu.items()},
            },
        }

    def _refresh_gpu_status(self) -> None:
        if gpu_binary_ready():
            self._gpu_status.set(f"✓ GPU Helper 已就绪: {gpu_binary()}")
        else:
            self._gpu_status.set(f"✗ GPU Helper 未编译 — 请先编译: {gpu_binary()}")

    # ----- Log / status -----

    def _enqueue_log(self, line: str) -> None:
        self._ui_queue.put(("log", line))

    def _append_log(self, line: str) -> None:
        self._log.configure(state=tk.NORMAL)
        self._log.insert(tk.END, line + "\n")
        self._log.see(tk.END)
        self._log.configure(state=tk.DISABLED)
        self._parse_status_line(line)

    def _parse_status_line(self, line: str) -> None:
        m = re.search(r"mining ~([\d.]+) MH/s", line)
        if m:
            self._hashrate.set(f"{m.group(1)} MH/s")
        m = re.search(r"total accepted: (\d+)", line)
        if m:
            self._shares.set(m.group(1))
        if "SHARE ACCEPTED" in line:
            try:
                self._shares.set(str(int(self._shares.get()) + 1))
            except ValueError:
                self._shares.set("1")

    def _clear_log(self) -> None:
        self._log.configure(state=tk.NORMAL)
        self._log.delete("1.0", tk.END)
        self._log.configure(state=tk.DISABLED)

    def _drain_queue(self) -> None:
        try:
            while True:
                kind, payload = self._ui_queue.get_nowait()
                if kind == "log":
                    self._append_log(payload)
                elif kind == "status":
                    self._status.set(payload)
                elif kind == "done":
                    self._on_process_exit(payload)
        except queue.Empty:
            pass
        self.after(100, self._drain_queue)

    def _set_running_ui(self, running: bool) -> None:
        state_start = tk.DISABLED if running else tk.NORMAL
        state_stop = tk.NORMAL if running else tk.DISABLED
        self._st_start.configure(state=state_start)
        self._so_start.configure(state=state_start)
        self._st_stop.configure(state=state_stop)
        self._so_stop.configure(state=state_stop)
        self._status.set("挖矿中…" if running else "就绪")

    def _on_process_exit(self, rc: int) -> None:
        def apply() -> None:
            self._set_running_ui(False)
            self._append_log(f"[gui] 进程结束 (exit={rc})")
            self._refresh_gpu_status()

        self.after(0, apply)

    # ----- Start / stop mining -----

    def _ensure_gpu(self) -> bool:
        if gpu_binary_ready():
            return True
        if not messagebox.askyesno(
            "需要编译",
            "Metal GPU Helper 尚未编译，是否现在编译？\n需要 Xcode Command Line Tools。",
        ):
            return False
        self._append_log("[gui] 正在编译 Metal Helper …")
        ok, msg = build_metal_helper(self._enqueue_log)
        self._refresh_gpu_status()
        if not ok:
            messagebox.showerror("编译失败", msg)
            return False
        self._append_log(f"[gui] {msg}")
        return True

    def _start_stratum(self) -> None:
        if self._runner.running:
            return
        if not self._ensure_gpu():
            return

        addr = self._st_addr.get().strip()
        if not addr:
            messagebox.showwarning("缺少地址", "请填写 BTCC 收款地址 (cc1...)")
            return

        worker = self._st_worker.get().strip() or default_worker()
        pool = self._st_pool.get().strip() or DEFAULT_POOL
        user = f"{addr}.{worker}"

        argv = [
            python_exe(),
            str(src_dir() / "stratum_miner.py"),
            "--url", pool,
            "--user", user,
            "--pass", self._st_pass.get().strip() or "x",
        ]

        proxy = self._st_proxy.get().strip()
        if proxy:
            argv.extend(["--proxy", proxy])

        suggest = self._st_suggest.get().strip()
        if suggest:
            argv.extend(["--suggest-difficulty", suggest])

        timeout = self._st_timeout.get().strip()
        if timeout:
            argv.extend(["--connect-timeout", timeout])

        if self._st_ipv6.get():
            argv.append("--prefer-ipv6")

        argv.extend(gpu_args_from_vars(self._st_gpu))

        save_settings(self._collect_settings())
        self._shares.set("0")
        self._hashrate.set("—")
        self._append_log(f"[gui] 启动矿池挖矿: {user} @ {pool}")
        try:
            self._runner.start(argv, cwd=str(repo_root()))
            self._set_running_ui(True)
        except Exception as e:
            messagebox.showerror("启动失败", str(e))

    def _start_solo(self) -> None:
        if self._runner.running:
            return
        if not self._ensure_gpu():
            return

        argv = [
            python_exe(),
            str(src_dir() / "gbt_miner.py"),
            "--rpchost", self._so_host.get().strip(),
            "--rpcport", self._so_port.get().strip(),
            "--rpcuser", self._so_user.get().strip(),
            "--rpcpassword", self._so_pass.get().strip(),
            "--wallet", self._so_wallet.get().strip() or "miner",
        ]

        addr = self._so_addr.get().strip()
        if addr:
            argv.extend(["--address", addr])

        maxblk = self._so_maxblk.get().strip()
        if maxblk and maxblk != "0":
            argv.extend(["--max-blocks", maxblk])

        argv.extend(gpu_args_from_vars(self._so_gpu))

        save_settings(self._collect_settings())
        self._append_log("[gui] 启动 Solo 挖矿 …")
        try:
            self._runner.start(argv, cwd=str(repo_root()))
            self._set_running_ui(True)
        except Exception as e:
            messagebox.showerror("启动失败", str(e))

    def _stop(self) -> None:
        if self._runner.running:
            self._append_log("[gui] 正在停止 …")
            self._runner.stop()

    # ----- Tools -----

    def _tool_build(self) -> None:
        if self._runner.running:
            messagebox.showwarning("忙", "请先停止挖矿")
            return
        self._append_log("[gui] 编译 Metal Helper …")
        ok, msg = build_metal_helper(self._enqueue_log)
        self._refresh_gpu_status()
        if ok:
            messagebox.showinfo("完成", msg)
        else:
            messagebox.showerror("失败", msg)

    def _tool_smoke(self) -> None:
        if self._runner.running:
            messagebox.showwarning("忙", "请先停止挖矿")
            return
        if not self._ensure_gpu():
            return
        argv = [python_exe(), str(repo_root() / "tests" / "smoke_metal_nonce_finder.py")]
        self._append_log("[gui] 运行冒烟测试 …")
        self._runner.start(argv, cwd=str(repo_root()))
        self._set_running_ui(True)

    def _tool_proxy(self) -> None:
        if self._runner.running:
            messagebox.showwarning("忙", "请先停止挖矿")
            return
        proxy = self._st_proxy.get().strip()
        if not proxy:
            proxy = "http://127.0.0.1:7890"
            self._st_proxy.set(proxy)
        script = repo_root() / "scripts" / "test_proxy.sh"
        if not script.is_file():
            messagebox.showerror("缺失", f"未找到 {script}")
            return
        argv = ["/bin/bash", str(script), proxy]
        self._append_log(f"[gui] 测试代理: {proxy}")
        self._runner.start(argv, cwd=str(repo_root()))
        self._set_running_ui(True)

    def _on_close(self) -> None:
        if self._runner.running:
            if not messagebox.askyesno("确认退出", "挖矿正在运行，确定退出？"):
                return
            self._runner.stop()
        save_settings(self._collect_settings())
        self.destroy()


def main() -> int:
    if sys.platform != "darwin":
        print("macOS only", file=sys.stderr)
        return 1
    # Allow importing stratum_miner helpers when running proxy test from gui dir
    sys.path.insert(0, str(src_dir()))
    app = MinerGUI()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
