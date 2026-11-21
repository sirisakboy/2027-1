#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — ไฟร์วอลล์ / NAT / เส้นทางขาออก
#  ใช้ iptables (backend nft บน Debian 12) + systemd unit ที่รันซ้ำได้ (idempotent)
# ==============================================================================
# shellcheck shell=bash

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

FW_SVC_UNIT="/etc/systemd/system/arena-vpn-firewall.service"

fw_egress_if() {
  if [[ -n ${AVPN_EGRESS_IF:-} ]]; then
    printf '%s' "$AVPN_EGRESS_IF"
  else
    detect_default_iface
  fi
}

# เพิ่มกฎแบบ idempotent
#   fw_rule <chain> <rule...>          → ใช้ -A (ต่อท้าย)
#   fw_rule_i <chain> <rule...>        → ใช้ -I (แทรกบนสุด)  ← จำเป็นบน Oracle/อิมเมจที่ปิดท้ายด้วย REJECT
fw_rule() {
  fw_rule_at A "$@"
}

fw_rule_i() {
  fw_rule_at I "$@"
}

fw_rule_at() {
  [[ ${EUID:-$(id -u)} -ne 0 ]] && ! is_true "${AVPN_ALLOW_NONROOT:-0}" && return 0
  local op=$1 chain=$2
  shift 2
  if iptables -C "$chain" "$@" 2>/dev/null; then
    return 0
  fi
  if [[ $op == I ]]; then
    # แทรกที่ตำแหน่ง 1 เสมอ เพื่อให้อยู่เหนือ REJECT/DROP ของอิมเมจคลาวด์
    iptables -I "$chain" 1 "$@" 2>/dev/null || true
  else
    iptables -A "$chain" "$@" 2>/dev/null || true
  fi
}

fw_open_port() { # fw_open_port <tcp|udp> <port>
  local proto=$1 port=$2
  # ต้องแทรกบนสุด: อิมเมจ Oracle/Ubuntu ใส่ "-A INPUT -j REJECT" ไว้ท้ายเชน
  fw_rule_i INPUT -p "$proto" --dport "$port" -j ACCEPT
}

# พอร์ต SSH ปัจจุบันจาก sshd ที่กำลังฟัง (fallback: 22)
fw_current_ssh_ports() {
  local ports
  ports="$(ss -ltnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | sort -un | tr '\n' ' ')"
  [[ -n $ports ]] || ports="22"
  printf '%s' "$ports"
}

fw_apply() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]] && ! is_true "${AVPN_ALLOW_NONROOT:-0}"; then
    warn "ไม่มีสิทธิ์ root — ข้ามการตั้งกฎไฟร์วอลล์ (โหมดทดสอบ)"
    return 0
  fi
  if ! have iptables || ! have iptables-save; then
    warn "ไม่พบ iptables ในเครื่อง — ข้ามการตั้งไฟร์วอลล์/NAT (ติดตั้ง: apt-get install -y iptables)"
    return 0
  fi
  local egress
  egress="$(fw_egress_if)"
  [[ -n $egress ]] || die "ตรวจการ์ดเครือข่ายขาออกไม่ได้ — ตั้ง AVPN_EGRESS_IF"
  info "การ์ดขาออก (NAT): $egress"

  # ---------- policy ----------
  if is_true "$AVPN_HARDENED_FIREWALL"; then
    iptables -P INPUT DROP 2>/dev/null || true
    info "โหมดไฟร์วอลล์เข้มงวด: INPUT = DROP (เปิดเฉพาะที่จำเป็น)"
  else
    iptables -P INPUT ACCEPT 2>/dev/null || true
  fi
  iptables -P FORWARD DROP 2>/dev/null || true
  iptables -P OUTPUT ACCEPT 2>/dev/null || true

  # ---------- INPUT: อนุญาตที่จำเป็น ----------
  fw_rule_i INPUT -i lo -j ACCEPT
  fw_rule_i INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  fw_rule_i INPUT -p icmp --icmp-type echo-request -j ACCEPT

  local p
  for p in $(fw_current_ssh_ports) ${AVPN_SSH_FALLBACK_PORTS:-}; do
    [[ $p =~ ^[0-9]+$ ]] && fw_open_port tcp "$p"
  done

  fw_open_port udp "$AVPN_WG_PORT"
  fw_open_port "$AVPN_OVPN_PROTO" "$AVPN_OVPN_PORT"
  if is_true "$AVPN_OVPN_UDP_ALT"; then
    fw_open_port udp "$AVPN_OVPN_PORT"
  fi

  if is_true "$AVPN_PORTAL_ENABLED"; then
    fw_open_port tcp "$AVPN_PORTAL_PORT"
  fi

  if ! is_true "$AVPN_HARDENED_FIREWALL"; then
    # โหมดปกติ: ให้พอร์ตอื่นที่ผู้ใช้เปิดไว้ทำงานได้
    iptables -P INPUT ACCEPT 2>/dev/null || true
  else
    # รับ traffic ที่ initiator มาจาก tunnel ด้วย (เช่น SSH เข้า 10.8.0.1)
    fw_rule_i INPUT -i "$AVPN_WG_IF" -j ACCEPT
    fw_rule_i INPUT -i "tun+" -j ACCEPT
  fi

  # ---------- FORWARD: ระหว่าง tunnel กับอินเทอร์เน็ต ----------
  fw_rule_i FORWARD -i "$AVPN_WG_IF" -o "$egress" -j ACCEPT
  fw_rule_i FORWARD -i "tun+" -o "$egress" -j ACCEPT
  fw_rule_i FORWARD -i "$egress" -o "$AVPN_WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  fw_rule_i FORWARD -i "$egress" -o "tun+" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  # ให้ client VPN คุยกันเอง (ใช้เครื่องในทีมเป็น jump host ได้)
  fw_rule_i FORWARD -i "$AVPN_WG_IF" -o "$AVPN_WG_IF" -j ACCEPT
  fw_rule_i FORWARD -i "tun+" -o "$AVPN_WG_IF" -j ACCEPT
  fw_rule_i FORWARD -i "$AVPN_WG_IF" -o "tun+" -j ACCEPT

  # ---------- NAT ----------
  fw_rule POSTROUTING -t nat -s "$AVPN_WG_NET" -o "$egress" -j MASQUERADE
  fw_rule POSTROUTING -t nat -s "$AVPN_OVPN_NET" -o "$egress" -j MASQUERADE
  fw_rule POSTROUTING -t nat -s "$AVPN_OVPN_NET2" -o "$egress" -j MASQUERADE

  # สร้าง subnet อุโมงค์รับขาเข้า (กรณี service สตาร์ทก่อน wg)
  fw_rule_i INPUT -i "tun+" -p "$AVPN_OVPN_PROTO" --dport "$AVPN_OVPN_PORT" -j ACCEPT

  ok "ไฟร์วอลล์ + NAT พร้อมใช้งาน"
}

