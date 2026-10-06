# -*- coding: utf-8 -*-
"""
batch_ar_aic_localization_compare_v7.py

基于 AR-AIC 到时拾取的声发射批量定位与误差对比脚本。

适用场景：
    - 数据文件位于 E:\\AE_DATA 或其它目录；
    - 文件名包含真实坐标，例如 4channel_0.17_0.269.csv；
    - 同名 JSON 中保存采样率、trigger_offset、传感器坐标、通道信息；
    - AE 事件门限触发点通常在 2048 点附近，但真实首达可能早于 2048；
    - 使用 WPT 子波包 + Lamb/常数波速 + AR-AIC TOA + TDOA 定位；
    - 输出预计坐标、真实坐标和误差对比。

基本用法：
    E:\\1.tools\\py\\python.exe batch_ar_aic_localization_compare_v7.py --data-dir E:\\AE_DATA

常用参数：
    --loc-channels auto        # auto/4/8/12/16，默认按文件名 Nchannel 自动选择
    --wpt-level 4              # WPT 层数
    --energy-threshold 0.001   # 子波包能量阈值
    --aic-pre-us 180           # AR-AIC 搜索窗：触发点前多少 us
    --aic-post-us 80           # AR-AIC 搜索窗：触发点后多少 us
    --ar-order 4               # AR 阶数
    --ar-signal raw            # raw/envelope/energy/tkeo
    --velocity-mode lamb       # lamb/constant
    --default-velocity 2500    # Lamb 失败或 constant 模式时使用

输出：
    E:\\AE_DATA\\ar_aic_localization_compare_v7\\
        ar_aic_localization_comparison.csv
        ar_aic_localization_summary.json
        ar_aic_failures.csv
        per_file_band_results/*.csv
        plots/ar_aic_location_comparison.png
        plots/ar_aic_error_hist.png
        plots/ar_aic_error_by_file.png

说明：
    1. AR-AIC 的核心是用 AR 模型残差方差代替普通 AIC 中的原始方差，
       AIC_AR(k)=n1*log(sigma_AR1^2)+n2*log(sigma_AR2^2)+常数项。
    2. 由于 2048 点通常是门限越过点，不是真实首达点，脚本默认允许在触发点前搜索。
    3. 若没有安装 PyWavelets，将自动退化为 FFT 子带重构，建议正式使用时安装 PyWavelets。
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np
import pandas as pd

try:
    from scipy import signal, optimize
    from scipy.linalg import toeplitz
except Exception as exc:  # pragma: no cover
    raise ImportError("需要 scipy。建议安装：pip install scipy==1.11.4") from exc

try:
    import pywt  # type: ignore
except Exception:  # pragma: no cover
    pywt = None

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except Exception:  # pragma: no cover
    plt = None

EPS = np.finfo(float).eps

FILENAME_RE = re.compile(
    r"(?P<n>\d+)\s*channel[_\-](?P<x>[-+]?\d+(?:\.\d+)?)[_\-](?P<y>[-+]?\d+(?:\.\d+)?)",
    re.IGNORECASE,
)


@dataclass
class MaterialParams:
    E: float = 70.0e9
    nu: float = 0.33
    rho: float = 2700.0
    thickness_m: float = 4.0e-3


@dataclass
class BatchParams:
    fs_default: float = 2.0e6
    plate_x_m: float = 0.50
    plate_y_m: float = 0.40
    wpt_level: int = 4
    wavelet_name: str = "db6"
    energy_threshold: float = 0.001
    ref_channel: int = 4
    loc_channels: str = "auto"
    trigger_index_default: int = 2048
    aic_pre_us: float = 180.0
    aic_post_us: float = 80.0
    ar_order: int = 4
    ar_signal: str = "raw"  # raw/envelope/energy/tkeo
    ar_min_segment: int = 64
    ar_candidate_step: int = 1
    toa_quality_threshold: float = 3.0
    residual_threshold_s: float = 8.0e-6
    velocity_margin: float = 1.35
    min_valid_sensors: int = 3
    velocity_mode: str = "lamb"  # lamb/constant
    default_velocity_mps: float = 2500.0
    lamb_mode: str = "A0"
    save_aic_debug: bool = False
    material: MaterialParams = None  # initialized in __post_init__

    def __post_init__(self):
        if self.material is None:
            self.material = MaterialParams()


# -----------------------------------------------------------------------------
# File and metadata helpers
# -----------------------------------------------------------------------------

def parse_true_xy_from_filename(csv_path: Path) -> Tuple[Optional[int], Optional[Tuple[float, float]]]:
    m = FILENAME_RE.search(csv_path.stem)
    if not m:
        return None, None
    return int(m.group("n")), (float(m.group("x")), float(m.group("y")))


def load_json_sidecar(csv_path: Path) -> Dict[str, Any]:
    jp = csv_path.with_suffix(".json")
    if not jp.exists():
        return {}
    with jp.open("r", encoding="utf-8-sig") as f:
        return json.load(f)


def channel_label_to_number(label: str) -> Optional[int]:
    m = re.search(r"CH\s*0*(\d{1,2})", str(label), re.IGNORECASE)
    if not m:
        return None
    ch = int(m.group(1))
    return ch if 1 <= ch <= 16 else None


def channel_mask_to_channels(mask_value: Any) -> List[int]:
    if mask_value is None:
        return []
    try:
        if isinstance(mask_value, str):
            s = mask_value.strip().lower()
            val = int(s, 16) if s.startswith("0x") else int(s, 16)
        else:
            val = int(mask_value)
    except Exception:
        return []
    return [i + 1 for i in range(16) if (val >> i) & 1]


def format_channels(chs: Sequence[int]) -> str:
    return ",".join(f"CH{int(c):02d}" for c in chs)


def read_waveform_csv(csv_path: Path) -> Tuple[pd.DataFrame, Dict[int, str]]:
    df = pd.read_csv(csv_path, encoding="utf-8-sig")
    if df.empty:
        raise ValueError("CSV 文件为空")
    ch_col_map: Dict[int, str] = {}
    for col in df.columns:
        ch = channel_label_to_number(str(col))
        if ch is not None:
            ch_col_map[ch] = str(col)
    if not ch_col_map:
        # fallback: use numeric columns except index/time columns
        numeric_cols: List[str] = []
        for col in df.columns:
            name = str(col).strip().lower()
            if name in {"sample_index", "index", "time_us", "time", "t"}:
                continue
            try:
                pd.to_numeric(df[col].iloc[: min(20, len(df))])
                numeric_cols.append(str(col))
            except Exception:
                pass
        for i, col in enumerate(numeric_cols[:16], start=1):
            ch_col_map[i] = col
    if not ch_col_map:
        raise ValueError("未找到 CHxx 通道列，也无法从数值列推断")
    return df, ch_col_map


def infer_active_channels(meta: Dict[str, Any], ch_col_map: Dict[int, str]) -> List[int]:
    saved = meta.get("saved_channels") or meta.get("channels") or []
    active: List[int] = []
    if isinstance(saved, list):
        for item in saved:
            ch = channel_label_to_number(str(item))
            if ch is not None:
                active.append(ch)
    if not active:
        active = channel_mask_to_channels(meta.get("channel_mask_hex") or meta.get("channel_mask"))
    if not active:
        active = sorted(ch_col_map.keys())
    active = [ch for ch in active if ch in ch_col_map]
    return sorted(dict.fromkeys(active))


def get_sensor_xy_all(meta: Dict[str, Any]) -> np.ndarray:
    keys = [
        "sensor_xy_m_all_ch1_to_ch16",
        "sensor_xy_all_ch1_to_ch16",
        "sensor_xy_m_all",
        "sensor_xy_m",
    ]
    arr = None
    for k in keys:
        if k in meta:
            arr = meta[k]
            break
    out = np.zeros((16, 2), dtype=float)
    if arr is None:
        return out
    a = np.asarray(arr, dtype=float)
    if a.ndim == 2 and a.shape[1] >= 2:
        n = min(16, a.shape[0])
        out[:n, :] = a[:n, :2]
    return out


def select_localization_channels(active: Sequence[int], filename_n: Optional[int], requested: str) -> List[int]:
    active = sorted(dict.fromkeys(int(x) for x in active))
    if not active:
        raise ValueError("没有有效采样通道")
    req = str(requested).lower().strip()
    if req == "auto":
        n = int(filename_n) if filename_n is not None else len(active)
    else:
        n = int(req)
    if n not in (4, 8, 12, 16):
        raise ValueError("定位通道数只能是 auto/4/8/12/16")
    if n > len(active):
        raise ValueError(f"定位通道数 {n} 大于当前有效采样通道数 {len(active)}")
    return active[:n]


def load_waveform_for_channels(csv_path: Path, channels: Sequence[int]) -> Tuple[np.ndarray, Dict[str, Any]]:
    meta = load_json_sidecar(csv_path)
    df, ch_col_map = read_waveform_csv(csv_path)
    missing = [ch for ch in channels if ch not in ch_col_map]
    if missing:
        raise ValueError(f"CSV 缺少通道列：{format_channels(missing)}")
    X = np.column_stack([pd.to_numeric(df[ch_col_map[ch]], errors="coerce").to_numpy(dtype=float) for ch in channels])
    finite = np.all(np.isfinite(X), axis=1)
    X = X[finite, :]
    if X.shape[0] < 256:
        raise ValueError("有效数据点数过少")
    meta["_csv_rows"] = int(X.shape[0])
    return X, meta


# -----------------------------------------------------------------------------
# Preprocess and subbands
# -----------------------------------------------------------------------------

def preprocess_no_filter(X: np.ndarray) -> np.ndarray:
    X = np.asarray(X, dtype=float)
    X = X - np.nanmean(X, axis=0)
    std = np.nanstd(X, axis=0)
    std[~np.isfinite(std) | (std <= 0)] = 1.0
    return X / std


def wpt_subband_signals(X: np.ndarray, level: int, wavelet_name: str) -> np.ndarray:
    """Return subbands with shape (N, C, 2**level).

    Preferred path uses PyWavelets WaveletPacket.  If PyWavelets is unavailable,
    falls back to simple FFT rectangular subbands so the batch script can still run.
    """
    X = np.asarray(X, dtype=float)
    n, chn = X.shape
    nb = 2 ** int(level)
    sub = np.zeros((n, chn, nb), dtype=float)
    if pywt is not None:
        for ch in range(chn):
            wp = pywt.WaveletPacket(data=X[:, ch], wavelet=wavelet_name, mode="symmetric", maxlevel=level)
            nodes = wp.get_level(level, order="freq")
            for k, node in enumerate(nodes):
                rec_wp = pywt.WaveletPacket(data=None, wavelet=wavelet_name, mode="symmetric")
                rec_wp[node.path] = node.data
                y = rec_wp.reconstruct(update=False)
                y = np.asarray(y, dtype=float).ravel()
                if y.size >= n:
                    y = y[:n]
                else:
                    y = np.pad(y, (0, n - y.size), mode="constant")
                sub[:, ch, k] = y
        return sub

    # Fallback: FFT bandpass decomposition over [0, fs/2] normalized bins.
    # This is not identical to WPT, but keeps the script executable if pywt is missing.
    Xf = np.fft.rfft(X, axis=0)
    freqs = np.fft.rfftfreq(n, d=1.0)
    nyq = 0.5
    edges = np.linspace(0.0, nyq, nb + 1)
    for k in range(nb):
        mask = (freqs >= edges[k]) & (freqs < edges[k + 1] if k < nb - 1 else freqs <= edges[k + 1])
        Yf = np.zeros_like(Xf)
        Yf[mask, :] = Xf[mask, :]
        y = np.fft.irfft(Yf, n=n, axis=0)
        sub[:, :, k] = y
    return sub


def compute_subband_energy(subbands: np.ndarray) -> np.ndarray:
    e = np.sum(subbands ** 2, axis=(0, 1))
    return e / (np.sum(e) + EPS)


def default_band_table(n_bands: int, fs: float, thickness_mm: float, default_mode: str) -> pd.DataFrame:
    rows = []
    nyq = fs / 2.0
    for k in range(n_bands):
        fmin = k * nyq / n_bands
        fmax = (k + 1) * nyq / n_bands
        fc = 0.5 * (fmin + fmax)
        fd = (fc / 1e6) * thickness_mm
        rows.append({
            "Use": True,
            "Band": k + 1,
            "Fmin_Hz": fmin,
            "Fmax_Hz": fmax,
            "Fc_Hz": fc,
            "fd_MHz_mm": fd,
            "Mode": default_mode,
            "Velocity_mps": np.nan,
        })
    return pd.DataFrame(rows)


# -----------------------------------------------------------------------------
# Lamb velocity calculation, adapted from the existing V6/V7 style implementation
# -----------------------------------------------------------------------------

def aluminum_bulk_speeds(E: float, nu: float, rho: float) -> Tuple[float, float]:
    cL = math.sqrt(E * (1 - nu) / (rho * (1 + nu) * (1 - 2 * nu)))
    cT = math.sqrt(E / (2 * rho * (1 + nu)))
    return cL, cT


def lamb_eq_real(c: float, xi: float, cL: float, cT: float, mode_type: str) -> float:
    K = math.pi * xi / c
    mode = mode_type.upper()
    if mode == "S":
        if c < cT:
            a = math.pi * xi * math.sqrt(1 / c ** 2 - 1 / cL ** 2)
            b = math.pi * xi * math.sqrt(1 / c ** 2 - 1 / cT ** 2)
            D = (b ** 2 + K ** 2) ** 2
            return math.tanh(b) / math.tanh(a) - (4 * K ** 2 * a * b) / D
        if c < cL:
            a = math.pi * xi * math.sqrt(1 / c ** 2 - 1 / cL ** 2)
            q = math.pi * xi * math.sqrt(1 / cT ** 2 - 1 / c ** 2)
            D = (q ** 2 - K ** 2) ** 2
            return math.tan(q) / math.tanh(a) - (4 * K ** 2 * a * q) / D
        p = math.pi * xi * math.sqrt(1 / cL ** 2 - 1 / c ** 2)
        q = math.pi * xi * math.sqrt(1 / cT ** 2 - 1 / c ** 2)
        D = (q ** 2 - K ** 2) ** 2
        return math.tan(q) / math.tan(p) + (4 * K ** 2 * p * q) / D
    if mode == "A":
        if c < cT:
            a = math.pi * xi * math.sqrt(1 / c ** 2 - 1 / cL ** 2)
            b = math.pi * xi * math.sqrt(1 / c ** 2 - 1 / cT ** 2)
            D = (b ** 2 + K ** 2) ** 2
            return math.tanh(b) / math.tanh(a) - D / (4 * K ** 2 * a * b)
        if c < cL:
            a = math.pi * xi * math.sqrt(1 / c ** 2 - 1 / cL ** 2)
            q = math.pi * xi * math.sqrt(1 / cT ** 2 - 1 / c ** 2)
            D = (q ** 2 - K ** 2) ** 2
            return math.tan(q) / math.tanh(a) + D / (4 * K ** 2 * a * q)
        p = math.pi * xi * math.sqrt(1 / cL ** 2 - 1 / c ** 2)
        q = math.pi * xi * math.sqrt(1 / cT ** 2 - 1 / c ** 2)
        D = (q ** 2 - K ** 2) ** 2
        return math.tan(q) / math.tan(p) + D / (4 * K ** 2 * p * q)
    raise ValueError("mode_type must be S or A")


def find_roots_one_fd(xi: float, cL: float, cT: float, cmin: float, cmax: float, mode_type: str) -> np.ndarray:
    roots: List[float] = []
    regions = [(cmin, cT - 1.0, 700), (cT + 1.0, cL - 1.0, 700), (cL + 1.0, cmax, 900)]
    for a, b, n in regions:
        if b <= a:
            continue
        cgrid = np.linspace(a, b, n)
        vals = np.full(cgrid.shape, np.nan)
        for i, c in enumerate(cgrid):
            try:
                vals[i] = lamb_eq_real(float(c), xi, cL, cT, mode_type)
            except Exception:
                vals[i] = np.nan
        valid = np.isfinite(vals[:-1]) & np.isfinite(vals[1:]) & (vals[:-1] * vals[1:] < 0)
        for idx in np.flatnonzero(valid):
            c1, c2 = cgrid[idx], cgrid[idx + 1]
            try:
                sol = optimize.root_scalar(lambda cc: lamb_eq_real(cc, xi, cL, cT, mode_type), bracket=[c1, c2], method="brentq")
                r = float(sol.root)
                if cmin < r < cmax:
                    roots.append(r)
            except Exception:
                pass
    roots = sorted(roots)
    unique: List[float] = []
    for r in roots:
        if not unique or abs(r - unique[-1]) > 3.0:
            unique.append(r)
    return np.asarray(unique, dtype=float)


def track_modes(root_cell: List[np.ndarray], nmode: int, tol_track: float) -> np.ndarray:
    n = len(root_cell)
    modes = np.full((nmode, n), np.nan)
    next_mode = 0
    for i, roots in enumerate(root_cell):
        roots = np.sort(np.asarray(roots, dtype=float))
        if roots.size == 0:
            continue
        used = np.zeros(roots.size, dtype=bool)
        if i == 0:
            nnew = min(roots.size, nmode)
            modes[:nnew, i] = roots[:nnew]
            next_mode = nnew
            continue
        pred = modes[:, i - 1].copy()
        if i >= 2:
            prev2 = modes[:, i - 2]
            ok = np.isfinite(pred) & np.isfinite(prev2)
            pred[ok] = pred[ok] + (pred[ok] - prev2[ok])
        pairs = []
        for m in range(nmode):
            if np.isfinite(pred[m]):
                idx_min = int(np.argmin(np.abs(roots - pred[m])))
                pairs.append((abs(roots[idx_min] - pred[m]), m, idx_min))
        for d, m, r in sorted(pairs, key=lambda t: t[0]):
            if not used[r] and np.isnan(modes[m, i]) and d < tol_track:
                modes[m, i] = roots[r]
                used[r] = True
        for r in range(roots.size):
            if not used[r] and next_mode < nmode:
                modes[next_mode, i] = roots[r]
                next_mode += 1
    return modes


def calc_group_velocity(cp: np.ndarray, fd: np.ndarray) -> np.ndarray:
    cg = np.full_like(cp, np.nan, dtype=float)
    for m in range(cp.shape[0]):
        idx = np.flatnonzero(np.isfinite(cp[m, :]))
        if idx.size < 3:
            continue
        x = fd[idx]
        y = cp[m, idx]
        dydx = np.gradient(y, x)
        denom = y - x * dydx
        with np.errstate(divide="ignore", invalid="ignore"):
            cgtmp = y ** 2 / denom
        cgtmp[(~np.isfinite(cgtmp)) | (cgtmp <= 0) | (cgtmp > 2e4)] = np.nan
        cg[m, idx] = cgtmp
    return cg


def interp_valid(x: np.ndarray, y: np.ndarray, xq: float) -> float:
    valid = np.isfinite(x) & np.isfinite(y) & (y > 0)
    if np.count_nonzero(valid) < 2:
        return np.nan
    xv = x[valid]
    yv = y[valid]
    yq = np.interp(xq, xv, yv, left=np.nan, right=np.nan)
    if not np.isfinite(yq):
        if xq < xv[0]:
            yq = yv[0]
        else:
            yq = yv[-1]
    return float(yq) if np.isfinite(yq) and 0 < yq < 2e4 else np.nan


def update_band_velocity_by_lamb(T: pd.DataFrame, material: MaterialParams, fallback_v: float) -> pd.DataFrame:
    T = T.copy()
    try:
        cL, cT = aluminum_bulk_speeds(material.E, material.nu, material.rho)
        fd_targets = T["fd_MHz_mm"].to_numpy(dtype=float)
        positive = fd_targets[fd_targets > 0]
        if positive.size == 0:
            raise ValueError("no positive fd")
        fd_min = max(0.02, 0.80 * np.min(positive))
        fd_max = max(0.05, 1.10 * np.max(fd_targets))
        fd_grid = np.linspace(fd_min, fd_max, 180)
        xi_grid = fd_grid * 1e3
        roots_s = [find_roots_one_fd(xi, cL, cT, 50.0, 12000.0, "S") for xi in xi_grid]
        roots_a = [find_roots_one_fd(xi, cL, cT, 50.0, 12000.0, "A") for xi in xi_grid]
        cp_s = track_modes(roots_s, 4, 1200.0)
        cp_a = track_modes(roots_a, 4, 1200.0)
        cg_s = calc_group_velocity(cp_s, fd_grid)
        cg_a = calc_group_velocity(cp_a, fd_grid)
        vals = []
        for mode, fd in zip(T["Mode"].astype(str).tolist(), fd_targets):
            mu = mode.upper().strip()
            if mu == "S0":
                vals.append(interp_valid(fd_grid, cg_s[0], fd))
            elif mu == "A0":
                vals.append(interp_valid(fd_grid, cg_a[0], fd))
            elif mu == "S1":
                vals.append(interp_valid(fd_grid, cg_s[1], fd))
            elif mu == "A1":
                vals.append(interp_valid(fd_grid, cg_a[1], fd))
            else:
                vals.append(np.nan)
        vals = np.asarray(vals, dtype=float)
        vals[(~np.isfinite(vals)) | (vals <= 0)] = fallback_v
        T["Velocity_mps"] = vals
    except Exception:
        T["Velocity_mps"] = fallback_v
    return T


# -----------------------------------------------------------------------------
# AR-AIC TOA picking
# -----------------------------------------------------------------------------

def analytic_envelope(x: np.ndarray) -> np.ndarray:
    return np.abs(signal.hilbert(np.asarray(x, dtype=float).ravel()))


def tkeo(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=float).ravel()
    if x.size < 3:
        return np.zeros_like(x)
    y = np.zeros_like(x)
    y[1:-1] = x[1:-1] ** 2 - x[:-2] * x[2:]
    y[0] = y[1]
    y[-1] = y[-2]
    return y


def transform_for_ar_aic(x: np.ndarray, mode: str) -> np.ndarray:
    x = np.asarray(x, dtype=float).ravel()
    mode = str(mode).lower().strip()
    if mode in {"raw", "原始", "原始信号"}:
        z = x.copy()
    elif mode in {"envelope", "env", "包络"}:
        z = analytic_envelope(x)
    elif mode in {"energy", "能量"}:
        z = x ** 2
    elif mode in {"tkeo", "teager"}:
        z = tkeo(x)
    else:
        z = x.copy()
    z = z - np.nanmean(z)
    return z


def ar_residual_variance_yw(x: np.ndarray, order: int) -> float:
    """Estimate AR residual variance by Yule-Walker equations."""
    x = np.asarray(x, dtype=float).ravel()
    x = x[np.isfinite(x)]
    n = x.size
    p = int(order)
    if n <= p + 4:
        return np.nan
    x = x - np.mean(x)
    if not np.any(np.isfinite(x)) or np.nanstd(x) <= 0:
        return np.nan
    r = np.empty(p + 1, dtype=float)
    for lag in range(p + 1):
        r[lag] = np.dot(x[: n - lag], x[lag:]) / n
    if r[0] <= EPS or not np.isfinite(r[0]):
        return np.nan
    R = toeplitz(r[:p])
    rhs = r[1:p + 1]
    try:
        a = np.linalg.solve(R + np.eye(p) * (EPS * r[0]), rhs)
        sigma2 = r[0] - float(np.dot(a, rhs))
    except Exception:
        return np.nan
    if not np.isfinite(sigma2) or sigma2 <= 0:
        sigma2 = EPS
    return float(sigma2)


def ar_aic_curve(
    x: np.ndarray,
    idx1: int,
    idx2: int,
    order: int = 4,
    min_segment: int = 64,
    step: int = 1,
    ar_signal: str = "raw",
) -> Tuple[np.ndarray, np.ndarray]:
    """Compute AR-AIC curve within [idx1, idx2] inclusive.

    For candidate k, the pre-event segment is xw[:k] and post-event segment is
    xw[k:].  The AR model order is fixed, so the 2p penalty is constant and not
    relevant to argmin, but it is included for completeness.
    """
    x = transform_for_ar_aic(x, ar_signal)
    n_all = x.size
    idx1 = max(0, int(idx1))
    idx2 = min(n_all - 1, int(idx2))
    if idx2 <= idx1:
        return np.array([], dtype=int), np.array([], dtype=float)
    xw = x[idx1:idx2 + 1]
    m = xw.size
    min_seg = int(max(min_segment, order + 8, 8))
    if m < 2 * min_seg + 1:
        return np.arange(idx1, idx2 + 1, dtype=int), np.full(m, np.nan)
    aic = np.full(m, np.nan, dtype=float)
    st = int(max(1, step))
    for k in range(min_seg, m - min_seg + 1, st):
        n1 = k
        n2 = m - k
        v1 = ar_residual_variance_yw(xw[:k], order)
        v2 = ar_residual_variance_yw(xw[k:], order)
        if np.isfinite(v1) and np.isfinite(v2) and v1 > 0 and v2 > 0:
            aic[k] = n1 * math.log(v1 + EPS) + n2 * math.log(v2 + EPS) + 4 * order
    return np.arange(idx1, idx2 + 1, dtype=int), aic


def ar_aic_pick(
    x: np.ndarray,
    fs: float,
    trigger_idx: int,
    pre_us: float,
    post_us: float,
    order: int,
    min_segment: int,
    step: int,
    ar_signal: str,
) -> Dict[str, Any]:
    n = len(x)
    pre_n = int(round(pre_us * 1e-6 * fs))
    post_n = int(round(post_us * 1e-6 * fs))
    idx1 = max(0, int(trigger_idx) - pre_n)
    idx2 = min(n - 1, int(trigger_idx) + post_n)
    idx_abs, aic = ar_aic_curve(x, idx1, idx2, order=order, min_segment=min_segment, step=step, ar_signal=ar_signal)
    out: Dict[str, Any] = {
        "toa": np.nan,
        "idxFinal": np.nan,
        "aicMin": np.nan,
        "quality": np.nan,
        "idxWindow1": idx1,
        "idxWindow2": idx2,
        "methodUsed": "AR_AIC_Failed",
    }
    if idx_abs.size == 0 or np.all(~np.isfinite(aic)):
        return out
    iloc = int(np.nanargmin(aic))
    idx = float(idx_abs[iloc])
    amin = float(aic[iloc])
    finite = aic[np.isfinite(aic)]
    if finite.size >= 8:
        med = float(np.nanmedian(finite))
        mad = float(1.4826 * np.nanmedian(np.abs(finite - med)) + EPS)
        q = (med - amin) / mad
    else:
        q = np.nan
    # Penalize boundary picks, as they usually mean the window is not appropriate.
    edge_margin = max(3, int(0.02 * len(aic)))
    boundary = iloc <= edge_margin or iloc >= len(aic) - edge_margin - 1
    if boundary and np.isfinite(q):
        q = 0.25 * q
    out.update({
        "toa": idx / fs,
        "idxFinal": idx,
        "aicMin": amin,
        "quality": float(q),
        "boundaryPick": bool(boundary),
        "methodUsed": "AR_AIC",
    })
    return out


# -----------------------------------------------------------------------------
# TDOA localization
# -----------------------------------------------------------------------------

def clamp_point(p: np.ndarray, plate_xy: np.ndarray) -> np.ndarray:
    p = np.asarray(p, dtype=float).ravel().copy()
    p[0] = min(max(p[0], 0.0), float(plate_xy[0]))
    p[1] = min(max(p[1], 0.0), float(plate_xy[1]))
    return p


def tdoa_residual_objective(p: np.ndarray, sensor_xy: np.ndarray, ref_xy: np.ndarray,
                            valid_ch: np.ndarray, dt: np.ndarray, v: float, plate_xy: np.ndarray) -> float:
    p = clamp_point(p, plate_xy)
    dref = np.hypot(p[0] - ref_xy[0], p[1] - ref_xy[1])
    r = []
    for ch in valid_ch:
        di = np.hypot(p[0] - sensor_xy[ch, 0], p[1] - sensor_xy[ch, 1])
        r.append((di - dref) / v - dt[ch])
    r = np.asarray(r, dtype=float)
    return float(np.sum(r ** 2))


def localize_from_tdoa(sensor_xy: np.ndarray, dt: np.ndarray, ref: int, v: float, plate_xy: np.ndarray) -> Tuple[np.ndarray, float, bool]:
    valid_ch = np.flatnonzero(np.isfinite(dt))
    valid_ch = valid_ch[valid_ch != ref]
    if valid_ch.size < 2:
        return np.array([np.nan, np.nan]), np.inf, False
    seeds = np.vstack([
        np.mean(sensor_xy, axis=0),
        sensor_xy,
        plate_xy / 2.0,
        [0.0, 0.0],
        [plate_xy[0], 0.0],
        [0.0, plate_xy[1]],
        plate_xy,
    ])
    seeds = np.unique(seeds, axis=0)
    best_f = np.inf
    best_p = np.array([np.nan, np.nan])
    ref_xy = sensor_xy[ref]
    for p0 in seeds:
        try:
            res = optimize.minimize(
                lambda p: tdoa_residual_objective(p, sensor_xy, ref_xy, valid_ch, dt, v, plate_xy),
                p0,
                method="Nelder-Mead",
                options={"xatol": 1e-10, "fatol": 1e-16, "maxiter": 1000, "maxfev": 3000, "disp": False},
            )
            p = clamp_point(res.x, plate_xy)
            f = tdoa_residual_objective(p, sensor_xy, ref_xy, valid_ch, dt, v, plate_xy)
            if f < best_f:
                best_f = f
                best_p = p
        except Exception:
            pass
    residual = math.sqrt(best_f / valid_ch.size) if np.isfinite(best_f) else np.inf
    return best_p, residual, bool(np.isfinite(residual) and np.all(np.isfinite(best_p)))


def compute_band_weight(e_ratio: float, quality: float, residual: float, success: bool) -> float:
    if not success or not np.isfinite(residual) or residual <= 0 or not np.isfinite(quality):
        return 0.0
    w = max(float(e_ratio), 0.0) * math.log1p(max(float(quality), 0.0)) / (residual + 1e-12)
    return float(w) if np.isfinite(w) else 0.0


# -----------------------------------------------------------------------------
# Main localization logic
# -----------------------------------------------------------------------------

def run_ar_aic_localization(
    X_raw: np.ndarray,
    physical_channels: Sequence[int],
    sensor_xy_all: np.ndarray,
    true_xy: Tuple[float, float],
    fs: float,
    trigger_idx: int,
    params: BatchParams,
) -> Dict[str, Any]:
    X = preprocess_no_filter(X_raw)
    physical_channels = list(map(int, physical_channels))
    sensor_xy = np.asarray([sensor_xy_all[ch - 1] for ch in physical_channels], dtype=float)
    if np.any(~np.isfinite(sensor_xy)) or sensor_xy.shape[1] != 2:
        raise ValueError("传感器坐标无效")
    if np.all(np.linalg.norm(sensor_xy, axis=1) < EPS):
        raise ValueError("传感器坐标全为 0，无法定位。请确认 JSON 中保存了传感器坐标。")

    n_ch = X.shape[1]
    n_bands = 2 ** int(params.wpt_level)
    plate_xy = np.array([params.plate_x_m, params.plate_y_m], dtype=float)
    ref_phys = int(params.ref_channel)
    if ref_phys in physical_channels:
        ref = physical_channels.index(ref_phys)
    else:
        ref = 0

    subbands = wpt_subband_signals(X, params.wpt_level, params.wavelet_name)
    energy_ratio = compute_subband_energy(subbands)
    T = default_band_table(n_bands, fs, params.material.thickness_m * 1e3, params.lamb_mode)
    T["EnergyRatio"] = energy_ratio
    if params.velocity_mode.lower() == "lamb":
        T = update_band_velocity_by_lamb(T, params.material, params.default_velocity_mps)
    else:
        T["Velocity_mps"] = params.default_velocity_mps

    rows: List[Dict[str, Any]] = []
    for k in range(n_bands):
        er = float(energy_ratio[k])
        v = float(T.loc[k, "Velocity_mps"])
        use_band = bool(T.loc[k, "Use"])
        Y = subbands[:, :, k]
        picks = [
            ar_aic_pick(
                Y[:, ch], fs, trigger_idx, params.aic_pre_us, params.aic_post_us,
                params.ar_order, params.ar_min_segment, params.ar_candidate_step, params.ar_signal
            )
            for ch in range(n_ch)
        ]
        toa = np.array([p["toa"] for p in picks], dtype=float)
        q = np.array([p["quality"] for p in picks], dtype=float)
        idx_final = np.array([p["idxFinal"] for p in picks], dtype=float)
        aic_min = np.array([p["aicMin"] for p in picks], dtype=float)
        boundary = np.array([bool(p.get("boundaryPick", False)) for p in picks], dtype=bool)

        dt = np.full(n_ch, np.nan)
        if np.isfinite(toa[ref]):
            dt = toa - toa[ref]
            dt[ref] = 0.0

        toa_valid = np.isfinite(toa) & np.isfinite(q) & (q >= params.toa_quality_threshold) & (~boundary)
        tdoa_valid = np.zeros(n_ch, dtype=bool)
        tdoa_valid[ref] = bool(toa_valid[ref])
        loc = np.array([np.nan, np.nan])
        residual = np.inf
        success = False
        reason = ""
        used_channels = ""
        min_q = np.nan
        mean_q = np.nan
        valid_sensor_count = 0

        if not use_band:
            reason = "UserOff"
        elif er < params.energy_threshold:
            reason = "LowEnergy"
        elif not np.isfinite(v) or v <= 0:
            reason = "BadVelocity"
        elif not toa_valid[ref]:
            reason = "BadReferenceTOA"
        else:
            for ch in range(n_ch):
                if ch == ref:
                    continue
                if not toa_valid[ch] or not np.isfinite(dt[ch]):
                    continue
                dij = np.hypot(sensor_xy[ch, 0] - sensor_xy[ref, 0], sensor_xy[ch, 1] - sensor_xy[ref, 1])
                if abs(dt[ch]) <= params.velocity_margin * dij / v:
                    tdoa_valid[ch] = True
            valid_sensor_count = int(np.count_nonzero(tdoa_valid))
            used_channels = ",".join(f"CH{physical_channels[i]:02d}" for i, ok in enumerate(tdoa_valid) if ok)
            q_used = q[tdoa_valid]
            q_used = q_used[np.isfinite(q_used)]
            if q_used.size:
                min_q = float(np.min(q_used))
                mean_q = float(np.mean(q_used))
            if valid_sensor_count < params.min_valid_sensors:
                reason = "TooFewValidSensors"
            else:
                dt_used = np.full(n_ch, np.nan)
                dt_used[tdoa_valid] = dt[tdoa_valid]
                loc, residual, success = localize_from_tdoa(sensor_xy, dt_used, ref, v, plate_xy)
                if not success:
                    reason = "NoConverge"
                elif residual > params.residual_threshold_s:
                    reason = "HighResidual"
                    success = False
                else:
                    reason = "OK"
        weight = compute_band_weight(er, mean_q, residual, success)
        row: Dict[str, Any] = {
            "Band": k + 1,
            "Use": use_band,
            "Fmin_Hz": float(T.loc[k, "Fmin_Hz"]),
            "Fmax_Hz": float(T.loc[k, "Fmax_Hz"]),
            "Fc_Hz": float(T.loc[k, "Fc_Hz"]),
            "fd_MHz_mm": float(T.loc[k, "fd_MHz_mm"]),
            "Mode": str(T.loc[k, "Mode"]),
            "Velocity_mps": v,
            "EnergyRatio": er,
            "ValidSensorCount": valid_sensor_count,
            "UsedChannels": used_channels,
            "TOAQualityMinUsed": min_q,
            "TOAQualityMeanUsed": mean_q,
            "X_m": float(loc[0]),
            "Y_m": float(loc[1]),
            "Residual_s": float(residual),
            "Weight": float(weight),
            "Valid": bool(success),
            "RejectReason": reason,
        }
        for i, phys in enumerate(physical_channels):
            row[f"TOA_CH{phys:02d}_s"] = float(toa[i]) if np.isfinite(toa[i]) else np.nan
            row[f"TDOA_CH{phys:02d}_s"] = float(dt[i]) if np.isfinite(dt[i]) else np.nan
            row[f"TOAQuality_CH{phys:02d}"] = float(q[i]) if np.isfinite(q[i]) else np.nan
            row[f"AIC_FinalIdx_CH{phys:02d}"] = float(idx_final[i]) if np.isfinite(idx_final[i]) else np.nan
            row[f"AIC_Min_CH{phys:02d}"] = float(aic_min[i]) if np.isfinite(aic_min[i]) else np.nan
            row[f"AIC_Boundary_CH{phys:02d}"] = bool(boundary[i])
            row[f"TOAValid_CH{phys:02d}"] = bool(toa_valid[i])
            row[f"TDOAValid_CH{phys:02d}"] = bool(tdoa_valid[i])
        rows.append(row)

    band_df = pd.DataFrame(rows)
    valid = band_df["Valid"].to_numpy(dtype=bool) & (band_df["Weight"].to_numpy(dtype=float) > 0)
    if np.any(valid):
        W = band_df.loc[valid, "Weight"].to_numpy(dtype=float)
        P = band_df.loc[valid, ["X_m", "Y_m"]].to_numpy(dtype=float)
        final_pos = np.sum(P * W[:, None], axis=0) / np.sum(W)
    else:
        final_pos = np.array([np.nan, np.nan])
    true_xy_arr = np.asarray(true_xy, dtype=float)
    err_vec = final_pos - true_xy_arr
    err_m = float(np.linalg.norm(err_vec)) if np.all(np.isfinite(final_pos)) else np.nan
    return {
        "final_pos": final_pos,
        "error_vec": err_vec,
        "error_m": err_m,
        "band_results": band_df,
        "n_valid_bands": int(np.count_nonzero(valid)),
        "selected_channels": physical_channels,
        "ref_physical_channel": physical_channels[ref],
        "trigger_index": int(trigger_idx),
        "fs_hz": float(fs),
    }


# -----------------------------------------------------------------------------
# Batch processing
# -----------------------------------------------------------------------------

def process_one_file(csv_path: Path, params: BatchParams, out_dir: Path) -> Dict[str, Any]:
    filename_n, xy_from_name = parse_true_xy_from_filename(csv_path)
    meta = load_json_sidecar(csv_path)
    if xy_from_name is None:
        txy = meta.get("target_xy_m") or meta.get("true_xy_m")
        if not txy or len(txy) < 2:
            raise ValueError("无法从文件名或 JSON 解析真实坐标")
        true_xy = (float(txy[0]), float(txy[1]))
    else:
        true_xy = xy_from_name

    df, ch_col_map = read_waveform_csv(csv_path)
    active = infer_active_channels(meta, ch_col_map)
    selected = select_localization_channels(active, filename_n, params.loc_channels)
    X = np.column_stack([pd.to_numeric(df[ch_col_map[ch]], errors="coerce").to_numpy(dtype=float) for ch in selected])
    X = X[np.all(np.isfinite(X), axis=1), :]
    if X.shape[0] < 256:
        raise ValueError("有效数据点数过少")

    fs = float(meta.get("sample_rate_hz") or meta.get("fs_hz") or params.fs_default)
    trig = meta.get("trigger_offset", meta.get("trigger_index", None))
    trigger_idx = int(round(float(trig))) if trig is not None else int(params.trigger_index_default)
    trigger_idx = max(0, min(X.shape[0] - 1, trigger_idx))
    sensor_xy_all = get_sensor_xy_all(meta)

    result = run_ar_aic_localization(X, selected, sensor_xy_all, true_xy, fs, trigger_idx, params)

    per_dir = out_dir / "per_file_band_results"
    per_dir.mkdir(parents=True, exist_ok=True)
    band_path = per_dir / f"{csv_path.stem}_ar_aic_bands.csv"
    result["band_results"].to_csv(band_path, index=False, encoding="utf-8-sig")

    pred = result["final_pos"]
    err_vec = result["error_vec"]
    row = {
        "file_name": csv_path.name,
        "file_path": str(csv_path),
        "channel_count_in_name": filename_n,
        "true_x_m": float(true_xy[0]),
        "true_y_m": float(true_xy[1]),
        "pred_x_m": float(pred[0]) if np.isfinite(pred[0]) else np.nan,
        "pred_y_m": float(pred[1]) if np.isfinite(pred[1]) else np.nan,
        "error_x_m": float(err_vec[0]) if np.isfinite(err_vec[0]) else np.nan,
        "error_y_m": float(err_vec[1]) if np.isfinite(err_vec[1]) else np.nan,
        "error_m": float(result["error_m"]),
        "error_mm": float(result["error_m"] * 1000.0) if np.isfinite(result["error_m"]) else np.nan,
        "n_valid_bands": int(result["n_valid_bands"]),
        "selected_channels": format_channels(result["selected_channels"]),
        "ref_physical_channel": f"CH{int(result['ref_physical_channel']):02d}",
        "fs_hz": float(result["fs_hz"]),
        "trigger_index": int(result["trigger_index"]),
        "ar_order": params.ar_order,
        "ar_signal": params.ar_signal,
        "aic_pre_us": params.aic_pre_us,
        "aic_post_us": params.aic_post_us,
        "wpt_level": params.wpt_level,
        "energy_threshold": params.energy_threshold,
        "velocity_mode": params.velocity_mode,
        "band_results_csv": str(band_path),
    }
    return row


def summarize_results(df: pd.DataFrame, params: BatchParams) -> Dict[str, Any]:
    ok = np.isfinite(df.get("error_m", pd.Series(dtype=float)).to_numpy(dtype=float))
    err = df.loc[ok, "error_m"].to_numpy(dtype=float) if len(df) else np.array([])
    summary: Dict[str, Any] = {
        "n_files": int(len(df)),
        "n_success": int(err.size),
        "n_failed_or_invalid": int(len(df) - err.size),
        "params": asdict(params),
    }
    if err.size:
        summary.update({
            "mean_error_m": float(np.mean(err)),
            "median_error_m": float(np.median(err)),
            "rmse_error_m": float(math.sqrt(np.mean(err ** 2))),
            "max_error_m": float(np.max(err)),
            "min_error_m": float(np.min(err)),
            "mean_error_mm": float(np.mean(err) * 1000),
            "median_error_mm": float(np.median(err) * 1000),
            "rmse_error_mm": float(math.sqrt(np.mean(err ** 2)) * 1000),
            "max_error_mm": float(np.max(err) * 1000),
        })
    return summary


def make_plots(df: pd.DataFrame, out_dir: Path, params: BatchParams) -> None:
    if plt is None or df.empty:
        return
    plot_dir = out_dir / "plots"
    plot_dir.mkdir(parents=True, exist_ok=True)
    ok = np.isfinite(df["pred_x_m"]) & np.isfinite(df["pred_y_m"])
    if np.any(ok):
        d = df.loc[ok]
        fig, ax = plt.subplots(figsize=(7.2, 5.8), dpi=150)
        ax.scatter(d["true_x_m"], d["true_y_m"], marker="o", label="True", s=42)
        ax.scatter(d["pred_x_m"], d["pred_y_m"], marker="x", label="Predicted", s=52)
        for _, r in d.iterrows():
            ax.plot([r["true_x_m"], r["pred_x_m"]], [r["true_y_m"], r["pred_y_m"]], linewidth=0.8, alpha=0.6)
        ax.set_xlim(0, params.plate_x_m)
        ax.set_ylim(0, params.plate_y_m)
        ax.set_aspect("equal", adjustable="box")
        ax.set_xlabel("x / m")
        ax.set_ylabel("y / m")
        ax.set_title("AR-AIC localization comparison")
        ax.grid(True, alpha=0.25)
        ax.legend()
        fig.tight_layout()
        fig.savefig(plot_dir / "ar_aic_location_comparison.png")
        plt.close(fig)

    err = df["error_mm"].to_numpy(dtype=float)
    err = err[np.isfinite(err)]
    if err.size:
        fig, ax = plt.subplots(figsize=(7.2, 4.8), dpi=150)
        ax.hist(err, bins=min(20, max(5, int(math.sqrt(err.size)))))
        ax.set_xlabel("Error / mm")
        ax.set_ylabel("Count")
        ax.set_title("AR-AIC localization error histogram")
        ax.grid(True, alpha=0.25)
        fig.tight_layout()
        fig.savefig(plot_dir / "ar_aic_error_hist.png")
        plt.close(fig)

        fig, ax = plt.subplots(figsize=(9.0, 4.8), dpi=150)
        ax.plot(np.arange(1, len(df) + 1), df["error_mm"], marker="o", linewidth=1.0)
        ax.set_xlabel("File index")
        ax.set_ylabel("Error / mm")
        ax.set_title("AR-AIC localization error by file")
        ax.grid(True, alpha=0.25)
        fig.tight_layout()
        fig.savefig(plot_dir / "ar_aic_error_by_file.png")
        plt.close(fig)


def run_batch(args: argparse.Namespace) -> None:
    params = BatchParams(
        fs_default=float(args.fs_default),
        plate_x_m=float(args.plate_x),
        plate_y_m=float(args.plate_y),
        wpt_level=int(args.wpt_level),
        wavelet_name=str(args.wavelet),
        energy_threshold=float(args.energy_threshold),
        ref_channel=int(args.ref_channel),
        loc_channels=str(args.loc_channels),
        trigger_index_default=int(args.trigger_index),
        aic_pre_us=float(args.aic_pre_us),
        aic_post_us=float(args.aic_post_us),
        ar_order=int(args.ar_order),
        ar_signal=str(args.ar_signal),
        ar_min_segment=int(args.ar_min_segment),
        ar_candidate_step=int(args.ar_candidate_step),
        toa_quality_threshold=float(args.quality_threshold),
        residual_threshold_s=float(args.residual_threshold),
        velocity_margin=float(args.velocity_margin),
        min_valid_sensors=int(args.min_valid_sensors),
        velocity_mode=str(args.velocity_mode),
        default_velocity_mps=float(args.default_velocity),
        lamb_mode=str(args.lamb_mode),
        save_aic_debug=bool(args.save_aic_debug),
    )
    params.material.thickness_m = float(args.thickness)
    data_dir = Path(args.data_dir)
    if not data_dir.exists():
        raise FileNotFoundError(f"数据目录不存在：{data_dir}")
    out_dir = Path(args.out_dir) if args.out_dir else data_dir / "ar_aic_localization_compare_v7"
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_files = sorted(p for p in data_dir.rglob("*.csv") if out_dir not in p.parents)
    if not csv_files:
        raise FileNotFoundError(f"未在 {data_dir} 中找到 CSV 文件")

    rows: List[Dict[str, Any]] = []
    failures: List[Dict[str, Any]] = []
    t0 = time.time()
    print(f"[INFO] data_dir={data_dir}")
    print(f"[INFO] out_dir={out_dir}")
    print(f"[INFO] files={len(csv_files)}")
    print(f"[INFO] AR-AIC: order={params.ar_order}, signal={params.ar_signal}, window=-{params.aic_pre_us}/+{params.aic_post_us} us")

    for i, csv_path in enumerate(csv_files, start=1):
        try:
            row = process_one_file(csv_path, params, out_dir)
            rows.append(row)
            print(f"[{i:04d}/{len(csv_files):04d}] OK  {csv_path.name}  pred=({row['pred_x_m']:.4f},{row['pred_y_m']:.4f})  err={row['error_mm']:.2f} mm  valid_bands={row['n_valid_bands']}")
        except Exception as exc:
            failures.append({"file_name": csv_path.name, "file_path": str(csv_path), "reason": str(exc)[:1000]})
            print(f"[{i:04d}/{len(csv_files):04d}] FAIL {csv_path.name}: {exc}")

    df = pd.DataFrame(rows)
    fail_df = pd.DataFrame(failures)
    comp_path = out_dir / "ar_aic_localization_comparison.csv"
    fail_path = out_dir / "ar_aic_failures.csv"
    summary_path = out_dir / "ar_aic_localization_summary.json"
    df.to_csv(comp_path, index=False, encoding="utf-8-sig")
    fail_df.to_csv(fail_path, index=False, encoding="utf-8-sig")
    summary = summarize_results(df, params)
    summary["elapsed_s"] = time.time() - t0
    with summary_path.open("w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    make_plots(df, out_dir, params)
    print("\n[DONE]")
    print(f"comparison: {comp_path}")
    print(f"summary:    {summary_path}")
    print(f"failures:   {fail_path}")
    if df.empty:
        print("No successful localization results.")
    else:
        print(json.dumps(summary, ensure_ascii=False, indent=2))


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Batch AR-AIC AE localization comparison for Nchannel_x_y.csv data.")
    p.add_argument("--data-dir", default=r"E:\AE_DATA", help="数据目录，默认 E:\\AE_DATA")
    p.add_argument("--out-dir", default="", help="输出目录，默认 data_dir/ar_aic_localization_compare_v7")
    p.add_argument("--loc-channels", default="auto", help="auto/4/8/12/16，默认 auto")
    p.add_argument("--fs-default", type=float, default=2.0e6, help="JSON 缺失采样率时使用")
    p.add_argument("--trigger-index", type=int, default=2048, help="JSON 缺失 trigger_offset 时使用")
    p.add_argument("--plate-x", type=float, default=0.50)
    p.add_argument("--plate-y", type=float, default=0.40)
    p.add_argument("--thickness", type=float, default=4.0e-3, help="板厚/m")
    p.add_argument("--wavelet", default="db6")
    p.add_argument("--wpt-level", type=int, default=4)
    p.add_argument("--energy-threshold", type=float, default=0.001)
    p.add_argument("--ref-channel", type=int, default=4, help="物理参考通道号，若不在选定通道中则自动用第一个通道")
    p.add_argument("--aic-pre-us", type=float, default=300.0)
    p.add_argument("--aic-post-us", type=float, default=200.0)
    p.add_argument("--ar-order", type=int, default=4)
    p.add_argument("--ar-signal", default="raw", choices=["raw", "envelope", "energy", "tkeo"], help="AR-AIC 计算对象")
    p.add_argument("--ar-min-segment", type=int, default=64, help="AR-AIC 前/后段最少样本数")
    p.add_argument("--ar-candidate-step", type=int, default=1, help="候选点步进；大批量可设为2或4加速")
    p.add_argument("--quality-threshold", type=float, default=3.0, help="AR-AIC质量阈值")
    p.add_argument("--residual-threshold", type=float, default=1e-5)
    p.add_argument("--velocity-margin", type=float, default=1.35)
    p.add_argument("--min-valid-sensors", type=int, default=3)
    p.add_argument("--velocity-mode", default="lamb", choices=["lamb", "constant"])
    p.add_argument("--default-velocity", type=float, default=2500.0)
    p.add_argument("--lamb-mode", default="A0", choices=["A0", "S0", "A1", "S1"])
    p.add_argument("--save-aic-debug", action="store_true", help="预留参数：当前只输出每个子带TOA/AIC摘要，不保存完整AIC曲线")
    return p


if __name__ == "__main__":
    parser = build_arg_parser()
    run_batch(parser.parse_args())
