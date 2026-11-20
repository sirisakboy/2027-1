#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — ชั้นฉุกเฉิน (Emergency Layers)
#  หลักคิด: "ถ้าท่อ VPN ล่ม ต้องยังเข้าถึงเซิร์ฟเวอร์ได้เสมอ"
#   L1 SSH หลายพอร์ต (22 + fallback) — เปิดค้างไว้ตลอด ปิดได้เมื่อมั่นใจ
#   L2 พอร์ตสำรองแบบสุ่ม + สลับสด ๆ ผ่าน cloud serial console
#   L3 คู่มือกู้คืนผ่าน console ของผู้ให้บริการ (Oracle / GCP / AWS)
# ==============================================================================
# shellcheck shell=bash

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

SSHD_DROPIN="/etc/ssh/sshd_config.d/10-arena-vpn.conf"
SSHD_DROPIN_BAK="/etc/ssh/sshd_config.d/10-arena-vpn.conf.bak"
ROTATE_BIN="/usr/local/bin/arena-vpn-rotate-port"
STATE_SSH_PORTS="$AVPN_STATE/ssh-ports"

# พอร์ตที่ sshd กำลังฟังจริง
ssh_listening_ports() {
  ss -ltnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | sort -un | tr '\n' ' '
}

# พอร์ตว่างในช่วงที่กำหนด
pick_free_port() {
  local lo=20000 hi=60000 tries=0 p
  while ((tries < 200)); do
    p=$((RANDOM % (hi - lo + 1) + lo))
    if ! ss -lntu 2>/dev/null | awk '{print $5}' | sed 's/.*://' | grep -qx "$p"; then
      printf '%s' "$p"
      return 0
    fi
    tries=$((tries + 1))
  done
  return 1
}

failover_apply() {
  if ! is_true "$AVPN_FALLBACK_ENABLED"; then
    info "ปิดชั้นฉุกเฉินตามการตั้งค่า (AVPN_FALLBACK_ENABLED=0)"
    return 0
  fi
  have sshd || apt_install openssh-server

  mkdir -p /etc/ssh/sshd_config.d
  local ports="22"
  local p
  for p in ${AVPN_SSH_FALLBACK_PORTS:-}; do
    [[ $p =~ ^[0-9]+$ ]] || continue
    case " $ports " in *" $p "*) continue ;; esac
    ports="$ports $p"
  done
  # พอร์ตสุ่มที่เคยสร้างไว้ (ถ้ามี)
  if [[ -s $STATE_SSH_PORTS ]]; then
    while read -r p; do
      [[ $p =~ ^[0-9]+$ ]] || continue
      case " $ports " in *" $p "*) continue ;; esac
      ports="$ports $p"
    done <"$STATE_SSH_PORTS"
  fi

  {
    echo "# จัดการโดย Arena VPN — SSH หลายพอร์ตเป็นเส้นทางสำรอง (ฉุกเฉิน)"
    echo "# ปิดได้ด้วย: sudo arena-vpn failover disable"
    for p in $ports; do echo "Port $p"; done
  } | sys_write "$SSHD_DROPIN" 644

  # ตรวจ config ก่อน restart — กันเครื่องล็อกตัวเอง
  if [[ ! -s $SSHD_DROPIN ]]; then
    warn "ไม่มีสิทธิ์เขียน $SSHD_DROPIN — ข้ามการตั้ง SSH หลายพอร์ต"
    return 0
  fi
  if ! sshd -t 2>/dev/null; then
    mv -f "$SSHD_DROPIN" "$SSHD_DROPIN.invalid"
    err "sshd config ที่สร้างไม่ผ่านการตรวจ (ดู $SSHD_DROPIN.invalid) — ยกเลิกการเปลี่ยน"
    return 1
  fi

  if systemd_available; then
    svc reload ssh 2>/dev/null || svc restart ssh 2>/dev/null || svc restart sshd
    sleep 1
  fi
  printf 'SSH พร้อมฟังที่พอร์ต: %s\n' "$(ssh_listening_ports)"
  ok "ชั้นฉุกเฉิน L1 พร้อม (SSH หลายพอร์ต)"
}

failover_disable() {
  if [[ -f $SSHD_DROPIN ]]; then
    mv -f "$SSHD_DROPIN" "$SSHD_DROPIN_BAK"
    if sshd -t 2>/dev/null && systemd_available; then
      svc reload ssh 2>/dev/null || svc restart ssh 2>/dev/null || true
    fi
    ok "ปิด SSH หลายพอร์ตแล้ว (ssh กลับไปใช้ค่าเดิม)"
  else
    info "ยังไม่ได้เปิดชั้นฉุกเฉิน L1"
  fi
}

