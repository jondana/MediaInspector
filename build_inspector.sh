#!/bin/bash
set -e
export MACOSX_DEPLOYMENT_TARGET="11.0"

echo "=================================================="
echo "   🔍 Building Standalone MediaInspector App      "
echo "=================================================="

# Define Path to Custom Icon (falls back to MediaEngine icon or auto-generates)
ICON_SRC="$HOME/Desktop/Personal/MediaInspector.png"
if [ ! -f "$ICON_SRC" ]; then
    ICON_SRC="$HOME/Desktop/Personal/Inspector.png"
fi

# 1. Detect Python with Tkinter
PYTHON_EXEC=""
for candidate in python3.12 python3.11 python3.13 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if "$candidate" -c "import tkinter" >/dev/null 2>&1; then
            PYTHON_EXEC="$(command -v "$candidate")"
            echo "✔ Found compatible Python: $PYTHON_EXEC"
            break
        fi
    fi
done

if [ -z "$PYTHON_EXEC" ]; then
    echo "❌ ERROR: No Python with Tkinter found. Run: brew install python-tk"
    exit 1
fi

WORKDIR="$HOME/Desktop/InspectorBuild"
VENV_DIR="/tmp/inspector_build_venv"
BIN_CACHE="$HOME/Desktop/static_bin"

rm -rf "$WORKDIR" "$VENV_DIR"
mkdir -p "$WORKDIR" "$BIN_CACHE"
cd "$WORKDIR"

# 2. Acquire True Static FFprobe Binary
echo "📦 Checking standalone FFprobe binary..."
ARCH=$(uname -m)

if [ ! -f "$BIN_CACHE/ffprobe" ]; then
    echo "⬇️ Downloading standalone static FFprobe binary for $ARCH..."
    if [ "$ARCH" = "arm64" ]; then
        URL_FFPROBE="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip"
    else
        URL_FFPROBE="https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffprobe.zip"
    fi
    (curl -L -f -o /tmp/ffprobe.zip "$URL_FFPROBE" && unzip -o /tmp/ffprobe.zip -d "$BIN_CACHE/" && rm -f /tmp/ffprobe.zip) || true
    if [ "$ARCH" != "arm64" ] && [ ! -f "$BIN_CACHE/ffprobe" ]; then
        echo "⬇️ Falling back to Evermeet static archive for Intel..."
        (curl -L -f -o /tmp/ffprobe.zip "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip" && unzip -o /tmp/ffprobe.zip -d "$BIN_CACHE/" && rm -f /tmp/ffprobe.zip) || true
    fi
    find "$BIN_CACHE" -mindepth 2 -type f -name "ffprobe" -exec mv -f {} "$BIN_CACHE/ffprobe" \; 2>/dev/null || true
    if [ ! -f "$BIN_CACHE/ffprobe" ]; then
        echo "❌ ERROR: Failed to acquire static FFprobe binary."
        exit 1
    fi
    chmod +x "$BIN_CACHE/ffprobe" 2>/dev/null || true
fi

# 3. Setup Virtualenv & Build Dependencies
echo "📦 Setting up virtual build environment..."
"$PYTHON_EXEC" -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
if [ "$ARCH" = "arm64" ]; then
    "$VENV_DIR/bin/pip" install pyinstaller customtkinter tkinterdnd2-universal pillow --quiet || \
    "$VENV_DIR/bin/pip" install pyinstaller customtkinter tkinterdnd2 pillow --quiet
else
    "$VENV_DIR/bin/pip" install pyinstaller customtkinter tkinterdnd2 pillow --quiet || \
    "$VENV_DIR/bin/pip" install pyinstaller customtkinter tkinterdnd2-universal pillow --quiet
fi

# PyInstaller hook for tkinterdnd2
cat << 'HOOKEOF' > hook-tkinterdnd2.py
from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs
datas = collect_data_files('tkinterdnd2')
binaries = collect_dynamic_libs('tkinterdnd2')
HOOKEOF

# 4. Write Python Code
cat << 'PYEOF' > media_inspector_gui.py
import os
import sys
import re
import json
import math
import urllib.parse
import unicodedata
import shutil
import signal
import subprocess
import threading
import queue
import time
import tkinter as tk
from tkinter import messagebox, filedialog
import customtkinter as ctk
import webbrowser

_GLOBAL_APP_INSTANCE = None

# Neutralize default CTk wheel bindings to prevent interference with kinetic physics
try:
    import customtkinter.windows.widgets.ctk_scrollable_frame as ctk_sf
    import customtkinter.windows.widgets.ctk_textbox as ctk_tb

    ctk_sf.CTkScrollableFrame._set_mouse_wheel_for_children = lambda self, widget, enable=True: None
    ctk_sf.CTkScrollableFrame._enable_mouse_wheel_for_children = lambda self, widget: None
    ctk_sf.CTkScrollableFrame._mouse_wheel_all = lambda self, event: None
    ctk_sf.CTkScrollableFrame._mouse_wheel_windows = lambda self, event: None
    ctk_sf.CTkScrollableFrame._mouse_wheel_linux = lambda self, event: None
    ctk_tb.CTkTextbox._mouse_wheel_all = lambda self, event: None
except Exception:
    pass

if getattr(sys, 'frozen', False):
    base_dir = getattr(sys, '_MEIPASS', os.path.dirname(sys.executable))
    parent_dir = os.path.dirname(base_dir)
    for sub in [
        os.path.join(base_dir, "_internal", "tkinterdnd2", "tkdnd"),
        os.path.join(base_dir, "_internal", "tkdnd"),
        os.path.join(base_dir, "tkinterdnd2", "tkdnd"),
        os.path.join(base_dir, "tkdnd"),
        os.path.join(parent_dir, "Resources", "tkdnd"),
        os.path.join(parent_dir, "Resources", "tkinterdnd2", "tkdnd"),
        os.path.join(parent_dir, "Frameworks", "tkinterdnd2", "tkdnd"),
    ]:
        if os.path.isdir(sub):
            os.environ["TKDND_LIBRARY"] = sub
            break

try:
    from tkinterdnd2 import TkinterDnD, DND_FILES
    HAS_TKDND = True
except ImportError:
    HAS_TKDND = False

if getattr(sys, 'frozen', False):
    BUNDLE_DIR = os.path.dirname(sys.executable)
else:
    BUNDLE_DIR = os.path.dirname(os.path.abspath(__file__))
INTERNAL_BIN = os.path.join(BUNDLE_DIR, "bin")
os.environ["PATH"] = f"{BUNDLE_DIR}:{INTERNAL_BIN}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:{os.environ.get('PATH', '')}"

def find_binary(name):
    for candidate_dir in (BUNDLE_DIR, INTERNAL_BIN):
        internal = os.path.join(candidate_dir, name)
        if os.path.exists(internal) and os.access(internal, os.X_OK):
            return internal
    found = shutil.which(name)
    if found and os.path.exists(found):
        return found
    return name

FFPROBE_BIN = find_binary("ffprobe")

SUPPORTED_EXTENSIONS = (
    ".mp4", ".mov", ".mkv", ".m4v", ".avi", ".crm", ".raw", ".wmv", ".flv",
    ".webm", ".ts", ".mts", ".m2ts", ".vob", ".ogv", ".m2v", ".mxf",
    ".jpg", ".jpeg", ".png", ".tiff", ".tif", ".webp", ".heic", ".bmp", ".gif", ".dng", ".cr2", ".nef", ".arw",
    ".mp3", ".wav", ".aac", ".m4a", ".flac", ".aiff", ".aif", ".ogg", ".wma", ".opus", ".m4r", ".ac3", ".eac3"
)

def format_detailed_duration(seconds):
    if seconds is None:
        return "N/A"
    try:
        s = float(seconds)
    except (ValueError, TypeError):
        return str(seconds)
    if s < 0:
        return "N/A"
    total_sec = int(s)
    hours = total_sec // 3600
    mins = (total_sec % 3600) // 60
    secs = total_sec % 60
    clock = f"{hours:02d}:{mins:02d}:{secs:02d}" if hours > 0 else f"{mins:02d}:{secs:02d}"
    return f"{clock} ({s:.2f} s)"

def format_time_duration(seconds, force_hours=False):
    if seconds is None:
        return "--:--"
    try:
        s = float(seconds)
    except (ValueError, TypeError):
        return "--:--"
    if s < 0:
        return "--:--"
    total_sec = int(round(s))
    hours = total_sec // 3600
    mins = (total_sec % 3600) // 60
    secs = total_sec % 60
    if hours > 0 or force_hours:
        return f"{hours:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"

def format_bitrate_str(bps):
    if not bps:
        return "N/A"
    try:
        b = float(bps)
    except (ValueError, TypeError):
        return str(bps)
    if b >= 1_000_000_000:
        return f"{b / 1_000_000_000:.2f} Gb/s"
    elif b >= 1_000_000:
        return f"{b / 1_000_000:.1f} Mb/s"
    elif b >= 1_000:
        return f"{b / 1_000:.0f} kb/s"
    return f"{int(b)} b/s"

def format_bytes_size_str(n_bytes, total_bytes=None):
    if not n_bytes:
        return "N/A"
    try:
        b = float(n_bytes)
    except (ValueError, TypeError):
        return str(n_bytes)
    if b >= (1024**3):
        h_str = f"{b / (1024**3):.2f} GB"
    elif b >= (1024**2):
        h_str = f"{b / (1024**2):.2f} MB"
    elif b >= 1024:
        h_str = f"{b / 1024:.1f} KB"
    else:
        h_str = f"{int(b)} Bytes"
    comma_b = f"{int(b):,}"
    if total_bytes and total_bytes > 0:
        pct = (b / total_bytes) * 100.0
        return f"{h_str} ({comma_b} bytes, {pct:.1f}%)"
    return f"{h_str} ({comma_b} bytes)"

def get_common_resolution_label(width, height):
    try:
        w, h = int(width), int(height)
    except Exception:
        return ""
    mapping = {
        (7680, 4320): "8K UHD", (3840, 2160): "4K UHD", (4096, 2160): "DCI 4K",
        (2560, 1440): "2K QHD", (2048, 1080): "2K DCI", (1920, 1080): "Full HD 1080p",
        (1280, 720): "HD 720p", (720, 480): "NTSC 480p", (720, 576): "PAL 576p",
        (1080, 1920): "Vertical Full HD", (2160, 3840): "Vertical 4K"
    }
    label = mapping.get((w, h))
    return f" ({label})" if label else ""

def analyze_pix_fmt(pix_fmt, raw_bits=None):
    pf = str(pix_fmt or "").lower()
    bit_depth = None
    if raw_bits:
        try:
            bit_depth = f"{int(raw_bits)}-Bit"
        except (ValueError, TypeError):
            pass
    if not bit_depth:
        if any(x in pf for x in ("16le", "16be", "16")):
            bit_depth = "16-Bit"
        elif any(x in pf for x in ("12le", "12be", "12")):
            bit_depth = "12-Bit"
        elif any(x in pf for x in ("10le", "10be", "10", "p010", "p210")):
            bit_depth = "10-Bit"
        elif any(x in pf for x in ("9le", "9be", "9")):
            bit_depth = "9-Bit"
        elif pf:
            bit_depth = "8-Bit"
        else:
            bit_depth = "N/A"

    chroma = "N/A"
    if any(x in pf for x in ("420", "nv12", "nv21", "p010", "yuvj420")):
        chroma = "4:2:0"
    elif any(x in pf for x in ("422", "nv16", "p210", "yuvj422")):
        chroma = "4:2:2"
    elif any(x in pf for x in ("444", "nv24", "yuvj444", "rgb", "bgr")):
        chroma = "4:4:4"
    elif "411" in pf:
        chroma = "4:1:1"
    elif any(x in pf for x in ("gray", "ya8", "ya16")):
        chroma = "Monochrome (4:0:0)"
    return chroma, bit_depth

