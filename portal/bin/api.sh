#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN Portal — API backend (CGI สำหรับ busybox httpd)
#  Shell ล้วน: ไม่ต้องลง Node/Python บน VM เล็ก ๆ
#  Security: Basic Auth ทุก route (ยกเว้น health), หน่วงเมื่อรหัสผิด,
#            ชื่ออุปกรณ์ต้องผ่าน valid_peer_name, ดาวน์โหลดเฉพาะไฟล์ใน allowlist
# ==============================================================================
set -u

AVPN_HOME="${AVPN_HOME:-/usr/local/lib/arena-vpn}"
LIB="${AVPN_LIB:-$AVPN_HOME/lib}"
AVPN_BIN="${AVPN_BIN:-/usr/local/bin/arena-vpn}"
[[ -x $AVPN_BIN ]] || AVPN_BIN="$AVPN_HOME/arena-vpn"   # โหมด dev: ใช้ CLI ใน repo

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/peers.sh"
# shellcheck source=/dev/null
source "$LIB/wg.sh"
# shellcheck source=/dev/null
source "$LIB/ovpn.sh"

HTDOCS="${AVPN_HTDOCS:-/var/lib/arena-vpn/www}"
RUNTIME="$AVPN_STATE/portal"
FILES_DIR="$HTDOCS/files"
mkdir -p "$RUNTIME" "$FILES_DIR" 2>/dev/null || true

# ---------------- HTTP output ----------------
hdr() { printf '%s\r\n' "$1"; }
begin_json() {
  local status=${1:-}
  if [[ -n $status ]]; then printf 'Status: %s\r\n' "$status"; fi
  hdr "Content-Type: application/json; charset=utf-8"
  hdr "Cache-Control: no-store"
  hdr "X-Content-Type-Options: nosniff"
  hdr "Referrer-Policy: no-referrer"
  hdr "X-Frame-Options: DENY"
  printf '\r\n'
}
json_ok() {
  begin_json
  printf '{"ok":true%s}\n' "${1:-}"
  exit 0
}
json_error() {
  begin_json "${1}"
  printf '{"ok":false,"error":"%s"}\n' "$(json_escape "$2")"
  exit 0
}

# ---------------- request helpers ----------------
method() { printf '%s' "${REQUEST_METHOD:-GET}"; }
qs_get() {
  printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | awk '{gsub(/\+/," ");print}'
}
read_body() {
  local len=${CONTENT_LENGTH:-0}
  [[ $len =~ ^[0-9]+$ ]] || return 0
  ((len > 0 && len <= 65536)) || return 0
  dd bs=1 count="$len" 2>/dev/null
}
# อ่านค่า string จาก JSON แบบง่าย ไม่ต้องพึ่ง jq
json_get() {
  printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}
client_ip() { printf '%s' "${REMOTE_ADDR:-unknown}" | tr -cd '[:xdigit:].:'; }

build_packages() { # build_packages <name>
  peer_render_files "$1" 2>/dev/null || true
  local dir="$FILES_DIR" name=$1 ip priv proto content
  mkdir -p "$dir" 2>/dev/null || true
  ip="$(peer_field "$name" 2)"
  priv="$(cat "$AVPN_PEERS_DIR/$name/wg-private.key" 2>/dev/null || true)"
  if [[ -n $priv && -n $ip ]]; then
    content="$(wg_render_client "$name" "$ip" "$priv" 2>/dev/null || true)"
    [[ -n $content ]] && { printf '%s\n' "$content" >"$dir/$name.conf"; chmod 600 "$dir/$name.conf"; }
  fi
  for proto in tcp udp; do
    content="$(ovpn_render_client "$name" "$proto" 2>/dev/null || true)"
    [[ -n $content ]] && { printf '%s\n' "$content" >"$dir/$name-$proto.ovpn"; chmod 600 "$dir/$name-$proto.ovpn"; }
  done
}

