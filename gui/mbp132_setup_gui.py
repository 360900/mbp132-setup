#!/usr/bin/env python3
"""Graphical installer for mbp132-setup. Collects choices and runs mbp132-setup-cli.sh."""
import math
import os
import re
import shlex
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_foreign("cairo")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "mbp132-setup-cli.sh")
APP_ID = "io.github.x360900.mbp132setup"

MODELS = {
    "MacBookPro13,2": "tested",
    "MacBookPro13,1": "untested",
    "MacBookPro13,3": "untested",
    "MacBookPro14,1": "untested",
    "MacBookPro14,2": "untested",
    "MacBookPro14,3": "untested",
}
WIFI_NVRAM_MODELS = {"MacBookPro13,2"}
EASE = "cubic-bezier(.2,0,0,1)"
HUE, CHROMA = 255, 0.16  # One token: accents.blue


# ------------------------------------------------------------------- color --
def oklch(lightness, chroma, hue):
    """OKLCH to clamped sRGB floats."""
    a = chroma * math.cos(math.radians(hue))
    b = chroma * math.sin(math.radians(hue))
    lm = lightness + 0.3963377774 * a + 0.2158037573 * b
    mm = lightness - 0.1055613458 * a - 0.0638541728 * b
    sm = lightness - 0.0894841775 * a - 1.2914855480 * b
    lin = (
        4.0767416621 * lm**3 - 3.3077115913 * mm**3 + 0.2309699292 * sm**3,
        -1.2684380046 * lm**3 + 2.6097574011 * mm**3 - 0.3413193965 * sm**3,
        -0.0041960863 * lm**3 - 0.7034186147 * mm**3 + 1.7076147010 * sm**3,
    )

    def gamma(x):
        x = min(1.0, max(0.0, x))
        return 12.92 * x if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055

    return tuple(gamma(x) for x in lin)


def css_rgb(rgb):
    return "rgb(%d,%d,%d)" % tuple(round(c * 255) for c in rgb)


def palette(dark):
    """Colors from tokens/one.json in oneDesign."""
    n = 0.006
    if dark:
        values = dict(canvas=0.215, surface=0.25, alt=0.285, text=0.96, text2=0.76, text3=0.6, accent=0.74)
        container = oklch(0.36, CHROMA * 0.9, HUE)
        on_container = oklch(0.9, CHROMA * 0.55, HUE)
        on_accent = (0.05, 0.07, 0.1)
    else:
        values = dict(canvas=0.975, surface=1.0, alt=0.965, text=0.2, text2=0.45, text3=0.62, accent=0.56)
        container = oklch(0.92, CHROMA * 0.36, HUE)
        on_container = oklch(0.36, CHROMA * 0.45, HUE)
        on_accent = (1.0, 1.0, 1.0)
    pal = {k: oklch(v, n, HUE) for k, v in values.items() if k != "accent"}
    pal["accent"] = oklch(values["accent"], CHROMA, HUE)
    pal["container"] = container
    pal["on_container"] = on_container
    pal["on_accent"] = on_accent
    pal["danger"] = oklch(0.74 if dark else 0.56, 0.2, 25)
    pal["warning"] = oklch(0.74 if dark else 0.56, 0.16, 75)
    pal["success"] = oklch(0.74 if dark else 0.56, 0.15, 150)
    pal["stroke"] = (1, 1, 1) if dark else (0, 0, 0)
    return pal


