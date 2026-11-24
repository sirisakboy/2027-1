#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Arena Proxy — core logic (ไม่ผูกกับ GUI)

แยกส่วนที่ "ตัดสินใจ/สร้างคำสั่ง" ออกจากส่วน "วาดหน้าจอ" เพื่อให้เทสต์ได้จริง
บนเครื่องที่ไม่มีจอ (CI) — ทุกคำสั่งภายนอกวิ่งผ่าน run() จุดเดียว
ซึ่ง monkeypatch ได้ในเทสต์

รองรับ 2 เป้าหมายที่ Kali Linux ใช้จริง:
  • GNOME  → gsettings org.gnome.system.proxy (ตามที่ผู้ใช้ขอ)
  • XFCE   → xfconf-query (ค่าเริ่มต้นของ Kali)
  • shell  → http_proxy/https_proxy/all_proxy/no_proxy + apt/sudo
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Iterable, Sequence

APP = "arena-proxy"
VERSION = "1.0.0"

# ค่า no_proxy ที่ปลอดภัยและจำเป็นเสมอ (ห้ามตัด localhost ออก ไม่งั้น portal/VPN พัง)
DEFAULT_NO_PROXY = [
    "localhost",
    "127.0.0.1",
    "::1",
    "*.local",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10",   # CGNAT — กัน proxy loop กับเน็ตบ้าน
    "10.8.0.0/24",     # WireGuard ของ Arena VPN
    "10.9.0.0/24",     # OpenVPN ของ Arena VPN
]

RC_MARK_BEGIN = "# >>> arena-proxy >>>"
RC_MARK_END = "# <<< arena-proxy <<<"


# ─────────────────────────────────────────────────────────── paths ──
def config_dir(home: Path | None = None) -> Path:
    """ไดเรกทอรี config

    กฎ: ถ้าผู้เรียกระบุ home เอง (เช่นเทสต์) ต้องใช้ค่านั้นเสมอ
    ห้ามให้ XDG_CONFIG_HOME ของ environment มาทับ — ไม่งั้นเทสต์ที่แยก home
    จะไปเขียนทับ config จริงของผู้ใช้/ของ run อื่น (เจอบน CI)
    """
    if home is not None:
        return Path(home) / ".config" / APP
    home = Path.home()
    return Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / APP


def state_dir(home: Path | None = None) -> Path:
    if home is not None:
        return Path(home) / ".cache" / APP
    home = Path.home()
    return Path(os.environ.get("XDG_CACHE_HOME") or home / ".cache") / APP


def config_path(home: Path | None = None) -> Path:
    return config_dir(home) / "config.json"


def snapshot_path(home: Path | None = None) -> Path:
    return state_dir(home) / "original.json"


def env_sh_path(home: Path | None = None) -> Path:
    return config_dir(home) / "env.sh"


# ─────────────────────────────────────────────────────────── model ──
@dataclass
class ProxyState:
    host: str = "127.0.0.1"
    port: int = 8080
    kind: str = "http"                 # http | socks5
    no_proxy: list[str] = field(default_factory=lambda: list(DEFAULT_NO_PROXY))
    enabled: bool = False
    apply_gnome: bool = True
    apply_xfce: bool = True
    apply_apt: bool = False

    def url(self) -> str:
        scheme = "socks5h" if self.kind == "socks5" else "http"
        return f"{scheme}://{self.host}:{self.port}"

    def validate(self) -> list[str]:
        errs: list[str] = []
        if not self.host or not self.host.strip():
            errs.append("ต้องใส่ IP หรือชื่อเครื่อง")
        elif not re.fullmatch(r"[A-Za-z0-9._\-\[\]:]+", self.host.strip()):
            errs.append("IP/ชื่อเครื่องมีอักขระที่ไม่ควรมี")
        try:
            p = int(self.port)
        except (TypeError, ValueError):
            errs.append("Port ต้องเป็นตัวเลข")
        else:
            if not 1 <= p <= 65535:
                errs.append("Port ต้องอยู่between 1–65535")
        if self.kind not in ("http", "socks5"):
            errs.append("ชนิด proxy ต้องเป็น http หรือ socks5")
        return errs


