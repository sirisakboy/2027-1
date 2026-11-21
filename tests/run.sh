#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — smoke tests
#  รันได้โดยไม่ต้องมี VPN/root จริง: ใช้โฟลเดอร์ชั่วคราว + shim ของ wg
#  ใช้:  bash tests/run.sh
# ==============================================================================
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$ROOT/tests/.work"
PASS=0
FAIL=0
SKIP=0

export NO_COLOR=1
export AVPN_ALLOW_NONROOT=1
export AVPN_ETC="$WORK/etc"
export AVPN_STATE="$WORK/state"
export AVPN_ENV_FILE="$WORK/etc/arena-vpn.env"
export AVPN_PEERS_DIR="$WORK/etc/peers"
export AVPN_PEERS_TSV="$WORK/etc/peers.tsv"
export AVPN_WG_DIR="$WORK/wireguard"
export AVPN_OVPN_DIR="$WORK/openvpn"
export AVPN_OVPN_LOG_DIR="$WORK/log"
export AVPN_HTDOCS_ROOT="$WORK/www"
export AVPN_BACKUP_DIR="$WORK/backups"
export AVPN_PUBLIC_HOST="vpn.test.local"

C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_SK=$'\033[33m'; C_Z=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_NO=""; C_SK=""; C_Z=""; }

pass() { PASS=$((PASS + 1)); printf '  %s✔%s %s\n' "$C_OK" "$C_Z" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  %s✖%s %s\n' "$C_NO" "$C_Z" "$1"; [[ -n ${2:-} ]] && printf '      %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); printf '  %s○%s %s (ข้าม)\n' "$C_SK" "$C_Z" "$1"; }
group() { printf '\n%s▸ %s%s\n' $'\033[1m' "$1" "$C_Z"; }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/etc" "$WORK/state"

# ---------------- shim ของ wg (X25519 จริงถ้ามี cryptography) ----------------
cat >"$WORK/bin/wg" <<'SHIM'
#!/usr/bin/env bash
# shim สำหรับเทสต์: ถ้ามี python cryptography จะคำนวณ pubkey จริง ไม่งั้นใช้ hash
set -u
case "${1:-}" in
  genkey)
    head -c 32 /dev/urandom | base64 -w0
    echo
    ;;
  pubkey)
    key="$(cat)"
    if python3 -c 'import cryptography' 2>/dev/null; then
      printf '%s' "$key" | python3 -c '
import sys, base64, hashlib
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization as s
k = X25519PrivateKey.from_private_bytes(base64.b64decode(sys.stdin.read().strip()))
print(base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode())
'
    else
      printf '%s' "$key" | sha256sum | awk '{print $1}' | head -c 32 | base64 -w0
      echo
    fi
    ;;
  show)
    [[ -f "$WORK_SHIM_STATE" ]] || exit 1
    cat "$WORK_SHIM_STATE"
    ;;
  set) exit 0 ;;
  *) exit 0 ;;
esac
SHIM
chmod +x "$WORK/bin/wg"
export WORK_SHIM_STATE="$WORK/wg-show.txt"
export PATH="$WORK/bin:$PATH"

# ---------------- helpers ----------------
run() { bash "$ROOT/arena-vpn" "$@" 2>&1; }

# ==============================================================================
group "1. โครงสร้างไฟล์"
for f in arena-vpn VERSION README.md lib/common.sh lib/peers.sh lib/wg.sh lib/ovpn.sh \
  lib/firewall.sh lib/dns.sh lib/failover.sh lib/portal.sh lib/doctor.sh lib/backup.sh \
  portal/www/index.html portal/bin/api.sh config/arena-vpn.env.example; do
  [[ -f "$ROOT/$f" ]] && pass "มีไฟล์ $f" || fail "ขาดไฟล์ $f"
done
[[ -x "$ROOT/arena-vpn" ]] && pass "arena-vpn รันได้ (executable)" || fail "arena-vpn ไม่ได้ chmod +x"

group "2. bash syntax"
SYNTAX_FAIL=0
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || { fail "syntax: ${f#"$ROOT"/}"; SYNTAX_FAIL=1; }
done < <(find "$ROOT" -name '*.sh' -o -name 'arena-vpn' | grep -v '/tests/.work/')
[[ $SYNTAX_FAIL == 0 ]] && pass "ทุกสคริปต์ผ่าน bash -n"

group "3. shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x -S error "$ROOT/arena-vpn" "$ROOT"/lib/*.sh "$ROOT/portal/bin/api.sh" >"$WORK/sc.txt" 2>&1; then
    pass "ไม่มี error ระดับสูงจาก shellcheck"
  else
    fail "shellcheck พบปัญหา" "$(head -5 "$WORK/sc.txt")"
  fi
else
  skip "shellcheck (ติดตั้ง: pip install shellcheck-py)"
fi