# ---------------- auth ----------------
AUTH_FILE="$RUNTIME/auth"
auth_ok() {
  local user="${REMOTE_USER:-}" pass="${REMOTE_PASSWORD:-}" dec
  [[ -f $AUTH_FILE ]] || return 1
  if [[ -z $user && -n ${HTTP_AUTHORIZATION:-} ]]; then
    dec="$(printf '%s' "${HTTP_AUTHORIZATION#Basic }" | base64 -d 2>/dev/null)" || return 1
    user="${dec%%:*}"
    pass="${dec#*:}"
  fi
  [[ -n $user ]] || return 1
  local expected_u expected_p
  expected_u="$(cut -f1 "$AUTH_FILE")"
  expected_p="$(cut -f2 "$AUTH_FILE")"
  [[ $user == "$expected_u" && $pass == "$expected_p" ]]
}

require_auth() {
  local ip n f
  is_true "${AVPN_PORTAL_AUTH_DISABLED:-0}" && return 0
  ip="$(client_ip)"
  f="$RUNTIME/fail-$ip"
  n="$(cat "$f" 2>/dev/null || echo 0)"
  [[ $n =~ ^[0-9]+$ ]] || n=0
  ((n > 3)) && sleep 2
  ((n > 8)) && sleep 5
  if auth_ok; then
    rm -f "$f"
    return 0
  fi
  echo $((n + 1)) >"$f" 2>/dev/null || true
  printf 'Status: 401\r\n' 
  hdr 'WWW-Authenticate: Basic realm="Arena VPN Portal", charset="UTF-8"'
  begin_json
  printf '{"ok":false,"error":"ต้องเข้าสู่ระบบ"}\n'
  exit 0
}

# ---------------- peer helpers ----------------

peer_json() { # <name> — ข้อมูลครบของอุปกรณ์ 1 ตัว
  local name=$1 row ip created status note ovcn idx
  row="$(awk -F'\t' -v n="$name" '$1==n{print; exit}' "$AVPN_PEERS_TSV")"
  [[ -n $row ]] || return 1
  IFS=$'\t' read -r _ ip _ _ ovcn idx created status note <<<"$row"
  local hs=0 rx=0 tx=0 online=false endpoint="" live
  live="$(wg_live_peers 2>/dev/null | awk -F'\t' -v n="$name" '$1==n{print; exit}')"
  if [[ -n $live ]]; then
    endpoint="$(printf '%s' "$live" | cut -f2)"
    hs="$(printf '%s' "$live" | cut -f3)"
    rx="$(printf '%s' "$live" | cut -f4)"
    tx="$(printf '%s' "$live" | cut -f5)"
    [[ $hs =~ ^[0-9]+$ ]] || hs=0
    ((hs > 0)) && (($(date +%s) - hs < 180)) && online=true
  fi
  printf '{"name":"%s","ip":"%s","status":"%s","created":%s,"note":"%s","online":%s,"lastHandshake":%s,"rx":%s,"tx":%s,"endpoint":"%s","ovpnCn":"%s","ovpnIndex":%s,"links":{"wg":"/api/download?id=%s&type=wg","ovpnTcp":"/api/download?id=%s&type=ovpn-tcp","ovpnUdp":"/api/download?id=%s&type=ovpn-udp"}}' \
    "$(json_escape "$name")" "$(json_escape "$ip")" "$(json_escape "${status:-unknown}")" "${created:-0}" \
    "$(json_escape "${note:-}")" "$online" "$hs" "${rx:-0}" "${tx:-0}" "$(json_escape "$endpoint")" \
    "$(json_escape "$ovcn")" "${idx:-0}" "$name" "$name" "$name"
}

peers_json() {
  local out="[" first=1 name
  while IFS=$'\t' read -r name _; do
    [[ -z $name ]] && continue
    ((first)) || out+=","
    first=0
    out+="$(peer_json "$name")"
  done < <(peer_any_rows)
  printf '%s]' "$out"
}

# ---------------- routes ----------------
route_health() {
  begin_json
  printf '{"ok":true,"version":"%s"}\n' "$AVPN_VERSION"
  exit 0
}

route_session() {
  local host led_peers
  host="$(public_host 2>/dev/null || echo unknown)"
  local online total
  online="$(cat "$AVPN_STATE/portal/last-online" 2>/dev/null || echo 0)"
  total="$(peer_count)"
  begin_json
  printf '{"ok":true,"version":"%s","host":"%s","wgPort":%s,"ovpnPort":%s,"peers":%s,"counts":{"total":%s,"online":%s}}\n' \
    "$AVPN_VERSION" "$(json_escape "$host")" "$AVPN_WG_PORT" "$AVPN_OVPN_PORT" \
    "$(peers_json)" "$total" "$total"
}

route_status() {
  load_env
  local wg ov dns fw host
  wg="$(wg_status_summary)"
  ov="$(ovpn_live_clients | wc -l | tr -d ' ')"
  dns="$(systemd_available && svc_active dnsmasq && echo up || echo down)"
  fw="$(iptables -S 2>/dev/null | grep -q MASQUERADE && echo up || echo down)"
  host="$(public_host 2>/dev/null || echo unknown)"
  local ssh_ports
  ssh_ports="$(ss -ltnp 2>/dev/null | awk '/sshd/{print $4}' | sed 's/.*://' | sort -un | paste -sd, -)"
  begin_json
  printf '{"ok":true,"server":{"host":"%s","version":"%s"},"services":{"wireguard":"%s","openvpnClients":%s,"dns":"%s","firewall":"%s","ssh":"%s"},"config":{"wgPort":%s,"ovpnPort":%s,"portalPort":%s,"mtu":%s,"maxClients":%s}}\n' \
    "$(json_escape "$host")" "$AVPN_VERSION" "$(json_escape "$wg")" "$ov" "$dns" "$fw" \
    "$(json_escape "${ssh_ports:-none}")" "$AVPN_WG_PORT" "$AVPN_OVPN_PORT" "$AVPN_PORTAL_PORT" \
    "$AVPN_MTU" "$AVPN_MAX_CLIENTS"
}

route_peers() { begin_json; printf '{"ok":true,"peers":%s}\n' "$(peers_json)"; exit 0; }

route_peer_create() {
  local body name note rc=0
  body="$(read_body)"
  name="$(json_get "$body" name | tr -cd 'a-z0-9_-')"
  note="$(json_get "$body" note | tr -cd '[:alnum:] ._-' | cut -c1-60)"
  valid_peer_name "$name" || json_error 400 "ชื่ออุปกรณ์ใช้ a-z 0-9 _ - เท่านั้น (สูงสุด 32 ตัว)"
  peer_exists "$name" && json_error 409 "มีชื่ออุปกรณ์นี้แล้ว"
  (($(peer_count) < AVPN_MAX_CLIENTS)) || json_error 429 "เต็มจำนวนแล้ว (สูงสุด $AVPN_MAX_CLIENTS)"
  peer_new "$name" "$note" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) ;;
    2) json_error 400 "ชื่อไม่ถูกต้อง" ;;
    3) json_error 409 "มีชื่ออุปกรณ์นี้แล้ว" ;;
    4) json_error 429 "IP ในอุโมงค์เต็ม" ;;
    *) json_error 500 "สร้างอุปกรณ์ไม่สำเร็จ (รหัส $rc) — ดู log ที่ /var/log/arena-vpn" ;;
  esac
  wg_apply >/dev/null 2>&1 || true
  ovpn_write_ccd 2>/dev/null; ovpn_apply >/dev/null 2>&1 || true
  build_packages "$name" >/dev/null 2>&1 || true
  begin_json
  printf '{"ok":true,"peer":%s}\n' "$(peer_json "$name")"
  exit 0
}

