from __future__ import annotations

import csv
import json
import math
import os
import queue
import re
import threading
import time
import traceback
import tkinter as tk
from dataclasses import asdict
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Dict, List, Optional, Tuple

import numpy as np
from matplotlib import rcParams
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
from matplotlib.figure import Figure
from matplotlib.patches import Circle

from ae_fpga_client.config import AEConfig, ControlConfig, default_config, sample_rate_options
from ae_fpga_client.protocol import AEEvent
from ae_fpga_client.udp_client import AEUdpClient, ReceiveStats
from ae_localization.d1_aic_core import (
    D1AICLocalizationParams,
    D1AICOptions,
    MaterialParams,
    d1_aic_localize,
)

# -----------------------------------------------------------------------------
# Matplotlib thesis-style font configuration.
# Chinese labels use SimSun; English/numbers use Times New Roman where possible.
# -----------------------------------------------------------------------------
rcParams["font.family"] = ["Times New Roman", "SimSun"]
rcParams["font.serif"] = ["Times New Roman"]
rcParams["font.sans-serif"] = ["SimSun", "Microsoft YaHei", "Times New Roman"]
rcParams["axes.unicode_minus"] = False

# -----------------------------------------------------------------------------
# Nature-style blue GUI palette and typography
# -----------------------------------------------------------------------------
FONT_CN = "SimSun"
FONT_EN = "Times New Roman"
FONT_MONO = "Consolas"
FONT_UI_SIZE = 10
FONT_TITLE_SIZE = 20
FONT_CHART_LABEL_SIZE = 8
FONT_CHART_TITLE_SIZE = 10

COLOR_BG = "#F7FBFF"
COLOR_PANEL = "#EAF3F8"
COLOR_PANEL_2 = "#D9ECF7"
COLOR_TEXT = "#0B2545"
COLOR_PRIMARY = "#1F5F99"
COLOR_PRIMARY_DARK = "#0B3C5D"
COLOR_ACCENT = "#2B7BBA"
COLOR_GRID = "#D3E5F2"
COLOR_BORDER = "#9EC9E2"
COLOR_WHITE = "#FFFFFF"

MPL_LINE = "#1F77B4"
MPL_LINE_2 = "#D95F02"
MPL_SENSOR = "#9E9E9E"
MPL_TARGET = "#C44E52"
MPL_EST = "#1B9E77"
MPL_BAR = "#4C78A8"
SENSOR_DIAMETER_M = 0.012
SENSOR_RADIUS_M = SENSOR_DIAMETER_M / 2.0


def safe_float(text: str, default: float = 0.0) -> float:
    try:
        return float(str(text).strip())
    except Exception:
        return default


def safe_int(text: str, default: int = 0, base: int = 10) -> int:
    try:
        return int(str(text).strip(), base)
    except Exception:
        return default


def fmt_coord_for_filename(v: float) -> str:
    # Windows allows '.', but this keeps file names compact and stable.
    s = f"{float(v):.4f}".rstrip("0").rstrip(".")
    if s == "-0":
        s = "0"
    return s


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    stem = path.stem
    suffix = path.suffix
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    candidate = path.with_name(f"{stem}_{ts}{suffix}")
    if not candidate.exists():
        return candidate
    for i in range(1, 1000):
        candidate = path.with_name(f"{stem}_{ts}_{i}{suffix}")
        if not candidate.exists():
            return candidate
    return path.with_name(f"{stem}_{ts}_{os.getpid()}{suffix}")


