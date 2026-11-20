#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — DNS ภายในอุโมงค์ (dnsmasq)
#  ทำ 3 อย่าง: แก้ DNS ให้เร็ว/ไม่รั่ว, บล็อกโฆษณาเบา ๆ, เปิดให้ client ใช้ชื่อเครื่องกันได้
# ==============================================================================
# shellcheck shell=bash

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

DNS_CONF="/etc/dnsmasq.d/arena-vpn.conf"
DNS_BLOCKLIST="/etc/arena-vpn/dns-blocklist.txt"
DNS_BLOCKLIST_URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"

dns_install() {
  apt_install dnsmasq
  # Debian: dnsmasq.service ชนกับ systemd-resolved ที่ฟัง 127.0.0.1:53
  # เราไม่ต้องใช้ 53 บน loopback → ปิด resolved แบบไม่ลบ เพื่อให้ dnsmasq ได้พอร์ตที่ต้องการ
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    return 0
  fi
  if systemd_available && systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
    svc disable --now systemd-resolved
    systemd_available && svc mask systemd-resolved
    # คืน resolv.conf ให้ระบบยังแก้ DNS ได้ปกติผ่านดาวน์สตรีมของเรา
    printf 'nameserver %s\n' "${AVPN_DNS_UPSTREAMS%% *}" >/etc/resolv.conf 2>/dev/null || true
  fi
}

dns_write_conf() {
  local listen="127.0.0.1,${AVPN_WG_SERVER_IP},${AVPN_OVPN_SERVER_IP},${AVPN_OVPN_SERVER_IP2}"
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    return 0
  fi
  mkdir -p /etc/dnsmasq.d
  {
    cat <<EOF
# จัดการโดย Arena VPN
# ฟังเฉพาะในอุโมงค์ + loopback (ไม่เปิด DNS resolver ให้คนนอกใช้ฟรี)
listen-address=${listen}
bind-dynamic
no-resolv
no-poll
no-hosts
$(for u in $AVPN_DNS_UPSTREAMS; do printf 'server=%s\n' "$u"; done)cache-size=1000
domain-needed
bogus-priv
# กันการสอบถาม DNS ผ่าน TCP ถูกใช้เป็นช่องโหว่
max-cache-ttl=600
EOF
    if [[ -s $DNS_BLOCKLIST ]]; then
      printf 'addn-hosts=%s\n' "$DNS_BLOCKLIST"
    fi
  } >"$DNS_CONF"
}

dns_fetch_blocklist() {
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL --max-time 20 "$DNS_BLOCKLIST_URL" 2>/dev/null |
      awk '/^0\.0\.0\.0/ {print "0.0.0.0 " $2}' >"$tmp"; then
    warn "ดาวน์โหลด blocklist ไม่ได้ (ข้ามไป — ไม่กระทบ VPN)"
    rm -f "$tmp"
    return 0
  fi
  if [[ $(wc -l <"$tmp") -lt 100 ]]; then
    warn "blocklist ผิดรูป (สั้นเกินไป) — ข้ามการอัปเดต"
    rm -f "$tmp"
    return 0
  fi
  install -m 644 "$tmp" "$DNS_BLOCKLIST"
  rm -f "$tmp"
}

dns_apply() {
  if ! is_true "$AVPN_DNS_ENABLED"; then
    svc disable --now dnsmasq
    return 0
  fi
  dns_install
  dns_write_conf
  if systemd_available; then
    svc enable dnsmasq
    svc restart dnsmasq
  fi
  [[ ${EUID:-$(id -u)} -eq 0 ]] && ok "DNS ภายในอุโมงค์พร้อม (${AVPN_CLIENT_DNS})"
}

dns_status() {
  if systemd_available && svc_active dnsmasq; then
    printf 'up'
  else
    printf 'down'
  fi
}
