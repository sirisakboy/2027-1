#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — WireGuard engine (ช่องทางหลัก)
#  - คีย์/คอนฟิกอยู่ใต้ /etc/arena-vpn + /etc/wireguard
#  - เปลี่ยน peer แล้วใช้ syncconf (ไม่ตัดการเชื่อมต่อของคนอื่น)
# ==============================================================================
# shellcheck shell=bash

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

WG_DIR="${AVPN_WG_DIR:-/etc/wireguard}"
WG_IF="${AVPN_WG_IF:-wg0}"
WG_KEY_DIR="$AVPN_ETC/keys"

wg_pkg_install() {
  apt_install wireguard-tools
  if ! modprobe wireguard 2>/dev/null; then
    warn "โหลดโมดูล wireguard ในเคอร์เนลไม่ได้ — จะใช้ userspace (wireguard-go) แทน"
    apt_install wireguard-go || true
  fi
}

wg_ensure_keys() {
  mkdir -p "$WG_KEY_DIR"
  chmod 700 "$WG_KEY_DIR"
  if [[ ! -s "$WG_KEY_DIR/wg-server.key" ]]; then
    (umask 077 && wg genkey >"$WG_KEY_DIR/wg-server.key")
    wg pubkey <"$WG_KEY_DIR/wg-server.key" >"$WG_KEY_DIR/wg-server.pub"
    ok "สร้างคีย์ WireGuard ของเซิร์ฟเวอร์แล้ว"
  fi
}

wg_server_pub() { cat "$WG_KEY_DIR/wg-server.pub" 2>/dev/null; }

# สร้างคู่คีย์ของอุปกรณ์: คืน "<private>" และเขียน public ลงตัวแปร global
wg_gen_peer_keys() {
  local name=$1 dir priv pub
  dir="$AVPN_PEERS_DIR/$name"
  mkdir -p "$dir"
  chmod 700 "$dir"
  (umask 077 && wg genkey >"$dir/wg-private.key")
  priv="$(cat "$dir/wg-private.key")"
  pub="$(printf '%s\n' "$priv" | wg pubkey)"
  printf '%s\n' "$pub" >"$dir/wg-public.key"
  printf '%s' "$pub"
}

wg_server_conf_text() {
  local egress
  egress="${AVPN_EGRESS_IF:-$(detect_default_iface)}"
  cat <<EOF
# จัดการโดย Arena VPN — ห้ามแก้มือ (ใช้ sudo arena-vpn apply เพื่อสร้างใหม่)
[Interface]
Address = ${AVPN_WG_SERVER_IP}/${AVPN_WG_NET#*/}
ListenPort = ${AVPN_WG_PORT}
PrivateKey = $(cat "$WG_KEY_DIR/wg-server.key")
MTU = ${AVPN_MTU}
SaveConfig = false
EOF

  local name ip pub status
  while IFS=$'\t' read -r name ip pub _ _ _ _ status _; do
    [[ $status == active ]] || continue
    cat <<EOF

[Peer]
# ${name}
PublicKey = ${pub}
AllowedIPs = ${ip}/32
EOF
  done < <(peer_active_rows)
  printf '\n# egress-interface=%s\n' "${egress:-none}"
}

# เขียน server conf + เปิด/รีโหลดอินเทอร์เฟซ
wg_apply() {
  mkdir -p "$WG_DIR"
  chmod 700 "$WG_DIR"
  local tmp="" changed=0
  tmp="$(mktemp)"
  wg_server_conf_text >"$tmp"
  if [[ ! -f "$WG_DIR/$WG_IF.conf" ]] || ! cmp -s "$tmp" "$WG_DIR/$WG_IF.conf"; then
    changed=1
  fi
  install -m 600 "$tmp" "$WG_DIR/$WG_IF.conf"
  rm -f "$tmp"

  if ! systemd_available; then
    warn "ไม่มี systemd — ข้ามการเปิด wg-quick (โหมดทดสอบ)"
    return 0
  fi

  if ! have wg-quick; then
    warn "ไม่พบ wg-quick (wireguard-tools) — ข้ามการเปิดอินเทอร์เฟซ"
    return 0
  fi

  if ! svc_active "wg-quick@$WG_IF"; then
    systemctl enable "wg-quick@$WG_IF" >/dev/null 2>&1 || true
    svc start "wg-quick@$WG_IF"
  elif ((changed == 1)); then
    # syncconf: ใช้ค่าจากไฟล์ โดยไม่ตัด peer ที่กำลังใช้งาน
    if wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") 2>/dev/null; then
      ok "อัปเดต WireGuard แบบสด (syncconf) แล้ว"
    else
      svc restart "wg-quick@$WG_IF"
    fi
  else
    info "WireGuard ไม่มีการเปลี่ยนแปลง"
  fi
  wg_iface_up || warn "wg-quick ยังไม่ทำงาน — ตรวจ: sudo systemctl status wg-quick@$WG_IF"
}

wg_iface_up() {
  [[ -d /sys/class/net/$WG_IF ]]
}

# ข้อมูล peer สด: name<TAB>endpoint<TAB>handshake<TAB>rx<TAB>tx
wg_live_peers() {
  local raw pub end hs rx tx name
  raw="$(wg show "$WG_IF" dump 2>/dev/null)" || return 0
  while IFS=$'\t' read -r pub _ end _ hs rx tx _; do
    [[ -z $pub || $pub == "PrivateKey"* ]] && continue
    name="$(awk -F'\t' -v p="$pub" '$3==p{print $1; exit}' "$AVPN_PEERS_TSV" 2>/dev/null)"
    [[ -n $name ]] || name="(ไม่รู้จัก)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${end:-}" "${hs:-0}" "${rx:-0}" "${tx:-0}"
  done <<<"$raw"
}

wg_status_summary() {
  if wg_iface_up; then
    local total online
    total="$(wg show "$WG_IF" peers 2>/dev/null | wc -l | tr -d ' ')"
    online="$(wg show "$WG_IF" latest-handshakes 2>/dev/null |
      awk -v now="$(date +%s)" '$2>0 && (now-$2)<180{c++} END{print c+0}')"
    printf 'up:%s peers:%s online:%s' "$WG_IF" "$total" "$online"
  else
    printf 'down'
  fi
}

# คอนฟิกฝั่งอุปกรณ์ (ไฟล์เดียวจบ + inline คีย์)
wg_render_client() {
  local name=$1 ip=$2 priv=$3 endpoint dns_line=""
  endpoint="$(public_host 2>/dev/null || echo "SERVER-IP")"
  if is_true "$AVPN_DNS_ENABLED"; then
    dns_line="DNS = ${AVPN_CLIENT_DNS}"
  else
    dns_line="DNS = $(printf '%s' "$AVPN_DNS_UPSTREAMS" | awk '{print $1}')"
  fi
  cat <<EOF
# Arena VPN — อุปกรณ์: ${name}
# ใช้กับแอป WireGuard (Windows/macOS/iOS/Android) หรือ wg-quick (Termux/Linux)
[Interface]
PrivateKey = ${priv}
Address = ${ip}/32
${dns_line}
MTU = ${AVPN_MTU}

[Peer]
PublicKey = $(wg_server_pub)
Endpoint = ${endpoint}:${AVPN_WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}

wg_remove_peer_live() {
  local pub=$1
  wg set "$WG_IF" peer "$pub" remove 2>/dev/null || true
}
