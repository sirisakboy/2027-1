#!/usr/bin/env bash
# ==============================================================================
#  Arena Proxy — ตัวติดตั้ง/ตัวเรียกใช้ GUI สำหรับ Kali Linux
#
#  ทำไมต้องมีตัวนี้: GUI ตัวเดียวไม่พอ —
#    • Kali ปกติไม่มี python3-tk          → ต้องติดตั้งให้ (หรือบอกให้ชัด)
#    • ต้องมีปุ่มในเมนู                    → ต้องวาง .desktop
#    • ตั้ง gsettings ต้องมี D-Bus ของเดสก์ท็อป
#    • ตั้ง apt/sudo ต้องเป็น root          → ต้องใช้ pkexec
#    • รันจาก sudo ตรง ๆ จะพัง (ไม่มี DISPLAY/XAUTHORITY)
#
#  ใช้:
#    bash arena-proxy.sh                # เปิด GUI (ติดตั้งให้อัตโนมัติถ้าขาด)
#    bash arena-proxy.sh --install      # ติดตั้งลงเมนู + ไอคอน (ไม่ต้อง root)
#    bash arena-proxy.sh --install --system  # ติดตั้งทั้งเครื่อง (ต้อง root)
#    bash arena-proxy.sh --check        # ตรวจความพร้อมของระบบ (ไม่แก้อะไร)
#    bash arena-proxy.sh --cli on 127.0.0.1 8080   # ใช้ผ่าน command line
#    bash arena-proxy.sh --uninstall
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP="arena-proxy"
VERSION="1.0.0"
C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_WA=$'\033[33m'; C_DI=$'\033[2m'; C_Z=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_NO=""; C_WA=""; C_DI=""; C_Z=""; }