def get_codec_config_box(codec_name, codec_tag):
    cn = str(codec_name or "").lower()
    ct = str(codec_tag or "").strip()
    if "hevc" in cn or "h265" in cn or "hvc1" in ct or "hev1" in ct:
        return "hvcC"
    elif "h264" in cn or "avc" in cn or "avc1" in ct:
        return "avcC"
    elif "vp9" in cn or "vp09" in ct:
        return "vpcC"
    elif "av1" in cn or "av01" in ct:
        return "av1C"
    elif "prores" in cn or "apc" in ct:
        return "fiel / colr"
    elif "mp4v" in ct:
        return "esds"
    elif "aac" in cn or "mp4a" in ct:
        return "esds"
    elif "ac3" in cn or "ac-3" in cn:
        return "dac3"
    elif "eac3" in cn:
        return "dec3"
    return ct or "N/A"

def get_frame_rate_mode(stream):
    r_str = stream.get("r_frame_rate", "")
    avg_str = stream.get("avg_frame_rate", "")
    if r_str and avg_str and r_str != "0/0" and avg_str != "0/0":
        return "Constant (CFR)" if r_str == avg_str else "Variable (VFR)"
    return "Constant (CFR)"

def calculate_bpp(bitrate, width, height, fps):
    try:
        b = float(bitrate)
        w = float(width)
        h = float(height)
        f = float(fps)
        if w > 0 and h > 0 and f > 0 and b > 0:
            return round(b / (w * h * f), 3)
    except Exception:
        pass
    return None

def parse_stream_fps_val(stream):
    for k in ("avg_frame_rate", "r_frame_rate"):
        val = stream.get(k)
        if val and val != "0/0" and val != "N/A":
            if "/" in val:
                num, den = val.split("/", 1)
                try:
                    den_f = float(den)
                    if den_f > 0:
                        return float(num) / den_f
                except (ValueError, ZeroDivisionError):
                    pass
            else:
                try:
                    return float(val)
                except ValueError:
                    pass
    return None

def clean_file_path(raw_path):
    p = unicodedata.normalize('NFC', str(raw_path).strip())
    if p.startswith("file://localhost/"):
        p = "/" + p[17:]
    elif p.startswith("file:///"):
        p = "/" + p[8:]
    elif p.startswith("file://"):
        p = "/" + p[7:].lstrip("/")
    p = urllib.parse.unquote(p)
    changed = True
    while changed:
        changed = False
        for open_c, close_c in [('{', '}'), ('"', '"'), ("'", "'")]:
            if not os.path.exists(p) and p.startswith(open_c) and p.endswith(close_c) and len(p) >= 2:
                cand = p[1:-1].strip()
                if os.path.exists(cand) or not os.path.exists(p):
                    p = cand
                    changed = True
    if p.startswith("file://localhost/"):
        p = "/" + p[17:]
    elif p.startswith("file:///"):
        p = "/" + p[8:]
    elif p.startswith("file://"):
        p = "/" + p[7:].lstrip("/")
    return urllib.parse.unquote(p).strip()

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")

BG_MAIN = "#141416"
CARD_BG = "#1a1a20"
CARD_BORDER = "#282832"
TEXT_PRIMARY = "#f4f4f6"
TEXT_MUTED = "#8e8e9a"
ACCENT_BLUE = "#2563eb"
ACCENT_BLUE_HOVER = "#1d4ed8"
NEUTRAL_BTN = "#2a2a34"
NEUTRAL_BTN_HOVER = "#383846"
ULTRA_BG = "#0f191e"
ULTRA_BORDER = "#1c2e37"
ULTRA_TEXT = "#46748A"

SETTINGS_DIR = os.path.expanduser("~/Library/Application Support/MediaInspector")
SETTINGS_FILE = os.path.join(SETTINGS_DIR, "settings.json")

def load_app_settings():
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        pass
    return {}

def save_app_settings(settings):
    try:
        os.makedirs(SETTINGS_DIR, exist_ok=True)
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2)
    except Exception:
        pass

# ============================================================
# 120 FPS UNIVERSAL SUB-PIXEL QUARTZ KINETIC SCROLL ENGINE
# ============================================================
class QuartzKineticScroller:
    def __init__(self, get_view_metrics, set_view_fraction, after_fn, cancel_after_fn=None, smooth_time=0.08):
        self.get_view_metrics = get_view_metrics
        self.set_view_fraction = set_view_fraction
        self.after_fn = after_fn
        self.cancel_after_fn = cancel_after_fn
        self.smooth_time = smooth_time

        self.current_y = 0.0
        self.target_y = 0.0
        self.velocity = 0.0
        self.is_animating = False
        self.last_frame_time = 0.0
        self._anim_job = None

    def sync_position(self):
        if self.is_animating:
            return
        if self._anim_job and self.cancel_after_fn:
            try:
                self.cancel_after_fn(self._anim_job)
            except Exception:
                pass
            self._anim_job = None

        metrics = self.get_view_metrics()
        if metrics:
            view_h, total_h, frac = metrics
            max_scroll = max(0.0, total_h - view_h)
            self.current_y = max(0.0, min(max_scroll, frac * total_h))
            self.target_y = self.current_y
            self.velocity = 0.0

    def handle_wheel_input(self, delta_input):
        metrics = self.get_view_metrics()
        if not metrics:
            return
        view_h, total_h, frac = metrics
        if total_h <= view_h or total_h <= 0:
            return

        max_scroll_px = total_h - view_h
        if not self.is_animating:
            calc_y = frac * total_h
            if abs(self.current_y - calc_y) > 35.0:
                self.current_y = max(0.0, min(max_scroll_px, calc_y))
            self.target_y = self.current_y
            self.velocity = 0.0

        if abs(delta_input) >= 60:
            norm = delta_input / 120.0
        else:
            norm = delta_input

        magnitude = abs(norm)
        accel = min(4.2, 1.0 + (magnitude * 0.12))
        impulse = -math.copysign((magnitude ** 1.18) * 7.0 * accel, norm)

        self.target_y = max(0.0, min(max_scroll_px, self.target_y + impulse))

        if not self.is_animating:
            self.is_animating = True
            self.last_frame_time = time.perf_counter()
            self._physics_step()

    def _physics_step(self):
        self._anim_job = None
        try:
            metrics = self.get_view_metrics()
            if not metrics:
                self.is_animating = False
                return

            view_h, total_h, frac = metrics
            if total_h <= view_h or total_h <= 0:
                self.is_animating = False
                self.set_view_fraction(0.0)
                return

            max_scroll_px = max(0.0, total_h - view_h)
            self.target_y = max(0.0, min(max_scroll_px, self.target_y))

            now = time.perf_counter()
            dt = min(0.05, max(0.001, now - self.last_frame_time))
            self.last_frame_time = now

            omega = 2.0 / max(0.03, self.smooth_time)
            x = omega * dt
            exp = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
            change = self.current_y - self.target_y
            temp = (self.velocity + omega * change) * dt
            self.velocity = (self.velocity - omega * temp) * exp
            next_y = self.target_y + (change + temp) * exp

            if abs(self.target_y - next_y) < 0.4 and abs(self.velocity) < 16.0:
                self.current_y = self.target_y
                self.velocity = 0.0
                if total_h > 0:
                    self.set_view_fraction(self.current_y / total_h)
                self.is_animating = False
            else:
                self.current_y = max(0.0, min(max_scroll_px, next_y))
                if total_h > 0:
                    self.set_view_fraction(self.current_y / total_h)
                self._anim_job = self.after_fn(8, self._physics_step)
        except Exception:
            self.is_animating = False

