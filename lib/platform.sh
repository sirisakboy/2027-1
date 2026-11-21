#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — ชั้นแพลตฟอร์ม (Platform layer)
#
#  หลักคิด: "ชื่อคลาวด์" บอกอะไรได้น้อยกว่า "ความสามารถจริงของเครื่อง"
#  จึงแยกเป็น 2 ส่วน:
#     1. detect_platform  → รู้ว่าเป็นอะไร (ไว้แสดงคำแนะนำ/คำสั่ง firewall ที่ถูกต้อง)
#     2. platform_caps    → รู้ว่าทำอะไรได้ (TUN? systemd? public IP? คงทน?)
#
#  รองรับ 4 กลุ่มหลัก:
#     cloudshell  — Google Cloud Shell (ไม่มี TUN, ไม่มี inbound, ชั่วคราว)
#     aws         — AWS EC2 (IMDSv2, Security Group, Elastic IP)
#     oracle      — Oracle Cloud (iptables REJECT ในเครื่อง, idle reclaim)
#     selfhosted  — เซิร์ฟเวอร์ส่วนตัว/โฮมแล็บ (NAT, PPPoE, CGNAT, DDNS)
#   + gcp / azure / container / unknown
# ==============================================================================
# shellcheck shell=bash

# ---------- ตัวแปรระดับโมดูล (ค่าดีฟอลต์) ----------
AVPN_PLATFORM="${AVPN_PLATFORM:-unknown}"
AVPN_HAS_TUN="${AVPN_HAS_TUN:-1}"
AVPN_HAS_SYSTEMD="${AVPN_HAS_SYSTEMD:-1}"
AVPN_HAS_PUBLIC_IP="${AVPN_HAS_PUBLIC_IP:-1}"
AVPN_IS_EPHEMERAL="${AVPN_IS_EPHEMERAL:-0}"

# ---------- ตรวจ N capability ----------
platform_has_tun() {
  [[ -e /dev/net/tun ]] && return 0
  modprobe tun 2>/dev/null || true
  [[ -e /dev/net/tun ]]
}

platform_has_systemd() { [[ -d /run/systemd/system ]] && [[ -d /etc/systemd/system ]]; }

