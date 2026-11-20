<div align="center">

# 🛡️ Arena VPN

**VPN ส่วนตัวบนคลาวด์ฟรี — สำหรับงานพัฒนาโปรเจกต์ และใช้ยามฉุกเฉิน**

WireGuard + OpenVPN fallback · พอร์ทัลเว็บ · ระบบฉุกเฉิน 4 ชั้น · สำรอง/ย้ายเครื่องในคำสั่งเดียว

`Debian 12` · `Ubuntu 22.04+` · `bash + busybox` (ไม่ต้อง Node/Python บน VM)

</div>

---

## ทำไมต้องสร้างเอง

VPN ฟรีทั่วไปจำกัดแบนด์วิดท์ แชร์ IP และมองไม่เห็นท่อของคุณ
การมีอุโมงค์ส่วนตัวบน free tier ทำให้:

| ต้องการ | ได้ |
|---|---|
| AI CLI ดึงโมเดล/แพ็กเกจได้ไม่ติดบล็อก | อุโมงค์ 1:1 ของคุณ, 10 TB/เดือน (Oracle) |
| ใช้งานจากโรงแรม/องค์กรที่บล็อก UDP | OpenVPN TCP 443 (หน้าตาเหมือน HTTPS) |
| เข้าเครื่อง dev จากที่ไหนก็ได้ | SSH ผ่าน VPN + พอร์ตสำรอง 4 ชั้น |
| ไม่ต้องจ่ายรายเดือน | 0 บาท บน Always Free Tier |
| คีย์อยู่กับคุณ 100% | ไม่มี SaaS ตรงกลาง ไม่มี telemetry |

## เริ่มใน 3 คำสั่ง

```bash
git clone https://github.com/sirisakboy/2027-1.git && cd 2027-1
sudo ./arena-vpn init --portal --yes

# สร้างอุปกรณ์ + QR สำหรับสแกนในมือถือ
sudo arena-vpn peer add phone && sudo arena-vpn peer qr phone
```

แล้วเปิด **`https://<IP>:8443`** เพื่อจัดการอุปกรณ์ทั้งหมดจากเบราว์เซอร์

> **ก่อนเริ่ม**: เปิดพอร์ตที่ cloud firewall ของผู้ให้บริการด้วย
> `UDP 51820` · `TCP 443` · `TCP 8443` (รายละเอียด: [docs/03-platforms.md](docs/03-platforms.md))

### หรือติดตั้งอัตโนมัติตอนสร้าง VM

วาง [`cloud-init.yaml`](cloud-init.yaml) ในช่อง **User data** ตอนสร้างเครื่อง
แล้วรอ 3–5 นาที — ระบบจะติดตั้งเองทั้งหมด รหัสพอร์ทัลอยู่ใน `/root/arena-vpn-portal.txt`

## ภาพรวมระบบ

```
┌─ เครื่องคุณ ─────────┐        ┌─ VM ฟรี (Debian 12) ───────────────────────┐
│ WireGuard app  ──────┼─ UDP ─▶│ wg0 10.8.0.1 ─┐                            │
│ OpenVPN Connect ─────┼─ TCP ─▶│ tun 10.9.x.x ─┼─ NAT ─▶ Internet           │
│ SSH 22 / 2222  ──────┼───────▶│ dnsmasq · พอร์ทัล :8443 · doctor/failover  │
└──────────────────────┘        └────────────────────────────────────────────┘
```

## คำสั่งที่ใช้บ่อย

```bash
arena-vpn status                  # สรุปทุกบริการ + ตารางอุปกรณ์
arena-vpn peer list               # ใครออนไลน์ ใช้ข้อมูลเท่าไร
arena-vpn peer add <ชื่อ>         # อุปกรณ์ใหม่ (ไฟล์เดียวจบ)
arena-vpn peer qr <ชื่อ>          # QR สแกนจากมือถือ
arena-vpn peer revoke <ชื่อ>      # ตัดเครื่องที่หายทันที
sudo arena-vpn doctor --fix       # ซ่อมเองเมื่อต่อไม่ติด
sudo arena-vpn failover rotate 2  # เปิด SSH พอร์ตฉุกเฉินใหม่
sudo arena-vpn backup             # สำรองเข้ารหัส (ย้ายเครื่องได้)
arena-vpn portal open             # URL + รหัสพอร์ทัล
```

## ฟีเจอร์

- 🚀 **WireGuard** เป็นช่องทางหลัก — เบา เร็ว แบตต่ำ
- 🧯 **OpenVPN TCP 443 + UDP 443** — ผ่านไฟร์วอลล์เข้มงวด, revoke รายเครื่องได้จริง (CRL)
- 🌐 **พอร์ทัลเว็บ** — เพิ่ม/ดาวน์โหลด/เพิกถอนอุปกรณ์, สถานะออนไลน์สด, หน้าเส้นทางฉุกเฉิน
- 🩺 **`doctor --fix`** — ไล่ซ่อม 5 สาเหตุที่ทำให้ "ต่อไม่ติด" บ่อยที่สุด
- 🛡️ **ฉุกเฉิน 4 ชั้น** — WG → OpenVPN TCP → SSH พอร์ตสำรอง → Cloud console
- 💾 **สำรอง/ย้ายเครื่อง** — AES-256 + PBKDF2, ย้ายคลาวด์ใหม่ใน 10 นาที
- 🌏 **ปรับตามคลาวด์** — preset สำหรับ GCP (MTU 1360), Oracle, AWS
- 🔒 **ปลอดภัยโดยค่าเริ่มต้น** — ปิด IPv6 กัน leak, DNS ในอุโมงค์, tls-crypt, ไฟล์ 600
- 🧾 **`--json`** ทุกคำสั่ง — ใช้กับสคริปต์/CI ได้

