#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — OpenVPN engine (ช่องทางสำรอง / ฉุกเฉิน)
#  - CA แบบ EC P-256 + openssl ca (มี CRL จริง → เพิกถอนอุปกรณ์ได้)
#  - tls-crypt (ซ่อนลายเซ็น OpenVPN จาก DPI)
#  - 2 อินสแตนซ์: TCP 443 (ผ่านไฟร์วอลล์เข้ม) และ UDP 443 (เร็วเมื่อ UDP ผ่าน)
# ==============================================================================
# shellcheck shell=bash

# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

OVPN_DIR="${AVPN_OVPN_DIR:-/etc/openvpn}"
OVPN_SERVER_DIR="$OVPN_DIR/server"
OVPN_CA_DIR="$AVPN_ETC/ca"
OVPN_CCD_TCP="$OVPN_DIR/ccd-tcp"
OVPN_CCD_UDP="$OVPN_DIR/ccd-udp"
OVPN_TC="$OVPN_DIR/tls-crypt.key"
OVPN_LOG_DIR="${AVPN_OVPN_LOG_DIR:-/var/log/openvpn}"

ovpn_pkg_install() {
  apt_install openvpn openssl
}

# ตรวจว่าเครื่องพร้อมสำหรับ OpenVPN จริง (ใช้ใน init / doctor)
ovpn_pkg_ready() {
  have openvpn && have openssl
}

ovpn_ensure_dirs() {
  mkdir -p "$OVPN_CA_DIR/private" "$OVPN_CA_DIR/newcerts" "$OVPN_CA_DIR/issued" \
    "$OVPN_SERVER_DIR" "$OVPN_CCD_TCP" "$OVPN_CCD_UDP" "$OVPN_LOG_DIR" 2>/dev/null || true
  chmod 700 "$OVPN_CA_DIR" "$OVPN_CA_DIR/private"
  chmod 755 "$OVPN_SERVER_DIR"
  [[ -f "$OVPN_CA_DIR/index.txt" ]] || : >"$OVPN_CA_DIR/index.txt"
  [[ -f "$OVPN_CA_DIR/serial" ]] || printf '1000\n' >"$OVPN_CA_DIR/serial"
  [[ -f "$OVPN_CA_DIR/crlnumber" ]] || printf '1000\n' >"$OVPN_CA_DIR/crlnumber"
}