# ============================================================
# 120 FPS ULTRA-PERFORMANCE QUARTZ QUEUE CANVAS (WITH VIEWPORT CULLING)
# ============================================================
class QuartzQueueCanvas(tk.Canvas):
    CARD_H = 104
    CARD_GAP = 6
    ROW_STEP = 110

    def __init__(self, master, on_select_item=None, on_drop_files=None, **kwargs):
        super().__init__(master, bg=CARD_BG, bd=0, highlightthickness=0, relief="flat", **kwargs)
        self.on_select_item = on_select_item
        self.on_drop_files = on_drop_files
        self.items = []
        self.selected_idx = -1
        self.metadata_cache = {}
        self.rendered_rows = {}
        self._updating_viewport = False
        self._external_yscrollcommand = None

        self.scroller = QuartzKineticScroller(
            get_view_metrics=self._get_scroll_metrics,
            set_view_fraction=self.yview_moveto,
            after_fn=self.after,
            cancel_after_fn=self.after_cancel
        )
        self.bind("<Configure>", self._on_resize)
        self.bind("<Button-1>", self._on_click)

        if HAS_TKDND:
            try:
                self.drop_target_register(DND_FILES)
                self.dnd_bind('<<Drop>>', self._handle_drop)
            except Exception:
                pass

    def configure(self, cnf=None, **kwargs):
        if "yscrollcommand" in kwargs:
            self._external_yscrollcommand = kwargs.pop("yscrollcommand")
            kwargs["yscrollcommand"] = self._on_scroll_notify
        return super().configure(cnf, **kwargs)

    config = configure

    def _on_scroll_notify(self, first, last):
        if self._external_yscrollcommand:
            try:
                self._external_yscrollcommand(first, last)
            except Exception:
                pass
        if not self._updating_viewport:
            self._update_visible_rows()

    def yview(self, *args):
        res = super().yview(*args)
        if args and not self._updating_viewport:
            self._update_visible_rows()
        return res

    def yview_moveto(self, fraction):
        res = super().yview_moveto(fraction)
        if not self._updating_viewport:
            self._update_visible_rows()
        return res

    def _get_scroll_metrics(self):
        sr = self.cget("scrollregion")
        if not sr:
            return None
        try:
            parts = [float(p) for p in str(sr).split()]
            total_h = parts[3] - parts[1]
        except Exception:
            return None
        view_h = float(self.winfo_height())
        if total_h <= 0 or view_h <= 0:
            return None
        return (view_h, total_h, self.yview()[0])

    def handle_wheel_input(self, delta_input):
        self.scroller.handle_wheel_input(delta_input)

    def set_items(self, items, selected_idx=-1):
        self.items = list(items)
        self.selected_idx = selected_idx
        self.redraw_all()

    def set_selected_idx(self, idx):
        old_idx = self.selected_idx
        self.selected_idx = idx
        w = max(200, self.winfo_width())
        for target in (old_idx, idx):
            if target in self.rendered_rows and 0 <= target < len(self.items):
                self.delete(f"card_row_{target}")
                self._draw_row(target, self.items[target], w)

    def update_badges(self, filepath, badges):
        if filepath in self.items:
            idx = self.items.index(filepath)
            if idx in self.rendered_rows:
                w = max(200, self.winfo_width())
                self.delete(f"card_row_{idx}")
                self._draw_row(idx, filepath, w)

    def _get_visible_range(self):
        total_items = len(self.items)
        if total_items == 0:
            return -1, -1
        view_h = float(self.winfo_height())
        if view_h <= 1:
            try:
                view_h = float(self.cget("height"))
            except Exception:
                view_h = 400.0
        y_top = self.canvasy(0)
        y_bot = self.canvasy(view_h)
        start_idx = max(0, int((y_top - 4) // self.ROW_STEP) - 1)
        end_idx = min(total_items - 1, int((y_bot - 4) // self.ROW_STEP) + 1)
        return start_idx, end_idx

    def _update_visible_rows(self, force=False):
        if self._updating_viewport:
            return
        self._updating_viewport = True
        try:
            total_items = len(self.items)
            w = max(200, self.winfo_width())
            total_h = max(1, total_items * self.ROW_STEP + 8)

            sr = (0, 0, w, total_h)
            cur_sr = self.cget("scrollregion")
            if not cur_sr or str(cur_sr) != f"0 0 {w} {total_h}":
                self.configure(scrollregion=sr)

            if total_items == 0:
                self.delete("all")
                self.rendered_rows.clear()
                h = max(100, self.winfo_height())
                self.create_text(w / 2, h / 2, text="No files in queue", fill=TEXT_MUTED, font=("SF Pro Text", 11), tags="placeholder")
                if not self.scroller.is_animating:
                    self.scroller.sync_position()
                return

            self.delete("placeholder")

            start_idx, end_idx = self._get_visible_range()
            if start_idx < 0:
                return

            needed_indices = set(range(start_idx, end_idx + 1))

            if force:
                for idx in list(self.rendered_rows.keys()):
                    self.delete(f"card_row_{idx}")
                self.rendered_rows.clear()

            for idx in list(self.rendered_rows.keys()):
                if idx not in needed_indices:
                    self.delete(f"card_row_{idx}")
                    del self.rendered_rows[idx]
                elif not force and idx < len(self.items):
                    if self.rendered_rows[idx] != self.items[idx]:
                        self.delete(f"card_row_{idx}")
                        del self.rendered_rows[idx]

            for idx in range(start_idx, end_idx + 1):
                if idx not in self.rendered_rows and idx < len(self.items):
                    self._draw_row(idx, self.items[idx], w)
                    self.rendered_rows[idx] = self.items[idx]

            if not self.scroller.is_animating:
                self.scroller.sync_position()
        finally:
            self._updating_viewport = False

    def redraw_all(self):
        self._update_visible_rows(force=True)

    def _draw_rounded_rect(self, x1, y1, x2, y2, radius=8, **kwargs):
        r = max(1.0, min(float(radius), (x2 - x1) / 2.0, (y2 - y1) / 2.0))
        fill_col = kwargs.get("fill")
        border_col = kwargs.get("outline")
        border_w = max(1, int(round(float(kwargs.get("width", 1.0) or 1.0))))
        tags = kwargs.get("tags")

        has_border = bool(border_col and border_col != "" and border_col != fill_col and border_w > 0)

        if has_border:
            cx1, cy1 = x1 + r, y1 + r
            cx2, cy2 = x2 - r, y2 - r
            if cx2 < cx1:
                cx1 = cx2 = (x1 + x2) / 2.0
            if cy2 < cy1:
                cy1 = cy2 = (y1 + y2) / 2.0
            self.create_polygon(
                cx1, cy1, cx2, cy1, cx2, cy2, cx1, cy2,
                fill=border_col, outline=border_col, width=r * 2.0,
                joinstyle=tk.ROUND, tags=tags
            )

            inner_r = max(0.5, r - border_w)
            bw = r - inner_r
            ix1, iy1 = x1 + bw, y1 + bw
            ix2, iy2 = x2 - bw, y2 - bw
            icx1, icy1 = ix1 + inner_r, iy1 + inner_r
            icx2, icy2 = ix2 - inner_r, iy2 - inner_r
            if icx2 < icx1:
                icx1 = icx2 = (ix1 + ix2) / 2.0
            if icy2 < icy1:
                icy1 = icy2 = (iy1 + iy2) / 2.0
            return self.create_polygon(
                icx1, icy1, icx2, icy1, icx2, icy2, icx1, icy2,
                fill=fill_col, outline=fill_col, width=inner_r * 2.0,
                joinstyle=tk.ROUND, tags=tags
            )
        else:
            col = fill_col or border_col or "#000000"
            cx1, cy1 = x1 + r, y1 + r
            cx2, cy2 = x2 - r, y2 - r
            if cx2 < cx1:
                cx1 = cx2 = (x1 + x2) / 2.0
            if cy2 < cy1:
                cy1 = cy2 = (y1 + y2) / 2.0
            return self.create_polygon(
                cx1, cy1, cx2, cy1, cx2, cy2, cx1, cy2,
                fill=col, outline=col, width=r * 2.0,
                joinstyle=tk.ROUND, tags=tags
            )

    def _draw_row(self, idx, filepath, w):
        y1 = idx * self.ROW_STEP + 4
        y2 = y1 + self.CARD_H
        x1, x2 = 6, w - 6
        is_sel = (idx == self.selected_idx)
        card_tag = f"card_row_{idx}"

        fill_col = "#222a38" if is_sel else "#18181f"
        border_col = "#3b82f6" if is_sel else "#262632"
        border_w = 2 if is_sel else 1

        if not is_sel:
            self._draw_rounded_rect(x1, y1 + 1, x2, y2 + 2, radius=8, fill="#0c0c10", outline="", tags=card_tag)
        self._draw_rounded_rect(x1, y1, x2, y2, radius=8, fill=fill_col, outline=border_col, width=border_w, tags=card_tag)

        fn = os.path.basename(filepath)
        name_color = "#ffffff" if is_sel else "#d1d5db"
        avail_name_w = max(60, (x2 - x1) - 20)
        max_chars = max(10, int(avail_name_w / 7.2))
        disp_name = fn[:max_chars - 3] + "…" if len(fn) > max_chars else fn
        self.create_text(x1 + 10, y1 + 15, text=disp_name, fill=name_color, anchor="w", font=("SF Pro Text", 10, "bold"), tags=card_tag)

        cached = self.metadata_cache.get(filepath)
        badges = cached[2] if cached and len(cached) >= 3 else []

        if not badges:
            self.create_text((x1 + x2) / 2, y1 + 60, text="⏳ Analyzing metadata...", fill="#8e8e9a", font=("SF Pro Text", 9), tags=card_tag)
            return

        chip_y_start = y1 + 28
        chip_h = 20
        chip_gap_y = 4
        chip_gap_x = 4
        inner_w = (x2 - x1) - 16
        col_w = (inner_w - chip_gap_x) / 2

        num_badges = min(6, len(badges))
        for i in range(num_badges):
            b_info = badges[i]
            if len(b_info) == 5:
                _, val, bg_col, text_col, border_col = b_info
            else:
                val, bg_col, text_col = b_info[1], b_info[2], b_info[3]
                border_col = "#2e3036"

            r = i // 2
            c = i % 2
            is_full_span = (i == num_badges - 1 and c == 0)

            cy1 = chip_y_start + r * (chip_h + chip_gap_y)
            cy2 = cy1 + chip_h

            if is_full_span:
                cx1 = x1 + 8
                cx2 = x2 - 8
            else:
                cx1 = x1 + 8 + c * (col_w + chip_gap_x)
                cx2 = cx1 + col_w

            self._draw_rounded_rect(cx1, cy1, cx2, cy2, radius=5, fill=bg_col, outline=border_col, width=1, tags=card_tag)

            val_str = str(val)
            chip_avail_w = max(24, cx2 - cx1 - 6)

            # Dynamically auto-scale font size so long specs never truncate
            font_sz = 9
            if len(val_str) >= 22:
                font_sz = 7
            elif len(val_str) >= 16:
                font_sz = 8

            char_w = 4.5 if font_sz == 7 else (5.1 if font_sz == 8 else 5.8)
            max_c_chars = max(6, int(chip_avail_w / char_w))
            disp_val = val_str[:max_c_chars - 1] + "…" if len(val_str) > max_c_chars else val_str
            self.create_text((cx1 + cx2) / 2, (cy1 + cy2) / 2, text=disp_val, fill=text_col, font=("SF Pro Text", font_sz, "bold"), anchor="center", tags=card_tag)

    def _on_resize(self, event):
        self.redraw_all()

    def _on_click(self, event):
        self.focus_set()
        cy = self.canvasy(event.y)
        idx = int((cy - 4) // self.ROW_STEP)
        if 0 <= idx < len(self.items):
            if self.on_select_item:
                self.on_select_item(idx)

    def _handle_drop(self, event):
        if self.on_drop_files:
            self.on_drop_files(event)

# ============================================================
# UNIVERSAL EVENT SCROLL HANDLER
# ============================================================
class UniversalScrollHandler:
    def __init__(self, root, queue_scroller=None, report_scroller=None,
                 queue_canvas=None, report_textbox=None):
        self.root = root
        self.queue_scroller = queue_scroller
        self.report_scroller = report_scroller
        self.queue_canvas = queue_canvas
        self.report_textbox = report_textbox
        self.manual_scroller = None
        self.manual_view = None

        for seq in ("<MouseWheel>", "<TouchpadScroll>", "<Button-4>", "<Button-5>"):
            try:
                self.root.unbind_class("Text", seq)
            except Exception:
                pass
            try:
                self.root.bind_all(seq, self.on_global_scroll, add="+")
            except Exception:
                pass

    def on_global_scroll(self, event):
        try:
            raw_delta = getattr(event, "delta", 0)
            if getattr(event, "num", None) == 4:
                raw_delta = 1
            elif getattr(event, "num", None) == 5:
                raw_delta = -1
            if raw_delta == 0:
                return

            delta = float(raw_delta)
            x, y = getattr(event, "x_root", None), getattr(event, "y_root", None)
            if x is None or y is None:
                x, y = self.root.winfo_pointerxy()

            def is_inside(w):
                if not w or not w.winfo_ismapped():
                    return False
                try:
                    return (w.winfo_rootx() <= x <= w.winfo_rootx() + w.winfo_width()) and                            (w.winfo_rooty() <= y <= w.winfo_rooty() + w.winfo_height())
                except Exception:
                    return False

            if is_inside(self.queue_canvas):
                if self.queue_scroller:
                    self.queue_scroller.handle_wheel_input(delta)
                return "break"
            if is_inside(self.report_textbox) or (hasattr(self.report_textbox, "_textbox") and is_inside(self.report_textbox._textbox)):
                if self.report_scroller:
                    self.report_scroller.handle_wheel_input(delta)
                return "break"
            if getattr(self, "manual_view", None) and (is_inside(self.manual_view) or (hasattr(self.manual_view, "_textbox") and is_inside(self.manual_view._textbox))):
                if getattr(self, "manual_scroller", None):
                    self.manual_scroller.handle_wheel_input(delta)
                return "break"
        except Exception:
            pass

if HAS_TKDND:
    class CTkWithDnD(ctk.CTk, TkinterDnD.DnDWrapper):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            try:
                self.TkdndVersion = TkinterDnD._require(self)
            except Exception as e:
                print(f"[WARNING] TkinterDnD init: {e}")
else:
    class CTkWithDnD(ctk.CTk):
        pass

class MediaInspectorApp:
    def __init__(self, root, initial_files=None):
        global _GLOBAL_APP_INSTANCE
        _GLOBAL_APP_INSTANCE = self
        self.root = root
        self.root.title("MediaInspector")

        self.settings = load_app_settings()
        saved_w = self.settings.get("window_width", 860)
        saved_h = self.settings.get("window_height", 880)
        saved_x = self.settings.get("window_x")
        saved_y = self.settings.get("window_y")
        try:
            saved_w = max(680, int(saved_w))
            saved_h = max(650, int(saved_h))
        except (ValueError, TypeError):
            saved_w, saved_h = 860, 880

        if saved_x is not None and saved_y is not None:
            try:
                self.root.geometry(f"{saved_w}x{saved_h}+{int(saved_x)}+{int(saved_y)}")
            except Exception:
                self.root.geometry(f"{saved_w}x{saved_h}")
        else:
            self.root.geometry(f"{saved_w}x{saved_h}")
        self.root.minsize(680, 650)
        self.root.configure(fg_color=BG_MAIN)

        self._save_timer = None
        self.root.bind("<Configure>", self._on_window_configure)
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)
        try:
            self.root.createcommand("::tk::mac::Quit", self.on_closing)
        except Exception:
            pass

        self.drawer_open = self.settings.get("drawer_open", False)
        self.file_list = []
        self.file_cards = []
        self.file_metadata_cache = {}
        self._probe_queue = queue.Queue()
        self._stop_probe_worker = False
        self.current_index = -1
        self.raw_json_data = None
        self.current_report_text = ""
        self.is_json_mode = False

        threading.Thread(target=self._probe_queue_worker, daemon=True).start()

        self.setup_ui()
        self.setup_drag_and_drop()

        if initial_files:
            self.root.after(100, lambda: self.load_files(initial_files))

    def _on_window_configure(self, event):
        if event.widget == self.root:
            w = self.root.winfo_width()
            h = self.root.winfo_height()
            x = self.root.winfo_x()
            y = self.root.winfo_y()
            if w >= 680 and h >= 650:
                changed = False
                if w != self.settings.get("window_width") or h != self.settings.get("window_height"):
                    self.settings["window_width"] = w
                    self.settings["window_height"] = h
                    changed = True
                if x != self.settings.get("window_x") or y != self.settings.get("window_y"):
                    self.settings["window_x"] = x
                    self.settings["window_y"] = y
                    changed = True
                if changed:
                    if self._save_timer:
                        try:
                            self.root.after_cancel(self._save_timer)
                        except Exception:
                            pass
                    self._save_timer = self.root.after(400, self._save_settings)

    def _save_settings(self):
        save_app_settings(self.settings)

    def on_closing(self):
        self._stop_probe_worker = True
        w = self.root.winfo_width()
        h = self.root.winfo_height()
        if w >= 680 and h >= 650:
            self.settings["window_width"] = w
            self.settings["window_height"] = h
            self.settings["window_x"] = self.root.winfo_x()
            self.settings["window_y"] = self.root.winfo_y()
        self.settings["drawer_open"] = self.drawer_open
        self._save_settings()
        self.root.destroy()

    def toggle_drawer(self):
        self.drawer_open = not self.drawer_open
        self.settings["drawer_open"] = self.drawer_open
        self._save_settings()
        if self.drawer_open:
            self.drawer_frame.pack(side="left", fill="y", padx=(0, 10), before=self.detail_frame)
            self.btn_toggle_queue.configure(text="Queue ◂", fg_color=ACCENT_BLUE, hover_color=ACCENT_BLUE_HOVER)
            if hasattr(self, "canvas_queue"):
                self.canvas_queue.redraw_all()
        else:
            self.drawer_frame.pack_forget()
            self.btn_toggle_queue.configure(text="Queue ▸", fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER)
        self.root.after(50, lambda: self._reflow_badges(force=True))

    def open_user_manual(self):
        if hasattr(self, "_manual_window") and self._manual_window and self._manual_window.winfo_exists():
            self._manual_window.lift()
            self._manual_window.focus_force()
            return

        # Center the manual directly over the main window
        self.root.update_idletasks()
        rx, ry = self.root.winfo_rootx(), self.root.winfo_rooty()
        rw, rh = self.root.winfo_width(), self.root.winfo_height()
        w_manual = min(740, max(640, rw))
        h_manual = min(860, max(600, rh))
        pos_x = max(0, rx + (rw - w_manual) // 2)
        pos_y = max(0, ry + (rh - h_manual) // 2)

        win = ctk.CTkToplevel(self.root)
        win.withdraw()
        self._manual_window = win
        win.title("MediaInspector - User Manual & Guide")
        win.geometry(f"{w_manual}x{h_manual}+{pos_x}+{pos_y}")
        win.minsize(640, 560)
        win.configure(fg_color=BG_MAIN)

        top_bar = ctk.CTkFrame(win, fg_color="transparent")
        top_bar.pack(fill="x", padx=16, pady=(12, 8))

        lbl_top = ctk.CTkLabel(
            top_bar, text="MediaInspector User Manual",
            font=ctk.CTkFont(family="SF Pro Display", size=17, weight="bold"),
            text_color=TEXT_PRIMARY
        )
        lbl_top.pack(side="left")

        btn_kofi = ctk.CTkButton(
            top_bar, text="☕ Support on Ko-fi", width=145, height=30, corner_radius=8,
            fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER, text_color=TEXT_PRIMARY,
            font=ctk.CTkFont(family="SF Pro Text", size=12, weight="bold"),
            command=lambda: webbrowser.open("https://ko-fi.com/jondana")
        )
        btn_kofi.pack(side="right")

        manual_text = ctk.CTkTextbox(
            win,
            font=ctk.CTkFont(family="SF Pro Text", size=13),
            fg_color="#0e0e0e",
            text_color="#e0e0e0",
            corner_radius=8,
            border_width=1,
            border_color="#1e1e1e",
            wrap="word"
        )
        manual_text.pack(fill="both", expand=True, padx=16, pady=(0, 10))

        def get_manual_metrics():
            tb_inner = getattr(manual_text, "_textbox", None)
            if not tb_inner or not tb_inner.winfo_ismapped(): return None
            view_h = float(tb_inner.winfo_height())
            if view_h <= 0: return None
            top_frac, bot_frac = tb_inner.yview()
            vis_frac = max(0.0001, bot_frac - top_frac)
            return (view_h, view_h, 0.0) if vis_frac >= 0.9999 else (view_h, view_h / vis_frac, top_frac)

        manual_scroller = QuartzKineticScroller(
            get_view_metrics=get_manual_metrics,
            set_view_fraction=lambda f: getattr(manual_text, "_textbox").yview_moveto(f) if getattr(manual_text, "_textbox", None) else None,
            after_fn=manual_text.after,
            cancel_after_fn=manual_text.after_cancel
        )

        if hasattr(self, "scroll_handler"):
            self.scroll_handler.manual_scroller = manual_scroller
            self.scroll_handler.manual_view = manual_text

        def _on_manual_wheel(event):
            try:
                raw_delta = getattr(event, "delta", 0)
                if getattr(event, "num", None) == 4: raw_delta = 1
                elif getattr(event, "num", None) == 5: raw_delta = -1
                if raw_delta != 0:
                    manual_scroller.handle_wheel_input(float(raw_delta))
                    return "break"
            except Exception:
                pass

        for seq in ("<MouseWheel>", "<TouchpadScroll>", "<Button-4>", "<Button-5>"):
            try:
                win.bind(seq, _on_manual_wheel, add="+")
                manual_text.bind(seq, _on_manual_wheel, add="+")
                if hasattr(manual_text, "_textbox"):
                    manual_text._textbox.bind(seq, _on_manual_wheel, add="+")
            except Exception:
                pass

        tb = getattr(manual_text, "_textbox", manual_text)
        tb.configure(state="normal", padx=20, pady=16)
        tb.delete("1.0", "end")

        tb.tag_configure("sec_h", font=("SF Pro Display", 14, "bold"), foreground=ULTRA_TEXT, spacing1=22, spacing3=6)
        tb.tag_configure("sec_h_top", font=("SF Pro Display", 14, "bold"), foreground=ULTRA_TEXT, spacing1=2, spacing3=6)
        tb.tag_configure("intro", font=("SF Pro Text", 12), foreground="#9aa4a9", spacing1=2, spacing2=4, spacing3=10, lmargin1=4, lmargin2=4)
        tb.tag_configure("item", lmargin1=10, lmargin2=30, tabs=(30,), spacing1=3, spacing2=3, spacing3=5)
        tb.tag_configure("bullet", font=("SF Pro Text", 12, "bold"), foreground=ULTRA_TEXT)
        tb.tag_configure("val", font=("SF Pro Text", 12, "bold"), foreground=TEXT_PRIMARY)
        tb.tag_configure("body", font=("SF Pro Text", 12), foreground="#c4cbcf")

        sections = [
            ("1. OVERVIEW & CAPABILITIES",
             "MediaInspector is an ultra-fast, professional media analyzer engineered for film, video, and audio production workflows, providing deep technical inspection without indexing or preview stalls.",
             [
                 ("Broad Format Support", "Inspects video, audio, image formats, and professional containers (MOV, MP4, MKV, ProRes, RAW, WAV, FLAC, HEIC, PNG, etc.)."),
                 ("Deep Stream Analysis", "Extracts container structure, codec profiles, resolution, CFR/VFR frame timing, chroma subsampling, bit depth, and bitrate."),
                 ("Color Science & HDR", "Analyzes color primaries, transfer characteristics (PQ, HLG, SDR), matrix coefficients, and HDR10 mastering metadata.")
             ]),

            ("2. INTERFACE & WORKFLOW",
             "Easily inspect individual clips or batch-analyze entire media directories.",
             [
                 ("Files Queue Drawer", "Toggle the collapsible left drawer using the 'Queue ▸/◂' button or the item count badge to switch between loaded files."),
                 ("HUD Quick Specs", "Top stat badges summarize core parameters at a glance: Resolution, Bitrate, Frame Rate, Color Space, Audio, and File Size."),
                 ("Copy & Export", "Review formatted stream metadata, click 'Copy' to copy to clipboard, or click 'Export' to save full text or raw JSON to disk.")
             ]),

            ("3. SHORTCUTS & NAVIGATION",
             "Designed for speed and seamless integration with macOS.",
             [
                 ("Drag & Drop", "Drop media files or folders anywhere onto the window to inspect immediately."),
                 ("Reveal in Finder", "Quickly reveal the active file directly in its Finder directory."),
                 ("Kinetic Scrolling", "Fluid 120 FPS sub-pixel scrolling engine for effortless trackpad and wheel navigation through lengthy technical reports.")
             ]),

            ("4. SUPPORT & CONTRIBUTIONS",
             "MediaInspector is free and open-source software built for creators and engineers.",
             [
                 ("Ko-fi Page", "https://ko-fi.com/jondana"),
                 ("Author", "Jon Dana"),
                 ("Contributions", "If MediaInspector saves you time and streamlines your production workflow, support on Ko-fi is warmly appreciated!")
             ])
        ]

        for sec_idx, (sec_title, intro, items) in enumerate(sections):
            h_tags = ("sec_h", "sec_h_top") if sec_idx == 0 else "sec_h"
            tb.insert("end", f"{sec_title}\n", h_tags)
            if intro:
                tb.insert("end", f"{intro}\n", "intro")
            for lbl, val in items:
                sep = "" if lbl.endswith("?") else ":"
                tb.insert("end", "•\t", ("bullet", "item"))
                tb.insert("end", f"{lbl}{sep} ", ("val", "item"))
                tb.insert("end", f"{val}\n", ("body", "item"))

        tb.configure(state="disabled")
        win.after(60, manual_scroller.sync_position)

        bottom_bar = ctk.CTkFrame(win, fg_color="transparent")
        bottom_bar.pack(fill="x", padx=16, pady=(6, 12))

        btn_close = ctk.CTkButton(
            bottom_bar, text="Close", width=90, height=32, corner_radius=8,
            fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER, text_color=TEXT_PRIMARY,
            font=ctk.CTkFont(family="SF Pro Text", size=12, weight="bold"),
            command=win.destroy
        )
        btn_close.pack(side="right")

        win.deiconify()
        win.after(100, lambda: (win.lift(), win.focus_force()))

    def setup_ui(self):
        # Master container
        self.main_frame = ctk.CTkFrame(self.root, fg_color="transparent")
        self.main_frame.pack(fill="both", expand=True, padx=14, pady=14)

        # Header Bar
        header = ctk.CTkFrame(self.main_frame, fg_color="transparent")
        header.pack(fill="x", pady=(0, 10))

        self.title_lbl = ctk.CTkLabel(
            header,
            text="MediaInspector",
            font=ctk.CTkFont(family="SF Pro Display", size=18, weight="bold"),
            text_color=TEXT_PRIMARY,
            cursor="hand2"
        )
        self.title_lbl.pack(side="left")
        self.title_lbl.bind("<Button-1>", lambda e: self.open_user_manual())
        self.title_lbl.bind("<Enter>", lambda e: self.title_lbl.configure(text_color=ULTRA_TEXT))
        self.title_lbl.bind("<Leave>", lambda e: self.title_lbl.configure(text_color=TEXT_PRIMARY))

        self.btn_toggle_queue = ctk.CTkButton(
            header,
            text="Queue ◂" if self.drawer_open else "Queue ▸",
            width=80,
            height=28,
            corner_radius=7,
            fg_color=ACCENT_BLUE if self.drawer_open else NEUTRAL_BTN,
            hover_color=ACCENT_BLUE_HOVER if self.drawer_open else NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=11, weight="bold"),
            command=self.toggle_drawer
        )
        self.btn_toggle_queue.pack(side="left", padx=(10, 0))

        self.badge_count = ctk.CTkLabel(
            header,
            text="0 items",
            font=ctk.CTkFont(family="SF Pro Text", size=11, weight="bold"),
            text_color="#94a3b8",
            fg_color="#22222a",
            corner_radius=6,
            padx=8,
            pady=2,
            cursor="pointinghand"
        )
        self.badge_count.pack(side="left", padx=(8, 0))
        self.badge_count.bind("<Button-1>", lambda e: self.toggle_drawer())

        # Header action buttons
        self.btn_open_file = ctk.CTkButton(
            header,
            text="＋ Open Media...",
            width=115,
            height=28,
            corner_radius=7,
            fg_color=ACCENT_BLUE,
            hover_color=ACCENT_BLUE_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=11, weight="bold"),
            command=self.browse_files
        )
        self.btn_open_file.pack(side="right", padx=(6, 0))

        self.btn_reveal_finder = ctk.CTkButton(
            header,
            text="Reveal in Finder",
            width=115,
            height=28,
            corner_radius=7,
            fg_color=NEUTRAL_BTN,
            hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=11, weight="bold"),
            command=self.reveal_in_finder,
            state="disabled"
        )
        self.btn_reveal_finder.pack(side="right", padx=(6, 0))

        self.btn_clear_all = ctk.CTkButton(
            header,
            text="Clear",
            width=65,
            height=28,
            corner_radius=7,
            fg_color=NEUTRAL_BTN,
            hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=11, weight="bold"),
            command=self.clear_all
        )
        self.btn_clear_all.pack(side="right")

        # Body: Left Drawer (Files list) + Right Inspector Viewer
        self.split_pane = ctk.CTkFrame(self.main_frame, fg_color="transparent")
        self.split_pane.pack(fill="both", expand=True)

        # Right Detail Container
        self.detail_frame = ctk.CTkFrame(self.split_pane, fg_color=CARD_BG, corner_radius=10, border_width=1, border_color=CARD_BORDER)
        self.detail_frame.pack(side="right", fill="both", expand=True)

        # Left File Drawer (Width expanded to 300px for clean badge chip grid)
        self.drawer_frame = ctk.CTkFrame(self.split_pane, width=300, fg_color=CARD_BG, corner_radius=10, border_width=1, border_color=CARD_BORDER)
        self.drawer_frame.pack_propagate(False)

        drawer_top_bar = ctk.CTkFrame(self.drawer_frame, fg_color="transparent")
        drawer_top_bar.pack(fill="x", padx=10, pady=(8, 4))

        drawer_hdr = ctk.CTkLabel(
            drawer_top_bar,
            text="FILES QUEUE",
            font=ctk.CTkFont(family="SF Pro Text", size=10, weight="bold"),
            text_color=TEXT_MUTED
        )
        drawer_hdr.pack(side="left", padx=4)

        btn_close_drawer = ctk.CTkButton(
            drawer_top_bar,
            text="✕",
            width=22,
            height=22,
            corner_radius=6,
            fg_color="transparent",
            hover_color=NEUTRAL_BTN_HOVER,
            text_color=TEXT_MUTED,
            font=ctk.CTkFont(family="SF Pro Text", size=11, weight="bold"),
            command=self.toggle_drawer
        )
        btn_close_drawer.pack(side="right")

        queue_wrap = ctk.CTkFrame(self.drawer_frame, fg_color="transparent")
        queue_wrap.pack(fill="both", expand=True, padx=6, pady=(0, 8))

        self.canvas_queue = QuartzQueueCanvas(
            queue_wrap,
            on_select_item=self.select_file,
            on_drop_files=lambda event: self.load_files(self.root.tk.splitlist(getattr(event, 'data', '')))
        )
        self.canvas_queue.metadata_cache = self.file_metadata_cache
        self.canvas_queue.pack(side="left", fill="both", expand=True, padx=(0, 2), pady=0)

        self.queue_scrollbar = ctk.CTkScrollbar(
            queue_wrap,
            command=self._on_queue_scrollbar_drag,
            fg_color="transparent",
            button_color="#262626",
            button_hover_color="#333333",
            width=10
        )
        self.queue_scrollbar.pack(side="right", fill="y", pady=0)
        self.canvas_queue.configure(yscrollcommand=self.queue_scrollbar.set)

        if self.drawer_open:
            self.drawer_frame.pack(side="left", fill="y", padx=(0, 10), before=self.detail_frame)

        # Top Bar of Inspector Detail (Badges, Search filter, Copy/Export)
        self.detail_top = ctk.CTkFrame(self.detail_frame, fg_color="transparent")
        self.detail_top.pack(fill="x", padx=12, pady=(10, 8))

        self.btn_copy = ctk.CTkButton(
            self.detail_top,
            text="Copy",
            width=65,
            height=26,
            corner_radius=6,
            fg_color=NEUTRAL_BTN,
            hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=10, weight="bold"),
            command=self.copy_report
        )
        self.btn_copy.pack(side="right", padx=(4, 0))

        self.btn_export = ctk.CTkButton(
            self.detail_top,
            text="Export",
            width=65,
            height=26,
            corner_radius=6,
            fg_color=NEUTRAL_BTN,
            hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=10, weight="bold"),
            command=self.export_report
        )
        self.btn_export.pack(side="right", padx=(4, 0))

        self.lbl_active_title = ctk.CTkLabel(
            self.detail_top,
            text="No Media Selected",
            font=ctk.CTkFont(family="SF Pro Display", size=13, weight="bold"),
            text_color=TEXT_PRIMARY,
            anchor="w"
        )
        self.lbl_active_title.pack(side="left", fill="x", expand=True, padx=(0, 10))

        # Quick Specs Badges Bar
        self.badges_bar = ctk.CTkFrame(self.detail_frame, fg_color="transparent")
        self.badges_bar.pack(fill="x", padx=12, pady=(0, 8))
        self.badges_bar.pack_propagate(False)
        self.badges_bar.bind("<Configure>", lambda e: self._reflow_badges())
        self._badge_widgets = []

        # Metadata Report Text Box with Modern Proportional Typography & Tabs
        self.report_text = ctk.CTkTextbox(
            self.detail_frame,
            font=ctk.CTkFont(family="SF Pro Text", size=11),
            fg_color="#121215",
            text_color="#e2e8f0",
            corner_radius=8,
            border_width=1,
            border_color="#22222a",
            wrap="none"
        )
        self.report_text.pack(fill="both", expand=True, padx=12, pady=(0, 10))

        tb = getattr(self.report_text, "_textbox", self.report_text)
        try:
            tb.configure(font=("SF Pro Text", 11), tabs=("170",))
            tb.tag_configure("section", font=("SF Pro Display", 12, "bold"), foreground="#ffffff", spacing1=16, spacing3=3)
            tb.tag_configure("k_lbl", font=("SF Pro Text", 11), foreground="#8e8e9a")
            tb.tag_configure("v_txt", font=("SF Pro Text", 11, "bold"), foreground="#f4f4f6")
        except Exception:
            pass

        self.placeholder_lbl = tk.Label(
            tb,
            text="Drop a file to inspect metadata",
            font=("SF Pro Text", 14),
            fg=TEXT_MUTED,
            bg="#121215"
        )

        # Kinetic Scroller Hook
        def get_metrics():
            tb_inner = getattr(self.report_text, "_textbox", None)
            if not tb_inner or not tb_inner.winfo_ismapped():
                return None
            view_h = float(tb_inner.winfo_height())
            if view_h <= 0:
                return None
            yv = tb_inner.yview()
            top_frac, bot_frac = yv[0], yv[1]
            vis_frac = max(0.0001, bot_frac - top_frac)
            if vis_frac >= 0.9999:
                return (view_h, view_h, 0.0)
            return (view_h, view_h / vis_frac, top_frac)

        self.scroller = QuartzKineticScroller(
            get_view_metrics=get_metrics,
            set_view_fraction=lambda f: getattr(self.report_text, "_textbox").yview_moveto(f) if getattr(self.report_text, "_textbox", None) else None,
            after_fn=self.report_text.after,
            cancel_after_fn=self.report_text.after_cancel
        )

        self.scroll_handler = UniversalScrollHandler(
            self.root,
            queue_scroller=self.canvas_queue.scroller,
            report_scroller=self.scroller,
            queue_canvas=self.canvas_queue,
            report_textbox=self.report_text
        )

        self.show_placeholder()

    def _on_queue_scrollbar_drag(self, *args):
        self.canvas_queue.yview(*args)
        self.canvas_queue.scroller.sync_position()

    def setup_drag_and_drop(self):
        if not HAS_TKDND:
            return

        def on_drop(event):
            raw = getattr(event, 'data', '')
            if not raw:
                return
            try:
                items = self.root.tk.splitlist(raw)
            except Exception:
                items = [raw]
            self.load_files(items)
            return "break"

        targets = [self.root, self.main_frame, self.detail_frame, self.report_text, self.drawer_frame, getattr(self, "canvas_queue", None)]
        targets = [w for w in targets if w is not None]
        if hasattr(self, "placeholder_lbl"):
            targets.append(self.placeholder_lbl)
        for w in targets:
            try:
                w.drop_target_register(DND_FILES)
                w.dnd_bind('<<Drop>>', on_drop)
            except Exception:
                pass

    def show_placeholder(self):
        self.lbl_active_title.configure(text="Drop media to inspect", text_color=TEXT_MUTED)
        self.btn_reveal_finder.configure(state="disabled")
        self.clear_badges()
        tb = getattr(self.report_text, "_textbox", self.report_text)
        tb.configure(state="normal")
        tb.delete("1.0", "end")
        tb.configure(state="disabled")
        if hasattr(self, "placeholder_lbl"):
            self.placeholder_lbl.place(relx=0.5, rely=0.5, anchor="center")

    def clear_badges(self):
        if hasattr(self, "badges_bar"):
            for w in self.badges_bar.winfo_children():
                w.destroy()
            self._badge_widgets = []
            self._last_badges_w = None
            self.badges_bar.configure(height=0)

    def _reflow_badges(self, event=None, force=False):
        if not getattr(self, "_badge_widgets", None):
            return

        avail_w = 0
        if event and getattr(event, "width", 0) > 50:
            avail_w = event.width
        if avail_w <= 50 and hasattr(self, "badges_bar"):
            avail_w = self.badges_bar.winfo_width()
        if avail_w <= 50 and hasattr(self, "detail_frame"):
            df_w = self.detail_frame.winfo_width()
            if df_w > 50:
                avail_w = df_w - 24
        if avail_w <= 50:
            rw = self.root.winfo_width()
            avail_w = (rw - 322) if rw > 350 else 538

        if not force and getattr(self, "_last_badges_w", None) == avail_w:
            return
        self._last_badges_w = avail_w

        badges = self._badge_widgets
        n = len(badges)
        if n == 0:
            return

        gap_x = 6
        gap_y = 6
        row_h = 30

        def get_min_w(b):
            if hasattr(b, "_min_w"):
                return b._min_w
            txt = getattr(b, "_text", "")
            return max(85, len(str(txt)) * 8 + 20)

        min_w_map = {b: get_min_w(b) for b in badges}

        best_rows = None
        for r in range(1, n + 1):
            base_cnt = n // r
            rem = n % r
            cand_rows = []
            cur_idx = 0
            for i in range(r):
                c = base_cnt + (1 if i < rem else 0)
                cand_rows.append(badges[cur_idx:cur_idx + c])
                cur_idx += c

            fits = True
            for row in cand_rows:
                k = len(row)
                if k == 0:
                    continue
                row_min = sum(min_w_map[x] for x in row) + (k - 1) * gap_x
                if row_min > avail_w:
                    fits = False
                    break

            if fits:
                best_rows = cand_rows
                break

        if not best_rows:
            best_rows = []
            cur_row = []
            cur_row_w = 0
            for b in badges:
                bw = min_w_map[b]
                needed = bw if not cur_row else bw + gap_x
                if cur_row and (cur_row_w + needed > avail_w):
                    best_rows.append(cur_row)
                    cur_row = [b]
                    cur_row_w = bw
                else:
                    cur_row.append(b)
                    cur_row_w += needed
            if cur_row:
                best_rows.append(cur_row)

        cur_y = 0
        for row in best_rows:
            k = len(row)
            if k == 0:
                continue

            row_min_sum = sum(min_w_map[b] for b in row)
            total_gaps = (k - 1) * gap_x
            avail_cards_w = max(0, avail_w - total_gaps)
            extra_w = max(0, avail_cards_w - row_min_sum)

            cur_x = 0
            for j, b in enumerate(row):
                min_w = min_w_map[b]
                if k == 1:
                    w_px = min(max(min_w, 180), avail_w)
                else:
                    add_w = (extra_w * (min_w / row_min_sum)) if row_min_sum > 0 else (extra_w / k)
                    w_px = max(min_w, round(min_w + add_w))

                if j == k - 1 and k > 1 and extra_w > 0:
                    w_px = max(min_w, avail_w - cur_x)

                b.configure(width=int(w_px), height=int(row_h))
                b.place(x=int(cur_x), y=int(cur_y))
                cur_x += int(w_px) + gap_x

            cur_y += row_h + gap_y

        total_h = max(row_h, cur_y - gap_y)
        self.badges_bar.configure(height=total_h)

    def add_stat_card(self, title, value, bg_col, text_col, border_col="#242424", reflow=True):
        card = ctk.CTkFrame(
            self.badges_bar,
            fg_color=bg_col,
            corner_radius=7,
            border_width=1,
            border_color=border_col
        )
        card.pack_propagate(False)

        lbl_v = ctk.CTkLabel(
            card,
            text=str(value),
            font=ctk.CTkFont(family="SF Pro Text", size=12, weight="bold"),
            text_color="#f5f5f7",
            anchor="w"
        )
        lbl_v.pack(side="left", padx=(10, 6))

        lbl_t = ctk.CTkLabel(
            card,
            text=str(title).upper(),
            font=ctk.CTkFont(family="SF Pro Text", size=9, weight="bold"),
            text_color=text_col,
            anchor="w"
        )
        lbl_t.pack(side="left", padx=(0, 10))

        card._min_w = max(100, (len(str(value)) + len(str(title))) * 7 + 28)
        if not hasattr(self, "_badge_widgets"):
            self._badge_widgets = []
        self._badge_widgets.append(card)

        if reflow:
            self._reflow_badges(force=True)

    def add_badge(self, text, bg_col="#1e1e1e", text_col="#dedede", reflow=True):
        self.add_stat_card("INFO", text, bg_col, text_col, reflow=reflow)

    def browse_files(self):
        f = filedialog.askopenfilenames(
            title="Select Media to Inspect",
            filetypes=[("All Media Files", "*.*")]
        )
        if f:
            self.load_files(f)

    @staticmethod
    def truncate_filename(name, max_len=24):
        if len(name) <= max_len:
            return name
        base, ext = os.path.splitext(name)
        if len(ext) > 7:
            ext = ""
        avail = max_len - len(ext) - 3
        if avail > 4:
            return f"{base[:avail]}…{ext}"
        return name[:max_len - 1] + "…"

    def _probe_queue_worker(self):
        while not self._stop_probe_worker:
            try:
                fp = self._probe_queue.get(timeout=0.5)
            except queue.Empty:
                continue
            if fp not in self.file_metadata_cache:
                try:
                    res = self._probe_file(fp)
                    self.file_metadata_cache[fp] = res
                except Exception:
                    pass
            if fp in self.file_metadata_cache:
                data = self.file_metadata_cache[fp]
                self.root.after(0, lambda p=fp, d=data: self._update_card_badges(p, d[2]))
            self._probe_queue.task_done()

    def _update_card_badges(self, filepath, badges):
        if hasattr(self, "canvas_queue"):
            self.canvas_queue.update_badges(filepath, badges)

    def clear_all(self):
        self.file_list = []
        self.file_cards = []
        self.file_metadata_cache.clear()
        if hasattr(self, "canvas_queue"):
            self.canvas_queue.metadata_cache = self.file_metadata_cache
            self.canvas_queue.set_items([], -1)
        self.current_index = -1
        self.raw_json_data = None
        self.current_report_text = ""
        self.badge_count.configure(text="0 items")
        self.show_placeholder()

    def load_files(self, paths):
        target_idx = -1
        new_files = []
        for p in paths:
            clean = clean_file_path(p)
            if not clean or not os.path.exists(clean):
                continue
            if os.path.isdir(clean):
                for root_dir, _, filenames in os.walk(clean):
                    for fn in sorted(filenames):
                        if fn.startswith("."):
                            continue
                        fp = os.path.join(root_dir, fn)
                        if fp.lower().endswith(SUPPORTED_EXTENSIONS):
                            if fp in self.file_list:
                                if target_idx == -1:
                                    target_idx = self.file_list.index(fp)
                            elif fp not in new_files:
                                new_files.append(fp)
                                if fp not in self.file_metadata_cache:
                                    self._probe_queue.put(fp)
            elif os.path.isfile(clean):
                if clean in self.file_list:
                    if target_idx == -1:
                        target_idx = self.file_list.index(clean)
                elif clean not in new_files:
                    new_files.append(clean)
                    if clean not in self.file_metadata_cache:
                        self._probe_queue.put(clean)

        if new_files:
            self.file_list = new_files + self.file_list
            target_idx = 0

        self.badge_count.configure(text=f"{len(self.file_list)} items")
        if hasattr(self, "canvas_queue"):
            self.canvas_queue.set_items(self.file_list, self.current_index)
            if new_files:
                self.canvas_queue.yview_moveto(0.0)
                self.canvas_queue.scroller.sync_position()
        if target_idx != -1:
            self.select_file(target_idx)
        elif self.current_index >= 0 and self.current_index < len(self.file_list):
            self.select_file(self.current_index)

    def select_file(self, idx):
        if idx < 0 or idx >= len(self.file_list):
            return
        self.current_index = idx
        if hasattr(self, "canvas_queue"):
            self.canvas_queue.set_selected_idx(idx)

        filepath = self.file_list[idx]
        if hasattr(self, "placeholder_lbl"):
            self.placeholder_lbl.place_forget()
        self.btn_reveal_finder.configure(state="normal")

        if hasattr(self, "_loading_job") and self._loading_job:
            try:
                self.root.after_cancel(self._loading_job)
            except Exception:
                pass
            self._loading_job = None

        def _apply_data(rep, jdata, bdgs):
            self.raw_json_data = jdata
            self.current_report_text = rep
            self.lbl_active_title.configure(text=os.path.basename(filepath), text_color=TEXT_PRIMARY)
            self.clear_badges()
            for card in bdgs:
                if len(card) == 5:
                    c_title, c_val, c_bg, c_fg, c_border = card
                    self.add_stat_card(c_title, c_val, c_bg, c_fg, c_border, reflow=False)
                elif len(card) == 3:
                    self.add_stat_card("INFO", card[0], card[1], card[2], reflow=False)
            self._reflow_badges(force=True)
            self.filter_report()

        if filepath in self.file_metadata_cache:
            c_rep, c_jdata, c_bdgs = self.file_metadata_cache[filepath]
            _apply_data(c_rep, c_jdata, c_bdgs)
            return

        self.lbl_active_title.configure(text=f"Analyzing: {os.path.basename(filepath)}...", text_color="#38bdf8")
        tb = getattr(self.report_text, "_textbox", self.report_text)
        tb.configure(state="normal")
        tb.delete("1.0", "end")
        tb.configure(state="disabled")
        self.clear_badges()

        def _show_loading():
            if self.current_index == idx:
                tb.configure(state="normal")
                tb.delete("1.0", "end")
                tb.insert("1.0", f"\n  ⏳ Extracting comprehensive metadata for:\n  {filepath}...\n")
                tb.configure(state="disabled")

        self._loading_job = self.root.after(400, _show_loading)

        def _worker():
            try:
                report_str, json_data, badges = self._probe_file(filepath)
            except Exception as e:
                report_str = f"❌ Analysis error: {e}"
                json_data = None
                badges = [("Error", str(e), "#450a0a", "#f87171", "#7f1d1d")]

            def _apply():
                if hasattr(self, "_loading_job") and self._loading_job:
                    try:
                        self.root.after_cancel(self._loading_job)
                    except Exception:
                        pass
                    self._loading_job = None
                self.file_metadata_cache[filepath] = (report_str, json_data, badges)
                self._update_card_badges(filepath, badges)
                if self.current_index == idx:
                    _apply_data(report_str, json_data, badges)

            self.root.after(0, _apply)

        threading.Thread(target=_worker, daemon=True).start()

    def filter_report(self):
        tb = getattr(self.report_text, "_textbox", self.report_text)
        tb.configure(state="normal")
        tb.delete("1.0", "end")

        if self.is_json_mode:
            text_to_show = json.dumps(self.raw_json_data, indent=2) if self.raw_json_data else "{}"
            tb.insert("1.0", text_to_show)
        else:
            lines = self.current_report_text.splitlines() if self.current_report_text else []
            for line in lines:
                if line.isupper() and len(line.strip()) > 2 and "\t" not in line:
                    tb.insert("end", f"{line}\n", "section")
                elif "\t" in line:
                    parts = line.split("\t")
                    if len(parts) >= 4:
                        tb.insert("end", parts[0] + "\t", "k_lbl")
                        tb.insert("end", parts[1] + "\t", "v_txt")
                        tb.insert("end", parts[2] + "\t", "k_lbl")
                        tb.insert("end", parts[3] + "\n", "v_txt")
                    elif len(parts) >= 2:
                        tb.insert("end", parts[0] + "\t", "k_lbl")
                        tb.insert("end", parts[1] + "\n", "v_txt")
                    else:
                        tb.insert("end", line + "\n", "v_txt")
                elif line.strip() == "":
                    tb.insert("end", "\n")
                else:
                    tb.insert("end", line + "\n", "v_txt")

        tb.configure(state="disabled")
        if hasattr(self, "scroller"):
            self.scroller.sync_position()

    def toggle_json_view(self):
        self.is_json_mode = not self.is_json_mode
        self.btn_json_toggle.configure(
            text="Report" if self.is_json_mode else "{ } JSON",
            fg_color="#1d4ed8" if self.is_json_mode else NEUTRAL_BTN
        )
        self.filter_report()

    def copy_report(self):
        tb = getattr(self.report_text, "_textbox", self.report_text)
        text = tb.get("1.0", "end-1c").strip()
        if not text:
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        old = self.btn_copy.cget("text")
        self.btn_copy.configure(text="Copied!")
        self.root.after(1400, lambda: self.btn_copy.configure(text=old))

    def export_report(self):
        if not self.current_report_text:
            return
        def_name = f"{os.path.basename(self.file_list[self.current_index])}_metadata.txt"
        dest = filedialog.asksaveasfilename(
            initialfile=def_name,
            defaultextension=".txt",
            filetypes=[("Text File", "*.txt"), ("JSON File", "*.json")]
        )
        if dest:
            try:
                with open(dest, "w", encoding="utf-8") as f:
                    if dest.endswith(".json") and self.raw_json_data:
                        json.dump(self.raw_json_data, f, indent=2)
                    else:
                        f.write(self.current_report_text)
                messagebox.showinfo("Export Successful", f"Report saved to:\n{dest}")
            except Exception as e:
                messagebox.showerror("Export Failed", str(e))

    def reveal_in_finder(self):
        if self.current_index >= 0 and self.current_index < len(self.file_list):
            fp = self.file_list[self.current_index]
            if os.path.exists(fp):
                subprocess.Popen(["open", "-R", fp])

    def _probe_file(self, filepath):
        if not os.path.exists(filepath):
            return f"❌ File not found: {filepath}", None, []

        file_size_bytes = os.path.getsize(filepath)
        filename = os.path.basename(filepath)

        cmd = [
            FFPROBE_BIN, "-v", "error",
            "-show_format",
            "-show_streams",
            "-show_chapters",
            "-of", "json",
            filepath
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=15)
            if res.returncode != 0 or not res.stdout.strip():
                return f"❌ ffprobe failed to inspect:\n{res.stderr.strip()}", None, []
            probe_data = json.loads(res.stdout)
        except Exception as e:
            return f"❌ Analysis error: {e}", None, []

        fmt = probe_data.get("format", {})
        streams = probe_data.get("streams", [])
        chapters = probe_data.get("chapters", [])
        fmt_tags = {str(k).lower(): v for k, v in fmt.get("tags", {}).items()}

        video_streams = [s for s in streams if s.get("codec_type") == "video"]
        audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
        subtitle_streams = [s for s in streams if s.get("codec_type") == "subtitle"]

        ext = os.path.splitext(filepath)[1].lower()
        is_image_file = ext in (
            ".jpg", ".jpeg", ".png", ".tiff", ".tif", ".webp", ".heic",
            ".bmp", ".gif", ".dng", ".cr2", ".nef", ".arw"
        )
        is_audio_file = ext in (
            ".mp3", ".wav", ".aac", ".m4a", ".flac", ".aiff", ".aif",
            ".ogg", ".wma", ".opus", ".m4r", ".ac3", ".eac3"
        )

        pure_video_streams = []
        image_streams = []
        for s in video_streams:
            c_name = s.get("codec_name", "").lower()
            disp = s.get("disposition", {}) or {}
            is_pic = (
                is_image_file
                or is_audio_file
                or disp.get("attached_pic") == 1
                or (c_name in ("mjpeg", "png", "bmp", "tiff", "webp", "gif") and (audio_streams or len(video_streams) > 1))
                or (c_name in ("mjpeg", "png", "webp", "tiff", "bmp", "heic") and (fmt.get("duration") is None or float(fmt.get("duration", 0) or 0) <= 0.05))
            )
            if is_pic:
                image_streams.append(s)
            else:
                pure_video_streams.append(s)

        is_picture_content = is_image_file or (bool(image_streams) and not pure_video_streams and not audio_streams)
        is_audio_content = is_audio_file or (bool(audio_streams) and not pure_video_streams)

        # Generate Punchy HUD Quick Stat Cards (Data on the Left of Title)
        badges = []
        dur_sec = fmt.get("duration") if not is_picture_content else None
        if not dur_sec and pure_video_streams and not is_picture_content:
            dur_sec = pure_video_streams[0].get("duration")
        dur_val = 0.0
        if dur_sec:
            try:
                dur_val = max(0.0, float(dur_sec))
            except (ValueError, TypeError):
                dur_val = 0.0
        dur_short = format_time_duration(dur_val) if dur_val > 0 else ""
        sz_str = format_bytes_size_str(file_size_bytes).split(" (")[0] if file_size_bytes else "N/A"
        size_val = f"{sz_str} ({dur_short})" if dur_short else sz_str

        if pure_video_streams:
            v0 = pure_video_streams[0]
            # 1. Resolution - Accent Highlight
            w0 = v0.get("width", 0)
            h0 = v0.get("height", 0)
            lbl0 = get_common_resolution_label(w0, h0).strip(" ()")
            res_val = f"{lbl0} ({w0}x{h0})" if (lbl0 and w0 and h0) else (f"{w0}x{h0}" if (w0 and h0) else "N/A")
            badges.append(("Resolution", res_val, ULTRA_BG, ULTRA_TEXT, ULTRA_BORDER))

            # 2. Bitrate - Sky Blue
            v_br = fmt.get("bit_rate") or v0.get("bit_rate") or v0.get("tags", {}).get("bps") or v0.get("tags", {}).get("BPS")
            br_val = format_bitrate_str(v_br) if v_br else "N/A"
            badges.append(("Bitrate", br_val, "#0c2229", "#38bdf8", "#154352"))

            # 3. Frame Rate - Emerald Green
            fps0 = parse_stream_fps_val(v0)
            fr_mode = get_frame_rate_mode(v0)
            mode_short = "CFR" if "CFR" in fr_mode else ("VFR" if "VFR" in fr_mode else "")
            fps_val = (f"{fps0:.2f} FPS" + (f" ({mode_short})" if mode_short else "")) if fps0 else "N/A"
            badges.append(("Frame Rate", fps_val, "#0b2418", "#34d399", "#144d32"))

            # 4. Color & Depth - Gold for HDR, Purple for SDR
            pix_fmt = v0.get("pix_fmt", "")
            chroma0, bit_depth0 = analyze_pix_fmt(pix_fmt, v0.get("bits_per_raw_sample"))
            cprim = v0.get("color_primaries")
            cp_disp = "BT.709" if (cprim and "709" in cprim) else ("BT.2020" if (cprim and "2020" in cprim) else (cprim.upper() if cprim and cprim not in ("N/A", "unknown") else "SDR"))
            c_trc = str(v0.get("color_transfer", "")).lower()
            is_hdr = any(k in c_trc for k in ("smpte2084", "pq", "arib-std-b67", "hlg"))
            if is_hdr:
                color_val = f"{cp_disp} HDR • {bit_depth0}"
                badges.append(("Color / HDR", color_val, "#291a07", "#fbbf24", "#57380f"))
            else:
                cd_parts = [cp_disp]
                if bit_depth0 and bit_depth0 != "N/A": cd_parts.append(bit_depth0)
                if chroma0 and chroma0 != "N/A": cd_parts.append(chroma0)
                color_val = " • ".join(cd_parts)
                badges.append(("Color Space", color_val, "#1c162b", "#c084fc", "#3b2b5c"))

            # 5. Audio - Indigo
            if audio_streams:
                a0 = audio_streams[0]
                ac0 = a0.get("codec_name", "").upper()
                sr0 = a0.get("sample_rate")
                sr_k = f"{float(sr0)/1000.0:.0f}k" if sr0 else ""
                try: ch0 = int(a0.get("channels", 2) or 2)
                except Exception: ch0 = 2
                ch_str = "Mono" if ch0 == 1 else ("Stereo" if ch0 == 2 else f"{ch0}Ch")
                a_parts = [ac0] if ac0 else []
                if ch_str: a_parts.append(ch_str)
                if sr_k: a_parts.append(sr_k)
                audio_val = " • ".join(a_parts) or "Audio Stream"
                badges.append(("Audio", audio_val, "#141a29", "#818cf8", "#233252"))
            else:
                badges.append(("Audio", "No Audio Track", "#18191c", "#9ca3af", "#2e3036"))

            # 6. File Size - Neutral Graphite
            badges.append(("File Size", size_val, "#18191c", "#e2e8f0", "#2e3036"))

        elif is_picture_content and (image_streams or pure_video_streams):
            im0 = (image_streams or pure_video_streams)[0]
            w0 = im0.get("width", 0)
            h0 = im0.get("height", 0)
            mp = round((w0 * h0) / 1_000_000.0, 1) if (w0 and h0) else 0
            c_name = im0.get("codec_name", "IMAGE").upper()
            pix_fmt = im0.get("pix_fmt", "")
            chroma0, bit_depth0 = analyze_pix_fmt(pix_fmt, im0.get("bits_per_raw_sample"))
            dar = im0.get("display_aspect_ratio") or (f"{round(w0/h0, 2)}:1" if (w0 and h0) else "")
            sz_str = format_bytes_size_str(file_size_bytes).split(" (")[0] if file_size_bytes else "N/A"

            badges.append(("Resolution", f"{mp} MP ({w0}x{h0})" if mp > 0 else (f"{w0}x{h0}" if (w0 and h0) else "N/A"), ULTRA_BG, ULTRA_TEXT, ULTRA_BORDER))
            badges.append(("Format", c_name, "#0c2229", "#38bdf8", "#154352"))
            badges.append(("Color Depth", f"{bit_depth0} ({pix_fmt})" if bit_depth0 != "N/A" else pix_fmt, "#1c162b", "#c084fc", "#3b2b5c"))
            badges.append(("Chroma", chroma0 if chroma0 != "N/A" else "Standard", "#0b2418", "#34d399", "#144d32"))
            badges.append(("Aspect Ratio", dar or "N/A", "#141a29", "#818cf8", "#233252"))
            badges.append(("File Size", sz_str, "#18191c", "#e2e8f0", "#2e3036"))

        elif is_audio_content and audio_streams:
            a0 = audio_streams[0]
            ac0 = a0.get("codec_name", "").upper()
            lossless = any(c in ac0.lower() for c in ("pcm", "flac", "alac", "truehd", "wavpack", "ape"))
            a_br = a0.get("bit_rate") or a0.get("tags", {}).get("bps") or fmt.get("bit_rate")
            sr0 = a0.get("sample_rate")
            sr_k = f"{float(sr0)/1000.0:.1f} kHz" if sr0 else ""
            try: ch0 = int(a0.get("channels", 2) or 2)
            except Exception: ch0 = 2
            layout = a0.get("channel_layout") or ("Mono" if ch0 == 1 else ("Stereo" if ch0 == 2 else f"{ch0} Ch"))

            badges.append(("Audio Format", f"{ac0} {'(Lossless)' if lossless else ''}".strip(), ULTRA_BG, ULTRA_TEXT, ULTRA_BORDER))
            badges.append(("Bitrate", "Lossless" if lossless else (format_bitrate_str(a_br) if a_br else "N/A"), "#0c2229", "#38bdf8", "#154352"))
            badges.append(("Sample Rate", sr_k or "N/A", "#0b2418", "#34d399", "#144d32"))
            badges.append(("Channels", str(layout), "#1c162b", "#c084fc", "#3b2b5c"))
            badges.append(("Duration", dur_short or "N/A", "#141a29", "#818cf8", "#233252"))
            badges.append(("File Size", sz_str, "#18191c", "#e2e8f0", "#2e3036"))

        lines = []

        def add_2col(k1, v1, k2="", v2=""):
            if v1 is not None and str(v1).strip() != "":
                lines.append(f"{k1}\t{v1}")
            if k2 and v2 is not None and str(v2).strip() != "":
                lines.append(f"{k2}\t{v2}")

        # GENERAL
        lines.append("GENERAL")
        fmt_long = fmt.get("format_long_name", "")
        fmt_name = fmt.get("format_name", "")
        container_disp = fmt_long.split(" (")[0] if fmt_long else fmt_name
        add_2col("Container", container_disp)
        gen_sz = format_bytes_size_str(file_size_bytes)
        add_2col("File Size", gen_sz)
        gen_dur = format_detailed_duration(dur_sec) if (dur_sec and not is_picture_content) else "N/A"
        add_2col("Duration", gen_dur)
        gen_br = format_bitrate_str(fmt.get("bit_rate")) if (fmt.get("bit_rate") and not is_picture_content) else "N/A"
        add_2col("Bitrate", gen_br)
        raw_date = fmt_tags.get("creation_time") or fmt_tags.get("date") or fmt_tags.get("com.apple.quicktime.creationdate")
        if not raw_date and pure_video_streams:
            v_tags = {str(k).lower(): v for k, v in pure_video_streams[0].get("tags", {}).items()}
            raw_date = v_tags.get("creation_time") or v_tags.get("date") or v_tags.get("com.apple.quicktime.creationdate")
        c_date = "N/A"
        if raw_date:
            first_d = str(raw_date).split(";")[0].split(",")[0].strip()
            m = re.match(r"^(\d{4}-\d{2}-\d{2})[T\s](\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?", first_d)
            if m:
                tz_raw = m.group(3)
                if tz_raw in ("Z", "+00:00", "-00:00", "+0000", "-0000"):
                    tz = " UTC"
                elif tz_raw:
                    tz = f" {tz_raw[:3]}:{tz_raw[3:]}" if len(tz_raw) == 5 and ":" not in tz_raw else f" {tz_raw}"
                else:
                    tz = ""
                c_date = f"{m.group(1)} {m.group(2)}{tz}"
            else:
                c_date = first_d
        add_2col("Creation Date", c_date)
        lines.append("")

        # VIDEO STREAMS
        for idx, vs in enumerate(pure_video_streams):
            codec_name = vs.get("codec_name", "").upper()
            prof = vs.get("profile", "")
            lvl = vs.get("level", "")
            lvl_str = f"@{lvl}" if (lvl and str(lvl) != "-99") else ""
            if lvl_str and not lvl_str.startswith("@L") and lvl_str != "@":
                lvl_str = f"@L{lvl}"
            prof_full = f"{prof}{lvl_str}".strip("@")
            codec_prof = f"{codec_name} ({prof_full})" if prof_full else codec_name

            w, h = vs.get("width"), vs.get("height")
            res_label = get_common_resolution_label(w, h)
            res_disp = f"{w} x {h}{res_label}" if (w and h) else "N/A"

            fps_val = parse_stream_fps_val(vs)
            fps_mode = get_frame_rate_mode(vs)
            fps_disp = f"{fps_val:.3f} fps ({fps_mode})" if fps_val else "N/A"

            dar = vs.get("display_aspect_ratio")
            if not dar and w and h and int(h) > 0:
                dar = f"{round(float(w)/float(h), 2)}:1"
            dar_disp = dar or "N/A"

            pix_fmt = vs.get("pix_fmt", "")
            chroma, bit_depth = analyze_pix_fmt(pix_fmt, vs.get("bits_per_raw_sample"))
            bd_disp = f"{bit_depth} ({pix_fmt})" if pix_fmt else bit_depth

            cprim = vs.get("color_primaries") or "N/A"
            cspace = vs.get("color_space") or "N/A"

            crange = str(vs.get("color_range", "")).lower()
            if crange in ("tv", "limited"):
                range_disp = "TV"
            elif crange in ("pc", "full", "jpeg"):
                range_disp = "Full"
            elif crange:
                range_disp = crange.upper()
            else:
                range_disp = "N/A"

            lines.append(f"VIDEO STREAM #{idx + 1}")
            add_2col("Codec / Profile", codec_prof, "Resolution", res_disp)
            add_2col("Frame Rate", fps_disp, "Aspect Ratio", dar_disp)
            add_2col("Bit Depth", bd_disp, "Chroma Sampling", chroma)
            add_2col("Color Primaries", cprim, "Matrix / Space", cspace)
            add_2col("Color Range", range_disp)
            lines.append("")

        # AUDIO STREAMS
        for idx, a_st in enumerate(audio_streams):
            ac_name = a_st.get("codec_name", "").upper()
            prof = a_st.get("profile", "")
            codec_disp = f"{ac_name} ({prof})" if prof else ac_name

            a_br = a_st.get("bit_rate") or a_st.get("tags", {}).get("bps") or a_st.get("tags", {}).get("BPS")
            br_disp = format_bitrate_str(a_br)

            ch = a_st.get("channels")
            layout = a_st.get("channel_layout", "")
            ch_disp = f"{ch} Channels ({layout})" if (ch and layout) else (f"{ch} Channels" if ch else "N/A")

            sr = a_st.get("sample_rate")
            sr_disp = f"{float(sr)/1000.0:.1f} kHz" if sr else "N/A"

            a_tags = {str(k).lower(): v for k, v in a_st.get("tags", {}).items()}
            lang = a_tags.get("language") or "eng"

            lines.append(f"AUDIO STREAM #{idx + 1}")
            add_2col("Codec", codec_disp, "Bitrate", br_disp)
            add_2col("Channels", ch_disp, "Sample Rate", sr_disp)
            add_2col("Language", lang)
            lines.append("")

        # IMAGE STREAMS
        for idx, img_st in enumerate(image_streams):
            codec_name = img_st.get("codec_name", "").upper()
            w = img_st.get("width")
            h = img_st.get("height")
            sec_name = "ALBUM ART / COVER" if is_audio_content else f"IMAGE STREAM #{idx + 1}"
            lines.append(sec_name)
            add_2col("Codec", codec_name, "Resolution", f"{w} x {h}" if (w and h) else "N/A")
            chroma, bit_depth = analyze_pix_fmt(img_st.get("pix_fmt"), img_st.get("bits_per_raw_sample"))
            add_2col("Bit Depth", bit_depth, "Chroma Sampling", chroma)
            lines.append("")

        # SUBTITLES
        for idx, sub_st in enumerate(subtitle_streams):
            codec_name = sub_st.get("codec_name", "").upper()
            s_tags = {str(k).lower(): v for k, v in sub_st.get("tags", {}).items()}
            lines.append(f"SUBTITLE STREAM #{idx + 1}")
            add_2col("Codec", codec_name, "Language", s_tags.get("language") or "N/A")
            if s_tags.get("title"):
                add_2col("Title", s_tags.get("title"))
            lines.append("")

        # CHAPTERS
        if chapters:
            lines.append(f"CHAPTERS ({len(chapters)} Total)")
            for ch in chapters:
                c_id = ch.get("id")
                c_start = format_detailed_duration(ch.get("start_time"))
                c_end = format_detailed_duration(ch.get("end_time"))
                c_title = ch.get("tags", {}).get("title", f"Chapter {c_id}")
                lines.append(f"{c_title}\t{c_start} -> {c_end}")
            lines.append("")

        return "\n".join(lines), probe_data, badges