# ─────────────────────────────────────────────────────── runner ──
def run(cmd: Sequence[str], *, timeout: int = 10, check: bool = False) -> subprocess.CompletedProcess:
    """จุดเดียวที่เรียกคำสั่งภายนอก — เทสต์ monkeypatch ตัวนี้ได้"""
    try:
        return subprocess.run(
            [str(c) for c in cmd], capture_output=True, text=True,
            timeout=timeout, check=check,
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(list(cmd), 127, "", "ไม่พบคำสั่ง")
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(list(cmd), 124, "", "timeout")


def have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


# ─────────────────────────────────────────── gsettings (GNOME) ──
GS_ROOT = "org.gnome.system.proxy"
GS_HTTP = f"{GS_ROOT}.http"
GS_HTTPS = f"{GS_ROOT}.https"
GS_SOCKS = f"{GS_ROOT}.socks"


def _gv_list(items: Iterable[str]) -> str:
    """สร้าง GVariant ของ string array: ['a', 'b']"""
    inner = ", ".join("'" + str(i).replace("'", "") + "'" for i in items if str(i).strip())
    return f"[{inner}]"


def build_gsettings_set(state: ProxyState) -> list[list[str]]:
    """คำสั่ง gsettings ทั้งหมดสำหรับ 'เปิด' proxy (ทั้งเครื่อง)"""
    host, port = state.host.strip(), str(int(state.port))
    cmds: list[list[str]] = [
        ["gsettings", "set", GS_ROOT, "mode", "manual"],
        ["gsettings", "set", GS_HTTP, "host", host],
        ["gsettings", "set", GS_HTTP, "port", str(int(port))],
        ["gsettings", "set", GS_HTTPS, "host", host],
        ["gsettings", "set", GS_HTTPS, "port", str(int(port))],
        ["gsettings", "set", GS_ROOT, "ignore-hosts", _gv_list(state.no_proxy)],
    ]
    if state.kind == "socks5":
        cmds += [
            ["gsettings", "set", GS_ROOT, "use-same-proxy", "true"],
            ["gsettings", "set", GS_SOCKS, "host", host],
            ["gsettings", "set", GS_SOCKS, "port", str(int(port))],
        ]
    else:
        cmds += [
            ["gsettings", "set", GS_ROOT, "use-same-proxy", "true"],
            ["gsettings", "set", GS_SOCKS, "host", ""],
            ["gsettings", "set", GS_SOCKS, "port", "0"],
        ]
    return cmds


def build_gsettings_off() -> list[list[str]]:
    return [["gsettings", "set", GS_ROOT, "mode", "none"]]


GS_KEYS = [
    (GS_ROOT, "mode"),
    (GS_ROOT, "ignore-hosts"),
    (GS_ROOT, "use-same-proxy"),
    (GS_HTTP, "host"),
    (GS_HTTP, "port"),
    (GS_HTTPS, "host"),
    (GS_HTTPS, "port"),
    (GS_SOCKS, "host"),
    (GS_SOCKS, "port"),
]


def read_gsettings_snapshot() -> dict[str, str]:
    """อ่านค่าปัจจุบันไว้คืนค่าเมื่อกด OFF"""
    snap: dict[str, str] = {}
    if not have("gsettings"):
        return snap
    for schema, key in GS_KEYS:
        r = run(["gsettings", "get", schema, key])
        if r.returncode == 0:
            snap[f"{schema} {key}"] = r.stdout.strip()
    return snap


def build_gsettings_restore(snapshot: dict[str, str]) -> list[list[str]]:
    """คำสั่งคืนค่าเดิมจาก snapshot (value ดิบของ gsettings ใช้ได้ตรง ๆ)"""
    out: list[list[str]] = []
    for k, v in snapshot.items():
        if not v:
            continue
        schema, _, key = k.partition(" ")
        if schema and key:
            out.append(["gsettings", "set", schema, key, v])
    return out


# ───────────────────────────────────────────── xfconf (XFCE/Kali) ──
XFC_PROXY = "/system/proxy"


def build_xfconf_set(state: ProxyState) -> list[list[str]]:
    host, port = state.host.strip(), str(int(state.port))
    cmds = [
        ["xfconf-query", "-c", "xfce4-session", "-p", f"{XFC_PROXY}/mode", "-n", "-t", "string", "-s", "manual"],
        ["xfconf-query", "-c", "xfce4-session", "-p", f"{XFC_PROXY}/http/host", "-n", "-t", "string", "-s", host],
        ["xfconf-query", "-c", "xfce4-session", "-p", f"{XFC_PROXY}/http/port", "-n", "-t", "int", "-s", port],
        ["xfconf-query", "-c", "xfce4-session", "-p", f"{XFC_PROXY}/https/host", "-n", "-t", "string", "-s", host],
        ["xfconf-query", "-c", "xfce4-session", "-p", f"{XFC_PROXY}/https/port", "-n", "-t", "int", "-s", port],
        ["xfconf-query", "-c", "xfce4-session", "-p", f"{XFC_PROXY}/use_same_proxy", "-n", "-t", "bool", "-s", "true"],
    ]
    if state.kind == "socks5":
        cmds += [
            ["xfconf-query", "-c", "xfce4-session", "-p", f"{XFC_PROXY}/socks/host", "-n", "-t", "string", "-s", host],
            ["xfconf-query", "-c", "xfce4-session", "-p", f"{XFC_PROXY}/socks/port", "-n", "-t", "int", "-s", port],
        ]
    return cmds


def build_xfconf_off() -> list[list[str]]:
    return [
        ["xfconf-query", "-c", "xfce4-session", "-p", f"{XFC_PROXY}/mode", "-n", "-t", "string", "-s", "none"],
    ]


# ──────────────────────────────────────────── environment / shell ──
def build_env_vars(state: ProxyState) -> dict[str, str]:
    """ตัวแปรที่ต้อง export — ทั้งตัวพิมพ์เล็กและใหญ่ (บางโปรแกรมอ่านตัวเล็กเท่านั้น)"""
    url = state.url()
    no_proxy = ",".join(state.no_proxy)
    env = {
        "http_proxy": url,
        "https_proxy": url,
        "HTTP_PROXY": url,
        "HTTPS_PROXY": url,
        "no_proxy": no_proxy,
        "NO_PROXY": no_proxy,
    }
    if state.kind == "socks5":
        env.update({
            "all_proxy": url, "ALL_PROXY": url,
            "ftp_proxy": url, "FTP_PROXY": url,
        })
    return env


def build_env_snippet(state: ProxyState) -> str:
    """เนื้อหา env.sh — เปิด = export, ปิด = unset (ไฟล์เดิมใช้ได้ทั้งสองทาง)"""
    lines = [
        f"# {APP} {VERSION} — สร้างอัตโนมัติ ห้ามแก้มือ (กด Apply ใน GUI แทน)",
        "# ไฟล์นี้ถูก source จาก ~/.zshrc / ~/.bashrc / ~/.profile",
    ]
    keys = [
        "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
        "no_proxy", "NO_PROXY",
        "all_proxy", "ALL_PROXY", "ftp_proxy", "FTP_PROXY",
    ]
    if state.enabled:
        vals = build_env_vars(state)
        for k in keys:
            if k in vals:
                lines.append(f"export {k}={shquote(vals[k])}")
            else:
                lines.append(f"unset {k} 2>/dev/null || true")
    else:
        for k in keys:
            lines.append(f"unset {k} 2>/dev/null || true")
    return "\n".join(lines) + "\n"


def shquote(s: str) -> str:
    return "'" + str(s).replace("'", "'\\''") + "'"


def build_rc_block() -> str:
    return (
        f"{RC_MARK_BEGIN}\n"
        f'[ -f "$HOME/.config/arena-proxy/env.sh" ] && . "$HOME/.config/arena-proxy/env.sh"\n'
        f"{RC_MARK_END}\n"
    )


def rc_targets(home: Path | None = None) -> list[Path]:
    home = Path(home or Path.home())
    out = []
    for name in (".zshrc", ".bashrc", ".profile"):
        p = home / name
        out.append(p)
    return out


def install_rc_block(home: Path | None = None) -> list[Path]:
    """ใส่บล็อก guarded ลง rc (idempotent) — คืนรายชื่อไฟล์ที่แก้"""
    changed: list[Path] = []
    block = build_rc_block()
    for p in rc_targets(home):
        # สร้าง .zshrc/.bashrc ถ้ายังไม่มี? ไม่ — แตะเฉพาะไฟล์ที่มีอยู่ หรือ .profile
        if not p.exists() and p.name != ".profile":
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""
        except OSError:
            continue
        if RC_MARK_BEGIN in text:
            continue
        new = (text.rstrip("\n") + "\n\n" if text.strip() else "") + block
        p.write_text(new, encoding="utf-8")
        changed.append(p)
    return changed


def remove_rc_block(home: Path | None = None) -> list[Path]:
    changed: list[Path] = []
    for p in rc_targets(home):
        if not p.exists():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if RC_MARK_BEGIN not in text:
            continue
        new = re.sub(
            re.escape(RC_MARK_BEGIN) + r".*?" + re.escape(RC_MARK_END) + r"\n?",
            "", text, flags=re.S,
        )
        p.write_text(new, encoding="utf-8")
        changed.append(p)
    return changed


# ─────────────────────────────────────────── apt / sudo (ต้อง root) ──
APT_FILE = "/etc/apt/apt.conf.d/95arena-proxy"


def build_apt_conf(state: ProxyState) -> str:
    url = state.url()
    return (
        f"// {APP} — สร้างอัตโนมัติ\n"
        f'Acquire::http::Proxy "{url}";\n'
        f'Acquire::https::Proxy "{url}";\n'
        f'Acquire::ftp::Proxy "{url}";\n'
    )


# ───────────────────────────────────── Firefox pref sync ──
FF_PROXY_KEYS = {
    "network.proxy.type": ("type", str),
    "network.proxy.http": ("http_host", str),
    "network.proxy.http_port": ("http_port", int),
    "network.proxy.ssl": ("https_host", str),
    "network.proxy.ssl_port": ("https_port", int),
    "network.proxy.socks": ("socks_host", str),
    "network.proxy.socks_port": ("socks_port", int),
    "network.proxy.socks_version": ("socks_version", int),
    "network.proxy.no_proxies_on": ("no_proxies", str),
}

_PREF_RE = re.compile(r'user_pref\(\s*"([^"]+)"\s*,\s*(.*?)\s*\)\s*;', re.S)


def _js_unquote(v: str):
    v = v.strip()
    if v.startswith('"') and v.endswith('"') and len(v) >= 2:
        body = v[1:-1]
        return (body.replace('\\"', '"').replace("\\\\", "\\"), True)
    try:
        return (int(v), False)
    except ValueError:
        return (v, False)


def parse_firefox_prefs(text: str) -> dict:
    """อ่าน prefs.js / user.js → dict ของค่าที่เกี่ยวกับ proxy"""
    found: dict = {}
    for name, raw in _PREF_RE.findall(text):
        if name not in FF_PROXY_KEYS:
            continue
        val, _is_str = _js_unquote(raw)
        found[FF_PROXY_KEYS[name][0]] = val
    return found


# Firefox เขียนค่าในรูปแบบ string ที่ escape มาแล้ว (เช่น "local\u002Chost")
_ESC_RE = re.compile(r"\\u([0-9a-fA-F]{4})|\\x([0-9a-fA-F]{2})")


def _ff_unescape(s: str) -> str:
    if not isinstance(s, str):
        return s

    def rep(m):
        if m.group(1):
            return chr(int(m.group(1), 16))
        return chr(int(m.group(2), 16))

    return _ESC_RE.sub(rep, s)


def find_firefox_profiles(home: Path | None = None) -> list[Path]:
    home = Path(home or Path.home())
    roots = [
        home / ".mozilla" / "firefox",
        home / "snap" / "firefox" / "common" / ".mozilla" / "firefox",
        home / ".var" / "app" / "org.mozilla.firefox" / ".mozilla" / "firefox",
    ]
    out: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        for d in sorted(root.iterdir()):
            if not d.is_dir() or not (d / "prefs.js").exists() and not (d / "user.js").exists():
                continue
            # ข้าม profile ที่ไม่ใช่ (ชื่อโฟลเดอร์ profile ลงท้ายด้วยชื่อ) — เอาที่มี prefs เป็นหลัก
            out.append(d)
    return out


def read_firefox_proxy(profile: Path) -> dict:
    """รวม prefs.js + user.js (user.js ชนะ เพราะ Firefox ใช้ค่านี้ตอนเปิด)"""
    merged: dict = {}
    for fname in ("prefs.js", "user.js"):
        f = profile / fname
        if f.exists():
            try:
                merged.update(parse_firefox_prefs(f.read_text(encoding="utf-8", errors="replace")))
            except OSError:
                pass
    return merged


def firefox_to_state(prefs: dict, base: ProxyState | None = None) -> tuple[ProxyState, list[str]]:
    """แปลงค่า Firefox → ProxyState + รายการคำเตือน"""
    st = ProxyState(**asdict(base)) if base else ProxyState()
    warn: list[str] = []
    ptype = prefs.get("type", 0)
    if ptype in (0, 5):
        # คืน host ว่าง = "ไม่มีอะไรให้ซิงก์" เพื่อให้ผู้เรียกไม่ทับค่าที่ผู้ใช้พิมพ์ไว้
        st.host, st.port, st.kind = "", 0, "http"
        if ptype == 0:
            warn.append("Firefox ตั้งเป็น 'ไม่มี proxy' — ไม่มีอะไรให้ sync")
        else:
            warn.append("Firefox ใช้ 'Use system proxy' — ค่าจริงอยู่ใน gsettings ไม่ได้อยู่ใน prefs")
        return st, warn
    if ptype != 1:
        warn.append(f"Firefox proxy type={ptype} (PAC/auto) — ซิงก์ได้เฉพาะแบบ manual")

    socks_host = _ff_unescape(prefs.get("socks_host") or "")
    socks_port = int(prefs.get("socks_port") or 0)
    http_host = _ff_unescape(prefs.get("http_host") or "")
    http_port = int(prefs.get("http_port") or 0)

    # SOCKS ชนะถ้า Firefox ตั้ง socks_version ไว้ และ socks host มีค่า (plugin container ใช้ socks)
    if socks_host and socks_port and int(prefs.get("socks_version") or 0) in (4, 5):
        st.kind = "socks5"
        st.host, st.port = socks_host, socks_port
    elif http_host and http_port:
        st.kind = "http"
        st.host, st.port = http_host, http_port
    else:
        st.host, st.port = "", 0

    np = _ff_unescape(prefs.get("no_proxies") or "")
    if np.strip():
        items = [x.strip() for x in np.split(",") if x.strip()]
        # รวมกับค่าที่จำเป็นของเรา เพื่อไม่ให้ localhost หลุด
        merged = items + [d for d in DEFAULT_NO_PROXY if d not in items]
        st.no_proxy = merged
    return st, warn


# ─────────────────────────────────────── state persistence ──
def save_state(state: ProxyState, home: Path | None = None) -> Path:
    p = config_path(home)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(asdict(state), ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, p)
    try:
        p.chmod(0o600)
    except OSError:
        pass
    return p


def load_state(home: Path | None = None) -> ProxyState:
    p = config_path(home)
    if not p.exists():
        return ProxyState()
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ProxyState()
    known = {f for f in ProxyState().__dict__}
    return ProxyState(**{k: v for k, v in d.items() if k in known})


def save_snapshot(snap: dict, home: Path | None = None) -> None:
    p = snapshot_path(home)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(snap, ensure_ascii=False, indent=2), encoding="utf-8")


