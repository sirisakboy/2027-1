#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Arena Proxy — GUI (Tkinter) สำหรับ Kali Linux

ทำไมต้องมี: การตั้ง proxy ทั้งเครื่องบน Kali ต้องแก้หลายที่พร้อมกัน
(GNOME gsettings, XFCE xfconf, http_proxy ในเชลล์, apt, Firefox)
พิมพ์ผิดที่เดียวก็พัง — ตัวนี้ทำทั้งชุดจากช่อง IP + Port เดียว

รัน:  python3 arena_proxy_gui.py
      pkexec python3 arena_proxy_gui.py     # ถ้าจะตั้ง apt/sudo ด้วย

หน้าจอมี: ช่อง IP · ช่อง Port · ปุ่ม Apply · ปุ่ม Sync from Firefox · สวิตช์ ON/OFF
"""

from __future__ import annotations

import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import webbrowser
from pathlib import Path

# ── ให้ import core ได้ทั้งตอนรันตรง ๆ และตอนถูก import จากเทสต์ ──
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import tkinter as tk
from tkinter import messagebox, ttk

import arena_proxy_core as core

APP_TITLE = f"Arena Proxy {core.VERSION} — Kali Linux"
C_BG = "#12141a"
C_PANEL = "#1b1f27"
C_FG = "#e6e6e6"
C_DIM = "#8b93a7"
C_ACCENT = "#3ddc97"
C_ON = "#3ddc97"
C_OFF = "#ff5c7a"
C_WARN = "#ffcc66"
C_ENTRY = "#0e1015"


class ArenaProxyApp:
    """หน้าต่างหลัก — โครงสร้างแยกเป็น widget ย่อยให้เทสต์ด้วย stub ได้"""

    def __init__(self, root: tk.Misc, home: Path | None = None):
        self.root = root
        self.home = Path(home) if home else Path.home()
        self.state = core.load_state(self.home)
        self.log_q: queue.Queue[tuple[str, str]] = queue.Queue()
        self._busy = False

        try:
            root.title(APP_TITLE)
            root.minsize(720, 620)
            root.configure(bg=C_BG)
        except tk.TclError:
            pass

        self._build_style()
        self._build_header()
        self._build_form()
        self._build_actions()
        self._build_log()
        self._build_footer()

        self._refresh_status()
        self._pump_log()
        self.log("info", f"พร้อมใช้งาน · config: {core.config_path(self.home)}")
        self._detect_desktop()

    # ─────────────────────────────── widgets ──
    def _build_style(self):
        try:
            st = ttk.Style()
            st.theme_use("clam")
            st.configure("A.TFrame", background=C_BG)
            st.configure("P.TFrame", background=C_PANEL)
            st.configure("A.TLabel", background=C_BG, foreground=C_FG, font=("DejaVu Sans", 10))
            st.configure("Title.TLabel", background=C_BG, foreground=C_FG, font=("DejaVu Sans", 16, "bold"))
            st.configure("Dim.TLabel", background=C_BG, foreground=C_DIM, font=("DejaVu Sans", 9))
            st.configure("P.TLabel", background=C_PANEL, foreground=C_FG, font=("DejaVu Sans", 10))
            st.configure("PDim.TLabel", background=C_PANEL, foreground=C_DIM, font=("DejaVu Sans", 9))
            st.configure("A.TButton", font=("DejaVu Sans", 10, "bold"), padding=(14, 9))
            st.configure("Big.TButton", font=("DejaVu Sans", 11, "bold"), padding=(18, 11))
            st.configure("A.TCheckbutton", background=C_PANEL, foreground=C_FG,
                         font=("DejaVu Sans", 10), selectcolor=C_ENTRY)
            st.configure("A.TEntry", fieldbackground=C_ENTRY, foreground=C_FG,
                         insertcolor=C_FG, padding=8)
            st.configure("S.TEntry", fieldbackground=C_ENTRY, foreground=C_ACCENT,
                         insertcolor=C_ACCENT, padding=8)
            st.configure("A.Horizontal.TProgressbar", background=C_ACCENT)
        except tk.TclError:
            pass

    def _build_header(self):
        hdr = ttk.Frame(self.root, style="A.TFrame", padding=(22, 18, 22, 6))
        hdr.pack(fill="x")
        ttk.Label(hdr, text="Arena Proxy", style="Title.TLabel").pack(side="left")
        ttk.Label(hdr, text="ตั้ง proxy ทั้งเครื่อง Kali — ที่เดียวจบ", style="Dim.TLabel").pack(
            side="left", padx=(14, 0), pady=(6, 0))

        self.status_lbl = ttk.Label(hdr, text="● ปิดอยู่", style="A.TLabel")
        self.status_lbl.pack(side="right")

    def _build_form(self):
        wrap = ttk.Frame(self.root, style="A.TFrame", padding=(22, 8, 22, 0))
        wrap.pack(fill="x")
        box = ttk.Frame(wrap, style="P.TFrame", padding=18)
        box.pack(fill="x")
        ttk.Label(box, text="ปลายทาง proxy", style="PDim.TLabel").grid(
            row=0, column=0, columnspan=4, sticky="w", pady=(0, 10))

        ttk.Label(box, text="IP / Host", style="P.TLabel").grid(row=1, column=0, sticky="w", padx=(0, 10))
        self.ip_var = tk.StringVar(value=self.state.host)
        self.ip_entry = ttk.Entry(box, textvariable=self.ip_var, style="S.TEntry", width=26, font=("DejaVu Sans Mono", 12))
        self.ip_entry.grid(row=2, column=0, sticky="we", padx=(0, 16))

        ttk.Label(box, text="Port", style="P.TLabel").grid(row=1, column=1, sticky="w", padx=(0, 10))
        self.port_var = tk.StringVar(value=str(self.state.port))
        self.port_entry = ttk.Entry(box, textvariable=self.port_var, style="S.TEntry", width=10, font=("DejaVu Sans Mono", 12))
        self.port_entry.grid(row=2, column=1, sticky="we", padx=(0, 16))

        ttk.Label(box, text="ชนิด", style="P.TLabel").grid(row=1, column=2, sticky="w", padx=(0, 10))
        self.kind_var = tk.StringVar(value=self.state.kind)
        self.kind_cb = ttk.Combobox(box, textvariable=self.kind_var, values=("http", "socks5"),
                                    state="readonly", width=10, font=("DejaVu Sans", 11))
        self.kind_cb.grid(row=2, column=2, sticky="we", padx=(0, 16))

        self.no_proxy_lbl = ttk.Label(box, text="", style="PDim.TLabel")
        self.no_proxy_lbl.grid(row=3, column=0, columnspan=4, sticky="w", pady=(10, 0))

        box.columnconfigure(0, weight=3)
        box.columnconfigure(1, weight=0)
        box.columnconfigure(2, weight=0)

        # ตัวเลือกว่าจะให้ตั้งอะไรบ้าง
        self.gnome_var = tk.BooleanVar(value=self.state.apply_gnome)
        self.xfce_var = tk.BooleanVar(value=self.state.apply_xfce)
        self.apt_var = tk.BooleanVar(value=self.state.apply_apt)
        opts = ttk.Frame(wrap, style="A.TFrame", padding=(0, 10, 0, 0))
        opts.pack(fill="x")
        ttk.Label(opts, text="ตั้งกับ:", style="Dim.TLabel").pack(side="left")
        for text, var, name in (
            ("GNOME (gsettings)", self.gnome_var, "gnome"),
            ("XFCE (xfconf)", self.xfce_var, "xfce"),
            ("apt / sudo (ต้อง root)", self.apt_var, "apt"),
        ):
            cb = ttk.Checkbutton(opts, text=text, variable=var, style="A.TCheckbutton")
            cb.pack(side="left", padx=(10, 0))
            setattr(self, f"chk_{name}", cb)

    def _build_actions(self):
        bar = ttk.Frame(self.root, style="A.TFrame", padding=(22, 14, 22, 0))
        bar.pack(fill="x")

        self.apply_btn = ttk.Button(bar, text="  Apply  ", style="Big.TButton", command=self.on_apply)
        self.apply_btn.pack(side="left")

        self.off_btn = ttk.Button(bar, text="  ปิด (OFF)  ", style="A.TButton", command=self.on_off)
        self.off_btn.pack(side="left", padx=(10, 0))

        self.sync_btn = ttk.Button(bar, text="  Sync from Firefox  ", style="A.TButton", command=self.on_sync)
        self.sync_btn.pack(side="left", padx=(10, 0))

        self.test_btn = ttk.Button(bar, text="  ทดสอบ  ", style="A.TButton", command=self.on_test)
        self.test_btn.pack(side="left", padx=(10, 0))

        # สวิตช์ ON/OFF
        sw = ttk.Frame(bar, style="A.TFrame")
        sw.pack(side="right")
        ttk.Label(sw, text="สถานะ:", style="Dim.TLabel").pack(side="left", padx=(0, 8))
        self.toggle = tk.Button(
            sw, text="OFF", width=7, relief="flat", bd=0,
            bg=C_OFF, fg="#0b0d11", activebackground=C_OFF,
            font=("DejaVu Sans", 12, "bold"), cursor="hand2", command=self.on_toggle,
        )
        self.toggle.pack(side="left")

    def _build_log(self):
        wrap = ttk.Frame(self.root, style="A.TFrame", padding=(22, 14, 22, 0))
        wrap.pack(fill="both", expand=True)
        ttk.Label(wrap, text="บันทึก", style="Dim.TLabel").pack(anchor="w", pady=(0, 6))
        holder = tk.Frame(wrap, bg=C_PANEL, highlightthickness=1, highlightbackground="#2a3040")
        holder.pack(fill="both", expand=True)
        self.log_txt = tk.Text(
            holder, height=11, bg=C_PANEL, fg=C_FG, bd=0, padx=12, pady=10,
            font=("DejaVu Sans Mono", 9), wrap="word", state="disabled",
            insertbackground=C_FG,
        )
        sb = ttk.Scrollbar(holder, orient="vertical", command=self.log_txt.yview)
        self.log_txt.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self.log_txt.pack(side="left", fill="both", expand=True)
        for tag, color in (("ok", C_ON), ("err", C_OFF), ("warn", C_WARN),
                           ("info", C_DIM), ("head", C_ACCENT)):
            self.log_txt.tag_configure(tag, foreground=color)
        self.progress = ttk.Progressbar(wrap, mode="indeterminate", style="A.Horizontal.TProgressbar")
        self.progress.pack(fill="x", pady=(8, 0))

    def _build_footer(self):
        f = ttk.Frame(self.root, style="A.TFrame", padding=(22, 10, 22, 14))
        f.pack(fill="x")
        self.hint_lbl = ttk.Label(
            f,
            text="เปิด terminal ใหม่ (หรือ `source ~/.config/arena-proxy/env.sh`) เพื่อให้ http_proxy มีผลในเชลล์ปัจจุบัน",
            style="Dim.TLabel",
        )
        self.hint_lbl.pack(side="left")
        ttk.Button(f, text="คู่มือ", style="A.TButton",
                   command=lambda: webbrowser.open("https://github.com/sirisakboy/2027-1#readme")).pack(side="right")

    # ─────────────────────────────── helpers ──
    def log(self, level: str, msg: str) -> None:
        self.log_q.put((level, msg))

    def _pump_log(self):
        try:
            while True:
                level, msg = self.log_q.get_nowait()
                self.log_txt.configure(state="normal")
                prefix = {"ok": "✔ ", "err": "✖ ", "warn": "! ", "info": "· ", "head": "▸ "}.get(level, "· ")
                self.log_txt.insert("end", prefix + str(msg) + "\n", level)
                self.log_txt.see("end")
                self.log_txt.configure(state="disabled")
        except queue.Empty:
            pass
        try:
            self.root.after(120, self._pump_log)
        except tk.TclError:
            pass

    def _set_busy(self, busy: bool) -> None:
        self._busy = busy
        state = "disabled" if busy else "normal"
        for b in (self.apply_btn, self.off_btn, self.sync_btn, self.test_btn):
            try:
                b.configure(state=state)
            except tk.TclError:
                pass
        try:
            if busy:
                self.progress.start(12)
            else:
                self.progress.stop()
        except tk.TclError:
            pass

    def _refresh_status(self) -> None:
        self.state = core.load_state(self.home)
        on = self.state.enabled
        try:
            self.status_lbl.configure(text=("● เปิดอยู่ · " + self.state.url()) if on else "● ปิดอยู่",
                                      foreground=C_ON if on else C_OFF)
            self.toggle.configure(text="ON" if on else "OFF",
                                  bg=C_ON if on else C_OFF,
                                  activebackground=C_ON if on else C_OFF)
        except tk.TclError:
            pass
        try:
            self.no_proxy_lbl.configure(
                text="ยกเว้น (no_proxy): " + ", ".join(self.state.no_proxy[:6])
                     + (f" … +{len(self.state.no_proxy) - 6}" if len(self.state.no_proxy) > 6 else ""))
        except tk.TclError:
            pass

    def _detect_desktop(self) -> None:
        """บอกผู้ใช้ว่าเครื่องนี้มี GNOME/XFCE ให้ตั้งไหม (Kali ปกติ = XFCE)"""
        has_gs = core.have("gsettings") and bool(os.environ.get("DBUS_SESSION_BUS_ADDRESS"))
        has_xf = core.have("xfconf-query") and bool(
            os.environ.get("XFCE4SESSION_OWNER") or os.environ.get("XDG_CURRENT_DESKTOP", "").lower().find("xfce") >= 0
            or os.environ.get("DESKTOP_SESSION", "").lower().find("xfce") >= 0
        )
        de = os.environ.get("XDG_CURRENT_DESKTOP") or os.environ.get("DESKTOP_SESSION") or "?"
        self.log("head", f"desktop ที่ตรวจพบ: {de}")
        if has_gs:
            self.log("ok", "GNOME/gsettings พร้อมใช้งาน")
        else:
            self.log("warn", "gsettings ใช้ไม่ได้ในเซสชันนี้ (ไม่มี D-Bus?) — จะข้าม GNOME")
        if has_xf:
            self.log("ok", "XFCE/xfconf พร้อมใช้งาน")
        else:
            self.log("warn", "xfconf-query ใช้ไม่ได้ในเซสชันนี้ — จะข้าม XFCE")
        if core.have("firefox") or core.have("firefox-esr"):
            profs = core.find_firefox_profiles(self.home)
            self.log("info", f"Firefox: พบ {len(profs)} โปรไฟล์" if profs else "Firefox: ยังไม่พบโปรไฟล์ (เปิด Firefox ก่อน)")

    def read_form(self) -> core.ProxyState:
        st = core.ProxyState(
            host=self.ip_var.get().strip(),
            port=int(self.port_var.get()) if str(self.port_var.get()).strip().isdigit() else -1,
            kind=self.kind_var.get() or "http",
            no_proxy=list(self.state.no_proxy or core.DEFAULT_NO_PROXY),
            enabled=True,
            apply_gnome=bool(self.gnome_var.get()),
            apply_xfce=bool(self.xfce_var.get()),
            apply_apt=bool(self.apt_var.get()),
        )
        return st

    def _report(self, results) -> bool:
        all_ok = True
        for r in results:
            if r.ok:
                self.log("ok", f"{r.label}: {r.detail}")
            else:
                all_ok = False
                self.log("err", f"{r.label}: {r.detail}")
        return all_ok

    # ─────────────────────────────── actions ──
    def on_apply(self) -> None:
        st = self.read_form()
        errs = st.validate()
        if errs:
            for e in errs:
                self.log("err", e)
            try:
                messagebox.showerror("ค่าไม่ถูกต้อง", "\n".join(errs), parent=self.root)
            except tk.TclError:
                pass
            return
        self.log("head", f"Apply → {st.url()}  (GNOME={st.apply_gnome} XFCE={st.apply_xfce} apt={st.apply_apt})")
        self._set_busy(True)

        def work():
            try:
                res = core.apply_state(st, self.home)
                self._report(res)
                self.log("ok", "Apply เสร็จ — เปิด terminal ใหม่เพื่อใช้ http_proxy")
            except Exception as e:  # noqa: BLE001 — ต้องไม่ทำให้ GUI ตาย
                self.log("err", f"Apply ล้มเหลว: {e}")
            finally:
                self.root.after(0, lambda: (self._set_busy(False), self._refresh_status()))

        threading.Thread(target=work, daemon=True).start()

    def on_off(self) -> None:
        self.log("head", "ปิด proxy ทุกชั้น")
        self._set_busy(True)

        def work():
            try:
                self._report(core.clear_state(self.state, self.home))
                self.log("ok", "ปิดแล้ว — คืนค่าเดิมของระบบ (ถ้ามี snapshot)")
            except Exception as e:  # noqa: BLE001
                self.log("err", f"ปิดล้มเหลว: {e}")
            finally:
                self.root.after(0, lambda: (self._set_busy(False), self._refresh_status()))

        threading.Thread(target=work, daemon=True).start()

    def on_toggle(self) -> None:
        cur = core.load_state(self.home)
        if cur.enabled:
            self.on_off()
        else:
            self.on_apply()

    def on_sync(self) -> None:
        """ดึงค่า proxy จาก Firefox แล้วเติมลงช่อง IP/Port/ชนิด"""
        self.log("head", "Sync from Firefox")
        profs = core.find_firefox_profiles(self.home)
        if not profs:
            self.log("err", "ไม่พบโปรไฟล์ Firefox — เปิด Firefox อย่างน้อยหนึ่งครั้งก่อน")
            self.log("info", f"ค้นหาใน: {Path(self.home) / '.mozilla/firefox'} (รวม snap/flatpak)")
            return
        last_err = ""
        for p in profs:
            prefs = core.read_firefox_proxy(p)
            if not prefs:
                last_err = f"{p.name}: อ่าน prefs ไม่ได้"
                continue
            st, warns = core.firefox_to_state(prefs, self.state)
            for w in warns:
                self.log("warn", f"{p.name}: {w}")
            if st.host and st.port and int(st.port) > 0:
                self.ip_var.set(st.host)
                self.port_var.set(str(st.port))
                self.kind_var.set(st.kind)
                self.state.no_proxy = st.no_proxy
                self._refresh_status()
                self.log("ok", f"ซิงก์จาก {p.name} → {st.url()} (no_proxy {len(st.no_proxy)} รายการ)")
                self.log("info", "ตรวจค่าแล้วกด Apply เพื่อใช้งาน (Sync ไม่ได้ตั้งค่าให้เอง)")
                return
        self.log("err", last_err or "ไม่พบค่าที่ใช้ได้ใน Firefox")

    def on_test(self) -> None:
        """ทดสอบว่าปลายทางตอบจริง — ผ่าน proxy ที่กรอกไว้"""
        st = self.read_form()
        errs = st.validate()
        if errs:
            for e in errs:
                self.log("err", e)
            return
        self.log("head", f"ทดสอบ {st.url()}")
        self._set_busy(True)

        def work():
            try:
                import socket
                sock = socket.create_connection((st.host, int(st.port)), timeout=6)
                sock.close()
                self.log("ok", f"เชื่อมต่อ TCP {st.host}:{st.port} ได้")
            except Exception as e:  # noqa: BLE001
                self.log("err", f"เชื่อมต่อไม่ได้: {e}")
                self.log("info", "ตรวจว่า proxy/VPN ทำงานอยู่ และ IP/Port ถูก")
                self.root.after(0, lambda: self._set_busy(False))
                return
            # ลอง HTTP ผ่าน proxy จริง (ถ้ามี curl)
            if core.have("curl"):
                r = core.run([
                    "curl", "-sS", "--max-time", "8", "-o", "/dev/null",
                    "-w", "%{http_code}", "-x", st.url(), "https://ifconfig.me/ip",
                ])
                code = (r.stdout or "").strip()
                if r.returncode == 0 and code.startswith(("2", "3")):
                    self.log("ok", f"ผ่าน proxy ออกเน็ตได้ (HTTP {code})")
                else:
                    self.log("warn", f"ต่อ TCP ได้ แต่ HTTP ผ่าน proxy ไม่ผ่าน (curl rc={r.returncode})")
            self.root.after(0, lambda: (self._set_busy(False), self._refresh_status()))

        threading.Thread(target=work, daemon=True).start()


# ─────────────────────────────────────────── main ──
def _ensure_disclaimer(parent=None) -> None:
    pass


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--selftest" in argv or "--version" in argv:
        return core.main_selftest()
    headless = "--headless" in argv

    if not headless and not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        sys.stderr.write("ไม่พบ DISPLAY — ต้องรันในหน้าจอ (หรือใช้ --selftest)\n")
        return 2

    try:
        root = tk.Tk()
    except tk.TclError as e:
        sys.stderr.write(f"เปิดหน้าต่างไม่ได้: {e}\n")
        sys.stderr.write("ทางแก้: ติดตั้ง python3-tk และรันในเซสชันเดสก์ท็อป\n")
        return 2

    app = ArenaProxyApp(root)
    if headless:
        # สำหรับเทสต์: สร้าง widget ทั้งหมดแล้วออกทันที
        try:
            root.after(10, root.destroy)
            root.mainloop()
        except tk.TclError:
            pass
        return 0
    try:
        root.mainloop()
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