def build_css(dark):
    p = palette(dark)
    c = {k: css_rgb(v) for k, v in p.items()}
    stroke = "rgba(255,255,255,.1)" if dark else "rgba(0,0,0,.1)"
    fill = "rgba(255,255,255,.08)" if dark else "rgba(0,0,0,.05)"
    fill_hover = "rgba(255,255,255,.12)" if dark else "rgba(0,0,0,.08)"
    return f"""
:root {{
  --accent-bg-color: {c['accent']}; --accent-fg-color: {c['on_accent']}; --accent-color: {c['accent']};
  --window-bg-color: {c['canvas']}; --window-fg-color: {c['text']};
  --view-bg-color: {c['surface']}; --view-fg-color: {c['text']};
  --headerbar-bg-color: {c['canvas']}; --headerbar-fg-color: {c['text']}; --headerbar-backdrop-color: {c['canvas']};
  --card-bg-color: {c['surface']}; --card-fg-color: {c['text']};
  --destructive-color: {c['danger']}; --warning-color: {c['warning']}; --success-color: {c['success']};
}}
window, label, entry, button, row {{ font-family: "Inter", "Adwaita Sans", "Cantarell", sans-serif; font-size: 14px; }}
headerbar {{ min-height: 50px; box-shadow: none; }}
headerbar .title {{ font-size: 15px; font-weight: 700; }}
button {{ min-height: 36px; border-radius: 10px; background: {fill}; transition: background 120ms {EASE}; }}
button:hover {{ background: {fill_hover}; }}
button.suggested-action {{ background: {c['accent']}; color: {c['on_accent']}; padding: 0 20px; font-weight: 600; }}
button.suggested-action:hover {{ background: {c['accent']}; opacity: .92; }}
button.suggested-action:disabled {{ opacity: .4; }}
button.flat {{ background: none; }}
button.flat:hover {{ background: {fill}; }}
windowcontrols button {{ min-height: 24px; min-width: 24px; border-radius: 99px; }}
.boxed-list, list.boxed-list {{ border-radius: 14px; background: {c['surface']}; box-shadow: 0 0 0 1px {stroke}; }}
row {{ min-height: 52px; }}
row.expander list row {{ min-height: 52px; }}
entry, searchbar entry {{ min-height: 36px; border-radius: 10px; background: {fill}; }}
.page-title {{ font-size: 22px; font-weight: 750; letter-spacing: -0.005em; }}
.page-sub {{ color: {c['text2']}; }}
.hero-title {{ font-size: 28px; font-weight: 800; letter-spacing: -0.005em; }}
.section-title {{ font-size: 15px; font-weight: 700; }}
.dim {{ color: {c['text2']}; }}
.caption-text {{ font-size: 12px; color: {c['text2']}; }}
.mono, textview.mono text {{ font-family: "Geist Mono", "JetBrains Mono", "Noto Sans Mono", monospace; font-size: 12px; }}
.choice {{ padding: 12px; border-radius: 14px; background: {c['surface']}; box-shadow: 0 0 0 1px {stroke}; transition: background 120ms {EASE}, box-shadow 120ms {EASE}; }}
.choice:hover {{ background: {c['alt']}; }}
.choice:checked {{ background: {c['surface']}; box-shadow: 0 0 0 2px {c['accent']}; }}
.choice:checked .choice-title {{ color: {c['accent']}; }}
.choice-title {{ font-weight: 600; }}
.caution {{ padding: 14px; border-radius: 14px; background: alpha({c['warning']}, .14); box-shadow: 0 0 0 1px alpha({c['warning']}, .35); }}
.caution-title {{ font-weight: 700; }}
.icon-tile {{ min-width: 32px; min-height: 32px; border-radius: 10px; background: {c['container']}; color: {c['on_container']}; }}
.command {{ padding: 12px 14px; border-radius: 10px; background: {c['alt']}; }}
.logbox {{ border-radius: 14px; background: {c['alt']}; box-shadow: 0 0 0 1px {stroke}; }}
.logbox textview, .logbox textview text {{ background: transparent; color: {c['text2']}; }}
.step-dot {{ min-width: 8px; min-height: 8px; border-radius: 99px; background: {fill_hover}; transition: background 220ms {EASE}; }}
.step-dot.done {{ background: {c['accent']}; }}
.actionbar {{ padding: 12px 24px; }}
progressbar trough, progressbar progress {{ min-height: 6px; border-radius: 99px; }}
progressbar progress {{ background: {c['accent']}; }}
.ok-text {{ color: {c['success']}; }}
.err-text {{ color: {c['danger']}; }}
"""


# ---------------------------------------------------------------- hardware --
def read(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def has_usb(vendor, product):
    base = "/sys/bus/usb/devices"
    try:
        names = os.listdir(base)
    except OSError:
        return False
    return any(read(f"{base}/{n}/idVendor") == vendor and read(f"{base}/{n}/idProduct") == product for n in names)


def has_pci(vendor, device):
    base = "/sys/bus/pci/devices"
    try:
        names = os.listdir(base)
    except OSError:
        return False
    return any(read(f"{base}/{n}/vendor") == f"0x{vendor}" and read(f"{base}/{n}/device") == f"0x{device}" for n in names)


def countries():
    rows = []
    for line in read("/usr/share/zoneinfo/iso3166.tab").splitlines():
        if line and not line.startswith("#") and "\t" in line:
            code, name = line.split("\t", 1)
            rows.append((code.strip(), name.strip()))
    return sorted(rows, key=lambda r: r[1].casefold())


def detect_country():
    """The system's regulatory country, else the one for the timezone."""
    try:
        out = subprocess.run(["iw", "reg", "get"], capture_output=True, text=True, timeout=3).stdout
        match = re.search(r"^country ([A-Z]{2}):", out, re.M)
        if match and match.group(1) != "00":
            return match.group(1)
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        zone = os.path.realpath("/etc/localtime").split("zoneinfo/", 1)[1]
    except IndexError:
        return ""
    for line in read("/usr/share/zoneinfo/zone.tab").splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and not line.startswith("#") and parts[2] == zone:
            return parts[0]
    return ""


def flag(code):
    return "".join(chr(0x1F1E6 + ord(c) - 65) for c in code)


def valid_mac(mac):
    """Same rules as validate_wifi_mac in the CLI. Returns an error, or None."""
    mac = mac.lower()
    if not re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
        return "Use the format aa:bb:cc:dd:ee:ff"
    if mac.startswith("00:90:4c"):
        return "This is Broadcom's placeholder, not your Mac's address"
    if int(mac[:2], 16) & 1:
        return "This is a multicast address"
    return None


# --------------------------------------------------------------- keyboards --
ROW_NUM = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]
ROW_Q = list("QWERTYUIOP[]")
ROW_A = list("ASDFGHJKL;'")
ROW_Z = list("ZXCVBNM,./")