group "4. CLI พื้นฐาน"
out="$(run version)"
[[ $out == *"$(cat "$ROOT/VERSION")"* ]] && pass "arena-vpn version" || fail "version ผิด" "$out"
out="$(run --help)"
[[ $out == *"peer add"* && $out == *"doctor"* ]] && pass "arena-vpn --help แสดงคำสั่งหลัก" || fail "--help ไม่ครบ"
out="$(run config list)"
[[ -z $out ]] || pass "config list ทำงาน (ยังไม่มีไฟล์ = ว่าง)"
printf 'AVPN_WG_PORT=51999\n' >"$AVPN_ENV_FILE"
out="$(run config get AVPN_WG_PORT)"
[[ $out == "51999" ]] && pass "config get อ่านค่าจาก env ไฟล์" || fail "config get ผิด" "$out"
sed -i 's/51999/51820/' "$AVPN_ENV_FILE"

group "5. สร้างคีย์และอุปกรณ์"
out="$(run peer add laptop)"
[[ $out == *"สร้างแล้ว"* ]] && pass "peer add laptop สำเร็จ" || fail "peer add ล้มเหลว" "$out"
[[ -f "$AVPN_PEERS_DIR/laptop/wg-private.key" ]] && pass "มี private key ของ laptop" || fail "ไม่มี private key"
[[ -f "$AVPN_PEERS_DIR/laptop/laptop.conf" ]] && pass "มีไฟล์ laptop.conf" || fail "ไม่มี .conf"
[[ -f "$AVPN_PEERS_DIR/laptop/laptop-tcp.ovpn" ]] && pass "มีไฟล์ .ovpn สำรอง" || fail "ไม่มี .ovpn"
conf="$(cat "$AVPN_PEERS_DIR/laptop/laptop.conf")"
[[ $conf == *"[Interface]"* && $conf == *"Endpoint = vpn.test.local"* ]] && pass ".conf มี Interface + Endpoint ถูกต้อง" || fail ".conf ไม่ถูกต้อง" "$conf"
[[ $conf == *"DNS = 10.8.0.1"* ]] && pass ".conf มี DNS ภายในอุโมงค์" || fail ".conf ไม่มี DNS"
[[ $conf == *"MTU = 1420"* ]] && pass ".conf ระบุ MTU" || fail ".conf ไม่มี MTU"
ovpn="$(cat "$AVPN_PEERS_DIR/laptop/laptop-tcp.ovpn")"
[[ $ovpn == *"<ca>"* && $ovpn == *"<cert>"* && $ovpn == *"<key>"* && $ovpn == *"<tls-crypt>"* ]] \
  && pass ".ovpn ฝัง ca/cert/key/tls-crypt ครบ (ไฟล์เดียวจบ)" || fail ".ovpn ไม่ครบ"
[[ $ovpn == *"proto tcp"* && $ovpn == *"remote vpn.test.local 443"* ]] && pass ".ovpn ใช้ TCP 443" || fail ".ovpn port/proto ผิด"

out="$(run peer add phone)"
[[ $out == *"สร้างแล้ว"* ]] && pass "peer add phone สำเร็จ" || fail "peer add phone ล้มเหลว"
ip_phone="$(awk -F'\t' '$1=="phone"{print $2}' "$AVPN_PEERS_TSV")"
[[ $ip_phone == "10.8.0.3" ]] && pass "IP ของอุปกรณ์ถัดไปถูกต้อง (10.8.0.3)" || fail "IP ผิด" "$ip_phone"

out="$(run peer add laptop)"
[[ $out == *"มีอุปกรณ์ชื่อ"* ]] && pass "กันชื่อซ้ำ (ไม่สร้างทับ)" || fail "ไม่กันชื่อซ้ำ"

out="$(run peer add "Bad Name!!")"
[[ $out == *"ไม่ถูกต้อง"* ]] && pass "ปฏิเสธชื่ออุปกรณ์ที่ผิดรูปแบบ" || fail "รับชื่อผิดรูปแบบ"

out="$(run peer list)"
[[ $out == *"laptop"* && $out == *"phone"* ]] && pass "peer list แสดงทั้งสองเครื่อง" || fail "peer list ไม่ครบ"

group "6. WireGuard server config"
run apply >/dev/null 2>&1
wgc="$AVPN_WG_DIR/wg0.conf"
[[ -f $wgc ]] && pass "สร้าง wg0.conf" || fail "ไม่มี wg0.conf"
[[ $(grep -c '^\[Peer\]' "$wgc") == 2 ]] && pass "wg0.conf มี 2 peers" || fail "จำนวน peer ใน wg0.conf ผิด"
[[ $(stat -c '%a' "$wgc") == 600 ]] && pass "wg0.conf สิทธิ์ 600" || fail "สิทธิ์ wg0.conf ผิด ($(stat -c '%a' "$wgc"))"