route_peer_action() { # /revoke /delete /refresh
  local rest="${1#/}" name action
  name="${rest%%/*}"
  action="${rest#*/}"
  [[ $name =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || json_error 400 "ชื่อไม่ถูกต้อง"
  peer_exists "$name" || json_error 404 "ไม่พบอุปกรณ์"
  export AVPN_ALLOW_NONROOT="${AVPN_ALLOW_NONROOT:-0}" AVPN_ETC AVPN_STATE AVPN_ENV_FILE \
    AVPN_PEERS_DIR AVPN_PEERS_TSV AVPN_WG_DIR AVPN_OVPN_DIR AVPN_OVPN_LOG_DIR AVPN_PUBLIC_HOST
  case "$action" in
    revoke)
      "$AVPN_BIN" peer revoke "$name" 2>"$RUNTIME/last-action.log" || json_error 500 "เพิกถอนไม่สำเร็จ: $(tail -1 "$RUNTIME/last-action.log")"
      json_ok
      ;;
    delete)
      "$AVPN_BIN" peer delete "$name" --yes 2>"$RUNTIME/last-action.log" || json_error 500 "ลบไม่สำเร็จ: $(tail -1 "$RUNTIME/last-action.log")"
      json_ok
      ;;
    refresh)
      "$AVPN_BIN" peer refresh "$name" 2>"$RUNTIME/last-action.log" || json_error 500 "สร้างใหม่ไม่สำเร็จ: $(tail -1 "$RUNTIME/last-action.log")"
      build_packages "$name" >/dev/null 2>&1 || true
      json_ok
      ;;
    *) json_error 400 "ไม่รู้จักคำสั่ง" ;;
  esac
}

route_download() {
  local id type file
  id="$(qs_get id)"
  type="$(qs_get type)"
  file="$(qs_get file)"
  if [[ -z $file ]]; then
    valid_peer_name "$id" || json_error 400 "ไม่รู้จักอุปกรณ์"
    peer_exists "$id" || json_error 404 "ไม่พบอุปกรณ์"
    build_packages "$id" >/dev/null 2>&1 || true
    case "$type" in
      wg) file="$id.conf" ;;
      ovpn-tcp) file="$id-tcp.ovpn" ;;
      ovpn-udp) file="$id-udp.ovpn" ;;
      *) json_error 400 "ไม่รู้จักชนิดไฟล์" ;;
    esac
  else
    case "$file" in
      host-info.txt | emergency.txt) ;;
      *) json_error 400 "ไฟล์นี้ไม่มีในระบบ" ;;
    esac
  fi
  local src="$FILES_DIR/$file"
  [[ -f $src ]] || json_error 404 "ไม่พบไฟล์ — กดสร้างอุปกรณ์ใหม่ก่อน"
  printf 'Content-Type: application/octet-stream\r\n'
  printf 'Content-Disposition: attachment; filename="%s"\r\n' "$file"
  printf 'Cache-Control: no-store\r\n\r\n'
  cat "$src"
  exit 0
}

