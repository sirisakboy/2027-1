#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — ไลบรารีกลาง (shared library)
#  ทุกสคริปต์ source ไฟล์นี้: log, env, IP, systemd, helper พื้นฐาน
# ==============================================================================
# shellcheck shell=bash

# ---------- ตำแหน่งไฟล์ / เวอร์ชัน ----------
_AVPN_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AVPN_HOME="$(cd -- "$_AVPN_LIB_DIR/.." && pwd -P)"
if [[ -f "$AVPN_HOME/VERSION" ]]; then
  AVPN_VERSION="$(tr -d '[:space:]' <"$AVPN_HOME/VERSION")"
else
  AVPN_VERSION="dev"
fi

# path หลัก — override ได้ผ่าน environment (ใช้ในเทสต์ / container)
AVPN_ETC="${AVPN_ETC:-/etc/arena-vpn}"
AVPN_STATE="${AVPN_STATE:-/var/lib/arena-vpn}"
AVPN_ENV_FILE="${AVPN_ENV_FILE:-$AVPN_ETC/arena-vpn.env}"
AVPN_PEERS_DIR="${AVPN_PEERS_DIR:-$AVPN_ETC/peers}"
AVPN_PEERS_TSV="${AVPN_PEERS_TSV:-$AVPN_ETC/peers.tsv}"
AVPN_WG_DIR="${AVPN_WG_DIR:-/etc/wireguard}"
AVPN_OVPN_DIR="${AVPN_OVPN_DIR:-/etc/openvpn}"
AVPN_BACKUP_DIR="${AVPN_BACKUP_DIR:-/var/backups/arena-vpn}"

export AVPN_ETC AVPN_STATE AVPN_ENV_FILE AVPN_PEERS_DIR AVPN_PEERS_TSV

# ---------- สี / log ----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
  C_LIME=$'\033[38;5;154m'
else
  C_RESET="" C_DIM="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_LIME=""
fi

log()  { printf '%s\n' "$*"; }
info() { printf '%s[•]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()   { printf '%s[✔]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[✖]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
step() { printf '\n%s▶ %s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET" >&2; }
die()  { err "$*"; exit 1; }

# ---------- helpers พื้นฐาน ----------
have() { command -v "$1" >/dev/null 2>&1; }

is_true() {
  case "${1,,}" in
    1 | true | yes | on | y) return 0 ;;
    *) return 1 ;;
  esac
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
  # ในเทสต์/คอนเทนเนอร์ที่ไม่ได้มีสิทธิ์ root ให้ข้ามได้ด้วย AVPN_ALLOW_NONROOT=1
  is_true "${AVPN_ALLOW_NONROOT:-0}" && return 0
  die "ต้องรันด้วยสิทธิ์ root — ลอง: sudo arena-vpn"
}

require_cmd() {
  have "$1" || die "ไม่พบคำสั่ง '$1' — ติดตั้งก่อน: apt-get install -y $2"
}

systemd_available() { [[ -d /run/systemd/system ]]; }

# รัน service command; ถ้าไม่มี systemd จะคืนค่า 0 แบบ no-op (container/LXC)
svc() {
  local action="$1"; shift
  systemd_available || return 0
  [[ ${EUID:-$(id -u)} -eq 0 ]] || return 0
  systemctl "$action" "$@" 2>&1 | sed 's/^/    /' >&2 || true
}

svc_active() {
  systemd_available || return 0
  [[ ${EUID:-$(id -u)} -eq 0 ]] || return 0
  systemctl is-active --quiet "$1" 2>/dev/null
}

# ---------- apt (รองรับ cloud-init ที่แย่ง lock) ----------
apt_run() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]] && ! is_true "${AVPN_ALLOW_NONROOT:-0}"; then
    warn "ไม่มีสิทธิ์ root — ข้าม apt $*"
    return 1
  fi
  local tries=0 out
  export DEBIAN_FRONTEND=noninteractive
  while true; do
    if out="$(apt-get -y -o Dpkg::Options::=--force-confold "$@" 2>&1)"; then
      return 0
    fi
    tries=$((tries + 1))
    if ((tries >= 6)); then
      printf '%s\n' "$out" >&2
      return 1
    fi
    # ถ้า error ไม่ใช่เรื่อง lock ให้เลิกเลย ไม่ต้องรอ
    case "$out" in
      *"Could not get lock"* | *"Unable to acquire"* | *"dpkg was interrupted"* | *"is another process"*) ;;
      *)
        printf '%s\n' "$out" >&2
        return 1
        ;;
    esac
    warn "apt ติด lock — รอ 5 วิ แล้วลองใหม่ (ครั้งที่ $tries/6)"
    sleep 5
  done
}