group "7. OpenVPN CA / CRL"
ca="$AVPN_ETC/ca/ca.crt"
[[ -f $ca ]] && pass "มี CA certificate" || fail "ไม่มี CA"
openssl verify -CAfile "$ca" "$AVPN_ETC/ca/issued/client-laptop.crt" >/dev/null 2>&1 \
  && pass "ใบรับรอง client-laptop ผ่านการตรวจ" || fail "ใบรับรองไม่ผ่าน verify"
[[ -s "$AVPN_OVPN_DIR/crl.pem" ]] && pass "มีไฟล์ CRL" || fail "ไม่มี CRL"
lines="$(awk '/BEGIN/{f=1;next}/END/{f=0}f' "$AVPN_OVPN_DIR/tls-crypt.key" | grep -c .)"
[[ $lines == 16 ]] && pass "tls-crypt key มี 16 บรรทัด x 32 hex" || fail "รูปแบบ tls-crypt ผิด ($lines บรรทัด)"
[[ $(stat -c '%a' "$AVPN_OVPN_DIR/tls-crypt.key") == 600 ]] && pass "tls-crypt สิทธิ์ 600" || fail "สิทธิ์ tls-crypt ผิด"
[[ -f "$AVPN_OVPN_DIR/server/ovpn-tcp.conf" ]] && pass "มี server conf ของ OpenVPN TCP" || fail "ไม่มี ovpn-tcp.conf"
grep -q "tls-crypt" "$AVPN_OVPN_DIR/server/ovpn-tcp.conf" && pass "OpenVPN ใช้ tls-crypt" || fail "ไม่ได้เปิด tls-crypt"
grep -q "crl-verify" "$AVPN_OVPN_DIR/server/ovpn-tcp.conf" && pass "OpenVPN ตรวจ CRL (revoke ได้จริง)" || fail "ไม่มี crl-verify"
# ตรวจ IP pool / DNS / ccd ว่าไม่ผิดรูป (เคยมีบั๊ก 10.9.0.0.200)
grep -Eq "^ifconfig-pool 10\.9\.0\.[0-9]+ 10\.9\.0\.[0-9]+ 255\.255\.255\.0$" "$AVPN_OVPN_DIR/server/ovpn-tcp.conf" \
  && pass "ifconfig-pool ของ OpenVPN ถูกต้อง" || fail "ifconfig-pool ผิดรูป" "$(grep ifconfig-pool "$AVPN_OVPN_DIR/server/ovpn-tcp.conf")"
grep -q 'dhcp-option DNS 10.8.0.1' "$AVPN_OVPN_DIR/server/ovpn-tcp.conf" \
  && pass "OpenVPN push DNS ไปที่ dnsmasq ในอุโมงค์" || fail "DNS ที่ push ไม่ถูกต้อง"
grep -q "^dev tun-tcp" "$AVPN_OVPN_DIR/server/ovpn-tcp.conf" && grep -q "^dev tun-udp" "$AVPN_OVPN_DIR/server/ovpn-udp.conf" \
  && pass "2 อินสแตนซ์ใช้ dev คนละตัว (ไม่ชนกัน)" || fail "dev ถูกล็อกซ้ำกัน"

group "8. CCD ผูก IP ระหว่าง 2 ระบบ"
ccd="$AVPN_OVPN_DIR/ccd-tcp/laptop"
[[ -f $ccd ]] && pass "มี CCD ของ laptop" || fail "ไม่มี CCD"
[[ "$(cat "$ccd" 2>/dev/null)" == "ifconfig-push 10.9.0.2 255.255.255.0" ]] \
  && pass "IP ใน OpenVPN ตรงกับ WireGuard (10.8.0.2 ↔ 10.9.0.2)" || fail "CCD ผิด" "$(cat "$ccd" 2>/dev/null)"

group "9. เพิกถอนและลบ"
run peer revoke phone >/dev/null 2>&1
st="$(awk -F'\t' '$1=="phone"{print $8}' "$AVPN_PEERS_TSV")"
[[ $st == revoked ]] && pass "peer revoke เปลี่ยนสถานะเป็น revoked" || fail "revoke ไม่ทำงาน" "$st"
[[ $(grep -c '^\[Peer\]' "$AVPN_WG_DIR/wg0.conf") == 1 ]] && pass "wg0.conf เหลือ 1 peer หลัง revoke" || fail "wg0.conf ยังมี peer ที่ถูก revoke"
[[ ! -f "$AVPN_OVPN_DIR/ccd-tcp/phone" ]] && pass "ลบ CCD ของเครื่องที่ถูก revoke" || fail "CCD ยังอยู่"

run peer refresh phone >/dev/null 2>&1
st="$(awk -F'\t' '$1=="phone"{print $8}' "$AVPN_PEERS_TSV")"
[[ $st == active ]] && pass "peer refresh คืนสถานะ active" || fail "refresh ไม่ทำงาน"

