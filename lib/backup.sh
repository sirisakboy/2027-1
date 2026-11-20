#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — สำรอง / กู้คืน / ย้ายเครื่อง
#  เก็บทุกอย่างที่ต้องใช้กู้: env, peers registry, คีย์ WireGuard, CA + ใบรับรอง,
#  tls-crypt, กฎ firewall — เข้ารหัสด้วย AES-256 (passphrase)
#  ใช้ย้ายจาก free tier หนึ่ง → อีกเจ้าได้ในคำสั่งเดียว
# ==============================================================================
# shellcheck shell=bash

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/peers.sh"

BACKUP_MAGIC="arena-vpn-backup-v1"

backup_create() {
  local out=${1:-"$AVPN_BACKUP_DIR/arena-vpn-$(date +%Y%m%d-%H%M%S).tar.gz.enc"}
  local pass=${AVPN_BACKUP_PASSPHRASE:-}
  mkdir -p "$(dirname -- "$out")"
  chmod 700 "$(dirname -- "$out")" 2>/dev/null || true

  if [[ -z $pass ]]; then
    [[ -t 0 ]] || die "ต้องระบุ passphrase: AVPN_BACKUP_PASSPHRASE=... arena-vpn backup [path]"
    read -r -s -p "ตั้งรหัสผ่านไฟล์สำรอง: " pass; echo
    local pass2
    read -r -s -p "พิมพ์ซ้ำ: " pass2; echo
    [[ $pass == "$pass2" ]] || die "รหัสไม่ตรงกัน"
    [[ ${#pass} -ge 8 ]] || die "รหัสสั้นเกินไป (อย่างน้อย 8 ตัว)"
  fi

  local tmp work stage
  work="$(mktemp -d)"
  stage="$work/stage"
  tmp="$work/backup.tar.gz"
  mkdir -p "$stage"
  {
    echo "$BACKUP_MAGIC"
    echo "created=$(date -Is)"
    echo "version=$AVPN_VERSION"
    echo "host=$(hostname 2>/dev/null)"
  } >"$stage/MANIFEST"
  printf '\n' >>"$stage/MANIFEST"

  # คัดลอกไฟล์ที่ต้องกู้ลง stage (รักษา path เดิม)
  _stage() { # _stage <abs-path>
    local src=$1
    [[ -e $src ]] || return 0
    local dst="$stage${src}"
    mkdir -p "$(dirname -- "$dst")"
    cp -a "$src" "$dst" 2>/dev/null || true
  }
  _stage "$AVPN_ENV_FILE"
  _stage "$AVPN_PEERS_TSV"
  _stage "$AVPN_PEERS_DIR"
  _stage "$AVPN_ETC/keys"
  _stage "$AVPN_ETC/ca"
  _stage "$AVPN_OVPN_DIR/tls-crypt.key"
  _stage "$AVPN_OVPN_DIR/crl.pem"
  _stage "$AVPN_WG_DIR/$AVPN_WG_IF.conf"
  _stage "$AVPN_STATE/iptables.v4"
  _stage "$AVPN_STATE/ssh-ports"
  _stage "$AVPN_STATE/portal/auth"
  _stage "/etc/ssh/sshd_config.d/10-arena-vpn.conf"

  local count
  count="$(find "$stage" -type f ! -name MANIFEST | wc -l | tr -d ' ')"
  if [[ $count -eq 0 ]]; then
    rm -rf "$work"
    die "ไม่พบข้อมูลให้สำรอง — ติดตั้งก่อน: sudo arena-vpn init"
  fi

  tar -czf "$tmp" -C "$stage" . 2>/dev/null || {
    rm -rf "$work"
    die "สร้างไฟล์สำรองไม่สำเร็จ"
  }
  ok "รวบรวม $count ไฟล์"

  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
    -pass "pass:$pass" -in "$tmp" -out "$out" || {
    rm -rf "$work"
    die "เข้ารหัสไม่สำเร็จ"
  }
  chmod 600 "$out"
  rm -rf "$work"
  ok "สำรองข้อมูลแล้ว: $out ($(du -h "$out" | cut -f1))"
  warn "เก็บไฟล์นี้ไว้นอกเครื่อง (Google Drive/Dropbox ที่ต่อไว้) — และจำรหัสให้ได้"
  printf '%s\n' "$out"
}

backup_restore() {
  local file=${1:-}
  [[ -f $file ]] || die "ระบุไฟล์สำรอง: arena-vpn restore <file.tar.gz.enc>"
  local pass=${AVPN_BACKUP_PASSPHRASE:-}
  if [[ -z $pass ]]; then
    [[ -t 0 ]] || die "ต้องระบุ AVPN_BACKUP_PASSPHRASE"
    read -r -s -p "รหัสผ่านไฟล์สำรอง: " pass; echo
  fi
  local work
  work="$(mktemp -d)"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "pass:$pass" \
    -in "$file" -out "$work/backup.tar.gz" 2>/dev/null || {
    rm -rf "$work"
    die "ถอดรหัสไม่สำเร็จ — รหัสผิดหรือไฟล์เสียหาย"
  }
  tar -tzf "$work/backup.tar.gz" >/dev/null 2>&1 || {
    rm -rf "$work"
    die "ไฟล์สำรองเสียหาย"
  }
  local manifest
  manifest="$(tar -xzOf "$work/backup.tar.gz" ./MANIFEST 2>/dev/null | head -1 || true)"
  [[ -z $manifest ]] && manifest="$(tar -xzOf "$work/backup.tar.gz" MANIFEST 2>/dev/null | head -1 || true)"
  if [[ $manifest != "$BACKUP_MAGIC" ]]; then
    warn "ไม่พบ MANIFEST ที่ตรงรุ่น — จะลองกู้คืนต่อ"
  fi
  confirm "กู้คืนทับข้อมูลปัจจุบัน? (จะเขียนทับ env/คีย์/peers)" || die "ยกเลิก"
  local stage="$work/stage"
  mkdir -p "$stage"
  tar -xzf "$work/backup.tar.gz" -C "$stage" 2>/dev/null || die "แตกไฟล์ไม่สำเร็จ"
  _restore() { # _restore <path ที่ manage>
    local rel=$1
    [[ -e "$stage/$rel" ]] || return 0
    mkdir -p "$(dirname -- "/$rel")"
    cp -a "$stage/$rel/." "/$rel/" 2>/dev/null || cp -a "$stage/$rel" "/$rel" 2>/dev/null || true
  }
  _restore "${AVPN_ENV_FILE#/}"
  _restore "${AVPN_PEERS_TSV#/}"
  _restore "${AVPN_PEERS_DIR#/}"
  _restore "${AVPN_ETC#/}/keys"
  _restore "${AVPN_ETC#/}/ca"
  _restore "${AVPN_OVPN_DIR#/}/tls-crypt.key"
  _restore "${AVPN_OVPN_DIR#/}/crl.pem"
  _restore "${AVPN_WG_DIR#/}/${AVPN_WG_IF}.conf"
  _restore "${AVPN_STATE#/}/iptables.v4"
  _restore "${AVPN_STATE#/}/ssh-ports"
  _restore "${AVPN_STATE#/}/portal/auth"
  _restore "etc/ssh/sshd_config.d/10-arena-vpn.conf"
  rm -rf "$work"
  chmod 600 "$AVPN_ENV_FILE" 2>/dev/null || true
  chmod 700 "$AVPN_ETC" "$AVPN_PEERS_DIR" 2>/dev/null || true
  ok "กู้คืนไฟล์แล้ว — กำลังนำค่ากลับมาใช้"
  apply_all
}

backup_list() {
  mkdir -p "$AVPN_BACKUP_DIR"
  ls -lh "$AVPN_BACKUP_DIR" 2>/dev/null | sed '1d' || true
}

# สำรองอัตโนมัติรายสัปดาห์ (เก็บ 4 ชุดล่าสุด) — ไม่ต้องมีรหัส (ใช้ key file)
backup_schedule() {
  local keyfile="$AVPN_ETC/backup.key"
  if [[ ! -f $keyfile ]]; then
    (umask 077 && openssl rand -base64 32 >"$keyfile")
    chmod 600 "$keyfile"
    ok "สร้างกุญแจสำรองอัตโนมัติ: $keyfile"
  fi
  cat >/etc/systemd/system/arena-vpn-backup.service <<EOF
[Unit]
Description=Arena VPN automatic backup
[Service]
Type=oneshot
Environment=AVPN_BACKUP_PASSPHRASE=$(cat "$keyfile")
Environment=ASSUME_YES=1
ExecStart=/usr/local/bin/arena-vpn backup ${AVPN_BACKUP_DIR}/auto-\$(date +%%Y%%m%%d).tar.gz.enc
EOF
  cat >/etc/systemd/system/arena-vpn-backup.timer <<'EOF'
[Unit]
Description=Arena VPN weekly backup
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemd_available && {
    systemctl daemon-reload >/dev/null 2>&1 || true
    svc enable arena-vpn-backup.timer
    svc start arena-vpn-backup.timer
  }
  ok "ตั้งสำรองอัตโนมัติรายสัปดาห์แล้ว (เก็บใน $AVPN_BACKUP_DIR)"
}