route_qr() {
  local id
  id="$(qs_get id)"
  valid_peer_name "$id" || json_error 400 "ไม่รู้จักอุปกรณ์"
  peer_exists "$id" || json_error 404 "ไม่พบอุปกรณ์"
  if ! have qrencode; then
    begin_json
    printf '{"ok":false,"error":"ยังไม่ได้ติดตั้ง qrencode","svg":null}\n'
    exit 0
  fi
  # สร้าง config ชั่วคราวในหน่วยความจำ (ไม่เขียนไฟล์) แล้วแปลงเป็น SVG
  local cfg svg
  cfg="$(wg_render_client "$id" "$(peer_field "$id" 2)" "$(cat "$AVPN_PEERS_DIR/$id/wg-private.key" 2>/dev/null)" 2>/dev/null)"
  if [[ -z $cfg ]]; then
    begin_json
    printf '{"ok":false,"error":"สร้าง config ไม่ได้","svg":null}\n'
    exit 0
  fi
  svg="$(printf '%s' "$cfg" | qrencode -t SVG -o - -r 1 2>/dev/null || true)"
  begin_json
  if [[ -z $svg ]]; then
    printf '{"ok":false,"error":"สร้าง QR ไม่สำเร็จ","svg":null}\n'
  else
    printf '{"ok":true,"svg":%s}\n' "$(json_escape "$svg")"
  fi
  exit 0
}

route_emergency() {
  local host ports="22"
  host="$(public_host 2>/dev/null || echo your-server-ip)"
  local p
  for p in ${AVPN_SSH_FALLBACK_PORTS:-}; do ports="$ports,$p"; done
  begin_json
  printf '{"ok":true,"host":"%s","sshPorts":"%s","wgPort":%s,"ovpnPort":%s,"checklist":%s}\n' \
    "$(json_escape "$host")" "$ports" "$AVPN_WG_PORT" "$AVPN_OVPN_PORT" \
    '["เปิดไฟร์วอลล์คลาวด์ให้พอร์ต UDP '"$AVPN_WG_PORT"' และ TCP '"$AVPN_OVPN_PORT"' ก่อน","เริ่มที่ WireGuard — เบาที่สุดและเร็วที่สุด","ถ้าองค์กร/โรงแรมบล็อก UDP ให้ใช้ OpenVPN TCP 443 (หน้าตาเหมือน HTTPS)","ต่อไม่ได้เลย: เข้า Console ของคลาวด์ แล้วสั่ง arena-vpn doctor --fix","ดาวน์โหลดไฟล์ใหม่จากหน้านี้ทุกครั้งที่ IP เซิร์ฟเวอร์เปลี่ยน"]'
}

route_config() {
  load_env
  begin_json
  printf '{"ok":true,"config":{"publicHost":"%s","wgPort":%s,"ovpnPort":%s,"portalPort":%s,"mtu":%s,"maxClients":%s,"dns":"%s","fallback":"%s","version":"%s"}}\n' \
    "$(json_escape "${AVPN_PUBLIC_HOST}")" "$AVPN_WG_PORT" "$AVPN_OVPN_PORT" "$AVPN_PORTAL_PORT" \
    "$AVPN_MTU" "$AVPN_MAX_CLIENTS" "$AVPN_CLIENT_DNS" "$AVPN_FALLBACK_ENABLED" "$AVPN_VERSION"
}

route_help() {
  begin_json
  printf '{"ok":true,"routes":["/api/session","/api/status","/api/peers","/api/peer/<name>/{revoke,delete,refresh}","/api/download?id=<name>&type={wg,ovpn-tcp,ovpn-udp}","/api/emergency","/api/config","/api/health"]}\n'
}

# ---------------- router ----------------
P="${PATH_INFO:-}"
[[ -z $P || $P == "/" ]] && P="/api/help"
case "$P" in
  /api/health) route_health ;;
esac
require_auth

case "$(method) $P" in
  "GET /api/help") route_help ;;
  "GET /api/session") route_session ;;
  "GET /api/status") route_status ;;
  "GET /api/peers") route_peers ;;
  "GET /api/config") route_config ;;
  "GET /api/emergency") route_emergency ;;
  "GET /api/qr") route_qr ;;
  "GET /api/download") route_download ;;
  "POST /api/peers") route_peer_create ;;
  "POST /api/peer/"*) route_peer_action "${P#/api/peer}" ;;
  *) json_error 404 "ไม่พบคำสั่งนี้" ;;
esac