is_cgnat_ip() { # 100.64.0.0/10 (RFC 6598) — ISP ไทยหลายเจ้าใช้
  local ip=$1 a b
  is_ipv4 "$ip" || return 1
  a=${ip%%.*}
  b=${ip#*.}; b=${b%%.*}
  ((a == 100 && b >= 64 && b <= 127))
}

is_private_ip() { # 10/8, 172.16/12, 192.168/16
  local ip=$1 a b
  is_ipv4 "$ip" || return 1
  a=${ip%%.*}
  b=${ip#*.}; b=${b%%.*}
  ((a == 10)) && return 0
  ((a == 172 && b >= 16 && b <= 31)) && return 0
  ((a == 192 && b == 168)) && return 0
  return 1
}

# IP ของการ์ดขาออก (จะรู้ว่าเป็น private/NAT หรือไม่)
egress_local_ip() {
  local iface=${AVPN_EGRESS_IF:-$(detect_default_iface)}
  [[ -n $iface ]] || return 1
  ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

egress_mtu() {
  local iface=${AVPN_EGRESS_IF:-$(detect_default_iface)}
  [[ -n $iface ]] || return 1
  local mtu
  mtu="$(cat "/sys/class/net/$iface/mtu" 2>/dev/null)"
  [[ $mtu =~ ^[0-9]+$ ]] && printf '%s' "$mtu"
}

# ---------- ตรวจจับแพลตฟอร์ม ----------
# ลำดับสำคัญ: ตรวจ "สภาพแวดล้อม" ก่อน (Cloud Shell/container) แล้วค่อยตรวจ metadata
detect_platform() {
  # 1) Google Cloud Shell — env var ที่ Google ตั้งให้เสมอ
  if [[ ${CLOUD_SHELL:-} == true ]] || [[ -n ${DEVSHELL_PROJECT_ID:-} ]] ||
    grep -qi cloudshell /proc/1/cgroup 2>/dev/null ||
    [[ -f /google/devshell/bashrc ]] 2>/dev/null; then
    echo cloudshell
    return
  fi

  # 2) container (ไม่มี systemd หรือ pid1 เป็น process ที่ไม่ใช่ init)
  if [[ ! -d /run/systemd/system ]] && [[ -f /.dockerenv ]]; then
    echo container
    return
  fi

  # 3) metadata ของแต่ละคลาวด์ (ยืนยันตัวตนได้จริง)
  #    Oracle: endpoint เฉพาะ + ต้องใช้ header
  if curl -fsS --max-time 2 -o /dev/null -s -H 'Authorization: Bearer Oracle' \
    "http://169.254.169.254/opc/v2/instance/" 2>/dev/null; then
    echo oracle
    return
  fi

  #    GCP: ต้องมี header Metadata-Flavor เสมอ
  if curl -fsS --max-time 2 -o /dev/null -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/id" 2>/dev/null; then
    echo gcp
    return
  fi

  #    Azure: ต้องมี header Metadata: true
  if curl -fsS --max-time 2 -o /dev/null -H 'Metadata: true' \
    "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 2>/dev/null; then
    echo azure
    return
  fi

  #    AWS: IMDSv2 (session token) ก่อน — AMI ใหม่ปิด IMDSv1 ไว้เป็นค่าเริ่มต้น
  if detect_aws_imds; then
    echo aws
    return
  fi

  # 4) ไม่ใช่คลาวด์ → เซิร์ฟเวอร์ส่วนตัว แต่ต้องแยก "หลัง NAT" ออก
  local iface_ip
  iface_ip="$(egress_local_ip 2>/dev/null || true)"
  if [[ -n $iface_ip ]] && is_private_ip "$iface_ip"; then
    echo selfhosted-nat
    return
  fi
  echo selfhosted
}

detect_aws_imds() {
  local token
  token="$(curl -fsS --max-time 2 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    "http://169.254.169.254/latest/api/token" 2>/dev/null)" || return 1
  [[ -n $token ]] || return 1
  curl -fsS --max-time 2 -o /dev/null -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null
}

# คงชื่อเดิมไว้ใช้กับโค้ดเก่า (failover guide) — คืนชื่อคลาวด์แบบย่อ
detect_cloud() {
  local p
  p="$(detect_platform)"
  case "$p" in
    selfhosted-nat) echo "selfhosted" ;;
    container) echo "unknown" ;;
    *) echo "$p" ;;
  esac
}

# ---------- ตั้งค่าความสามารถของเครื่อง ----------
platform_apply_caps() {
  local p=$1
  AVPN_PLATFORM="$p"

  if platform_has_tun; then AVPN_HAS_TUN=1; else AVPN_HAS_TUN=0; fi
  if platform_has_systemd; then AVPN_HAS_SYSTEMD=1; else AVPN_HAS_SYSTEMD=0; fi

  case "$p" in
    cloudshell)
      AVPN_HAS_TUN=0        # Cloud Shell ไม่ให้ /dev/net/tun
      AVPN_HAS_PUBLIC_IP=0  # ไม่มี inbound port
      AVPN_IS_EPHEMERAL=1   # VM ถูกลบเมื่อ session หมด
      ;;
    container)
      AVPN_HAS_PUBLIC_IP=${AVPN_HAS_PUBLIC_IP:-0}
      ;;
    selfhosted-nat)
      AVPN_HAS_PUBLIC_IP=0  # ต้อง port-forward เอง
      ;;
    *)
      AVPN_HAS_PUBLIC_IP=1
      ;;
  esac
}

# ค่า MTU ที่ปลอดภัย: ใช้ MTU ของการ์ดขาออกลบ overhead แล้ว clamp
platform_mtu() {
  local p=$1 base
  base="$(egress_mtu 2>/dev/null || echo 1500)"
  [[ $base =~ ^[0-9]+$ ]] || base=1500
  case "$p" in
    gcp | cloudshell) echo 1360 ;;                 # GCP ใช้ MTU 1460 → ต้องเผื่อ
    *) local calc=$((base - 80))
       ((calc > 1420)) && calc=1420
       ((calc < 1280)) && calc=1280                # ต่ำสุดที่ IPv4 รับประกันได้
       echo "$calc" ;;
  esac
}