def rounded(cr, x, y, w, h, r):
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
    cr.close_path()


def key_text(cr, text, x, y, w, h, color, size):
    cr.select_font_face("Inter", 0, 0)
    cr.set_font_size(size)
    ext = cr.text_extents(text)
    cr.set_source_rgb(*color)
    cr.move_to(x + (w - ext.width) / 2 - ext.x_bearing, y + (h - ext.height) / 2 - ext.y_bearing)
    cr.show_text(text)


def draw_key(cr, pal, x, y, w, h, u, text, mark=False):
    pad = max(1.0, u * 0.045)
    radius = max(2.0, u * 0.13)
    rounded(cr, x + pad, y + pad, w - 2 * pad, h - 2 * pad, radius)
    cr.set_source_rgb(*(pal["accent"] if mark else pal["surface"]))
    cr.fill_preserve()
    cr.set_source_rgba(*pal["stroke"], 0.16)
    cr.set_line_width(1)
    cr.stroke()
    if text:
        size = u * (0.3 if len(text) < 2 else 0.2)
        key_text(cr, text, x, y, w, h, pal["on_accent"] if mark else pal["text2"], size)


def draw_body(cr, pal, width, height):
    rounded(cr, 0, 0, width, height, min(width, height) * 0.05)
    cr.set_source_rgb(*pal["alt"])
    cr.fill()


def draw_layout(cr, width, height, pal, iso):
    """A MacBook keyboard. Marks what tells ANSI and ISO apart: Enter and left Shift."""
    draw_body(cr, pal, width, height)
    columns = 14.5
    margin = width * 0.03
    u = (width - 2 * margin) / columns
    rows_h = u * 5
    top = max(margin, (height - rows_h) / 2)

    def row(index, keys):
        x = margin
        for text, size, mark in keys:
            draw_key(cr, pal, x, top + index * u, size * u, u, u, text, mark)
            x += size * u

    plain = lambda items: [(t, 1, False) for t in items]
    row(0, [("§" if iso else "`", 1, False)] + plain(ROW_NUM) + [("del", 1.5, False)])
    if iso:
        row(1, [("tab", 1.5, False)] + plain(ROW_Q))
        row(2, [("caps", 1.75, False)] + plain(ROW_A) + [("\\", 1, False)])
        # Tall, L-shaped Enter over rows 1 and 2.
        pad = max(1.0, u * 0.045)
        right = margin + columns * u - pad
        x1 = margin + 13.5 * u + pad
        x2 = margin + 13.75 * u + pad
        y1, y2, y3 = top + u + pad, top + 2 * u + pad, top + 3 * u - pad
        cr.move_to(x1, y1)
        cr.line_to(right, y1)
        cr.line_to(right, y3)
        cr.line_to(x2, y3)
        cr.line_to(x2, y2)
        cr.line_to(x1, y2)
        cr.close_path()
        cr.set_source_rgb(*pal["accent"])
        cr.fill()
        key_text(cr, "enter", x2 - u * 0.25, y1, right - x2 + u * 0.25, y2 - y1, pal["on_accent"], u * 0.2)
        row(3, [("shift", 1.25, False), ("`", 1, True)] + plain(ROW_Z) + [("shift", 2.25, False)])
    else:
        row(1, [("tab", 1.5, False)] + plain(ROW_Q) + [("\\", 1, False)])
        row(2, [("caps", 1.75, False)] + plain(ROW_A) + [("enter", 1.75, True)])
        row(3, [("shift", 2.25, True)] + plain(ROW_Z) + [("shift", 2.25, False)])
    row(4, [("fn", 1, False), ("ctrl", 1, False), ("opt", 1, False), ("cmd", 1.25, False), ("", 5.25, False),
            ("cmd", 1.25, False), ("opt", 1, False), ("", 2.75, False)])