def load_snapshot(home: Path | None = None) -> dict:
    p = snapshot_path(home)
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


# ─────────────────────────────────────── apply / clear ──
@dataclass
class StepResult:
    ok: bool
    label: str
    detail: str = ""


def apply_state(state: ProxyState, home: Path | None = None, *, dry_run: bool = False) -> list[StepResult]:
    """เปิด proxy ตาม state — คืนผลทีละขั้นเพื่อแสดงใน GUI"""
    results: list[StepResult] = []
    errs = state.validate()
    if errs:
        return [StepResult(False, "ตรวจค่า", "; ".join(errs))]

    state.enabled = True

    # 1) เก็บค่าเดิมไว้ก่อน "ครั้งแรกครั้งเดียว" เพื่อคืนค่าได้ภายหลัง
    snapfile = snapshot_path(home)
    if not dry_run and not snapfile.exists() and have("gsettings"):
        save_snapshot(read_gsettings_snapshot(), home)
        results.append(StepResult(True, "สำรองค่าเดิม", str(snapfile)))

    # 2) GNOME
    if state.apply_gnome:
        if not have("gsettings"):
            results.append(StepResult(False, "GNOME (gsettings)", "ไม่พบ gsettings — ข้าม"))
        else:
            okn = 0
            for cmd in build_gsettings_set(state):
                if dry_run:
                    okn += 1
                    continue
                r = run(cmd)
                if r.returncode == 0:
                    okn += 1
                else:
                    results.append(StepResult(False, "gsettings", f"{' '.join(cmd[2:])} → {r.stderr.strip()[:120]}"))
                    break
            if okn == len(build_gsettings_set(state)):
                results.append(StepResult(True, "GNOME (gsettings)", f"mode=manual → {state.url()}"))

    # 3) XFCE (ค่าเริ่มต้นของ Kali)
    if state.apply_xfce:
        if not have("xfconf-query"):
            results.append(StepResult(False, "XFCE (xfconf)", "ไม่พบ xfconf-query — ข้าม"))
        else:
            okn = 0
            for cmd in build_xfconf_set(state):
                if dry_run:
                    okn += 1
                    continue
                if run(cmd).returncode == 0:
                    okn += 1
            results.append(StepResult(okn == len(build_xfconf_set(state)), "XFCE (xfconf)",
                                      f"ตั้งค่า {okn}/{len(build_xfconf_set(state))} ค่า"))

    # 4) shell env (ไฟล์ env.sh + บล็อกใน rc)
    if not dry_run:
        ep = env_sh_path(home)
        ep.parent.mkdir(parents=True, exist_ok=True)
        ep.write_text(build_env_snippet(state), encoding="utf-8")
        touched = install_rc_block(home)
        results.append(StepResult(True, "http_proxy / https_proxy",
                                  f"เขียน {ep.name} + rc: {', '.join(p.name for p in touched) or 'มีอยู่แล้ว'}"))
    else:
        results.append(StepResult(True, "http_proxy / https_proxy", "dry-run"))

    # 5) apt / sudo (ต้อง root)
    if state.apply_apt:
        if os.geteuid() != 0:
            results.append(StepResult(False, "apt/sudo", "ต้องรันด้วย root (หรือ pkexec) — ข้าม"))
        elif dry_run:
            results.append(StepResult(True, "apt/sudo", "dry-run"))
        else:
            try:
                Path(APT_FILE).write_text(build_apt_conf(state), encoding="utf-8")
                results.append(StepResult(True, "apt/sudo", APT_FILE))
            except OSError as e:
                results.append(StepResult(False, "apt/sudo", str(e)))

    if not dry_run:
        save_state(state, home)
    return results


