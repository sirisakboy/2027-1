#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
เรนเดอร์ภาพหน้าจอของ Arena Proxy จาก "widget tree จริง" ที่โค้ดสร้าง

ไม่ได้วาดขึ้นมาเอง — สร้าง ArenaProxyApp บน tkinter stub แล้วเดินอ่าน widget
(pack/grid, text, สี, ฟอนต์) ออกมาเป็น PNG
เพื่อให้เห็นหน้าตาจริงบนเครื่องที่ไม่มีจอ (CI / แซนด์บ็อกซ์)

    python3 tools/proxy-gui/tests/render_preview.py [--on] [-o out.png]

ต้องมี: pillow (pip install pillow)
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
sys.path.insert(0, str(HERE / "stubs"))
sys.path.insert(0, str(PKG))

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.stderr.write("ต้องติดตั้ง pillow: pip install pillow\n")
    raise SystemExit(2)

import tkinter as tk  # stub
import arena_proxy_gui as gui  # noqa: E402
import arena_proxy_core as core  # noqa: E402

import glob as _glob


def _has_thai(path: str) -> bool:
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        return False
    try:
        t = TTFont(path, fontNumber=0, lazy=True)
        cmap = t.getBestCmap() or {}
        return 0x0E01 in cmap and "LastResort" not in path
    except Exception:  # noqa: BLE001
        return False


def _pick(cands: list[str], fallback: str) -> str:
    for c in cands:
        if Path(c).exists() and _has_thai(c):
            return c
    return fallback


# ── หาฟอนต์ที่รองรับภาษาไทย ──────────────────────────────────────────────
# ลำดับ: repo sirisakboy/thai-font (ถ้าโคลนไว้) → ฟอนต์ในระบบ (Kali มี Noto/TLWG)
# ถ้าไม่พบเลย จะใช้ DejaVu + แสดงข้อความอังกฤษแทน (ภาพยังอ่านออก)
#
#   git clone --depth 1 https://github.com/sirisakboy/thai-font.git /tmp/thai-font
#   THAI_FONT_DIR=/tmp/thai-font python3 tools/proxy-gui/tests/render_preview.py
#
THAI_FONT_DIR = os.environ.get("THAI_FONT_DIR", "/tmp/thai-font")

# ชื่อที่ต้องการ (เรียงตามความชอบ) — Chakra Petch เข้ากับ UI มืดที่สุด
PREFERRED = [
    "TH Chakra Petch",       # UI สมัยใหม่ อ่านง่าย
    "TH Niramit AS",
    "TH Krub",
    "THSarabun",
    "NotoSansThai", "Noto Sans Thai", "Sarabun",
    "tlwg", "Waree", "Loma", "Garuda", "Kinnari", "Norasi",
]

# ถ้าไม่มีฟอนต์ไทยเลย ลองโคลน repo ฟอนต์ให้อัตโนมัติ (ต้องมี git + เน็ต)
if not Path(THAI_FONT_DIR).is_dir():
    import shutil as _sh
    import subprocess as _sp
    if _sh.which("git"):
        try:
            sys.stderr.write("[preview] ไม่พบฟอนต์ไทย — กำลังโคลน sirisakboy/thai-font …\n")
            _sp.run(["git", "clone", "-q", "--depth", "1",
                     "https://github.com/sirisakboy/thai-font.git", THAI_FONT_DIR],
                    timeout=180, check=False)
        except Exception:  # noqa: BLE001
            pass

_cands: list[str] = []
if Path(THAI_FONT_DIR).is_dir():
    _cands += sorted(_glob.glob(THAI_FONT_DIR + "/*.[tT][tT][fF]"))
for _d in ("/usr/share/fonts/truetype/noto/", "/usr/share/fonts/truetype/tlwg/",
           "/usr/share/fonts/opentype/noto/", "/usr/share/fonts/"):
    _cands += sorted(_glob.glob(_d + "**/*.[tT][tT][fF]", recursive=True))


