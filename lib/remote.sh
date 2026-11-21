#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — โหมด "เครื่องควบคุม" (สำหรับ Google Cloud Shell / เครื่องที่ไม่มี TUN)
#
#  Cloud Shell ไม่มี /dev/net/tun และไม่มี inbound port → รัน VPN server ไม่ได้
#  แต่ใช้งานเป็น "รีโมตคอนโทรล" ของ VM จริงได้ดีมาก:
#
#     1) remote exec   — สั่งคำสั่ง arena-vpn บน VM ผ่าน SSH (ไม่ต้องเปิด terminal ค้าง)
#     2) proxy socks5  — เปิด SOCKS5 ผ่าน SSH tunnel → ใช้เน็ตของ VPN โดยไม่ต้องมี TUN
#     3) bootstrap     — ติดตั้ง Arena VPN บน VM ใหม่จาก Cloud Shell ในคำสั่งเดียว
# ==============================================================================
# shellcheck shell=bash

REMOTE_PROXY_PORT_DEFAULT=1080
REMOTE_PROXY_PID="$AVPN_STATE/proxy.pid"
REMOTE_PROXY_LOG="$AVPN_STATE/proxy.log"

# ---------- ตรวจ SSH client ----------
remote_require_ssh() {
  have ssh || die "ไม่พบ ssh — ติดตั้ง: apt-get install -y openssh-client"
}

# แยก "user@host" และพอร์ต:  remote_parse <target> [--port N]
remote_parse() {
  REMOTE_TARGET=$1
  REMOTE_PORT=${2:-22}
  REMOTE_IDENTITY=${3:-}
  [[ $REMOTE_TARGET == *@* ]] || REMOTE_TARGET="root@$REMOTE_TARGET"
}

# เตรียมอาร์เรย์ SSH options ไว้ใน REMOTE_SSH_OPTS (ใช้ได้กับทุกคำสั่ง)
remote_ssh_opts() {
  REMOTE_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
  [[ -n ${REMOTE_IDENTITY:-} ]] && REMOTE_SSH_OPTS+=(-i "$REMOTE_IDENTITY")
  [[ ${REMOTE_PORT:-22} != 22 ]] && REMOTE_SSH_OPTS+=(-p "$REMOTE_PORT")
  return 0
}