# เขียน openssl.cnf ที่ชี้ path จริง (รองรับ AVPN_ETC ที่ไม่ใช่ /etc/arena-vpn ในเทสต์)
ovpn_write_cnf() {
  local cnf="$OVPN_CA_DIR/openssl.cnf"
  cat >"$cnf" <<EOF
# จัดการโดย Arena VPN
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = $OVPN_CA_DIR
database          = \$dir/index.txt
new_certs_dir     = \$dir/newcerts
certificate       = \$dir/ca.crt
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
private_key       = \$dir/private/ca.key
default_md        = sha256
default_days      = 3650
default_crl_days  = 3650
policy            = policy_any
unique_subject    = no
copy_extensions   = none

[ policy_any ]
commonName = supplied

[ req ]
distinguished_name = req_dn
prompt = no

[ req_dn ]
CN = placeholder

[ server_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ client_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
}

ovpn_gen_ec_key() {
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null
}

ovpn_ca_init() {
  ovpn_ensure_dirs
  if [[ -s "$OVPN_CA_DIR/ca.crt" && -s "$OVPN_CA_DIR/private/ca.key" ]]; then
    return 0
  fi
  info "สร้าง CA (EC P-256) ของ Arena VPN…"
  (umask 077 && ovpn_gen_ec_key >"$OVPN_CA_DIR/private/ca.key")
  openssl req -x509 -new -key "$OVPN_CA_DIR/private/ca.key" -sha256 -days 3650 \
    -subj "/CN=ArenaVPN-CA-$(date +%Y)" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$OVPN_CA_DIR/ca.crt" 2>/dev/null
  ovpn_write_cnf
  openssl ca -gencrl -config "$OVPN_CA_DIR/openssl.cnf" -out "$OVPN_DIR/crl.pem" 2>/dev/null
  ok "สร้าง CA เรียบร้อย"
}

# สร้างคีย์ tls-crypt (ใช้ร่วมทุกอินสแตนซ์)
# รูปแบบ: OpenVPN static key V1 = 2048 บิต (256 ไบต์) แสดงเป็น 32 บรรทัด x 32 hex
ovpn_ensure_tlscrypt() {
  if [[ -s "$OVPN_TC" ]]; then
    return 0
  fi
  mkdir -p "$(dirname -- "$OVPN_TC")"
  if have openvpn; then
    (umask 077 && openvpn --genkey secret "$OVPN_TC")
  else
    {
      printf '#\n# 2048 bit OpenVPN static key\n#\n'
      printf '%s\n' '-----BEGIN OpenVPN Static key V1-----'
      # 512 hex chars -> 32 บรรทัด x 32 ตัวอักษร (ตามฟอร์แมต OpenVPN static key)
      openssl rand 256 | od -An -v -tx1 | tr -d ' \n' | fold -w32
      printf '\n'
      printf '%s\n' '-----END OpenVPN Static key V1-----'
    } >"$OVPN_TC"
    chmod 600 "$OVPN_TC"
  fi
  ok "สร้าง tls-crypt key"
}

# ออกใบรับรอง: ovpn_issue_cert <cn> server|client
ovpn_issue_cert() {
  local cn=$1 kind=$2 work ext out
  ovpn_ca_init
  ovpn_write_cnf
  work="$(mktemp -d)"
  chmod 700 "$work"
  ext="client_ext"
  [[ $kind == server ]] && ext="server_ext"

  (umask 077 && ovpn_gen_ec_key >"$work/$cn.key")
  openssl req -new -key "$work/$cn.key" -subj "/CN=$cn" -out "$work/$cn.csr" 2>/dev/null
  openssl ca -batch -config "$OVPN_CA_DIR/openssl.cnf" -extensions "$ext" \
    -in "$work/$cn.csr" -out "$work/$cn.crt" -notext -days 3650 >/dev/null 2>&1 ||
    die "ออกใบรับรองให้ '$cn' ไม่สำเร็จ"

  install -m 600 "$work/$cn.key" "$OVPN_CA_DIR/issued/$cn.key"
  install -m 644 "$work/$cn.crt" "$OVPN_CA_DIR/issued/$cn.crt"
  rm -rf -- "$work"
  out="$OVPN_CA_DIR/issued/$cn.crt"
  printf '%s' "$out"
}

# เพิกถอน + อัปเดต CRL
ovpn_revoke_cert() {
  local cn=$1 cert
  cert="$OVPN_CA_DIR/issued/$cn.crt"
  ovpn_ca_init
  ovpn_write_cnf
  if [[ -f $cert ]]; then
    openssl ca -batch -config "$OVPN_CA_DIR/openssl.cnf" -revoke "$cert" \
      -crl_reason superseded >/dev/null 2>&1 || true
  fi
  openssl ca -gencrl -config "$OVPN_CA_DIR/openssl.cnf" -out "$OVPN_DIR/crl.pem" 2>/dev/null
  ovpn_reload_all
}

# สร้างใบรับรองฝั่งเซิร์ฟเวอร์ (CN = host)
ovpn_server_cert() {
  local cn
  cn="${AVPN_PUBLIC_HOST:-$(public_host 2>/dev/null || echo arena-vpn)}"
  cn="${cn//[^A-Za-z0-9._-]/_}"
  [[ -f "$OVPN_CA_DIR/issued/$cn.crt" ]] || ovpn_issue_cert "$cn" server >/dev/null
  # เผื่อ host เปลี่ยนภายหลัง — เซิร์ฟเวอร์ใช้ใบเดียวเสมอ
  [[ -f "$OVPN_SERVER_DIR/server.crt" ]] ||
    install -m 644 "$OVPN_CA_DIR/issued/$cn.crt" "$OVPN_SERVER_DIR/server.crt"
  [[ -f "$OVPN_SERVER_DIR/server.key" ]] ||
    install -m 600 "$OVPN_CA_DIR/issued/$cn.key" "$OVPN_SERVER_DIR/server.key"
}

# ข้อความ server.conf ของอินสแตนซ์: ovpn_server_conf_text tcp|udp
ovpn_server_conf_text() {
  local proto=$1 port net mask srv dns ccd name
  if [[ $proto == tcp ]]; then
    port=$AVPN_OVPN_PORT
    net=$AVPN_OVPN_NET
    srv=$AVPN_OVPN_SERVER_IP
    ccd=$OVPN_CCD_TCP
    name="ovpn-tcp"
  else
    port=$AVPN_OVPN_PORT
    net=$AVPN_OVPN_NET2
    srv=$AVPN_OVPN_SERVER_IP2
    ccd=$OVPN_CCD_UDP
    name="ovpn-udp"
  fi
  mask="255.255.255.0"
  # DNS ใน tunnel ชี้ dnsmasq ที่ฟังอยู่ (10.8.0.1) — ใช้ได้ทั้ง 2 อินสแตนซ์
  dns="${AVPN_WG_SERVER_IP}"
  cat <<EOF
# จัดการโดย Arena VPN — $name
port ${port}
proto ${proto}
dev tun-${proto}
topology subnet
server ${net%/*} ${mask}
ifconfig-pool ${net%.*}.200 ${net%.*}.250 ${mask}
ifconfig-pool-persist ${OVPN_LOG_DIR}/ipp-${proto}.txt
push "redirect-gateway def1 bypass-dhcp"
push "route ${AVPN_WG_NET%/*} 255.255.255.0"
push "dhcp-option DNS ${dns}"
push "block-outside-dns"
keepalive 10 60
client-to-client
max-clients ${AVPN_MAX_CLIENTS}
user nobody
group nogroup
persist-key
persist-tun
ca $OVPN_CA_DIR/ca.crt
cert $OVPN_SERVER_DIR/server.crt
key $OVPN_SERVER_DIR/server.key
dh none
tls-crypt $OVPN_TC
crl-verify $OVPN_DIR/crl.pem
client-config-dir $ccd
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
tls-version-min 1.2
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384
mute-replay-warnings
status ${OVPN_LOG_DIR}/status-${proto}.log 15
log-append ${OVPN_LOG_DIR}/${proto}.log
verb 3
mute 20
EOF
  if [[ $proto == udp ]]; then
    printf 'push "explicit-exit-notify 3"\n'
  fi
}

# เขียน CCD ให้ทุก peer active: IP คงที่ = 10.9.x.<host เดียวกับ wg>
ovpn_write_ccd() {
  local name ip status hostnum
  mkdir -p "$OVPN_CCD_TCP" "$OVPN_CCD_UDP"
  find "$OVPN_CCD_TCP" -type f -delete 2>/dev/null || true
  find "$OVPN_CCD_UDP" -type f -delete 2>/dev/null || true
  while IFS=$'\t' read -r name ip _ _ _ _ _ status _; do
    [[ $status == active ]] || continue
    hostnum="${ip##*.}"
    [[ $hostnum -ge 2 && $hostnum -le 254 ]] || continue
    printf 'ifconfig-push %s %s\n' "${AVPN_OVPN_NET%.*}.${hostnum}" "255.255.255.0" >"$OVPN_CCD_TCP/$name"
    printf 'ifconfig-push %s %s\n' "${AVPN_OVPN_NET2%.*}.${hostnum}" "255.255.255.0" >"$OVPN_CCD_UDP/$name"
    chmod 644 "$OVPN_CCD_TCP/$name" "$OVPN_CCD_UDP/$name"
  done < <(peer_active_rows)
}

ovpn_apply() {
  # แพ็กเกจติดตั้งแล้วตอน init — ห้าม apt ซ้ำในทุกการเปลี่ยน peer (จะช้า/ค้าง)
  ovpn_ca_init
  ovpn_ensure_tlscrypt
  ovpn_server_cert
  ovpn_ensure_dirs
  ovpn_write_ccd

  install -m 644 "$OVPN_CA_DIR/ca.crt" "$OVPN_SERVER_DIR/ca.crt"
  if [[ -f "$OVPN_DIR/crl.pem" ]]; then
    install -m 644 "$OVPN_DIR/crl.pem" "$OVPN_SERVER_DIR/crl.pem"
  fi

  local proto f changed
  for proto in tcp udp; do
    if [[ $proto == udp ]] && ! is_true "$AVPN_OVPN_UDP_ALT"; then
      systemctl disable --now openvpn-server@ovpn-udp >/dev/null 2>&1 || true
      continue
    fi
    f="$OVPN_SERVER_DIR/ovpn-$proto.conf"
    changed=0
    ovpn_server_conf_text "$proto" >"$f.tmp"
    if [[ ! -f $f ]] || ! cmp -s "$f.tmp" "$f"; then changed=1; fi
    install -m 600 "$f.tmp" "$f"
    rm -f "$f.tmp"
    if systemd_available && [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      svc enable "openvpn-server@ovpn-$proto"
      if ((changed == 1)) && svc_active "openvpn-server@ovpn-$proto"; then
        svc restart "openvpn-server@ovpn-$proto"
      else
        svc start "openvpn-server@ovpn-$proto"
      fi
    fi
  done
}

ovpn_reload_all() {
  systemd_available || return 0
  local proto
  for proto in tcp udp; do
    svc_active "openvpn-server@ovpn-$proto" && svc restart "openvpn-server@ovpn-$proto"
  done
}

# เนื้อหาไฟล์ .ovpn สำหรับอุปกรณ์ (inline ทุกอย่าง = ไฟล์เดียวจบ)
ovpn_render_client() {
  local name=$1 proto=${2:-tcp} port=$AVPN_OVPN_PORT endpoint cn
  endpoint="$(public_host 2>/dev/null || echo "SERVER-IP")"
  # CN จริงอยู่ในทะเบียน peers (คอลัมน์ 5) — กันพลาดถ้าตั้งชื่อ CN แบบอื่น
  cn="$(awk -F'\t' -v n="$name" '$1==n{print $5; exit}' "$AVPN_PEERS_TSV" 2>/dev/null)"
  [[ -n $cn ]] || cn="client-$name"
  cat <<EOF
# Arena VPN — ${name} (${proto^^} ${port})
# ใช้กับแอป OpenVPN Connect / openvpn (Termux) — ไฟล์เดียวจบ ไม่ต้องมีไฟล์อื่น
client
dev tun
proto ${proto}
remote ${endpoint} ${port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
keepalive 10 60
verb 3
<ca>
$(cat "$OVPN_CA_DIR/ca.crt")
</ca>
<cert>
$(cat "$OVPN_CA_DIR/issued/$cn.crt")
</cert>
<key>
$(cat "$OVPN_CA_DIR/issued/$cn.key")
</key>
<tls-crypt>
$(cat "$OVPN_TC")
</tls-crypt>
EOF
}

# สถานะผู้เชื่อมต่อสด: cn<TAB>real<TAB>rx<TAB>tx<TAB>since
ovpn_live_clients() {
  local f proto
  for proto in tcp udp; do
    f="/var/log/openvpn/status-$proto.log"
    [[ -f $f ]] || continue
    awk -v proto="$proto" '
      /^OpenVPN CLIENT LIST/ {inlist=1; next}
      /^ROUTING TABLE/ {inlist=0}
      inlist && NR>3 && $1 != "Common" && NF>=4 {
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, proto
      }' "$f"
  done
}

ovpn_status_summary() {
  local n
  n="$(ovpn_live_clients | wc -l | tr -d ' ')"
  printf 'clients:%s' "$n"
}