def main():
    try:
        initial_files = [clean_file_path(f) for f in sys.argv[1:] if os.path.exists(clean_file_path(f)) and not f.startswith("-psn")]
        root = CTkWithDnD()
        app = MediaInspectorApp(root, initial_files=initial_files)

        def on_mac_open(*args):
            found = []
            for arg in args:
                if isinstance(arg, (list, tuple)):
                    for item in arg:
                        c = clean_file_path(item)
                        if os.path.exists(c): found.append(c)
                elif isinstance(arg, str):
                    c = clean_file_path(arg)
                    if os.path.exists(c): found.append(c)
            if found:
                root.after(0, lambda: app.load_files(found))

        try:
            root.createcommand("::tk::mac::OpenDocument", on_mac_open)
        except Exception:
            pass

        root.mainloop()
    except Exception as e:
        with open(os.path.expanduser("~/Library/Logs/MediaInspector_crash.log"), "w") as f:
            f.write(str(e))
        raise

if __name__ == "__main__":
    main()

PYEOF

# 5. Convert PNG to Multi-Resolution Apple ICNS Format
PYINSTALLER_ICON_ARG=""
if [ -f "$ICON_SRC" ]; then
    echo "🎨 Processing icon from $ICON_SRC..."
    ICONSET_DIR="/tmp/AppIcon.iconset"
    ICNS_PATH="$WORKDIR/AppIcon.icns"
    rm -rf "$ICONSET_DIR" "$ICNS_PATH"
    mkdir -p "$ICONSET_DIR"

    "$VENV_DIR/bin/python" - "$ICON_SRC" << 'PYICON'
