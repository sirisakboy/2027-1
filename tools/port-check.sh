#!/usr/bin/env bash
# ==============================================================================
#  ตรวจว่าพอร์ต VPN เปิดจริงจากภายนอกหรือไม่ (รันจากเครื่องของคุณ ไม่ใช่บน VM)
#
#  ใช้: bash tools/port-check.sh <IP-หรือ-โดเมน>
#  ต้องมี: nc (netcat) — macOS/Linux มีมาให้ หรือ apt install netcat-openbsd
# ==============================================================================
set -uo pipefail

HOST=${1:-}
if [[ -z $HOST ]]; then
  echo "ใช้: bash tools/port-check.sh <IP-หรือ-โดเมน>" >&2
  echo "ตัวอย่าง: bash tools/port-check.sh 34.87.12.34" >&2
  exit 1
fi

if ! command -v nc >/dev/null 2>&1; then
  echo "ไม่พบ nc — ติดตั้งก่อน: sudo apt install -y netcat-openbsd  (หรือ brew install netcat)" >&2
  exit 1
fi

ok=0
bad=0
check_tcp() {
  local port=$1 name=$2
  if nc -z -w 3 "$HOST" "$port" 2>/dev/null; then
    printf '  \033[32m✔\033[0m %-26s TCP %-6s เปิด\n' "$name" "$port"
    ok=$((ok + 1))
  else
    printf '  \033[31m✖\033[0m %-26s TCP %-6s ปิด/ถูกบล็อก\n' "$name" "$port"
    bad=$((bad + 1))
  fi
}

check_udp() {
  local port=$1 name=$2
  # UDP ตรวจได้ยาก — ถ้าไม่มี ICMP port unreachable กลับมา ถือว่า "น่าจะเปิด"
  if nc -z -u -w 3 "$HOST" "$port" 2>/dev/null; then
    printf '  \033[33m○\033[0m %-26s UDP %-6s ไม่มี ICMP ตอบกลับ (น่าจะเปิด)\n' "$name" "$port"
  else
    printf '  \033[31m✖\033[0m %-26s UDP %-6s ถูกปฏิเสธ/บล็อก\n' "$name" "$port"
  fi
}

echo
echo "  ตรวจพอร์ตของ $HOST"
echo "  ─────────────────────────────────────────────────"
check_tcp 22 "SSH"
check_tcp 2222 "SSH สำรอง"
check_udp 51820 "WireGuard"
check_tcp 443 "OpenVPN TCP / fallback"
check_udp 443 "OpenVPN UDP"
check_tcp 8443 "พอร์ทัล"
echo "  ─────────────────────────────────────────────────"
echo
echo "  ถ้า TCP เปิดแต่ UDP ไม่ขึ้น: cloud firewall ส่วนใหญ่ต้องเพิ่ม UDP rule แยก"
echo "  ถ้าทุกพอร์ตปิด: ตรวจ Security List / VPC Firewall / Security Group ที่หน้าเว็บคลาวด์"
echo
[[ $bad -eq 0 ]] || exit 1