# ชื่ออุปกรณ์อุโมงค์ — Cloud Shell บางรุ่นมี tun0 ถูกใช้แล้ว
platform_tun_name() {
  local p=$1
  case "$p" in
    cloudshell) echo "wg-avpn" ;;
    *) echo "${AVPN_WG_IF:-wg0}" ;;
  esac
}

# ---------- คำแนะนำเฉพาะแพลตฟอร์ม ----------
# พิมพ์คำสั่ง firewall ที่ต้องไปทำ "นอกเครื่อง" + ข้อควรระวัง
platform_firewall_guide() {
  local p=$1 host=${2:-<IP หรือ โดเมน>} wgport=${3:-51820} ovport=${4:-443} portalport=${5:-8443}
  case "$p" in
    gcp)
      cat <<EOF
  ${C_BOLD}Google Cloud — VPC firewall rule${C_RESET} (ต้องทำที่หน้าเว็บ ถ้าไม่ทำ = ต่อไม่ติด)

    gcloud compute firewall-rules create arena-vpn \\
      --allow=udp:${wgport},tcp:${ovport},tcp:${portalport},udp:${ovport} \\
      --source-ranges=0.0.0.0/0 --direction=INGRESS

  หรือ Console → VPC network → Firewall → Create firewall rule
    Targets: All instances · Source IPv4: 0.0.0.0/0
    Protocols/ports: tcp:${ovport},${portalport}  udp:${wgport},${ovport}

  ${C_YELLOW}กับดัก GCP${C_RESET}
    • MTU ของ e2-micro = 1460 → ตั้ง AVPN_MTU=1360 (สคริปต์ตั้งให้แล้ว)
    • Network Service Tier ต้องเป็น Standard (Premium ฟรีแค่ 1 GB/เดือน)
    • Ephemeral IP เปลี่ยนเมื่อ stop/start → ใช้ Static IP หรือโดเมน
EOF
      ;;
    aws)
      cat <<EOF
  ${C_BOLD}AWS — Security Group${C_RESET} (Inbound rules)

    aws ec2 authorize-security-group-ingress --group-id sg-XXXXXXXX \\
      --ip-permissions \\
        IpProtocol=udp,FromPort=${wgport},ToPort=${wgport},IpRanges='[{CidrIp=0.0.0.0/0}]' \\
        IpProtocol=tcp,FromPort=${ovport},ToPort=${ovport},IpRanges='[{CidrIp=0.0.0.0/0}]' \\
        IpProtocol=tcp,FromPort=${portalport},ToPort=${portalport},IpRanges='[{CidrIp=0.0.0.0/0}]'

  หรือ Console → EC2 → Security Groups → Inbound rules → Edit

  ${C_YELLOW}กับดัก AWS${C_RESET}
    • บัญชีใหม่ (หลัง 15 ก.ค. 2025) ไม่มี 750 ชม. ฟรีแล้ว → ใช้เครดิต ~\$200 / 6 เดือน
    • Elastic IP ฟรีเมื่อผูกกับเครื่องที่รันอยู่ — แต่คิดเงินถ้า allocate ค้างไว้ไม่ผูก
    • IMDSv2 เปิดเป็นค่าเริ่มต้น → ถ้าใช้ IMDSv1 ตรวจแพลตฟอร์มจะไม่เจอ (แก้แล้วในเวอร์ชันนี้)
    • NAT Gateway คิดเงินรายชั่วโมง — อย่าสร้างโดยไม่จำเป็น
EOF
      ;;
    oracle)
      cat <<EOF
  ${C_BOLD}Oracle Cloud — Security List / NSG${C_RESET} (Ingress Rules)

    Networking → VCN → Security Lists → Default Security List → Add Ingress Rules
      Source CIDR: 0.0.0.0/0 · IP Protocol: UDP · Destination Port Range: ${wgport}
      Source CIDR: 0.0.0.0/0 · IP Protocol: TCP · Destination Port Range: ${ovport},${portalport}

  ${C_YELLOW}กับดัก Oracle (สำคัญมาก)${C_RESET}
    • ${C_RED}อิมเมจ Oracle Linux/Ubuntu มีกฎ iptables '-A INPUT -j REJECT' อยู่ท้ายเชน${C_RESET}
      กฎที่เรา "append" จะอยู่หลัง REJECT → ไม่เคยถูกใช้
      เวอร์ชันนี้แก้โดยใช้ ${C_BOLD}iptables -I${C_RESET} (แทรกบนสุด) แทน -A แล้ว
    • A1.Flex ที่ CPU/เน็ต/แรม < 20% ติดกัน 7 วัน → ${C_RED}อาจถูกเรียกคืน${C_RESET}
    • Free Tier: "Out of capacity" บ่อย → ลอง AD อื่น/ลดสเปก/อัปเกรด PAYG
    • หลังอัปเกรด PAYG จะได้ 4 OCPU/24 GB คืน (จาก 2/12) และไม่ถูกเรียกคืน