# ---------- 1) remote exec ----------
# ใช้: arena-vpn remote <user@host> <คำสั่ง arena-vpn...>
cmd_remote() {
  local target=${1:-}; shift || true
  [[ -n $target ]] || die "ใช้: arena-vpn remote <user@host> [--port N] [--key ไฟล์] <คำสั่ง...>"
  load_env

  local port=${AVPN_REMOTE_PORT:-22} identity="${AVPN_REMOTE_KEY:-}"
  local args=()
  while (($#)); do
    case "$1" in
      --port) port=$2; shift 2 ;;
      --key) identity=$2; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  remote_parse "$target" "$port" "$identity"
  remote_require_ssh
  ((${#args[@]})) || args=(status)

  info "→ ${REMOTE_TARGET}: ${args[*]}"
  remote_ssh_opts

  # ส่งคำสั่งแบบปลอดภัย: quote ทุกอาร์กิวเมนต์
  local quoted="" a
  for a in "${args[@]}"; do
    quoted+=" $(printf '%q' "$a")"
  done
  local out rc
  out="$(ssh "${REMOTE_SSH_OPTS[@]}" "$REMOTE_TARGET" "sudo arena-vpn${quoted}" 2>&1)"
  rc=$?                       # ← ต้องเก็บทันทีหลัง ssh (ไม่ใช่หลัง local)
  printf '%s\n' "$out"
  if ((rc == 0)); then
    ok "เสร็จแล้ว"
  elif [[ $out == *"arena-vpn: command not found"* || $out == *"arena-vpn: not found"* ]]; then
    err "ยังไม่ได้ติดตั้ง Arena VPN บนเครื่องปลายทาง"
    printf '  ติดตั้งก่อนด้วย: %sarena-vpn bootstrap %s%s\n' "$C_BOLD" "$REMOTE_TARGET" "$C_RESET"
  elif [[ $out == *"Permission denied"* ]]; then
    err "SSH เข้าเครื่องปลายทางไม่ได้ (กุญแจ/สิทธิ์)"
    printf '  ตรวจ: ssh -v %s   หรือระบุกุญแจ: --key ~/.ssh/ไฟล์.pem\n' "$REMOTE_TARGET"
  else
    err "ล้มเหลว (ssh exit $rc)"
  fi
  return $rc
}

# ---------- 2) SOCKS5 proxy ผ่าน SSH (ไม่ต้องมี TUN) ----------
# ใช้: arena-vpn proxy start <user@host> [--port 1080] / stop / status
cmd_proxy() {
  local sub=${1:-status}; shift || true
  load_env
  case "$sub" in
    start)
      local target=${1:-}; shift || true
      [[ -n $target ]] || die "ใช้: arena-vpn proxy start <user@host> [--port 1080]"
      local port=$REMOTE_PROXY_PORT_DEFAULT identity="${AVPN_REMOTE_KEY:-}"
      local sshport="${AVPN_REMOTE_PORT:-22}"
      while (($#)); do
        case "$1" in
          --port) port=$2; shift 2 ;;
          --key) identity=$2; shift 2 ;;
          --ssh-port) sshport=$2; shift 2 ;;
          *) shift ;;
        esac
      done
      remote_parse "$target" "$sshport" "$identity"
      remote_require_ssh
      if proxy_running; then
        warn "มี proxy รันอยู่แล้ว (PID $(cat "$REMOTE_PROXY_PID" 2>/dev/null)) — หยุดก่อน: arena-vpn proxy stop"
        return 1
      fi
      mkdir -p "$AVPN_STATE"
      remote_ssh_opts
      # -D = dynamic port forwarding (SOCKS5), -N = ไม่รันคำสั่ง远端, -f = background
      ssh "${REMOTE_SSH_OPTS[@]}" -N -f -D "127.0.0.1:${port}" "$REMOTE_TARGET" 2>"$REMOTE_PROXY_LOG" ||
        die "เปิด SOCKS proxy ไม่สำเร็จ — ดู: $REMOTE_PROXY_LOG"
      # หา PID ของ ssh ที่เพิ่งเปิด
      local pid
      pid="$(pgrep -f -- "-D 127.0.0.1:${port}.*${REMOTE_TARGET}" | head -1)"
      [[ -n $pid ]] && echo "$pid" >"$REMOTE_PROXY_PID"
      sleep 1
      if proxy_running; then
        ok "เปิด SOCKS5 proxy แล้ว → socks5h://127.0.0.1:${port} (ผ่าน ${REMOTE_TARGET})"
        cat <<EOF

  ใช้งาน (เลือกอย่างใดอย่างหนึ่ง)

    # 1. ทั้งเชลล์ (คำสั่งใน shell นี้จะออกผ่าน VPN)
    export ALL_PROXY=socks5h://127.0.0.1:${port}
    curl -s https://ipinfo.io/ip        # ต้องเป็น IP ของ VPN

    # 2. เฉพาะคำสั่งเดียว
    curl --socks5-hostname 127.0.0.1:${port} https://ipinfo.io/ip

    # 3. git ผ่าน proxy
    git -c http.proxy=socks5h://127.0.0.1:${port} clone <repo>
    # หรือทั้ง session: git config --global http.proxy socks5h://127.0.0.1:${port}

    # 4. pip / npm
    pip install --proxy socks5h://127.0.0.1:${port} <pkg>
    npm config set proxy socks5h://127.0.0.1:${port}

  หยุด: arena-vpn proxy stop
EOF
        return 0
      fi
      err "proxy ไม่ขึ้น — ดู log: $REMOTE_PROXY_LOG"
      return 1
      ;;
    stop)
      if proxy_running; then
        local pid
        pid="$(cat "$REMOTE_PROXY_PID" 2>/dev/null)"
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$REMOTE_PROXY_PID"
        ok "หยุด proxy แล้ว"
      else
        info "ไม่มี proxy ที่รันอยู่"
        # เก็บกวาด ssh -D ที่ค้าง
        pkill -f -- "-D 127.0.0.1:${REMOTE_PROXY_PORT_DEFAULT}" 2>/dev/null || true
      fi
      ;;
    status)
      if proxy_running; then
        local pid
        pid="$(cat "$REMOTE_PROXY_PID")"
        ok "proxy ทำงาน (PID $pid)"
        ss -ltnp 2>/dev/null | grep -E ":${REMOTE_PROXY_PORT_DEFAULT}" || true
      else
        info "proxy ไม่ได้ทำงาน"
      fi
      ;;
    test)
      local port=${1:-$REMOTE_PROXY_PORT_DEFAULT}
      local -a urls=("https://ifconfig.me/ip" "https://api.github.com/zen" "https://icanhazip.com")
      if ! proxy_running; then
        err "proxy ไม่ได้ทำงาน — สั่ง: arena-vpn proxy start <user@host>"
        return 1
      fi
      info "ทดสอบ SOCKS5 ที่ 127.0.0.1:${port} (ลอง ${#urls[@]} ปลายทาง) …"
      if ! have curl; then
        warn "ไม่พบ curl — ทดสอบด้วย: curl --socks5-hostname 127.0.0.1:${port} https://ifconfig.me/ip"
        return 1
      fi
      local u body rc=1
      for u in "${urls[@]}"; do
        body="$(curl -sS --max-time 12 --socks5-hostname "127.0.0.1:${port}" "$u" 2>/dev/null)" || continue
        [[ -n $body ]] || continue
        ok "ผ่าน SOCKS5 ได้: ${u} → ${body//$'\n'/ }"
        printf '  %sทดสอบว่าเป็น IP ของ VPN จริง:%s curl -s --socks5-hostname 127.0.0.1:%s https://ifconfig.me/ip\n' \
          "$C_DIM" "$C_RESET" "$port"
        printf '  %sเทียบกับ IP ตรง ๆ:%s curl -s https://ifconfig.me/ip\n' "$C_DIM" "$C_RESET"
        rc=0
        break
      done
      ((rc == 0)) || {
        err "ทุกปลายทางล้มเหลว — proxy อาจตายแล้ว หรือเครื่องปลายทางออกเน็ตไม่ได้"
        printf '  ดู log: %s\n' "$REMOTE_PROXY_LOG"
        tail -5 "$REMOTE_PROXY_LOG" 2>/dev/null | sed 's/^/    /'
      }
      return $rc
      ;;
    *)
      die "proxy: start <user@host> | stop | status | test"
      ;;
  esac
}

