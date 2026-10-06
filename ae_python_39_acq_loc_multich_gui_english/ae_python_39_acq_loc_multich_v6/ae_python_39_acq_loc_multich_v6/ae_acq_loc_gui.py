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
from matplotlib.patches import Circle, Rectangle

from ae_fpga_client.config import AEConfig, ControlConfig, default_config, sample_rate_options
from ae_fpga_client.protocol import AEEvent
from ae_fpga_client.udp_client import AEUdpClient, ReceiveStats
from ae_localization.core import (
    EventWindowOptions,
    LocalizationParams,
    MaterialParams,
    TOAOptions,
    compute_wpt_subband_energy,
    default_band_table,
    preprocess_signals,
    process_ae_wpt_localization_toa,
    update_band_velocity_by_lamb,
    local_aic_curve,
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

# English interface display switch. False means the English Location Result
# page hides subband-energy details, while the original/full layout code remains
# available and the Chinese GUI file does not need to be changed.
SHOW_SUBBAND_DETAILS_IN_ENGLISH = False


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
        self.title("AE Acquisition and Multichannel Localization System - Python")
        self.geometry("1920x1080")
        self.minsize(1500, 900)

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

    def _setup_theme(self) -> None:
        """Apply a thesis/Nature-style blue theme to the Tkinter GUI."""
        self.configure(bg=COLOR_BG)
        self.option_add("*Font", (FONT_CN, FONT_UI_SIZE))
        self.option_add("*TCombobox*Listbox.font", (FONT_CN, FONT_UI_SIZE))

        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except Exception:
            pass

        style.configure(".", font=(FONT_CN, FONT_UI_SIZE), background=COLOR_BG, foreground=COLOR_TEXT)
        style.configure("TFrame", background=COLOR_BG)
        style.configure("TLabelframe", background=COLOR_BG, bordercolor=COLOR_BORDER, relief="solid")
        style.configure("TLabelframe.Label", background=COLOR_BG, foreground=COLOR_PRIMARY_DARK, font=(FONT_CN, FONT_UI_SIZE, "bold"))
        style.configure("TLabel", background=COLOR_BG, foreground=COLOR_TEXT, font=(FONT_CN, FONT_UI_SIZE))
        style.configure("TEntry", fieldbackground=COLOR_WHITE, foreground=COLOR_TEXT, insertcolor=COLOR_PRIMARY_DARK, font=(FONT_EN, FONT_UI_SIZE))
        style.configure("TCombobox", fieldbackground=COLOR_WHITE, foreground=COLOR_TEXT, font=(FONT_CN, FONT_UI_SIZE))
        style.configure("TCheckbutton", background=COLOR_BG, foreground=COLOR_TEXT, font=(FONT_CN, FONT_UI_SIZE))
        style.configure("TButton", background=COLOR_PRIMARY, foreground=COLOR_WHITE, bordercolor=COLOR_PRIMARY_DARK, focusthickness=1, focuscolor=COLOR_ACCENT, padding=(8, 4), font=(FONT_CN, FONT_UI_SIZE, "bold"))
        style.map("TButton", background=[("active", COLOR_ACCENT), ("pressed", COLOR_PRIMARY_DARK)], foreground=[("disabled", "#A0A0A0")])
        style.configure("TNotebook", background=COLOR_BG, borderwidth=0)
        style.configure("TNotebook.Tab", background=COLOR_PANEL_2, foreground=COLOR_PRIMARY_DARK, padding=(12, 5), font=(FONT_CN, FONT_UI_SIZE, "bold"))
        style.map("TNotebook.Tab", background=[("selected", COLOR_PRIMARY)], foreground=[("selected", COLOR_WHITE)])
        style.configure("Treeview", background=COLOR_WHITE, fieldbackground=COLOR_WHITE, foreground=COLOR_TEXT, rowheight=24, font=(FONT_EN, FONT_UI_SIZE))
        style.configure("Treeview.Heading", background=COLOR_PRIMARY_DARK, foreground=COLOR_WHITE, font=(FONT_CN, FONT_UI_SIZE, "bold"))
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
        ax.tick_params(colors=COLOR_TEXT, labelsize=FONT_CHART_LABEL_SIZE)
        for label in ax.get_xticklabels() + ax.get_yticklabels():
            label.set_fontname(FONT_EN)
            label.set_fontsize(FONT_CHART_LABEL_SIZE)
        if title:
            ax.set_title(title, fontname=FONT_CN, fontsize=FONT_CHART_TITLE_SIZE, color=COLOR_PRIMARY_DARK, pad=5)

    def _build_ui(self) -> None:
        root = ttk.Frame(self)
        root.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)

        top = ttk.Frame(root)
        top.pack(fill=tk.X, pady=(0, 6))
        top.columnconfigure(0, weight=1)
        top.columnconfigure(1, weight=0)
        top.columnconfigure(2, weight=0)
        ttk.Label(
            top,
            text="AE Acquisition and Multichannel Localization System",
            font=(FONT_CN, FONT_TITLE_SIZE, "bold"),
            foreground=COLOR_PRIMARY_DARK,
        ).grid(row=0, column=0, sticky="w")

        self.logo_path = r"C:\Users\Adam\Downloads\CQU.png"
        self.logo_image: Optional[tk.PhotoImage] = None
        logo_area = ttk.Frame(top)
        logo_area.grid(row=0, column=1, sticky="e", padx=(8, 12))
        self.logo_label = ttk.Label(logo_area, text="", anchor="center")
        self.logo_label.grid(row=0, column=0, sticky="e")
        self._load_logo_image(self.logo_path)

        self.clock_var = tk.StringVar(value="")
        ttk.Label(top, textvariable=self.clock_var, font=(FONT_EN, FONT_UI_SIZE), foreground=COLOR_PRIMARY_DARK).grid(row=0, column=2, sticky="e")

        # Layout required by the updated design:
        #   left   = parameter setting pages;
        #   center = waveform / localization pages;
        #   right  = original parameter output / display panels;
        #   bottom = full-width running log.
        body = ttk.PanedWindow(root, orient=tk.HORIZONTAL)
        body.pack(fill=tk.BOTH, expand=True)

        left = ttk.Frame(body, width=360)
        center = ttk.Frame(body)
        right = ttk.Frame(body, width=410)
        left.pack_propagate(False)
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
            self.logo_label.configure(image="", text="")
            return
        try:
            img = tk.PhotoImage(file=str(p))
            max_w, max_h = 120, 54
            scale = max(1, math.ceil(max(img.width() / max_w, img.height() / max_h)))
            if scale > 1:
                img = img.subsample(scale, scale)
            self.logo_image = img
            self.logo_label.configure(image=self.logo_image, text="")
            self.logo_path = str(p)
        except Exception:
            self.logo_image = None
            self.logo_label.configure(image="", text="")

    def on_import_logo(self) -> None:
        """Select a logo image and show it in the top bar. The button is hidden in the English UI."""
        path = filedialog.askopenfilename(
            title="Select Logo Image",
            filetypes=[("Image files", "*.png *.gif"), ("PNG files", "*.png"), ("GIF files", "*.gif"), ("All files", "*.*")],
        )
        if path:
            self.logo_path = path
            self._load_logo_image(path)

    def _build_left_param_pages(self, parent: ttk.Frame) -> None:
        """Left-side parameter setting pages.

        The parameter input area remains on the left. It is split into pages so
        UDP/acquisition parameters, save/geometry parameters, localization
        parameters, and operation controls do not crowd into one long page.
        """
        nb = ttk.Notebook(parent)
        nb.pack(fill=tk.BOTH, expand=True)

        udp_page = ttk.Frame(nb)
        save_page = ttk.Frame(nb)
        loc_page = ttk.Frame(nb)
        nb.add(udp_page, text="UDP")
        nb.add(save_page, text="Data")
        nb.add(loc_page, text="Localization")

        # ------------------------------------------------------------------ UDP page
        net = ttk.LabelFrame(udp_page, text="Network and Connection")
        net.pack(fill=tk.X, padx=6, pady=(6, 6))
        self.local_ip = tk.StringVar(value=self.cfg.local_ip)
        self.local_port = tk.StringVar(value=str(self.cfg.local_port))
        self.remote_ip = tk.StringVar(value=self.cfg.remote_ip)
        self.remote_port = tk.StringVar(value=str(self.cfg.remote_port))
        self.conn_var = tk.StringVar(value="Disconnected")
        self._row_entry(net, "Local IP", self.local_ip, 0, width=16)
        self._row_entry(net, "Local Port", self.local_port, 1, width=8)
        self._row_entry(net, "FPGA IP", self.remote_ip, 2, width=16)
        self._row_entry(net, "FPGA Port", self.remote_port, 3, width=8)
        ttk.Label(net, textvariable=self.conn_var).grid(row=4, column=0, columnspan=3, sticky="w", padx=6, pady=4)
        ttk.Button(net, text="Connect UDP", command=self.on_connect).grid(row=5, column=0, columnspan=3, sticky="ew", padx=6, pady=(2, 3))
        ttk.Button(net, text="Disconnect UDP", command=self.on_disconnect).grid(row=6, column=0, columnspan=3, sticky="ew", padx=6, pady=(3, 6))
        net.columnconfigure(1, weight=1)

        ctrl = ttk.LabelFrame(udp_page, text="Acquisition / Trigger")
        ctrl.pack(fill=tk.X, padx=6, pady=(0, 6))
        labels, codes = sample_rate_options()
        self.sr_labels = list(labels)
        self.sr_codes = list(codes)
        self.rate_var = tk.StringVar(value="10MHz")
        ttk.Label(ctrl, text="ADC Sample Rate").grid(row=0, column=0, sticky="w", padx=6, pady=4)
        ttk.Combobox(ctrl, textvariable=self.rate_var, values=self.sr_labels, state="readonly", width=12).grid(row=0, column=1, sticky="w", padx=6)
        self.mask_var = tk.StringVar(value="000F")
        self._row_entry(ctrl, "Channel Mask", self.mask_var, 1, width=8)
        self.threshold_var = tk.StringVar(value="4000")
        self._row_entry(ctrl, "AE Threshold", self.threshold_var, 2, width=10)
        self.pulse_freq_var = tk.StringVar(value="1000")
        self._row_entry(ctrl, "Pulse Frequency (kHz)", self.pulse_freq_var, 3, width=10)
        self.pulse_gap_var = tk.StringVar(value="1000")
        self._row_entry(ctrl, "Pulse Gap (us)", self.pulse_gap_var, 4, width=10)
        self.pulse_count_var = tk.StringVar(value="1")
        self._row_entry(ctrl, "Pulse Count", self.pulse_count_var, 5, width=8)
        self.duty_var = tk.StringVar(value="50")
        self._row_entry(ctrl, "Duty Cycle (%)", self.duty_var, 6, width=8)
        self.rx_enable_var = tk.BooleanVar(value=True)
        self.tx_enable_var = tk.BooleanVar(value=False)
        self.time_sync_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(ctrl, text="Enable ADC RX", variable=self.rx_enable_var).grid(row=7, column=0, sticky="w", padx=6, pady=3)
        ttk.Checkbutton(ctrl, text="Enable Pulse TX", variable=self.tx_enable_var).grid(row=7, column=1, sticky="w", padx=6, pady=3)
        ttk.Checkbutton(ctrl, text="Time Sync", variable=self.time_sync_var).grid(row=8, column=0, sticky="w", padx=6, pady=3)
        ttk.Button(ctrl, text="Send Parameters", command=self.on_send_control).grid(row=9, column=0, columnspan=3, sticky="ew", padx=6, pady=6)

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
        ttk.Label(savef, textvariable=self.save_channel_info_var, wraplength=310, foreground=COLOR_PRIMARY_DARK).grid(row=6, column=0, columnspan=3, sticky="w", padx=6, pady=(2, 4))
        savef.columnconfigure(1, weight=1)

        namef = ttk.LabelFrame(save_page, text="Sensor Channels / Names")
        namef.pack(fill=tk.BOTH, expand=True, padx=6, pady=(0, 6))
        ttk.Label(namef, text="Note: only channels enabled in the returned channel_mask are saved; CSV column names include channel numbers and sensor names.", wraplength=310).grid(row=0, column=0, columnspan=4, sticky="w", padx=6, pady=(4, 4))
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
        locf = ttk.LabelFrame(loc_page, text="Localization Parameters")
        locf.pack(fill=tk.X, padx=6, pady=(6, 6))
        self.loc_source_var = tk.StringVar(value="Current Acquisition Data")
        self.loc_channel_count_var = tk.StringVar(value="4")
        self.loc_level_var = tk.StringVar(value="4")
        self.loc_wavelet_var = tk.StringVar(value="db6")
        self.loc_ref_ch_var = tk.StringVar(value="4")
        self.loc_mode_var = tk.StringVar(value="A0")
        self.loc_energy_thr_var = tk.StringVar(value="0.001")
        self.loc_res_thr_var = tk.StringVar(value="8e-6")
        self.loc_filter_low_var = tk.StringVar(value="40000")
        self.loc_filter_high_var = tk.StringVar(value="500000")
        self.loc_thickness_var = tk.StringVar(value="0.004")
        # AIC search window anchored to FPGA threshold trigger index.
        # The true first arrival can be earlier than the threshold crossing, so
        # these two values should be adjustable from the GUI.
        self.loc_aic_pre_us_var = tk.StringVar(value="180")
        self.loc_aic_post_us_var = tk.StringVar(value="80")
        ttk.Label(locf, text="Data Source").grid(row=0, column=0, sticky="w", padx=6, pady=3)
        ttk.Combobox(locf, textvariable=self.loc_source_var, values=["Current Acquisition Data", "Loaded Saved Data"], state="readonly", width=12).grid(row=0, column=1, sticky="w", padx=6, pady=3)
        ttk.Label(locf, text="Channel Count").grid(row=1, column=0, sticky="w", padx=6, pady=3)
        ttk.Combobox(locf, textvariable=self.loc_channel_count_var, values=["4", "8", "12", "16"], state="readonly", width=8).grid(row=1, column=1, sticky="w", padx=6, pady=3)
        self._row_entry(locf, "WPT Level", self.loc_level_var, 2, width=8)
        self._row_entry(locf, "Wavelet", self.loc_wavelet_var, 3, width=8)
        self._row_entry(locf, "Reference Channel", self.loc_ref_ch_var, 4, width=8)
        self._row_entry(locf, "Mode (A0/S0)", self.loc_mode_var, 5, width=8)
        self._row_entry(locf, "Energy Threshold", self.loc_energy_thr_var, 6, width=8)
        self._row_entry(locf, "Residual / s", self.loc_res_thr_var, 7, width=8)
        self._row_entry(locf, "Filter Low / Hz", self.loc_filter_low_var, 8, width=10)
        self._row_entry(locf, "Filter High / Hz", self.loc_filter_high_var, 9, width=10)
        self._row_entry(locf, "Plate Thickness / m", self.loc_thickness_var, 10, width=8)
        self._row_entry(locf, "AIC Pre-window / us", self.loc_aic_pre_us_var, 11, width=8)
        self._row_entry(locf, "AIC Post-window / us", self.loc_aic_post_us_var, 12, width=8)
        ttk.Button(locf, text="Run Localization", command=self.on_localize).grid(row=13, column=0, columnspan=3, sticky="ew", padx=6, pady=6)

        geom = ttk.LabelFrame(save_page, text="Sensor Coordinates / m")
        geom.pack(fill=tk.BOTH, expand=True, padx=6, pady=(0, 6))
        defaults16 = [(0.0, 0.0) for _ in range(16)]
        self.sensor_vars: List[Tuple[tk.StringVar, tk.StringVar]] = []
        ttk.Label(geom, text="Channel").grid(row=0, column=0, sticky="w", padx=6, pady=2)
        ttk.Label(geom, text="X").grid(row=0, column=1, sticky="w", padx=4, pady=2)
        ttk.Label(geom, text="Y").grid(row=0, column=2, sticky="w", padx=4, pady=2)
        ttk.Label(geom, text="Channel").grid(row=0, column=3, sticky="w", padx=10, pady=2)
        ttk.Label(geom, text="X").grid(row=0, column=4, sticky="w", padx=4, pady=2)
        ttk.Label(geom, text="Y").grid(row=0, column=5, sticky="w", padx=4, pady=2)
        for i, (x0, y0) in enumerate(defaults16, start=1):
            block = 0 if i <= 8 else 3
            r = i if i <= 8 else i - 8
            ttk.Label(geom, text=f"CH{i:02d}").grid(row=r, column=block, sticky="w", padx=(6 if block == 0 else 10, 2), pady=2)
            xv = tk.StringVar(value=f"{x0:.3f}")
            yv = tk.StringVar(value=f"{y0:.3f}")
            self.sensor_vars.append((xv, yv))
            ttk.Entry(geom, textvariable=xv, width=7).grid(row=r, column=block + 1, padx=2, pady=2)
            ttk.Entry(geom, textvariable=yv, width=7).grid(row=r, column=block + 2, padx=2, pady=2)
        self.plate_x_var = tk.StringVar(value="0.500")
        self.plate_y_var = tk.StringVar(value="0.400")
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
            wraplength=310,
        ).pack(fill=tk.X, expand=False, padx=6, pady=6)

        # ------------------------------------------------------------------ Run controls: placed below the UDP parameter page
        cmd = ttk.LabelFrame(udp_page, text="Runtime Commands")
        cmd.pack(fill=tk.X, padx=6, pady=(0, 6))
        ttk.Button(cmd, text="One-click Acquisition", command=self.on_round_trip).grid(row=0, column=0, padx=4, pady=4, sticky="ew")
        ttk.Button(cmd, text="Refresh Plot", command=self.on_plot).grid(row=1, column=0, padx=4, pady=4, sticky="ew")
        ttk.Button(cmd, text="Clear Log", command=self.on_clear_log).grid(row=2, column=0, padx=4, pady=4, sticky="ew")
        cmd.columnconfigure(0, weight=1)


    def _build_right_output(self, parent: ttk.Frame) -> None:
        """Right-side output/display panels kept in the original style."""
        self.event_text = self._make_info_box(parent, "Event Frame Info", 11)
        self.packet_text = self._make_info_box(parent, "Packet Info", 9)
        self.save_text = self._make_info_box(parent, "Save Info", 6)
        self.loc_text = self._make_info_box(parent, "Localization Summary", 16)


    def _build_param_pages(self, parent: ttk.Frame) -> None:
        # Backward-compatible alias. New layout calls _build_left_param_pages().
        self._build_left_param_pages(parent)


    def _build_log_bottom(self, parent: ttk.Frame) -> None:
        logf = ttk.LabelFrame(parent, text="Run Log")
        logf.pack(fill=tk.X, expand=False, pady=(6, 0))
        self.log_list = tk.Listbox(logf, height=7, font=(FONT_MONO, FONT_UI_SIZE), bg=COLOR_WHITE, fg=COLOR_TEXT, selectbackground=COLOR_ACCENT, selectforeground=COLOR_WHITE, relief=tk.FLAT)
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
        ttk.Label(wave_top, text="   Waveform display: CH1-CH16; localization uses the selected channel count", font=(FONT_CN, FONT_UI_SIZE), foreground=COLOR_PRIMARY_DARK).pack(side=tk.LEFT, padx=10)

        self.fig_wave = Figure(figsize=(12, 8), dpi=100, facecolor=COLOR_BG)
        self.axes_wave = [self.fig_wave.add_subplot(4, 4, i + 1) for i in range(16)]
        self._style_figure(self.fig_wave)
        self.fig_wave.tight_layout(pad=0.9)
        self.canvas_wave = FigureCanvasTkAgg(self.fig_wave, master=wave_tab)
        self.canvas_wave.get_tk_widget().pack(fill=tk.BOTH, expand=True)

        # Localization result page.
        # In this English GUI, subband-energy panels are hidden by default.
        # The full subband layout code is kept below behind a display switch so
        # the Chinese GUI/version can remain unchanged.
        if SHOW_SUBBAND_DETAILS_IN_ENGLISH:
            loc_vertical = ttk.PanedWindow(loc_tab, orient=tk.VERTICAL)
            loc_vertical.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

            top_row = ttk.PanedWindow(loc_vertical, orient=tk.HORIZONTAL)
            mid_row = ttk.PanedWindow(loc_vertical, orient=tk.HORIZONTAL)
            bottom_row = ttk.Frame(loc_vertical)
            loc_vertical.add(top_row, weight=4)
            loc_vertical.add(mid_row, weight=3)
            loc_vertical.add(bottom_row, weight=3)

            loc_map_frame = ttk.LabelFrame(top_row, text="Localization Map")
            ref_frame = ttk.LabelFrame(top_row, text="AIC Arrival-Time Annotation by Channel")
            top_row.add(loc_map_frame, weight=1)
            top_row.add(ref_frame, weight=1)

            self.fig_loc = Figure(figsize=(6.2, 4.2), dpi=100, facecolor=COLOR_BG)
            self.ax_loc = self.fig_loc.add_subplot(1, 1, 1)
            self._style_figure(self.fig_loc)
            self.canvas_loc = FigureCanvasTkAgg(self.fig_loc, master=loc_map_frame)
            self.canvas_loc.get_tk_widget().pack(fill=tk.BOTH, expand=True)

            self.fig_ref = Figure(figsize=(7.2, 5.0), dpi=100, facecolor=COLOR_BG)
            self.axes_aic = [self.fig_ref.add_subplot(4, 1, i + 1) for i in range(4)]
            self._style_figure(self.fig_ref)
            self.canvas_ref = FigureCanvasTkAgg(self.fig_ref, master=ref_frame)
            self.canvas_ref.get_tk_widget().pack(fill=tk.BOTH, expand=True)

            energy_fig_frame = ttk.LabelFrame(mid_row, text="Subband Energy Plot")
            energy_table_frame = ttk.LabelFrame(mid_row, text="Subband Energy Table")
            mid_row.add(energy_fig_frame, weight=1)
            mid_row.add(energy_table_frame, weight=1)

            self.fig_energy = Figure(figsize=(6.2, 3.2), dpi=100, facecolor=COLOR_BG)
            self.ax_energy = self.fig_energy.add_subplot(1, 1, 1)
            self._style_figure(self.fig_energy)
            self.canvas_energy = FigureCanvasTkAgg(self.fig_energy, master=energy_fig_frame)
            self.canvas_energy.get_tk_widget().pack(fill=tk.BOTH, expand=True)

            energy_cols = ("Band", "Fmin_kHz", "Fmax_kHz", "Energy", "Velocity", "Valid", "Reason")
            self.energy_tree = ttk.Treeview(energy_table_frame, columns=energy_cols, show="headings", height=8)
            for c in energy_cols:
                self.energy_tree.heading(c, text=c)
                self.energy_tree.column(c, width=88, anchor="center")
            self.energy_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(4, 0), pady=4)
            sb_e = ttk.Scrollbar(energy_table_frame, orient=tk.VERTICAL, command=self.energy_tree.yview)
            sb_e.pack(side=tk.RIGHT, fill=tk.Y, pady=4)
            self.energy_tree.configure(yscrollcommand=sb_e.set)

            band_table_frame = ttk.LabelFrame(bottom_row, text="Subband Localization Results")
            band_table_frame.pack(fill=tk.BOTH, expand=True)
            band_cols = ("Band", "Energy", "Velocity", "X", "Y", "Residual", "Weight", "Valid", "Reason")
            self.band_tree = ttk.Treeview(band_table_frame, columns=band_cols, show="headings", height=9)
            for c in band_cols:
                self.band_tree.heading(c, text=c)
                self.band_tree.column(c, width=88, anchor="center")
            self.band_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(4, 0), pady=4)
            sb_b = ttk.Scrollbar(band_table_frame, orient=tk.VERTICAL, command=self.band_tree.yview)
            sb_b.pack(side=tk.RIGHT, fill=tk.Y, pady=4)
            self.band_tree.configure(yscrollcommand=sb_b.set)
        else:
            loc_vertical = ttk.PanedWindow(loc_tab, orient=tk.VERTICAL)
            loc_vertical.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

            ref_frame = ttk.LabelFrame(loc_vertical, text="AIC Arrival-Time Calculation")
            loc_map_frame = ttk.LabelFrame(loc_vertical, text="Predicted Localization Map")
            loc_vertical.add(ref_frame, weight=5)
            loc_vertical.add(loc_map_frame, weight=4)

            self.fig_ref = Figure(figsize=(10.0, 5.0), dpi=100, facecolor=COLOR_BG)
            self.axes_aic = [self.fig_ref.add_subplot(4, 1, i + 1) for i in range(4)]
            self._style_figure(self.fig_ref)
            self.canvas_ref = FigureCanvasTkAgg(self.fig_ref, master=ref_frame)
            self.canvas_ref.get_tk_widget().pack(fill=tk.BOTH, expand=True)

            self.fig_loc = Figure(figsize=(10.0, 4.0), dpi=100, facecolor=COLOR_BG)
            self.ax_loc = self.fig_loc.add_subplot(1, 1, 1)
            self._style_figure(self.fig_loc)
            self.canvas_loc = FigureCanvasTkAgg(self.fig_loc, master=loc_map_frame)
            self.canvas_loc.get_tk_widget().pack(fill=tk.BOTH, expand=True)

    def _build_right(self, parent: ttk.Frame) -> None:
        # Backward-compatible alias. New layout uses _build_right_output().
        self._build_right_output(parent)


    def _make_info_box(self, parent: ttk.Frame, title: str, height: int) -> tk.Text:
        f = ttk.LabelFrame(parent, text=title)
        f.pack(fill=tk.BOTH, expand=False, pady=(0, 6))
        txt = tk.Text(f, height=height, width=48, font=(FONT_MONO, FONT_UI_SIZE), wrap=tk.NONE, bg=COLOR_WHITE, fg=COLOR_TEXT, insertbackground=COLOR_PRIMARY_DARK, relief=tk.FLAT)
        txt.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        txt.insert("1.0", "No data.")
        txt.configure(state=tk.DISABLED)
        return txt

    def _row_entry(self, parent: ttk.Frame, label: str, var: tk.StringVar, row: int, width: int = 12) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=6, pady=3)
        ttk.Entry(parent, textvariable=var, width=width).grid(row=row, column=1, sticky="w", padx=6, pady=3)

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
    def make_loc_params(self, fs: float, selected_channel_indices: List[int], sensor_xy_all: Optional[np.ndarray] = None) -> LocalizationParams:
        if len(selected_channel_indices) < 4:
            raise ValueError("Localization requires at least 4 channels.")
        all_xy = np.asarray(sensor_xy_all, dtype=float) if sensor_xy_all is not None else self.read_sensor_xy()
        sensor_xy = all_xy[selected_channel_indices, :]

        ref_global = max(1, min(16, safe_int(self.loc_ref_ch_var.get(), 4))) - 1
        if ref_global in selected_channel_indices:
            ref_relative = selected_channel_indices.index(ref_global) + 1
        else:
            # If the user-selected reference channel is not inside the selected
            # active set, use the last channel of the first four active channels.
            fallback_pos = min(3, len(selected_channel_indices) - 1)
            ref_relative = fallback_pos + 1
            ref_global = selected_channel_indices[fallback_pos]
            self.ui_queue.put(("log", f"Reference channel CH{safe_int(self.loc_ref_ch_var.get(), 4)} is not used in this localization run; automatically switched to CH{ref_global + 1}."))

        mode = self.loc_mode_var.get().strip().upper() or "A0"
        if mode not in {"A0", "S0"}:
            mode = "A0"
        params = LocalizationParams(
            fs=float(fs),
            wavelet_name=self.loc_wavelet_var.get().strip() or "db6",
            wpt_level=max(1, min(7, safe_int(self.loc_level_var.get(), 4))),
            ref_channel=ref_relative,
            sensor_xy=sensor_xy,
            plate_xy=np.array([safe_float(self.plate_x_var.get(), 0.5), safe_float(self.plate_y_var.get(), 0.4)], dtype=float),
            energy_threshold=safe_float(self.loc_energy_thr_var.get(), 0.001),
            residual_threshold=safe_float(self.loc_res_thr_var.get(), 8e-6),
            filter_low_hz=safe_float(self.loc_filter_low_var.get(), 4.0e4),
            filter_high_hz=safe_float(self.loc_filter_high_var.get(), 5.0e5),
            default_mode=mode,
            material=MaterialParams(thickness_m=safe_float(self.loc_thickness_var.get(), 0.004)),
            toa=TOAOptions(method="Envelope Event Window + AIC"),
            event=EventWindowOptions(
                pre_us=max(1.0, safe_float(self.loc_aic_pre_us_var.get(), 180.0)),
                post_us=max(1.0, safe_float(self.loc_aic_post_us_var.get(), 80.0)),
            ),
        )
        return params


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
        try:
            params.event.trigger_index = int(event.frame.trigger_offset)
            # Do not force AIC to be after the threshold trigger.
            # The real first arrival may occur before trigger_offset.
            params.event.min_pick_pre_samples = None
        except Exception:
            pass
        t0 = time.perf_counter()
        X_raw = samples.copy()
        # No band-pass filtering: only de-mean/std normalization inside preprocess_signals.
        # This avoids filter edge transients at the start of the AE frame.
        X = preprocess_signals(X_raw, params.fs, params.filter_low_hz, params.filter_high_hz)
        subbands, energy_ratio = compute_wpt_subband_energy(X, params.wpt_level, params.wavelet_name)
        band_config = default_band_table(2 ** params.wpt_level, params.fs, params.material.thickness_m * 1000.0, params.default_mode)
        band_config["EnergyRatio"] = energy_ratio
        band_config, lamb = update_band_velocity_by_lamb(band_config, params.material)
        out = process_ae_wpt_localization_toa(X, subbands, energy_ratio, params, band_config)
        names = self.read_sensor_names()
        out.update({
            "X_raw": X_raw,
            "X_preprocessed": X,
            "subbands": subbands,
            "energyRatio": energy_ratio,
            "params": params,
            "bandConfig": band_config,
            "lamb": lamb,
            "elapsed_s": time.perf_counter() - t0,
            "target_xy": self.read_target_xy(),
            "event_seq": int(event.event_seq),
            "active_channel_indices": active_idx,
            "selected_channel_indices": selected_idx,
            "selected_channel_labels": [f"CH{i + 1}" for i in selected_idx],
            "selected_sensor_names": [names[i] for i in selected_idx],
            "ref_global_channel": selected_idx[int(params.ref_channel) - 1] + 1,
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
            trig = int(meta.get("trigger_offset", data.get("trigger_offset", samples_full.shape[0] // 4))) if isinstance(meta, dict) else int(samples_full.shape[0] // 4)
            params.event.trigger_index = trig
            params.event.min_pick_pre_samples = None
        except Exception:
            params.event.trigger_index = int(samples_full.shape[0] // 4)
            params.event.min_pick_pre_samples = None
        t0 = time.perf_counter()
        X_raw = samples.copy()
        # No band-pass filtering: only de-mean/std normalization inside preprocess_signals.
        # This avoids filter edge transients at the start of the AE frame.
        X = preprocess_signals(X_raw, params.fs, params.filter_low_hz, params.filter_high_hz)
        subbands, energy_ratio = compute_wpt_subband_energy(X, params.wpt_level, params.wavelet_name)
        band_config = default_band_table(2 ** params.wpt_level, params.fs, params.material.thickness_m * 1000.0, params.default_mode)
        band_config["EnergyRatio"] = energy_ratio
        band_config, lamb = update_band_velocity_by_lamb(band_config, params.material)
        out = process_ae_wpt_localization_toa(X, subbands, energy_ratio, params, band_config)
        names = list(data.get("sensor_names", self.read_sensor_names()))
        if len(names) < 16:
            names = self.read_sensor_names()
        out.update({
            "X_raw": X_raw,
            "X_preprocessed": X,
            "subbands": subbands,
            "energyRatio": energy_ratio,
            "params": params,
            "bandConfig": band_config,
            "lamb": lamb,
            "elapsed_s": time.perf_counter() - t0,
            "target_xy": target_xy,
            "event_seq": int(data.get("event_seq", -1)),
            "active_channel_indices": active_idx,
            "selected_channel_indices": selected_idx,
            "selected_channel_labels": [f"CH{i + 1}" for i in selected_idx],
            "selected_sensor_names": [names[i] if i < len(names) else f"S{i+1}" for i in selected_idx],
            "ref_global_channel": selected_idx[int(params.ref_channel) - 1] + 1,
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
        params: LocalizationParams = out["params"]  # type: ignore[assignment]
        band_results = out.get("bandResults")
        n_valid = int(out.get("nValid", 0))
        lines = [
            f"event_seq: {out.get('event_seq')}",
            f"Estimated X / m: {pos[0]:.6f}",
            f"Estimated Y / m: {pos[1]:.6f}",
            f"Actual X / m: {target[0]:.6f}",
            f"Actual Y / m: {target[1]:.6f}",
            f"Error / m: {err:.6f}",
            f"Valid Subbands: {n_valid}",
            f"Elapsed / s: {float(out.get('elapsed_s', np.nan)):.3f}",
            f"fs/MHz: {params.fs / 1e6:.3f}",
            f"Selected Channel Count: {len(out.get('selected_channel_indices', []))}",
            f"Selected Channels: {', '.join(out.get('selected_channel_labels', []))}",
            f"Reference Channel: CH{int(out.get('ref_global_channel', params.ref_channel))}",
            f"WPT Level: {params.wpt_level}",
            f"Wavelet: {params.wavelet_name}",
            f"Sensor Coordinates:",
        ]
        selected_labels = out.get("selected_channel_labels", [])
        selected_names = out.get("selected_sensor_names", [])
        for i, p in enumerate(params.sensor_xy, start=1):
            ch_label = selected_labels[i - 1] if i - 1 < len(selected_labels) else f"CH{i}"
            name = selected_names[i - 1] if i - 1 < len(selected_names) else f"S{i}"
            lines.append(f"  {ch_label} {name}: ({p[0]:.4f}, {p[1]:.4f})")
        if band_results is not None:
            try:
                # Show the top valid bands by weight.
                T = band_results
                valid = T[T["Valid"]].sort_values("Weight", ascending=False).head(6)
                lines.append("Top valid bands:")
                if len(valid) == 0:
                    lines.append("  none")
                else:
                    for _, r in valid.iterrows():
                        lines.append(
                            f"  B{int(r['Band']):02d}: x={r['X_m']:.4f}, y={r['Y_m']:.4f}, "
                            f"v={r['Velocity_mps']:.1f}, res={r['Residual_s']:.2e}, w={r['Weight']:.2e}"
                        )
            except Exception:
                pass
        self._set_text(self.loc_text, "\n".join(lines))
        self._log(f"Localization OK: x={pos[0]:.5f} m, y={pos[1]:.5f} m, error={err:.5f} m, valid_bands={n_valid}")


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
        params: LocalizationParams = out["params"]  # type: ignore[assignment]
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
        # Draw a clear frame around the plate area so the predicted point is
        # visually constrained inside the physical board boundary.
        plate_box = Rectangle(
            (0.0, 0.0),
            float(plate_xy[0]),
            float(plate_xy[1]),
            fill=False,
            edgecolor=COLOR_PRIMARY_DARK,
            linewidth=1.8,
            linestyle="-",
            label="Plate Boundary",
            zorder=2,
        )
        ax.add_patch(plate_box)
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
        ax.set_title("Predicted AE Source Localization Result", fontname=FONT_CN, fontsize=FONT_CHART_TITLE_SIZE, color=COLOR_PRIMARY_DARK)
        ax.legend(prop={"family": FONT_CN, "size": FONT_CHART_LABEL_SIZE}, frameon=True, facecolor=COLOR_WHITE, edgecolor=COLOR_BORDER)
        for label in ax.get_xticklabels() + ax.get_yticklabels():
            label.set_fontname("Times New Roman")
            label.set_fontsize(9)
        self.fig_loc.tight_layout(pad=1.0)
        self.canvas_loc.draw_idle()

    def _plot_energy(self, out: Dict[str, object]) -> None:
        if not hasattr(self, "ax_energy") or not hasattr(self, "canvas_energy"):
            return
        energy = np.asarray(out.get("energyRatio", []), dtype=float)
        if energy.size == 0:
            return
        bands = np.arange(1, energy.size + 1)
        ax = self.ax_energy
        ax.clear()
        self._style_axis(ax)
        ax.grid(True, axis="y", color=COLOR_GRID, linewidth=0.45)
        ax.bar(bands, energy, width=0.82, color=MPL_BAR, edgecolor=COLOR_PRIMARY_DARK, linewidth=0.25)
        ax.set_xlim(0.3, energy.size + 0.7)
        ax.set_xlabel("Subband Index", fontname=FONT_CN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
        ax.set_ylabel("Energy Ratio", fontname=FONT_CN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
        ax.set_title("Subband Energy Distribution", fontname=FONT_CN, fontsize=FONT_CHART_TITLE_SIZE, color=COLOR_PRIMARY_DARK)
        for label in ax.get_xticklabels() + ax.get_yticklabels():
            label.set_fontname("Times New Roman")
            label.set_fontsize(8)
        self.fig_energy.tight_layout(pad=0.9)
        self.canvas_energy.draw_idle()

    def _plot_reference_signal(self, out: Dict[str, object]) -> None:
        """Plot four selected channels vertically with AIC results.

        The FPGA event trigger is expected near ``event.frame.trigger_offset``
        (for example sample index 2048).  The AIC curve is recomputed for the
        displayed subband and shown together with the raw channel waveform.  The
        The full 8192-point event frame is displayed.  The AIC curve is
        calculated inside the trigger-anchored search window, while the waveform
        itself is shown over the complete frame so that the global trend can be
        inspected.  The first arrival is allowed to occur before the threshold
        trigger point.
        """
        params: LocalizationParams = out["params"]  # type: ignore[assignment]
        X_raw = np.asarray(out.get("X_raw", np.empty((0, 0))), dtype=float)
        if X_raw.size == 0:
            return

        n_samples, n_ch = X_raw.shape
        n_plot = min(n_ch, 4)
        selected_labels = list(out.get("selected_channel_labels", [f"CH{i + 1}" for i in range(n_ch)]))
        selected_names = list(out.get("selected_sensor_names", [f"S{i + 1}" for i in range(n_ch)]))
        x_idx = np.arange(n_samples, dtype=float)

        T = out.get("bandResults")
        band_idx = self._choose_aic_annotation_band(out)
        band_row = None
        if T is not None and band_idx is not None:
            try:
                band_row = T.iloc[int(band_idx)]
            except Exception:
                band_row = None

        subbands = np.asarray(out.get("subbands", np.empty((0, 0, 0))), dtype=float)
        event_diag = out.get("eventDiag", {}) or {}
        try:
            idx_win = np.asarray(event_diag.get("idxWindow", [np.nan, np.nan]), dtype=float)
            idx1 = int(max(0, min(n_samples - 1, round(float(idx_win[0]))))) if np.isfinite(idx_win[0]) else 0
            idx2 = int(max(0, min(n_samples - 1, round(float(idx_win[1]))))) if np.isfinite(idx_win[1]) else n_samples - 1
        except Exception:
            idx1, idx2 = 0, n_samples - 1
        if idx2 <= idx1:
            idx1, idx2 = 0, n_samples - 1

        trig_idx = getattr(params.event, "trigger_index", None)
        if trig_idx is None or not np.isfinite(trig_idx):
            try:
                trig_idx = float(event_diag.get("idxCenter", n_samples // 4))
            except Exception:
                trig_idx = n_samples // 4
        trig_idx = int(max(0, min(n_samples - 1, round(float(trig_idx)))))
        min_pick_idx = event_diag.get("minPickIdx", None)

        # Recreate a clean 4-row layout every time, avoiding the old 4x4 layout.
        self.fig_ref.clear()
        self.axes_aic = [self.fig_ref.add_subplot(4, 1, i + 1) for i in range(4)]
        axes = self.axes_aic

        # Display y limits from only the selected four raw channels.
        finite = X_raw[:, :n_plot][np.isfinite(X_raw[:, :n_plot])]
        if finite.size > 0:
            q = np.nanpercentile(np.abs(finite), 99.5)
            ylim = max(float(q) * 1.30, 1.0)
        else:
            ylim = 1.0

        # Always display the full event frame instead of zooming into the AIC
        # window.  This makes it clear where the AIC pick lies relative to all
        # 8192 samples and to the FPGA threshold trigger point.
        x_left = 0
        x_right = n_samples - 1

        for i, ax in enumerate(axes):
            ax.clear()
            self._style_axis(ax)
            if i >= n_plot:
                ax.set_visible(False)
                continue
            ax.set_visible(True)

            y_raw = X_raw[:, i]
            ax.plot(x_idx, y_raw, linewidth=0.65, color=MPL_LINE, label="Time-Domain Signal" if i == 0 else None)
            ax.axvline(trig_idx, linestyle=":", linewidth=1.0, color=COLOR_PRIMARY_DARK, alpha=0.85, label="Threshold Trigger Point" if i == 0 else None)
            ax.axvline(idx1, linestyle="-.", linewidth=0.75, color="#7A7A7A", alpha=0.75, label="AIC Search Window" if i == 0 else None)
            ax.axvline(idx2, linestyle="-.", linewidth=0.75, color="#7A7A7A", alpha=0.75)
            ax.set_xlim(x_left, x_right)
            ax.set_ylim(-ylim, ylim)
            ax.grid(True, color=COLOR_GRID, linewidth=0.45)

            label = selected_labels[i] if i < len(selected_labels) else f"CH{i + 1}"
            name = selected_names[i] if i < len(selected_names) else ""
            title = f"{label} {name}".strip()

            idx_final = toa_s = aic_min = quality = np.nan
            method = ""
            if band_row is not None:
                c = i + 1  # relative channel number in localization matrix
                idx_final = self._toa_row_value(band_row, f"AIC_FinalIdx_CH{c}")
                toa_s = self._toa_row_value(band_row, f"TOA_CH{c}_s")
                aic_min = self._toa_row_value(band_row, f"AIC_Min_CH{c}")
                quality = self._toa_row_value(band_row, f"TOAQuality_CH{c}")
                try:
                    method = str(band_row.get(f"TOAMethod_CH{c}", ""))
                except Exception:
                    method = ""

            # Plot AIC calculation result for the same subband used for annotation.
            if band_idx is not None and subbands.ndim == 3 and band_idx < subbands.shape[2] and i < subbands.shape[1]:
                y_aic_src = subbands[:, i, int(band_idx)]
                idx_abs, aic = local_aic_curve(y_aic_src, idx1, idx2, min_pick_idx=min_pick_idx)
                finite_aic = np.isfinite(aic)
                if idx_abs.size > 0 and np.any(finite_aic):
                    a = aic.copy()
                    amin = np.nanmin(a[finite_aic])
                    amax = np.nanmax(a[finite_aic])
                    if np.isfinite(amax - amin) and (amax - amin) > 0:
                        a_norm = ((a - amin) / (amax - amin) * 2.0 - 1.0) * (0.78 * ylim)
                    else:
                        a_norm = np.zeros_like(a)
                    ax.plot(idx_abs, a_norm, linewidth=0.75, color=MPL_LINE_2, alpha=0.90, label="AIC Result (Normalized)" if i == 0 else None)

            if np.isfinite(idx_final):
                idx_final_f = float(idx_final)
                ax.axvline(idx_final_f, linestyle="--", linewidth=1.1, color=MPL_TARGET, alpha=0.98, label="AIC Arrival Time" if i == 0 else None)
                try:
                    y_marker = np.interp(idx_final_f, x_idx, y_raw)
                except Exception:
                    y_marker = 0.0
                ax.plot([idx_final_f], [y_marker], marker="o", markersize=4.0, color=MPL_TARGET)
                txt = (
                    f"B{(band_idx or 0) + 1:02d}  idx={idx_final_f:.1f}\n"
                    f"TOA={toa_s*1e6:.2f} μs  AICmin={aic_min:.2e}\n"
                    f"Q={quality:.2f}  {method}"
                )
                ax.text(
                    0.012, 0.96, txt,
                    transform=ax.transAxes,
                    va="top", ha="left",
                    fontsize=7.0,
                    fontname=FONT_EN,
                    color=COLOR_PRIMARY_DARK,
                    bbox=dict(boxstyle="round,pad=0.20", facecolor="white", edgecolor=COLOR_BORDER, alpha=0.86),
                )
            else:
                ax.text(
                    0.012, 0.96, "AIC TOA: NaN",
                    transform=ax.transAxes,
                    va="top", ha="left",
                    fontsize=7.0,
                    fontname=FONT_EN,
                    color=MPL_TARGET,
                    bbox=dict(boxstyle="round,pad=0.20", facecolor="white", edgecolor=COLOR_BORDER, alpha=0.86),
                )

            ax.set_title(title, fontname=FONT_EN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_PRIMARY_DARK, pad=2)
            if i == n_plot - 1:
                ax.set_xlabel("Sample Index", fontname=FONT_CN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
            ax.set_ylabel("Amplitude / code", fontname=FONT_CN, fontsize=FONT_CHART_LABEL_SIZE, color=COLOR_TEXT)
            for tick in ax.get_xticklabels() + ax.get_yticklabels():
                tick.set_fontname(FONT_EN)
                tick.set_fontsize(7.0)
            if i == 0:
                ax.legend(prop={"family": FONT_CN, "size": 7}, loc="upper right", frameon=True, facecolor=COLOR_WHITE, edgecolor=COLOR_BORDER)

        if band_idx is not None:
            title = f"Full-Frame AIC Arrival-Time Annotation: Subband B{band_idx + 1:02d}, trigger idx={trig_idx}, AIC window=[{idx1},{idx2}]"
        else:
            title = f"Full-Frame AIC Arrival-Time Annotation: no available subband, trigger idx={trig_idx}, AIC window=[{idx1},{idx2}]"
        self.fig_ref.suptitle(title, fontname=FONT_CN, fontsize=FONT_CHART_TITLE_SIZE, color=COLOR_PRIMARY_DARK, y=0.995)
        self.fig_ref.tight_layout(rect=[0.0, 0.0, 1.0, 0.955], pad=0.55)
        self.canvas_ref.draw_idle()

    def _update_energy_table(self, out: Dict[str, object]) -> None:
        if not hasattr(self, "energy_tree"):
            return
        for item in self.energy_tree.get_children():
            self.energy_tree.delete(item)
        T = out.get("bandResults")
        if T is None:
            return
        try:
            for _, r in T.iterrows():
                self.energy_tree.insert("", tk.END, values=(
                    int(r["Band"]),
                    f"{float(r['Fmin_Hz'])/1e3:.1f}",
                    f"{float(r['Fmax_Hz'])/1e3:.1f}",
                    f"{float(r['EnergyRatio']):.4g}",
                    f"{float(r['Velocity_mps']):.1f}" if np.isfinite(float(r['Velocity_mps'])) else "NaN",
                    "Yes" if bool(r["Valid"]) else "No",
                    str(r["RejectReason"]),
                ))
        except Exception as exc:
            self._log(f"Energy table update failed: {exc}")

    def _update_band_table(self, out: Dict[str, object]) -> None:
        if not hasattr(self, "band_tree"):
            return
        for item in self.band_tree.get_children():
            self.band_tree.delete(item)
        T = out.get("bandResults")
        if T is None:
            return
        try:
            for _, r in T.iterrows():
                self.band_tree.insert("", tk.END, values=(
                    int(r["Band"]),
                    f"{float(r['EnergyRatio']):.4g}",
                    f"{float(r['Velocity_mps']):.1f}" if np.isfinite(float(r['Velocity_mps'])) else "NaN",
                    f"{float(r['X_m']):.5f}" if np.isfinite(float(r['X_m'])) else "NaN",
                    f"{float(r['Y_m']):.5f}" if np.isfinite(float(r['Y_m'])) else "NaN",
                    f"{float(r['Residual_s']):.2e}" if np.isfinite(float(r['Residual_s'])) else "NaN",
                    f"{float(r['Weight']):.3g}" if np.isfinite(float(r['Weight'])) else "NaN",
                    "Yes" if bool(r["Valid"]) else "No",
                    str(r["RejectReason"]),
                ))
        except Exception as exc:
            self._log(f"Band table update failed: {exc}")

    def _display_localization_outputs(self, out: Dict[str, object]) -> None:
        self._update_loc_info(out)
        self._plot_reference_signal(out)
        self._plot_localization(out)
        if SHOW_SUBBAND_DETAILS_IN_ENGLISH:
            self._plot_energy(out)
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
