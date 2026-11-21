#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — Doctor (ตรวจสุขภาพ + ซ่อมเอง)
#  เป้าหมาย: อาการ "ต่อ VPN ไม่ได้" 90% มาจาก 5 สาเหตุนี้ →
#    1) public IP เปลี่ยน  2) ไฟร์วอลล์คลาวด์ปิดพอร์ต  3) service ตาย
#    4) ไม่ได้เปิด IP forwarding/NAT  5) DNS ใน tunnel ผิด
#  arena-vpn doctor --fix จะไล่ซ่อมตามลำดับโดยไม่ทำอะไรพังเพิ่ม
# ==============================================================================
# shellcheck shell=bash

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/peers.sh"
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/wg.sh"
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/ovpn.sh"
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/firewall.sh"
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/dns.sh"
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/failover.sh"
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/platform.sh"

DOC_RESULTS=()
DOC_FAILS=0
DOC_ACTION=0

rec() { # rec <ok|warn|fail> <id> <msg>
  DOC_RESULTS+=("$1|$2|$3")
  case "$1" in
    fail) DOC_FAILS=$((DOC_FAILS + 1)) ;;
  esac
}

port_listening() { # <proto> <port>
  ss -lnu 2>/dev/null | grep -q ":$2 " && return 0
  ss -lnt 2>/dev/null | grep -q ":$2 " && return 0
  return 1
}

doctor_check_env() {
  load_env
  rec ok env "โหลด config จาก $AVPN_ENV_FILE (v$AVPN_VERSION)"
  if [[ -z ${AVPN_PUBLIC_HOST:-} ]]; then
    rec warn env-host "ยังไม่ได้ตั้ง AVPN_PUBLIC_HOST — ถ้า IP เปลี่ยน ไฟล์ client จะค้างที่ IP เก่า"
  else
    rec ok env-host "Endpoint ที่ประกาศไว้: ${AVPN_PUBLIC_HOST}"
  fi
}

doctor_check_public_ip() {
  local old new
  old="$(cat "$AVPN_STATE/public-ip" 2>/dev/null || true)"
  new="$(detect_public_ip 2>/dev/null || true)"
  if [[ -z $new ]]; then
    rec warn ip "ตรวจ public IP ไม่ได้ (อาจถูกจำกัดเน็ตขาออก) — ข้าม"
    return
  fi
  if [[ -z $old ]]; then
    rec ok ip "public IP: $new"
  elif [[ $old == "$new" ]]; then
    rec ok ip "public IP ไม่เปลี่ยน ($new)"
  else
    rec fail ip "public IP เปลี่ยน! เก่า=$old ใหม่=$new → ไฟล์ client ที่แจกไปจะต่อไม่ได้"
    DOC_ACTION=1
  fi
}

doctor_check_services() {
  local svc_name state
  if is_true "${AVPN_SIM_SERVICES:-0}"; then
    rec warn svc "โหมดจำลอง (AVPN_SIM_SERVICES=1) — ข้ามการตรวจ systemd"
    return
  fi
  for svc_name in "wg-quick@$AVPN_WG_IF" "openvpn-server@ovpn-tcp" "openvpn-server@ovpn-udp" dnsmasq arena-vpn-portal; do
    if ! systemd_available; then
      rec warn "svc:$svc_name" "ไม่มี systemd — ข้ามการตรวจ service"
      continue
    fi
    state="$(systemctl is-active "$svc_name" 2>/dev/null || true)"
    case "$state" in
      active) rec ok "svc:$svc_name" "$svc_name ทำงาน" ;;
      inactive | failed) rec fail "svc:$svc_name" "$svc_name $state" ;;
      *) rec warn "svc:$svc_name" "$svc_name สถานะ: ${state:-unknown}" ;;
    esac
  done
}