proxy_running() {
  local pid
  pid="$(cat "$REMOTE_PROXY_PID" 2>/dev/null || true)"
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

# ---------- 3) bootstrap VM ระยะไกลจาก Cloud Shell ----------
# ใช้: arena-vpn bootstrap <user@host> [--key ไฟล์] [--host โดเมน]
cmd_bootstrap() {
  local target=${1:-}; shift || true
  [[ -n $target ]] || die "ใช้: arena-vpn bootstrap <user@host> [--key ไฟล์]"
  load_env
  local port=${AVPN_REMOTE_PORT:-22} identity="${AVPN_REMOTE_KEY:-}" pubhost=""
  while (($#)); do
    case "$1" in
      --port) port=$2; shift 2 ;;
      --key) identity=$2; shift 2 ;;
      --host) pubhost=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  remote_parse "$target" "$port" "$identity"
  remote_require_ssh
  remote_ssh_opts

  # --host ต้องผ่าน %q ฝั่งเรา แล้วตัดสินใจเรื่อง sudo ฝั่งปลายทาง
  local hostarg=""
  [[ -n $pubhost ]] && hostarg=" --host $(printf '%q' "$pubhost")"

  step "ติดตั้ง Arena VPN บน ${REMOTE_TARGET}"
  # shellcheck disable=SC2029
  ssh "${REMOTE_SSH_OPTS[@]}" "$REMOTE_TARGET" bash -s <<EOF || { err "bootstrap ล้มเหลว"; return 1; }
set -e
export DEBIAN_FRONTEND=noninteractive
# ---- ตรวจ distro ก่อนติดตั้ง (Oracle Linux / RHEL ใช้ dnf ไม่ได้กับสคริปต์นี้) ----
. /etc/os-release 2>/dev/null || true
case "\${ID:-}" in
  debian|ubuntu|raspbian) ;;
  *)
    echo "✖ distro \${PRETTY_NAME:-\${ID:-unknown}} ยังไม่รองรับ — ต้องเป็น Debian 12 / Ubuntu 22.04/24.04"
    echo "  ทางแก้: สร้าง VM ใหม่ด้วยอิมเมจ Ubuntu, หรือเปลี่ยนอิมเมจ Oracle Linux → Ubuntu"
    exit 64
    ;;