def _pref_rank(path: str) -> int:
    base = Path(path).stem.lower()
    for i, want in enumerate(PREFERRED):
        if want.lower() in base:
            return i
    return len(PREFERRED)


_ok_cands = [c for c in _cands if _has_thai(c)]
_ok_cands.sort(key=_pref_rank)

FONT_R = _pick(_ok_cands[:40], "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
# ตัวหนา: เอาตัวที่ชื่อเข้าคู่กันและมี Bold
_stem = Path(FONT_R).stem
_bold_pool = [c for c in _ok_cands if Path(c).stem.startswith(_stem) and "Bold" in Path(c).stem]
FONT_B = _pick(_bold_pool, FONT_R)
FONT_M = FONT_R   # log มีภาษาไทย → ต้องใช้ฟอนต์ไทย (mono มาตรฐานไม่มี glyph ไทย)


def thai_available() -> bool:
    return _has_thai(FONT_R)


# ถ้าไม่มีฟอนต์ไทย ให้ใช้ข้อความอังกฤษแทน (ภาพจะได้อ่านออก ไม่ใช่กล่อง)
TH = thai_available()


def T(th: str, en: str) -> str:
    return th if TH else en

BG = (18, 20, 26)
PANEL = (27, 31, 39)
FG = (230, 230, 230)
DIM = (139, 147, 167)
ACCENT = (61, 220, 151)
RED = (255, 92, 122)
WARN = (255, 204, 102)
ENTRY = (14, 16, 21)

PAD = 22
W = 780


_FCACHE: dict = {}


def font(size=13, bold=False, mono=False):
    path = FONT_M if mono else (FONT_B if bold else FONT_R)
    key = (path, size)
    if key in _FCACHE:
        return _FCACHE[key]
    try:
        f = ImageFont.truetype(path, size)
    except OSError:
        f = ImageFont.load_default()
    _FCACHE[key] = f
    return f


# ── font fallback ระดับตัวอักษร ─────────────────────────────────────────
# ฟอนต์ไทย (Chakra Petch/Sarabun) ไม่มีสัญลักษณ์ UI (✔ ● ▸) และ DejaVu ไม่มีไทย
# Tk/Pango แก้ด้วย fallback chain — ที่นี่ทำเหมือนกัน: เลือกฟอนต์ตามโค้ดพอยต์
_SYM_CACHE: dict = {}


def _font_has(path: str, ch: str) -> bool:
    key = (path, ch)
    if key in _SYM_CACHE:
        return _SYM_CACHE[key]
    try:
        from fontTools.ttLib import TTFont
        cm = TTFont(path, lazy=True, fontNumber=0).getBestCmap() or {}
        _SYM_CACHE[key] = ord(ch) in cm
    except Exception:  # noqa: BLE001
        _SYM_CACHE[key] = False
    return _SYM_CACHE[key]


def _is_thai(ch: str) -> bool:
    o = ord(ch)
    return 0x0E00 <= o <= 0x0E7F


def draw_mixed(d, xy, text, f_thai=None, *, fill=FG, f_sym=None, _font=None):
    """วาดข้อความแบบผสมฟอนต์: ไทย→ฟอนต์ไทย, สัญลักษณ์/ละติน→DejaVu

    Tk/Pango เลือกฟอนต์อัตโนมัติต่อตัวอักษร (fallback chain) — ที่นี่ทำเหมือนกัน
    ฟอนต์ไทยส่วนใหญ่ (Chakra Petch / Sarabun) ไม่มี ✔ ▸ ● ดังนั้นต้องสลับฟอนต์
    """
    f_thai = f_thai if f_thai is not None else (_font or font(13))
    _sz = int(getattr(f_thai, "size", 13) or 13)
    # f_sym ต้องเป็นฟอนต์ "สัญลักษณ์" จริง (DejaVu) ไม่ใช่ฟอนต์ไทย
    if f_sym is None:
        _fp = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" \
            if "Bold" in str(getattr(f_thai, "path", "")) \
            else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
        _k = (_fp, _sz)
        if _k not in _FCACHE:
            try:
                _FCACHE[_k] = ImageFont.truetype(_fp, _sz)
            except OSError:
                _FCACHE[_k] = ImageFont.load_default()
        f_sym = _FCACHE[_k]

    if not TH:
        d.text(xy, text, font=f_sym, fill=fill)
        return

    def pick(ch):
        """คืนฟอนต์ที่ 'มี glyph จริง' สำหรับตัวอักษรนี้"""
        if _is_thai(ch) and _font_has(FONT_R, ch):
            return f_thai
        if _font_has(FONT_M_SYM if False else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", ch):
            return f_sym
        return f_thai   # ไม่มีที่ไหนมี → ปล่อยให้ฟอนต์ไทยวาด (กล่อง)

    def fpath(f):
        return str(getattr(f, "path", id(f)))

    x, y = xy
    buf, cur, cur_path = "", None, None
    for ch in text:
        f_for_ch = pick(ch)
        if cur is None:
            cur, cur_path = f_for_ch, fpath(f_for_ch)
        if fpath(f_for_ch) != cur_path:          # เทียบด้วย path (PIL สร้าง object ใหม่ทุกครั้ง)
            d.text((x, y), buf, font=cur, fill=fill)
            x += d.textlength(buf, font=cur)
            buf, cur, cur_path = "", f_for_ch, fpath(f_for_ch)
        buf += ch
    if buf:
        d.text((x, y), buf, font=cur, fill=fill)


def measure(d, text, f_thai=None, *, _font=None):
    """วัดความกว้างข้อความแบบผสมฟอนต์ (ให้ตรงกับ draw_mixed)"""
    f_thai = f_thai if f_thai is not None else (_font or font(13))
    _sz = int(getattr(f_thai, "size", 13) or 13)
    _fp = ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
           if "Bold" in str(getattr(f_thai, "path", ""))
           else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
    _k = (_fp, _sz)
    if _k not in _FCACHE:
        try:
            _FCACHE[_k] = ImageFont.truetype(_fp, _sz)
        except OSError:
            _FCACHE[_k] = ImageFont.load_default()
    f_sym = _FCACHE[_k]

    if not TH:
        return d.textlength(text, font=f_sym)

    def pick_f(ch):
        if _is_thai(ch) and _font_has(FONT_R, ch):
            return f_thai
        if _font_has(_fp, ch):
            return f_sym
        return f_thai

    total = 0.0
    buf, cur_path, cur = "", None, None
    for ch in text:
        f_for_ch = pick_f(ch)
        pth = str(getattr(f_for_ch, "path", id(f_for_ch)))
        if cur is None:
            cur, cur_path = f_for_ch, pth
        if pth != cur_path:
            total += d.textlength(buf, font=cur)
            buf, cur, cur_path = "", f_for_ch, pth
        buf += ch
    if buf:
        total += d.textlength(buf, font=cur)
    return total


def walk(node, out):
    for c in getattr(node, "children", []):
        out.append(c)
        walk(c, out)


def render(state_on: bool, out_path: Path) -> None:
    root = tk.Tk()
    # แยกโฮมตามสถานะ กันสถานะรอบก่อนค้าง (config.json เขียนทับ)
    ho = Path(f"/tmp/preview-home-{'on' if state_on else 'off'}")
    (ho / ".config" / "arena-proxy").mkdir(parents=True, exist_ok=True)
    cfg = ho / ".config" / "arena-proxy" / "config.json"
    if cfg.exists():
        cfg.unlink()               # เริ่มจากสะอาดทุกครั้ง
    app = gui.ArenaProxyApp(root, home=ho)

    # ตั้งสถานะให้ตรงกับที่ต้องการถ่าย
    if state_on:
        app.ip_var.set("127.0.0.1")
        app.port_var.set("1080")
        app.kind_var.set("socks5")
        # ต้องเขียนลง config ด้วย เพราะ _refresh_status() อ่านจากดิสก์ (พฤติกรรมจริงของแอป)
        core.save_state(core.ProxyState(host="127.0.0.1", port=1080,
                                        kind="socks5", enabled=True), ho)
        app._refresh_status()
    app._pump_log()          # 1) ระบายของเดิม
    app.log_txt.delete("0", "end")
    # 2) เขียน log ใหม่ "หลัง" ล้าง — กันถูกระบายทิ้ง
    if state_on:
        for lvl, msg in [
            ("head", "Apply → socks5h://127.0.0.1:1080  (GNOME=True XFCE=True apt=False)"),
            ("ok", T("สำรองค่าเดิม: /root/.cache/arena-proxy/original.json",
                     "Snapshot saved: /root/.cache/arena-proxy/original.json")),
            ("ok", "GNOME (gsettings): mode=manual → socks5h://127.0.0.1:1080"),
            ("ok", T("XFCE (xfconf): ตั้งค่า 8/8 ค่า", "XFCE (xfconf): 8/8 keys set")),
            ("ok", T("http_proxy / https_proxy: เขียน env.sh + rc: .zshrc, .bashrc, .profile",
                     "http_proxy / https_proxy: wrote env.sh + rc: .zshrc, .bashrc, .profile")),
            ("ok", T("Apply เสร็จ — เปิด terminal ใหม่เพื่อใช้ http_proxy",
                     "Apply done — open a new terminal to use http_proxy")),
        ]:
            app.log_q.put((lvl, msg))
    else:
        for lvl, msg in [
            ("head", T("desktop ที่ตรวจพบ: XFCE", "desktop detected: XFCE")),
            ("ok", T("XFCE/xfconf พร้อมใช้งาน", "XFCE/xfconf ready")),
            ("warn", T("gsettings ใช้ไม่ได้ในเซสชันนี้ (ไม่มี D-Bus?) — จะข้าม GNOME",
                       "gsettings unavailable in this session (no D-Bus?) — skipping GNOME")),
            ("info", T("Firefox: พบ 2 โปรไฟล์", "Firefox: 2 profiles found")),
            ("info", T("พร้อมใช้งาน · config: /root/.config/arena-proxy/config.json",
                       "ready · config: /root/.config/arena-proxy/config.json")),
        ]:
            app.log_q.put((lvl, msg))
    app._pump_log()

    # ── วัดความสูงที่ต้องใช้ (log ยืดตามจำนวนบรรทัดจริง) ──
    _lines = app.log_txt.content.rstrip("\n").split("\n") if app.log_txt.content.strip() else []
    lh = max(96, 30 + 21 * len(_lines))
    H = (18 + 30 + 6) + (8 + 18 + 26 + 34 + 26 + 22 + 18) + (10 + 24 + 14) \
        + (14 + 52) + (14 + 18 + 6 + lh + 8 + 6) + (10 + 24 + 14)

    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    y = 18

    # ── header ──
    draw_mixed(d, (PAD, y), "Arena Proxy", font(27, bold=True), fill=FG)
    tw = measure(d, "Arena Proxy", font(27, bold=True))
    draw_mixed(d, (PAD + tw + 22, y + 16),
               T("ตั้ง proxy ทั้งเครื่อง Kali · ที่เดียวจบ",
                 "System-wide proxy for Kali · all in one place"),
               _font=font(13), fill=DIM)
    on = state_on
    _status = str(app.status_lbl.cget("text"))
    if not TH:
        _status = _status.replace("เปิดอยู่", "ON").replace("ปิดอยู่", "OFF")
    _sf = font(15)
    _sw = measure(d, _status, _sf)
    draw_mixed(d, (W - PAD - _sw, y + 10), _status, _sf, fill=ACCENT if on else RED)
    y += 30 + 6

    # ── form panel ──
    y += 8
    ph = 18 + 26 + 34 + 26 + 22
    d.rounded_rectangle([PAD, y, W - PAD, y + ph], 8, fill=PANEL)
    iy = y + 16
    draw_mixed(d, (PAD + 18, iy), T("ปลายทาง proxy", "Proxy endpoint"), _font=font(15), fill=DIM)
    iy += 28
    draw_mixed(d, (PAD + 18, iy), "IP / Host", _font=font(16), fill=FG)
    draw_mixed(d, (PAD + 350, iy), "Port", _font=font(16), fill=FG)
    draw_mixed(d, (PAD + 500, iy), T("ชนิด", "Type"), _font=font(16), fill=FG)
    iy += 26
    # entries
    d.rounded_rectangle([PAD + 18, iy, PAD + 320, iy + 36], 5, fill=ENTRY, outline=(42, 48, 64))
    draw_mixed(d, (PAD + 30, iy + 7), app.ip_var.get(), _font=font(16, mono=True), fill=ACCENT)
    d.rounded_rectangle([PAD + 350, iy, PAD + 470, iy + 36], 5, fill=ENTRY, outline=(42, 48, 64))
    draw_mixed(d, (PAD + 360, iy + 7), app.port_var.get(), _font=font(16, mono=True), fill=ACCENT)
    d.rounded_rectangle([PAD + 500, iy, PAD + 640, iy + 36], 5, fill=ENTRY, outline=(42, 48, 64))
    draw_mixed(d, (PAD + 510, iy + 8), app.kind_var.get(), _font=font(14), fill=ACCENT)
    draw_mixed(d, (PAD + 648, iy + 9), "▾", _font=font(15), fill=DIM)
    iy += 34 + 12
    _np = str(app.no_proxy_lbl.cget("text"))
    if not TH:
        _np = _np.replace("ยกเว้น", "Bypass")
    # ตัดให้พอดีความกว้าง
    while d.textlength(_np, font=font(15)) > (W - 2 * PAD - 40) and len(_np) > 20:
        _np = _np[:-2]
    draw_mixed(d, (PAD + 18, iy), _np, _font=font(15), fill=DIM)
    y += ph + 10

    # ── options ──
    draw_mixed(d, (PAD, y + 6), T("ตั้งกับ:", "Apply to:"), _font=font(15), fill=DIM)
    x = PAD + 54
    for label, checked in ((app.chk_gnome.cget("text"), app.gnome_var.get()),
                           (app.chk_xfce.cget("text"), app.xfce_var.get()),
                           (app.chk_apt.cget("text"), app.apt_var.get())):
        d.rounded_rectangle([x, y + 2, x + 15, y + 17], 3,
                            fill=ACCENT if checked else ENTRY, outline=DIM)
        if checked:
            d.line([x + 3, y + 10, x + 7, y + 14], fill=(10, 20, 14), width=2)
            d.line([x + 7, y + 14, x + 13, y + 5], fill=(10, 20, 14), width=2)
        _lbl = str(label).strip()
        if not TH:
            _lbl = "apt / sudo (needs root)" if "root" in _lbl else _lbl
        draw_mixed(d, (x + 22, y + 3), _lbl, _font=font(15), fill=FG)
        x += 22 + measure(d, _lbl, font(15)) + 22
    y += 24 + 14

    # ── action bar ──
    bx = PAD
    for label, primary in (("Apply", True), (T("ปิด (OFF)", "OFF"), False), ("Sync from Firefox", False), (T("ทดสอบ", "Test"), False)):
        label = label.strip()
        if not TH:
            label = {"ปิด (OFF)": "OFF", "ทดสอบ": "Test"}.get(label, label)
        f = font(13, bold=primary)
        tw_ = measure(d, label, f)
        bw = tw_ + 36
        bh = 40 if primary else 36
        top = y + (40 - bh) // 2
        d.rounded_rectangle([bx, top, bx + bw, top + bh], 6,
                            fill=ACCENT if primary else (35, 40, 52),
                            outline=None if primary else (52, 60, 78))
        draw_mixed(d, (bx + 18, top + (bh - 16) // 2), label, f,
                   fill=(12, 20, 16) if primary else FG)
        bx += bw + 10
    # toggle
    tgx = W - PAD - 78
    draw_mixed(d, (tgx - 58, y + 12), T("สถานะ:", "State:"), _font=font(15), fill=DIM)
    d.rounded_rectangle([tgx, y + 4, tgx + 78, y + 40], 18, fill=ACCENT if on else RED)
    _tg = str(app.toggle.cget("text"))
    draw_mixed(d, (tgx + (78 - measure(d, _tg, font(16, bold=True))) / 2, y + 14),
               _tg, _font=font(16, bold=True), fill=(11, 13, 17))
    y += 52 + 14

    # ── log ──
    draw_mixed(d, (PAD, y), T("บันทึก", "Log"), _font=font(15), fill=DIM)
    y += 18 + 6
    d.rounded_rectangle([PAD, y, W - PAD, y + lh], 6, fill=PANEL, outline=(42, 48, 64))
    ly = y + 12
    colors = {"ok": ACCENT, "err": RED, "warn": WARN, "info": DIM, "head": ACCENT}
    prefixes = {"ok": "✔ ", "err": "✖ ", "warn": "! ", "info": "· ", "head": "▸ "}
    tagmap = {}
    for tag in ("head", "ok", "warn", "err", "info"):
        for txt in getattr(app.log_txt, "tags", {}).get(tag, []):
            tagmap[txt.strip("\n")] = tag
    for line in app.log_txt.content.rstrip("\n").split("\n"):
        lvl = tagmap.get(line, "info")
        draw_mixed(d, (PAD + 12, ly), prefixes.get(lvl, "· ") + line, font(13), fill=colors.get(lvl, DIM))
        ly += 21
    y += lh + 8
    # progress bar
    d.rounded_rectangle([PAD, y, W - PAD, y + 6], 3, fill=(35, 40, 52))
    y += 6 + 10

    # ── footer ──
    draw_mixed(d, (PAD, y),
               T("เปิด terminal ใหม่ (หรือ source ~/.config/arena-proxy/env.sh) "
                 "เพื่อให้ http_proxy มีผลในเชลล์ปัจจุบัน",
                 "Open a new terminal (or source ~/.config/arena-proxy/env.sh) "
                 "for http_proxy to take effect"), _font=font(13), fill=DIM)
    d.rounded_rectangle([W - PAD - 62, y - 6, W - PAD, y + 20], 5, fill=(35, 40, 52), outline=(52, 60, 78))
    draw_mixed(d, (W - PAD - 50, y - 2), T("คู่มือ", "Docs"), _font=font(16), fill=FG)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path)
    _w = []
    walk(root, _w)
    print(f"[font thai={'yes' if TH else 'NO'}] ", end="")
    print(f"บันทึก: {out_path}  ({img.size[0]}×{img.size[1]}) · widgets={len(_w)}")


def main() -> int:
    root = tk.Tk()
    ho = Path("/tmp/preview-home")
    (ho / ".config" / "arena-proxy").mkdir(parents=True, exist_ok=True)
    app = gui.ArenaProxyApp(root, home=ho)
    out = []
    walk(root, out)

    args = sys.argv[1:]
    off_p = Path(PKG / "preview-off.png")
    on_p = Path(PKG / "preview-on.png")
    for i, a in enumerate(args):
        if a == "-o" and i + 1 < len(args):
            off_p = Path(args[i + 1])

    render(False, off_p)
    if "--on" in args or not args:
        render(True, on_p)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
