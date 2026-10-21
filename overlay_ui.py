#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SchoolGuard Xubuntu Fullscreen Overlay UI (Zero-Dependency: GTK3 Native + Tkinter Fallback)
Hoạt động 100% ngay trên Xubuntu mặc định mà KHÔNG cần cài thêm gói apt hay quyền sudo!
  - Chế độ lock: Khóa toàn màn hình + Chặn bàn phím/chuột + Hiển thị thông báo Giáo viên
  - Chế độ broadcast: Hiển thị trực tiếp màn hình bài giảng Giáo viên toàn màn hình
"""

import json
import os
import sys
import time
from datetime import datetime

STATE_FILE = "/dev/shm/sg_state.json"
FRAME_FILE = "/dev/shm/sg_broadcast.jpg"

# Ưu tiên GTK3 (Có sẵn 100% trên mọi máy Xubuntu/Ubuntu Desktop không cần sudo apt install)
HAS_GTK = False
try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk, GdkPixbuf, GLib, Pango
    HAS_GTK = True
except Exception:
    HAS_GTK = False


class GtkOverlayApp:
    def __init__(self):
        self.win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.win.set_title("SchoolGuard Classroom Overlay")
        self.win.set_decorated(False)
        self.win.set_keep_above(True)
        self.win.fullscreen()

        screen = Gdk.Screen.get_default()
        self.screen_w = screen.get_width() if screen else 1920
        self.screen_h = screen.get_height() if screen else 1080
        self.win.set_default_size(self.screen_w, self.screen_h)

        # Áp dụng CSS Dark Mode hiện đại
        css = b"""
        window { background-color: #090d16; }
        .badge { background-color: #172554; color: #60a5fa; border-radius: 8px; padding: 8px 18px; font-weight: bold; font-size: 16px; }
        .title { color: #f8fafc; font-weight: 800; font-size: 32px; }
        .msg-box { background-color: #111827; border: 2px solid #1e293b; border-radius: 12px; padding: 24px 36px; }
        .msg-text { color: #e2e8f0; font-size: 20px; }
        .clock { color: #94a3b8; font-family: monospace; font-size: 22px; font-weight: bold; }
        .footer { color: #64748b; font-size: 13px; }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        # Chặn đóng cửa sổ (Alt+F4) và mọi phím tắt
        self.win.connect("delete-event", lambda w, e: True)
        self.win.connect("key-press-event", lambda w, e: True)

        self.stack = Gtk.Stack()
        self.win.add(self.stack)

        # 1. Giao diện Khóa Màn Hình
        self.lock_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        self.lock_box.set_valign(Gtk.Align.CENTER)
        self.lock_box.set_halign(Gtk.Align.CENTER)

        self.lbl_icon = Gtk.Label()
        self.lbl_icon.set_markup("<span font='56'>🔒</span>")
        self.lock_box.pack_start(self.lbl_icon, False, False, 0)

        self.lbl_badge = Gtk.Label(label="PHÒNG MÁY TIN HỌC • MÁY HỌC SINH")
        self.lbl_badge.get_style_context().add_class("badge")
        self.lock_box.pack_start(self.lbl_badge, False, False, 0)

        self.lbl_title = Gtk.Label(label="MÁY TÍNH ĐANG ĐƯỢC KHÓA BỞI GIÁO VIÊN")
        self.lbl_title.get_style_context().add_class("title")
        self.lock_box.pack_start(self.lbl_title, False, False, 6)

        msg_frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        msg_frame.get_style_context().add_class("msg-box")
        self.lbl_msg = Gtk.Label(label="Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên.")
        self.lbl_msg.get_style_context().add_class("msg-text")
        self.lbl_msg.set_line_wrap(True)
        self.lbl_msg.set_max_width_chars(65)
        self.lbl_msg.set_justify(Gtk.Justification.CENTER)
        msg_frame.pack_start(self.lbl_msg, False, False, 0)
        self.lock_box.pack_start(msg_frame, False, False, 10)

        self.lbl_clock = Gtk.Label(label="--:--:--")
        self.lbl_clock.get_style_context().add_class("clock")
        self.lock_box.pack_start(self.lbl_clock, False, False, 6)

        self.lbl_footer = Gtk.Label(label="Hệ thống Quản lý Phòng máy SchoolGuard • Bàn phím và chuột đang tạm khóa")
        self.lbl_footer.get_style_context().add_class("footer")
        self.lock_box.pack_start(self.lbl_footer, False, False, 16)

        self.stack.add_named(self.lock_box, "lock")

        # 2. Giao diện Trình Chiếu Bài Giảng
        self.broadcast_image = Gtk.Image()
        self.stack.add_named(self.broadcast_image, "broadcast")

        self.last_mtime = 0
        self.win.show_all()
        self.win.present()

        GLib.timeout_add(70, self._poll_state)
        GLib.timeout_add(1000, self._tick_clock)
        GLib.timeout_add(500, self._grab_seat)

    def _grab_seat(self):
        try:
            self.win.set_keep_above(True)
            self.win.fullscreen()
            gdk_win = self.win.get_window()
            if gdk_win:
                display = gdk_win.get_display()
                seat = display.get_default_seat()
                if seat:
                    seat.grab(gdk_win, Gdk.SeatCapabilities.ALL, True, None, None, None, None)
        except Exception:
            pass
        return True

    def _tick_clock(self):
        self.lbl_clock.set_text(datetime.now().strftime("%H:%M:%S  •  %d/%m/%Y"))
        return True

    def _poll_state(self):
        try:
            if not os.path.exists(STATE_FILE):
                Gtk.main_quit()
                return False

            with open(STATE_FILE, "r", encoding="utf-8") as f:
                state = json.load(f)

            mode = state.get("mode", "normal")
            if mode not in ("lock", "broadcast"):
                Gtk.main_quit()
                return False

            self.stack.set_visible_child_name(mode)
            m_name = state.get("machine_name", "MÁY HỌC SINH")
            msg = state.get("lock_message") or "Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên."
            self.lbl_badge.set_text(f"PHÒNG MÁY TIN HỌC  •  {m_name}")
            self.lbl_msg.set_text(msg)

            if mode == "broadcast" and os.path.exists(FRAME_FILE):
                mtime = os.path.getmtime(FRAME_FILE)
                if mtime > self.last_mtime:
                    self.last_mtime = mtime
                    pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                        FRAME_FILE, self.screen_w, self.screen_h, True
                    )
                    self.broadcast_image.set_from_pixbuf(pixbuf)
        except Exception:
            pass
        return True

    def run(self):
        Gtk.main()


if __name__ == "__main__":
    if HAS_GTK:
        GtkOverlayApp().run()
    else:
        # Dự phòng Tkinter nếu môi trường không có GTK
        import tkinter as tk
        root = tk.Tk()
        root.attributes("-fullscreen", True)
        root.attributes("-topmost", True)
        root.overrideredirect(True)
        root.configure(bg="#090d16")
        lbl = tk.Label(root, text="MÁY TÍNH ĐANG ĐƯỢC KHÓA BỞI GIÁO VIÊN", fg="#fff", bg="#090d16", font=("Sans", 28, "bold"))
        lbl.pack(expand=True)
        def check():
            if not os.path.exists(STATE_FILE):
                root.destroy()
                return
            try:
                st = json.load(open(STATE_FILE))
                if st.get("mode") not in ("lock", "broadcast"):
                    root.destroy()
                    return
            except Exception:
                pass
            root.after(200, check)
        root.after(200, check)
        root.mainloop()