esac
# ---- ต้องเป็น sudo ได้ ----
if [ "\$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=; fi
if ! \$SUDO -n true 2>/dev/null; then
  echo "✖ ผู้ใช้ \$(id -un) ใช้ sudo ไม่ได้โดยไม่ถามรหัส — ตั้ง NOPASSWD หรือใช้ root"
  exit 65
fi
if ! command -v git >/dev/null 2>&1; then
  \$SUDO apt-get update -qq && \$SUDO apt-get install -y -qq git curl ca-certificates
fi
if [ ! -d "\$HOME/arena-vpn-src/.git" ]; then
  git clone --depth 1 https://github.com/sirisakboy/2027-1.git "\$HOME/arena-vpn-src"
else
  git -C "\$HOME/arena-vpn-src" pull --ff-only || true
fi
cd "\$HOME/arena-vpn-src"
\$SUDO ./arena-vpn init --portal --yes${hostarg}
EOF
  local rc=$?
  echo
  if ((rc == 0)); then
    ok "ติดตั้งบน ${REMOTE_TARGET} เสร็จแล้ว"
    info "ต่อไป: arena-vpn remote ${REMOTE_TARGET} peer add phone"
    info "หรือเปิด proxy ทันที: arena-vpn proxy start ${REMOTE_TARGET}"
  else
    err "bootstrap ล้มเหลว (exit $rc)"
  fi
  return $rc
}

# ---------- สรุปรวมสำหรับ Cloud Shell ----------
cloudshell_guide() {
  load_env
  cat <<EOF

${C_LIME}${C_BOLD}Cloud Shell ใช้งานเป็น "เครื่องควบคุม" ของ Arena VPN${C_RESET}
${C_DIM}ไม่สามารถรัน VPN server ได้เอง (ไม่มี TUN/inbound port) แต่สั่งงาน VM ได้เต็มรูปแบบ${C_RESET}

  ${C_BOLD}1) ติดตั้ง VPN บน VM ใหม่${C_RESET} — คำสั่งเดียวจบ
     arena-vpn bootstrap <user@vm-ip>

  ${C_BOLD}2) ใช้ VPN โดยไม่ต้องติดตั้ง VPN client${C_RESET} — SOCKS5 ผ่าน SSH
     arena-vpn proxy start <user@vm-ip>
     export ALL_PROXY=socks5h://127.0.0.1:${REMOTE_PROXY_PORT_DEFAULT}
     curl -s https://ipinfo.io/ip      ${C_DIM}# ต้องเป็น IP ของ VM${C_RESET}

  ${C_BOLD}3) สั่งงาน/ตรวจสอบ VM${C_RESET}
     arena-vpn remote <user@vm-ip> status
     arena-vpn remote <user@vm-ip> doctor --fix
     arena-vpn remote <user@vm-ip> peer add laptop
     arena-vpn remote <user@vm-ip> peer export phone /tmp/phone.zip
     # ดาวน์โหลดลงเครื่องจริง: Cloud Shell → ⋮ → Download file → /tmp/phone.zip

  ${C_BOLD}4) เก็บไฟล์ client ขึ้น Google Drive ตรง ๆ${C_RESET}
     gcloud storage cp /tmp/phone.zip gs://<bucket>/arena-vpn/

${C_YELLOW}ข้อจำกัดที่ต้องรู้${C_RESET}
  • Cloud Shell ถูกรีเซ็ตหลังไม่ใช้งาน ~20 นาที → proxy จะหลุด (SSH key ยังอยู่)
  • ดิสก์ $HOME 5 GB คงอยู่ข้าม session; ที่อื่นหายหมด
  • ต้องมี SSH key ของ VM: gcloud compute ssh <vm> จะสร้างให้อัตโนมัติ
EOF
}