fw_save() {
  # เก็บ snapshot ไว้กู้คืน + สร้าง service ที่รันตอนบูต
  mkdir -p "$AVPN_STATE"
  if ! have iptables-save; then
    warn "ไม่พบ iptables-save — ข้ามการบันทึกกฎไฟร์วอลล์"
    return 0
  fi
  iptables-save >"$AVPN_STATE/iptables.v4" 2>/dev/null || true

  sys_write "$FW_SVC_UNIT" 644 <<EOF
[Unit]
Description=Arena VPN firewall & NAT
After=network-online.target
Wants=network-online.target
Before=wg-quick@${AVPN_WG_IF}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/arena-vpn internal firewall-up
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
  systemd_available && svc enable arena-vpn-firewall
  if [[ ${EUID:-$(id -u)} -eq 0 ]] || is_true "${AVPN_ALLOW_NONROOT:-0}"; then
    ok "บันทึกกฎไฟร์วอลล์ + เปิดใช้ตอนบูตแล้ว"
  fi
}

fw_restore() {
  [[ -f "$AVPN_STATE/iptables.v4" ]] || die "ไม่พบไฟล์สำรองกฎไฟร์วอลล์"
  iptables-restore <"$AVPN_STATE/iptables.v4"
  ok "กู้คืนกฎไฟร์วอลล์จาก snapshot แล้ว"
}

# ---------- IPv6 ----------
ipv6_apply() {
  if is_true "$AVPN_BLOCK_IPV6"; then
    sys_write /etc/sysctl.d/99-arena-vpn-ipv6.conf 644 <<'EOF'
# Arena VPN: ปิด IPv6 เพื่อกัน traffic รั่วออกนอกอุโมงค์
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    sysctl -q -p /etc/sysctl.d/99-arena-vpn-ipv6.conf 2>/dev/null || true
    have sysctl && [[ -w /proc/sys/net/ipv6 ]] && ok "ปิด IPv6 แล้ว (กันการรั่วนอกอุโมงค์)"
  else
    rm -f /etc/sysctl.d/99-arena-vpn-ipv6.conf
    info "คง IPv6 ไว้ตามการตั้งค่า"
  fi
}

ip_forward_apply() {
  sys_write /etc/sysctl.d/99-arena-vpn-forward.conf 644 <<'EOF'
# Arena VPN: เปิด IP forwarding สำหรับ NAT ของ VPN
net.ipv4.ip_forward = 1
EOF
  sysctl -q -p /etc/sysctl.d/99-arena-vpn-forward.conf 2>/dev/null || true
}