apt_update() { apt_run update; }
apt_install() { apt_run install --no-install-recommends "$@"; }

# ---------- ตรวจ IP / network ----------
is_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    ((o <= 255)) || return 1
  done
}

is_cidr4() {
  local cidr=$1 ip mask
  [[ $cidr == */* ]] || return 1
  ip=${cidr%/*}
  mask=${cidr#*/}
  [[ $mask =~ ^[0-9]{1,2}$ ]] && ((mask >= 0 && mask <= 32)) && is_ipv4 "$ip"
}

# ดึง public IPv4 — ลองหลาย endpoint, กัน ISP บล็อกบางเจ้า
# จำผลไว้ในตัวแปรระหว่างรัน (เรียกซ้ำไม่ต้องยิงเน็ตใหม่)
_AVPN_IP_MEMO=""
detect_public_ip() {
  [[ -n ${_AVPN_IP_MEMO:-} ]] && { printf '%s' "$_AVPN_IP_MEMO"; return 0; }
  local url ip
  for url in "https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
    ip="$(curl -fsS --connect-timeout 2 --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    if is_ipv4 "$ip"; then
      _AVPN_IP_MEMO="$ip"
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

detect_default_iface() {
  ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}' ||
    ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

detect_cloud() {
  local hdr
  hdr="$(curl -fsS --max-time 3 -H 'Authorization: Bearer Oracle' \
    "http://169.254.169.254/opc/v2/instance/" 2>/dev/null)" && [[ -n $hdr ]] && { echo "oracle"; return; }
  curl -fsS --max-time 2 -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/id" >/dev/null 2>&1 && { echo "gcp"; return; }
  curl -fsS --max-time 2 "http://169.254.169.254/latest/meta-data/instance-id" >/dev/null 2>&1 && { echo "aws"; return; }
  echo "unknown"
}

# ---------- config / env ----------
apply_defaults() {
  : "${AVPN_WG_IF:=wg0}"
  : "${AVPN_WG_PORT:=51820}"
  : "${AVPN_WG_NET:=10.8.0.0/24}"
  : "${AVPN_WG_SERVER_IP:=10.8.0.1}"
  : "${AVPN_OVPN_PORT:=443}"
  : "${AVPN_OVPN_PROTO:=tcp}"
  : "${AVPN_OVPN_NET:=10.9.0.0/24}"
  : "${AVPN_OVPN_SERVER_IP:=10.9.0.1}"
  : "${AVPN_OVPN_NET2:=10.9.1.0/24}"
  : "${AVPN_OVPN_SERVER_IP2:=10.9.1.1}"
  : "${AVPN_OVPN_UDP_ALT:=1}"
  : "${AVPN_FALLBACK_ENABLED:=1}"
  : "${AVPN_SSH_FALLBACK_PORTS:=2222}"
  : "${AVPN_DNS_ENABLED:=1}"
  : "${AVPN_DNS_UPSTREAMS:=9.9.9.9 1.1.1.1}"
  : "${AVPN_CLIENT_DNS:=10.8.0.1}"
  : "${AVPN_BLOCK_IPV6:=1}"
  : "${AVPN_PORTAL_ENABLED:=1}"
  : "${AVPN_PORTAL_PORT:=8443}"
  : "${AVPN_PORTAL_TLS:=1}"
  : "${AVPN_PORTAL_BIND:=0.0.0.0}"
  : "${AVPN_PUBLIC_HOST:=}"
  : "${AVPN_MTU:=1420}"
  : "${AVPN_MAX_CLIENTS:=8}"
  : "${AVPN_HARDENED_FIREWALL:=0}"
  : "${AVPN_EGRESS_IF:=}"
}

load_env() {
  if [[ -f "$AVPN_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$AVPN_ENV_FILE"
    set +a
  fi
  apply_defaults
}

env_set() {
  local key=$1 val=$2 tmp
  mkdir -p "$AVPN_ETC"
  tmp="$(mktemp "${AVPN_ENV_FILE}.XXXXXX")"
  if [[ -f "$AVPN_ENV_FILE" ]]; then
    grep -v -E "^[[:space:]]*${key}=" "$AVPN_ENV_FILE" >"$tmp" || true
  fi
  printf '%s=%q\n' "$key" "$val" >>"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$AVPN_ENV_FILE"
}

# โหลด public host (ใช้ AVPN_PUBLIC_HOST ถ้าตั้งไว้ ไม่งั้นใช้ cache/ตรวจใหม่)
public_host() {
  load_env
  if [[ -n ${AVPN_PUBLIC_HOST:-} ]]; then
    printf '%s' "$AVPN_PUBLIC_HOST"
    return 0
  fi
  if [[ -s "$AVPN_STATE/public-ip" ]]; then
    tr -d '[:space:]' <"$AVPN_STATE/public-ip"
    return 0
  fi
  local ip
  if ip="$(detect_public_ip)"; then
    mkdir -p "$AVPN_STATE"
    printf '%s\n' "$ip" >"$AVPN_STATE/public-ip" 2>/dev/null || true
    printf '%s' "$ip"
    return 0
  fi
  warn "ตรวจ public IP ไม่ได้ — ตั้งเองได้: arena-vpn config set AVPN_PUBLIC_HOST <ip หรือ โดเมน>"
  return 1
}

refresh_public_ip() {
  local ip
  mkdir -p "$AVPN_STATE"
  _AVPN_IP_MEMO=""
  ip="$(detect_public_ip)" || return 1
  printf '%s\n' "$ip" >"$AVPN_STATE/public-ip"
  printf '%s' "$ip"
}

# ---------- security helpers ----------
gen_password() {
  local n=${1:-24}
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$n" || true
}

rand_hex() { openssl rand -hex "${1:-16}"; }

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  printf '%s' "$s"
}

# แปลงวลา handshake (epoch) เป็นข้อความอ่านง่าย
human_ago() {
  local ts=${1:-0} now diff
  now=$(date +%s)
  if [[ $ts -le 0 ]]; then
    printf 'ยังไม่เคยเชื่อม'
    return
  fi
  diff=$((now - ts))
  if ((diff < 0)); then diff=0; fi
  if ((diff < 60)); then printf '%s วิ' "$diff"
  elif ((diff < 3600)); then printf '%s นาที' "$((diff / 60))"
  elif ((diff < 86400)); then printf '%s ชม.' "$((diff / 3600))"
  else printf '%s วัน' "$((diff / 86400))"; fi
}

human_bytes() {
  local b=${1:-0}
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB",u," ");
    i=1; while(b>=1024 && i<5){b/=1024; i++}
    printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

# validate ชื่ออุปกรณ์: ascii ตัวเล็ก/ตัวเลข/_/- เท่านั้น (กัน path traversal)
valid_peer_name() {
  [[ $1 =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]
}

# ยืนยันก่อนทำลาย — ในโหมด non-interactive ต้องมี ASSUME_YES=1
confirm() {
  local prompt=$1
  if is_true "${ASSUME_YES:-0}"; then
    return 0
  fi
  if [[ -n ${AVPN_ASSUME_YES:-} ]] && is_true "$AVPN_ASSUME_YES"; then
    return 0
  fi
  [[ -t 0 ]] || die "ต้องยืนยันคำสั่งนี้ — เพิ่ม --yes"
  local ans
  read -r -p "$prompt [y/N] " ans
  [[ ${ans,,} == y || ${ans,,} == yes ]]
}

# แสดง QR ในเทอร์มินัล — ใช้ qrencode ถ้ามี ไม่งั้นใช้ python (ถ้ามี)
show_qr() {
  local file=$1
  if have qrencode; then
    qrencode -t ansiutf8 <"$file"
    return 0
  fi
  if have python3 && python3 -c 'import qrcode' 2>/dev/null; then
    python3 - "$file" <<'PYEOF'
import sys
import qrcode
qr = qrcode.QRCode(border=1)
qr.add_data(open(sys.argv[1], "rb").read())
qr.make()
qr.print_ascii(invert=True)
PYEOF
    return 0
  fi
  warn "ไม่มี qrencode — ติดตั้ง: apt-get install -y qrencode  หรือดู QR จากพอร์ทัลเว็บ"
  return 1
}

# เมื่อถูก source เข้ามาใช้งานตรง ๆ (เช่น CGI) ให้ค่าดีฟอลต์พร้อมใช้เสมอ
apply_defaults

# เขียนไฟล์ระบบ — ถ้าไม่มีสิทธิ์ root ให้ข้ามเงียบ ๆ (โหมดทดสอบ/คอนเทนเนอร์)
# เขียนไฟล์ระบบ (เนื้อหาจาก stdin) — ข้ามเงียบ ๆ เมื่อไม่มีสิทธิ์เขียน
sys_write() { # sys_write <path> [perms]
  local path=$1 perms=${2:-644}
  if ! mkdir -p "$(dirname -- "$path")" 2>/dev/null || [[ ! -w $(dirname -- "$path") ]]; then
    cat >/dev/null 2>&1 || true
    return 1
  fi
  cat >"$path" 2>/dev/null || return 1
  chmod "$perms" "$path" 2>/dev/null || true
  return 0
}

sys_rm() { rm -f "$1" 2>/dev/null || true; }

apt_pkg_present() {
  dpkg -s "$1" >/dev/null 2>&1
}