EOF
      ;;
    cloudshell)
      cat <<EOF
  ${C_BOLD}Google Cloud Shell — ${C_RED}ใช้เป็น "เครื่องแม่" ไม่ได้${C_RESET}

  Cloud Shell เป็นคอนเทนเนอร์ชั่วคราว ไม่มี /dev/net/tun และไม่มี inbound port
  → รัน VPN server ในนี้ไม่ได้ (ไม่ใช่ปัญหาการตั้งค่า แต่เป็นข้อจำกัดของแพลตฟอร์ม)

  ${C_BOLD}สิ่งที่ทำได้จริงจาก Cloud Shell${C_RESET}
    1) ${C_BOLD}ควบคุม VM${C_RESET}  — SSH เข้าเครื่องจริงแล้วสั่ง arena-vpn
         arena-vpn remote <user@vm-ip> status
    2) ${C_BOLD}ส่งคำสั่งครั้งเดียว${C_RESET} — ติดตั้ง/ซ่อมบน VM โดยไม่ต้องเปิด terminal ค้าง
         arena-vpn remote <user@vm-ip> init --yes
    3) ${C_BOLD}เปิด SOCKS5 proxy ผ่าน SSH${C_RESET} — ใช้เน็ตของ VPN โดยไม่ต้องมี TUN
         arena-vpn proxy start <user@vm-ip>     # แล้ว export ALL_PROXY=socks5://127.0.0.1:1080
    4) ${C_BOLD}ดาวน์โหลดไฟล์ client${C_RESET} จาก VM มาเก็บ/อัปขึ้น Drive
         arena-vpn remote <user@vm-ip> peer export phone phone.zip
EOF
      ;;
    selfhosted | selfhosted-nat)
      local eip
      eip="$(egress_local_ip 2>/dev/null || echo '?')"
      cat <<EOF
  ${C_BOLD}เซิร์ฟเวอร์ส่วนตัว — ตั้งค่าเราเตอร์/ไฟร์วอลล์${C_RESET}

  IP ภายนอกการ์ดขาออก: ${eip} $( [[ $p == selfhosted-nat ]] && echo "${C_YELLOW}(อยู่หลัง NAT)${C_RESET}" )

  ${C_BOLD}1. Port forwarding ที่เราเตอร์${C_RESET} (ถ้าอยู่หลัง NAT)
       UDP ${wgport}  → ${eip}:${wgport}
       TCP ${ovport}  → ${eip}:${ovport}
       TCP ${portalport} → ${eip}:${portalport}

  ${C_BOLD}2. ไฟร์วอลล์ในเครื่อง${C_RESET}
       # ufw (Ubuntu/Debian ที่เปิด ufw)
       sudo ufw allow ${wgport}/udp; sudo ufw allow ${ovport}/tcp; sudo ufw allow ${portalport}/tcp
       # firewalld (Rocky/Alma/Fedora)
       sudo firewall-cmd --add-port=${wgport}/udp --add-port=${ovport}/tcp --add-port=${portalport}/tcp --permanent
       sudo firewall-cmd --reload
       # raw iptables — Arena VPN จัดการให้แล้ว (ใช้ -I แทรกบนสุด)

  ${C_YELLOW}กับดักเซิร์ฟเวอร์ส่วนตัว${C_RESET}
    • ${C_RED}CGNAT${C_RESET}: ถ้า IP สาธารณะที่เห็นดึงมาได้อยู่ใน 100.64.0.0/10 = ทำ port-forward ไม่ได้
      (พบมากกับไฟเบอร์ AIS/True/3BB บางแพ็กเกจ) → ต้องขอ public IP จาก ISP หรือย้ายไปคลาวด์
    • PPPoE MTU 1492 → tunnel MTU 1412 (สคริปต์คำนวณให้อัตโนมัติจาก MTU การ์ด)
    • IP บ้านเปลี่ยนบ่อย → ใช้ DDNS (DuckDNS/Cloudflare) แล้วตั้ง AVPN_PUBLIC_HOST
    • ถ้าเราเตอร์ทำ NAT loopback ไม่ได้ จะทดสอบจากในบ้านด้วย public IP ไม่ได้