def clear_state(state: ProxyState | None = None, home: Path | None = None, *,
                dry_run: bool = False) -> list[StepResult]:
    """ปิด proxy ทุกชั้น + คืนค่าเดิมถ้ามี snapshot"""
    results: list[StepResult] = []
    st = state or load_state(home)
    st.enabled = False

    # 1) GNOME → none + คืนค่าเดิม
    if have("gsettings"):
        if not dry_run:
            for cmd in build_gsettings_off():
                run(cmd)
        results.append(StepResult(True, "GNOME (gsettings)", "mode=none"))
        snap = load_snapshot(home)
        if snap:
            if not dry_run:
                for cmd in build_gsettings_restore(snap):
                    run(cmd)
            results.append(StepResult(True, "คืนค่าเดิม", f"{len(snap)} ค่า"))

    # 2) XFCE
    if have("xfconf-query"):
        if not dry_run:
            for cmd in build_xfconf_off():
                run(cmd)
        results.append(StepResult(True, "XFCE (xfconf)", "mode=none"))

    # 3) shell env → unset
    if not dry_run:
        ep = env_sh_path(home)
        ep.parent.mkdir(parents=True, exist_ok=True)
        ep.write_text(build_env_snippet(st), encoding="utf-8")
        results.append(StepResult(True, "http_proxy / https_proxy", "unset แล้ว (เปิด shell ใหม่)"))

    # 4) apt
    if os.geteuid() == 0 and Path(APT_FILE).exists():
        if not dry_run:
            try:
                Path(APT_FILE).unlink()
            except OSError:
                pass
        results.append(StepResult(True, "apt/sudo", "ลบ " + APT_FILE))

    if not dry_run:
        save_state(st, home)
    return results