doctor_check_ports() {
  local tcp_ports=("$AVPN_OVPN_PORT" "$AVPN_PORTAL_PORT") udp_ports=("$AVPN_WG_PORT" "$AVPN_OVPN_PORT")
  local p
  if systemd_available; then
    port_listening udp "${AVPN_WG_PORT}" && rec ok "port:wg" "WireGuard ฟัง UDP ${AVPN_WG_PORT}" ||
      rec fail "port:wg" "ไม่มีใครฟัง UDP ${AVPN_WG_PORT}"
    port_listening tcp "${AVPN_OVPN_PORT}" && rec ok "port:ovpn" "OpenVPN ฟัง TCP ${AVPN_OVPN_PORT}" ||
      rec fail "port:ovpn" "ไม่มีใครฟัง TCP ${AVPN_OVPN_PORT}"
    port_listening tcp "${AVPN_PORTAL_PORT}" && rec ok "port:portal" "พอร์ทัลฟัง TCP ${AVPN_PORTAL_PORT}" ||
      rec warn "port:portal" "พอร์ทัลไม่ได้ฟัง TCP ${AVPN_PORTAL_PORT}"
  fi
  # ตรวจว่า firewall ในเครื่องไม่ได้บล็อก (เฉพาะโหมดเข้มงวด)
  if is_true "$AVPN_HARDENED_FIREWALL"; then
    for p in "${tcp_ports[@]}" "${udp_ports[@]}"; do
      iptables -S INPUT 2>/dev/null | grep -q -- "--dport $p" && rec ok "fw:$p" "ไฟร์วอลล์เปิดพอร์ต $p" ||
        rec fail "fw:$p" "ไฟร์วอลล์เข้มงวดบล็อกพอร์ต $p"
    done
  fi
}

doctor_check_forwarding() {
  local fwd
  fwd="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  [[ $fwd == 1 ]] && rec ok forwarding "IP forwarding เปิด" || { rec fail forwarding "IP forwarding ปิด (VPN ต่อได้แต่ออกเน็ตไม่ได้)"; DOC_ACTION=1; }
  local egress
  egress="$(fw_egress_if)"
  [[ -n $egress ]] && rec ok egress "การ์ดขาออก: $egress" || rec fail egress "หาการ์ดขาออกไม่ได้"
  iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE &&
    rec ok nat "NAT (MASQUERADE) พร้อม" || { rec fail nat "ไม่มีกฎ NAT — client ออกเน็ตไม่ได้"; DOC_ACTION=1; }
}

doctor_check_dns() {
  if ! is_true "$AVPN_DNS_ENABLED"; then
    rec warn dns "ปิด DNS ภายในอุโมงค์ (ใช้ DNS สาธารณะ)"; return
  fi
  if systemd_available && svc_active dnsmasq; then
    if dig +short +time=2 +tries=1 @127.0.0.1 example.com >/dev/null 2>&1; then
      rec ok dns "dnsmasq ตอบ query ได้"
    else
      rec warn dns "dnsmasq ทำงานแต่ทดสอบ query ไม่ได้ (อาจไม่มี dig)"
    fi
  else
    rec fail dns "dnsmasq ไม่ทำงาน"
    DOC_ACTION=1
  fi
}

doctor_check_disk() {
  local used_pct
  used_pct="$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
  if [[ -n $used_pct ]] && ((used_pct >= 90)); then
    rec fail disk "ดิสก์เต็ม ${used_pct}% — เครื่องจะพังทันที"
  elif [[ -n $used_pct ]] && ((used_pct >= 80)); then
    rec warn disk "ดิสก์ใช้ ${used_pct}%"
  else
    rec ok disk "ดิสก์ใช้ ${used_pct:-?}%"
  fi
}

doctor_check_ssh() {
  local ports="$*"
  local p
  for p in ${ports:-22} $(cat "$AVPN_STATE/ssh-ports" 2>/dev/null); do
    if port_listening tcp "$p"; then
      rec ok "ssh:$p" "SSH ฟังพอร์ต $p"
    elif [[ $p == 22 ]]; then
      rec warn "ssh:$p" "SSH ไม่ได้ฟังพอร์ต 22 (ปกติถ้าย้ายพอร์ต)"
    else
      rec warn "ssh:$p" "พอร์ตสำรอง $p ไม่ทำงาน"
    fi
  done
  if is_true "$AVPN_FALLBACK_ENABLED"; then
    [[ -f "$SSHD_DROPIN" ]] && rec ok fallback "ชั้นฉุกเฉิน L1 (SSH หลายพอร์ต) เปิด" ||
      { rec warn fallback "ชั้นฉุกเฉิน L1 ปิดอยู่"; DOC_ACTION=1; }
  fi
}