run peer delete phone --yes >/dev/null 2>&1
[[ -z "$(awk -F'\t' '$1=="phone"' "$AVPN_PEERS_TSV")" ]] && pass "peer delete ลบออกจากทะเบียน" || fail "delete ไม่ทำงาน"
[[ ! -d "$AVPN_PEERS_DIR/phone" ]] && pass "ลบโฟลเดอร์คีย์ของ phone" || fail "โฟลเดอร์ยังอยู่"

group "10. doctor"
out="$(run doctor)"
[[ $out == *"สุขภาพของ"* ]] && pass "doctor แสดงผลรวม" || fail "doctor ไม่ทำงาน" "$out"
[[ $out == *"✖"* ]] || pass "doctor ไม่พบปัญหาระดับ fail ในโหมดทดสอบ"
out="$(run doctor --json)"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,list) and len(d)>0' 2>/dev/null \
  && pass "doctor --json คืน JSON ที่ parse ได้" || fail "doctor --json ผิดรูป" "$out"

group "11. backup / restore"
export AVPN_BACKUP_PASSPHRASE="test-pass-123456"
out="$(run backup "$WORK/backups/t1.tar.gz.enc")"
[[ -f "$WORK/backups/t1.tar.gz.enc" ]] && pass "สร้างไฟล์สำรอง" || fail "backup ล้มเหลว" "$out"
[[ $(head -c 8 "$WORK/backups/t1.tar.gz.enc" | wc -c) -gt 0 ]] &&
  head -c 8 "$WORK/backups/t1.tar.gz.enc" | grep -q "Salted" && pass "ไฟล์สำรองถูกเข้ารหัส (Salted__)" || fail "ไฟล์สำรองไม่ได้เข้ารหัส"
unset AVPN_BACKUP_PASSPHRASE
out="$(AVPN_BACKUP_PASSPHRASE=wrong-pass run restore "$WORK/backups/t1.tar.gz.enc")"
[[ $out == *"ถอดรหัสไม่สำเร็จ"* ]] && pass "ปฏิเสธรหัสผ่านผิด" || fail "ไม่ปฏิเสธรหัสผิด"

group "12. พอร์ทัล API"
mkdir -p "$WORK/www/cgi-bin" "$WORK/state/portal"
cp "$ROOT/portal/bin/api.sh" "$WORK/www/cgi-bin/api"
printf 'admin\tsecret123\n' >"$WORK/state/portal/auth"
api() {
  # api <METHOD> <PATH> [QUERY] [BODY] [AUTH]
  local m=$1 p=$2 q=${3:-} b=${4:-} a=${5:-}
  env -i PATH="$WORK/bin:/usr/bin:/bin" \
    AVPN_HOME="$ROOT" AVPN_LIB="$ROOT/lib" AVPN_HTDOCS="$WORK/www" \
    AVPN_ETC="$AVPN_ETC" AVPN_STATE="$AVPN_STATE" AVPN_PEERS_DIR="$AVPN_PEERS_DIR" \
    AVPN_PEERS_TSV="$AVPN_PEERS_TSV" AVPN_ENV_FILE="$AVPN_ENV_FILE" \
    AVPN_WG_DIR="$AVPN_WG_DIR" AVPN_OVPN_DIR="$AVPN_OVPN_DIR" AVPN_OVPN_LOG_DIR="$AVPN_OVPN_LOG_DIR" \
    AVPN_PUBLIC_HOST="$AVPN_PUBLIC_HOST" AVPN_ALLOW_NONROOT=1 WORK_SHIM_STATE="$WORK_SHIM_STATE" \
    REQUEST_METHOD="$m" PATH_INFO="$p" QUERY_STRING="$q" CONTENT_LENGTH="${#b}" \
    REMOTE_ADDR="127.0.0.1" ${a:+HTTP_AUTHORIZATION="$a"} \
    bash "$WORK/www/cgi-bin/api" <<<"$b"
}
AUTH="Basic $(printf 'admin:secret123' | base64 -w0)"
out="$(api GET /api/health | tr -d '\r' | tail -1)"
[[ $out == *'"ok":true'* ]] && pass "health ไม่ต้อง auth" || fail "health ผิด" "$out"
code="$(api GET /api/peers "" "" "" | head -1)"
[[ $code == *"401"* ]] && pass "ไม่ส่งรหัส → 401" || fail "ไม่กันการเข้าถึง" "$code"
out="$(api GET /api/peers "" "" "$AUTH" | tr -d '\r' | tail -1)"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"]; assert any(p["name"]=="laptop" for p in d["peers"])' 2>/dev/null \
  && pass "GET /api/peers คืนรายการอุปกรณ์" || fail "/api/peers ผิด" "$out"
out="$(api GET /api/status "" "" "$AUTH" | tr -d '\r' | tail -1)"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["server"]["version"]' 2>/dev/null \
  && pass "GET /api/status คืนข้อมูลเซิร์ฟเวอร์" || fail "/api/status ผิด"
