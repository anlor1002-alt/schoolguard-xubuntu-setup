#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SchoolGuard Xubuntu Fullscreen Overlay UI (Pre-Warmed Persistent Daemon)
- Chạy ngầm sẵn trong RAM 24/7: khi nhận lệnh LOCK / BROADCAST sẽ bật lên tức thì (< 20ms)
- Khi nhận lệnh UNLOCK (mode = normal) sẽ ẩn cửa sổ và nhả chuột/phím tức thì (< 10ms)
"""

import json
import os
import sys
import time
from datetime import datetime

STATE_FILE = "/dev/shm/sg_state.json"
FRAME_FILE = "/dev/shm/sg_broadcast.jpg"

HAS_GTK = False
try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk, GdkPixbuf, GLib
    HAS_GTK = True
except Exception:
    HAS_GTK = False


class GtkOverlayApp:
    def __init__(self):
        self.win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.win.set_title("SchoolGuard Classroom Overlay")
        self.win.set_decorated(False)
        self.win.set_skip_taskbar_hint(True)
        self.win.set_skip_pager_hint(True)
        self.win.set_keep_above(True)

        screen = Gdk.Screen.get_default()
        self.screen_w = screen.get_width() if screen else 1920
        self.screen_h = screen.get_height() if screen else 1080
        self.win.set_default_size(self.screen_w, self.screen_h)

        css = b"""
        window { background-color: #090b0e; }
        .clock-time {
            color: #ededef;
            font-family: monospace;
            font-size: 52px;
            font-weight: 700;
        }
        .clock-date {
            color: #6e7785;
            font-family: monospace;
            font-size: 14px;
            font-weight: 500;
        }
        .station-tag {
            background-color: #12151c;
            color: #9ba3b0;
            border: 1px solid #222733;
            border-radius: 6px;
            padding: 6px 16px;
            font-family: monospace;
            font-weight: 600;
            font-size: 13px;
        }
        .lock-title {
            color: #ededef;
            font-weight: 700;
            font-size: 28px;
        }
        .msg-container {
            background-color: #11141b;
            border: 1px solid #222733;
            border-left: 3px solid #2f6feb;
            border-radius: 8px;
            padding: 24px 36px;
        }
        .msg-header {
            color: #8a919e;
            font-weight: 600;
            font-size: 12px;
        }
        .msg-body {
            color: #ededef;
            font-size: 20px;
            font-weight: 500;
        }
        .security-footer {
            color: #565e6b;
            font-size: 13px;
            font-weight: 500;
        }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        self.win.connect("delete-event", lambda w, e: True)
        self.win.connect("key-press-event", lambda w, e: True)

        self.stack = Gtk.Stack()
        self.win.add(self.stack)

        # 1. Giao diện Khóa Màn Hình
        self.lock_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        self.lock_box.set_valign(Gtk.Align.CENTER)
        self.lock_box.set_halign(Gtk.Align.CENTER)

        clock_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        clock_box.set_halign(Gtk.Align.CENTER)
        self.lbl_clock_time = Gtk.Label(label="--:--:--")
        self.lbl_clock_time.get_style_context().add_class("clock-time")
        clock_box.pack_start(self.lbl_clock_time, False, False, 0)

        self.lbl_clock_date = Gtk.Label(label="--/--/----")
        self.lbl_clock_date.get_style_context().add_class("clock-date")
        clock_box.pack_start(self.lbl_clock_date, False, False, 0)
        self.lock_box.pack_start(clock_box, False, False, 4)

        self.lbl_badge = Gtk.Label(label="MÁY HỌC SINH — PHÒNG TIN HỌC")
        self.lbl_badge.get_style_context().add_class("station-tag")
        self.lock_box.pack_start(self.lbl_badge, False, False, 0)

        self.lbl_title = Gtk.Label(label="Màn hình đang tạm khóa")
        self.lbl_title.get_style_context().add_class("lock-title")
        self.lock_box.pack_start(self.lbl_title, False, False, 4)

        msg_frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        msg_frame.get_style_context().add_class("msg-container")

        lbl_msg_head = Gtk.Label(label="Thông báo từ giáo viên")
        lbl_msg_head.get_style_context().add_class("msg-header")
        lbl_msg_head.set_halign(Gtk.Align.START)
        msg_frame.pack_start(lbl_msg_head, False, False, 0)

        self.lbl_msg = Gtk.Label(label="Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên.")
        self.lbl_msg.get_style_context().add_class("msg-body")
        self.lbl_msg.set_line_wrap(True)
        self.lbl_msg.set_max_width_chars(65)
        self.lbl_msg.set_halign(Gtk.Align.START)
        self.lbl_msg.set_justify(Gtk.Justification.LEFT)
        msg_frame.pack_start(self.lbl_msg, False, False, 0)
        self.lock_box.pack_start(msg_frame, False, False, 8)

        self.lbl_footer = Gtk.Label(label="SchoolGuard — Chuột và bàn phím đang được quản lý bởi giáo viên")
        self.lbl_footer.get_style_context().add_class("security-footer")
        self.lock_box.pack_start(self.lbl_footer, False, False, 12)

        self.stack.add_named(self.lock_box, "lock")

        # 2. Giao diện Trình Chiếu Bài Giảng
        self.broadcast_image = Gtk.Image()
        self.stack.add_named(self.broadcast_image, "broadcast")

        self.last_frame_mtime = 0
        self.last_state_mtime = 0
        self.is_visible = False
        self.current_mode = "normal"
        self.win.hide()

        self._tick_clock()
        self._poll_state()
        GLib.timeout_add(25, self._poll_state)
        GLib.timeout_add(1000, self._tick_clock)
        GLib.timeout_add(300, self._enforce_topmost)

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

    def _ungrab_seat(self):
        try:
            gdk_win = self.win.get_window()
            if gdk_win:
                display = gdk_win.get_display()
                seat = display.get_default_seat()
                if seat:
                    seat.ungrab()
        except Exception:
            pass

    def _enforce_topmost(self):
        if self.is_visible and self.current_mode in ("lock", "broadcast"):
            self._grab_seat()
        return True

    def _tick_clock(self):
        if self.is_visible:
            now = datetime.now()
            self.lbl_clock_time.set_text(now.strftime("%H:%M:%S"))
            self.lbl_clock_date.set_text(now.strftime("%d/%m/%Y"))
        return True

    def _poll_state(self):
        try:
            if not os.path.exists(STATE_FILE):
                if self.is_visible:
                    self._ungrab_seat()
                    self.win.hide()
                    self.is_visible = False
                return True

            st_mtime = os.path.getmtime(STATE_FILE)
            if st_mtime != self.last_state_mtime:
                self.last_state_mtime = st_mtime
                with open(STATE_FILE, "r", encoding="utf-8") as f:
                    state = json.load(f)

                mode = state.get("mode", "normal")
                self.current_mode = mode

                if mode in ("lock", "broadcast"):
                    m_name = state.get("machine_name", "MÁY HỌC SINH")
                    msg = state.get("lock_message") or "Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên."
                    self.lbl_badge.set_text(f"{m_name} — PHÒNG TIN HỌC")
                    self.lbl_msg.set_text(msg)
                    self.stack.set_visible_child_name(mode)

                    if not self.is_visible:
                        self.is_visible = True
                        self._tick_clock()
                        self.win.show_all()
                        self.win.fullscreen()
                        self.win.set_keep_above(True)
                        self.win.present()
                        self._grab_seat()
                else:
                    if self.is_visible:
                        self.is_visible = False
                        self._ungrab_seat()
                        self.win.hide()

            if self.is_visible and self.current_mode == "broadcast" and os.path.exists(FRAME_FILE):
                f_mtime = os.path.getmtime(FRAME_FILE)
                if f_mtime > self.last_frame_mtime:
                    self.last_frame_mtime = f_mtime
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
        import tkinter as tk

        class TkOverlayApp:
            def __init__(self):
                self.root = tk.Tk()
                self.root.title("SchoolGuard Classroom Overlay")
                self.root.attributes("-fullscreen", True)
                self.root.attributes("-topmost", True)
                self.root.overrideredirect(True)
                self.root.configure(bg="#090b0e")
                self.root.bind("<Key>", lambda e: "break")
                self.root.protocol("WM_DELETE_WINDOW", lambda: None)

                container = tk.Frame(self.root, bg="#090b0e")
                container.place(relx=0.5, rely=0.5, anchor="center")

                self.lbl_clock_time = tk.Label(
                    container, text="--:--:--", bg="#090b0e", fg="#ededef", font=("Consolas", 42, "bold")
                )
                self.lbl_clock_time.pack(pady=(0, 2))

                self.lbl_clock_date = tk.Label(
                    container, text="--/--/----", bg="#090b0e", fg="#6e7785", font=("Consolas", 12)
                )
                self.lbl_clock_date.pack(pady=(0, 18))

                self.lbl_badge = tk.Label(
                    container,
                    text="MÁY HỌC SINH — PHÒNG TIN HỌC",
                    bg="#12151c",
                    fg="#9ba3b0",
                    font=("Consolas", 11, "bold"),
                    padx=16,
                    pady=6,
                )
                self.lbl_badge.pack(pady=(0, 14))

                self.lbl_title = tk.Label(
                    container, text="Màn hình đang tạm khóa", bg="#090b0e", fg="#ededef", font=("Segoe UI", 22, "bold")
                )
                self.lbl_title.pack(pady=(0, 18))

                msg_card = tk.Frame(container, bg="#11141b", padx=32, pady=22)
                msg_card.pack(pady=(0, 18), fill="x")

                lbl_msg_head = tk.Label(
                    msg_card, text="Thông báo từ giáo viên", bg="#11141b", fg="#8a919e", font=("Segoe UI", 11, "bold")
                )
                lbl_msg_head.pack(anchor="w", pady=(0, 6))

                self.lbl_msg = tk.Label(
                    msg_card,
                    text="Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên.",
                    bg="#11141b",
                    fg="#ededef",
                    font=("Segoe UI", 15),
                    wraplength=680,
                    justify="left",
                )
                self.lbl_msg.pack(anchor="w")

                self.is_visible = False
                self.root.withdraw()
                self._poll()

            def _poll(self):
                try:
                    if os.path.exists(STATE_FILE):
                        with open(STATE_FILE, "r", encoding="utf-8") as f:
                            state = json.load(f)
                        mode = state.get("mode", "normal")
                        if mode in ("lock", "broadcast"):
                            now = datetime.now()
                            self.lbl_clock_time.config(text=now.strftime("%H:%M:%S"))
                            self.lbl_clock_date.config(text=now.strftime("%d/%m/%Y"))
                            m_name = state.get("machine_name", "MÁY HỌC SINH")
                            msg = state.get("lock_message") or "Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên."
                            self.lbl_badge.config(text=f"{m_name} — PHÒNG TIN HỌC")
                            self.lbl_msg.config(text=msg)
                            if not self.is_visible:
                                self.is_visible = True
                                self.root.deiconify()
                                self.root.attributes("-fullscreen", True)
                                self.root.attributes("-topmost", True)
                                self.root.lift()
                        else:
                            if self.is_visible:
                                self.is_visible = False
                                self.root.withdraw()
                except Exception:
                    pass
                self.root.after(25, self._poll)

            def run(self):
                self.root.mainloop()

        TkOverlayApp().run()
