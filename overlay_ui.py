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
        window { background-color: #0b0f19; }
        .slot-pill {
            background-color: #172554;
            color: #60a5fa;
            border: 1px solid #1e3a8a;
            border-radius: 9999px;
            padding: 8px 24px;
            font-weight: 800;
            font-size: 15px;
            letter-spacing: 1.5px;
        }
        .lock-title {
            color: #f8fafc;
            font-weight: 900;
            font-size: 32px;
            letter-spacing: 0.5px;
        }
        .msg-container {
            background-color: #0f172a;
            border: 2px solid #334155;
            border-radius: 16px;
            padding: 24px 44px;
        }
        .msg-header {
            color: #38bdf8;
            font-weight: 700;
            font-size: 14px;
            letter-spacing: 1px;
        }
        .msg-body {
            color: #f8fafc;
            font-size: 22px;
            font-weight: 500;
        }
        .clock-time {
            color: #60a5fa;
            font-family: monospace;
            font-size: 38px;
            font-weight: 800;
        }
        .clock-date {
            color: #94a3b8;
            font-family: monospace;
            font-size: 15px;
            font-weight: 600;
        }
        .security-badge {
            background-color: #1e1b4b;
            border: 1px solid #4338ca;
            color: #c7d2fe;
            border-radius: 9999px;
            padding: 8px 22px;
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 0.5px;
        }
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
        self.lock_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20)
        self.lock_box.set_valign(Gtk.Align.CENTER)
        self.lock_box.set_halign(Gtk.Align.CENTER)

        # Slot machine badge pill (e.g. MÁY 01 / hostname)
        self.lbl_badge = Gtk.Label(label="PHÒNG MÁY TIN HỌC  •  MÁY HỌC SINH")
        self.lbl_badge.get_style_context().add_class("slot-pill")
        self.lock_box.pack_start(self.lbl_badge, False, False, 0)

        # Lock Title
        self.lbl_title = Gtk.Label(label="🔒 MÁY TÍNH ĐANG ĐƯỢC KHÓA BỞI GIÁO VIÊN")
        self.lbl_title.get_style_context().add_class("lock-title")
        self.lock_box.pack_start(self.lbl_title, False, False, 6)

        # Elevated Teacher Message Card
        msg_frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        msg_frame.get_style_context().add_class("msg-container")

        lbl_msg_head = Gtk.Label(label="💬 LỜI NHẮN TỪ GIÁO VIÊN:")
        lbl_msg_head.get_style_context().add_class("msg-header")
        lbl_msg_head.set_halign(Gtk.Align.CENTER)
        msg_frame.pack_start(lbl_msg_head, False, False, 0)

        self.lbl_msg = Gtk.Label(label="Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên.")
        self.lbl_msg.get_style_context().add_class("msg-body")
        self.lbl_msg.set_line_wrap(True)
        self.lbl_msg.set_max_width_chars(65)
        self.lbl_msg.set_justify(Gtk.Justification.CENTER)
        msg_frame.pack_start(self.lbl_msg, False, False, 0)
        self.lock_box.pack_start(msg_frame, False, False, 10)

        # Digital Clock Ticker
        clock_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        clock_box.set_halign(Gtk.Align.CENTER)
        self.lbl_clock_time = Gtk.Label(label="--:--:--")
        self.lbl_clock_time.get_style_context().add_class("clock-time")
        clock_box.pack_start(self.lbl_clock_time, False, False, 0)

        self.lbl_clock_date = Gtk.Label(label="--/--/----")
        self.lbl_clock_date.get_style_context().add_class("clock-date")
        clock_box.pack_start(self.lbl_clock_date, False, False, 0)
        self.lock_box.pack_start(clock_box, False, False, 6)

        # Security Status Badge Footer
        self.lbl_footer = Gtk.Label(label="🛡️ Hệ thống Quản lý SchoolGuard Pro • Bàn phím & Chuột đang tạm khóa")
        self.lbl_footer.get_style_context().add_class("security-badge")
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
        now = datetime.now()
        self.lbl_clock_time.set_text(now.strftime("%H:%M:%S"))
        self.lbl_clock_date.set_text(now.strftime("%A, %d/%m/%Y"))
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
        from datetime import datetime

        class TkOverlayApp:
            def __init__(self):
                self.root = tk.Tk()
                self.root.title("SchoolGuard Classroom Overlay")
                self.root.attributes("-fullscreen", True)
                self.root.attributes("-topmost", True)
                self.root.overrideredirect(True)
                self.root.configure(bg="#0b0f19")
                self.root.bind("<Key>", lambda e: "break")
                self.root.protocol("WM_DELETE_WINDOW", lambda: None)

                # Khung trung tâm
                container = tk.Frame(self.root, bg="#0b0f19")
                container.place(relx=0.5, rely=0.5, anchor="center")

                # Slot Badge Pill
                self.lbl_badge = tk.Label(
                    container,
                    text="PHÒNG MÁY TIN HỌC  •  MÁY HỌC SINH",
                    bg="#172554",
                    fg="#60a5fa",
                    font=("Segoe UI", 13, "bold"),
                    padx=20,
                    pady=6,
                    relief="solid",
                    bd=1,
                    highlightbackground="#1e3a8a",
                )
                self.lbl_badge.pack(pady=(0, 16))

                # Lock Title
                self.lbl_title = tk.Label(
                    container,
                    text="🔒 MÁY TÍNH ĐANG ĐƯỢC KHÓA BỞI GIÁO VIÊN",
                    bg="#0b0f19",
                    fg="#f8fafc",
                    font=("Segoe UI", 26, "bold"),
                )
                self.lbl_title.pack(pady=(0, 20))

                # Elevated Message Card
                msg_card = tk.Frame(
                    container,
                    bg="#0f172a",
                    highlightbackground="#334155",
                    highlightthickness=2,
                    padx=36,
                    pady=24,
                )
                msg_card.pack(pady=(0, 20), fill="x")

                lbl_msg_head = tk.Label(
                    msg_card,
                    text="💬 LỜI NHẮN TỪ GIÁO VIÊN:",
                    bg="#0f172a",
                    fg="#38bdf8",
                    font=("Segoe UI", 11, "bold"),
                )
                lbl_msg_head.pack(pady=(0, 8))

                self.lbl_msg = tk.Label(
                    msg_card,
                    text="Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên.",
                    bg="#0f172a",
                    fg="#f8fafc",
                    font=("Segoe UI", 16),
                    wraplength=750,
                    justify="center",
                )
                self.lbl_msg.pack()

                # Digital Clock Ticker
                self.lbl_clock_time = tk.Label(
                    container,
                    text="--:--:--",
                    bg="#0b0f19",
                    fg="#60a5fa",
                    font=("Consolas", 32, "bold"),
                )
                self.lbl_clock_time.pack(pady=(0, 2))

                self.lbl_clock_date = tk.Label(
                    container,
                    text="--/--/----",
                    bg="#0b0f19",
                    fg="#94a3b8",
                    font=("Segoe UI", 12, "bold"),
                )
                self.lbl_clock_date.pack(pady=(0, 24))

                # Security Badge Footer
                self.lbl_footer = tk.Label(
                    container,
                    text="🛡️ Hệ thống Quản lý SchoolGuard Pro • Bàn phím & Chuột đang tạm khóa",
                    bg="#1e1b4b",
                    fg="#c7d2fe",
                    font=("Segoe UI", 10, "bold"),
                    padx=18,
                    pady=8,
                    relief="solid",
                    bd=1,
                    highlightbackground="#4338ca",
                )
                self.lbl_footer.pack()

                self._update_clock()
                self._poll_state()

            def _update_clock(self):
                now = datetime.now()
                self.lbl_clock_time.config(text=now.strftime("%H:%M:%S"))
                self.lbl_clock_date.config(text=now.strftime("%A, %d/%m/%Y"))
                self.root.after(1000, self._update_clock)

            def _poll_state(self):
                if not os.path.exists(STATE_FILE):
                    self.root.destroy()
                    return
                try:
                    with open(STATE_FILE, "r", encoding="utf-8") as f:
                        state = json.load(f)
                    mode = state.get("mode", "normal")
                    if mode not in ("lock", "broadcast"):
                        self.root.destroy()
                        return
                    m_name = state.get("machine_name", "MÁY HỌC SINH")
                    msg = state.get("lock_message") or "Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên."
                    self.lbl_badge.config(text=f"PHÒNG MÁY TIN HỌC  •  {m_name}")
                    self.lbl_msg.config(text=msg)
                except Exception:
                    pass
                self.root.after(100, self._poll_state)

            def run(self):
                self.root.mainloop()

        TkOverlayApp().run()
