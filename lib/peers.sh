#!/usr/bin/env bash
# ==============================================================================
#  Arena VPN — peer registry (ทะเบียนอุปกรณ์)
#  peers.tsv = แหล่งความจริงเดียว (single source of truth) ของทุกอุปกรณ์
#  คอลัมน์: name  wg_ip  wg_pub  wg_priv_file  ovpn_cn  ovpn_index  created  status  note
#  status: active | revoked
# ==============================================================================
# shellcheck shell=bash

PEERS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$PEERS_LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$PEERS_LIB_DIR/wg.sh"
# shellcheck source=/dev/null
source "$PEERS_LIB_DIR/ovpn.sh"

peers_init() {
  mkdir -p "$AVPN_PEERS_DIR" "$AVPN_STATE"
  chmod 700 "$AVPN_ETC" "$AVPN_PEERS_DIR" 2>/dev/null || true
  [[ -f "$AVPN_PEERS_TSV" ]] || { : >"$AVPN_PEERS_TSV"; chmod 600 "$AVPN_PEERS_TSV"; }
}

peer_exists() {
  awk -F'\t' -v n="$1" '$1==n{found=1} END{exit !found}' "$AVPN_PEERS_TSV" 2>/dev/null
}

peer_active_exists() {
  awk -F'\t' -v n="$1" '$1==n && $8=="active"{found=1} END{exit !found}' "$AVPN_PEERS_TSV" 2>/dev/null
}

# ดึงฟิลด์ของ peer: peer_field <name> <field-number>
peer_field() {
  awk -F'\t' -v n="$1" -v f="$2" '$1==n{print $f; exit}' "$AVPN_PEERS_TSV"
}

# จำนวน active peers
peer_count() {
  awk -F'\t' '$8=="active"{c++} END{print c+0}' "$AVPN_PEERS_TSV" 2>/dev/null
}

# IP ถัดไปที่ว่าง (10.x.x.2 .. .254) — ใช้ IP ที่ถูกใช้แล้วทั้งหมดรวม revoked
peer_next_ip() {
  local net=${AVPN_WG_NET:-10.8.0.0/24} prefix base i ip
  prefix=${net%/*}
  base=${prefix%.*}
  for ((i = 2; i <= 254; i++)); do
    ip="${base}.${i}"
    if ! awk -F'\t' -v x="$ip" '$2==x{found=1} END{exit !found}' "$AVPN_PEERS_TSV" 2>/dev/null; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

peer_ip_in_use() {
  awk -F'\t' -v x="$1" '$2==x{found=1} END{exit !found}' "$AVPN_PEERS_TSV" 2>/dev/null
}

# สร้าง peer ใหม่ — คืนค่าเป็น "name<TAB>ip"
# หมายเหตุ: การสร้างคีย์ทำใน arena-vpn (cmd_peer_add) เพื่อคุมลำดับขั้นตอน
peer_register() {
  local name=$1 ip=$2 pub=$3 priv_file=$4 ovpn_cn=$5 ovpn_idx=$6 note=${7:-}
  mkdir -p "$AVPN_PEERS_DIR/$name"
  chmod 700 "$AVPN_PEERS_DIR/$name"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tactive\t%s\n' \
    "$name" "$ip" "$pub" "$priv_file" "$ovpn_cn" "$ovpn_idx" "$(date +%s)" "$note" >>"$AVPN_PEERS_TSV"
  sort -t$'\t' -k1,1 "$AVPN_PEERS_TSV" -o "$AVPN_PEERS_TSV"
  chmod 600 "$AVPN_PEERS_TSV"
}

# อัปเดตฟิลด์ของ peer (แบบ atomic)
peer_set_field() {
  local name=$1 field=$2 value=$3 tmp
  tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v n="$name" -v f="$field" -v v="$value" \
    '$1==n{$f=v} {print}' "$AVPN_PEERS_TSV" >"$tmp"
  mv -f "$tmp" "$AVPN_PEERS_TSV"
  chmod 600 "$AVPN_PEERS_TSV"
}

peer_revoke() {
  peer_set_field "$1" 8 revoked
}

# ลบถาวร — ลบไฟล์ + ออกจาก TSV
peer_delete() {
  local name=$1 tmp
  tmp="$(mktemp)"
  awk -F'\t' -v n="$name" '$1!=n' "$AVPN_PEERS_TSV" >"$tmp"
  mv -f "$tmp" "$AVPN_PEERS_TSV"
  rm -rf -- "${AVPN_PEERS_DIR:?}/$name"
}

# ลิสต์แบบสั้น: name ip status
peer_list_brief() {
  awk -F'\t' '{printf "%-22s %-12s %s\n", $1, $2, $8}' "$AVPN_PEERS_TSV" 2>/dev/null
}

# แถวของ active peers ทั้งหมด (ใช้สร้าง config)
peer_active_rows() {
  awk -F'\t' '$8=="active"' "$AVPN_PEERS_TSV" 2>/dev/null
}

peer_any_rows() {
  cat "$AVPN_PEERS_TSV" 2>/dev/null
}

# สร้างอุปกรณ์ครบชุด (คีย์ WireGuard + ใบรับรอง OpenVPN + ไฟล์ config)
# ใช้ร่วมกันระหว่าง CLI และพอร์ทัล — คืนค่า "<name>\t<ip>"
peer_new() {
  local name=$1 note=${2:-} ip pub cn idx
  valid_peer_name "$name" || return 2
  peer_exists "$name" && return 3
  apply_defaults
  # ต้องมีคีย์เซิร์ฟเวอร์ก่อน ไม่งั้นไฟล์ client จะไม่มี PublicKey ให้เชื่อม
  wg_ensure_keys >/dev/null 2>&1 || return 6
  ip="$(peer_next_ip)" || return 4
  peers_init
  pub="$(wg_gen_peer_keys "$name")"
  cn="client-$name"
  idx="$(awk -F'\t' 'END{print NR+1}' "$AVPN_PEERS_TSV")"
  peer_register "$name" "$ip" "$pub" "$AVPN_PEERS_DIR/$name/wg-private.key" "$cn" "$idx" "$note"
  ovpn_issue_cert "$cn" client >/dev/null || return 5
  peer_render_files "$name"
  printf '%s\t%s' "$name" "$ip"
}

# เขียนไฟล์ config ของอุปกรณ์ลงโฟลเดอร์ peer (ใช้ซ้ำหลังเปลี่ยน IP/คีย์)
peer_render_files() {
  local name=$1 dir ip priv proto content
  dir="$AVPN_PEERS_DIR/$1"
  ip="$(peer_field "$name" 2)"
  priv="$(cat "$dir/wg-private.key" 2>/dev/null || true)"
  [[ -n $priv && -n $ip ]] || return 0
  content="$(wg_render_client "$name" "$ip" "$priv" 2>/dev/null || true)"
  [[ -n $content ]] && { printf '%s\n' "$content" >"$dir/$name.conf"; chmod 600 "$dir/$name.conf"; }
  for proto in tcp udp; do
    content="$(ovpn_render_client "$name" "$proto" 2>/dev/null || true)"
    [[ -n $content ]] && { printf '%s\n' "$content" >"$dir/$name-$proto.ovpn"; chmod 600 "$dir/$name-$proto.ovpn"; }
  done
}