def draw_modifiers(cr, width, height, pal, windows, fn_swap):
    """The bottom row: what is printed on each key, and what it does with these options."""
    draw_body(cr, pal, width, height)
    keys = [
        ("fn", "Ctrl" if fn_swap else "Fn", fn_swap, 1),
        ("control", "Fn" if fn_swap else "Ctrl", fn_swap, 1),
        ("option", "Win" if windows else "Alt", windows, 1),
        ("command", "Alt" if windows else "Win", windows, 1.25),
        ("", "", False, 3.5),
        ("command", "AltGr" if windows else "Win", windows, 1.25),
        ("option", "AltGr", False, 1),
    ]
    units = sum(k[3] for k in keys)
    margin = width * 0.03
    u = (width - 2 * margin) / units
    key_h = min(u * 1.05, height * 0.72)
    y = (height - key_h) / 2
    x = margin
    for printed, does, changed, size in keys:
        w = size * u
        pad = 2.5
        rounded(cr, x + pad, y, w - 2 * pad, key_h, u * 0.13)
        cr.set_source_rgb(*(pal["accent"] if changed else pal["surface"]))
        cr.fill_preserve()
        cr.set_source_rgba(*pal["stroke"], 0.16)
        cr.set_line_width(1)
        cr.stroke()
        if printed:
            ink = pal["on_accent"] if changed else pal["text"]
            faint = pal["on_accent"] if changed else pal["text3"]
            key_text(cr, printed, x, y + key_h * 0.08, w, key_h * 0.3, faint, max(8.0, u * 0.14))
            key_text(cr, does, x, y + key_h * 0.42, w, key_h * 0.45, ink, max(11.0, u * 0.25))
        x += w


class Canvas(Gtk.DrawingArea):
    """Draws with the palette for the current light or dark mode."""

    def __init__(self, painter, height):
        super().__init__(content_height=height, hexpand=True)
        self.painter = painter
        self.set_draw_func(self._draw)
        Adw.StyleManager.get_default().connect("notify::dark", lambda *_: self.queue_draw())

    def _draw(self, _area, cr, width, height):
        self.painter(cr, width, height, palette(Adw.StyleManager.get_default().get_dark()))


# --------------------------------------------------------------------- app --
def label(text, css=None, wrap=True, xalign=0.0):
    widget = Gtk.Label(label=text, wrap=wrap, xalign=xalign, natural_wrap_mode=Gtk.NaturalWrapMode.WORD)
    for name in css or []:
        widget.add_css_class(name)
    return widget


def icon_tile(name):
    tile = Gtk.Image(icon_name=name, valign=Gtk.Align.CENTER, pixel_size=16)
    tile.add_css_class("icon-tile")
    return tile


def boxed(*rows):
    box = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
    box.add_css_class("boxed-list")
    for row in rows:
        box.append(row)
    return box


class Page(Gtk.ScrolledWindow):
    def __init__(self, title, subtitle=None):
        super().__init__(hscrollbar_policy=Gtk.PolicyType.NEVER, vexpand=True)
        self.heading = title
        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        clamp = Adw.Clamp(maximum_size=660, child=self.body, margin_top=24, margin_bottom=24, margin_start=24, margin_end=24)
        self.set_child(clamp)
        if title:
            head = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            head.append(label(title, ["page-title"]))
            if subtitle:
                head.append(label(subtitle, ["page-sub"]))
            self.body.append(head)

    def add(self, widget):
        self.body.append(widget)
        return widget


