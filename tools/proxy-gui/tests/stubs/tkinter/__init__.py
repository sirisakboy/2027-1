# -*- coding: utf-8 -*-
"""
stub ของ tkinter — ใช้เฉพาะในเทสต์ของ repo นี้ (แซนด์บ็อกซ์ไม่มี python3-tk)

ไม่ได้จำลองการวาด แต่จำลอง "สัญญา" ที่โค้ด GUI พึ่งพา:
  • widget มี .pack/.grid/.configure/.cget ใช้ได้
  • StringVar/BooleanVar เก็บค่าและส่งผ่าน read/write
  • Entry/Text/Combobox เก็บค่าได้
  • after() เรียกทันที (เทสต์ไม่ต้องรอ loop)

ใช้โดยการใส่ tools/proxy-gui/tests/stubs ไว้หน้า sys.path
"""

from __future__ import annotations

import sys
import types


class TclError(Exception):
    pass


class _Var:
    def __init__(self, master=None, value=None, name=None):
        self._v = value

    def get(self):
        return self._v

    def set(self, v):
        self._v = v


class StringVar(_Var):
    pass


class BooleanVar(_Var):
    pass


class IntVar(_Var):
    pass


class DoubleVar(_Var):
    pass


class Misc:
    def __init__(self, master=None, **kw):
        self.master = master
        self._cfg = dict(kw)
        self.children: list = []
        self._packs = []
        if master is not None and hasattr(master, "children"):
            master.children.append(self)
        # รองรับทั้ง text= และ textvariable=
        if "textvariable" in kw and kw["textvariable"] is not None:
            tv = kw["textvariable"]
            self._text_src = tv
        else:
            self._text_src = None

    # --- lifecycle ที่โค้ดเรียก ---
    def configure(self, cnf=None, **kw):
        if isinstance(cnf, dict):
            self._cfg.update(cnf)
        elif cnf is not None:
            self._cfg["_first"] = cnf
        self._cfg.update(kw)
        return self

    config = configure

    def cget(self, key):
        if key == "text":
            if self._text_src is not None:
                return self._text_src.get()
            return self._cfg.get("text", "")
        return self._cfg.get(key, "")

    def __getitem__(self, key):
        return self.cget(key)

    def __setitem__(self, key, val):
        self._cfg[key] = val

    def pack(self, *a, **k):
        self._packs.append(("pack", a, k))
        return self

    def grid(self, *a, **k):
        self._packs.append(("grid", a, k))
        return self

    def pack_forget(self, *a, **k):
        return self

    def grid_forget(self, *a, **k):
        return self

    def columnconfigure(self, *a, **k):
        return self

    def rowconfigure(self, *a, **k):
        return self

    def bind(self, *a, **k):
        return self

    def destroy(self):
        return None

    def winfo_exists(self):
        return 1

    def focus_set(self):
        return None

    def title(self, *a):
        if a:
            self._cfg["title"] = a[0]

    def minsize(self, *a):
        return None

    def geometry(self, *a):
        return None

    def protocol(self, *a, **k):
        return None

    def mainloop(self, *a, **k):
        return None

    def quit(self):
        return None

    def update_idletasks(self):
        return None

    def update(self):
        return None

    # after(): คิวไว้ ไม่เรียกทันที (ของจริงก็ทำแบบนี้) — เทสต์เรียก flush_after()
    def after(self, ms, func=None, *args):
        if callable(func):
            if not hasattr(self, "_pending_after"):
                self._pending_after = []
            self._pending_after.append((func, args))
            return f"after#{len(self._pending_after)}"
        return "after#0"

    def after_cancel(self, _id):
        return None

    def flush_after(self, rounds: int = 25) -> int:
        """เรียก callback ที่ค้างอยู่ (จำกัดรอบ กัน loop ของ _pump_log ที่ตั้งเวลาซ้ำ)"""
        ran = 0
        for _ in range(rounds):
            pending = getattr(self, "_pending_after", [])
            if not pending:
                break
            func, args = pending.pop(0)
            func(*args)
            ran += 1
        return ran


class Tk(Misc):
    def __init__(self, *a, **k):
        super().__init__(None, **k)
        self._destroyed = False

    def destroy(self):
        self._destroyed = True

    def mainloop(self, *a, **k):
        return None


class Toplevel(Tk):
    pass


class Frame(Misc):
    pass


class Label(Misc):
    pass


class Button(Misc):
    """รองรับ .invoke() เหมือนของจริง"""

    def invoke(self):
        cmd = self._cfg.get("command")
        if callable(cmd):
            return cmd()
        return None


class Checkbutton(Misc):
    def __init__(self, master=None, **kw):
        super().__init__(master, **kw)
        self.variable = kw.get("variable")

    def invoke(self):
        if self.variable is not None:
            self.variable.set(not self.variable.get())
        cmd = self._cfg.get("command")
        if callable(cmd):
            return cmd()
        return None