ok()   { printf '  %s✔%s %s\n' "$C_OK" "$C_Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WA" "$C_Z" "$*"; }
err()  { printf '  %s✖%s %s\n' "$C_NO" "$C_Z" "$*" >&2; }
info() { printf '  %s·%s %s\n' "$C_DI" "$C_Z" "$*"; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ─────────────────────────────────── ตรวจระบบ ──
detect_desktop() {
  local de="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-}}"
  printf '%s' "${de:-unknown}"
}

check_report() {
  printf '\n%sArena Proxy %s — ตรวจความพร้อม%s\n' "$C_WA" "$VERSION" "$C_Z"
  printf '%s────────────────────────────────────────%s\n' "$C_DI" "$C_Z"

  # Python
  if have python3; then
    ok "python3: $(python3 -V 2>&1)"
  else
    err "ไม่พบ python3 — ติดตั้ง: sudo apt install python3"
  fi

  # tkinter
  if python3 -c 'import tkinter' 2>/dev/null; then
    ok "tkinter: พร้อม"
  else
    warn "tkinter: ยังไม่มี — จะติดตั้งให้ตอนเปิด (sudo apt install python3-tk)"
  fi

  # เครื่องมือที่ GUI จะเรียก
  for t in gsettings xfconf-query curl; do
    if have "$t"; then ok "$t: พบ"; else info "$t: ไม่มี (จะข้ามส่วนนั้น)"; fi
  done

  # เดสก์ท็อป + D-Bus (gsettings ต้องมี)
  printf '  %sเดสก์ท็อป:%s %s\n' "$C_DI" "$C_Z" "$(detect_desktop)"
  if [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
    ok "D-Bus session: พร้อม (gsettings ใช้ได้)"
  else
    warn "ไม่มี DBUS_SESSION_BUS_ADDRESS — gsettings จะไม่ทำงาน (ปกติถ้ารันผ่าน ssh/sudo)"
    info "ถ้าตั้งใจใช้ GNOME ให้เปิดจาก terminal ในเดสก์ท็อป"
  fi

  # Firefox/ESR
  if have firefox || have firefox-esr; then
    ok "Firefox: $(command -v firefox firefox-esr 2>/dev/null | head -1)"
  else
    warn "ไม่พบ Firefox — ปุ่ม Sync จะไม่มีข้อมูลให้ดึง"
  fi

  # สิทธิ์ root
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    ok "รันเป็น root — ตั้ง apt/sudo proxy ได้"
  else
    info "รันเป็นผู้ใช้ปกติ — ตั้ง GNOME/XFCE/env ได้ แต่ apt ต้องกดผ่าน pkexec"
  fi

  # โปรไฟล์ Firefox
  local n=0
  for d in "$HOME"/.mozilla/firefox "$HOME"/snap/firefox/common/.mozilla/firefox; do
    [[ -d $d ]] && n=$((n + $(find "$d" -maxdepth 2 -name prefs.js 2>/dev/null | wc -l)))
  done
  [[ $n -gt 0 ]] && ok "พบโปรไฟล์ Firefox: $n" || info "ยังไม่พบโปรไฟล์ Firefox"
  printf '\n'
}

# ─────────────────────────────────── ติดตั้ง tkinter ──
ensure_tk() {
  python3 -c 'import tkinter' 2>/dev/null && return 0

  warn "ยังไม่มี tkinter — กำลังติดตั้ง python3-tk"
  if [[ ${EUID:-$(id -u)} -ne 0 ]] && have sudo; then
    sudo apt-get update -qq && sudo apt-get install -y python3-tk
  elif [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    apt-get update -qq && apt-get install -y python3-tk
  else
    die "ติดตั้งเองไม่ได้ — รัน: sudo apt install python3-tk"
  fi

  python3 -c 'import tkinter' 2>/dev/null || {
    err "ติดตั้งแล้วแต่ยัง import ไม่ได้"
    info "Kali: sudo apt update && sudo apt install python3-tk python3-pil.imagetk"
    info "หรือใช้แบบ CLI: bash $APP.sh --cli on 127.0.0.1 8080"
    return 1
  }
  ok "ติดตั้ง tkinter เรียบร้อย"
}

# ─────────────────────────────────── .desktop ──
install_desktop() {
  local target_dir
  if [[ ${1:-} == --system ]]; then
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "การติดตั้งทั้งเครื่องต้องรันด้วย sudo"
    target_dir="/usr/share/applications"
  else
    target_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  fi
  mkdir -p "$target_dir" || die "สร้าง $target_dir ไม่ได้"

  # ใช้ pkexec ถ้ามี เพื่อให้ตั้ง apt ได้ด้วย (จะถามรหัสเมื่อเปิด)
  local exec_line
  if have pkexec; then
    exec_line="pkexec env DISPLAY=\$DISPLAY XAUTHORITY=\$XAUTHORITY XDG_CURRENT_DESKTOP=\$XDG_CURRENT_DESKTOP python3 $SELF_DIR/arena_proxy_gui.py"
  else
    exec_line="python3 $SELF_DIR/arena_proxy_gui.py"
  fi

  cat >"$target_dir/arena-proxy.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Arena Proxy
Name[th]=Arena Proxy — ตั้ง proxy ทั้งเครื่อง
Comment=Set system proxy (gsettings/xfconf/env) for Kali Linux
Comment[th]=ตั้ง gsettings org.gnome.system.proxy + export http_proxy/https_proxy พร้อมปุ่ม ON/OFF
Exec=sh -c '$exec_line'
Icon=network-proxy
Terminal=false
Categories=Network;Settings;System;
Keywords=proxy;http_proxy;gsettings;vpn;kali;
StartupNotify=true
EOF
  chmod 644 "$target_dir/arena-proxy.desktop"
  ok "วางเมนูแล้ว: $target_dir/arena-proxy.desktop"
  have update-desktop-database >/dev/null 2>&1 && update-desktop-database "$target_dir" 2>/dev/null || true

  # ไอคอนสำรอง (SVG เล็ก ๆ) ถ้าไม่มี network-proxy
  local icon_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
  if [[ ${1:-} == --system ]]; then icon_dir="/usr/share/icons/hicolor/scalable/apps"; fi
  mkdir -p "$icon_dir" 2>/dev/null && cat >"$icon_dir/network-proxy.svg" <<'SVG' 2>/dev/null || true
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <circle cx="32" cy="32" r="30" fill="#12141a" stroke="#3ddc97" stroke-width="3"/>
  <path d="M16 32h32M32 16v32" stroke="#3ddc97" stroke-width="3"/>
  <circle cx="32" cy="32" r="9" fill="none" stroke="#3ddc97" stroke-width="3"/>
</svg>
SVG
  info "เปิดจากเมนู: Arena Proxy"
}

uninstall_desktop() {
  local f1="${XDG_DATA_HOME:-$HOME/.local/share}/applications/arena-proxy.desktop"
  local f2="/usr/share/applications/arena-proxy.desktop"
  local removed=0
  for f in "$f1" "$f2"; do
    if [[ -f $f ]]; then
      rm -f "$f" 2>/dev/null && { ok "ลบ $f"; removed=1; } || warn "ลบ $f ไม่ได้ (ต้อง sudo?)"
    fi
  done
  [[ $removed == 1 ]] || info "ไม่พบไฟล์ที่ติดตั้งไว้"
}

# ─────────────────────────────────── CLI mode ──
cli_mode() {
  local action=${1:-status}; shift || true
  local py="$SELF_DIR/arena_proxy_core.py"
  case "$action" in
    on | apply)
      local ip=${1:-127.0.0.1} port=${2:-8080}
      python3 - "$ip" "$port" <<'PY'
import sys, arena_proxy_core as core
ip, port = sys.argv[1], int(sys.argv[2])
st = core.ProxyState(host=ip, port=port, enabled=True)
for r in core.apply_state(st):
    print(("✔ " if r.ok else "✖ ") + f"{r.label}: {r.detail}")
PY
      ;;
    off | clear)
      python3 - <<'PY'
import arena_proxy_core as core
for r in core.clear_state():
    print(("✔ " if r.ok else "✖ ") + f"{r.label}: {r.detail}")
PY
      ;;
    status)
      python3 - <<'PY'
import arena_proxy_core as core
st = core.load_state()
print(core.describe(st))
env = core.current_env_proxy()
if env:
    print("ตัวแปรในเชลล์นี้:", ", ".join(f"{k}={v}" for k, v in env.items()))
else:
    print("ไม่มี http_proxy/https_proxy ในเชลล์นี้ (เปิด terminal ใหม่หลัง Apply)")
PY
      ;;
    *)
      die "ใช้: --cli [on <ip> <port> | off | status]"
      ;;
  esac
}

# ─────────────────────────────────── main ──
case "${1:-}" in
  --check | -c)
    check_report
    exit 0
    ;;
  --install | -i)
    shift || true
    install_desktop "$@"
    exit 0
    ;;
  --uninstall)
    uninstall_desktop
    exit 0
    ;;
  --cli)
    shift || true
    cd "$SELF_DIR" || die "เข้า $SELF_DIR ไม่ได้"
    cli_mode "$@"
    exit $?
    ;;
  --version | -V)
    echo "$APP $VERSION"
    exit 0
    ;;
  --help | -h)
    sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# ค่าเริ่มต้น: เปิด GUI
check_report

if ! python3 -c 'import tkinter' 2>/dev/null; then
  ensure_tk || exit 1
fi

if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then
  err "ไม่พบ DISPLAY — ต้องรันในหน้าจอเดสก์ท็อป"
  info "ถ้าอยู่ใน SSH: ssh -X user@เครื่อง แล้วรันใหม่"
  info "หรือใช้แบบ CLI: bash $APP.sh --cli on 127.0.0.1 8080"
  exit 2
fi

cd "$SELF_DIR" || die "เข้า $SELF_DIR ไม่ได้"
exec python3 "$SELF_DIR/arena_proxy_gui.py" "$@"