out="$(api POST /api/peers "" '{"name":"tvmobile"}' "$AUTH" | tr -d '\r' | tail -1)"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"]; assert d["peer"]["name"]=="tvmobile"' 2>/dev/null \
  && pass "POST /api/peers สร้างอุปกรณ์ใหม่" || fail "สร้างผ่าน API ไม่ได้" "$out"
out="$(api GET /api/download "id=tvmobile&type=wg" "" "$AUTH" | tr -d '\r')"
[[ $out == *"[Interface]"* && $out == *"PrivateKey"* ]] && pass "ดาวน์โหลด .conf ผ่าน API" || fail "ดาวน์โหลดไม่ได้"
out="$(api GET /api/download "id=../../etc/passwd&type=wg" "" "$AUTH" | tr -d '\r')"
[[ $out == *"ไม่รู้จักอุปกรณ์"* ]] && pass "กัน path traversal ตอนดาวน์โหลด" || fail "มีช่องโหว่ path traversal" "$out"
out="$(api GET /api/download "file=../../etc/passwd" "" "$AUTH" | tr -d '\r')"
[[ $out == *"ไฟล์นี้ไม่มีในระบบ"* ]] && pass "บังคับ allowlist ของชื่อไฟล์" || fail "allowlist ไม่ทำงาน"
out="$(api POST /api/peer/tvmobile/revoke "" "" "$AUTH" | tr -d '\r' | tail -1)"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"]' 2>/dev/null \
  && pass "POST /api/peer/<name>/revoke" || fail "revoke ผ่าน API ไม่ได้" "$out"

