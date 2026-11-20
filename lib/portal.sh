#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — พอร์ทัลเว็บ
#  busybox httpd (เบามาก ~1MB, มากับ Debian) + CGI shell
#  TLS ด้วย stunnel (busybox httpd ไม่มี TLS ในตัว)
# ==============================================================================
# shellcheck shell=bash

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

PORTAL_ROOT="${AVPN_HTDOCS_ROOT:-/var/lib/arena-vpn/www}"
PORTAL_RUNTIME="$AVPN_STATE/portal"
PORTAL_CERT_DIR="$AVPN_ETC/portal-tls"
STUNNEL_CONF="/etc/stunnel/arena-vpn.conf"

portal_deps() {
  apt_install busybox-static openssl qrencode
  if is_true "${AVPN_PORTAL_TLS:-1}"; then
    apt_install stunnel4
  fi
}

portal_cert() {
  mkdir -p "$PORTAL_CERT_DIR"
  chmod 700 "$PORTAL_CERT_DIR"
  [[ -s "$PORTAL_CERT_DIR/portal.key" ]] && return 0
  local ip sans host
  ip="$(cat "$AVPN_STATE/public-ip" 2>/dev/null || echo "")"
  host="${AVPN_PUBLIC_HOST:-}"
  sans="DNS:localhost,IP:127.0.0.1"
  is_ipv4 "$ip" && sans+=",IP:$ip"
  if [[ -n $host ]]; then
    if is_ipv4 "$host"; then sans+=",IP:$host"; else sans+=",DNS:$host"; fi
  fi
  (umask 077 && openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
    -keyout "$PORTAL_CERT_DIR/portal.key" -out "$PORTAL_CERT_DIR/portal.crt" \
    -subj "/CN=arena-vpn-portal" \
    -addext "subjectAltName=$sans" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" 2>/dev/null)
  chmod 640 "$PORTAL_CERT_DIR/portal.key"
  chown root:stunnel4 "$PORTAL_CERT_DIR/portal.key" 2>/dev/null || true
  ok "สร้างใบรับรอง TLS ของพอร์ทัลแล้ว (self-signed)"
}

portal_auth_setup() {
  mkdir -p "$PORTAL_RUNTIME"
  chmod 700 "$PORTAL_RUNTIME"
  local user="${AVPN_PORTAL_USER:-admin}" pass="${AVPN_PORTAL_PASS:-}"
  if [[ -f "$PORTAL_RUNTIME/auth" && -z ${AVPN_PORTAL_PASS:-} ]]; then
    return 0
  fi
  [[ -n $pass ]] || pass="$(gen_password 20)"
  printf '%s\t%s\n' "$user" "$pass" >"$PORTAL_RUNTIME/auth"
  chmod 600 "$PORTAL_RUNTIME/auth"
  env_set AVPN_PORTAL_USER "$user"
  env_set AVPN_PORTAL_PASS "$pass"
  ok "ตั้งรหัสผ่านพอร์ทัลแล้ว (user: $user)"
}

portal_deploy_files() {
  mkdir -p "$PORTAL_ROOT/files" "$PORTAL_ROOT/cgi-bin" "$PORTAL_RUNTIME"
  # HTML
  if [[ -f "$AVPN_HOME/portal/www/index.html" ]]; then
    install -m 644 "$AVPN_HOME/portal/www/index.html" "$PORTAL_ROOT/index.html"
  else
    warn "ไม่พบไฟล์หน้าเว็บใน $AVPN_HOME/portal/www — ข้าม"
  fi
  # CGI backend (คัดลอก และชี้ path ให้ถูกกับ AVPN_HOME จริง)
  if [[ -f "$AVPN_HOME/portal/bin/api.sh" ]]; then
    install -m 755 "$AVPN_HOME/portal/bin/api.sh" "$PORTAL_ROOT/cgi-bin/api"
  fi
  # ไฟล์ช่วยเหลือ
  cat >"$PORTAL_ROOT/files/host-info.txt" <<EOF
Arena VPN — ข้อมูลเซิร์ฟเวอร์
────────────────────────────
Host            : $(public_host 2>/dev/null || echo unknown)
WireGuard       : UDP $(load_env; echo "$AVPN_WG_PORT")
OpenVPN TCP     : $(load_env; echo "$AVPN_OVPN_PORT")
พอร์ทัล          : https://$(public_host 2>/dev/null || echo unknown):$(load_env; echo "$AVPN_PORTAL_PORT")
สร้างเมื่อ       : $(date -Is)
EOF
  chmod 644 "$PORTAL_ROOT/files/host-info.txt"
}

portal_units() {
  local httpd_bin="/usr/bin/busybox"
  have busybox || httpd_bin="$(command -v busybox)"
  local port="${AVPN_PORTAL_PORT}"
  local bind="${AVPN_PORTAL_BIND:-0.0.0.0}"
  local listen_addr="127.0.0.1:8080"
  if ! is_true "${AVPN_PORTAL_TLS:-1}"; then
    listen_addr="${bind}:${port}"
  fi

  sys_write /etc/systemd/system/arena-vpn-portal.service 644 <<EOF
[Unit]
Description=Arena VPN portal (busybox httpd + CGI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=AVPN_HOME=${AVPN_HOME}
Environment=AVPN_LIB=${AVPN_HOME}/lib
Environment=AVPN_BIN=/usr/local/bin/arena-vpn
ExecStart=${httpd_bin} httpd -f -p ${listen_addr} -h ${PORTAL_ROOT}
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

  if is_true "${AVPN_PORTAL_TLS:-1}"; then
    mkdir -p /etc/stunnel
    sys_write "$STUNNEL_CONF" 600 <<EOF
; จัดการโดย Arena VPN — TLS terminator ของพอร์ทัล
pid = /run/stunnel-arena-vpn.pid
output = /var/log/stunnel4/arena-vpn.log
debug = 4

[arena-vpn-portal]
accept = ${bind}:${port}
connect = 127.0.0.1:8080
cert = ${PORTAL_CERT_DIR}/portal.crt
key = ${PORTAL_CERT_DIR}/portal.key
sslVersionMin = TLSv1.2
options = NO_SSLv2
options = NO_SSLv3
EOF
    sys_write /etc/systemd/system/arena-vpn-portal-tls.service 644 <<EOF
[Unit]
Description=Arena VPN portal TLS (stunnel)
After=network-online.target arena-vpn-portal.service
Wants=network-online.target
Requires=arena-vpn-portal.service

[Service]
Type=simple
ExecStart=/usr/bin/stunnel4 ${STUNNEL_CONF}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  fi
}

portal_apply() {
  portal_deps
  portal_cert
  portal_auth_setup
  portal_deploy_files
  portal_units
  if systemd_available; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    svc enable arena-vpn-portal
    svc restart arena-vpn-portal
    if is_true "${AVPN_PORTAL_TLS:-1}"; then
      svc enable arena-vpn-portal-tls
      svc restart arena-vpn-portal-tls
    else
      svc disable arena-vpn-portal-tls 2>/dev/null || true
    fi
  fi
  ok "พอร์ทัลพร้อม: $(portal_url)"
}

portal_url() {
  load_env
  local host scheme="https"
  host="$(public_host 2>/dev/null || echo 127.0.0.1)"
  is_true "${AVPN_PORTAL_TLS:-1}" || scheme="http"
  printf '%s://%s:%s' "$scheme" "$host" "${AVPN_PORTAL_PORT}"
}

portal_credentials() {
  local user pass
  user="$(cut -f1 "$PORTAL_RUNTIME/auth" 2>/dev/null)"
  pass="$(cut -f2 "$PORTAL_RUNTIME/auth" 2>/dev/null)"
  printf 'user: %s\npass: %s\n' "${user:-?}" "${pass:-?}"
}

portal_reset_password() {
  local pass
  pass="$(gen_password 20)"
  env_set AVPN_PORTAL_PASS "$pass"
  printf '%s\t%s\n' "${AVPN_PORTAL_USER:-admin}" "$pass" >"$PORTAL_RUNTIME/auth"
  chmod 600 "$PORTAL_RUNTIME/auth"
  if systemd_available; then svc restart arena-vpn-portal; fi
  ok "ตั้งรหัสผ่านพอร์ทัลใหม่แล้ว"
  portal_credentials
}

# ตรวจว่า CGI ทำงานได้จริง (ใช้เป็น health check)
portal_health() {
  load_env
  local url
  url="https://127.0.0.1:${AVPN_PORTAL_PORT}/api/health"
  is_true "${AVPN_PORTAL_TLS:-1}" || url="http://127.0.0.1:${AVPN_PORTAL_PORT}/api/health"
  curl -fsSk --max-time 5 "$url" 2>/dev/null | grep -q '"ok":true'
}