# สลับพอร์ตสำรองใหม่แบบสด ๆ (ใช้เมื่อพอร์ตเดิมถูกบล็อก/throttle)
failover_rotate() {
  local n=${1:-1} i p applied=()
  is_true "$AVPN_FALLBACK_ENABLED" || die "เปิดก่อน: sudo arena-vpn config set AVPN_FALLBACK_ENABLED 1 && sudo arena-vpn apply"
  for ((i = 0; i < n; i++)); do
    p="$(pick_free_port)" || die "หาพอร์ตว่างไม่ได้"
    applied+=("$p")
    echo "$p" >>"$STATE_SSH_PORTS"
  done
  sort -u "$STATE_SSH_PORTS" -o "$STATE_SSH_PORTS"
  failover_apply >/dev/null
  fw_open_port tcp "${applied[@]}" 2>/dev/null || {
    for p in "${applied[@]}"; do fw_open_port tcp "$p"; done
  }
  fw_save >/dev/null 2>&1 || true
  ok "เพิ่มพอร์ต SSH ฉุกเฉินใหม่: ${applied[*]}"
  printf '%s\n' "ทดสอบ: ssh -p ${applied[0]} root@$(public_host)" >&2
  warn "อย่าลืม: กฎไฟร์วอลล์ของผู้ให้บริการคลาวด์ (Security List / VPC Firewall) ต้องเปิดพอร์ตนี้ด้วย"
}

failover_reset_ports() {
  : >"$STATE_SSH_PORTS"
  failover_apply
}

failover_status() {
  load_env
  echo "SSH ปัจจุบันฟังที่: $(ssh_listening_ports)"
  if systemd_available; then
    echo "sshd: $(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo unknown)"
  fi
  if [[ -f $SSHD_DROPIN ]]; then
    echo "ชั้นฉุกเฉิน L1: เปิด (ตามไฟล์ $SSHD_DROPIN)"
  elif [[ -f $SSHD_DROPIN_BAK ]]; then
    echo "ชั้นฉุกเฉิน L1: ปิด"
  else
    echo "ชั้นฉุกเฉิน L1: ยังไม่ติดตั้ง"
  fi
  if [[ -s $STATE_SSH_PORTS ]]; then
    echo "พอร์ตสุ่มสำรอง: $(tr '\n' ' ' <"$STATE_SSH_PORTS")"
  fi
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "ตรวจพบ ufw ทำงานอยู่ — อาจทับกฎ iptables ของ Arena VPN"
  fi
}

# สคริปต์ที่วางไว้ให้เรียกจาก console ได้ง่าย ๆ
failover_install_rotate_bin() {
  sys_write "$ROTATE_BIN" 755 <<'EOS'
#!/bin/bash
# Arena VPN — สลับพอร์ต SSH ฉุกเฉินแบบเร็ว (เรียกจาก cloud serial console ได้)
exec /usr/local/bin/arena-vpn failover rotate "$@"
EOS
}

# ---------- L3: คู่มือกู้คืนผ่าน console ----------
failover_emergency_guide() {
  local cloud
  cloud="$(detect_cloud)"
  cat <<EOF
${C_BOLD}คู่มือกู้คืนเมื่อเข้าเซิร์ฟเวอร์ไม่ได้ (${cloud})${C_RESET}
─────────────────────────────────────────────────────────────
ขั้น 1  เปิด Console ของเครื่อง (ไม่ต้องใช้ SSH)
EOF
  case "$cloud" in
    oracle)
      cat <<EOF
       Oracle Cloud → Compute → Instances → เลือกเครื่อง → Console connection
       → Create local connection → Launch console → login ด้วย user/password ของ OS
       (ถ้ายังไม่ตั้งรหัส: ใช้ cloud-init หรือ mount boot volume ไปตั้งก่อน)
EOF
      ;;
    gcp)
      cat <<EOF
       GCP → Compute Engine → VM instances → เลือกเครื่อง → ปุ่ม SSH → "Open in browser window"
       ถ้า SSH ไม่ได้: Enable serial console แล้วใช้ ปุ่ม "Connect to serial console"
EOF
      ;;
    aws)
      cat <<EOF
       AWS → EC2 → Instances → เลือกเครื่อง → Actions → Monitor and troubleshoot
       → Get system log / EC2 serial console (ต้องเปิดใน account settings ก่อน)
EOF
      ;;
    *)
      cat <<EOF
       เปิด "web console / VNC console / serial console" จากหน้าเว็บของผู้ให้บริการ
       (Oracle, GCP, AWS, Azure, Vultr, Hetzner, DigitalOcean เปิดฟีเจอร์นี้ฟรีทั้งหมด)
EOF
      ;;
  esac
  cat <<EOF

ขั้น 2  ตรวจและซ่อมท่อ VPN ด้วยคำสั่งเดียว
       sudo arena-vpn doctor --fix

ขั้น 3  ถ้าต้องการพอร์ตใหม่ทันที (ยังไม่ต้องมี VPN)
       sudo arena-vpn failover rotate 2

ขั้น 4  ถ้า sshd พังจาก config ที่แก้ไว้
       sudo rm -f $SSHD_DROPIN && sudo systemctl restart ssh

ขั้น 5  ถ้าเครื่องบูตไม่ขึ้น (kernel/ดิสก์เต็ม)
       ตรวจดิสก์: df -h   |   ล้าง log: journalctl --vacuum-size=200M
EOF
}
