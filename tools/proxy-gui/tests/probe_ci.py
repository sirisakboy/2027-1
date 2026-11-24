import contextlib, importlib.util, io, sys, traceback
out = []

def p(s):
    out.append(str(s))

sys.path.insert(0, "tools/proxy-gui/tests/stubs")
sys.path.insert(0, "tools/proxy-gui")
spec = importlib.util.spec_from_file_location("rp", "tools/proxy-gui/tests/render_preview.py")
rp = importlib.util.module_from_spec(spec)
try:
    with contextlib.redirect_stderr(io.StringIO()):
        spec.loader.exec_module(rp)
    p(f"import rp OK TH={rp.TH} FONT_R={rp.FONT_R}")
except BaseException:
    p("IMPORT FAILED:"); out.append(traceback.format_exc())
    open("/tmp/probe.txt", "w").write("\n".join(out)); raise SystemExit(3)

try:
    from PIL import Image, ImageDraw
    p("PIL OK")
except BaseException:
    p("PIL MISSING"); out.append(traceback.format_exc())
    open("/tmp/probe.txt", "w").write("\n".join(out)); raise SystemExit(4)

try:
    d = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    p(f"measure={rp.measure(d, 'ทดสอบ', rp.font(13))}")
    rp.draw_mixed(d, (0, 0), "▸ Apply ไทย", rp.font(13), fill=(255, 255, 255))
    p("draw_mixed OK")
except BaseException:
    p("RENDER FAILED:"); out.append(traceback.format_exc())
    open("/tmp/probe.txt", "w").write("\n".join(out)); raise SystemExit(5)

open("/tmp/probe.txt", "w").write("\n".join(out))