doctor_check_platform() {
  local p
  p="$(detect_platform)"
  platform_apply_caps "$p"
  rec ok "platform" "ตรวจพบแพลตฟอร์ม: $p"
  local line lvl msg
  while IFS=$'\t' read -r lvl msg; do
    [[ -z $lvl ]] && continue
    rec "$lvl" "platform-$lvl" "$msg"
  done < <(platform_findings "$p")
}

doctor_check_security() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    rec warn ufw "ufw ทำงานอยู่ — อาจทับกฎ iptables ของ Arena VPN (ปิด ufw หรือย้ายกฎ)"
  fi
  if grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config 2>/dev/null ||
    grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    rec warn rootlogin "SSH อนุญาต root login ด้วยรหัสผ่าน — พิจารณาใช้กุญแจเท่านั้น"
  fi
  if ! is_true "$AVPN_BLOCK_IPV6"; then
    rec warn ipv6 "IPv6 ไม่ถูกปิด — เสี่ยง traffic รั่วออกนอกอุโมงค์"
  fi
}

doctor_checks() {
  DOC_RESULTS=(); DOC_FAILS=0; DOC_ACTION=0
  doctor_check_env
  doctor_check_platform
  doctor_check_public_ip
  doctor_check_services
  doctor_check_ports
  doctor_check_forwarding
  doctor_check_dns
  doctor_check_disk
  doctor_check_ssh "${AVPN_SSH_FALLBACK_PORTS:-}"
  doctor_check_security
}

doctor_print() {
  local r
  printf '\n%s╭─ สุขภาพของ %s %s\n' "$C_BOLD" "$(hostname 2>/dev/null || echo server)" "$C_RESET"
  for r in "${DOC_RESULTS[@]}"; do
    local st rest id msg
    st=${r%%|*}; rest=${r#*|}; id=${rest%%|*}; msg=${rest#*|}
    case "$st" in
      ok) printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$msg" ;;
      warn) printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$msg" ;;
      fail) printf '  %s✖%s %s\n' "$C_RED" "$C_RESET" "$msg" ;;
    esac
  done
  printf '%s╰─ %s\n' "$C_BOLD" "$C_RESET"
  if ((DOC_FAILS > 0)); then
    err "พบปัญหา $DOC_FAILS อย่าง"
    return 1
  fi
  ok "ทุกอย่างปกติดี"
  return 0
}

doctor_fix() {
  step "ซ่อมตามลำดับ (ไม่ทำอะไรที่ยังดีอยู่)"
  load_env
  # 1) IP เปลี่ยน → อัปเดตไฟล์ client
  local new old
  old="$(cat "$AVPN_STATE/public-ip" 2>/dev/null || true)"
  new="$(refresh_public_ip 2>/dev/null || true)"
  if [[ -n $new && $old != "$new" ]]; then
    warn "IP เปลี่ยน $old → $new — กำลังสร้างไฟล์ client ใหม่"
    peer_refresh_all
  fi
  # 2) กฎ network
  ip_forward_apply
  fw_apply
  fw_save
  ipv6_apply
  # 3) services
  if systemd_available; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    svc start "wg-quick@$AVPN_WG_IF"
    svc restart "openvpn-server@ovpn-tcp"
    is_true "$AVPN_OVPN_UDP_ALT" && svc restart "openvpn-server@ovpn-udp"
    is_true "$AVPN_DNS_ENABLED" && svc restart dnsmasq
    svc restart arena-vpn-portal
    if is_true "${AVPN_PORTAL_TLS:-1}"; then svc restart arena-vpn-portal-tls; fi
  fi
  # 4) SSH fallback
  is_true "$AVPN_FALLBACK_ENABLED" && failover_apply >/dev/null 2>&1
  ok "ซ่อมเสร็จ — รัน doctor อีกครั้งเพื่อยืนยัน"
}

# สร้างไฟล์ client ใหม่ให้ทุกอุปกรณ์ที่ยัง active (หลัง IP เปลี่ยน)
peer_refresh_all() {
  local name ip
  while IFS=$'\t' read -r name ip _; do
    [[ -z $name ]] && continue
    printf '  • อัปเดต %s (%s)\n' "$name" "$ip" >&2
    peer_regen_files "$name"
  done < <(peer_active_rows | awk -F'\t' '{print $1"\t"$2}')
}
