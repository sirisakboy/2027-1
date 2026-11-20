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
printf '\n%s─────────────────────────────%s\n' $'\033[2m' "$C_Z"
printf '  ผ่าน %s%d%s   ไม่ผ่าน %s%d%s   ข้าม %s%d%s\n\n' \
  "$C_OK" "$PASS" "$C_Z" "$C_NO" "$FAIL" "$C_Z" "$C_SK" "$SKIP" "$C_Z"
((FAIL == 0)) || exit 1