EOF
      ;;
    *)
      cat <<EOF
  เปิดพอร์ตที่ไฟร์วอลล์ของผู้ให้บริการ (หรือเราเตอร์ ถ้าเป็นเครื่องที่บ้าน)
       UDP ${wgport} · TCP ${ovport} · TCP ${portalport}
EOF
      ;;
  esac
}

# ---------- ตรวจสุขภาพเฉพาะแพลตฟอร์ม ----------
# คืนค่าเป็นบรรทัด "ok|warn|fail<TAB>ข้อความ" ให้ doctor นำไปใช้
platform_findings() {
  local p=$1
  case "$p" in
    cloudshell)
      printf 'fail\tCloud Shell ไม่มี /dev/net/tun — รัน VPN server ที่นี่ไม่ได้ (ใช้เป็นเครื่องควบคุมแทน)\n'
      ;;
    oracle)
      # ตรวจกฎ REJECT ที่ท้าย INPUT ซึ่งจะกลืนกฎของเรา
      if iptables -S INPUT 2>/dev/null | grep -qE '^-A INPUT -j (REJECT|DROP)'; then
        local appends
        appends="$(iptables -S INPUT 2>/dev/null | grep -c -- '--dport 51820' || true)"
        printf 'warn\tพบกฎ REJECT/DROP ท้าย INPUT ของอิมเมจ Oracle — Arena VPN ใช้ -I แทรกบนสุดแล้ว (ok) แต่กฎที่คุณเพิ่มเองด้วย -A จะไม่ทำงาน\n'
        : "$appends"
      fi
      ;;
    selfhosted | selfhosted-nat)
      local pub iface_ip
      pub="$(cat "$AVPN_STATE/public-ip" 2>/dev/null || true)"
      iface_ip="$(egress_local_ip 2>/dev/null || true)"
      if [[ -n $pub ]] && is_cgnat_ip "$pub"; then
        printf 'fail\tIP สาธารณะ %s อยู่ในช่วง CGNAT (100.64/10) — port forwarding ทำไม่ได้ ต้องขอ public IP จาก ISP\n' "$pub"
      elif [[ -n $pub && -n $iface_ip ]] && [[ $pub != "$iface_ip" ]]; then
        printf 'warn\tเครื่องอยู่หลัง NAT (%s → %s) — ต้อง port-forward UDP 51820/TCP 443 ที่เราเตอร์\n' "$iface_ip" "$pub"
      fi
      if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        printf 'warn\tufw เปิดใช้งาน — ต้อง ufw allow 51820/udp, 443/tcp, 8443/tcp\n'
      fi
      if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
        printf 'warn\tfirewalld ทำงานอยู่ — ต้อง firewall-cmd --add-port=51820/udp --permanent && --reload\n'
      fi
      ;;
    aws)
      local token
      token="$(curl -fsS --max-time 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
        "http://169.254.169.254/latest/api/token" 2>/dev/null || true)"
      if [[ -n $token ]]; then
        printf 'ok\tIMDSv2 ทำงาน (ตรวจแพลตฟอร์มได้ถูกต้อง)\n'
      else
        printf 'warn\tตรวจ IMDSv2 ไม่ได้ — ถ้าอยู่บน EC2 ให้ตรวจว่าเปิด metadata service ไว้\n'
      fi
      ;;
    gcp)
      local base
      base="$(egress_mtu 2>/dev/null || true)"
      if [[ -n $base ]] && ((base <= 1460)) && ((${AVPN_MTU:-0} >= 1420)); then
        printf 'fail\tMTU ของการ์ด %s แต่ AVPN_MTU=%s — จะเกิดอาการเว็บโหลดค้างครึ่งเดียว (ตั้ง 1360)\n' "$base" "${AVPN_MTU:-?}"
      fi
      ;;
  esac
}
