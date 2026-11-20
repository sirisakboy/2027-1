#!/usr/bin/env python3
"""
Arena VPN — dev server สำหรับพอร์ทัล (ใช้ดู/แก้หน้าเว็บโดยไม่ต้องมี VM)

รัน:   python3 tests/dev-portal.py [port]
เปิด:  http://localhost:8080      (user: admin  pass: arena-demo)

- เสิร์ฟ portal/www/index.html
- เรียก portal/bin/api.sh เป็น CGI เหมือน busybox httpd บนเครื่องจริง
- ใช้โฟลเดอร์ชั่วคราวเป็น /etc/arena-vpn + สร้างอุปกรณ์ตัวอย่างให้
- ใช้ wg shim ถ้าเครื่องไม่มี WireGuard (คีย์จะไม่ใช่ X25519 จริง — สำหรับดู UI เท่านั้น)
"""
import base64
import os
import shutil
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEMO_USER, DEMO_PASS = "admin", "arena-demo"


def make_shim(bindir: str) -> None:
    """wg shim: ถ้ามี cryptography จะสร้าง X25519 จริง ไม่งั้นใช้ sha256"""
    path = os.path.join(bindir, "wg")
    with open(path, "w") as f:
        f.write(
            """#!/usr/bin/env bash
set -u
case "${1:-}" in
  genkey) head -c 32 /dev/urandom | base64 -w0; echo ;;
  pubkey)
    k="$(cat)"
    if python3 -c 'import cryptography' 2>/dev/null; then
      printf '%s' "$k" | python3 -c '
import sys, base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization as s
k = X25519PrivateKey.from_private_bytes(base64.b64decode(sys.stdin.read().strip()))
print(base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode())'
    else
      printf '%s' "$k" | sha256sum | awk '{print $1}' | head -c 32 | base64 -w0; echo
    fi ;;
  *) exit 0 ;;
esac
"""
        )
    os.chmod(path, 0o755)


class Handler(BaseHTTPRequestHandler):
    env: dict = {}
    work: str = ""

    def log_message(self, fmt, *args):  # noqa: A003
        sys.stderr.write("  %s\n" % (fmt % args))

    def _cgi(self, method: str) -> None:
        path, _, query = self.path.partition("?")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        env = dict(self.env)
        env.update(
            REQUEST_METHOD=method,
            PATH_INFO=path,
            QUERY_STRING=query,
            CONTENT_LENGTH=str(len(body)),
            REMOTE_ADDR=self.client_address[0],
        )
        if self.headers.get("Authorization"):
            env["HTTP_AUTHORIZATION"] = self.headers["Authorization"]
        proc = subprocess.run(
            ["/usr/bin/env", "bash", os.path.join(ROOT, "portal/bin/api.sh")],
            input=body,
            capture_output=True,
            env=env,
        )
        raw = proc.stdout
        head, _, payload = raw.partition(b"\r\n\r\n")
        status, headers = 200, []
        for line in head.decode("utf-8", "replace").split("\r\n"):
            key, _, value = line.partition(":")
            if not value:
                continue
            if key.strip().lower() == "status":
                status = int(value.split()[0])
            else:
                headers.append((key.strip(), value.strip()))
        if proc.stderr:
            sys.stderr.write(proc.stderr.decode("utf-8", "replace")[-2000:])
        self.send_response(status)
        sent = {k.lower() for k, _ in headers}
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        if "content-type" not in sent:
            self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/api/"):
            return self._cgi("GET")
        page = os.path.join(ROOT, "portal/www/index.html")
        with open(page, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):  # noqa: N802
        if self.path.startswith("/api/"):
            return self._cgi("POST")
        self.send_error(405)


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    work = tempfile.mkdtemp(prefix="arena-vpn-dev-")
    bindir = os.path.join(work, "bin")
    for d in ("bin", "etc/peers", "state/portal", "www", "wireguard", "openvpn", "log"):
        os.makedirs(os.path.join(work, d), exist_ok=True)
    make_shim(bindir)
    os.makedirs(os.path.join(work, "state/portal"), exist_ok=True)
    with open(os.path.join(work, "state/portal/auth"), "w") as f:
        f.write(f"{DEMO_USER}\t{DEMO_PASS}\n")

    env = dict(os.environ)
    env.update(
        PATH=f"{bindir}:/usr/local/bin:/usr/bin:/bin",
        AVPN_HOME=ROOT,
        AVPN_LIB=os.path.join(ROOT, "lib"),
        AVPN_BIN=os.path.join(ROOT, "arena-vpn"),
        AVPN_HTDOCS=os.path.join(work, "www"),
        AVPN_ETC=os.path.join(work, "etc"),
        AVPN_STATE=os.path.join(work, "state"),
        AVPN_ENV_FILE=os.path.join(work, "etc/arena-vpn.env"),
        AVPN_PEERS_DIR=os.path.join(work, "etc/peers"),
        AVPN_PEERS_TSV=os.path.join(work, "etc/peers.tsv"),
        AVPN_WG_DIR=os.path.join(work, "wireguard"),
        AVPN_OVPN_DIR=os.path.join(work, "openvpn"),
        AVPN_OVPN_LOG_DIR=os.path.join(work, "log"),
        AVPN_PUBLIC_HOST="vpn.demo.local",
        AVPN_ALLOW_NONROOT="1",
        AVPN_PORTAL_ENABLED="0",
    )

    # สร้างอุปกรณ์ตัวอย่าง
    for name in ("laptop-boss", "phone-a54", "ci-runner"):
        subprocess.run(
            [env["AVPN_BIN"], "peer", "add", name],
            env=env,
            capture_output=True,
        )

    Handler.env = env
    Handler.work = work
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"""
  ┌─────────────────────────────────────────────────────────┐
  │  Arena VPN — DEV PORTAL (ข้อมูลตัวอย่าง ไม่ใช่ของจริง)  │
  └─────────────────────────────────────────────────────────┘
     http://localhost:{port}
     user: {DEMO_USER}   pass: {DEMO_PASS}
     data: {work}
     หยุด: Ctrl+C
""")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  ปิด dev portal — ลบข้อมูลชั่วคราว")
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