## เอกสาร

| ไฟล์ | เนื้อหา |
|---|---|
| [docs/00-ทําไมต้องมี.md](docs/00-ทําไมต้องมี.md) | ทำไมต้อง VPN ของตัวเอง + ข้อจำกัดที่ต้องรู้ |
| [docs/01-เริ่มต้น.md](docs/01-เริ่มต้น.md) | 15 นาทีแรก: สมัคร → ติดตั้ง → ต่อติด |
| [docs/02-คำสั่งทั้งหมด.md](docs/02-คำสั่งทั้งหมด.md) | Reference ทุกคำสั่งและตัวแปร |
| [docs/03-platforms.md](docs/03-platforms.md) | **GCP / Oracle / AWS** ทีละขั้น + กับดัก |
| [docs/04-สถาปัตยกรรม.md](docs/04-สถาปัตยกรรม.md) | ทำไมเลือกแบบนี้ + trade-off |
| [docs/05-แก้ปัญหา.md](docs/05-แก้ปัญหา.md) | อาการ → สาเหตุ → วิธีแก้ |
| [docs/06-ความปลอดภัย.md](docs/06-ความปลอดภัย.md) | ป้องกันอะไร ไม่ป้องกันอะไร |
| [docs/07-ฉุกเฉิน.md](docs/07-ฉุกเฉิน.md) | คู่มือวันที่ทุกอย่างพัง |
| [docs/08-สํารองและย้ายเครื่อง.md](docs/08-สํารองและย้ายเครื่อง.md) | backup/restore/ย้ายคลาวด์ |
| [docs/09-ตัดสินใจออกแบบ.md](docs/09-ตัดสินใจออกแบบ.md) | ADR: ทำไมเลือกแบบนี้ + roadmap |

## โครงสร้างโปรเจกต์

```
arena-vpn                  CLI หลัก (bash)
lib/
  common.sh                log, env, IP, apt, helpers
  peers.sh                 ทะเบียนอุปกรณ์ (peers.tsv)
  wg.sh                    WireGuard engine
  ovpn.sh                  OpenVPN engine (CA/CRL/tls-crypt)
  firewall.sh              NAT + iptables + systemd unit
  dns.sh                   dnsmasq ในอุโมงค์
  failover.sh              ชั้นฉุกเฉิน + คู่มือ console
  portal.sh                ติดตั้งพอร์ทัล (busybox httpd + stunnel)
  doctor.sh                ตรวจ/ซ่อม
  backup.sh                สำรอง/กู้คืน
portal/
  www/index.html           หน้าเว็บ (single-page, ไม่มี dependency)
  bin/api.sh               CGI backend (bash)
config/arena-vpn.env.example
docs/                      คู่มือภาษาไทย 10 ไฟล์ (ตามสถานการณ์)
cloud-init.yaml            ติดตั้งอัตโนมัติตอนสร้าง VM
tools/port-check.sh        ตรวจพอร์ตจากภายนอก
tests/                     smoke tests + dev portal
tests/                     smoke tests (รันได้โดยไม่ต้องมี VPN)
```

## พัฒนา / ทดสอบ

```bash
bash tests/run.sh                    # 79 smoke tests (ไม่ต้องมี root/VPN)
python3 tests/dev-portal.py 8080     # ดูพอร์ทัลด้วยข้อมูลตัวอย่าง
bash tools/port-check.sh <IP>        # ตรวจว่าพอร์ตเปิดจากภายนอกจริง
```

โปรเจกต์ใช้ bash + busybox เท่านั้น ไม่มี build step ไม่มี `node_modules` บน VM
ดูแนวทางการร่วมพัฒนา: [CONTRIBUTING.md](CONTRIBUTING.md)

## ข้อกำหนดระบบ

- Linux **Debian 12 / Ubuntu 22.04+** (root)
- แพ็กเกจที่ติดตั้งอัตโนมัติ: `wireguard-tools`, `openvpn`, `iptables`, `dnsmasq`,
  `busybox-static`, `stunnel4`, `openssl`, `qrencode`, `zip`
- ทรัพยากรขั้นต่ำ: **1 vCPU, 512 MB RAM, 1 GB ดิสก์** (e2-micro พอสบาย)
- IPv4 public address + สิทธิ์แก้ cloud firewall

## ความปลอดภัย (สรุป)

✅ เข้ารหัสมาตรฐานสมัยใหม่ · revoke ได้จริง · ปิด IPv6 กัน leak · ไม่มี telemetry
⚠️ ไม่ใช่ anonymous VPN · ไม่ใช่เครื่องมือหลบกฎหมาย — ใช้กับเครื่องมือพัฒนาของคุณเท่านั้น
📄 รายละเอียด: [docs/06-ความปลอดภัย.md](docs/06-ความปลอดภัย.md)

## สถานะ

✅ ติดตั้ง/ถอด/กู้คืนทดสอบแล้ว · ✅ 79 smoke tests ผ่าน · ✅ shellcheck ไม่มี error
⚠️ ยังไม่ได้ทดสอบกับแอป WireGuard/OpenVPN บนอุปกรณ์จริงใน CI (ต้องมี VM จริง)

## License

GPL-3.0 — ดู [LICENSE](LICENSE)