group "13. ไฟล์ตัวอย่าง config"
EX="$ROOT/config/arena-vpn.env.example"
MISSING=""
while IFS='=' read -r k _; do
  [[ -z $k || $k == \#* ]] && continue
  grep -q "^$k=" "$EX" || MISSING+="$k "
done < <(grep -oE 'AVPN_[A-Z0-9_]+' "$ROOT/lib/common.sh" | sort -u |
  grep -vE '^(AVPN_(ETC|STATE|ENV_FILE|PEERS_DIR|PEERS_TSV|WG_DIR|OVPN_DIR|OVPN_LOG_DIR|BACKUP_DIR|HOME|VERSION|HTDOCS_ROOT|ALLOW_NONROOT|BACKUP_PASSPHRASE|ALERT_WEBHOOK|PORTAL_USER|PORTAL_PASS|PORTAL_AUTH_DISABLED|IP_MEMO|LIB_DIR|ASSUME_YES)|_AVPN_IP_MEMO)$' |
  sed 's/$/=x/')
[[ -z $MISSING ]] && pass "ทุกตัวแปรในโค้ดมีในไฟล์ตัวอย่าง" || fail "ขาดตัวแปรในตัวอย่าง: $MISSING"

group "14. ความปลอดภัยของไฟล์"
[[ $(stat -c '%a' "$AVPN_PEERS_TSV") == 600 ]] && pass "peers.tsv สิทธิ์ 600" || fail "สิทธิ์ peers.tsv ผิด"
[[ $(stat -c '%a' "$AVPN_PEERS_DIR/laptop/wg-private.key") == 600 ]] && pass "private key สิทธิ์ 600" || fail "สิทธิ์ private key ผิด"
[[ $(stat -c '%a' "$AVPN_ETC") == 700 ]] && pass "/etc/arena-vpn สิทธิ์ 700" || fail "สิทธิ์โฟลเดอร์หลักผิด"

group "15. เอกสาร"
DOCFAIL=0
for d in "$ROOT"/docs/*.md; do
  [[ -s $d ]] || { fail "เอกสารว่าง: $(basename "$d")"; DOCFAIL=1; }
done
[[ $DOCFAIL == 0 ]] && pass "คู่มือมีเนื้อหาครบ $(ls "$ROOT"/docs/*.md | wc -l) ไฟล์"
LINKFAIL=0
while read -r link; do
  [[ -f "$ROOT/$link" ]] || { fail "ลิงก์เสียใน README: $link"; LINKFAIL=1; }
done < <(grep -oE '^\| \[[^]]+\]\(([^)]+\.md)\)' "$ROOT/README.md" | sed -E 's/.*\(([^)]+)\)/\1/' | sort -u)
[[ $LINKFAIL == 0 ]] && pass "ลิงก์ในตารางเอกสารของ README ถูกต้อง"


# ==============================================================================
group "16. แพลตฟอร์ม (Cloud Shell / GCP / AWS / Oracle / self-hosted)"

PLAT_SHIM="$WORK/bin"
# mock curl ที่เคารพ -o /dev/null — เลียนแบบ metadata endpoint ของแต่ละคลาวด์
cat >"$PLAT_SHIM/curl" <<'SH'
#!/usr/bin/env bash
# mock curl: PLATFORM_SIM=aws|oracle|gcp|azure|<empty>
sim="${PLATFORM_SIM:-}"; args="$*"; out=""; prev=""
for a in "$@"; do [[ $prev == "-o" ]] && out=$a; prev=$a; done
emit() {
  if [[ -n $out ]]; then
    [[ $out == /dev/null ]] && exit 0
    printf '%s\n' "$*" >"$out"; exit 0
  fi
  printf '%s\n' "$*"; exit 0
}
case "$sim" in
  aws)
    [[ $args == *"/latest/api/token"* ]] && emit "MOCK_TOKEN"
    [[ $args == *"instance-id"* && $args == *"MOCK_TOKEN"* ]] && emit "i-0123456789abcdef0"
    exit 22 ;;
  oracle) [[ $args == *"opc/v2/instance"* ]] && [[ $args == *"Bearer Oracle"* ]] && emit '{"id":"ocid1.instance"}'; exit 22 ;;
  gcp)    [[ $args == *"computeMetadata"* ]] && [[ $args == *"Metadata-Flavor: Google"* ]] && emit "777888999"; exit 22 ;;
  azure)  [[ $args == *"metadata/instance"* ]] && emit '{"vmId":"azure-1"}'; exit 22 ;;
  *) exit 22 ;;
esac
SH
chmod +x "$PLAT_SHIM/curl"

# เรียก detect_platform ภายใต้ env ที่กำหนด
plat_detect() {
  env -u CLOUD_SHELL -u AWS_REGION -u OCI_REGION \
    PATH="$PLAT_SHIM:$PATH" PLATFORM_SIM="${1:-}" AVPN_ALLOW_NONROOT=1 \
    bash -c "cd '$ROOT' && source lib/common.sh && source lib/platform.sh && detect_platform" 2>/dev/null
}

[[ "$(plat_detect aws)" == aws ]] && pass "ตรวจพบ AWS (ผ่าน IMDSv2 + token)" || fail "ตรวจ AWS ไม่ได้" "$(plat_detect aws)"
[[ "$(plat_detect oracle)" == oracle ]] && pass "ตรวจพบ Oracle (ต้องมี header Bearer)" || fail "ตรวจ Oracle ไม่ได้"
[[ "$(plat_detect gcp)" == gcp ]] && pass "ตรวจพบ GCP (ต้องมี Metadata-Flavor)" || fail "ตรวจ GCP ไม่ได้"
[[ "$(plat_detect azure)" == azure ]] && pass "ตรวจพบ Azure" || fail "ตรวจ Azure ไม่ได้"
[[ "$(plat_detect '')" == selfhosted || "$(plat_detect '')" == selfhosted-nat ]] && pass "ไม่มี metadata → self-hosted" || fail "ตรวจ self-hosted ไม่ได้"

# Cloud Shell: CLOUD_SHELL=true ต้องชนะทุกอย่าง
[[ "$(CLOUD_SHELL=true PATH="$PLAT_SHIM:$PATH" bash -c "cd '$ROOT' && source lib/common.sh && source lib/platform.sh && detect_platform" 2>/dev/null)" == cloudshell ]] \
  && pass "ตรวจพบ Google Cloud Shell (CLOUD_SHELL=true)" || fail "ตรวจ Cloud Shell ไม่ได้"

# Cloud Shell ต้องไม่มี TUN/public IP/ไม่คงทน
eval "$(CLOUD_SHELL=true PATH="$PLAT_SHIM:$PATH" bash -c "
  cd '$ROOT' && source lib/common.sh && source lib/platform.sh
  p=cloudshell; platform_apply_caps \$p
  echo \"CS_TUN=\$AVPN_HAS_TUN CS_SYS=\$AVPN_HAS_SYSTEMD CS_PUB=\$AVPN_HAS_PUBLIC_IP CS_EPH=\$AVPN_IS_EPHEMERAL\"" 2>/dev/null)"
[[ ${CS_TUN:-} == 0 ]] && pass "Cloud Shell: ไม่มี TUN (ตั้งค่าถูก)" || fail "Cloud Shell TUN ควรเป็น 0 (ได้ '${CS_TUN:-}')"
[[ ${CS_PUB:-} == 0 ]] && pass "Cloud Shell: ไม่มี inbound port" || fail "Cloud Shell public IP ควรเป็น 0"
[[ ${CS_EPH:-} == 1 ]] && pass "Cloud Shell: ข้อมูลไม่คงทน (ephemeral)" || fail "Cloud Shell ควรเป็น ephemeral"

# MTU: ต้องไม่เกิน NIC MTU - 80 และไม่ต่ำกว่า 1280
plat_mtu() {
  env -u CLOUD_SHELL PATH="$PLAT_SHIM:$PATH" PLATFORM_SIM="${2:-}" bash -c "
    cd '$ROOT' && source lib/common.sh && source lib/platform.sh && platform_mtu '$1'" 2>/dev/null
}
[[ "$(plat_mtu gcp)" == 1360 ]] && pass "MTU ของ GCP = 1360" || fail "MTU GCP ผิด (ได้ '$(plat_mtu gcp)')"
for pl in aws oracle selfhosted; do
  m="$(plat_mtu "$pl")"
  if [[ $m =~ ^[0-9]+$ ]] && ((m >= 1280 && m <= 1420)); then
    pass "MTU ของ $pl อยู่ในช่วงปลอดภัย ($m)"
  else
    fail "MTU ของ $pl ผิด: '$m'"
  fi
done

# platform_mtu ต้องเคารพ MTU จริงของการ์ด (PPPoE 1492 → ≤1412)
MTU_TEST=$(PATH="$PLAT_SHIM:$PATH" bash -c "
  cd '$ROOT' && source lib/common.sh && source lib/platform.sh
  egress_mtu() { echo 1492; }
  platform_mtu selfhosted" 2>/dev/null)
(( MTU_TEST <= 1412 && MTU_TEST >= 1280 )) && pass "เคารพ MTU การ์ดจริง 1492 → $MTU_TEST (PPPoE)" || fail "ไม่เคารพ MTU การ์ดจริง (ได้ $MTU_TEST)"

# CGNAT / private IP
# ฟังก์ชันเหล่านี้คืนค่าทาง exit code — ต้องเรียกตรง ๆ ไม่ใช่ $(...)
iprc() { bash -c "cd '$ROOT' && source lib/common.sh && source lib/platform.sh && $1 $2" 2>/dev/null; }
iprc is_cgnat_ip 100.64.1.5 && pass "จับ CGNAT 100.64/10 ได้ (ทำ VPN ไม่ได้)" || fail "ไม่จับ CGNAT 100.64.1.5"
iprc is_cgnat_ip 100.128.5.1; (( $? != 0 )) && pass "IP 100.128 ไม่ใช่ CGNAT" || fail "เข้าใจ 100.128 ผิดว่าเป็น CGNAT"
iprc is_cgnat_ip 8.8.8.8; (( $? != 0 )) && pass "8.8.8.8 ไม่ใช่ CGNAT" || fail "เข้าใจ 8.8.8.8 ผิด"
IP3OK=1
for ip in 10.1.2.3 192.168.1.1 172.16.0.1; do iprc is_private_ip "$ip" || IP3OK=0; done
[[ $IP3OK == 1 ]] && pass "จับ private IP ครบ 3 ช่วง" || fail "จับ private IP ไม่ครบ"
iprc is_private_ip 1.1.1.1; (( $? != 0 )) && pass "1.1.1.1 ไม่ใช่ private" || fail "เข้าใจ 1.1.1.1 ผิด"

# fw_rule ต้องใช้ -I (ไม่ใช่ -A) — บั๊ก Oracle
grep -q 'fw_rule_i()' "$ROOT/lib/firewall.sh" && pass "มี fw_rule_i (insert)" || fail "ไม่มี fw_rule_i"
if grep -qE '^\s*fw_rule\s+"?INPUT"?' "$ROOT/lib/firewall.sh"; then
  fail "ยังมี fw_rule (append) สำหรับ INPUT — จะถูก REJECT ของ Oracle กลืน"
else
  pass "ไม่มี fw_rule (append) สำหรับ INPUT แล้ว (แก้บั๊ก Oracle)"
fi
INS=$(grep -c 'fw_rule_i' "$ROOT/lib/firewall.sh")
((INS >= 8)) && pass "ใช้ -I กับกฎ ACCEPT ทั้งหมด ($INS จุด)" || fail "ใช้ fw_rule_i น้อยเกิน ($INS)"

# Oracle: ต้องมี -o /dev/null (กัน body หลุด) และ header บังคับ
grep -q 'opc/v2/instance' "$ROOT/lib/platform.sh" && pass "มี metadata endpoint ของ Oracle" || fail "ขาด endpoint Oracle"
grep -B2 'opc/v2/instance' "$ROOT/lib/platform.sh" | grep -q 'Authorization: Bearer Oracle' \
  && pass "Oracle probe ส่ง header ที่บังคับ" || fail "Oracle probe ไม่ส่ง header"
grep -B2 'opc/v2/instance' "$ROOT/lib/platform.sh" | grep -q -- '-o /dev/null' \
  && pass "Oracle probe ใช้ -o /dev/null (ไม่ให้ body หลุด)" || fail "Oracle probe ไม่มี -o /dev/null"

# AWS: ต้องลอง IMDSv2 ก่อน (token)
grep -q 'latest/api/token' "$ROOT/lib/platform.sh" && pass "AWS ใช้ IMDSv2 (ดึง token)" || fail "AWS ไม่มี IMDSv2"
grep -q 'X-aws-ec2-metadata-token' "$ROOT/lib/platform.sh" && pass "AWS ส่ง header token กลับ" || fail "AWS ไม่ส่ง header token"

# platform_findings: Cloud Shell ต้องเตือนว่าทำ server ไม่ได้
CS_MSG=$(CLOUD_SHELL=true PATH="$PLAT_SHIM:$PATH" bash -c "
  cd '$ROOT' && source lib/common.sh && source lib/platform.sh && platform_findings cloudshell" 2>/dev/null)
[[ $CS_MSG == *"tun"* || $CS_MSG == *"VPN server"* ]] && pass "Cloud Shell: เตือนว่าไม่มี TUN" || fail "Cloud Shell ไม่เตือนเรื่อง TUN"

# คำแนะนำ firewall ต้องมีคำสั่งจริงของแต่ละเจ้า
for pl in gcp aws oracle; do
  G=$(bash -c "cd '$ROOT' && source lib/common.sh && source lib/platform.sh && platform_firewall_guide '$pl' vpn.test 51820 443 8443" 2>/dev/null)
  case "$pl" in
    gcp)    [[ $G == *gcloud*'firewall-rules'* ]] && pass "guide GCP มีคำสั่ง gcloud" || fail "guide GCP ไม่มีคำสั่ง gcloud" ;;
    aws)    [[ $G == *authorize-security-group-ingress* ]] && pass "guide AWS มีคำสั่ง aws ec2" || fail "guide AWS ไม่มีคำสั่ง aws" ;;
    oracle) [[ $G == *"Security List"* || $G == *"Ingress"* ]] && pass "guide Oracle อธิบาย Security List" || fail "guide Oracle ไม่มี Security List" ;;
  esac
done
G_NAT=$(bash -c "cd '$ROOT' && source lib/common.sh && source lib/platform.sh && platform_firewall_guide selfhosted-nat 1.2.3.4 51820 443 8443" 2>/dev/null)
[[ $G_NAT == *"Port forward"* || $G_NAT == *"port forward"* ]] && pass "guide self-hosted พูดถึง port forwarding" || fail "guide self-hosted ไม่มี port forwarding"

# remote: การ quote อาร์กิวเมนต์ต้องปลอดภัย (ทดสอบ logic จริง)
cat >"$WORK/qtest.sh" <<'QT'
set -u
args=("ชื่อ มี ช่องว่าง" "--note" 'a'"'"'b"c' '$HOME; rm -rf /' "*glob*")
q=""
for a in "${args[@]}"; do q+=" $(printf '%q' "$a")"; done
f() { printf '%d' $#; }
eval "f${q}"
QT
QOUT="$(bash "$WORK/qtest.sh" 2>/dev/null)"
[[ $QOUT == 5 ]] && pass "remote: อาร์กิวเมนต์พิเศษไม่แตก (argc ถูกต้อง)" || fail "remote quote ผิด (ได้ '$QOUT')"
grep -q 'printf .%q.' "$ROOT/lib/remote.sh" && pass "remote ใช้ %q quote ก่อนส่ง ssh" || fail "remote ไม่ได้ quote"

# remote: ต้องเก็บ rc ของ ssh ทันที (บั๊ก local rc=$?)
if grep -A1 '"sudo arena-vpn' "$ROOT/lib/remote.sh" | grep -q 'out="\$(ssh'; then
  pass "remote เรียก ssh ใน subshell (rc ไม่ถูก local กลบ)"
else
  fail "remote อาจเก็บ rc ผิด (local rc=\$?)"
fi
grep -q 'rc=\$?' "$ROOT/lib/remote.sh" && pass "remote เก็บ exit code" || fail "remote ไม่เก็บ exit code"

# remote/proxy/bootstrap ต้องมีในคำสั่ง
for c in remote proxy bootstrap platform; do
  grep -qE "^\s*$c\)" "$ROOT/arena-vpn" && pass "มีคำสั่ง '$c' ในตัว dispatcher" || fail "ขาดคำสั่ง '$c'"
done
grep -q 'proxy.pid' "$ROOT/lib/remote.sh" && pass "proxy มี pidfile" || fail "proxy ไม่มี pidfile"

# env ตัวอย่างต้องมีคีย์ของโหมด remote
for k in AVPN_PLATFORM AVPN_REMOTE_PORT AVPN_REMOTE_KEY; do
  grep -q "^$k=" "$ROOT/config/arena-vpn.env.example" && pass "env ตัวอย่างมี $k" || fail "env ตัวอย่างขาด $k"
done

# Cloud Shell ต้องไม่ถูก "แก้" ให้รัน server ได้
grep -q 'no_tun\|HAS_TUN == 0' "$ROOT/arena-vpn" && pass "init ปฏิเสธเครื่องที่ไม่มี TUN อย่างเข้าใจ" || fail "init ไม่ได้ตรวจ TUN แบบใหม่"

# ==============================================================================
printf '\n%s─────────────────────────────%s\n' $'\033[2m' "$C_Z"
printf '  ผ่าน %s%d%s   ไม่ผ่าน %s%d%s   ข้าม %s%d%s\n\n' \
  "$C_OK" "$PASS" "$C_Z" "$C_NO" "$FAIL" "$C_Z" "$C_SK" "$SKIP" "$C_Z"
((FAIL == 0)) || exit 1