class Radiobutton(Checkbutton):
    pass


class Entry(Misc):
    def __init__(self, master=None, **kw):
        super().__init__(master, **kw)
        self.variable = kw.get("textvariable")
        self._text = kw.get("text", "")

    def get(self):
        if self.variable is not None:
            return self.variable.get()
        return self._text

    def set(self, v):
        if self.variable is not None:
            self.variable.set(v)
        else:
            self._text = v

    def insert(self, idx, s):
        if self.variable is not None:
            self.variable.set((self.variable.get() or "")[: int(idx) if str(idx).isdigit() else 0] + s)
        else:
            self._text += s

    def delete(self, *a):
        if self.variable is not None:
            self.variable.set("")
        else:
            self._text = ""

    def select_range(self, *a):
        return None

    def focus(self):
        return None


class Combobox(Entry):
    def __init__(self, master=None, **kw):
        super().__init__(master, **kw)
        self["values"] = kw.get("values", ())

    def current(self, idx=None):
        if idx is None:
            return 0
        vals = self._cfg.get("values") or ()
        if 0 <= idx < len(vals) and self.variable is not None:
            self.variable.set(vals[idx])
        return idx


class Text(Misc):
    def __init__(self, master=None, **kw):
        super().__init__(master, **kw)
        self.content = ""
        self.tags: dict = {}
        self._state = kw.get("state", "normal")

    def configure(self, cnf=None, **kw):
        if "state" in kw:
            self._state = kw["state"]
        return super().configure(cnf, **kw)

    def insert(self, index, text, tags=None):
        self.content += str(text)
        if tags:
            self.tags.setdefault(tags, []).append(str(text))

    def delete(self, *a):
        self.content = ""

    def see(self, *a):
        return None

    def tag_configure(self, name, **kw):
        self.tags.setdefault(name, [])

    def yview(self, *a):
        return (0.0, 1.0)

    def get(self, *a):
        return self.content


class Scrollbar(Misc):
    def set(self, *a):
        return None


class Progressbar(Misc):
    def __init__(self, master=None, **kw):
        super().__init__(master, **kw)
        self.running = False

    def start(self, *a):
        self.running = True

    def stop(self):
        self.running = False


class Canvas(Misc):
    pass


class LabelFrame(Misc):
    pass


class Separator(Misc):
    pass


class messagebox:
    """บันทึกการเรียกไว้ให้เทสต์ตรวจ แทนการเปิดหน้าต่างจริง"""

    calls: list = []

    @staticmethod
    def showerror(title, message, **kw):
        messagebox.calls.append(("error", title, message))

    @staticmethod
    def showinfo(title, message, **kw):
        messagebox.calls.append(("info", title, message))

    @staticmethod
    def showwarning(title, message, **kw):
        messagebox.calls.append(("warning", title, message))

    @staticmethod
    def askyesno(title, message, **kw):
        messagebox.calls.append(("yesno", title, message))
        return True


class ttk:
    Frame = Frame
    Label = Label
    Button = Button
    Checkbutton = Checkbutton
    Radiobutton = Radiobutton
    Entry = Entry
    Combobox = Combobox
    Scrollbar = Scrollbar
    Progressbar = Progressbar
    Separator = Separator
    LabelFrame = LabelFrame

    class Style:
        def __init__(self, *a, **k):
            pass

        def theme_use(self, *a):
            return None

        def configure(self, *a, **k):
            return None

        def map(self, *a, **k):
            return None


class font:
    class Font:
        def __init__(self, *a, **k):
            pass


def _install() -> None:
    """ติดตั้งโมดูล tkinter ปลอมเข้า sys.modules"""
    if "tkinter" in sys.modules and getattr(sys.modules["tkinter"], "__arena_stub__", False):
        return

    tkmod = types.ModuleType("tkinter")
    tkmod.__arena_stub__ = True
    for name in (
        "Tk", "Toplevel", "Frame", "Label", "Button", "Checkbutton", "Radiobutton",
        "Entry", "Text", "Canvas", "Scrollbar", "StringVar", "BooleanVar", "IntVar",
        "DoubleVar", "TclError", "Misc", "LabelFrame",
    ):
        setattr(tkmod, name, globals()[name])
    tkmod.ttk = ttk
    tkmod.messagebox = messagebox
    tkmod.font = font

    sys.modules["tkinter"] = tkmod
    sys.modules["tkinter.ttk"] = ttk  # type: ignore[assignment]
    sys.modules["tkinter.messagebox"] = messagebox  # type: ignore[assignment]
    sys.modules["tkinter.font"] = font  # type: ignore[assignment]


_install()
