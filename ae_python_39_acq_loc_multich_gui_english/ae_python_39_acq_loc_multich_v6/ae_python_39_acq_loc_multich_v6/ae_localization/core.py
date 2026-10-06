"""Four-channel acoustic-emission source localization.

This module is a Python 3.9 implementation of the MATLAB workflow in
AE_WPT_Lamb_EnvelopeEvent_AIC_GUI.m:

1. Load four-channel AE CSV data.
2. Optional zero-phase pre-filtering.
3. Wavelet packet decomposition and subband energy calculation.
4. Lamb-wave A0/S0 group velocity calculation for an aluminum plate.
5. Reference-channel envelope event-window detection.
6. AIC first-arrival TOA picking inside the event window.
7. TDOA localization and weighted fusion across valid subbands.

The module is independent of acquisition/UDP code. It only processes saved data.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence, Tuple, Union
import math
import warnings

import numpy as np
import pandas as pd

try:
    from scipy import signal, optimize
except Exception as exc:  # pragma: no cover
    raise ImportError("This module requires scipy. Install with: pip install scipy") from exc

try:
    import pywt
except Exception:  # pragma: no cover
    pywt = None


EPS = np.finfo(float).eps


@dataclass
class MaterialParams:
    E: float = 70.0e9
    nu: float = 0.33
    rho: float = 2700.0
    thickness_m: float = 4.0e-3


@dataclass
class TOAOptions:
    noise_frac: float = 0.30
    k: float = 3.0
    peak_ratio: float = 0.05
    hold_samples: int = 5
    quality_threshold: float = 6.0
    method: str = "Envelope Event Window + AIC"  # 包络TOA / 包络+AIC / Envelope Event Window + AIC
    aic_pre_us: float = 15.0
    aic_post_us: float = 35.0
    aic_signal: str = "Raw Subband"  # Raw Subband / 包络
    fallback_envelope: bool = True

    @property
    def use_aic(self) -> bool:
        return "AIC" in str(self.method)

    @property
    def use_envelope_event(self) -> bool:
        m = str(self.method).lower()
        return ("envelope event" in m) or ("包络事件窗" in str(self.method))


@dataclass
class EventWindowOptions:
    pre_us: float = 120.0
    post_us: float = 80.0
    # Optional known trigger/event sample index in the 8192-point frame.
    # For the FPGA AE capture workflow, this is usually event.frame.trigger_offset
    # (for example 2048).  When provided, the event window is anchored to this
    # point.  The first-arrival may occur before or after the threshold trigger,
    # therefore the search window should be adjusted by pre_us/post_us rather
    # than forcing the AIC minimum to be after the trigger.
    trigger_index: Optional[int] = None
    min_pick_pre_samples: Optional[int] = None


@dataclass
class LocalizationParams:
    fs: float = 2.5e6
    wavelet_name: str = "db6"
    wpt_level: int = 5
    ref_channel: int = 4  # 1-based, as in MATLAB GUI
    sensor_xy: np.ndarray = field(default_factory=lambda: np.array([
        [0.05, 0.35],
        [0.05, 0.05],
        [0.45, 0.05],
        [0.45, 0.35],
    ], dtype=float))
    plate_xy: np.ndarray = field(default_factory=lambda: np.array([0.50, 0.40], dtype=float))
    energy_threshold: float = 0.01
    residual_threshold: float = 8e-6
    velocity_margin: float = 1.35
    min_valid_sensors: int = 3
    filter_low_hz: float = 4.0e4
    filter_high_hz: float = 5.0e5
    default_mode: str = "A0"
    material: MaterialParams = field(default_factory=MaterialParams)
    toa: TOAOptions = field(default_factory=TOAOptions)
    event: EventWindowOptions = field(default_factory=EventWindowOptions)
    diag_band: int = 0


# -----------------------------------------------------------------------------
# Data I/O and preprocessing
# -----------------------------------------------------------------------------

def parse_index_list(text_or_values: Union[str, Sequence[int]]) -> List[int]:
    """Parse a MATLAB-style channel column string such as '2,3,4,5'.

    Returned indices are 1-based to match MATLAB/user-facing parameters.
    """
    if isinstance(text_or_values, str):
        import re
        parts = [p for p in re.split(r"[,，\s]+", text_or_values.strip()) if p]
        values = [int(round(float(p))) for p in parts]
    else:
        values = [int(round(float(v))) for v in text_or_values]
    if len(values) != 4 or any(v < 1 for v in values):
        raise ValueError("Channel columns should look like 2,3,4,5 and must contain four columns.")
    return values


def load_ae_csv(paths: Union[str, Sequence[str]], cols: Union[str, Sequence[int]] = "2,3,4,5") -> np.ndarray:
    """Load four-channel AE data.

    Parameters
    ----------
    paths:
        Either one CSV/TXT path containing at least four data columns, or a list
        of four single-channel CSV/TXT paths.
    cols:
        1-based column numbers used when `paths` has one file.

    Returns
    -------
    X : ndarray, shape (N, 4)
    """
    if isinstance(paths, (str, bytes)):
        file_list = [str(paths)]
    else:
        file_list = list(paths)

    if len(file_list) == 1:
        arr = np.genfromtxt(file_list[0], delimiter=",", dtype=float)
        if arr.ndim == 1:
            arr = arr.reshape(-1, 1)
        if np.all(np.isnan(arr)):
            arr = np.loadtxt(file_list[0], dtype=float)
            if arr.ndim == 1:
                arr = arr.reshape(-1, 1)
        col_idx = [c - 1 for c in parse_index_list(cols)]
        if max(col_idx) >= arr.shape[1]:
            raise ValueError(f"Channel column index exceeds CSV column count. CSV columns={arr.shape[1]}, input columns={cols}。")
        X = arr[:, col_idx]
    elif len(file_list) == 4:
        xs = []
        min_n = None
        for fp in file_list:
            arr = np.genfromtxt(fp, delimiter=",", dtype=float)
            if arr.ndim == 1:
                col = arr
            else:
                # first column with at least one finite value
                finite_cols = np.where(np.any(np.isfinite(arr), axis=0))[0]
                if finite_cols.size == 0:
                    raise ValueError(f"File {fp} has no numeric columns.")
                col = arr[:, finite_cols[0]]
            col = col[np.isfinite(col)]
            xs.append(col)
            min_n = len(col) if min_n is None else min(min_n, len(col))
        X = np.column_stack([x[:min_n] for x in xs])
    else:
        raise ValueError("Please select one four-channel CSV or four single-channel CSV files.")

    X = np.asarray(X, dtype=float)
    X = X[np.all(np.isfinite(X), axis=1), :]
    if X.shape[1] != 4 or X.shape[0] < 100:
        raise ValueError("Loaded data must have four columns and at least 100 valid samples.")
    return X


def preprocess_signals(X: np.ndarray, fs: float, f_low: float = 4.0e4, f_high: float = 5.0e5) -> np.ndarray:
    """Preprocess AE signals for localization without filtering.

    v6_nofilter_aic version:
    The previous implementation applied a zero-phase Butterworth/FFT band-pass
    filter before WPT/AIC.  In the FPGA acquisition workflow this could create a
    large edge transient at the first samples of the 8192-point event frame.

    To avoid the edge artifact, this function now **does not perform any
    filtering**.  It only removes the channel DC mean and normalizes each channel
    by its standard deviation for numerical conditioning of WPT energy and AIC.
    The f_low/f_high arguments are intentionally kept for API compatibility with
    the GUI and old scripts, but they are not used here.
    """
    del fs, f_low, f_high  # kept only for backward-compatible function signature
    X = np.asarray(X, dtype=float)
    X = X - np.nanmean(X, axis=0)
    std = np.nanstd(X, axis=0)
    std[~np.isfinite(std) | (std <= 0)] = 1.0
    return X / std


def pre_wpt_bandpass_filter(X: np.ndarray, fs: float, f_low: float, f_high: float) -> np.ndarray:
    nyq = fs / 2.0
    f_low = max(0.0, float(f_low))
    f_high = min(float(f_high), 0.999 * nyq)
    if not np.isfinite(f_low) or not np.isfinite(f_high) or f_low >= f_high:
        raise ValueError("Invalid pre-filter cutoff frequencies: require 0 <= low cutoff < high cutoff < fs/2.")
    if f_low <= 0 and f_high >= 0.999 * nyq:
        return np.asarray(X, dtype=float)

    try:
        if f_low <= 0:
            sos = signal.butter(4, f_high / nyq, btype="low", output="sos")
        elif f_high >= 0.999 * nyq:
            sos = signal.butter(4, f_low / nyq, btype="high", output="sos")
        else:
            sos = signal.butter(4, [f_low / nyq, f_high / nyq], btype="bandpass", output="sos")
        return signal.sosfiltfilt(sos, X, axis=0)
    except Exception:
        return fft_zero_phase_bandpass(X, fs, f_low, f_high)


def fft_zero_phase_bandpass(X: np.ndarray, fs: float, f_low: float, f_high: float) -> np.ndarray:
    X = np.asarray(X, dtype=float)
    n = X.shape[0]
    f = np.arange(n) * fs / n
    ffold = np.minimum(f, fs - f)
    mask = ((ffold >= f_low) & (ffold <= f_high)).astype(float)
    trans = max(0.02 * (f_high - f_low), 2 * fs / n)
    if f_low > 0:
        lo = (ffold >= max(0, f_low - trans)) & (ffold < f_low)
        mask[lo] = 0.5 - 0.5 * np.cos(np.pi * (ffold[lo] - (f_low - trans)) / trans)
    hi = (ffold > f_high) & (ffold <= min(fs / 2, f_high + trans))
    mask[hi] = 0.5 + 0.5 * np.cos(np.pi * (ffold[hi] - f_high) / trans)
    return np.real(np.fft.ifft(np.fft.fft(X, axis=0) * mask[:, None], axis=0))


# -----------------------------------------------------------------------------
# WPT and band table
# -----------------------------------------------------------------------------

def default_band_table(n_bands: int, fs: float, thickness_mm: float = 4.0, default_mode: str = "A0") -> pd.DataFrame:
    bw = (fs / 2.0) / n_bands
    band = np.arange(1, n_bands + 1)
    fmin = (band - 1) * bw
    fmax = band * bw
    fc = (fmin + fmax) / 2.0
    fd = fc * thickness_mm * 1e-6  # Hz * mm -> MHz*mm
    return pd.DataFrame({
        "Use": np.ones(n_bands, dtype=bool),
        "Band": band,
        "Fmin_Hz": fmin,
        "Fmax_Hz": fmax,
        "Fc_Hz": fc,
        "fd_MHz_mm": fd,
        "Mode": [default_mode] * n_bands,
        "Velocity_mps": np.full(n_bands, np.nan),
        "EnergyRatio": np.full(n_bands, np.nan),
    })


def wpt_subband_signals_4ch(X: np.ndarray, level: int, wavelet_name: str = "db6") -> np.ndarray:
    """Wavelet-packet reconstruction for N-channel AE data.

    The original MATLAB/Python first version was four-channel only.  The GUI now
    can select 4/8/12/16 sampled channels for localization, so the WPT routine
    works for any channel count N >= 4 while keeping the old function name for
    backward compatibility.
    """
    if pywt is None:
        raise ImportError("Wavelet packet decomposition requires PyWavelets. Install it with: pip install PyWavelets")
    X = np.asarray(X, dtype=float)
    if X.ndim != 2:
        raise ValueError("WPT input must be a 2D array: Nsamples x Nchannels.")
    n, n_ch = X.shape
    n_bands = 2 ** int(level)
    subbands = np.zeros((n, n_ch, n_bands), dtype=float)
    for ch in range(n_ch):
        wp = pywt.WaveletPacket(data=X[:, ch], wavelet=wavelet_name, mode="symmetric", maxlevel=level)
        nodes = wp.get_level(level, order="freq")
        if len(nodes) != n_bands:
            raise RuntimeError(f"Unexpected WPT terminal node count: expected {n_bands}, actual {len(nodes)}。")
        for k, node in enumerate(nodes):
            # Reconstruct only this node by building a sparse WaveletPacket.
            sparse = pywt.WaveletPacket(data=None, wavelet=wavelet_name, mode="symmetric", maxlevel=level)
            sparse[node.path] = node.data
            y = sparse.reconstruct(update=False)
            y = np.asarray(y, dtype=float).ravel()
            if y.size > n:
                y = y[:n]
            elif y.size < n:
                y = np.pad(y, (0, n - y.size), mode="constant")
            subbands[:, ch, k] = y
    return subbands


def compute_wpt_subband_energy(X: np.ndarray, level: int, wavelet_name: str = "db6") -> Tuple[np.ndarray, np.ndarray]:
    subbands = wpt_subband_signals_4ch(X, level, wavelet_name)
    energy = np.sum(subbands ** 2, axis=(0, 1))
    total = np.sum(energy) + EPS
    return subbands, energy / total


# -----------------------------------------------------------------------------
# Envelope event window and AIC TOA
# -----------------------------------------------------------------------------

def local_analytic(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=float).ravel()
    return signal.hilbert(x)


def local_moving_average(x: np.ndarray, n: int) -> np.ndarray:
    x = np.asarray(x, dtype=float).ravel()
    n = int(max(1, n))
    if n <= 1:
        return x
    return np.convolve(x, np.ones(n) / n, mode="same")


def local_envelope_coarse_toa(env: np.ndarray, fs: float, opt: TOAOptions) -> Tuple[float, float, float]:
    env = np.asarray(env, dtype=float).ravel()
    n = env.size
    if n < 32:
        return np.nan, np.nan, np.nan
    n0 = max(20, min(n - 10, int(round(opt.noise_frac * n))))
    noise = env[:n0]
    med0 = np.nanmedian(noise)
    sig0 = 1.4826 * np.nanmedian(np.abs(noise - med0)) + EPS
    thr_noise = med0 + opt.k * sig0
    thr_peak = opt.peak_ratio * np.nanmax(env)
    thr = max(thr_noise, thr_peak)
    above = env >= thr
    hold_n = max(1, int(round(opt.hold_samples)))
    score = np.convolve(above.astype(float), np.ones(hold_n), mode="same")
    idxs = np.flatnonzero(score >= hold_n)
    if idxs.size == 0:
        return np.nan, np.nan, thr
    idx0 = int(max(0, idxs[0] - math.floor(hold_n / 2)))
    toa = idx0 / fs
    if idx0 > 0 and np.isfinite(env[idx0 - 1]) and np.isfinite(env[idx0]) and env[idx0] != env[idx0 - 1]:
        frac = (thr - env[idx0 - 1]) / (env[idx0] - env[idx0 - 1])
        if np.isfinite(frac) and 0 <= frac <= 1:
            toa = ((idx0 - 1) + frac) / fs
    return float(idx0), float(toa), float(thr)


def local_aic_curve(x: np.ndarray, idx1: int, idx2: int, min_pick_idx: Optional[int] = None) -> Tuple[np.ndarray, np.ndarray]:
    """Return absolute AIC sample indices and AIC values.

    idx1/idx2 are zero-based inclusive bounds.  ``min_pick_idx`` does not remove
    the earlier noise samples from the AIC window; it only masks candidate
    minima before the known trigger/event sample.  This is important for the
    FPGA workflow where the AE event is expected near trigger_offset, while the
    AIC window still needs pre-event samples to estimate noise variance.
    """
    x = np.asarray(x, dtype=float).ravel()
    idx1 = int(max(0, idx1))
    idx2 = int(min(x.size - 1, idx2))
    if idx2 <= idx1:
        return np.array([], dtype=int), np.array([], dtype=float)
    xw = x[idx1:idx2 + 1]
    xw = xw - np.nanmean(xw)
    m = xw.size
    aic = np.full(m, np.nan, dtype=float)
    min_side = max(3, int(round(0.05 * m)))
    k_start = min_side
    k_end = m - min_side
    if min_pick_idx is not None and np.isfinite(min_pick_idx):
        k_start = max(k_start, int(math.ceil(float(min_pick_idx))) - idx1)
    if k_end <= k_start:
        return np.arange(idx1, idx2 + 1, dtype=int), aic
    for k in range(k_start, k_end + 1):
        v1 = max(np.var(xw[:k], ddof=0), EPS)
        v2 = max(np.var(xw[k:], ddof=0), EPS)
        aic[k] = k * np.log(v1) + (m - k - 1) * np.log(v2)
    return np.arange(idx1, idx2 + 1, dtype=int), aic


def local_aic_pick(x: np.ndarray, idx1: int, idx2: int, min_pick_idx: Optional[int] = None) -> Tuple[float, float]:
    """AIC picker. idx1/idx2 are zero-based inclusive bounds."""
    idx_abs, aic = local_aic_curve(x, idx1, idx2, min_pick_idx=min_pick_idx)
    if idx_abs.size == 0 or np.all(~np.isfinite(aic)):
        return np.nan, np.nan
    idx_local = int(np.nanargmin(aic))
    return float(idx_abs[idx_local]), float(aic[idx_local])


def detect_envelope_event_window(xref: np.ndarray, fs: float, params: LocalizationParams) -> Dict[str, object]:
    xref = np.asarray(xref, dtype=float).ravel()
    xref = xref - np.nanmean(xref)
    event = {
        "ok": False,
        "idxWindow": np.array([np.nan, np.nan]),
        "idxCenter": np.nan,
        "timeWindow_s": np.array([np.nan, np.nan]),
        "thr": np.nan,
        "quality": np.nan,
        "env": np.array([]),
        "message": "Envelope event-window detection failed",
    }
    if xref.size < 64 or np.linalg.norm(xref) < EPS:
        event["message"] = "Reference channel signal is empty or too short"
        return event
    env = np.abs(local_analytic(xref))
    env = local_moving_average(env, max(1, int(round(0.5e-6 * fs))))
    idx0, _, thr = local_envelope_coarse_toa(env, fs, params.toa)
    n = env.size
    n0 = max(20, min(n - 10, int(round(params.toa.noise_frac * n))))
    noise = env[:n0]
    med0 = np.nanmedian(noise)
    sig0 = 1.4826 * np.nanmedian(np.abs(noise - med0)) + EPS
    quality = np.nanmax(env) / (med0 + sig0 + EPS)
    event.update({"thr": thr, "quality": quality, "env": env})

    trig_idx = getattr(params.event, "trigger_index", None)
    if trig_idx is not None and np.isfinite(trig_idx):
        # FPGA事件帧中已知门限触发点，例如第2048点。
        # 注意：该点通常是“超过门限”的采样点，不等价于真实首达。
        # AE 首达可能早于门限点，因此这里只用 trigger_index 作为搜索窗锚点，
        # 搜索窗由 pre_us/post_us 决定，不再强制 AIC 拾取点必须晚于 trigger_index。
        idx0i = int(round(float(trig_idx)))
        idx0i = max(0, min(n - 1, idx0i))
        pre_n = max(1, int(round(params.event.pre_us * 1e-6 * fs)))
        post_n = max(1, int(round(params.event.post_us * 1e-6 * fs)))
        idx1 = max(0, idx0i - pre_n)
        idx2 = min(n - 1, idx0i + post_n)
        min_pick_cfg = getattr(params.event, "min_pick_pre_samples", None)
        if min_pick_cfg is None:
            min_pick = None
        else:
            try:
                min_pick = max(0, idx0i - int(min_pick_cfg))
            except Exception:
                min_pick = None
        event.update({
            "ok": True,
            "idxWindow": np.array([idx1, idx2]),
            "idxCenter": idx0i,
            "minPickIdx": min_pick,
            "timeWindow_s": np.array([idx1 / fs, idx2 / fs]),
            "message": (
                f"Using FPGA threshold trigger point to anchor AIC search window: idx={idx0i}, "
                f"window=[{idx1},{idx2}], Q={quality:.3g}"
            ),
        })
        return event

    if not np.isfinite(idx0):
        event["message"] = "Reference channel envelope was not triggered"
        return event
    pre_n = max(1, int(round(params.event.pre_us * 1e-6 * fs)))
    post_n = max(1, int(round(params.event.post_us * 1e-6 * fs)))
    idx0i = int(idx0)
    idx1 = max(0, idx0i - pre_n)
    idx2 = min(n - 1, idx0i + post_n)
    if idx2 - idx1 + 1 < 8:
        event["message"] = "Envelope event window is too short"
        return event
    event.update({
        "ok": True,
        "idxWindow": np.array([idx1, idx2]),
        "idxCenter": idx0i,
        "timeWindow_s": np.array([idx1 / fs, idx2 / fs]),
        "message": f"Envelope event window succeeded: TOA={idx0i / fs:.6g} s, Q={quality:.3g}",
    })
    return event


def estimate_first_arrival_toa(x: np.ndarray, fs: float, opt: TOAOptions, event_diag: Optional[Dict[str, object]] = None) -> Dict[str, object]:
    x = np.asarray(x, dtype=float).ravel()
    x = x - np.nanmean(x)
    result = {
        "toa": np.nan,
        "quality": np.nan,
        "thr": np.nan,
        "toaCoarse": np.nan,
        "idxCoarse": np.nan,
        "idxFinal": np.nan,
        "aicMin": np.nan,
        "methodUsed": "Failed",
    }
    if x.size < 32 or np.linalg.norm(x) < EPS:
        return result

    env = np.abs(local_analytic(x))
    env = local_moving_average(env, max(1, int(round(0.5e-6 * fs))))
    n = env.size
    n0 = max(20, min(n - 10, int(round(opt.noise_frac * n))))
    noise = env[:n0]
    med0 = np.nanmedian(noise)
    sig0 = 1.4826 * np.nanmedian(np.abs(noise - med0)) + EPS
    quality = np.nanmax(env) / (med0 + sig0 + EPS)
    result["quality"] = quality

    use_envelope_event = (
        opt.use_envelope_event and event_diag is not None and bool(event_diag.get("ok", False))
    )
    if use_envelope_event:
        idx1, idx2 = np.asarray(event_diag["idxWindow"], dtype=float)
        idxc = event_diag.get("idxCenter", np.nan)
        result["idxCoarse"] = idxc
        result["toaCoarse"] = idxc / fs if np.isfinite(idxc) else np.nan
        _, _, thr = local_envelope_coarse_toa(env, fs, opt)
        result["thr"] = thr
        if np.isfinite(idx1) and np.isfinite(idx2) and idx2 > idx1:
            x_aic = env if str(opt.aic_signal).lower() in ("envelope", "包络") else x
            idx_aic, aic_min = local_aic_pick(x_aic, int(idx1), int(idx2), min_pick_idx=event_diag.get("minPickIdx", None))
            if np.isfinite(idx_aic):
                result.update({
                    "toa": idx_aic / fs,
                    "idxFinal": idx_aic,
                    "aicMin": aic_min,
                    "methodUsed": "EnvelopeEvent_AIC",
                })
                return result

    idx0, toa_c, thr0 = local_envelope_coarse_toa(env, fs, opt)
    if not np.isfinite(idx0):
        result["methodUsed"] = "NoEnvelopeTrigger"
        return result
    result.update({"idxCoarse": idx0, "toaCoarse": toa_c, "thr": thr0, "idxFinal": idx0})

    if opt.use_aic and str(opt.method).lower() not in ("envelope toa", "包络toa"):
        pre = max(2, int(round(opt.aic_pre_us * 1e-6 * fs)))
        post = max(3, int(round(opt.aic_post_us * 1e-6 * fs)))
        idx1 = max(0, int(idx0) - pre)
        idx2 = min(n - 1, int(idx0) + post)
        x_aic = env if str(opt.aic_signal).lower() in ("envelope", "包络") else x
        idx_aic, aic_min = local_aic_pick(x_aic, idx1, idx2)
        if np.isfinite(idx_aic):
            result.update({"idxFinal": idx_aic, "aicMin": aic_min, "methodUsed": "Envelope_AIC"})
        else:
            result["methodUsed"] = "Envelope_AICFailed"
    else:
        result["methodUsed"] = "EnvelopeTOA"
    result["toa"] = result["idxFinal"] / fs if np.isfinite(result["idxFinal"]) else np.nan
    return result


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
        pred = (di - dref) / v
        r.append(pred - dt[ch])
    r = np.asarray(r, dtype=float)
    return float(np.sum(r ** 2))


def localize_from_tdoa(sensor_xy: np.ndarray, dt: np.ndarray, ref: int, v: float, plate_xy: np.ndarray) -> Tuple[np.ndarray, float, bool]:
    """Localize source from TDOA. ref is zero-based."""
    sensor_xy = np.asarray(sensor_xy, dtype=float)
    dt = np.asarray(dt, dtype=float).ravel()
    valid_ch = np.flatnonzero(np.isfinite(dt))
    valid_ch = valid_ch[valid_ch != ref]
    if valid_ch.size < 2:
        return np.array([np.nan, np.nan]), np.inf, False

    ref_xy = sensor_xy[ref]
    plate_xy = np.asarray(plate_xy, dtype=float)
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
    for p0 in seeds:
        res = optimize.minimize(
            lambda p: tdoa_residual_objective(p, sensor_xy, ref_xy, valid_ch, dt, v, plate_xy),
            p0,
            method="Nelder-Mead",
            options={"xatol": 1e-10, "fatol": 1e-16, "maxiter": 1000, "maxfev": 3000, "disp": False},
        )
        p = clamp_point(res.x, plate_xy)
        fval = tdoa_residual_objective(p, sensor_xy, ref_xy, valid_ch, dt, v, plate_xy)
        if fval < best_f:
            best_f = fval
            best_p = p
    residual = math.sqrt(best_f / valid_ch.size) if np.isfinite(best_f) else np.inf
    success = np.isfinite(residual) and np.all(np.isfinite(best_p))
    return best_p, residual, success


def compute_band_weight(e_ratio: float, toa_quality: float, residual: float, success: bool) -> float:
    if (not success) or (not np.isfinite(residual)) or residual <= 0 or (not np.isfinite(toa_quality)):
        return 0.0
    w = max(e_ratio, 0.0) * math.log1p(max(toa_quality, 0.0)) / (residual + 1e-12)
    return float(w) if np.isfinite(w) else 0.0


def mask_to_channel_string(mask: Sequence[bool]) -> str:
    return ",".join(f"CH{i + 1}" for i, ok in enumerate(mask) if ok)


# -----------------------------------------------------------------------------
# Lamb velocity calculation
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
        elif c < cL:
            a = math.pi * xi * math.sqrt(1 / c ** 2 - 1 / cL ** 2)
            q = math.pi * xi * math.sqrt(1 / cT ** 2 - 1 / c ** 2)
            D = (q ** 2 - K ** 2) ** 2
            return math.tan(q) / math.tanh(a) - (4 * K ** 2 * a * q) / D
        else:
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
        elif c < cL:
            a = math.pi * xi * math.sqrt(1 / c ** 2 - 1 / cL ** 2)
            q = math.pi * xi * math.sqrt(1 / cT ** 2 - 1 / c ** 2)
            D = (q ** 2 - K ** 2) ** 2
            return math.tan(q) / math.tanh(a) + D / (4 * K ** 2 * a * q)
        else:
            p = math.pi * xi * math.sqrt(1 / cL ** 2 - 1 / c ** 2)
            q = math.pi * xi * math.sqrt(1 / cT ** 2 - 1 / c ** 2)
            D = (q ** 2 - K ** 2) ** 2
            return math.tan(q) / math.tan(p) + D / (4 * K ** 2 * p * q)
    raise ValueError("mode_type must be 'S' or 'A'")


def find_roots_one_fd(xi: float, cL: float, cT: float, cmin: float, cmax: float, mode_type: str) -> np.ndarray:
    delta = 1.0
    regions = [
        (cmin, cT - delta, 2500),
        (cT + delta, cL - delta, 2200),
        (cL + delta, cmax, 3500),
    ]
    roots: List[float] = []
    for a, b, n in regions:
        if b <= a:
            continue
        cgrid = np.linspace(a, b, n)
        vals = np.full_like(cgrid, np.nan, dtype=float)
        for k, c in enumerate(cgrid):
            try:
                val = lamb_eq_real(float(c), xi, cL, cT, mode_type)
                vals[k] = val if np.isfinite(val) else np.nan
            except Exception:
                vals[k] = np.nan
        valid = np.isfinite(vals[:-1]) & np.isfinite(vals[1:]) & (vals[:-1] * vals[1:] < 0)
        for idx in np.flatnonzero(valid):
            c1, c2 = cgrid[idx], cgrid[idx + 1]
            try:
                sol = optimize.root_scalar(lambda c: lamb_eq_real(c, xi, cL, cT, mode_type), bracket=[c1, c2], method="brentq")
                r = float(sol.root)
                res = abs(lamb_eq_real(r, xi, cL, cT, mode_type))
                if np.isfinite(res) and res < 1e-5 and cmin < r < cmax:
                    roots.append(r)
            except Exception:
                pass
    roots = sorted(roots)
    if not roots:
        return np.array([], dtype=float)
    unique = [roots[0]]
    for r in roots[1:]:
        if abs(r - unique[-1]) > 3:
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
            idx = np.isfinite(pred) & np.isfinite(prev2)
            pred[idx] = pred[idx] + (pred[idx] - prev2[idx])
        pairs = []
        for m in range(nmode):
            if np.isfinite(pred[m]):
                idx_min = int(np.argmin(np.abs(roots - pred[m])))
                pairs.append((abs(roots[idx_min] - pred[m]), m, idx_min))
        for d, m, r in sorted(pairs, key=lambda x: x[0]):
            if not used[r] and np.isnan(modes[m, i]) and d < tol_track:
                modes[m, i] = roots[r]
                used[r] = True
        for m in range(nmode):
            if np.isnan(modes[m, i]) and np.isfinite(modes[m, i - 1]):
                idx_min = int(np.argmin(np.abs(roots - modes[m, i - 1])))
                d = abs(roots[idx_min] - modes[m, i - 1])
                if not used[idx_min] and d < 2 * tol_track:
                    modes[m, i] = roots[idx_min]
                    used[idx_min] = True
        for r in range(roots.size):
            if not used[r] and next_mode < nmode:
                modes[next_mode, i] = roots[r]
                next_mode += 1
    return modes


def calc_group_velocity(cp: np.ndarray, fd: np.ndarray) -> np.ndarray:
    cp = np.asarray(cp, dtype=float)
    fd = np.asarray(fd, dtype=float)
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
        bad = (~np.isfinite(cgtmp)) | (cgtmp <= 0) | (cgtmp > 2e4)
        cgtmp[bad] = np.nan
        cg[m, idx] = cgtmp
    return cg


def interp_valid(x: np.ndarray, y: np.ndarray, xq: float) -> float:
    valid = np.isfinite(x) & np.isfinite(y) & (y > 0)
    if np.count_nonzero(valid) < 2:
        return np.nan
    yq = np.interp(xq, x[valid], y[valid], left=np.nan, right=np.nan)
    if not np.isfinite(yq):
        # linear extrapolate if outside range
        xv, yv = x[valid], y[valid]
        if xq < xv[0]:
            yq = yv[0] + (xq - xv[0]) * (yv[1] - yv[0]) / (xv[1] - xv[0])
        else:
            yq = yv[-1] + (xq - xv[-1]) * (yv[-1] - yv[-2]) / (xv[-1] - xv[-2])
    if not np.isfinite(yq) or yq <= 0 or yq > 2e4:
        return np.nan
    return float(yq)


def update_band_velocity_by_lamb(T: pd.DataFrame, material: MaterialParams,
                                 modes: Optional[Sequence[str]] = None,
                                 fd_targets: Optional[Sequence[float]] = None) -> Tuple[pd.DataFrame, Dict[str, object]]:
    T = T.copy()
    cL, cT = aluminum_bulk_speeds(material.E, material.nu, material.rho)
    if modes is None:
        modes = T["Mode"].astype(str).tolist()
    if fd_targets is None:
        fd_targets = T["fd_MHz_mm"].to_numpy(dtype=float)
    fd_targets = np.asarray(fd_targets, dtype=float)
    positive = fd_targets[fd_targets > 0]
    if positive.size == 0:
        raise ValueError("fdTargets contains no positive values.")
    fd_min = max(0.02, 0.80 * np.min(positive))
    fd_max = max(0.05, 1.10 * np.max(fd_targets))
    n_fd = 320
    fd_grid = np.linspace(fd_min, fd_max, n_fd)
    xi_grid = fd_grid * 1e3  # MHz*mm -> m/s, same convention as MATLAB code
    nmode = 4
    cmin, cmax = 50.0, 12000.0
    roots_s = [find_roots_one_fd(xi, cL, cT, cmin, cmax, "S") for xi in xi_grid]
    roots_a = [find_roots_one_fd(xi, cL, cT, cmin, cmax, "A") for xi in xi_grid]
    cp_s = track_modes(roots_s, nmode, 1200.0)
    cp_a = track_modes(roots_a, nmode, 1200.0)
    cg_s = calc_group_velocity(cp_s, fd_grid)
    cg_a = calc_group_velocity(cp_a, fd_grid)
    v = []
    for mode, fd in zip(modes, fd_targets):
        mode_u = str(mode).strip().upper()
        if mode_u == "S0":
            v.append(interp_valid(fd_grid, cg_s[0], fd))
        elif mode_u == "A0":
            v.append(interp_valid(fd_grid, cg_a[0], fd))
        elif mode_u == "S1":
            v.append(interp_valid(fd_grid, cg_s[1], fd))
        elif mode_u == "A1":
            v.append(interp_valid(fd_grid, cg_a[1], fd))
        else:
            v.append(np.nan)
    T["Velocity_mps"] = np.asarray(v, dtype=float)
    lamb = {"fd": fd_grid, "cpS": cp_s, "cpA": cp_a, "cgS": cg_s, "cgA": cg_a, "cL": cL, "cT": cT}
    return T, lamb


# -----------------------------------------------------------------------------
# Main processing
# -----------------------------------------------------------------------------

def validate_params(params: LocalizationParams, require_velocity: bool = False, band_config: Optional[pd.DataFrame] = None) -> None:
    sensor = np.asarray(params.sensor_xy, dtype=float)
    if sensor.shape != (4, 2) or not np.all(np.isfinite(sensor)):
        raise ValueError("Sensor coordinates must be a finite 4x2 matrix.")
    if not (1 <= params.ref_channel <= 4):
        raise ValueError("Reference channel must be between 1 and 4.")
    if params.plate_xy[0] <= 0 or params.plate_xy[1] <= 0:
        raise ValueError("Plate dimensions must be positive.")
    if not params.wavelet_name:
        raise ValueError("Wavelet name cannot be empty.")
    if require_velocity and band_config is not None:
        active = band_config["Use"].to_numpy(dtype=bool)
        if "EnergyRatio" in band_config:
            er = band_config["EnergyRatio"].to_numpy(dtype=float)
            active = active & ((~np.isfinite(er)) | (er >= params.energy_threshold))
        vel = band_config["Velocity_mps"].to_numpy(dtype=float)
        if np.any(active & ((~np.isfinite(vel)) | (vel <= 0))):
            raise ValueError("One or more enabled subbands above the energy threshold have invalid velocity. Compute Lamb group velocity first or fill Velocity_mps manually.")


def process_ae_wpt_localization_toa(X: np.ndarray, subbands: np.ndarray, energy_ratio: np.ndarray,
                                    params: LocalizationParams, band_config: pd.DataFrame) -> Dict[str, object]:
    fs = params.fs
    ref = int(params.ref_channel) - 1
    sensor_xy = np.asarray(params.sensor_xy, dtype=float)
    plate_xy = np.asarray(params.plate_xy, dtype=float)
    n_bands = 2 ** int(params.wpt_level)
    n_ch = int(X.shape[1])
    if sensor_xy.shape[0] != n_ch:
        raise ValueError(f"Sensor coordinate count ({sensor_xy.shape[0]} ) must equal the localization channel count ({n_ch})。")
    if ref < 0 or ref >= n_ch:
        raise ValueError(f"Reference channel CH{ref + 1} exceeds localization channel count {n_ch}。")

    if len(band_config) != n_bands:
        raise ValueError("The subband table row count must equal 2^decomposition_level.")
    if subbands.shape[2] != n_bands:
        raise ValueError("The number of WPT subbands does not match the decomposition level.")

    if params.toa.use_envelope_event:
        event_diag = detect_envelope_event_window(X[:, ref], fs, params)
    else:
        event_diag = {"ok": False, "message": "Envelope event window is not enabled"}

    rows: List[Dict[str, object]] = []
    for k in range(n_bands):
        row_cfg = band_config.iloc[k]
        use_band = bool(row_cfg["Use"])
        fmin, fmax, fc = float(row_cfg["Fmin_Hz"]), float(row_cfg["Fmax_Hz"]), float(row_cfg["Fc_Hz"])
        fd = float(row_cfg["fd_MHz_mm"])
        mode = str(row_cfg["Mode"])
        v = float(row_cfg["Velocity_mps"]) if np.isfinite(row_cfg["Velocity_mps"]) else np.nan
        er = float(energy_ratio[k])
        Y = subbands[:, :, k]

        picks = [estimate_first_arrival_toa(Y[:, ch], fs, params.toa, event_diag) for ch in range(n_ch)]
        toa = np.array([p["toa"] for p in picks], dtype=float)
        q = np.array([p["quality"] for p in picks], dtype=float)
        thr = np.array([p["thr"] for p in picks], dtype=float)
        toa_coarse = np.array([p["toaCoarse"] for p in picks], dtype=float)
        idx_coarse = np.array([p["idxCoarse"] for p in picks], dtype=float)
        idx_final = np.array([p["idxFinal"] for p in picks], dtype=float)
        aic_min = np.array([p["aicMin"] for p in picks], dtype=float)
        method_used = [p["methodUsed"] for p in picks]

        dt = np.full(n_ch, np.nan)
        if np.isfinite(toa[ref]):
            dt = toa - toa[ref]
            dt[ref] = 0.0

        toa_valid = np.isfinite(toa) & np.isfinite(q) & (q >= params.toa.quality_threshold)
        tdoa_valid = np.zeros(n_ch, dtype=bool)
        tdoa_valid[ref] = bool(toa_valid[ref])
        loc = np.array([np.nan, np.nan])
        residual = np.inf
        success = False
        physical_ok = False
        reason = ""
        valid_sensor_count = 0
        valid_tdoa_count = 0
        min_q_used = np.nan
        mean_q_used = np.nan
        used_channels = ""

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
                dij_max = np.hypot(sensor_xy[ch, 0] - sensor_xy[ref, 0], sensor_xy[ch, 1] - sensor_xy[ref, 1])
                if abs(dt[ch]) <= params.velocity_margin * dij_max / v:
                    tdoa_valid[ch] = True
            valid_sensor_count = int(np.count_nonzero(tdoa_valid))
            valid_tdoa_count = valid_sensor_count - 1
            used_channels = mask_to_channel_string(tdoa_valid)
            q_used = q[tdoa_valid]
            q_used = q_used[np.isfinite(q_used)]
            if q_used.size:
                min_q_used = float(np.min(q_used))
                mean_q_used = float(np.mean(q_used))
            if valid_sensor_count < params.min_valid_sensors or valid_tdoa_count < (params.min_valid_sensors - 1):
                reason = "TooFewValidSensors"
            else:
                physical_ok = True
                dt_used = np.full(n_ch, np.nan)
                dt_used[ref] = 0.0
                dt_used[tdoa_valid] = dt[tdoa_valid]
                loc, residual, success = localize_from_tdoa(sensor_xy, dt_used, ref, v, plate_xy)
                if (not success) or np.any(~np.isfinite(loc)):
                    reason = "NoConverge"
                elif residual > params.residual_threshold:
                    reason = "HighResidual"
                    success = False
                else:
                    reason = "OK"

        weight = compute_band_weight(er, mean_q_used, residual, success)
        row = {
            "Use": use_band,
            "Band": k + 1,
            "Fmin_Hz": fmin,
            "Fmax_Hz": fmax,
            "Fc_Hz": fc,
            "fd_MHz_mm": fd,
            "Mode": mode,
            "Velocity_mps": v,
            "EnergyRatio": er,
            "ValidSensorCount": valid_sensor_count,
            "ValidTDOACount": valid_tdoa_count,
            "UsedChannels": used_channels,
            "TOAQualityMinUsed": min_q_used,
            "TOAQualityMeanUsed": mean_q_used,
            "X_m": loc[0],
            "Y_m": loc[1],
            "Residual_s": residual,
            "Weight": weight,
            "Valid": bool(success),
            "PhysicalOK": bool(physical_ok),
            "RejectReason": reason,
        }
        for ch in range(n_ch):
            c = ch + 1
            row[f"TOA_CH{c}_s"] = toa[ch]
            row[f"TDOA_CH{c}_s"] = dt[ch]
            row[f"TOAQuality_CH{c}"] = q[ch]
            row[f"TOA_Coarse_CH{c}_s"] = toa_coarse[ch]
            row[f"AIC_CoarseIdx_CH{c}"] = idx_coarse[ch]
            row[f"AIC_FinalIdx_CH{c}"] = idx_final[ch]
            row[f"AIC_Min_CH{c}"] = aic_min[ch]
            row[f"TOAMethod_CH{c}"] = method_used[ch]
            row[f"TOAValid_CH{c}"] = bool(toa_valid[ch])
            row[f"TDOAValid_CH{c}"] = bool(tdoa_valid[ch])
        rows.append(row)

    T = pd.DataFrame(rows)
    valid = T["Valid"].to_numpy(dtype=bool) & np.isfinite(T["X_m"].to_numpy(float)) & np.isfinite(T["Y_m"].to_numpy(float)) & (T["Weight"].to_numpy(float) > 0)
    if np.any(valid):
        W = T.loc[valid, "Weight"].to_numpy(dtype=float)
        P = T.loc[valid, ["X_m", "Y_m"]].to_numpy(dtype=float)
        final_pos = np.sum(P * W[:, None], axis=0) / np.sum(W)
    else:
        final_pos = np.array([np.nan, np.nan])
    return {"bandResults": T, "finalPos": final_pos, "nValid": int(np.count_nonzero(valid)), "eventDiag": event_diag}


def run_localization_from_csv(
    csv_paths: Union[str, Sequence[str]],
    cols: Union[str, Sequence[int]] = "2,3,4,5",
    params: Optional[LocalizationParams] = None,
    band_config: Optional[pd.DataFrame] = None,
    auto_lamb_velocity: bool = True,
) -> Dict[str, object]:
    """Convenience function: load CSV, preprocess, WPT, Lamb velocity, run localization."""
    if params is None:
        params = LocalizationParams()
    X_raw = load_ae_csv(csv_paths, cols)
    X = preprocess_signals(X_raw, params.fs, params.filter_low_hz, params.filter_high_hz)
    subbands, energy_ratio = compute_wpt_subband_energy(X, params.wpt_level, params.wavelet_name)
    if band_config is None:
        band_config = default_band_table(2 ** params.wpt_level, params.fs, params.material.thickness_m * 1000.0, params.default_mode)
    band_config = band_config.copy()
    band_config["EnergyRatio"] = energy_ratio
    if auto_lamb_velocity:
        need_vel = band_config["Use"].to_numpy(bool) & (energy_ratio >= params.energy_threshold)
        vel = band_config["Velocity_mps"].to_numpy(float)
        if np.any(need_vel & ((~np.isfinite(vel)) | (vel <= 0))):
            band_config, lamb = update_band_velocity_by_lamb(band_config, params.material)
        else:
            lamb = None
    else:
        lamb = None
    out = process_ae_wpt_localization_toa(X, subbands, energy_ratio, params, band_config)
    out.update({"X_raw": X_raw, "X": X, "subbands": subbands, "energyRatio": energy_ratio, "bandConfig": band_config, "lamb": lamb})
    return out