import sys, os
from PIL import Image, ImageOps

src_path = sys.argv[1]
iconset_dir = "/tmp/AppIcon.iconset"
scale = 0.82

img = ImageOps.exif_transpose(Image.open(src_path)).convert("RGBA")
w, h = img.size
resample_filter = getattr(Image.Resampling, 'LANCZOS', Image.LANCZOS)

targets = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for canvas_sz, filename in targets:
    canvas = Image.new("RGBA", (canvas_sz, canvas_sz), (0, 0, 0, 0))
    target_sz = max(1, int(canvas_sz * scale))
    ratio = min(target_sz / w, target_sz / h)
    new_w = max(1, int(w * ratio))
    new_h = max(1, int(h * ratio))
    resized = img.resize((new_w, new_h), resample_filter)
    canvas.paste(resized, ((canvas_sz - new_w) // 2, (canvas_sz - new_h) // 2), resized)
    canvas.save(os.path.join(iconset_dir, filename), "PNG")
PYICON


    iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
    rm -rf "$ICONSET_DIR"

    if [ -f "$ICNS_PATH" ]; then
        PYINSTALLER_ICON_ARG="--icon=$ICNS_PATH"
        echo "✔ Generated standalone Apple ICNS icon"
    fi
fi

# 6. Build with PyInstaller
echo "🔨 Running PyInstaller..."
"$VENV_DIR/bin/pyinstaller" --windowed --noconfirm --clean \
    ${PYINSTALLER_ICON_ARG:+"$PYINSTALLER_ICON_ARG"} \
    --additional-hooks-dir=. \
    --collect-all customtkinter \
    --collect-all tkinterdnd2 \
    --collect-all tkinter \
    --osx-bundle-identifier "com.local.mediainspector" \
    --name "MediaInspector" \
    media_inspector_gui.py

# 7. Embed Standalone Static FFprobe
echo "📦 Embedding static FFprobe into App bundle..."
BIN_DEST="dist/MediaInspector.app/Contents/MacOS"
mkdir -p "$BIN_DEST"
cp "$BIN_CACHE/ffprobe" "$BIN_DEST/ffprobe"
chmod +x "$BIN_DEST/ffprobe"

# 8. Configure Info.plist with Document Types for Dock Drag-and-Drop
"$PYTHON_EXEC" - << 'PYPLIST'
import plistlib, os
plist_path = "dist/MediaInspector.app/Contents/Info.plist"
if os.path.exists(plist_path):
    with open(plist_path, "rb") as f:
        pl = plistlib.load(f)
    pl["CFBundleDocumentTypes"] = [{
        "CFBundleTypeName": "Media Files",
        "CFBundleRole": "Viewer",
        "LSHandlerRank": "Alternate",
        "LSItemContentTypes": ["public.item", "public.data", "public.content", "public.movie", "public.video", "public.audio", "public.image"],
        "CFBundleTypeExtensions": [
            "mp4", "mov", "mkv", "m4v", "avi", "crm", "raw", "wmv", "flv", "webm", "ts", "mts", "m2ts", "vob", "mxf", "ogv",
            "mp3", "wav", "aac", "m4a", "flac", "aiff", "aif", "ogg", "opus", "wma", "ac3", "eac3", "dts",
            "jpg", "jpeg", "png", "tiff", "tif", "webp", "heic", "heif", "bmp", "gif", "dng", "cr2", "nef", "arw"
        ]
    }]
    pl["NSHighResolutionCapable"] = True
    pl["NSSupportsAppNap"] = False
    pl["NSSupportsAutomaticTermination"] = False
    with open(plist_path, "wb") as f:
        plistlib.dump(pl, f)
PYPLIST

APP_PATH="$HOME/Desktop/MediaInspector.app"
rm -rf "$APP_PATH"
mv "dist/MediaInspector.app" "$HOME/Desktop/"
touch "$APP_PATH"

# 9. Code Sign Locally
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

# 10. Create Standalone .DMG Installer
echo "📦 Creating Drag & Drop .dmg distribution file..."
DMG_PATH="$HOME/Desktop/MediaInspector.dmg"
rm -f "$DMG_PATH"

DMG_TMP="/tmp/dmg_staging_inspector"
rm -rf "$DMG_TMP"
mkdir -p "$DMG_TMP"

ditto "$APP_PATH" "$DMG_TMP/MediaInspector.app"
ln -s /Applications "$DMG_TMP/Applications"

cat << 'READMEEOF' > "$DMG_TMP/⚠️ FIRST-TIME USERS - READ ME.txt"
======================================================================
            MediaInspector - First-Time Setup Instructions
======================================================================

Because MediaInspector is self-built and ad-hoc signed, macOS Gatekeeper
will flag it as "damaged" or block it on first launch.

----------------------------------------------------------------------
👉 1-STEP FIX (Works on all macOS versions, including Sequoia):
----------------------------------------------------------------------

1. Drag "MediaInspector" into the "Applications" folder shortcut.

2. Open Terminal (press Cmd + Space, type "Terminal", press Enter).

3. Paste and run this command:
   xattr -cr /Applications/MediaInspector.app

✔ Done! This removes the quarantine flag. MediaInspector will now open
  immediately with a normal double-click.

----------------------------------------------------------------------
ℹ️ WHY IS THIS REQUIRED?
----------------------------------------------------------------------
macOS automatically quarantines downloaded files. Because MediaInspector is
built locally without an expensive Apple Developer certificate, macOS
falsely reports the app as "damaged". The command above simply removes
the quarantine tag so macOS treats it as a trusted local app.
======================================================================
READMEEOF

hdiutil create -volname "MediaInspector" -srcfolder "$DMG_TMP" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_TMP"

cd "$HOME"
rm -rf "$WORKDIR" "$VENV_DIR"

echo ""
echo "=================================================="
echo "  🎉 SUCCESS! Your distributor DMG is ready:     "
echo "  $DMG_PATH"
echo "=================================================="