# ─────────────────────────────────────── diagnostics ──
def current_env_proxy(environ: dict | None = None) -> dict[str, str]:
    env = environ if environ is not None else os.environ
    out = {}
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
        v = env.get(k)
        if v:
            out[k] = v
    return out


def describe(state: ProxyState) -> str:
    if not state.enabled:
        return "ปิดอยู่"
    return f"เปิด: {state.url()}"


def main_selftest() -> int:
    """รันด้วย --selftest เพื่อตรวจว่า core ทำงานโดยไม่ต้องมีจอ"""
    st = ProxyState(host="127.0.0.1", port=8080, enabled=True)
    assert st.validate() == [], st.validate()
    assert "http://127.0.0.1:8080" == st.url()
    cmds = build_gsettings_set(st)
    assert any("mode" in c and "manual" in c for c in cmds)
    env = build_env_vars(st)
    assert env["http_proxy"] == "http://127.0.0.1:8080"
    pf = parse_firefox_prefs(
        'user_pref("network.proxy.type", 1);\n'
        'user_pref("network.proxy.http", "10.0.0.5");\n'
        'user_pref("network.proxy.http_port", 3128);'
    )
    assert pf["type"] == 1 and pf["http_host"] == "10.0.0.5" and pf["http_port"] == 3128, pf
    print(f"{APP} {VERSION}: core OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main_selftest())