class Installer(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, default_width=760, default_height=680, title="MacBook Pro Setup")
        self.model = read("/sys/class/dmi/id/product_name", "unknown")
        self.has_t1 = has_usb("05ac", "8600")
        self.t1_recovery = has_usb("05ac", "1281")
        self.has_wifi = has_pci("14e4", "43ba")
        self.status = MODELS.get(self.model)
        applespi = read("/etc/modprobe.d/mbp132-applespi.conf")
        self.iso = "iso_layout=1" in applespi
        self.fn_swap = "fnremap=1" in applespi
        self.windows = "lv3:rwin_switch" in read("/etc/xdg/kxkbrc")
        self.country = detect_country()
        self.mac = ""
        self.force = False
        self.parts = dict(audio=True, touchbar=self.has_t1, sleep=True, wifi=self.has_wifi)
        self.proc = None
        self.running = False
        self.index = 0

        self.connect("close-request", self._on_close)
        self.title_widget = Adw.WindowTitle(title="MacBook Pro Setup")
        header = Adw.HeaderBar(title_widget=self.title_widget, show_start_title_buttons=False)
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT_RIGHT, transition_duration=220, vexpand=True)

        self.back = Gtk.Button(label="Back")
        self.back.connect("clicked", lambda *_: self.go(self.index - 1))
        self.next = Gtk.Button(label="Continue")
        self.next.add_css_class("suggested-action")
        self.next.connect("clicked", self._on_next)
        self.dots = Gtk.Box(spacing=8, hexpand=True, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        self.bar = Gtk.Box(spacing=8)
        self.bar.add_css_class("actionbar")
        for widget in (self.back, self.dots, self.next):
            self.bar.append(widget)

        self.pages = []
        for build in (self._welcome, self._keyboard, self._modifiers, self._wifi, self._components, self._review):
            page = build()
            if page is not None:
                self.pages.append(page)
                self.stack.add_child(page)
                dot = Gtk.Box()
                dot.add_css_class("step-dot")
                self.dots.append(dot)
        self.progress_page = self._progress()
        self.stack.add_child(self.progress_page)

        toolbar = Adw.ToolbarView(content=self.stack)
        toolbar.add_top_bar(header)
        toolbar.add_bottom_bar(self.bar)
        self.toasts = Adw.ToastOverlay(child=toolbar)
        self.set_content(self.toasts)
        self.go(0)

    # ------------------------------------------------------------ navigation
    def go(self, index):
        self.index = max(0, min(index, len(self.pages) - 1))
        page = self.pages[self.index]
        if page is self.review_page:
            self._refresh_review()
        self.stack.set_visible_child(page)
        self.title_widget.set_title(page.heading or "MacBook Pro Setup")
        self.back.set_visible(self.index > 0)
        self.next.set_label("Install" if page is self.review_page else "Continue")
        for i, dot in enumerate(self._dots()):
            if i <= self.index:
                dot.add_css_class("done")
            else:
                dot.remove_css_class("done")
        self._update_next()

    def _dots(self):
        child = self.dots.get_first_child()
        while child:
            yield child
            child = child.get_next_sibling()

    def _update_next(self):
        page = self.pages[self.index]
        ok = True
        if page is self.welcome_page:
            ok = bool(self.status) or self.force
        elif page is getattr(self, "wifi_page", None):
            ok = bool(self.country) and not (self.mac and valid_mac(self.mac))
        elif page is self.review_page:
            ok = any(self.parts.values()) or self.iso or self.fn_swap or self.windows
        self.next.set_sensitive(ok)

    def _on_next(self, *_):
        if self.pages[self.index] is self.review_page:
            self._install()
        else:
            self.go(self.index + 1)

    def _on_close(self, *_):
        if not self.running:
            return False
        dialog = Adw.AlertDialog(heading="Installation is still running",
                                 body="Stopping now can leave drivers half installed. Wait for it to finish.")
        dialog.add_response("ok", "Keep Waiting")
        dialog.present(self)
        return True

    # ----------------------------------------------------------------- pages
    def _welcome(self):
        page = self.welcome_page = Page("")
        hero = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin_top=8)
        hero.append(label("Set up Linux on your MacBook Pro", ["hero-title"]))
        hero.append(label("Audio, Touch Bar, sleep and Wi-Fi. A few questions, then one click.", ["page-sub"]))
        page.add(hero)

        caution = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        caution.add_css_class("caution")
        caution.append(label("Keep the macOS EFI partition", ["caution-title"]))
        caution.append(label("It holds the T1 chip's firmware. Without it the Touch Bar, camera, Touch ID and light "
                             "sensor stop working, and only reinstalling macOS brings it back.", ["dim"]))
        page.add(caution)

        status = {"tested": "Tested", "untested": "Supported, not tested yet"}.get(self.status, "Not supported")
        rows = [self._row("computer-symbolic", self.model, status)]
        if self.t1_recovery:
            rows.append(self._row("dialog-warning-symbolic", "Touch Bar firmware is missing",
                                  "The T1 chip is in recovery mode. Reinstall macOS or restore the EFI folder."))
        else:
            rows.append(self._row("input-keyboard-symbolic", "Touch Bar", "Found" if self.has_t1 else "Not found on this Mac"))
        rows.append(self._row("network-wireless-symbolic", "BCM43602 Wi-Fi", "Found" if self.has_wifi else "Not found, no settings needed"))
        page.add(boxed(*rows))

        if not self.status:
            row = Adw.SwitchRow(title="Run on this model anyway", subtitle="This script is made for 2016-2017 MacBook Pros")
            row.connect("notify::active", self._on_force)
            page.add(boxed(row))
        return page

    def _on_force(self, row, *_):
        self.force = row.get_active()
        self._update_next()

    def _row(self, icon, title, subtitle=None):
        row = Adw.ActionRow(title=title, subtitle=subtitle or "", use_markup=False)
        row.add_prefix(icon_tile(icon))
        return row

    def _keyboard(self):
        page = Page("Keyboard layout", "Look at your Enter key and the key next to left Shift.")
        grid = Gtk.Box(spacing=12, homogeneous=True)
        ansi = self._choice("US (ANSI)", "Wide Enter, long left Shift",
                            Canvas(lambda cr, w, h, p: draw_layout(cr, w, h, p, False), 160), not self.iso)
        iso = self._choice("International (ISO)", "Tall Enter, an extra key next to left Shift",
                           Canvas(lambda cr, w, h, p: draw_layout(cr, w, h, p, True), 160), self.iso)
        iso.set_group(ansi)
        iso.connect("toggled", lambda b: setattr(self, "iso", b.get_active()))
        grid.append(ansi)
        grid.append(iso)
        page.add(grid)
        page.add(label("ISO fixes the swapped keys next to left Shift and below Esc. Your language is set separately, "
                       "in your desktop's keyboard settings.", ["caption-text"]))
        return page

    def _choice(self, title, subtitle, canvas, active):
        inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        inner.append(canvas)
        inner.append(label(title, ["choice-title"], xalign=0.5))
        inner.append(label(subtitle, ["caption-text"], xalign=0.5))
        button = Gtk.ToggleButton(child=inner, active=active)
        button.add_css_class("choice")
        return button

    def _modifiers(self):
        page = Page("Modifier keys", "Each key shows its printed name and what it will do.")
        canvas = Canvas(lambda cr, w, h, p: draw_modifiers(cr, w, h, p, self.windows, self.fn_swap), 120)
        page.add(canvas)

        win = Adw.SwitchRow(title="Windows-style keys", subtitle="Ctrl, Win, Alt in Windows order, with AltGr on the "
                            "right Command and Option keys. KDE Plasma only.", active=self.windows)
        win.add_prefix(icon_tile("input-keyboard-symbolic"))
        swap = Adw.SwitchRow(title="Swap Fn and left Ctrl", subtitle="Puts Ctrl in the corner, as on most other laptops.",
                             active=self.fn_swap)
        swap.add_prefix(icon_tile("input-keyboard-symbolic"))

        def changed(row, _pspec, name):
            setattr(self, name, row.get_active())
            canvas.queue_draw()

        win.connect("notify::active", changed, "windows")
        swap.connect("notify::active", changed, "fn_swap")
        page.add(boxed(win, swap))
        return page

    def _wifi(self):
        if not self.has_wifi:
            return None
        page = self.wifi_page = Page("Wi-Fi country", "Decides which channels your Wi-Fi may use, so 5 GHz works with your router.")
        names = dict(countries())
        current = Adw.ActionRow(use_markup=False)
        current.add_prefix(icon_tile("emblem-ok-symbolic"))

        def show_country():
            code = self.country
            current.set_title(f"{flag(code)}  {names.get(code, code)}" if code else "Choose your country")
            current.set_subtitle("Selected" if code else "Needed for 5 GHz")

        show_country()
        page.add(boxed(current))
        search = Gtk.SearchEntry(placeholder_text="Search countries")
        page.add(search)

        listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE, activate_on_single_click=True)
        listbox.add_css_class("boxed-list")
        selected = None
        for code, name in countries():
            row = Adw.ActionRow(title=f"{flag(code)}  {name}", subtitle=code, use_markup=False)
            row.code, row.search = code, f"{name} {code}".casefold()
            listbox.append(row)
            if code == self.country:
                selected = row
        query = {"text": ""}
        listbox.set_filter_func(lambda row: query["text"] in row.search)

        def on_search(entry):
            query["text"] = entry.get_text().casefold().strip()
            listbox.invalidate_filter()

        def on_select(_box, row):
            if row is not None:
                self.country = row.code
                show_country()
                self._update_next()

        search.connect("search-changed", on_search)
        listbox.connect("row-selected", on_select)
        if selected is not None:
            listbox.select_row(selected)
        scroller = Gtk.ScrolledWindow(child=listbox, min_content_height=250, hscrollbar_policy=Gtk.PolicyType.NEVER)
        scroller.add_css_class("boxed-list")
        page.add(scroller)

        entry = Adw.EntryRow(title="Real Wi-Fi MAC address (optional)")
        entry.add_prefix(icon_tile("network-wireless-symbolic"))
        hint = label("Without it a stable made-up address is used, which works fine. macOS shows the real one with "
                     "ifconfig en0.", ["caption-text"])

        def on_mac(row):
            self.mac = row.get_text().strip()
            error = valid_mac(self.mac) if self.mac else None
            if error:
                row.add_css_class("error")
                hint.set_label(error)
            else:
                row.remove_css_class("error")
                hint.set_label("Without it a stable made-up address is used, which works fine. macOS shows the real "
                               "one with ifconfig en0.")
            self._update_next()

        entry.connect("changed", on_mac)
        page.add(boxed(entry))
        page.add(hint)
        return page

    def _components(self):
        page = Page("What to install", "Everything is on by default, and you can run this again at any time.")
        items = [
            ("audio", "audio-speakers-symbolic", "Audio", "Speakers and microphone driver, even volume steps", True),
            ("touchbar", "input-keyboard-symbolic", "Touch Bar", "Touch Bar and ambient light sensor driver", self.has_t1),
            ("sleep", "weather-clear-night-symbolic", "Sleep", "Reliable suspend. Press a key or the power button to wake", True),
            ("wifi", "network-wireless-symbolic", "Wi-Fi", "Calibration, 5 GHz, and recovery after sleep", self.has_wifi),
        ]
        rows = []
        for key, icon, title, subtitle, available in items:
            row = Adw.SwitchRow(title=title, subtitle=subtitle if available else "Not found on this Mac",
                                active=self.parts[key], sensitive=available)
            row.add_prefix(icon_tile(icon))
            row.connect("notify::active", self._on_part, key)
            rows.append(row)
        page.add(boxed(*rows))
        return page

    def _on_part(self, row, _pspec, key):
        self.parts[key] = row.get_active()

    def _review(self):
        page = self.review_page = Page("Ready to install", "You'll be asked for your password. Reboot when it's done.")
        self.summary = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.summary.add_css_class("boxed-list")
        page.add(self.summary)
        page.add(label("Same as running", ["section-title"]))
        box = Gtk.Box(spacing=8)
        box.add_css_class("command")
        self.command_label = label("", ["mono"])
        self.command_label.set_hexpand(True)
        self.command_label.set_selectable(True)
        box.append(self.command_label)
        copy = Gtk.Button(icon_name="edit-copy-symbolic", tooltip_text="Copy", valign=Gtk.Align.CENTER)
        copy.add_css_class("flat")
        copy.connect("clicked", lambda *_: self._copy(self.command_text()))
        box.append(copy)
        page.add(box)
        return page

    def args(self):
        out = []
        if self.iso:
            out.append("--iso")
        if self.fn_swap:
            out.append("--fn-ctrl-swap")
        if self.windows:
            out.append("--windows-keys")
        if not self.parts["audio"]:
            out.append("--no-audio")
        if not self.parts["touchbar"] and self.has_t1:
            out.append("--no-touchbar")
        if not self.parts["sleep"]:
            out.append("--no-sleep")
        if not self.parts["wifi"] and self.has_wifi:
            out.append("--no-wifi")
        if self.parts["wifi"] and self.has_wifi:
            if self.country:
                out += ["--wifi-country", self.country]
            if self.mac:
                out += ["--wifi-mac", self.mac.lower()]
        if self.force:
            out.append("--force")
        return out

    def command_text(self):
        return " ".join(["sudo", "./mbp132-setup-cli.sh"] + [shlex.quote(a) for a in self.args()])

    def _refresh_review(self):
        while (child := self.summary.get_first_child()) is not None:
            self.summary.remove(child)
        names = dict(countries())
        on = [n for k, n in (("audio", "Audio"), ("touchbar", "Touch Bar"), ("sleep", "Sleep"), ("wifi", "Wi-Fi")) if self.parts[k]]
        rows = [
            ("input-keyboard-symbolic", "Keyboard", "International (ISO)" if self.iso else "US (ANSI)"),
            ("input-keyboard-symbolic", "Modifier keys",
             ", ".join(n for f, n in ((self.windows, "Windows-style"), (self.fn_swap, "Fn and Ctrl swapped")) if f) or "Mac defaults"),
        ]
        if self.has_wifi and self.parts["wifi"]:
            rows.append(("network-wireless-symbolic", "Wi-Fi country", names.get(self.country, self.country)))
            rows.append(("network-wireless-symbolic", "Wi-Fi address", self.mac or "Stable made-up address"))
        rows.append(("emblem-system-symbolic", "Installing", ", ".join(on) or "Keyboard settings only"))
        for icon, title, value in rows:
            self.summary.append(self._row(icon, title, value))
        self.command_label.set_label(self.command_text())
        self._update_next()

    def _copy(self, text):
        self.get_display().get_clipboard().set(text)
        self.toasts.add_toast(Adw.Toast(title="Copied", timeout=2))

    # -------------------------------------------------------------- progress
    def _progress(self):
        page = Page("")
        self.progress_title = label("Installing", ["page-title"])
        self.progress_sub = label("Waiting for your password", ["page-sub"])
        page.add(self.progress_title)
        page.add(self.progress_sub)
        self.progress_bar = Gtk.ProgressBar()
        page.add(self.progress_bar)
        self.log_buffer = Gtk.TextBuffer()
        view = Gtk.TextView(buffer=self.log_buffer, editable=False, cursor_visible=False, monospace=True,
                            wrap_mode=Gtk.WrapMode.WORD_CHAR, left_margin=12, right_margin=12, top_margin=12, bottom_margin=12)
        view.add_css_class("mono")
        self.log_scroller = Gtk.ScrolledWindow(child=view, vexpand=True, min_content_height=300)
        self.log_scroller.add_css_class("logbox")
        page.add(self.log_scroller)
        return page

    def _install(self):
        self.stack.set_visible_child(self.progress_page)
        self.title_widget.set_title("Installing")
        self.dots.set_visible(False)
        self.back.set_visible(False)
        self.next.set_visible(False)
        self.progress_title.set_label("Installing")
        self.progress_sub.set_label("Waiting for your password")
        self.progress_bar.set_fraction(0.02)
        self.log_buffer.set_text("")
        self.running = True
        launcher = Gio.SubprocessLauncher.new(Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE)
        launcher.set_cwd(ROOT)
        try:
            self.proc = launcher.spawnv(["pkexec", CLI] + self.args())
        except GLib.Error as error:
            self._finished(False, error.message)
            return
        self.stream = Gio.DataInputStream.new(self.proc.get_stdout_pipe())
        self._read_line()
        self.proc.wait_check_async(None, self._on_exit)

    def _read_line(self):
        self.stream.read_line_async(GLib.PRIORITY_DEFAULT, None, self._on_line)

    def _on_line(self, stream, result):
        try:
            data, _length = stream.read_line_finish(result)
        except GLib.Error:
            return
        if data is None:
            return
        line = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", data.decode("utf-8", "replace")).rstrip("\r")
        self._log(line)
        self._phase(line)
        self._read_line()

    def _log(self, line):
        end = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end, line + "\n")
        adjustment = self.log_scroller.get_vadjustment()
        GLib.idle_add(lambda: adjustment.set_value(adjustment.get_upper()) and False)

    def _phase(self, line):
        phases = (("Installing dependencies", 0.06, "Installing dependencies"),
                  ("Audio:", 0.15, "Building the audio driver"),
                  ("Touch Bar:", 0.45, "Building the Touch Bar driver"),
                  ("Keyboard:", 0.6, "Setting up the keyboard"),
                  ("Sleep:", 0.66, "Setting up sleep"),
                  ("Wi-Fi:", 0.72, "Setting up Wi-Fi"),
                  ("Rebuilding initramfs", 0.78, "Rebuilding the boot image"),
                  ("All done", 1.0, "Finishing"))
        for needle, fraction, text in phases:
            if needle in line:
                self.progress_bar.set_fraction(fraction)
                self.progress_sub.set_label(text)

    def _on_exit(self, proc, result):
        try:
            proc.wait_check_finish(result)
            self._finished(True)
        except GLib.Error:
            status = proc.get_exit_status() if proc.get_if_exited() else -1
            if status in (126, 127):
                self._finished(False, "Password dialog was cancelled. Nothing was changed.", cancelled=True)
            else:
                self._finished(False, f"The installer stopped with an error (code {status}). See the log above.")

    def _finished(self, success, message="", cancelled=False):
        self.running = False
        self.bar.remove(self.next)
        self.bar.remove(self.back)
        self.bar.remove(self.dots)
        if success:
            self.title_widget.set_title("Done")
            self.progress_bar.set_fraction(1.0)
            self.progress_title.set_label("All done")
            self.progress_title.add_css_class("ok-text")
            self.progress_sub.set_label("Reboot to apply. After that, hold Fn for F1-F12, and press a key to wake from sleep.")
            left, right = Gtk.Button(label="Later"), Gtk.Button(label="Reboot Now")
            left.connect("clicked", lambda *_: self.close())
            right.add_css_class("suggested-action")
            right.connect("clicked", self._reboot)
        else:
            self.title_widget.set_title("Stopped" if cancelled else "Failed")
            self.progress_title.set_label("Not installed" if cancelled else "Something went wrong")
            self.progress_title.add_css_class("err-text")
            self.progress_sub.set_label(message)
            left = Gtk.Button(label="Copy Log")
            left.connect("clicked", lambda *_: self._copy(self.log_buffer.get_text(self.log_buffer.get_start_iter(), self.log_buffer.get_end_iter(), True)))
            right = Gtk.Button(label="Back")
            right.add_css_class("suggested-action")
            right.connect("clicked", self._retry)
        spacer = Gtk.Box(hexpand=True)
        self._final_widgets = [left, spacer, right]
        for widget in self._final_widgets:
            self.bar.append(widget)

    def _retry(self, *_):
        for widget in self._final_widgets:
            self.bar.remove(widget)
        for widget in (self.back, self.dots, self.next):
            self.bar.append(widget)
        self.dots.set_visible(True)
        self.next.set_visible(True)
        self.progress_title.remove_css_class("err-text")
        self.go(self.index)

    def _reboot(self, *_):
        subprocess.Popen(["systemctl", "reboot"])


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.provider = Gtk.CssProvider()

    def do_startup(self):
        Adw.Application.do_startup(self)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), self.provider,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        manager = Adw.StyleManager.get_default()
        manager.set_color_scheme(Adw.ColorScheme.DEFAULT)
        manager.connect("notify::dark", lambda *_: self._style())
        self._style()

    def _style(self):
        self.provider.load_from_string(build_css(Adw.StyleManager.get_default().get_dark()))

    def do_activate(self):
        window = self.get_active_window() or Installer(self)
        window.present()


if __name__ == "__main__":
    if os.geteuid() == 0:
        sys.exit("Run this as your normal user. It asks for your password when it installs.")
    sys.exit(App().run(sys.argv))
