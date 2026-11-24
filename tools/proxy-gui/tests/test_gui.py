#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
เทสต์ Arena Proxy — รันได้ทุกเครื่อง ไม่ต้องมีจอ ไม่ต้องมี kali

    python3 tools/proxy-gui/tests/test_gui.py

สองชั้น:
  A) core  — gsettings/xfconf/env/Firefox/state ล้วน ๆ (ไม่แตะระบบจริง)
  B) GUI   — สร้าง widget จริงบน tkinter stub แล้ว "กดปุ่ม" ตรวจ handler

ทุกคำสั่งภายนอกถูกดักที่ core.run() → ไม่มีการแก้เครื่องจริงระหว่างเทสต์
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
sys.path.insert(0, str(HERE / "stubs"))   # tkinter ปลอม
sys.path.insert(0, str(PKG))

import tkinter as tk                    # noqa: E402  (ได้ stub)
from tkinter import messagebox, ttk     # noqa: E402

import arena_proxy_core as core         # noqa: E402
import arena_proxy_gui as gui           # noqa: E402

PASS = 0
FAIL = 0
SKIP = 0
FAILS: list[str] = []


def ok(name: str, cond: bool, detail: str = "") -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  \033[32m✔\033[0m {name}")
    else:
        FAIL += 1
        FAILS.append(f"{name} :: {detail}")
        print(f"  \033[31m✖\033[0m {name}" + (f"\n      {detail}" if detail else ""))


def skip(name: str) -> None:
    global SKIP
    SKIP += 1
    print(f"  \033[33m○\033[0m {name} (ข้าม)")


def eq(name: str, got, want, extra: str = "") -> None:
    ok(name, got == want, f"got={got!r} want={want!r} {extra}".strip())


def group(title: str) -> None:
    print(f"\n\033[1m▸ {title}\033[0m")


# ───────────────────────────────── ดักคำสั่งภายนอก ──
class FakeSystem:
    """แทน core.run / core.have — บันทึกคำสั่งแทนการรันจริง"""

    def __init__(self):
        self.calls: list[list[str]] = []
        self.tools = {"gsettings", "xfconf-query", "curl"}
        self.fail_on: set[str] = set()
        self.gsettings_db: dict[str, str] = {}

    def install(self):
        core.run = self.run          # type: ignore[assignment]
        core.have = self.have        # type: ignore[assignment]
        return self

    def run(self, cmd, *, timeout=10, check=False):
        cmd = list(cmd)
        # เลียนแบบ subprocess ของจริง: ถ้ามี non-str จะ TypeError
        # (เทสต์ที่หลวมเกินไปเคยปล่อยบั๊ก int หลุดไปถึงเครื่องจริงมาแล้ว)
        for a in cmd:
            if not isinstance(a, str):
                raise TypeError(f"expected str, bytes or os.PathLike object, not {type(a).__name__}: {cmd!r}")
        self.calls.append(cmd)
        prog = cmd[0]
        if prog in self.fail_on:
            return core.subprocess.CompletedProcess(cmd, 1, "", f"{prog}: simulated failure")
        if prog == "gsettings":
            sub = cmd[1] if len(cmd) > 1 else ""
            if sub == "get" and len(cmd) >= 5:
                return core.subprocess.CompletedProcess(
                    cmd, 0, self.gsettings_db.get(f"{cmd[2]} {cmd[3]}", "default"), "")
            if sub == "set" and len(cmd) >= 5:
                self.gsettings_db[f"{cmd[2]} {cmd[3]}"] = str(cmd[4])
                return core.subprocess.CompletedProcess(cmd, 0, "", "")
        if prog == "curl":
            return core.subprocess.CompletedProcess(cmd, 0, "200", "")
        return core.subprocess.CompletedProcess(cmd, 0, "", "")

    def have(self, name):
        return name in self.tools

    def gset_calls(self) -> list[list[str]]:
        return [c for c in self.calls if c and c[0] == "gsettings" and c[1] == "set"]

    def find(self, *needle) -> list[list[str]]:
        return [c for c in self.calls if all(n in c for n in needle)]


# ───────────────────────────────── A) core ──
def test_core():
    group("1. ตรวจค่า IP / Port")
    st = core.ProxyState(host="127.0.0.1", port=8080)
    eq("ค่าเริ่มต้นผ่านการตรวจ", st.validate(), [])
    eq("URL แบบ http", core.ProxyState(host="10.0.0.5", port=3128).url(), "http://10.0.0.5:3128")
    eq("URL แบบ socks5 (ใช้ socks5h = DNS ฝั่ง proxy)",
       core.ProxyState(host="10.0.0.5", port=1080, kind="socks5").url(), "socks5h://10.0.0.5:1080")
    ok("IP ว่าง → error", any("IP" in e for e in core.ProxyState(host="  ").validate()))
    ok("port 0 → error", core.ProxyState(port=0).validate() != [])
    ok("port 70000 → error", core.ProxyState(port=70000).validate() != [])
    ok("port ไม่ใช่ตัวเลข → error", core.ProxyState(port="abc").validate() != [])
    ok("IP มีอักขระแปลก → error", core.ProxyState(host="1.2.3.4; rm -rf /").validate() != [])
    ok("IPv6 ผ่าน", core.ProxyState(host="::1", port=8080).validate() == [])

    group("2. gsettings (GNOME) — คำสั่งที่สร้าง")
    st = core.ProxyState(host="127.0.0.1", port=8080)
    cmds = core.build_gsettings_set(st)
    flat = [" ".join(map(str, c)) for c in cmds]
    ok("ตั้ง mode=manual", 'gsettings set org.gnome.system.proxy mode manual' in flat, str(flat[:1]))
    ok("ตั้ง http host", "gsettings set org.gnome.system.proxy.http host 127.0.0.1" in flat)
    ok("ตั้ง http port (เป็น int ไม่ใช่ str)", "gsettings set org.gnome.system.proxy.http port 8080" in flat)
    ok("ตั้ง https host ด้วย", "gsettings set org.gnome.system.proxy.https host 127.0.0.1" in flat)
    ok("ตั้ง ignore-hosts", any("ignore-hosts" in f for f in flat))
    ok("ตั้ง use-same-proxy", any("use-same-proxy true" in f for f in flat))
    ih = [c for c in cmds if "ignore-hosts" in c][0][-1]
    ok("ignore-hosts เป็น GVariant array", ih.startswith("[") and ih.endswith("]") and "'localhost'" in ih, ih)
    ok("ignore-hosts มี WireGuard subnet", "10.8.0.0/24" in ih, ih)
    ok("ignore-hosts มี CGNAT (กัน loop)", "100.64.0.0/10" in ih, ih)

    st_socks = core.ProxyState(host="127.0.0.1", port=1080, kind="socks5")
    flat_s = [" ".join(map(str, c)) for c in core.build_gsettings_set(st_socks)]
    ok("socks5 ตั้ง socks host/port", any("system.proxy.socks host" in f for f in flat_s))
    ok("socks5 ตั้ง socks port 1080", any("system.proxy.socks port 1080" in f for f in flat_s))
    flat_h = [" ".join(map(str, c)) for c in core.build_gsettings_set(core.ProxyState(kind="http"))]
    ok("http ล้างค่า socks เดิม (port 0)", any("system.proxy.socks port 0" in f for f in flat_h))

    eq("ปิด = mode none", core.build_gsettings_off(),
       [["gsettings", "set", "org.gnome.system.proxy", "mode", "none"]])

    group("3. คืนค่าเดิม (snapshot)")
    snap = {"org.gnome.system.proxy mode": "'auto'", "org.gnome.system.proxy.http port": "3128"}
    rest = core.build_gsettings_restore(snap)
    eq("คืนค่าได้ครบ 2 รายการ", len(rest), 2)
    ok("คืน mode=auto", ["'auto'" in c for c in rest if "mode" in c][0])
    eq("snapshot ว่าง → ไม่มีคำสั่ง", core.build_gsettings_restore({}), [])
    ok("snapshot มีค่าแปลก ('' ) → ข้าม", core.build_gsettings_restore({"x y": ""}) == [])

    group("4. XFCE (ค่าเริ่มต้นของ Kali)")
    xf = [" ".join(map(str, c)) for c in core.build_xfconf_set(core.ProxyState(host="10.1.1.1", port=8080))]
    ok("ใช้ xfconf-query", all(f.startswith("xfconf-query") for f in xf))
    ok("ตั้ง /system/proxy/mode", any("/system/proxy/mode" in f and "manual" in f for f in xf))
    ok("ตั้ง http host", any("/system/proxy/http/host" in f and "10.1.1.1" in f for f in xf))
    ok("ระบุชนิด int สำหรับ port", any("/system/proxy/http/port" in f and "-t int" in f for f in xf))
    ok("ปิด XFCE = mode none", "none" in " ".join(core.build_xfconf_off()[0]))

    group("5. ตัวแปรสภาพแวดล้อม (export http_proxy/https_proxy)")
    st = core.ProxyState(host="127.0.0.1", port=8080)
    env = core.build_env_vars(st)
    eq("http_proxy", env["http_proxy"], "http://127.0.0.1:8080")
    eq("https_proxy", env["https_proxy"], "http://127.0.0.1:8080")
    eq("HTTP_PROXY (ตัวใหญ่)", env["HTTP_PROXY"], "http://127.0.0.1:8080")
    eq("HTTPS_PROXY (ตัวใหญ่)", env["HTTPS_PROXY"], "http://127.0.0.1:8080")
    ok("no_proxy มี localhost", "localhost" in env["no_proxy"])
    ok("no_proxy มี 127.0.0.1 (ห้ามตัด!)", "127.0.0.1" in env["no_proxy"])
    ok("no_proxy มี 10.8.0.0/24 (WireGuard)", "10.8.0.0/24" in env["no_proxy"])
    ok("http ไม่ตั้ง all_proxy (จะพัง curl)", "all_proxy" not in env)
    env_s = core.build_env_vars(core.ProxyState(kind="socks5", port=1080))
    eq("socks5 ตั้ง all_proxy", env_s["all_proxy"], "socks5h://127.0.0.1:1080")

    on = core.build_env_snippet(core.ProxyState(host="127.0.0.1", port=8080, enabled=True))
    ok("env.sh ตอนเปิดมี export http_proxy", "export http_proxy=" in on)
    ok("env.sh ตอนเปิดมี export https_proxy", "export https_proxy=" in on)
    ok("env.sh ใช้เครื่องหมายคำพูดกันช่องว่าง", "'http://127.0.0.1:8080'" in on)
    off = core.build_env_snippet(core.ProxyState(host="127.0.0.1", port=8080, enabled=False))
    ok("env.sh ตอนปิด = unset", "unset http_proxy" in off and "export http_proxy=" not in off)
    ok("env.sh ตอนปิด unset all_proxy ด้วย", "unset all_proxy" in off)

    group("6. ใส่บล็อกใน rc (idempotent)")
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        (home / ".bashrc").write_text("# ของเดิม\nalias ll='ls -l'\n")
        (home / ".zshrc").write_text("# zsh เดิม\n")
        touched = core.install_rc_block(home)
        eq("แก้ 2 ไฟล์ที่มีอยู่ (+.profile ที่สร้างใหม่)", len(touched), 3)
        txt = (home / ".bashrc").read_text()
        ok("มี marker ครบ", core.RC_MARK_BEGIN in txt and core.RC_MARK_END in txt)
        ok("ไม่ทำลายเนื้อหาเดิม", "alias ll='ls -l'" in txt)
        ok("ใช้ guarded source (ไม่พังถ้าไฟล์หาย)", '[ -f "$HOME/.config/arena-proxy/env.sh" ]' in txt)
        again = core.install_rc_block(home)
        eq("รันซ้ำไม่เพิ่มบล็อกที่สอง", len(again), 0)
        eq("ยังมี marker เดียว", (home / ".bashrc").read_text().count(core.RC_MARK_BEGIN), 1)
        removed = core.remove_rc_block(home)
        eq("ลบบล็อกได้ 3 ไฟล์", len(removed), 3)
        ok("เนื้อหาเดิมยังอยู่หลังลบ", "alias ll='ls -l'" in (home / ".bashrc").read_text())
        ok("marker หายไปแล้ว", core.RC_MARK_BEGIN not in (home / ".bashrc").read_text())

    group("7. apt.conf (ต้อง root)")
    conf = core.build_apt_conf(core.ProxyState(host="127.0.0.1", port=8080))
    ok("ตั้ง Acquire::http::Proxy", 'Acquire::http::Proxy "http://127.0.0.1:8080";' in conf)
    ok("ตั้ง Acquire::https::Proxy", "Acquire::https::Proxy" in conf)
    ok("เป็นไฟล์เดียวใน /etc/apt/apt.conf.d", core.APT_FILE == "/etc/apt/apt.conf.d/95arena-proxy")

    group("8. อ่าน prefs.js ของ Firefox")
    js = (
        '// Mozilla User Preferences\n'
        'user_pref("network.proxy.type", 1);\n'
        'user_pref("network.proxy.http", "10.0.0.5");\n'
        'user_pref("network.proxy.http_port", 3128);\n'
        'user_pref("network.proxy.ssl", "10.0.0.5");\n'
        'user_pref("network.proxy.ssl_port", 3128);\n'
        'user_pref("network.proxy.no_proxies_on", "localhost,127.0.0.1,.internal");\n'
        'user_pref("network.proxy.socks", "");\n'
        'user_pref("network.proxy.socks_port", 0);\n'
        'user_pref("browser.startup.homepage", "https://example.com");\n'
    )
    pf = core.parse_firefox_prefs(js)
    eq("อ่าน type", pf.get("type"), 1)
    eq("อ่าน http host", pf.get("http_host"), "10.0.0.5")
    eq("อ่าน http port เป็น int", pf.get("http_port"), 3128)
    eq("อ่าน no_proxies", pf.get("no_proxies"), "localhost,127.0.0.1,.internal")
    ok("ไม่เก็บ pref ที่ไม่เกี่ยว", "browser.startup.homepage" not in str(pf))

    st, warns = core.firefox_to_state(pf)
    eq("แปลงเป็น state: host", st.host, "10.0.0.5")
    eq("แปลงเป็น state: port", str(st.port), "3128")
    eq("แปลงเป็น state: ชนิด", st.kind, "http")
    ok("คง no_proxy เดิมของ Firefox", "localhost" in st.no_proxy)
    ok("เติม 127.0.0.1 ให้แม้ Firefox ไม่มี", "127.0.0.1" in st.no_proxy)
    ok("เติม subnet WireGuard ให้", "10.8.0.0/24" in st.no_proxy)
    ok("ไม่เตือนเมื่ออ่านได้ปกติ", warns == [], str(warns))

    # SOCKS ใน Firefox
    js_s = ('user_pref("network.proxy.type", 1);\n'
            'user_pref("network.proxy.socks", "127.0.0.1");\n'
            'user_pref("network.proxy.socks_port", 9050);\n'
            'user_pref("network.proxy.socks_version", 5);\n')
    st_s, _ = core.firefox_to_state(core.parse_firefox_prefs(js_s))
    eq("Firefox SOCKS → socks5", st_s.kind, "socks5")
    eq("Firefox SOCKS port", str(st_s.port), "9050")

    # type=0 / 5 / 2
    st0, w0 = core.firefox_to_state(core.parse_firefox_prefs('user_pref("network.proxy.type", 0);'))
    ok("type=0 เตือนว่าไม่มี proxy", any("ไม่มี proxy" in w for w in w0), str(w0))
    st5, w5 = core.firefox_to_state(core.parse_firefox_prefs('user_pref("network.proxy.type", 5);'))
    ok("type=5 เตือนให้ไปดู system proxy", any("system proxy" in w for w in w5), str(w5))
    st2, w2 = core.firefox_to_state(core.parse_firefox_prefs('user_pref("network.proxy.type", 2);'))
    ok("type=2 (PAC) เตือน", any("PAC" in w for w in w2), str(w2))

    # escape ที่ Firefox เขียนจริง
    js_esc = ('user_pref("network.proxy.type", 1);\n'
              'user_pref("network.proxy.http", "10.0.0.5");\n'
              'user_pref("network.proxy.http_port", 3128);\n'
              'user_pref("network.proxy.no_proxies_on", "localhost\\u002C127.0.0.1");\n')
    pf_esc = core.parse_firefox_prefs(js_esc)
    st_esc, _ = core.firefox_to_state(pf_esc)
    ok("ถอด escape \\u002C ได้ (Firefox เขียนแบบนี้จริง)",
       "127.0.0.1" in st_esc.no_proxy, str(st_esc.no_proxy))
    eq("unescape ตรง ๆ", core._ff_unescape("a\\u002Cb"), "a,b")

    group("9. หาโปรไฟล์ Firefox (รวม snap/flatpak)")
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        eq("ไม่มีอะไรเลย → ว่าง", core.find_firefox_profiles(home), [])
        p1 = home / ".mozilla" / "firefox" / "abc.default"
        p1.mkdir(parents=True)
        (p1 / "prefs.js").write_text("user_pref('x',1);")
        eq("เจอโปรไฟล์ปกติ", [p.relative_to(home) for p in core.find_firefox_profiles(home)],
           [Path(".mozilla/firefox/abc.default")])
        p2 = home / "snap" / "firefox" / "common" / ".mozilla" / "firefox" / "snap.default"
        p2.mkdir(parents=True)
        (p2 / "user.js").write_text("")
        eq("เจอ snap ด้วย", len(core.find_firefox_profiles(home)), 2)
        p3 = home / ".var" / "app" / "org.mozilla.firefox" / ".mozilla" / "firefox" / "flatpak.default"
        p3.mkdir(parents=True)
        (p3 / "prefs.js").write_text("")
        eq("เจอ flatpak ด้วย", len(core.find_firefox_profiles(home)), 3)

    group("10. บันทึก/โหลด state")
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        eq("ยังไม่มีไฟล์ → ค่าเริ่มต้น", core.load_state(home).port, 8080)
        st = core.ProxyState(host="192.168.1.9", port=1081, kind="socks5", enabled=True)
        p = core.save_state(st, home)
        ok("เขียนไฟล์แล้ว", p.exists())
        eq("สิทธิ์ไฟล์ 600", oct(p.stat().st_mode)[-3:], "600")
        back = core.load_state(home)
        eq("โหลด host กลับมา", back.host, "192.168.1.9")
        eq("โหลด enabled กลับมา", back.enabled, True)
        eq("โหลด kind กลับมา", back.kind, "socks5")
        (core.config_path(home)).write_text("{ ไม่ใช่ json")
        eq("ไฟล์เสีย → ค่าเริ่มต้น (ไม่ crash)", core.load_state(home).host, "127.0.0.1")
        (core.config_path(home)).write_text('{"host":"1.1.1.1","port":9,"มั่ว":"x"}')
        eq("คีย์ที่ไม่รู้จักถูกทิ้ง", core.load_state(home).host, "1.1.1.1")

    group("11. apply / clear (ดักคำสั่งทั้งหมด)")
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        sysc = FakeSystem().install()
        st = core.ProxyState(host="127.0.0.1", port=8080, apply_gnome=True,
                             apply_xfce=True, apply_apt=False)
        try:
            res = core.apply_state(st, home)
        except Exception as e:  # noqa: BLE001 — ต้องรายงานเป็น fail ไม่ใช่ traceback
            ok("apply_state ไม่โยน exception", False, f"{type(e).__name__}: {e}")
            res = []
        else:
            ok("apply_state ไม่โยน exception", True)
        ok("apply ไม่มีขั้นที่ fail", all(r.ok for r in res), str([(r.label, r.detail) for r in res if not r.ok]))
        gs = sysc.gset_calls()
        ok("สั่ง gsettings set จริง", len(gs) >= 6, f"{len(gs)} คำสั่ง")
        ok("คำสั่งแรกคือ mode=manual", "manual" in gs[0], str(gs[0]))
        ok("สร้าง env.sh", core.env_sh_path(home).exists())
        ok("env.sh มี export http_proxy", "export http_proxy" in core.env_sh_path(home).read_text())
        ok("เขียน rc ให้ source", core.RC_MARK_BEGIN in (home / ".profile").read_text())
        ok("state ถูกบันทึกเป็น enabled", core.load_state(home).enabled)
        ok("บันทึก snapshot ค่าเดิม", core.snapshot_path(home).exists())

        # apply ซ้ำ: snapshot ต้องไม่ถูกทับ
        snap_before = core.snapshot_path(home).read_text()
        sysc.gsettings_db["org.gnome.system.proxy mode"] = "'manual'"
        core.apply_state(st, home)
        eq("apply ซ้ำไม่ทับ snapshot", core.snapshot_path(home).read_text(), snap_before)

        sysc.calls.clear()
        try:
            res = core.clear_state(st, home)
        except Exception as e:  # noqa: BLE001
            ok("clear_state ไม่โยน exception", False, f"{type(e).__name__}: {e}")
            res = []
        else:
            ok("clear_state ไม่โยน exception", True)
        ok("clear ไม่มีขั้น fail", all(r.ok for r in res))
        off = [c for c in sysc.calls if c[:2] == ["gsettings", "set"] and "mode" in c and "none" in c]
        ok("clear สั่ง mode=none", len(off) >= 1, str(sysc.calls[:3]))
        ok("clear เขียน env.sh เป็น unset", "unset http_proxy" in core.env_sh_path(home).read_text())
        ok("state เป็น disabled", not core.load_state(home).enabled)

        # apply ที่มีค่าผิด → ไม่รันคำสั่งเลย
        sysc.calls.clear()
        bad = core.apply_state(core.ProxyState(host="", port=8080), home)
        ok("ค่าผิด → คืน fail ทันที", bad and not bad[0].ok)
        eq("ค่าผิด → ไม่มีคำสั่งภายนอกเลย", len(sysc.calls), 0)

        # gsettings พัง → รายงาน fail แต่ไม่ throw
        sysc.fail_on = {"gsettings"}
        sysc.calls.clear()
        try:
            res = core.apply_state(core.ProxyState(host="127.0.0.1", port=8080, apply_gnome=True,
                                                   apply_xfce=False), home)
        except Exception as e:  # noqa: BLE001
            ok("gsettings พัง → ไม่โยน exception", False, f"{type(e).__name__}: {e}")
            res = []
        ok("gsettings พัง → รายงาน fail (ไม่ crash)", any(not r.ok for r in res), str(res))
        ok("env.sh ยังถูกเขียนแม้ gsettings พัง", core.env_sh_path(home).exists())

        # non-root ไม่แตะ apt
        sysc.fail_on = set()
        if os.geteuid() != 0:
            res = core.apply_state(core.ProxyState(host="1.1.1.1", port=8080,
                                                   apply_gnome=False, apply_xfce=False,
                                                   apply_apt=True), home)
            ok("ไม่ใช่ root → ข้าม apt พร้อมบอกเหตุผล",
               any(r.label == "apt/sudo" and not r.ok and "root" in r.detail for r in res),
               str([(r.label, r.ok) for r in res]))

    group("11b. คำสั่งทุกคำสั่งต้องเป็น str ล้วน (บั๊ก subprocess ที่เคยหลุด)")

    def assert_all_str(cmds, label):
        bad = [c for c in cmds for a in c if not isinstance(a, str)]
        ok(f"{label}: ทุกอาร์กิวเมนต์เป็น str", not bad, f"พบ non-str: {bad[:2]}")

    assert_all_str(core.build_gsettings_set(core.ProxyState(host="1.1.1.1", port=8080)), "gsettings (http)")
    assert_all_str(core.build_gsettings_set(core.ProxyState(host="1.1.1.1", port=1080, kind="socks5")), "gsettings (socks5)")
    assert_all_str(core.build_gsettings_off(), "gsettings off")
    assert_all_str(core.build_gsettings_restore({"org.gnome.system.proxy mode": "'auto'"}), "gsettings restore")
    assert_all_str(core.build_xfconf_set(core.ProxyState(host="1.1.1.1", port=8080)), "xfconf")
    assert_all_str(core.build_xfconf_off(), "xfconf off")

    # ยิงจริงผ่าน run() ที่เข้ม — ต้องไม่ TypeError
    with tempfile.TemporaryDirectory() as td:
        sysc = FakeSystem().install()
        try:
            core.apply_state(core.ProxyState(host="1.1.1.1", port=8080), Path(td))
            ok("apply_state รันจริงได้โดยไม่ TypeError", True)
        except TypeError as e:
            ok("apply_state รันจริงได้โดยไม่ TypeError", False, str(e))
        try:
            core.clear_state(core.ProxyState(host="1.1.1.1", port=8080), Path(td))
            ok("clear_state รันจริงได้โดยไม่ TypeError", True)
        except TypeError as e:
            ok("clear_state รันจริงได้โดยไม่ TypeError", False, str(e))

    group("12. dry-run ต้องไม่แตะดิสก์")
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        sysc = FakeSystem().install()
        res = core.apply_state(core.ProxyState(host="127.0.0.1", port=8080), home, dry_run=True)
        eq("dry-run ไม่เขียน config", core.config_path(home).exists(), False)
        eq("dry-run ไม่เขียน env.sh", core.env_sh_path(home).exists(), False)
        eq("dry-run ไม่เขียน rc", (home / ".profile").exists(), False)
        ok("dry-run คืนผลว่าผ่าน", all(r.ok for r in res), str(res))
        eq("dry-run ไม่ยิงคำสั่งภายนอก", len(sysc.calls), 0)


# ───────────────────────────────── B) GUI ──
def make_app(**state_kw):
    """สร้างแอปบน stub + ตั้งค่า state เริ่มต้น"""
    root = tk.Tk()
    app = gui.ArenaProxyApp(root, home=Path(tempfile.mkdtemp(prefix="arena-gui-")))
    for k, v in state_kw.items():
        setattr(app.state, k, v)
    return root, app


def wait_for(root, app, needles, timeout: float = 5.0) -> bool:
    """รอให้ thread เบื้องหลังเขียน log แล้ว flush คิว after() ของ stub"""
    import time
    if isinstance(needles, str):
        needles = (needles,)
    end = time.time() + timeout
    while time.time() < end:
        root.flush_after()
        if any(n in app.log_txt.content for n in needles):
            return True
        time.sleep(0.01)
    root.flush_after()
    return any(n in app.log_txt.content for n in needles)


def wait_enabled(root, app, want: bool, timeout: float = 5.0) -> bool:
    import time
    end = time.time() + timeout
    while time.time() < end:
        root.flush_after()
        if bool(core.load_state(app.home).enabled) == want:
            return True
        time.sleep(0.01)
    return bool(core.load_state(app.home).enabled) == want


def widgets_text(root) -> str:
    """รวมข้อความของทุก widget ในต้นไม้ (ไว้ตรวจว่ามี label ปุ่มครบ)"""
    out = []

    def walk(w):
        for c in getattr(w, "children", []):
            try:
                out.append(str(c.cget("text")))
            except Exception:  # noqa: BLE001
                pass
            walk(c)

    walk(root)
    return " | ".join(out)


def test_gui():
    group("13. GUI — โครงหน้าจอ")

    root = tk.Tk()
    app = gui.ArenaProxyApp(root, home=Path(tempfile.mkdtemp(prefix="arena-gui-")))
    txt = widgets_text(root)
    ok("มีช่อง IP", hasattr(app, "ip_entry"))
    ok("มีช่อง Port", hasattr(app, "port_entry"))
    ok("มีปุ่ม Apply", "Apply" in str(app.apply_btn.cget("text")))
    ok("มีปุ่ม Sync from Firefox", "Sync from Firefox" in str(app.sync_btn.cget("text")))
    ok("มีสวิตช์ ON/OFF", app.toggle.cget("text") in ("ON", "OFF"))
    ok("มีปุ่ม OFF", "OFF" in str(app.off_btn.cget("text")))
    ok("มีปุ่มทดสอบ", "ทดสอบ" in str(app.test_btn.cget("text")))
    ok("มี checkbox GNOME", hasattr(app, "chk_gnome"))
    ok("มี checkbox XFCE (จำเป็นสำหรับ Kali)", hasattr(app, "chk_xfce"))
    ok("มี checkbox apt", hasattr(app, "chk_apt"))
    ok("มีช่องบันทึก (log)", hasattr(app, "log_txt"))
    eq("ค่า IP เริ่มต้นเข้า widget จริง", app.ip_entry.get(), app.state.host)
    eq("ค่า Port เริ่มต้นเข้า widget จริง", str(app.port_entry.get()), str(app.state.port))

    group("14. GUI — ปุ่ม Sync from Firefox")

    # ไม่มีโปรไฟล์ → ต้องบอกให้ชัด ไม่ใช่เงียบ
    app.log_txt.delete("0", "end")
    app.on_sync(); root.flush_after()
    ok("ไม่มีโปรไฟล์ → ขึ้นข้อความบอกเหตุ", "ไม่พบโปรไฟล์ Firefox" in app.log_txt.content,
       app.log_txt.content[:200])

    # มีโปรไฟล์จริง → เติมช่อง IP/Port
    prof = Path(app.home) / ".mozilla" / "firefox" / "test.default"
    prof.mkdir(parents=True)
    (prof / "prefs.js").write_text(
        'user_pref("network.proxy.type", 1);\n'
        'user_pref("network.proxy.http", "192.168.44.7");\n'
        'user_pref("network.proxy.http_port", 8888);\n'
        'user_pref("network.proxy.no_proxies_on", "localhost,127.0.0.1,.corp");\n'
    )
    app.log_txt.delete("0", "end")
    app.on_sync(); root.flush_after()
    eq("Sync เติม IP จาก Firefox", app.ip_var.get(), "192.168.44.7")
    eq("Sync เติม Port จาก Firefox", app.port_var.get(), "8888")
    eq("Sync เติมชนิด", app.kind_var.get(), "http")
    ok("Sync บอกว่าต้องกด Apply ต่อ", "กด Apply" in app.log_txt.content, app.log_txt.content[-200:])
    eq("Sync ไม่ได้เปิด proxy ให้เอง", core.load_state(app.home).enabled, False)

    # Firefox ตั้ง SOCKS → ต้องได้ socks5
    (prof / "prefs.js").write_text(
        'user_pref("network.proxy.type", 1);\n'
        'user_pref("network.proxy.socks", "127.0.0.1");\n'
        'user_pref("network.proxy.socks_port", 9050);\n'
        'user_pref("network.proxy.socks_version", 5);\n'
    )
    app.on_sync(); root.flush_after()
    eq("Sync SOCKS → ชนิด socks5", app.kind_var.get(), "socks5")
    eq("Sync SOCKS → port 9050", app.port_var.get(), "9050")

    # Firefox ปิด proxy → ต้องเตือน ไม่ใช่ effacer ค่าเดิม
    (prof / "prefs.js").write_text('user_pref("network.proxy.type", 0);\n')
    app.ip_var.set("9.9.9.9")
    app.log_txt.delete("0", "end")
    app.on_sync(); root.flush_after()
    ok("type=0 → เตือน 'ไม่มี proxy'", "ไม่มี proxy" in app.log_txt.content, app.log_txt.content[:300])
    eq("type=0 → ไม่ล้างค่าที่พิมพ์ไว้", app.ip_var.get(), "9.9.9.9")

    group("15. GUI — ปุ่ม Apply (ดักคำสั่ง)")

    root2, app2 = make_app()
    sysc = FakeSystem().install()
    app2.ip_var.set("10.20.30.40")
    app2.port_var.set("3128")
    app2.gnome_var.set(True)
    app2.xfce_var.set(True)
    app2.apt_var.set(False)
    app2.log_txt.delete("0", "end")
    app2.on_apply()
    wait_for(root2, app2, "Apply เสร็จ")
    gs = [" ".join(map(str, c)) for c in sysc.gset_calls()]
    ok("Apply สั่ง gsettings mode manual", any("mode manual" in g for g in gs), str(gs[:2]))
    ok("Apply ตั้ง http host ตามที่พิมพ์", any("system.proxy.http host 10.20.30.40" in g for g in gs), str(gs))
    ok("Apply ตั้ง port 3128", any("http port 3128" in g for g in gs))
    ok("Apply เรียก xfconf ด้วย (Kali = XFCE)", any(c[0] == "xfconf-query" for c in sysc.calls))
    ok("Apply เขียน env.sh", core.env_sh_path(app2.home).exists())
    ok("Apply log ว่าเสร็จ", "Apply เสร็จ" in app2.log_txt.content, app2.log_txt.content[-300:])
    ok("Apply บันทึกสถานะ enabled", core.load_state(app2.home).enabled)
    ok("สวิตช์เปลี่ยนเป็น ON", app2.toggle.cget("text") == "ON", app2.toggle.cget("text"))

    group("16. GUI — ค่าผิดต้องไม่ยิงคำสั่ง")
    root3, app3 = make_app()
    sysc3 = FakeSystem().install()
    messagebox.calls.clear()
    app3.ip_var.set("")
    app3.port_var.set("8080")
    app3.on_apply(); root3.flush_after()
    eq("IP ว่าง → ไม่มีคำสั่งภายนอก", len(sysc3.calls), 0)
    ok("IP ว่าง → เด้งกล่อง error", any(c[0] == "error" for c in messagebox.calls), str(messagebox.calls))
    ok("IP ว่าง → log บอกเหตุ", "ต้องใส่ IP" in app3.log_txt.content, app3.log_txt.content[:200])

    root4, app4 = make_app()
    sysc4 = FakeSystem().install()
    app4.ip_var.set("1.2.3.4")
    app4.port_var.set("99999")
    app4.on_apply()
    eq("port 99999 → ไม่มีคำสั่งภายนอก", len(sysc4.calls), 0)

    group("17. GUI — ปุ่ม OFF / สวิตช์ ON-OFF")

    root5, app5 = make_app()
    sysc5 = FakeSystem().install()
    app5.ip_var.set("10.0.0.9")
    app5.port_var.set("8080")
    app5.gnome_var.set(True)
    app5.xfce_var.set(True)
    app5.on_apply()
    wait_enabled(root5, app5, True)
    ok("เปิดแล้ว state = enabled", core.load_state(app5.home).enabled)
    app5.log_txt.delete("0", "end")
    sysc5.calls.clear()
    app5.on_off()
    wait_enabled(root5, app5, False)
    ok("OFF → state = disabled", not core.load_state(app5.home).enabled)
    ok("OFF สั่ง gsettings mode=none",
       any(c[:2] == ["gsettings", "set"] and "none" in c for c in sysc5.calls), str(sysc5.calls[:3]))
    ok("OFF log ว่าคืนค่าเดิม", "คืนค่าเดิม" in app5.log_txt.content, app5.log_txt.content[-200:])
    ok("สวิตช์กลับเป็น OFF", app5.toggle.cget("text") == "OFF")

    # กดสวิตช์ = toggle ตามสถานะจริง
    root6, app6 = make_app()
    sysc6 = FakeSystem().install()
    app6.ip_var.set("10.0.0.10")
    app6.port_var.set("8080")
    app6.gnome_var.set(False)
    app6.xfce_var.set(False)
    ok("ตอนแรกสวิตช์ OFF", app6.toggle.cget("text") == "OFF")
    app6.toggle.invoke()
    wait_enabled(root6, app6, True)
    ok("กดสวิตช์ → เปิด", core.load_state(app6.home).enabled)

    group("18. GUI — ปุ่มทดสอบ")
    root7, app7 = make_app()
    sysc7 = FakeSystem().install()
    app7.ip_var.set("127.0.0.1")
    app7.port_var.set("9")          # ไม่มีอะไรฟัง → ต้องรายงานว่าเชื่อมไม่ได้
    app7.on_test()
    wait_for(root7, app7, ("เชื่อมต่อไม่ได้", "เชื่อมต่อ TCP"))
    ok("ทดสอบพอร์ตปิด → บอกว่าเชื่อมต่อไม่ได้",
       "เชื่อมต่อไม่ได้" in app7.log_txt.content, app7.log_txt.content[:300])

    group("19. GUI — ต้องไม่ตายเมื่อระบบภายนอกพัง")
    root8, app8 = make_app()
    sysc8 = FakeSystem().install()
    sysc8.fail_on = {"gsettings", "xfconf-query"}
    app8.ip_var.set("10.1.1.1")
    app8.port_var.set("8080")
    app8.on_apply()
    wait_for(root8, app8, ("Apply เสร็จ", "ล้มเหลว"))
    ok("ทั้ง gsettings/xfconf พัง → GUI ยังอยู่และรายงาน", "Apply เสร็จ" in app8.log_txt.content
       or "ล้มเหลว" in app8.log_txt.content, app8.log_txt.content[-300:])
    ok("ยังกดปุ่มต่อได้", str(app8.apply_btn.cget("state")) != "disabled")

    group("20. CLI entry point")
    eq("--selftest ผ่าน", gui.main(["--selftest"]), 0)
    eq("ไม่มี DISPLAY → exit 2", _no_display_run(), 2)


def test_font_fallback() -> None:
    """ตรวจ logic เลือกฟอนต์/วัดความกว้างของ render_preview (ไม่ต้องมีฟอนต์ไทยจริง)"""
    group("20b. ภาพตัวอย่าง — font fallback ระดับตัวอักษร")
    import importlib.util
    rp_path = HERE / "render_preview.py"
    src = rp_path.read_text(encoding="utf-8")

    ok("มี draw_mixed (fallback ต่อตัวอักษร)", "def draw_mixed(" in src)
    ok("มี measure() วัดความกว้างแบบผสมฟอนต์", "def measure(" in src)
    ok("ตรวจ glyph จริงด้วย cmap (ไม่ใช่แค่เดา)",
       "_font_has" in src and "getBestCmap" in src)
    ok("ฟอนต์สัญลักษณ์เป็น DejaVu (ไม่ใช่ฟอนต์ไทย)",
       "DejaVuSans-Bold.ttf" in src or "DejaVuSans.ttf" in src)
    ok("รองรับ THAI_FONT_DIR (ชี้ repo ฟอนต์ได้)", "THAI_FONT_DIR" in src)
    ok("โคลน sirisakboy/thai-font อัตโนมัติถ้าไม่มี",
       "sirisakboy/thai-font" in src)
    ok("มี fallback ภาษาอังกฤษเมื่อไม่มีฟอนต์ไทย", 'TH = thai_available()' in src)
    ok("แคชฟอนต์ (ไม่สร้างซ้ำทุกบรรทัด)", "_FCACHE" in src)

    # ทดสอบ logic จริงด้วยฟอนต์ที่มีอยู่ในเครื่อง (DejaVu)
    try:
        from PIL import Image, ImageDraw, ImageFont  # noqa: F401
    except ImportError:
        skip("เรนเดอร์ภาพจริง (ต้องมี pillow: pip install pillow)")
        return
    spec = importlib.util.spec_from_file_location("rp_test", rp_path)
    rp = importlib.util.module_from_spec(spec)
    import contextlib
    import io
    with contextlib.redirect_stderr(io.StringIO()):
        spec.loader.exec_module(rp)
    img = Image.new("RGB", (10, 10))
    d = ImageDraw.Draw(img)
    calls = []
    real_text = d.text

    def spy(xy, text, **kw):
        calls.append((text, str(getattr(kw.get("font"), "path", "?"))))
        return real_text(xy, text, **kw)

    d.text = spy
    with contextlib.redirect_stderr(io.StringIO()):
        rp.draw_mixed(d, (0, 0), "▸ Apply ✔", rp.font(13), fill=(255, 255, 255))
    ok("draw_mixed วาดได้โดยไม่ crash", True)
    with contextlib.redirect_stderr(io.StringIO()):
        w = rp.measure(d, "▸ Apply ไทย ✔", rp.font(13))
    ok("measure() คืนความกว้าง > 0", w > 0, str(w))


def _no_display_run() -> int:
    old = {k: os.environ.pop(k, None) for k in ("DISPLAY", "WAYLAND_DISPLAY")}
    try:
        return gui.main([])
    finally:
        for k, v in old.items():
            if v is not None:
                os.environ[k] = v


def stress_escape() -> None:
    """ค่าแปลก ๆ ต้องไม่ทำให้ GUI พัง"""
    group("21. ค่าแปลก (injection / unicode / ยาว)")
    for val in ["1.2.3.4", "::1", "โฮสต์.ไทย", "a" * 200, "10.0.0.1 # comment", "'; rm -rf / #",
                "$(whoami)", "`id`", "10.0.0.1\n10.0.0.2"]:
        st = core.ProxyState(host=val, port=8080)
        errs = st.validate()
        # ต้อง "ตัดสินใจได้" ไม่ใช่ crash — และต้องไม่ปล่อยผ่านอักขระอันตราย
        if any(ch in val for ch in "';$\"`\\#") or "\n" in val:
            ok(f"ปฏิเสธค่าอันตราย {val[:20]!r}", errs != [], f"errs={errs}")
        else:
            ok(f"รับค่าปกติ {val[:20]!r} ได้", isinstance(errs, list))

    # ตรวจว่าไม่มีการต่อสตริงคำสั่งแบบ shell ตรง ๆ
    src = (PKG / "arena_proxy_core.py").read_text(encoding="utf-8")
    ok("ไม่ใช้ shell=True", "shell=True" not in src, "พบ shell=True")
    ok("ไม่ใช้ os.system", "os.system" not in src)
    ok("คำสั่งทั้งหมดเป็น list (ไม่ใช่สตริง)", "subprocess.run(\n            list(cmd)" in src.replace("  ", "  ") or "list(cmd)" in src)

    # shquote ต้องกันช่องว่างได้
    eq("shquote ใส่ quote เดี่ยว", core.shquote("a b"), "'a b'")
    eq("shquote หนี quote ของตัวเอง", core.shquote("a'b"), "'a'\\''b'")

    # YAML/env snippet ต้องปลอดภัยพออ่านกลับ
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        st = core.ProxyState(host="10.0.0.1", port=8080, enabled=True,
                             no_proxy=["localhost", "โดเมน.ไทย"])
        core.env_sh_path(home).parent.mkdir(parents=True, exist_ok=True)
        core.env_sh_path(home).write_text(core.build_env_snippet(st))
        import subprocess
        r = subprocess.run(["bash", "-c",
                            f'. {core.env_sh_path(home)} && printf "%s" "$no_proxy"'],
                           capture_output=True, text=True)
        eq("env.sh ถูก source ได้จริงโดย bash", r.returncode, 0, r.stderr)
        ok("ค่า unicode อยู่ครบหลัง source", "โดเมน.ไทย" in r.stdout, r.stdout)


# ───────────────────────────────── main ──
def main() -> int:
    print(f"\033[1m══ Arena Proxy GUI — เทสต์ ══\033[0m  (tkinter: {'stub' if getattr(tk, '__arena_stub__', False) else 'จริง'})")
    try:
        test_core()
        test_gui()
        stress_escape()
        test_font_fallback()
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        print("\n\033[31mเทสต์หยุดกลางทาง (exception)\033[0m")
        print(f"RESULT pass={PASS} fail={FAIL + 1} skip={SKIP}")
        return 1

    print("\n" + "─" * 46)
    color = "\033[32m" if FAIL == 0 else "\033[31m"
    print(f"  ผ่าน {color}{PASS}\033[0m   ไม่ผ่าน \033[31m{FAIL}\033[0m")
    print(f"RESULT pass={PASS} fail={FAIL} skip={SKIP}")   # บรรทัดเครื่องจักรอ่าน (ไม่มีสี)
    if FAILS:
        print("\nรายการที่ไม่ผ่าน:")
        for f in FAILS:
            print("  •", f)
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
