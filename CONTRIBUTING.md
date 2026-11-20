# การร่วมพัฒนา

## ก่อนส่ง PR

```bash
# 1. ตรวจ syntax
for f in arena-vpn lib/*.sh portal/bin/api.sh tests/run.sh tools/*.sh; do bash -n "$f"; done

# 2. lint (ต้องไม่มี error)
shellcheck -x -S error arena-vpn lib/*.sh portal/bin/api.sh tests/run.sh tools/*.sh

# 3. รันเทสต์ (ต้องผ่านหมด)
bash tests/run.sh

# 4. ดู UI โดยไม่ต้องมี VM
python3 tests/dev-portal.py 8080
# → http://localhost:8080  (admin / arena-demo)
```

CI รัน 4 อย่างนี้ทุก push ดู [.github/workflows/ci.yml](.github/workflows/ci.yml)

## หลักการเขียนโค้ด

1. **bash เท่านั้น** (ไม่เพิ่ม dependency ที่ต้อง compile) — ทุกอย่างที่ใช้ต้องมีใน Debian 12
2. **ทุกฟังก์ชันที่แตะระบบ ต้อง idempotent** — รันซ้ำต้องไม่พัง
3. **ห้าม `rm -rf` โดยไม่มี guard** — ใช้ `${VAR:?}` เสมอเมื่อลบตาม path
4. **ข้อความผู้ใช้เป็นภาษาไทย** — ยกเว้น log ทางเทคนิค (ภาษาอังกฤษได้)
5. **ทุกคำสั่งใหม่ ต้องมี `--json`** ถ้าเป็นคำสั่งอ่านสถานะ
6. **เพิ่มฟีเจอร์ = เพิ่มเทสต์** ใน `tests/run.sh`

## โครงสร้างโค้ด

```
arena-vpn          ← dispatcher + คำสั่งผู้ใช้ (ไม่ควรมี logic ลึก)
lib/*.sh           ← engine แยกตามหน้าที่ source กันได้
portal/bin/api.sh  ← CGI (ใช้ lib ร่วมกับ CLI)
```

**กฎสำคัญ**: ถ้า logic ถูกใช้ทั้ง CLI และ API → ย้ายไป `lib/` (ดูตัวอย่าง `peer_new`, `peer_render_files`)

## การทดสอบบนเครื่องจริง

```bash
# ใน LXC/VM ทดสอบ (ไม่ใช่เครื่อง production)
sudo ./arena-vpn init --yes --no-portal
sudo arena-vpn doctor
```

หรือใช้ mock (ไม่ต้อง root):
```bash
bash tests/run.sh
```

## การรายงานบั๊ก

แนบผลลัพธ์นี้เสมอ:
```bash
arena-vpn version
arena-vpn doctor --json
uname -a && cat /etc/os-release | head -3
```

**ห้ามแนบ**: ไฟล์ `.conf`, `.ovpn`, คีย์, รหัสผ่าน, หรือ public IP จริง

## ความปลอดภัย

พบช่องโหว่ → **อย่าเปิด public issue** ให้ส่งอีเมลถึงผู้ดูแล repo โดยตรง
(หรือใช้ GitHub Security Advisory)

## License

การส่ง PR = ยอมรับให้เผยแพร่ภายใต้ GPL-3.0