class AEAcqLocGui(tk.Tk):
    """Integrated AE acquisition + selectable 4/8/12/16-channel localization GUI.

    The UDP acquisition path intentionally reuses the original ae_python_39_full_client
    UDP client/protocol modules. Localization is triggered explicitly after an event has
    been acquired, so data capture and localization remain logically separated.
    """

    def __init__(self) -> None:
        super().__init__()
        self.title("AE Acquisition and D1-AIC Multichannel Localization System - Python")
        self._init_window_geometry()

        self.cfg: AEConfig = default_config()
        self.client: Optional[AEUdpClient] = None
        self.last_event: Optional[AEEvent] = None
        self.last_stats: Optional[ReceiveStats] = None
        self.last_samples4: Optional[np.ndarray] = None
        self.loaded_saved_data: Optional[Dict[str, object]] = None
        self.last_loc_result: Optional[Dict[str, object]] = None
        self.is_busy = False
        self.ui_queue: "queue.Queue[tuple]" = queue.Queue()
        self.log_lines: List[str] = []
        self.log_max_lines = 600

        self._setup_theme()
        self._build_ui()
        self._log("Python acquisition-localization GUI initialized.")
        self.after(120, self._process_queue)
        self.after(1000, self._update_clock)
        self.protocol("WM_DELETE_WINDOW", self.on_close)

    # ------------------------------------------------------------------ UI

    def _init_window_geometry(self) -> None:
        """Make the main window adapt to the current monitor instead of forcing 1920x1080.

        The old fixed geometry/minsize could be larger than many laptop screens
        or high-DPI scaled desktops, so widgets were clipped.  This initializes
        a safe per-screen scale factor and opens the window maximized/full-screen
        where the platform supports it.
        """
        try:
            screen_w = max(800, int(self.winfo_screenwidth()))
            screen_h = max(600, int(self.winfo_screenheight()))
        except Exception:
            screen_w, screen_h = 1366, 768

        self.screen_w = screen_w
        self.screen_h = screen_h
        self.ui_scale = max(0.78, min(1.15, min(screen_w / 1920.0, screen_h / 1080.0)))
        self.left_pane_width = max(260, min(380, int(screen_w * 0.22)))
        self.right_pane_width = max(290, min(430, int(screen_w * 0.24)))

        # Never make the minimum window larger than the physical screen.
        min_w = max(760, min(1100, int(screen_w * 0.72)))
        min_h = max(540, min(760, int(screen_h * 0.72)))
        self.geometry(f"{min(screen_w, 1920)}x{min(screen_h, 1080)}+0+0")
        self.minsize(min_w, min_h)

        # Best-effort maximize.  Different Tk platforms use different options.
        try:
            self.state("zoomed")  # Windows
        except Exception:
            try:
                self.attributes("-zoomed", True)  # Linux/X11
            except Exception:
                pass

    def _scaled(self, value: float, minimum: int = 1) -> int:
        return max(minimum, int(round(float(value) * float(getattr(self, "ui_scale", 1.0)))))

    def _fs(self, value: int, minimum: int = 8) -> int:
        return max(minimum, self._scaled(value, minimum=minimum))

    def _figure_size(self, width: float, height: float) -> Tuple[float, float]:
        scale = float(getattr(self, "ui_scale", 1.0))
        return max(3.0, width * scale), max(2.0, height * scale)

    def _make_scrollable_container(self, parent: tk.Widget) -> Tuple[ttk.Frame, ttk.Frame]:
        """Return (container, inner_frame) with mouse-wheel vertical scrolling."""
        container = ttk.Frame(parent)
        canvas = tk.Canvas(container, bg=COLOR_BG, highlightthickness=0, bd=0)
        vbar = ttk.Scrollbar(container, orient=tk.VERTICAL, command=canvas.yview)
        inner = ttk.Frame(canvas)
        inner_id = canvas.create_window((0, 0), window=inner, anchor="nw")

        def _update_scrollregion(_event=None) -> None:
            canvas.configure(scrollregion=canvas.bbox("all"))

        def _fit_inner_width(event) -> None:
            canvas.itemconfigure(inner_id, width=max(1, int(event.width)))

        def _on_mousewheel(event) -> None:
            # Windows/macOS use event.delta; Linux often sends Button-4/5.
            if getattr(event, "num", None) == 4:
                canvas.yview_scroll(-1, "units")
            elif getattr(event, "num", None) == 5:
                canvas.yview_scroll(1, "units")
            else:
                delta = int(-1 * (event.delta / 120)) if event.delta else 0
                if delta:
                    canvas.yview_scroll(delta, "units")

        def _bind_wheel(_event=None) -> None:
            canvas.bind_all("<MouseWheel>", _on_mousewheel, add="+")
            canvas.bind_all("<Button-4>", _on_mousewheel, add="+")
            canvas.bind_all("<Button-5>", _on_mousewheel, add="+")

        def _unbind_wheel(_event=None) -> None:
            canvas.unbind_all("<MouseWheel>")
            canvas.unbind_all("<Button-4>")
            canvas.unbind_all("<Button-5>")

        inner.bind("<Configure>", _update_scrollregion)
        canvas.bind("<Configure>", _fit_inner_width)
        container.bind("<Enter>", _bind_wheel)
        container.bind("<Leave>", _unbind_wheel)

        canvas.configure(yscrollcommand=vbar.set)
        canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        vbar.pack(side=tk.RIGHT, fill=tk.Y)
        return container, inner

    def _bind_responsive_figure(self, fig: Figure, canvas: FigureCanvasTkAgg, pad: float = 0.8, rect=None) -> None:
        """Resize the Matplotlib figure to the actual Tk canvas size."""
        widget = canvas.get_tk_widget()
        last_size = {"w": 0, "h": 0}

        def _resize(event) -> None:
            w = max(120, int(event.width))
            h = max(90, int(event.height))
            if abs(w - last_size["w"]) < 8 and abs(h - last_size["h"]) < 8:
                return
            last_size["w"], last_size["h"] = w, h
            fig.set_size_inches(w / fig.dpi, h / fig.dpi, forward=False)
            try:
                if rect is None:
                    fig.tight_layout(pad=pad)
                else:
                    fig.tight_layout(rect=rect, pad=pad)
            except Exception:
                pass
            canvas.draw_idle()

        widget.bind("<Configure>", _resize, add="+")

    def _make_treeview_with_scrollbars(
        self,
        parent: ttk.Frame,
        columns: Tuple[str, ...],
        height: int,
        column_width: int = 88,
    ) -> ttk.Treeview:
        """Create a Treeview that can scroll both vertically and horizontally."""
        wrap = ttk.Frame(parent)
        wrap.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        wrap.rowconfigure(0, weight=1)
        wrap.columnconfigure(0, weight=1)

        tree = ttk.Treeview(wrap, columns=columns, show="headings", height=max(4, self._scaled(height)))
        for col in columns:
            tree.heading(col, text=col)
            tree.column(col, width=self._scaled(column_width, minimum=60), minwidth=55, anchor="center", stretch=False)

        ybar = ttk.Scrollbar(wrap, orient=tk.VERTICAL, command=tree.yview)
        xbar = ttk.Scrollbar(wrap, orient=tk.HORIZONTAL, command=tree.xview)
        tree.configure(yscrollcommand=ybar.set, xscrollcommand=xbar.set)

        tree.grid(row=0, column=0, sticky="nsew")
        ybar.grid(row=0, column=1, sticky="ns")
        xbar.grid(row=1, column=0, sticky="ew")
        return tree

    def _setup_theme(self) -> None:
        """Apply a thesis/Nature-style blue theme to the Tkinter GUI."""
        self.configure(bg=COLOR_BG)
        ui_font = self._fs(FONT_UI_SIZE)
        self.option_add("*Font", (FONT_CN, ui_font))
        self.option_add("*TCombobox*Listbox.font", (FONT_CN, ui_font))

        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except Exception:
            pass

        style.configure(".", font=(FONT_CN, ui_font), background=COLOR_BG, foreground=COLOR_TEXT)
        style.configure("TFrame", background=COLOR_BG)
        style.configure("TLabelframe", background=COLOR_BG, bordercolor=COLOR_BORDER, relief="solid")
        style.configure("TLabelframe.Label", background=COLOR_BG, foreground=COLOR_PRIMARY_DARK, font=(FONT_CN, ui_font, "bold"))
        style.configure("TLabel", background=COLOR_BG, foreground=COLOR_TEXT, font=(FONT_CN, ui_font))
        style.configure("TEntry", fieldbackground=COLOR_WHITE, foreground=COLOR_TEXT, insertcolor=COLOR_PRIMARY_DARK, font=(FONT_EN, ui_font))
        style.configure("TCombobox", fieldbackground=COLOR_WHITE, foreground=COLOR_TEXT, font=(FONT_CN, ui_font))
        style.configure("TCheckbutton", background=COLOR_BG, foreground=COLOR_TEXT, font=(FONT_CN, ui_font))
        style.configure("TButton", background=COLOR_PRIMARY, foreground=COLOR_WHITE, bordercolor=COLOR_PRIMARY_DARK, focusthickness=1, focuscolor=COLOR_ACCENT, padding=(self._scaled(8), self._scaled(4)), font=(FONT_CN, ui_font, "bold"))
        style.map("TButton", background=[("active", COLOR_ACCENT), ("pressed", COLOR_PRIMARY_DARK)], foreground=[("disabled", "#A0A0A0")])
        style.configure("TNotebook", background=COLOR_BG, borderwidth=0)
        style.configure("TNotebook.Tab", background=COLOR_PANEL_2, foreground=COLOR_PRIMARY_DARK, padding=(self._scaled(12), self._scaled(5)), font=(FONT_CN, ui_font, "bold"))
        style.map("TNotebook.Tab", background=[("selected", COLOR_PRIMARY)], foreground=[("selected", COLOR_WHITE)])
        style.configure("Treeview", background=COLOR_WHITE, fieldbackground=COLOR_WHITE, foreground=COLOR_TEXT, rowheight=self._scaled(24, minimum=20), font=(FONT_EN, ui_font))
        style.configure("Treeview.Heading", background=COLOR_PRIMARY_DARK, foreground=COLOR_WHITE, font=(FONT_CN, ui_font, "bold"))
        style.map("Treeview", background=[("selected", COLOR_ACCENT)], foreground=[("selected", COLOR_WHITE)])

    def _style_figure(self, fig: Figure) -> None:
        fig.patch.set_facecolor(COLOR_BG)
        for ax in fig.axes:
            ax.set_facecolor(COLOR_WHITE)

    def _style_axis(self, ax, title: str | None = None) -> None:
        ax.set_facecolor(COLOR_WHITE)
        ax.grid(True, color=COLOR_GRID, linewidth=0.45)
        for spine in ax.spines.values():
            spine.set_color(COLOR_BORDER)
            spine.set_linewidth(0.8)
        ax.tick_params(colors=COLOR_TEXT, labelsize=self._fs(FONT_CHART_LABEL_SIZE, minimum=7))
        for label in ax.get_xticklabels() + ax.get_yticklabels():
            label.set_fontname(FONT_EN)
            label.set_fontsize(self._fs(FONT_CHART_LABEL_SIZE, minimum=7))
        if title:
            ax.set_title(title, fontname=FONT_CN, fontsize=self._fs(FONT_CHART_TITLE_SIZE, minimum=8), color=COLOR_PRIMARY_DARK, pad=self._scaled(5))

    def _build_ui(self) -> None:
        root = ttk.Frame(self)
        root.pack(fill=tk.BOTH, expand=True, padx=self._scaled(8), pady=self._scaled(8))

        top = ttk.Frame(root)
        top.pack(fill=tk.X, pady=(0, 6))
        top.columnconfigure(0, weight=1)
        top.columnconfigure(1, weight=0)
        top.columnconfigure(2, weight=0)
        ttk.Label(
            top,
            text="AE Acquisition and D1-AIC Multichannel Localization System",
            font=(FONT_CN, self._fs(FONT_TITLE_SIZE, minimum=14), "bold"),
            foreground=COLOR_PRIMARY_DARK,
        ).grid(row=0, column=0, sticky="w")

        self.logo_path_var = tk.StringVar(value=r"CQU.png")
        self.logo_status_var = tk.StringVar(value="CQU.png")
        self.logo_image: Optional[tk.PhotoImage] = None
        logo_area = ttk.Frame(top)
        logo_area.grid(row=0, column=1, sticky="e", padx=(8, 12))
        self.logo_label = ttk.Label(logo_area, text="Logo", anchor="center", width=max(10, self._scaled(16)))
        self.logo_label.grid(row=0, column=0, rowspan=2, sticky="e", padx=(0, 6))
        ttk.Button(logo_area, text="Import Logo", command=self.on_import_logo).grid(row=0, column=1, sticky="ew", pady=(0, 2))
        ttk.Label(logo_area, textvariable=self.logo_status_var, font=(FONT_EN, self._fs(8, minimum=7)), foreground=COLOR_PRIMARY_DARK).grid(row=1, column=1, sticky="e")
        self._load_logo_image(self.logo_path_var.get())

        self.clock_var = tk.StringVar(value="")
        ttk.Label(top, textvariable=self.clock_var, font=(FONT_EN, self._fs(FONT_UI_SIZE)), foreground=COLOR_PRIMARY_DARK).grid(row=0, column=2, sticky="e")

        # Layout required by the updated design:
        #   left   = parameter setting pages;
        #   center = waveform / localization pages;
        #   right  = original parameter output / display panels;
        #   bottom = full-width running log.
        body = ttk.PanedWindow(root, orient=tk.HORIZONTAL)
        body.pack(fill=tk.BOTH, expand=True)

        left = ttk.Frame(body, width=self.left_pane_width)
        center = ttk.Frame(body)
        right = ttk.Frame(body, width=self.right_pane_width)
        left.pack_propagate(False)
        right.pack_propagate(False)
        body.add(left, weight=0)
        body.add(center, weight=1)
        body.add(right, weight=0)

        self._build_left_param_pages(left)
        self._build_center(center)
        self._build_right_output(right)
        self._build_log_bottom(root)


    def _load_logo_image(self, path: str) -> None:
        """Load and display the top-bar logo if the image file exists."""
        if not hasattr(self, "logo_label"):
            return
        p = Path(path)
        if not p.exists():
            self.logo_image = None
            self.logo_label.configure(image="", text="Logo")
            self.logo_status_var.set("Logo not found")
            return
        try:
            img = tk.PhotoImage(file=str(p))
            max_w, max_h = self._scaled(120, minimum=72), self._scaled(54, minimum=34)
            scale = max(1, math.ceil(max(img.width() / max_w, img.height() / max_h)))
            if scale > 1:
                img = img.subsample(scale, scale)
            self.logo_image = img
            self.logo_label.configure(image=self.logo_image, text="")
            self.logo_path_var.set(str(p))
            self.logo_status_var.set(p.name)
        except Exception:
            self.logo_image = None
            self.logo_label.configure(image="", text="Logo")
            self.logo_status_var.set("Logo load failed")

    def on_import_logo(self) -> None:
        """Select a logo image and show it in the top bar."""
        initial = self.logo_path_var.get().strip() or r"CQU.png"
        initial_path = Path(initial)
        path = filedialog.askopenfilename(
            title="Import Logo",
            initialdir=str(initial_path.parent) if initial_path.parent.exists() else str(Path.home()),
            filetypes=[("PNG images", "*.png"), ("GIF images", "*.gif"), ("All files", "*.*")],
        )
        if path:
            self._load_logo_image(path)


    def _build_left_param_pages(self, parent: ttk.Frame) -> None:
        """Left-side parameter setting pages.

        The parameter input area remains on the left. It is split into pages so
        UDP/acquisition parameters, save/geometry parameters, localization
        parameters, and operation controls do not crowd into one long page.
        """
        nb = ttk.Notebook(parent)
        nb.pack(fill=tk.BOTH, expand=True)

        udp_container, udp_page = self._make_scrollable_container(nb)
        save_container, save_page = self._make_scrollable_container(nb)
        loc_container, loc_page = self._make_scrollable_container(nb)
        nb.add(udp_container, text="UDP")
        nb.add(save_container, text="Data")
        nb.add(loc_container, text="Localization")

        # ------------------------------------------------------------------ UDP page
        net = ttk.LabelFrame(udp_page, text="Network and Connection")
        net.pack(fill=tk.X, padx=6, pady=(6, 6))
        self.local_ip = tk.StringVar(value=self.cfg.local_ip)
        self.local_port = tk.StringVar(value=str(self.cfg.local_port))
        self.remote_ip = tk.StringVar(value=self.cfg.remote_ip)
        self.remote_port = tk.StringVar(value=str(self.cfg.remote_port))
        self.conn_var = tk.StringVar(value="Disconnected")
        self._row_entry(net, "Local IP", self.local_ip, 0, width=16)
        self._row_entry(net, "Local Port", self.local_port, 1, width=16)
        self._row_entry(net, "FPGA IP", self.remote_ip, 2, width=16)
        self._row_entry(net, "FPGA Port", self.remote_port, 3, width=16)
        ttk.Label(net, textvariable=self.conn_var).grid(row=4, column=0, columnspan=3, sticky="w", padx=6, pady=4)
        ttk.Button(net, text="Connect UDP", command=self.on_connect).grid(row=5, column=0, columnspan=3, sticky="ew", padx=6, pady=(2, 3))
        ttk.Button(net, text="Disconnect UDP", command=self.on_disconnect).grid(row=6, column=0, columnspan=3, sticky="ew", padx=6, pady=(3, 6))
        net.columnconfigure(1, weight=1)

        ctrl = ttk.LabelFrame(udp_page, text="Acquisition / Trigger")
        ctrl.pack(fill=tk.X, padx=6, pady=(0, 6))
        labels, codes = sample_rate_options()
        self.sr_labels = list(labels)
        self.sr_codes = list(codes)
        self.rate_var = tk.StringVar(value="2MHz")
        ttk.Label(ctrl, text="ADC Sample Rate").grid(row=0, column=0, sticky="w", padx=6, pady=3)
        ttk.Combobox(ctrl, textvariable=self.rate_var, values=self.sr_labels, state="readonly", width=10).grid(row=0, column=1, sticky="w", padx=6)
        self.mask_var = tk.StringVar(value="000F")
        self._row_entry(ctrl, "Channel Mask", self.mask_var, 1, width=10)
        self.threshold_var = tk.StringVar(value="2000")
        self._row_entry(ctrl, "AE Threshold", self.threshold_var, 2, width=10)
        self.pulse_freq_var = tk.StringVar(value="1000")
        self._row_entry(ctrl, "Pulse Frequency \n (kHz)", self.pulse_freq_var, 3, width=10)
        self.pulse_gap_var = tk.StringVar(value="10000")
        self._row_entry(ctrl, "Pulse Gap (us)", self.pulse_gap_var, 4, width=10)
        self.pulse_count_var = tk.StringVar(value="1")
        self._row_entry(ctrl, "Pulse Count", self.pulse_count_var, 5, width=10)
        self.duty_var = tk.StringVar(value="50")
        self._row_entry(ctrl, "Duty Cycle (%)", self.duty_var, 6, width=10)
        self.rx_enable_var = tk.BooleanVar(value=True)
        self.tx_enable_var = tk.BooleanVar(value=False)
        self.time_sync_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(ctrl, text="Enable ADC RX", variable=self.rx_enable_var).grid(row=7, column=0, sticky="w", padx=6, pady=3)
        ttk.Checkbutton(ctrl, text="Enable Pulse TX", variable=self.tx_enable_var).grid(row=8, column=0, sticky="w", padx=6, pady=3)
        ttk.Checkbutton(ctrl, text="Time Sync", variable=self.time_sync_var).grid(row=9, column=0, sticky="w", padx=6, pady=3)
        ttk.Button(ctrl, text="Send Parameters", command=self.on_send_control).grid(row=10, column=0, columnspan=3, sticky="ew", padx=6, pady=6)

        # ------------------------------------------------------------------ Save page
        savef = ttk.LabelFrame(save_page, text="Target / Manual Save")
        savef.pack(fill=tk.X, padx=6, pady=(6, 6))
        self.target_x_var = tk.StringVar(value="0.250")
        self.target_y_var = tk.StringVar(value="0.200")
        self._row_entry(savef, "Actual X / m", self.target_x_var, 0, width=10)
        self._row_entry(savef, "Actual Y / m", self.target_y_var, 1, width=10)
        self.save_dir_var = tk.StringVar(value=str(Path.cwd() / "ae_saved_data"))
        ttk.Label(savef, text="Save Directory").grid(row=2, column=0, sticky="w", padx=6, pady=3)
        ttk.Entry(savef, textvariable=self.save_dir_var, width=18).grid(row=2, column=1, sticky="ew", padx=6, pady=3)
        ttk.Button(savef, text="Browse", command=self.on_browse_save_dir).grid(row=2, column=2, padx=6, pady=3)
        self.auto_save_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(savef, text="Auto-save after acquisition", variable=self.auto_save_var).grid(row=3, column=0, columnspan=3, sticky="w", padx=6, pady=3)
        ttk.Button(savef, text="Save Current Data", command=self.on_save_current_data).grid(row=4, column=0, columnspan=3, sticky="ew", padx=6, pady=4)
        ttk.Button(savef, text="Load Saved Data", command=self.on_load_saved_data).grid(row=5, column=0, columnspan=3, sticky="ew", padx=6, pady=4)
        self.save_channel_info_var = tk.StringVar(value="No event received: saved channels will be determined automatically by returned channel_mask")
        ttk.Label(savef, textvariable=self.save_channel_info_var, wraplength=self._scaled(310, minimum=230), foreground=COLOR_PRIMARY_DARK).grid(row=6, column=0, columnspan=3, sticky="w", padx=6, pady=(2, 4))
        savef.columnconfigure(1, weight=1)

        namef = ttk.LabelFrame(save_page, text="Sensor Channels / Names")
        namef.pack(fill=tk.BOTH, expand=True, padx=6, pady=(0, 6))
        ttk.Label(namef, text="Note: only channels enabled in the returned channel_mask are saved; CSV column names include channel numbers and sensor names.", wraplength=self._scaled(310, minimum=230)).grid(row=0, column=0, columnspan=4, sticky="w", padx=6, pady=(4, 4))
        self.sensor_name_vars: List[tk.StringVar] = []
        for i in range(16):
            r = 1 + (i % 8)
            c0 = 0 if i < 8 else 2
            ttk.Label(namef, text=f"CH{i + 1:02d}").grid(row=r, column=c0, sticky="w", padx=(6, 2), pady=2)
            nv = tk.StringVar(value=f"S{i + 1}")
            self.sensor_name_vars.append(nv)
            ttk.Entry(namef, textvariable=nv, width=9).grid(row=r, column=c0 + 1, sticky="w", padx=(2, 6), pady=2)
        for c in range(4):
            namef.columnconfigure(c, weight=1)

        # ------------------------------------------------------------------ Localization page
        locf = ttk.LabelFrame(loc_page, text="D1-AIC Localization Parameters")
        locf.pack(fill=tk.X, padx=6, pady=(6, 6))

        self.loc_source_var = tk.StringVar(value="Current Acquisition Data")
        self.loc_channel_count_var = tk.StringVar(value="4")
        self.loc_ref_ch_var = tk.StringVar(value="1")

        self.loc_voltage_divisor_var = tk.StringVar(value="8192")
        self.loc_remove_mean_var = tk.BooleanVar(value=True)
        self.loc_highpass_enable_var = tk.BooleanVar(value=False)
        self.loc_highpass_cutoff_hz_var = tk.StringVar(value="40000")
        self.loc_highpass_order_var = tk.StringVar(value="4")

        self.loc_divide_dt_var = tk.BooleanVar(value=False)
        self.loc_diff_smooth_pts_var = tk.StringVar(value="1")
        self.loc_detect_start_us_var = tk.StringVar(value="-200")
        self.loc_detect_end_us_var = tk.StringVar(value="400")
        self.loc_rms_baseline_us_var = tk.StringVar(value="60")
        self.loc_threshold_multiplier_var = tk.StringVar(value="10")
        self.loc_threshold_mode_var = tk.StringVar(value="per_channel")

        self.loc_aic_offset_start_us_var = tk.StringVar(value="-80")
        self.loc_aic_offset_end_us_var = tk.StringVar(value="100")
        self.loc_aic_smooth_pts_var = tk.StringVar(value="5")
        self.loc_aic_min_side_pts_var = tk.StringVar(value="10")

        self.loc_fft_pre_us_var = tk.StringVar(value="1")
        self.loc_fft_post_us_var = tk.StringVar(value="80")
        self.loc_fft_fmin_khz_var = tk.StringVar(value="80")
        self.loc_fft_fmax_khz_var = tk.StringVar(value="500")
        self.loc_fft_nfft_factor_var = tk.StringVar(value="4")

        self.loc_manual_velocity_enable_var = tk.BooleanVar(value=True)
        self.loc_manual_velocity_var = tk.StringVar(value="3150")
        self.loc_mode_var = tk.StringVar(value="A0")
        self.loc_velocity_type_var = tk.StringVar(value="group")
        self.loc_thickness_var = tk.StringVar(value="0.006")
        self.loc_young_gpa_var = tk.StringVar(value="70")
        self.loc_poisson_var = tk.StringVar(value="0.33")
        self.loc_density_var = tk.StringVar(value="2700")
        self.loc_grid_n_var = tk.StringVar(value="11")

        row = 0
        ttk.Label(locf, text="Data Source").grid(row=row, column=0, sticky="w", padx=6, pady=3)
        ttk.Combobox(locf, textvariable=self.loc_source_var, values=["Current Acquisition Data", "Loaded Saved Data"], state="readonly", width=17).grid(row=row, column=1, sticky="w", padx=6, pady=3)
        row += 1
        ttk.Label(locf, text="Channel Count").grid(row=row, column=0, sticky="w", padx=6, pady=3)
        ttk.Combobox(locf, textvariable=self.loc_channel_count_var, values=["4", "8", "12", "16"], state="readonly", width=8).grid(row=row, column=1, sticky="w", padx=6, pady=3)
        row += 1
        self._row_entry(locf, "Reference Channel", self.loc_ref_ch_var, row, width=8); row += 1
        self._row_entry(locf, "Voltage Divisor", self.loc_voltage_divisor_var, row, width=10); row += 1
        ttk.Checkbutton(locf, text="Remove DC Mean", variable=self.loc_remove_mean_var).grid(row=row, column=0, columnspan=2, sticky="w", padx=6, pady=3); row += 1
        ttk.Checkbutton(locf, text="Enable High-pass", variable=self.loc_highpass_enable_var).grid(row=row, column=0, columnspan=2, sticky="w", padx=6, pady=3); row += 1
        self._row_entry(locf, "High-pass Cutoff / Hz", self.loc_highpass_cutoff_hz_var, row, width=10); row += 1
        self._row_entry(locf, "High-pass Order", self.loc_highpass_order_var, row, width=8); row += 1
        self._row_entry(locf, "D1 Smooth Points", self.loc_diff_smooth_pts_var, row, width=8); row += 1
        ttk.Checkbutton(locf, text="D1 divide by dt", variable=self.loc_divide_dt_var).grid(row=row, column=0, columnspan=2, sticky="w", padx=6, pady=3); row += 1
        self._row_entry(locf, "Detect Start / us", self.loc_detect_start_us_var, row, width=8); row += 1
        self._row_entry(locf, "Detect End / us", self.loc_detect_end_us_var, row, width=8); row += 1
        self._row_entry(locf, "RMS Baseline / us", self.loc_rms_baseline_us_var, row, width=8); row += 1
        self._row_entry(locf, "Threshold Multiplier", self.loc_threshold_multiplier_var, row, width=8); row += 1
        ttk.Label(locf, text="Threshold Mode").grid(row=row, column=0, sticky="w", padx=6, pady=3)
        ttk.Combobox(locf, textvariable=self.loc_threshold_mode_var, values=["per_channel", "mean_all_channels", "max_all_channels"], state="readonly", width=17).grid(row=row, column=1, sticky="w", padx=6, pady=3)
        row += 1
        self._row_entry(locf, "AIC Start Offset / us", self.loc_aic_offset_start_us_var, row, width=8); row += 1
        self._row_entry(locf, "AIC End Offset / us", self.loc_aic_offset_end_us_var, row, width=8); row += 1
        self._row_entry(locf, "AIC Smooth Points", self.loc_aic_smooth_pts_var, row, width=8); row += 1
        self._row_entry(locf, "AIC Min-side Points", self.loc_aic_min_side_pts_var, row, width=8); row += 1
        self._row_entry(locf, "FFT Pre / us", self.loc_fft_pre_us_var, row, width=8); row += 1
        self._row_entry(locf, "FFT Post / us", self.loc_fft_post_us_var, row, width=8); row += 1
        self._row_entry(locf, "FFT Fmin / kHz", self.loc_fft_fmin_khz_var, row, width=8); row += 1
        self._row_entry(locf, "FFT Fmax / kHz", self.loc_fft_fmax_khz_var, row, width=8); row += 1
        self._row_entry(locf, "FFT NFFT Factor", self.loc_fft_nfft_factor_var, row, width=8); row += 1
        ttk.Checkbutton(locf, text="Use Manual Velocity", variable=self.loc_manual_velocity_enable_var).grid(row=row, column=0, columnspan=2, sticky="w", padx=6, pady=3); row += 1
        self._row_entry(locf, "Manual Velocity / m/s", self.loc_manual_velocity_var, row, width=10); row += 1
        ttk.Label(locf, text="Mode").grid(row=row, column=0, sticky="w", padx=6, pady=3)
        ttk.Combobox(locf, textvariable=self.loc_mode_var, values=["A0", "S0"], state="readonly", width=8).grid(row=row, column=1, sticky="w", padx=6, pady=3)
        row += 1
        ttk.Label(locf, text="Velocity Type").grid(row=row, column=0, sticky="w", padx=6, pady=3)
        ttk.Combobox(locf, textvariable=self.loc_velocity_type_var, values=["group", "phase"], state="readonly", width=8).grid(row=row, column=1, sticky="w", padx=6, pady=3)
        row += 1
        self._row_entry(locf, "Plate Thickness / m", self.loc_thickness_var, row, width=8); row += 1
        self._row_entry(locf, "Young Modulus / GPa", self.loc_young_gpa_var, row, width=8); row += 1
        self._row_entry(locf, "Poisson Ratio", self.loc_poisson_var, row, width=8); row += 1
        self._row_entry(locf, "Density / kg/m3", self.loc_density_var, row, width=8); row += 1
        self._row_entry(locf, "Localization Grid N", self.loc_grid_n_var, row, width=8); row += 1
        ttk.Button(locf, text="Run D1-AIC Localization", command=self.on_localize).grid(row=row, column=0, columnspan=3, sticky="ew", padx=6, pady=6)

        geom = ttk.LabelFrame(save_page, text="Sensor Coordinates / m")
        geom.pack(fill=tk.BOTH, expand=True, padx=2, pady=(0, 0))

        defaults16 = [(0.0, 0.0) for _ in range(16)]
        self.sensor_vars: List[Tuple[tk.StringVar, tk.StringVar]] = []
        ttk.Label(geom, text="Channel", width=8).grid(row=0, column=0, sticky="ew", padx=0, pady=0)
        ttk.Label(geom, text="X", width=2).grid(row=0, column=1, sticky="ew", padx=0, pady=0)
        ttk.Label(geom, text="Y", width=2).grid(row=0, column=2, sticky="ew", padx=0, pady=0)
        ttk.Label(geom, text="Channel", width=8).grid(row=0, column=3, sticky="ew", padx=0, pady=0)
        ttk.Label(geom, text="X", width=2).grid(row=0, column=4, sticky="ew", padx=0, pady=0)
        ttk.Label(geom, text="Y", width=2).grid(row=0, column=5, sticky="ew", padx=0, pady=0)
        for i, (x0, y0) in enumerate(defaults16, start=1):
            block = 0 if i <= 8 else 3
            r = i if i <= 8 else i - 8
            ttk.Label(geom, text=f"CH{i:02d}").grid(row=r, column=block, sticky="ew", padx=(0 if block == 0 else 0, 2), pady=0)
            xv = tk.StringVar(value=f"{x0:.3f}")
            yv = tk.StringVar(value=f"{y0:.3f}")
            self.sensor_vars.append((xv, yv))
            ttk.Entry(geom, textvariable=xv, width=4).grid(row=r, column=block + 1, padx=0, pady=0)
            ttk.Entry(geom, textvariable=yv, width=4).grid(row=r, column=block + 2, padx=0, pady=0)
        self.plate_x_var = tk.StringVar(value="0.500")
        self.plate_y_var = tk.StringVar(value="0.500")
        self._row_entry(geom, "Plate Length X", self.plate_x_var, 9, width=8)
        self._row_entry(geom, "Plate Width Y", self.plate_y_var, 10, width=8)
        note = ttk.LabelFrame(loc_page, text="Notes")
        note.pack(fill=tk.X, padx=6, pady=(0, 6))
        ttk.Label(
            note,
            text="Localization can use 4/8/12/16 channels; the first N active channels from the returned channel_mask are used.\n"
                 "The localization channel count cannot exceed the number of active sampled/returned channels; sensor coordinates are set on the Data Saving page and written to JSON with saved data.\n"
                 "AIC pre/post windows are in microseconds and anchored at the FPGA threshold trigger point; the real first arrival can occur before the trigger point.",
            justify=tk.LEFT,
            wraplength=self._scaled(310, minimum=230),
        ).pack(fill=tk.X, expand=True, padx=6, pady=6)

        # ------------------------------------------------------------------ Run controls: placed below the UDP parameter page
        cmd = ttk.LabelFrame(udp_page, text="Runtime Commands")
        cmd.pack(fill=tk.X, padx=6, pady=(0, 6))
        ttk.Button(cmd, text="One-click Acquisition", command=self.on_round_trip).grid(row=0, column=0, padx=4, pady=4, sticky="ew")
        ttk.Button(cmd, text="Refresh Plot", command=self.on_plot).grid(row=1, column=0, padx=4, pady=4, sticky="ew")
        ttk.Button(cmd, text="Clear Log", command=self.on_clear_log).grid(row=2, column=0, padx=4, pady=4, sticky="ew")
        cmd.columnconfigure(0, weight=1)


    def _build_right_output(self, parent: ttk.Frame) -> None:
        """Right-side output/display panels kept in the original style.

        The content is scrollable, so small-height screens do not hide the
        lower summary panels.
        """
        container, inner = self._make_scrollable_container(parent)
        container.pack(fill=tk.BOTH, expand=True)
        self.event_text = self._make_info_box(inner, "Event Frame Info", 11)
        self.packet_text = self._make_info_box(inner, "Packet Info", 9)
        self.save_text = self._make_info_box(inner, "Save Info", 6)
        self.loc_text = self._make_info_box(inner, "Localization Summary", 16)


    def _build_param_pages(self, parent: ttk.Frame) -> None:
        # Backward-compatible alias. New layout calls _build_left_param_pages().
        self._build_left_param_pages(parent)


    def _build_log_bottom(self, parent: ttk.Frame) -> None:
        logf = ttk.LabelFrame(parent, text="Run Log")
        logf.pack(fill=tk.X, expand=False, pady=(6, 0))
        self.log_list = tk.Listbox(logf, height=max(4, self._scaled(7)), font=(FONT_MONO, self._fs(FONT_UI_SIZE)), bg=COLOR_WHITE, fg=COLOR_TEXT, selectbackground=COLOR_ACCENT, selectforeground=COLOR_WHITE, relief=tk.FLAT)
        self.log_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(4, 0), pady=4)
        scroll = ttk.Scrollbar(logf, orient=tk.VERTICAL, command=self.log_list.yview)
        scroll.pack(side=tk.RIGHT, fill=tk.Y, pady=4)
        self.log_list.configure(yscrollcommand=scroll.set)


    def _build_center(self, parent: ttk.Frame) -> None:
        self.notebook = ttk.Notebook(parent)
        self.notebook.pack(fill=tk.BOTH, expand=True)

        wave_tab = ttk.Frame(self.notebook)
        loc_tab = ttk.Frame(self.notebook)
        self.notebook.add(wave_tab, text="AE Waveform")
        self.notebook.add(loc_tab, text="Localization Result")

        wave_top = ttk.Frame(wave_tab)
        wave_top.pack(fill=tk.X, padx=4, pady=4)
        ttk.Label(wave_top, text="Y-Axis Mode").pack(side=tk.LEFT, padx=(0, 4))
        self.y_mode_var = tk.StringVar(value="Fixed 16-bit Code Range")
        cb = ttk.Combobox(
            wave_top,
            textvariable=self.y_mode_var,
            values=["Fixed 16-bit Code Range", "ADC Differential Voltage / V"],
            state="readonly",
            width=20,
        )
        cb.pack(side=tk.LEFT)
        cb.bind("<<ComboboxSelected>>", lambda _e: self.on_plot())
        ttk.Label(wave_top, text="   Waveform display: CH1-CH16; localization uses Dynamic D1-AIC TOA picking", font=(FONT_CN, self._fs(FONT_UI_SIZE)), foreground=COLOR_PRIMARY_DARK).pack(side=tk.LEFT, padx=self._scaled(10))

        self.fig_wave = Figure(figsize=self._figure_size(12, 8), dpi=100, facecolor=COLOR_BG)
        self.axes_wave = [self.fig_wave.add_subplot(4, 4, i + 1) for i in range(16)]
        self._style_figure(self.fig_wave)
        self.fig_wave.tight_layout(pad=0.9)
        self.canvas_wave = FigureCanvasTkAgg(self.fig_wave, master=wave_tab)
        self.canvas_wave.get_tk_widget().pack(fill=tk.BOTH, expand=True)
        self._bind_responsive_figure(self.fig_wave, self.canvas_wave, pad=0.85)

        # Localization result page: all panels are placed in this single tab,
        # not inside secondary sub-tabs.
        loc_vertical = ttk.PanedWindow(loc_tab, orient=tk.VERTICAL)
        loc_vertical.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

        top_row = ttk.PanedWindow(loc_vertical, orient=tk.HORIZONTAL)
        mid_row = ttk.PanedWindow(loc_vertical, orient=tk.HORIZONTAL)
        bottom_row = ttk.Frame(loc_vertical)
        loc_vertical.add(top_row, weight=4)
        loc_vertical.add(mid_row, weight=3)
        loc_vertical.add(bottom_row, weight=3)

        loc_map_frame = ttk.LabelFrame(top_row, text="Localization Map")
        ref_frame = ttk.LabelFrame(top_row, text="D1-AIC Arrival-Time Annotation by Channel")
        top_row.add(loc_map_frame, weight=1)
        top_row.add(ref_frame, weight=1)

        self.fig_loc = Figure(figsize=self._figure_size(6.2, 4.2), dpi=100, facecolor=COLOR_BG)
        self.ax_loc = self.fig_loc.add_subplot(1, 1, 1)
        self._style_figure(self.fig_loc)
        self.canvas_loc = FigureCanvasTkAgg(self.fig_loc, master=loc_map_frame)
        self.canvas_loc.get_tk_widget().pack(fill=tk.BOTH, expand=True)
        self._bind_responsive_figure(self.fig_loc, self.canvas_loc, pad=1.0)

        self.fig_ref = Figure(figsize=self._figure_size(7.2, 5.0), dpi=100, facecolor=COLOR_BG)
        # AIC panel: in the current 4-channel localization workflow, place
        # channel plots vertically so the AIC arrival order is easy to compare.
        self.axes_aic = [self.fig_ref.add_subplot(4, 1, i + 1) for i in range(4)]
        self._style_figure(self.fig_ref)
        self.canvas_ref = FigureCanvasTkAgg(self.fig_ref, master=ref_frame)
        self.canvas_ref.get_tk_widget().pack(fill=tk.BOTH, expand=True)
        self._bind_responsive_figure(self.fig_ref, self.canvas_ref, pad=0.55, rect=[0.0, 0.0, 1.0, 0.955])

        energy_fig_frame = ttk.LabelFrame(mid_row, text="Summed FFT Spectrum Around D1-AIC Arrivals")
        energy_table_frame = ttk.LabelFrame(mid_row, text="D1-AIC Arrival Table")
        mid_row.add(energy_fig_frame, weight=1)
        mid_row.add(energy_table_frame, weight=1)

        self.fig_energy = Figure(figsize=self._figure_size(6.2, 3.2), dpi=100, facecolor=COLOR_BG)
        self.ax_energy = self.fig_energy.add_subplot(1, 1, 1)
        self._style_figure(self.fig_energy)
        self.canvas_energy = FigureCanvasTkAgg(self.fig_energy, master=energy_fig_frame)
        self.canvas_energy.get_tk_widget().pack(fill=tk.BOTH, expand=True)
        self._bind_responsive_figure(self.fig_energy, self.canvas_energy, pad=0.9)

        energy_cols = ("Channel", "Threshold_us", "Arrival_us", "TDOA_us", "Threshold", "BaselineRMS", "AICmin")
        self.energy_tree = self._make_treeview_with_scrollbars(energy_table_frame, energy_cols, height=8, column_width=88)

        band_table_frame = ttk.LabelFrame(bottom_row, text="TOA Localization Residuals")
        band_table_frame.pack(fill=tk.BOTH, expand=True)
        band_cols = ("Channel", "Arrival_us", "Residual_us", "Sensor_X", "Sensor_Y", "Used", "Method", "Note", " ")
        self.band_tree = self._make_treeview_with_scrollbars(band_table_frame, band_cols, height=9, column_width=88)


    def _build_right(self, parent: ttk.Frame) -> None:
        # Backward-compatible alias. New layout uses _build_right_output().
        self._build_right_output(parent)


    def _make_info_box(self, parent: ttk.Frame, title: str, height: int) -> tk.Text:
        f = ttk.LabelFrame(parent, text=title)
        f.pack(fill=tk.BOTH, expand=False, pady=(0, self._scaled(6)))
        txt = tk.Text(
            f,
            height=max(4, self._scaled(height)),
            width=max(34, self._scaled(48)),
            font=(FONT_MONO, self._fs(FONT_UI_SIZE)),
            wrap=tk.NONE,
            bg=COLOR_WHITE,
            fg=COLOR_TEXT,
            insertbackground=COLOR_PRIMARY_DARK,
            relief=tk.FLAT,
        )
        txt.pack(fill=tk.BOTH, expand=True, padx=self._scaled(4), pady=self._scaled(4))
        txt.insert("1.0", "No data.")
        txt.configure(state=tk.DISABLED)
        return txt

    def _row_entry(self, parent: ttk.Frame, label: str, var: tk.StringVar, row: int, width: int = 12) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=self._scaled(6), pady=self._scaled(3))
        ttk.Entry(parent, textvariable=var, width=width).grid(row=row, column=1, sticky="ew", padx=self._scaled(6), pady=self._scaled(3))
        try:
            parent.columnconfigure(1, weight=1)
        except Exception:
            pass

    # --------------------------------------------------------------- config
    def read_cfg(self) -> AEConfig:
        cfg = default_config()
        cfg.local_ip = self.local_ip.get().strip()
        cfg.local_port = int(self.local_port.get())
        cfg.remote_ip = self.remote_ip.get().strip()
        cfg.remote_port = int(self.remote_port.get())
        cfg.control = self.read_ctrl()
        return cfg

    def read_ctrl(self) -> ControlConfig:
        label = self.rate_var.get()
        code = self.sr_codes[self.sr_labels.index(label)] if label in self.sr_labels else 4
        mask_text = self.mask_var.get().strip()
        mask = int(mask_text, 16) if not mask_text.lower().startswith("0x") else int(mask_text, 16)
        return ControlConfig(
            pulse_freq_khz=int(self.pulse_freq_var.get()),
            pulse_count=int(self.pulse_count_var.get()),
            duty_pct=int(self.duty_var.get()),
            pulse_gap_us=int(self.pulse_gap_var.get()),
            pulse_channel_enable4=15,
            sample_rate_code=int(code),
            sample_rate_label=label,
            sample_mask=mask,
            time_sync_enable=bool(self.time_sync_var.get()),
            timestamp=datetime.now(),
            tx_enable=bool(self.tx_enable_var.get()),
            rx_enable=bool(self.rx_enable_var.get()),
            req_upload=False,
            ae_threshold=int(self.threshold_var.get()),
        )

    def read_sensor_xy(self) -> np.ndarray:
        """Return all configured physical sensor coordinates, CH1~CH16."""
        vals = []
        for xv, yv in self.sensor_vars:
            vals.append([safe_float(xv.get()), safe_float(yv.get())])
        return np.asarray(vals, dtype=float)

    def read_sensor_names(self) -> List[str]:
        names = []
        for i in range(16):
            if hasattr(self, "sensor_name_vars") and i < len(self.sensor_name_vars):
                name = self.sensor_name_vars[i].get().strip()
            else:
                name = ""
            names.append(name if name else f"S{i + 1}")
        return names

    def read_target_xy(self) -> np.ndarray:
        return np.array([safe_float(self.target_x_var.get()), safe_float(self.target_y_var.get())], dtype=float)

    @staticmethod
    def _mask_to_active_indices(mask: int) -> List[int]:
        return [i for i in range(16) if (int(mask) >> i) & 0x1]

    def get_event_active_indices(self, event: AEEvent) -> List[int]:
        """Return 0-based active channel indices according to FPGA returned channel mask.

        The saved/located channel set must follow the event returned by FPGA, not
        only the GUI input mask.  If the header mask is invalid, fall back to the
        SNSR mask and then to non-zero columns.
        """
        mask = 0
        try:
            mask = int(event.frame.hdr0.get("channel_mask", 0)) & 0xFFFF
        except Exception:
            mask = 0
        if mask == 0:
            try:
                mask = int(event.sensor.channel_mask) & 0xFFFF
            except Exception:
                mask = 0
        idx = self._mask_to_active_indices(mask)
        if not idx:
            samples = np.asarray(event.samples_full_i16)
            idx = [i for i in range(min(16, samples.shape[1])) if np.any(samples[:, i] != 0)]
        if not idx:
            idx = list(range(min(16, int(event.channel_count))))
        return idx

    @staticmethod
    def channel_list_text(indices: List[int]) -> str:
        return ",".join(f"CH{i + 1}" for i in indices) if indices else "none"

    def ensure_client(self, cfg: Optional[AEConfig] = None) -> AEUdpClient:
        if cfg is None:
            cfg = self.read_cfg()
        if self.client is None:
            self.client = AEUdpClient(cfg)
            self.client.open()
        elif not self.client.is_open:
            self.client.cfg = cfg
            self.client.open()
        else:
            self.client.cfg = cfg
        self.conn_var.set(f"Connected {cfg.local_ip}:{cfg.local_port}")
        return self.client

    # --------------------------------------------------------------- commands
    def on_connect(self) -> None:
        try:
            cfg = self.read_cfg()
            self.ensure_client(cfg)
            self._log(f"UDP ready: {cfg.local_ip}:{cfg.local_port} -> {cfg.remote_ip}:{cfg.remote_port}")
        except Exception as exc:
            self._log_error("UDP setup failed", exc)

    def on_disconnect(self) -> None:
        if self.client is not None:
            self.client.close()
        self.conn_var.set("Disconnected")
        self._log("UDP closed.")

    def on_send_control(self) -> None:
        try:
            cfg = self.read_cfg()
            client = self.ensure_client(cfg)
            pkt = client.send_control(cfg.control)
            self._log(f"USND sent: rate={cfg.control.sample_rate_label} code={cfg.control.sample_rate_code} threshold={cfg.control.ae_threshold} bytes={len(pkt)}")
        except Exception as exc:
            self._log_error("Send control failed", exc)

    def on_request_upload(self) -> None:
        try:
            cfg = self.read_cfg()
            self.ensure_client(cfg)
        except Exception as exc:
            self._log_error("UDP setup failed", exc)
            return
        self._start_worker(lambda: self._worker_request_receive(cfg), "Receive already running.")

    def on_receive_event(self) -> None:
        try:
            cfg = self.read_cfg()
            self.ensure_client(cfg)
        except Exception as exc:
            self._log_error("UDP setup failed", exc)
            return
        self._start_worker(lambda: self._worker_receive_only(cfg), "Receive already running.")

    def on_round_trip(self) -> None:
        try:
            cfg = self.read_cfg()
            self.ensure_client(cfg)
        except Exception as exc:
            self._log_error("UDP setup failed", exc)
            return
        self._start_worker(lambda: self._worker_round_trip(cfg), "Round trip already running.")

    def on_plot(self) -> None:
        if self.last_event is None:
            return
        self._plot_event(self.last_event)

    def on_browse_save_dir(self) -> None:
        d = filedialog.askdirectory(initialdir=self.save_dir_var.get() or str(Path.cwd()))
        if d:
            self.save_dir_var.set(d)

    def on_load_saved_data(self) -> None:
        path = filedialog.askopenfilename(
            initialdir=self.save_dir_var.get() or str(Path.cwd()),
            title="Select Saved AE Data CSV",
            filetypes=[("AE CSV", "*.csv"), ("All files", "*.*")],
        )
        if not path:
            return
        try:
            data = self.load_saved_dataset(Path(path))
            self.loaded_saved_data = data
            # Saved data is now the intended source for localization.
            self.loc_source_var.set("Loaded Saved Data")
            self._apply_saved_metadata_to_ui(data)
            active_idx = data.get("active_channel_indices", [])
            self.save_channel_info_var.set(
                f"Loaded saved data: {Path(path).name}; active channel count: {len(active_idx)}; active channels: {self.channel_list_text(active_idx)}"
            )
            self._set_text(
                self.save_text,
                f"Loaded CSV: {path}\n"
                f"Loaded JSON: {data.get('json_path', 'none')}\n"
                f"channels: {self.channel_list_text(active_idx)}\n"
                f"samples: {data['samples_full_i16'].shape[0]} x {len(active_idx)}",
            )
            self._log(f"Loaded saved AE data for localization: {path}")
        except Exception as exc:
            self._log_error("Load saved data failed", exc)

    def on_save_current_data(self) -> None:
        if self.last_event is None:
            self._log("No cached event to save.")
            return
        try:
            path = self.save_current_data(self.last_event)
            self._log(f"Saved current active-channel AE data: {path}")
        except Exception as exc:
            self._log_error("Save current data failed", exc)

    def on_localize(self) -> None:
        if self.loc_source_var.get() == "Loaded Saved Data":
            if self.loaded_saved_data is None:
                self._log("No saved AE data loaded. Please load a saved CSV first.")
                return
        else:
            if self.last_event is None:
                self._log("No cached AE event. Please acquire an event first.")
                return
        self._start_worker(self._worker_localize, "Localization/acquisition already running.")

    def on_clear_log(self) -> None:
        self.log_lines = []
        self.log_list.delete(0, tk.END)

    def _start_worker(self, target, busy_message: str) -> None:
        if self.is_busy:
            self._log(busy_message)
            return
        self.is_busy = True
        threading.Thread(target=target, daemon=True).start()

    # --------------------------------------------------------------- workers
    def _worker_request_receive(self, cfg: AEConfig) -> None:
        try:
            client = self.client
            if client is None or not client.is_open:
                raise RuntimeError("UDP client is not connected.")
            client.cfg = cfg
            self.ui_queue.put(("log", "Upload request sent. Receiving silently..."))
            event, stats = client.request_and_receive_event(
                cfg.control,
                timeout_s=cfg.timeout_s,
                expected_samples=cfg.frame_samples,
                expected_channels=16,
                idle_gap_s=0.20,
            )
            self.ui_queue.put(("event", event, stats))
        except Exception as exc:
            self.ui_queue.put(("error", "Upload/receive failed", exc, traceback.format_exc()))
        finally:
            self.ui_queue.put(("done",))

    def _worker_receive_only(self, cfg: AEConfig) -> None:
        try:
            client = self.client
            if client is None or not client.is_open:
                raise RuntimeError("UDP client is not connected.")
            client.cfg = cfg
            self.ui_queue.put(("log", "Receiving silently..."))
            event, stats = client.receive_event(
                timeout_s=cfg.timeout_s,
                expected_samples=cfg.frame_samples,
                expected_channels=16,
                strict_frame_size=True,
                idle_gap_s=0.20,
            )
            self.ui_queue.put(("event", event, stats))
        except Exception as exc:
            self.ui_queue.put(("error", "Receive failed", exc, traceback.format_exc()))
        finally:
            self.ui_queue.put(("done",))

    def _worker_round_trip(self, cfg: AEConfig) -> None:
        try:
            client = self.client
            if client is None or not client.is_open:
                raise RuntimeError("UDP client is not connected.")
            client.cfg = cfg
            pkt = client.send_control(cfg.control)
            self.ui_queue.put(("log", f"USND sent, bytes={len(pkt)}. Requesting upload..."))
            time.sleep(0.05)
            event, stats = client.request_and_receive_event(
                cfg.control,
                timeout_s=cfg.timeout_s,
                expected_samples=cfg.frame_samples,
                expected_channels=16,
                idle_gap_s=0.20,
            )
            self.ui_queue.put(("event", event, stats))
        except Exception as exc:
            self.ui_queue.put(("error", "Round trip failed", exc, traceback.format_exc()))
        finally:
            self.ui_queue.put(("done",))

    def _worker_localize(self) -> None:
        try:
            self.ui_queue.put(("log", "Localization started. This may take several seconds..."))
            if self.loc_source_var.get() == "Loaded Saved Data":
                if self.loaded_saved_data is None:
                    raise RuntimeError("No saved AE data loaded.")
                out = self.run_localization_saved(self.loaded_saved_data)
            else:
                event = self.last_event
                if event is None:
                    raise RuntimeError("No cached AE event.")
                out = self.run_localization(event)
            self.ui_queue.put(("loc", out))
        except Exception as exc:
            self.ui_queue.put(("error", "Localization failed", exc, traceback.format_exc()))
        finally:
            self.ui_queue.put(("done",))

    # --------------------------------------------------------------- saved-data loading
    @staticmethod
    def _parse_channel_from_header(header: str, fallback_index: int) -> int:
        m = re.search(r"CH\s*0*([1-9][0-9]?)", str(header), flags=re.IGNORECASE)
        if m:
            ch = int(m.group(1))
            if 1 <= ch <= 16:
                return ch - 1
        return fallback_index

    def load_saved_dataset(self, csv_path: Path) -> Dict[str, object]:
        csv_path = Path(csv_path).expanduser()
        if not csv_path.exists():
            raise FileNotFoundError(str(csv_path))
        json_path = csv_path.with_suffix(".json")
        meta: Dict[str, object] = {}
        if json_path.exists():
            try:
                meta = json.loads(json_path.read_text(encoding="utf-8"))
            except Exception:
                meta = {}

        with csv_path.open("r", newline="", encoding="utf-8-sig") as f:
            reader = csv.reader(f)
            header = next(reader)
            rows = []
            for row in reader:
                if not row:
                    continue
                rows.append(row)
        if not rows:
            raise ValueError("CSV file contains no data rows.")
        if len(header) < 3:
            raise ValueError("CSV header must contain sample_index,time_us and at least one channel column.")

        channel_headers = header[2:]
        active_idx = [self._parse_channel_from_header(h, i) for i, h in enumerate(channel_headers)]
        if len(set(active_idx)) != len(active_idx):
            # Fall back to JSON saved channel labels when header parsing is ambiguous.
            saved_channels = meta.get("saved_channels", []) if isinstance(meta, dict) else []
            parsed = []
            for i, ch in enumerate(saved_channels):
                parsed.append(self._parse_channel_from_header(str(ch), i))
            if len(parsed) == len(active_idx) and len(set(parsed)) == len(parsed):
                active_idx = parsed

        n = len(rows)
        samples_full = np.zeros((n, 16), dtype=np.int16)
        time_us = np.zeros(n, dtype=float)
        for r, row in enumerate(rows):
            if len(row) >= 2:
                time_us[r] = safe_float(row[1], float(r))
            for c, ch_idx in enumerate(active_idx):
                col = 2 + c
                if col < len(row) and 0 <= ch_idx < 16:
                    samples_full[r, ch_idx] = int(round(safe_float(row[col], 0.0)))

        # Apply metadata to GUI so the saved file can be calculated exactly with
        # the sensor coordinates and target coordinates stored with it.
        return {
            "csv_path": str(csv_path),
            "json_path": str(json_path) if json_path.exists() else "",
            "meta": meta,
            "samples_full_i16": samples_full,
            "time_us": time_us,
            "active_channel_indices": active_idx,
            "sample_rate_hz": float(meta.get("sample_rate_hz", 0.0) or 0.0) if isinstance(meta, dict) else 0.0,
            "target_xy": np.asarray(meta.get("target_xy_m", self.read_target_xy()), dtype=float) if isinstance(meta, dict) else self.read_target_xy(),
            "sensor_xy_all": np.asarray(meta.get("sensor_xy_m_all_ch1_to_ch16", self.read_sensor_xy()), dtype=float) if isinstance(meta, dict) else self.read_sensor_xy(),
            "sensor_names": list(meta.get("sensor_names_all_ch1_to_ch16", self.read_sensor_names())) if isinstance(meta, dict) and "sensor_names_all_ch1_to_ch16" in meta else self.read_sensor_names(),
            "event_seq": int(meta.get("event_seq", -1) or -1) if isinstance(meta, dict) else -1,
            "trigger_offset": int(meta.get("trigger_offset", n // 4) or (n // 4)) if isinstance(meta, dict) else (n // 4),
        }

    def _apply_saved_metadata_to_ui(self, data: Dict[str, object]) -> None:
        target = np.asarray(data.get("target_xy", self.read_target_xy()), dtype=float).ravel()
        if target.size >= 2 and np.all(np.isfinite(target[:2])):
            self.target_x_var.set(f"{float(target[0]):.6g}")
            self.target_y_var.set(f"{float(target[1]):.6g}")
        xy = np.asarray(data.get("sensor_xy_all", self.read_sensor_xy()), dtype=float)
        if xy.shape == (16, 2):
            for i, (xv, yv) in enumerate(self.sensor_vars):
                xv.set(f"{float(xy[i,0]):.6g}")
                yv.set(f"{float(xy[i,1]):.6g}")

    # --------------------------------------------------------------- saving
    def save_current_data(self, event: AEEvent) -> Path:
        active_idx = self.get_event_active_indices(event)
        if not active_idx:
            raise RuntimeError("Current event has no active channels to save.")
        samples = np.asarray(event.samples_full_i16[:, active_idx], dtype=np.int16)
        n_ch = int(samples.shape[1])
        tx, ty = self.read_target_xy()
        base = f"{n_ch}channel_{fmt_coord_for_filename(tx)}_{fmt_coord_for_filename(ty)}"
        out_dir = Path(self.save_dir_var.get()).expanduser()
        out_dir.mkdir(parents=True, exist_ok=True)
        csv_path = unique_path(out_dir / f"{base}.csv")

        names = self.read_sensor_names()
        channel_labels = [f"CH{i + 1:02d}" for i in active_idx]
        sensor_names = [names[i] for i in active_idx]
        col_names = [f"{ch}_{name}" for ch, name in zip(channel_labels, sensor_names)]

        if event.frame.time_us.size == samples.shape[0]:
            time_us = event.frame.time_us
        else:
            time_us = np.arange(samples.shape[0], dtype=float)

        with csv_path.open("w", newline="", encoding="utf-8-sig") as f:
            writer = csv.writer(f)
            writer.writerow(["sample_index", "time_us"] + col_names)
            for i in range(samples.shape[0]):
                writer.writerow([i, f"{float(time_us[i]):.9g}"] + [int(v) for v in samples[i, :]])

        mask = int(event.frame.hdr0.get("channel_mask", 0)) & 0xFFFF
        meta = {
            "file": csv_path.name,
            "created_at": datetime.now().isoformat(timespec="seconds"),
            "format": "sample_index,time_us," + ",".join(col_names),
            "filename_rule": "Nchannel_x_y.csv",
            "channel_count": n_ch,
            "channel_mask_hex": f"0x{mask:04X}",
            "saved_channels": channel_labels,
            "sensor_names": sensor_names,
            "sensor_names_all_ch1_to_ch16": names,
            "target_xy_m": [float(tx), float(ty)],
            "sensor_xy_m_all_ch1_to_ch16": self.read_sensor_xy().tolist(),
            "sensor_xy_m_saved_channels": self.read_sensor_xy()[active_idx, :].tolist(),
            "event_seq": int(event.event_seq),
            "sample_rate_hz": float(event.frame.sample_rate_hz),
            "frame_samples": int(event.frame.frame_samples),
            "pre_samples": int(event.frame.pre_samples),
            "post_samples": int(event.frame.post_samples),
            "trigger_offset": int(event.frame.trigger_offset),
            "event_payload_total_bytes": int(event.event_payload_total_bytes),
        }
        json_path = csv_path.with_suffix(".json")
        json_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
        self._set_text(
            self.save_text,
            f"CSV: {csv_path}\nJSON: {json_path}\n"
            f"saved_channels: {self.channel_list_text(active_idx)}\n"
            f"sensor_names: {', '.join(sensor_names)}\n"
            f"filename rule: {n_ch}channel_x_y",
        )
        return csv_path

    # --------------------------------------------------------------- localization
    def make_loc_params(self, fs: float, selected_channel_indices: List[int], sensor_xy_all: Optional[np.ndarray] = None) -> D1AICLocalizationParams:
        if len(selected_channel_indices) < 3:
            raise ValueError("D1-AIC localization requires at least 3 channels.")
        all_xy = np.asarray(sensor_xy_all, dtype=float) if sensor_xy_all is not None else self.read_sensor_xy()
        sensor_xy = all_xy[selected_channel_indices, :]
        plate_xy = np.array([safe_float(self.plate_x_var.get(), 0.5), safe_float(self.plate_y_var.get(), 0.5)], dtype=float)

        mode = self.loc_mode_var.get().strip().upper() or "A0"
        if mode not in {"A0", "S0"}:
            mode = "A0"

        d1opt = D1AICOptions(
            voltage_divisor=safe_float(self.loc_voltage_divisor_var.get(), 8192.0),
            remove_mean=bool(self.loc_remove_mean_var.get()),
            highpass_enabled=bool(self.loc_highpass_enable_var.get()),
            highpass_cutoff_hz=safe_float(self.loc_highpass_cutoff_hz_var.get(), 40000.0),
            highpass_order=max(1, safe_int(self.loc_highpass_order_var.get(), 4)),
            divide_diff_by_dt=bool(self.loc_divide_dt_var.get()),
            diff_smooth_pts=max(1, safe_int(self.loc_diff_smooth_pts_var.get(), 1)),
            threshold_detect_start_us=safe_float(self.loc_detect_start_us_var.get(), -200.0),
            threshold_detect_end_us=safe_float(self.loc_detect_end_us_var.get(), 400.0),
            rms_baseline_duration_us=safe_float(self.loc_rms_baseline_us_var.get(), 60.0),
            threshold_multiplier=safe_float(self.loc_threshold_multiplier_var.get(), 10.0),
            threshold_mode=self.loc_threshold_mode_var.get().strip() or "per_channel",
            aic_offset_start_us=safe_float(self.loc_aic_offset_start_us_var.get(), -80.0),
            aic_offset_end_us=safe_float(self.loc_aic_offset_end_us_var.get(), 100.0),
            aic_smooth_pts=max(1, safe_int(self.loc_aic_smooth_pts_var.get(), 5)),
            aic_min_side_pts=max(2, safe_int(self.loc_aic_min_side_pts_var.get(), 10)),
            fft_pre_us=safe_float(self.loc_fft_pre_us_var.get(), 1.0),
            fft_post_us=safe_float(self.loc_fft_post_us_var.get(), 80.0),
            fft_fmin_hz=safe_float(self.loc_fft_fmin_khz_var.get(), 80.0) * 1e3,
            fft_fmax_hz=safe_float(self.loc_fft_fmax_khz_var.get(), 500.0) * 1e3,
            fft_nfft_factor=max(1, safe_int(self.loc_fft_nfft_factor_var.get(), 4)),
            manual_velocity_enable=bool(self.loc_manual_velocity_enable_var.get()),
            manual_velocity_m_s=safe_float(self.loc_manual_velocity_var.get(), 3150.0),
            lamb_mode=mode,
            velocity_type=self.loc_velocity_type_var.get().strip() or "group",
            loc_grid_n=max(3, safe_int(self.loc_grid_n_var.get(), 11)),
        )
        mat = MaterialParams(
            E=safe_float(self.loc_young_gpa_var.get(), 70.0) * 1e9,
            nu=safe_float(self.loc_poisson_var.get(), 0.33),
            rho=safe_float(self.loc_density_var.get(), 2700.0),
            thickness_m=safe_float(self.loc_thickness_var.get(), 0.006),
        )
        return D1AICLocalizationParams(
            fs=float(fs),
            sensor_xy=sensor_xy,
            plate_xy=plate_xy,
            material=mat,
            d1aic=d1opt,
        )


    def run_localization(self, event: AEEvent) -> Dict[str, object]:
        active_idx = self.get_event_active_indices(event)
        n_active = len(active_idx)
        loc_n = safe_int(self.loc_channel_count_var.get(), 4)
        if loc_n not in (4, 8, 12, 16):
            loc_n = 4
        if loc_n > n_active:
            raise ValueError(
                f"Localization channel count {loc_n} cannot exceed the current number of active returned channels {n_active}."
                f" Current active channels: {self.channel_list_text(active_idx)}."
            )
        selected_idx = active_idx[:loc_n]
        samples = np.asarray(event.samples_full_i16[:, selected_idx], dtype=float)
        fs = float(event.frame.sample_rate_hz)
        if not math.isfinite(fs) or fs <= 0:
            label = self.rate_var.get()
            code = self.sr_codes[self.sr_labels.index(label)] if label in self.sr_labels else 4
            fs = 40e6 / float(code)
        params = self.make_loc_params(fs, selected_idx)
        trigger_index = int(event.frame.trigger_offset)
        names = self.read_sensor_names()
        t0 = time.perf_counter()
        out = d1_aic_localize(
            samples,
            fs,
            params,
            trigger_index=trigger_index,
            target_xy=self.read_target_xy(),
            channel_labels=[f"CH{i + 1}" for i in selected_idx],
            sensor_names=[names[i] for i in selected_idx],
        )
        out.update({
            "elapsed_s": time.perf_counter() - t0,
            "event_seq": int(event.event_seq),
            "active_channel_indices": active_idx,
            "selected_channel_indices": selected_idx,
            "selected_channel_labels": [f"CH{i + 1}" for i in selected_idx],
            "selected_sensor_names": [names[i] for i in selected_idx],
            "ref_global_channel": selected_idx[0] + 1,
        })
        return out


    def run_localization_saved(self, data: Dict[str, object]) -> Dict[str, object]:
        active_idx = list(data.get("active_channel_indices", []))
        n_active = len(active_idx)
        loc_n = safe_int(self.loc_channel_count_var.get(), 4)
        if loc_n not in (4, 8, 12, 16):
            loc_n = 4
        if loc_n > n_active:
            raise ValueError(
                f"Localization channel count {loc_n} cannot exceed the number of active channels in the loaded data {n_active}."
                f" Current active channels: {self.channel_list_text(active_idx)}."
            )
        selected_idx = active_idx[:loc_n]
        samples_full = np.asarray(data["samples_full_i16"], dtype=np.int16)
        samples = np.asarray(samples_full[:, selected_idx], dtype=float)
        fs = float(data.get("sample_rate_hz", 0.0) or 0.0)
        if not math.isfinite(fs) or fs <= 0:
            label = self.rate_var.get()
            code = self.sr_codes[self.sr_labels.index(label)] if label in self.sr_labels else 4
            fs = 40e6 / float(code)
        sensor_xy_all = np.asarray(data.get("sensor_xy_all", self.read_sensor_xy()), dtype=float)
        target_xy = np.asarray(data.get("target_xy", self.read_target_xy()), dtype=float)
        params = self.make_loc_params(fs, selected_idx, sensor_xy_all=sensor_xy_all)
        try:
            meta = data.get("meta", {}) if isinstance(data, dict) else {}
            trigger_index = int(meta.get("trigger_offset", data.get("trigger_offset", samples_full.shape[0] // 4))) if isinstance(meta, dict) else int(samples_full.shape[0] // 4)
        except Exception:
            trigger_index = int(samples_full.shape[0] // 4)
        names = list(data.get("sensor_names", self.read_sensor_names()))
        if len(names) < 16:
            names = self.read_sensor_names()
        t0 = time.perf_counter()
        out = d1_aic_localize(
            samples,
            fs,
            params,
            trigger_index=trigger_index,
            target_xy=target_xy,
            channel_labels=[f"CH{i + 1}" for i in selected_idx],
            sensor_names=[names[i] if i < len(names) else f"S{i+1}" for i in selected_idx],
        )
        out.update({
            "elapsed_s": time.perf_counter() - t0,
            "event_seq": int(data.get("event_seq", -1)),
            "active_channel_indices": active_idx,
            "selected_channel_indices": selected_idx,
            "selected_channel_labels": [f"CH{i + 1}" for i in selected_idx],
            "selected_sensor_names": [names[i] if i < len(names) else f"S{i+1}" for i in selected_idx],
            "ref_global_channel": selected_idx[0] + 1,
            "source_file": data.get("csv_path", ""),
        })
        return out


    def _process_queue(self) -> None:
        while True:
            try:
                item = self.ui_queue.get_nowait()
            except queue.Empty:
                break
            kind = item[0]
            if kind == "log":
                self._log(item[1])
            elif kind == "event":
                event, stats = item[1], item[2]
                self.last_event = event
                self.last_stats = stats
                active_idx = self.get_event_active_indices(event)
                self.last_samples4 = np.asarray(event.samples_full_i16[:, active_idx], dtype=np.int16)
                self.save_channel_info_var.set(
                    f"Current event active channel count: {len(active_idx)}; active channels: {self.channel_list_text(active_idx)}"
                )
                self.last_loc_result = None
                self._update_event_info(event, stats)
                self._plot_event(event)
                if self.auto_save_var.get():
                    try:
                        path = self.save_current_data(event)
                        self._log(f"Auto saved active-channel data: {path}")
                    except Exception as exc:
                        self._log(f"Auto save failed: {exc}")
                self._log(
                    f"Acquisition OK: seq={event.event_seq} packets={event.received_packet_count}/{event.packet_count} "
                    f"samples={event.sample_count} x {event.channel_count} payload={event.event_payload_total_bytes} bytes "
                    f"collect={stats.collect_s:.3f}s total={stats.total_s:.3f}s"
                )
            elif kind == "loc":
                out = item[1]
                self.last_loc_result = out
                self._display_localization_outputs(out)
            elif kind == "error":
                _kind, context, exc, tb = item
                self._log(f"{context}: {exc}")
                print(f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}][ERROR] {context}\n{tb}")
                messagebox.showerror(context, str(exc))
            elif kind == "done":
                self.is_busy = False
        self.after(100, self._process_queue)

    def _update_event_info(self, event: AEEvent, stats: ReceiveStats) -> None:
        h0, h1, h3 = event.frame.hdr0, event.frame.hdr1, event.frame.hdr3
        active_idx = self.get_event_active_indices(event)
        self._set_text(self.event_text, "\n".join([
            f"event_seq: {event.event_seq}",
            f"packet_count: {event.packet_count}",
            f"received_packet_count: {event.received_packet_count}",
            f"threshold: {h0['threshold']}",
            f"channel_mask: 0x{int(h0['channel_mask']):04X}",
            f"active_channels: {len(active_idx)} ({self.channel_list_text(active_idx)})",
            f"trigger_sample_index: {h0['trigger_sample_index']}",
            f"frame_samples: {event.frame.frame_samples}",
            f"pre/post: {event.frame.pre_samples} / {event.frame.post_samples}",
            f"trigger_offset: {event.frame.trigger_offset}",
            f"sample_rate_div: {event.frame.sample_rate_div}",
            f"sample_rate: {event.frame.sample_rate_hz / 1e6:.3f} MHz",
            f"frame_duration: {event.frame.frame_duration_us:.3f} us",
            f"time: {h1['year']:04d}-{h1['month']:02d}-{h1['day']:02d} {h1['hour']:02d}:{h1['minute']:02d}:{h1['second']:02d}.{h1['subsec_us']:06d}",
            f"hdr3_valid: {int(bool(h3.get('valid')))}",
        ]))
        first, last = event.packets[0], event.packets[-1]
        self._set_text(self.packet_text, "\n".join([
            f"raw_datagrams: {stats.raw_datagrams}",
            f"collect_s: {stats.collect_s:.3f}",
            f"decode_s: {stats.decode_s:.3f}",
            f"event_total_bytes: {event.event_total_bytes}",
            f"event_payload_bytes: {event.event_payload_total_bytes}",
            f"first payload bytes: {first.payload_bytes}",
            f"last payload bytes: {last.payload_bytes}",
            f"first/last flag: {int(first.is_first)} / {int(last.is_last)}",
            f"first offset: {first.payload_offset}",
            f"last offset: {last.payload_offset}",
        ]))


    def _plot_event(self, event: AEEvent) -> None:
        samples = np.asarray(event.samples_full_i16[:, :16], dtype=np.int16)
        n_samples, n_ch = samples.shape
        if n_ch < 16:
            padded = np.zeros((n_samples, 16), dtype=np.int16)
            padded[:, :n_ch] = samples
            samples = padded
            n_ch = 16
        if event.frame.time_us.size == n_samples:
            x = event.frame.time_us
            xlabel = "Time / us"
        else:
            x = np.arange(n_samples)
            xlabel = "Sample Index"

        if self.y_mode_var.get() == "ADC Differential Voltage / V":
            y = samples.astype(np.float64) * (2.0 / 16384.0)
            ylim = (-1.0, 1.0)
            ylabel = "Differential Voltage / V"
        else:
            y = samples.astype(np.float64)
            ylim = (-32768.0, 32767.0)
            ylabel = "Amplitude / code"

        for i, ax in enumerate(self.axes_wave):
            ax.clear()
            self._style_axis(ax)
            ax.plot(x, y[:, i], linewidth=0.55, color=MPL_LINE)
            if event.frame.time_us.size == n_samples:
                ax.axvline(0, linestyle="--", linewidth=0.6, color=MPL_LINE_2, alpha=0.9)
            ax.set_xlim(float(np.min(x)), float(np.max(x)))
            ax.set_ylim(*ylim)
            ax.set_title(f"CH{i + 1}", fontname=FONT_EN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_PRIMARY_DARK)
            # Avoid visual crowding: show y label only on the first column, x label only bottom row.
            if i % 4 == 0:
                ax.set_ylabel(ylabel, fontname=FONT_CN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
            if i >= 12:
                ax.set_xlabel(xlabel, fontname=FONT_CN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
            for label in ax.get_xticklabels() + ax.get_yticklabels():
                label.set_fontname(FONT_EN)
                label.set_fontsize(FONT_CHART_LABEL_SIZE)
        self.fig_wave.tight_layout(pad=0.85)
        self.canvas_wave.draw_idle()
        self._log(f"Waveform updated: {n_samples} samples x {n_ch} channels.")

    def _update_loc_info(self, out: Dict[str, object]) -> None:
        pos = np.asarray(out.get("finalPos", [np.nan, np.nan]), dtype=float)
        target = np.asarray(out.get("target_xy", [np.nan, np.nan]), dtype=float)
        err = np.linalg.norm(pos - target) if np.all(np.isfinite(pos)) and np.all(np.isfinite(target)) else np.nan
        params: D1AICLocalizationParams = out["params"]  # type: ignore[assignment]
        loc = out.get("loc_result", {}) or {}
        fft_res = out.get("fft", {}) or {}
        velocity_info = out.get("velocity_info", {}) or {}
        arrivals = out.get("arrival_results", []) or []
        lines = [
            f"event_seq: {out.get('event_seq')}",
            f"Estimated X / m: {pos[0]:.6f}",
            f"Estimated Y / m: {pos[1]:.6f}",
            f"Actual X / m: {target[0]:.6f}" if target.size >= 2 else "Actual X / m: NaN",
            f"Actual Y / m: {target[1]:.6f}" if target.size >= 2 else "Actual Y / m: NaN",
            f"Error / m: {err:.6f}",
            f"TOA RMS residual / us: {float(loc.get('rms_residual_us', np.nan)):.3f}",
            f"TOA Max residual / us: {float(loc.get('max_abs_residual_us', np.nan)):.3f}",
            f"t0 / us: {float(loc.get('t0_us', np.nan)):.3f}",
            f"Velocity / m/s: {float(out.get('velocity_m_s', np.nan)):.3f}",
            f"Velocity method: {velocity_info.get('method', '')}",
            f"FFT peak / kHz: {float(fft_res.get('peak_hz', np.nan))/1e3:.3f}",
            f"FFT method: {fft_res.get('combined_method', '')}",
            f"fs/MHz: {params.fs / 1e6:.3f}",
            f"Selected Channel Count: {len(out.get('selected_channel_indices', []))}",
            f"Selected Channels: {', '.join(out.get('selected_channel_labels', []))}",
            f"D1 threshold mode: {params.d1aic.threshold_mode}",
            f"Threshold multiplier: {params.d1aic.threshold_multiplier:.3g}",
            f"AIC offset / us: [{params.d1aic.aic_offset_start_us:.1f}, {params.d1aic.aic_offset_end_us:.1f}]",
            "Arrival times:",
        ]
        for r in arrivals:
            try:
                lines.append(
                    f"  {r.get('channel')}: thr={float(r.get('threshold_time_us')):.2f} us, "
                    f"AIC={float(r.get('arrival_time_us')):.2f} us, "
                    f"TDOA={float(r.get('arrival_time_us')) - float(arrivals[0].get('arrival_time_us')):.2f} us"
                )
            except Exception:
                pass
        selected_labels = out.get("selected_channel_labels", [])
        selected_names = out.get("selected_sensor_names", [])
        lines.append("Sensor Coordinates:")
        for i, p in enumerate(params.sensor_xy, start=1):
            ch_label = selected_labels[i - 1] if i - 1 < len(selected_labels) else f"CH{i}"
            name = selected_names[i - 1] if i - 1 < len(selected_names) else f"S{i}"
            lines.append(f"  {ch_label} {name}: ({p[0]:.4f}, {p[1]:.4f})")
        self._set_text(self.loc_text, "\n".join(lines))
        self._log(f"D1-AIC localization OK: x={pos[0]:.5f} m, y={pos[1]:.5f} m, error={err:.5f} m")


    @staticmethod
    def _choose_aic_annotation_band(out: Dict[str, object]) -> Optional[int]:
        """Return zero-based band index used for channel AIC annotations.

        Prefer the valid subband with the largest fusion weight. If no valid
        subband exists, fall back to the subband with the largest energy ratio.
        """
        T = out.get("bandResults")
        if T is None:
            return None
        try:
            valid = T[T["Valid"] == True].copy()  # noqa: E712
            if len(valid) > 0 and "Weight" in valid:
                valid = valid.sort_values("Weight", ascending=False)
                return int(valid.iloc[0]["Band"]) - 1
            if "EnergyRatio" in T and len(T) > 0:
                return int(T.sort_values("EnergyRatio", ascending=False).iloc[0]["Band"]) - 1
        except Exception:
            return None
        return None

    @staticmethod
    def _toa_row_value(row, name: str) -> float:
        try:
            v = row.get(name, np.nan)
            return float(v) if np.isfinite(float(v)) else np.nan
        except Exception:
            return np.nan

    def _plot_localization(self, out: Dict[str, object]) -> None:
        params: D1AICLocalizationParams = out["params"]  # type: ignore[assignment]
        pos = np.asarray(out.get("finalPos", [np.nan, np.nan]), dtype=float)
        target = np.asarray(out.get("target_xy", [np.nan, np.nan]), dtype=float)
        sensor_xy = np.asarray(params.sensor_xy, dtype=float)
        plate_xy = np.asarray(params.plate_xy, dtype=float)
        ax = self.ax_loc
        ax.clear()
        self._style_axis(ax)
        ax.set_aspect("equal", adjustable="box")
        margin = max(0.02, SENSOR_RADIUS_M * 2.0)
        ax.set_xlim(-margin, plate_xy[0] + margin)
        ax.set_ylim(-margin, plate_xy[1] + margin)
        ax.plot([0, plate_xy[0], plate_xy[0], 0, 0], [0, 0, plate_xy[1], plate_xy[1], 0], color=COLOR_PRIMARY_DARK, linewidth=1.0)
        sensor_label_added = False
        for p in sensor_xy:
            circ = Circle((float(p[0]), float(p[1])), SENSOR_RADIUS_M, facecolor="#BDBDBD", edgecolor="#666666", linewidth=0.9, alpha=0.9, label=("Sensor Position Ø12 mm" if not sensor_label_added else None))
            ax.add_patch(circ)
            sensor_label_added = True
        selected_labels = out.get("selected_channel_labels", [])
        selected_names = out.get("selected_sensor_names", [])
        for i, p in enumerate(sensor_xy, start=1):
            ch_label = selected_labels[i - 1] if i - 1 < len(selected_labels) else f"CH{i}"
            name = selected_names[i - 1] if i - 1 < len(selected_names) else ""
            ax.text(p[0], p[1], f" {ch_label}\n{name}", fontname=FONT_EN, fontsize=FONT_CHART_LABEL_SIZE, va="bottom", color=COLOR_PRIMARY_DARK)
        if np.all(np.isfinite(target)):
            ax.scatter([target[0]], [target[1]], marker="x", s=90, label="Actual Point", color=MPL_TARGET, linewidths=1.6)
        if np.all(np.isfinite(pos)):
            ax.scatter([pos[0]], [pos[1]], marker="o", s=70, label="Estimated Point", color=MPL_EST, edgecolors=COLOR_WHITE, linewidths=0.8)
            if np.all(np.isfinite(target)):
                ax.plot([target[0], pos[0]], [target[1], pos[1]], "--", linewidth=0.9, color=MPL_LINE_2)
        ax.set_xlabel("X / m", fontname=FONT_EN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
        ax.set_ylabel("Y / m", fontname=FONT_EN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
        ax.set_title("Four-Channel AE Source Localization Result", fontname=FONT_CN, fontsize=FONT_CHART_TITLE_SIZE, color=COLOR_PRIMARY_DARK)
        ax.legend(prop={"family": FONT_CN, "size": FONT_CHART_LABEL_SIZE}, frameon=True, facecolor=COLOR_WHITE, edgecolor=COLOR_BORDER)
        for label in ax.get_xticklabels() + ax.get_yticklabels():
            label.set_fontname("Times New Roman")
            label.set_fontsize(9)
        self.fig_loc.tight_layout(pad=1.0)
        self.canvas_loc.draw_idle()

    def _plot_energy(self, out: Dict[str, object]) -> None:
        """Plot summed FFT spectrum around the D1-AIC arrivals."""
        fft_res = out.get("fft", {}) or {}
        freqs = np.asarray(fft_res.get("freqs", []), dtype=float)
        spec = np.asarray(fft_res.get("sum_spec", []), dtype=float)
        ax = self.ax_energy
        ax.clear()
        self._style_axis(ax)
        if freqs.size and spec.size:
            ax.plot(freqs / 1e3, spec, linewidth=0.8, color=MPL_BAR)
            peak_hz = float(fft_res.get("peak_hz", np.nan))
            if np.isfinite(peak_hz):
                ax.axvline(peak_hz / 1e3, linestyle="--", linewidth=1.0, color=MPL_LINE_2, label=f"Peak {peak_hz/1e3:.2f} kHz")
                ax.legend(prop={"family": FONT_EN, "size": 7}, frameon=True, facecolor=COLOR_WHITE, edgecolor=COLOR_BORDER)
        ax.set_xlabel("Frequency / kHz", fontname=FONT_EN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
        ax.set_ylabel("Summed amplitude", fontname=FONT_EN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
        ax.set_title("Summed FFT Spectrum Around D1-AIC Arrivals", fontname=FONT_CN, fontsize=FONT_CHART_TITLE_SIZE, color=COLOR_PRIMARY_DARK)
        for label in ax.get_xticklabels() + ax.get_yticklabels():
            label.set_fontname(FONT_EN)
            label.set_fontsize(8)
        self.fig_energy.tight_layout(pad=0.9)
        self.canvas_energy.draw_idle()


    def _plot_reference_signal(self, out: Dict[str, object]) -> None:
        """Plot selected channels with |D1|, D1-AIC curve, threshold point and AIC arrival."""
        X_raw = np.asarray(out.get("X_raw", np.empty((0, 0))), dtype=float)
        d1_abs = np.asarray(out.get("d1_abs", np.empty((0, 0))), dtype=float)
        time_us = np.asarray(out.get("time_us", np.arange(X_raw.shape[0] if X_raw.ndim == 2 else 0)), dtype=float)
        arrivals = list(out.get("arrival_results", []) or [])
        if X_raw.size == 0 or d1_abs.size == 0:
            return
        n_samples, n_ch = X_raw.shape
        n_plot = min(n_ch, 4)
        selected_labels = list(out.get("selected_channel_labels", [f"CH{i + 1}" for i in range(n_ch)]))
        selected_names = list(out.get("selected_sensor_names", [f"S{i + 1}" for i in range(n_ch)]))

        self.fig_ref.clear()
        self.axes_aic = [self.fig_ref.add_subplot(4, 1, i + 1) for i in range(4)]
        axes = self.axes_aic
        for i, ax in enumerate(axes):
            ax.clear()
            self._style_axis(ax)
            if i >= n_plot:
                ax.set_visible(False)
                continue
            ax.set_visible(True)
            y_raw = X_raw[:, i]
            y_d1 = d1_abs[:, i]
            finite = y_raw[np.isfinite(y_raw)]
            ylim = max(float(np.nanpercentile(np.abs(finite), 99.5)) * 1.25, 1.0) if finite.size else 1.0
            ax.plot(time_us, y_raw, linewidth=0.6, color=MPL_LINE, label="Raw signal" if i == 0 else None)
            # Normalize |D1| to the raw-signal axis for visual comparison.
            if np.nanmax(y_d1) > 0:
                y_d1_norm = y_d1 / np.nanmax(y_d1) * 0.80 * ylim
                ax.plot(time_us, y_d1_norm, linewidth=0.65, color="#4C78A8", alpha=0.85, label="|D1| normalized" if i == 0 else None)
            if i < len(arrivals):
                r = arrivals[i]
                thr_t = float(r.get("threshold_time_us", np.nan))
                arr_t = float(r.get("arrival_time_us", np.nan))
                if np.isfinite(thr_t):
                    ax.axvline(thr_t, linestyle=":", linewidth=1.0, color=COLOR_PRIMARY_DARK, alpha=0.9, label="D1 threshold" if i == 0 else None)
                if np.isfinite(arr_t):
                    ax.axvline(arr_t, linestyle="--", linewidth=1.1, color=MPL_TARGET, alpha=0.98, label="D1-AIC arrival" if i == 0 else None)
                aic_t = np.asarray(r.get("aic_time_us", []), dtype=float)
                aic = np.asarray(r.get("aic_curve", []), dtype=float)
                if aic_t.size and aic.size and np.any(np.isfinite(aic)):
                    aa = aic.copy()
                    amin, amax = np.nanmin(aa), np.nanmax(aa)
                    if np.isfinite(amax - amin) and (amax - amin) > 0:
                        a_norm = ((aa - amin) / (amax - amin) * 2.0 - 1.0) * (0.70 * ylim)
                        ax.plot(aic_t, a_norm, linewidth=0.75, color=MPL_LINE_2, alpha=0.95, label="AIC curve normalized" if i == 0 else None)
                txt = f"thr={thr_t:.2f} us, AIC={arr_t:.2f} us"
                ax.text(0.012, 0.94, txt, transform=ax.transAxes, va="top", ha="left", fontsize=7.0, fontname=FONT_EN,
                        color=COLOR_PRIMARY_DARK, bbox=dict(boxstyle="round,pad=0.20", facecolor="white", edgecolor=COLOR_BORDER, alpha=0.86))
            label = selected_labels[i] if i < len(selected_labels) else f"CH{i + 1}"
            name = selected_names[i] if i < len(selected_names) else ""
            ax.set_title(f"{label} {name}".strip(), fontname=FONT_EN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_PRIMARY_DARK, pad=2)
            ax.set_ylabel("Amplitude / code", fontname=FONT_CN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
            ax.set_xlim(float(np.nanmin(time_us)), float(np.nanmax(time_us)))
            ax.set_ylim(-ylim, ylim)
            if i == n_plot - 1:
                ax.set_xlabel("Time / us", fontname=FONT_EN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
            for tick in ax.get_xticklabels() + ax.get_yticklabels():
                tick.set_fontname(FONT_EN)
                tick.set_fontsize(7.0)
            if i == 0:
                ax.legend(prop={"family": FONT_CN, "size": 7}, loc="upper right", frameon=True, facecolor=COLOR_WHITE, edgecolor=COLOR_BORDER)
        self.fig_ref.suptitle("D1-AIC Arrival-Time Annotation", fontname=FONT_CN, fontsize=FONT_CHART_TITLE_SIZE, color=COLOR_PRIMARY_DARK, y=0.995)
        self.fig_ref.tight_layout(rect=[0.0, 0.0, 1.0, 0.955], pad=0.55)
        self.canvas_ref.draw_idle()


    def _update_energy_table(self, out: Dict[str, object]) -> None:
        for item in self.energy_tree.get_children():
            self.energy_tree.delete(item)
        arrivals = list(out.get("arrival_results", []) or [])
        if not arrivals:
            return
        t0 = float(arrivals[0].get("arrival_time_us", np.nan))
        for r in arrivals:
            try:
                arr = float(r.get("arrival_time_us", np.nan))
                self.energy_tree.insert("", tk.END, values=(
                    str(r.get("channel", "")),
                    f"{float(r.get('threshold_time_us', np.nan)):.3f}",
                    f"{arr:.3f}",
                    f"{arr - t0:.3f}" if np.isfinite(t0) and np.isfinite(arr) else "NaN",
                    f"{float(r.get('threshold_value', np.nan)):.4g}",
                    f"{float(r.get('baseline_rms', np.nan)):.4g}",
                    f"{float(r.get('aic_min', np.nan)):.4g}",
                ))
            except Exception:
                pass


    def _update_band_table(self, out: Dict[str, object]) -> None:
        for item in self.band_tree.get_children():
            self.band_tree.delete(item)
        arrivals = list(out.get("arrival_results", []) or [])
        loc = out.get("loc_result", {}) or {}
        residuals = np.asarray(loc.get("residuals_us", []), dtype=float)
        params: D1AICLocalizationParams = out["params"]  # type: ignore[assignment]
        for i, r in enumerate(arrivals):
            try:
                sx, sy = params.sensor_xy[i]
                res = residuals[i] if i < residuals.size else np.nan
                self.band_tree.insert("", tk.END, values=(
                    str(r.get("channel", f"CH{i+1}")),
                    f"{float(r.get('arrival_time_us', np.nan)):.3f}",
                    f"{float(res):.3f}" if np.isfinite(res) else "NaN",
                    f"{float(sx):.4f}",
                    f"{float(sy):.4f}",
                    "Yes",
                    "D1-AIC TOA",
                    "OK",
                    "",
                ))
            except Exception:
                pass


    def _display_localization_outputs(self, out: Dict[str, object]) -> None:
        self._update_loc_info(out)
        self._plot_localization(out)
        self._plot_energy(out)
        self._plot_reference_signal(out)
        self._update_energy_table(out)
        self._update_band_table(out)
        self.notebook.select(1)

    def _set_text(self, txt: tk.Text, content: str) -> None:
        txt.configure(state=tk.NORMAL)
        txt.delete("1.0", tk.END)
        txt.insert("1.0", content)
        txt.configure(state=tk.DISABLED)

    def _log(self, msg: str) -> None:
        line = f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}][GUI] {msg}"
        print(line)
        self.log_lines.append(line)
        if len(self.log_lines) > self.log_max_lines:
            self.log_lines = self.log_lines[-self.log_max_lines:]
        self.log_list.delete(0, tk.END)
        for x in self.log_lines:
            self.log_list.insert(tk.END, x)
        self.log_list.see(tk.END)

    def _log_error(self, context: str, exc: Exception) -> None:
        self._log(f"{context}: {exc}")
        traceback.print_exc()
        messagebox.showerror(context, str(exc))

    def _update_clock(self) -> None:
        self.clock_var.set(datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        self.after(1000, self._update_clock)

    def on_close(self) -> None:
        try:
            if self.client is not None:
                self.client.close()
        finally:
            self.destroy()


def main() -> None:
    app = AEAcqLocGui()
    app.mainloop()


if __name__ == "__main__":
    main()
