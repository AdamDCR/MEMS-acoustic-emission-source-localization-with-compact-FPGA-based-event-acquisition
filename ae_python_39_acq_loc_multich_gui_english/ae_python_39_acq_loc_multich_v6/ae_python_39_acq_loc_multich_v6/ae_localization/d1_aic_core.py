from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Dict, List, Optional, Sequence, Tuple
import math

import numpy as np

try:
    from scipy import signal, optimize
except Exception:  # pragma: no cover
    signal = None
    optimize = None

EPS = np.finfo(float).eps


@dataclass
class MaterialParams:
    E: float = 70.0e9
    nu: float = 0.33
    rho: float = 2700.0
    thickness_m: float = 0.004


@dataclass
class D1AICOptions:
    voltage_divisor: float = 8192.0
    remove_mean: bool = True
    highpass_enabled: bool = False
    highpass_cutoff_hz: float = 40000.0
    highpass_order: int = 4
    divide_diff_by_dt: bool = False
    diff_smooth_pts: int = 1
    threshold_detect_start_us: float = -200.0
    threshold_detect_end_us: float = 400.0
    rms_baseline_duration_us: float = 60.0
    threshold_multiplier: float = 10.0
    threshold_mode: str = "per_channel"  # per_channel / mean_all_channels / max_all_channels
    aic_offset_start_us: float = -80.0
    aic_offset_end_us: float = 100.0
    aic_smooth_pts: int = 5
    aic_min_side_pts: int = 10
    fft_pre_us: float = 1.0
    fft_post_us: float = 80.0
    fft_fmin_hz: float = 80000.0
    fft_fmax_hz: float = 500000.0
    fft_nfft_factor: int = 4
    manual_velocity_enable: bool = True
    manual_velocity_m_s: float = 3150.0
    lamb_mode: str = "A0"             # A0 / S0
    velocity_type: str = "group"       # group / phase
    loc_grid_n: int = 11


@dataclass
class D1AICLocalizationParams:
    fs: float
    sensor_xy: np.ndarray
    plate_xy: np.ndarray = field(default_factory=lambda: np.array([0.5, 0.5], dtype=float))
    material: MaterialParams = field(default_factory=MaterialParams)
    d1aic: D1AICOptions = field(default_factory=D1AICOptions)
    trigger_index: Optional[int] = None


@dataclass
class ChannelD1AICResult:
    channel: str
    arrival_index: int
    arrival_time_us: float
    aic_min: float
    threshold_index: int
    threshold_time_us: float
    threshold_value: float
    baseline_rms: float
    baseline_start_us: float
    baseline_end_us: float
    baseline_n: int
    threshold_multiplier: float
    threshold_detect_start_us: float
    threshold_detect_end_us: float
    search_offset_start_us: float
    search_offset_end_us: float
    search_start_index: int
    search_end_index: int
    search_start_us: float
    search_end_us: float
    aic_time_us: np.ndarray
    aic_curve: np.ndarray

    def to_dict(self) -> Dict[str, object]:
        return {
            "channel": self.channel,
            "arrival_index": int(self.arrival_index),
            "arrival_time_us": float(self.arrival_time_us),
            "aic_min": float(self.aic_min),
            "threshold_index": int(self.threshold_index),
            "threshold_time_us": float(self.threshold_time_us),
            "threshold_value": float(self.threshold_value),
            "baseline_rms": float(self.baseline_rms),
            "baseline_start_us": float(self.baseline_start_us),
            "baseline_end_us": float(self.baseline_end_us),
            "baseline_n": int(self.baseline_n),
            "threshold_multiplier": float(self.threshold_multiplier),
            "threshold_detect_start_us": float(self.threshold_detect_start_us),
            "threshold_detect_end_us": float(self.threshold_detect_end_us),
            "search_offset_start_us": float(self.search_offset_start_us),
            "search_offset_end_us": float(self.search_offset_end_us),
            "search_start_index": int(self.search_start_index),
            "search_end_index": int(self.search_end_index),
            "search_start_us": float(self.search_start_us),
            "search_end_us": float(self.search_end_us),
            "aic_time_us": np.asarray(self.aic_time_us, dtype=float),
            "aic_curve": np.asarray(self.aic_curve, dtype=float),
        }


@dataclass
class LocalizationResult:
    pred_x_m: float
    pred_y_m: float
    t0_us: float
    rms_residual_us: float
    max_abs_residual_us: float
    residuals_us: np.ndarray
    error_mm: Optional[float]

    def to_dict(self) -> Dict[str, object]:
        return {
            "pred_x_m": float(self.pred_x_m),
            "pred_y_m": float(self.pred_y_m),
            "t0_us": float(self.t0_us),
            "rms_residual_us": float(self.rms_residual_us),
            "max_abs_residual_us": float(self.max_abs_residual_us),
            "residuals_us": np.asarray(self.residuals_us, dtype=float),
            "error_mm": None if self.error_mm is None else float(self.error_mm),
        }


# -----------------------------------------------------------------------------
# Basic signal helpers
# -----------------------------------------------------------------------------

def moving_average(x: np.ndarray, n: int) -> np.ndarray:
    y = np.asarray(x, dtype=float).copy()
    n = int(max(1, n))
    if n <= 1:
        return y
    finite = np.isfinite(y)
    if not np.all(finite):
        fill = float(np.nanmean(y[finite])) if np.any(finite) else 0.0
        y[~finite] = fill
    return np.convolve(y, np.ones(n, dtype=float) / float(n), mode="same")


def highpass_filter_matrix(x: np.ndarray, fs: float, enabled: bool, cutoff_hz: float, order: int) -> np.ndarray:
    X = np.asarray(x, dtype=float)
    if not enabled:
        return X.copy()
    if signal is None:
        raise RuntimeError("scipy.signal is required for high-pass filtering.")
    cutoff_hz = float(cutoff_hz)
    if cutoff_hz <= 0 or cutoff_hz >= 0.49 * float(fs):
        raise ValueError("Invalid high-pass cutoff frequency.")
    sos = signal.butter(int(max(1, order)), cutoff_hz, btype="highpass", fs=float(fs), output="sos")
    out = np.zeros_like(X, dtype=float)
    for i in range(X.shape[1]):
        y = np.asarray(X[:, i], dtype=float)
        finite = np.isfinite(y)
        if not np.all(finite):
            fill = float(np.nanmean(y[finite])) if np.any(finite) else 0.0
            y[~finite] = fill
        try:
            out[:, i] = signal.sosfiltfilt(sos, y)
        except Exception:
            out[:, i] = signal.sosfilt(sos, y)
    return out


def first_difference_matrix(X: np.ndarray, fs: float, divide_by_dt: bool) -> np.ndarray:
    X = np.asarray(X, dtype=float)
    d = np.zeros_like(X, dtype=float)
    d[1:, :] = np.diff(X, axis=0)
    if divide_by_dt:
        dt_us = 1e6 / float(fs)
        d = d / max(dt_us, 1e-30)
    return d


def compute_aic_curve(x: np.ndarray, min_side: int = 8) -> np.ndarray:
    x = np.asarray(x, dtype=float).ravel()
    n = len(x)
    aic = np.full(n, np.nan, dtype=float)
    min_side = max(2, int(min_side))
    if n < max(20, min_side * 2 + 2):
        return aic
    finite = np.isfinite(x)
    if not np.all(finite):
        fill = float(np.nanmean(x[finite])) if np.any(finite) else 0.0
        x = x.copy()
        x[~finite] = fill
    x = x - np.mean(x)
    eps = 1e-20
    for k in range(min_side, n - min_side):
        v1 = np.var(x[:k]) + eps
        v2 = np.var(x[k:]) + eps
        aic[k] = k * np.log(v1) + (n - k - 1) * np.log(v2)
    return aic


def compute_windowed_aic(values: np.ndarray, time_us: np.ndarray, search_start_us: float, search_end_us: float,
                         min_side: int = 8, smooth_pts: int = 1) -> Tuple[np.ndarray, np.ndarray, int, float, float, int, int]:
    y = np.asarray(values, dtype=float).ravel()
    t = np.asarray(time_us, dtype=float).ravel()
    if len(y) != len(t):
        raise ValueError("AIC failed: values and time_us lengths are inconsistent.")
    if search_end_us <= search_start_us:
        raise ValueError("AIC search end must be greater than start.")
    idx0 = int(np.searchsorted(t, float(search_start_us), side="left"))
    idx1 = int(np.searchsorted(t, float(search_end_us), side="right"))
    idx0 = max(0, min(idx0, len(y) - 1))
    idx1 = max(idx0 + 20, min(idx1, len(y)))
    yw = y[idx0:idx1]
    aic_w = compute_aic_curve(yw, min_side=min_side)
    if int(smooth_pts) > 1:
        aic_w = moving_average(aic_w, int(smooth_pts))
    if not np.any(np.isfinite(aic_w)):
        return t[idx0:idx1], aic_w, idx0, float(t[idx0]), float("nan"), idx0, idx1
    local_idx = int(np.nanargmin(aic_w))
    global_idx = idx0 + local_idx
    return t[idx0:idx1], aic_w, int(global_idx), float(t[global_idx]), float(aic_w[local_idx]), idx0, idx1


def compute_baseline_rms(values: np.ndarray, time_us: np.ndarray, detect_start_us: float,
                         baseline_duration_us: float) -> Tuple[float, float, float, int]:
    y = np.asarray(values, dtype=float).ravel()
    t = np.asarray(time_us, dtype=float).ravel()
    duration = float(baseline_duration_us)
    if duration <= 0:
        raise ValueError("RMS baseline duration must be positive.")
    b0 = float(detect_start_us) - duration
    b1 = float(detect_start_us)
    mask = (t >= b0) & (t < b1)
    if not np.any(mask):
        # Robust fallback: use all samples before detect_start_us.
        mask = t < float(detect_start_us)
    if not np.any(mask):
        # Final fallback: first 10% of the frame.
        n0 = max(5, int(round(0.10 * len(y))))
        mask = np.zeros_like(y, dtype=bool)
        mask[:n0] = True
        b0 = float(t[0])
        b1 = float(t[n0 - 1])
    vals = y[mask]
    vals = vals[np.isfinite(vals)]
    if vals.size < 3:
        raise ValueError("Too few valid samples in RMS baseline window.")
    rms = float(np.sqrt(np.mean(vals ** 2)))
    return rms, b0, b1, int(vals.size)


def find_first_threshold_crossing(values: np.ndarray, time_us: np.ndarray, threshold: float,
                                  detect_start_us: float, detect_end_us: float) -> Tuple[int, float]:
    y = np.asarray(values, dtype=float).ravel()
    t = np.asarray(time_us, dtype=float).ravel()
    if detect_end_us <= detect_start_us:
        raise ValueError("Threshold detection end must be greater than start.")
    th = float(threshold)
    if th <= 0:
        raise ValueError("Dynamic threshold must be positive.")
    mask = (t >= float(detect_start_us)) & (t <= float(detect_end_us))
    idx_candidates = np.where(mask)[0]
    if idx_candidates.size == 0:
        raise ValueError("D1 threshold detection window is empty.")
    yy = y[idx_candidates]
    crossed = np.where(yy >= th)[0]
    if crossed.size == 0:
        raise ValueError(f"No |D1| crossing was detected in {detect_start_us:.3f}~{detect_end_us:.3f} us. threshold={th:.6g}")
    idx = int(idx_candidates[int(crossed[0])])
    return idx, float(t[idx])


# -----------------------------------------------------------------------------
# FFT / velocity / localization
# -----------------------------------------------------------------------------

def fft_for_segment(x: np.ndarray, fs_hz: float, nfft_factor: int = 4) -> Tuple[np.ndarray, np.ndarray]:
    x = np.asarray(x, dtype=float).ravel()
    x = np.nan_to_num(x, nan=0.0)
    if len(x) < 8:
        raise ValueError("FFT window has too few samples.")
    x = x - np.mean(x)
    win = np.hanning(len(x))
    nfft = int(2 ** math.ceil(math.log2(max(8, len(x) * max(1, int(nfft_factor))))))
    spec = np.abs(np.fft.rfft(x * win, n=nfft))
    freqs = np.fft.rfftfreq(nfft, d=1.0 / float(fs_hz))
    return freqs, spec


def compute_arrival_window_fft(X: np.ndarray, time_us: np.ndarray, fs_hz: float, results: List[ChannelD1AICResult],
                               pre_us: float, post_us: float, fmin_hz: float,
                               fmax_hz: Optional[float], nfft_factor: int = 4) -> Dict[str, object]:
    X = np.asarray(X, dtype=float)
    t = np.asarray(time_us, dtype=float)
    per_ch = []
    common_freqs = None
    specs_interp = []
    for i, r in enumerate(results):
        win_start = float(r.arrival_time_us) - float(pre_us)
        win_end = float(r.arrival_time_us) + float(post_us)
        mask = (t >= win_start) & (t <= win_end)
        if not np.any(mask):
            raise ValueError(f"{r.channel}: FFT window is empty.")
        freqs, spec = fft_for_segment(X[mask, i], fs_hz=fs_hz, nfft_factor=nfft_factor)
        if common_freqs is None:
            common_freqs = freqs
        else:
            spec = np.interp(common_freqs, freqs, spec, left=0.0, right=0.0)
            freqs = common_freqs
        specs_interp.append(spec)
        maskf = freqs >= float(fmin_hz)
        if fmax_hz is not None and float(fmax_hz) > 0:
            maskf &= freqs <= float(fmax_hz)
        if not np.any(maskf):
            raise ValueError("FFT peak search band is empty.")
        idx_global = np.where(maskf)[0][int(np.argmax(spec[maskf]))]
        per_ch.append({
            "channel": r.channel,
            "win_start_us": float(win_start),
            "win_end_us": float(win_end),
            "freqs": freqs,
            "spec": spec,
            "peak_hz": float(freqs[idx_global]),
            "peak_amp": float(spec[idx_global]),
            "n_points": int(np.sum(mask)),
        })
    freqs = common_freqs
    spec_stack = np.vstack(specs_interp)
    spec_sum = np.sum(spec_stack, axis=0)
    maskf = freqs >= float(fmin_hz)
    if fmax_hz is not None and float(fmax_hz) > 0:
        maskf &= freqs <= float(fmax_hz)
    idx_global = np.where(maskf)[0][int(np.argmax(spec_sum[maskf]))]
    peak_ch_idx = int(np.argmax(spec_stack[:, idx_global]))
    return {
        "freqs": freqs,
        "sum_spec": spec_sum,
        "combined_method": "sum_across_channels",
        "peak_source_channel": per_ch[peak_ch_idx]["channel"],
        "per_channel": per_ch,
        "peak_hz": float(freqs[idx_global]),
        "peak_amp": float(spec_sum[idx_global]),
    }


def material_wave_speeds(E_pa: float, nu: float, rho: float) -> Tuple[float, float, float]:
    c_l = math.sqrt(E_pa * (1 - nu) / (rho * (1 + nu) * (1 - 2 * nu)))
    c_t = math.sqrt(E_pa / (2 * rho * (1 + nu)))
    c_plate = math.sqrt(E_pa / (rho * (1 - nu ** 2)))
    return c_l, c_t, c_plate


def rayleigh_speed_approx(c_t: float, nu: float) -> float:
    return c_t * (0.862 + 1.14 * nu) / (1 + nu)


def estimate_velocity_from_lamb_or_fallback(freq_hz: float, mat: MaterialParams, mode: str = "A0", velocity_type: str = "group") -> Tuple[float, Dict[str, object]]:
    """Return an engineering velocity estimate without WPT/CWT.

    If the original ae_localization.core is present, its Rayleigh-Lamb solver is used
    to evaluate a single frequency. Otherwise, a conservative approximation is used.
    """
    f = float(freq_hz)
    mode_u = str(mode).upper()
    try:
        import pandas as pd
        from ae_localization.core import update_band_velocity_by_lamb, MaterialParams as OldMaterialParams
        fd = f / 1e6 * mat.thickness_m * 1000.0
        T = pd.DataFrame({
            "Use": [True],
            "Band": [1],
            "Fmin_Hz": [max(0.0, f * 0.95)],
            "Fmax_Hz": [f * 1.05],
            "Fc_Hz": [f],
            "fd_MHz_mm": [fd],
            "Mode": [mode_u],
            "Velocity_mps": [np.nan],
            "EnergyRatio": [1.0],
        })
        T2, lamb = update_band_velocity_by_lamb(T, OldMaterialParams(E=mat.E, nu=mat.nu, rho=mat.rho, thickness_m=mat.thickness_m))
        v = float(T2.loc[0, "Velocity_mps"])
        if np.isfinite(v) and v > 0:
            return v, {"method": "lamb_from_ae_localization_core", "freq_hz": f, "mode": mode_u, "velocity_type": velocity_type}
    except Exception:
        pass
    c_l, c_t, c_plate = material_wave_speeds(mat.E, mat.nu, mat.rho)
    if mode_u.startswith("S"):
        v = c_plate
        method = "fallback_plate_extensional_velocity"
    else:
        v = rayleigh_speed_approx(c_t, mat.nu)
        method = "fallback_rayleigh_approx_velocity"
    return float(v), {"method": method, "freq_hz": f, "mode": mode_u, "velocity_type": velocity_type}


def locate_source_toa(sensor_xy: np.ndarray, arrival_us: np.ndarray, velocity_m_s: float,
                      board_length_m: float, board_width_m: float, grid_n: int = 11,
                      target_xy: Optional[np.ndarray] = None) -> LocalizationResult:
    sensor_xy = np.asarray(sensor_xy, dtype=float)
    t_sec = np.asarray(arrival_us, dtype=float) * 1e-6
    v = float(velocity_m_s)
    if sensor_xy.shape[0] < 3:
        raise ValueError("At least 3 sensors are required for TOA localization.")
    if v <= 0:
        raise ValueError("Wave velocity must be positive.")
    L = float(board_length_m)
    W = float(board_width_m)

    def residual_us_xy(xy):
        x, y = float(xy[0]), float(xy[1])
        d = np.sqrt((x - sensor_xy[:, 0]) ** 2 + (y - sensor_xy[:, 1]) ** 2)
        travel = d / v
        t0 = np.mean(t_sec - travel)
        res = t0 + travel - t_sec
        return res * 1e6

    def solve_t0_us(xy):
        x, y = float(xy[0]), float(xy[1])
        d = np.sqrt((x - sensor_xy[:, 0]) ** 2 + (y - sensor_xy[:, 1]) ** 2)
        travel = d / v
        return float(np.mean(t_sec - travel) * 1e6)

    best_xy = None
    best_cost = float("inf")
    starts = []
    xs = np.linspace(0, L, max(3, int(grid_n)))
    ys = np.linspace(0, W, max(3, int(grid_n)))
    for xx in xs:
        for yy in ys:
            starts.append((xx, yy))
    starts.append(tuple(np.mean(sensor_xy, axis=0)))

    if optimize is not None:
        for s in starts:
            try:
                res = optimize.least_squares(
                    residual_us_xy,
                    x0=np.array([np.clip(s[0], 0, L), np.clip(s[1], 0, W)]),
                    bounds=([0.0, 0.0], [L, W]),
                    method="trf",
                    max_nfev=300,
                    xtol=1e-12,
                    ftol=1e-12,
                    gtol=1e-12,
                )
                cost = float(np.sum(res.fun ** 2))
                if res.success and cost < best_cost:
                    best_cost = cost
                    best_xy = res.x
            except Exception:
                pass
    if best_xy is None:
        for s in starts:
            r = residual_us_xy(s)
            cost = float(np.sum(r ** 2))
            if cost < best_cost:
                best_cost = cost
                best_xy = np.array(s, dtype=float)

    best_res = residual_us_xy(best_xy)
    error_mm = None
    if target_xy is not None:
        target_xy = np.asarray(target_xy, dtype=float).ravel()
        if target_xy.size >= 2 and np.all(np.isfinite(target_xy[:2])):
            error_mm = float(np.linalg.norm(best_xy[:2] - target_xy[:2]) * 1000.0)
    return LocalizationResult(
        pred_x_m=float(best_xy[0]),
        pred_y_m=float(best_xy[1]),
        t0_us=float(solve_t0_us(best_xy)),
        rms_residual_us=float(np.sqrt(np.mean(best_res ** 2))),
        max_abs_residual_us=float(np.max(np.abs(best_res))),
        residuals_us=np.asarray(best_res, dtype=float),
        error_mm=error_mm,
    )


# -----------------------------------------------------------------------------
# Main D1-AIC localization pipeline
# -----------------------------------------------------------------------------

def prepare_signals_and_d1(X_raw: np.ndarray, params: D1AICLocalizationParams) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    opt = params.d1aic
    X = np.asarray(X_raw, dtype=float)
    if X.ndim != 2:
        raise ValueError("X_raw must be Nsamples x Nchannels.")
    div = float(opt.voltage_divisor) if float(opt.voltage_divisor) != 0 else 1.0
    Xp = X / div
    Xp = np.nan_to_num(Xp, nan=0.0)
    if opt.remove_mean:
        Xp = Xp - np.mean(Xp, axis=0, keepdims=True)
    Xp = highpass_filter_matrix(Xp, params.fs, opt.highpass_enabled, opt.highpass_cutoff_hz, opt.highpass_order)
    d1 = np.abs(first_difference_matrix(Xp, params.fs, opt.divide_diff_by_dt))
    if int(opt.diff_smooth_pts) > 1:
        for ch in range(d1.shape[1]):
            d1[:, ch] = moving_average(d1[:, ch], int(opt.diff_smooth_pts))
    trigger = params.trigger_index if params.trigger_index is not None else Xp.shape[0] // 4
    time_us = (np.arange(Xp.shape[0], dtype=float) - float(trigger)) / float(params.fs) * 1e6
    return time_us, Xp, d1


def compute_dynamic_d1_aic_results(channel_labels: Sequence[str], time_us: np.ndarray, d1_abs: np.ndarray,
                                   opt: D1AICOptions) -> List[ChannelD1AICResult]:
    detect_start = float(opt.threshold_detect_start_us)
    detect_end = float(opt.threshold_detect_end_us)
    if detect_end <= detect_start:
        raise ValueError("Threshold detection end must be greater than start.")
    if opt.aic_offset_end_us <= opt.aic_offset_start_us:
        raise ValueError("AIC end offset must be greater than start offset.")

    n_ch = int(d1_abs.shape[1])
    rms_list = []
    baseline_info = []
    for i in range(n_ch):
        rms, b0, b1, bn = compute_baseline_rms(d1_abs[:, i], time_us, detect_start, opt.rms_baseline_duration_us)
        rms_list.append(float(rms))
        baseline_info.append((float(rms), float(b0), float(b1), int(bn)))

    mode = str(opt.threshold_mode).strip().lower()
    if mode == "mean_all_channels":
        rms_used = [float(np.mean(rms_list))] * n_ch
    elif mode == "max_all_channels":
        rms_used = [float(np.max(rms_list))] * n_ch
    else:
        rms_used = rms_list

    results: List[ChannelD1AICResult] = []
    for i in range(n_ch):
        ch = channel_labels[i] if i < len(channel_labels) else f"CH{i+1}"
        rms_raw, b0, b1, bn = baseline_info[i]
        th = float(rms_used[i]) * float(opt.threshold_multiplier)
        threshold_idx, threshold_time = find_first_threshold_crossing(
            d1_abs[:, i], time_us, th, detect_start, detect_end
        )
        search_start = float(threshold_time) + float(opt.aic_offset_start_us)
        search_end = float(threshold_time) + float(opt.aic_offset_end_us)
        aic_time, aic_curve, arrival_idx, arrival_time, aic_min, idx0, idx1 = compute_windowed_aic(
            d1_abs[:, i], time_us, search_start, search_end,
            min_side=int(opt.aic_min_side_pts), smooth_pts=int(opt.aic_smooth_pts)
        )
        results.append(ChannelD1AICResult(
            channel=str(ch),
            arrival_index=int(arrival_idx),
            arrival_time_us=float(arrival_time),
            aic_min=float(aic_min),
            threshold_index=int(threshold_idx),
            threshold_time_us=float(threshold_time),
            threshold_value=float(th),
            baseline_rms=float(rms_raw),
            baseline_start_us=float(b0),
            baseline_end_us=float(b1),
            baseline_n=int(bn),
            threshold_multiplier=float(opt.threshold_multiplier),
            threshold_detect_start_us=detect_start,
            threshold_detect_end_us=detect_end,
            search_offset_start_us=float(opt.aic_offset_start_us),
            search_offset_end_us=float(opt.aic_offset_end_us),
            search_start_index=int(idx0),
            search_end_index=int(idx1),
            search_start_us=float(time_us[idx0]),
            search_end_us=float(time_us[min(idx1 - 1, len(time_us) - 1)]),
            aic_time_us=np.asarray(aic_time, dtype=float),
            aic_curve=np.asarray(aic_curve, dtype=float),
        ))
    return results


def d1_aic_localize(X_raw: np.ndarray, fs: float, params: D1AICLocalizationParams,
                    trigger_index: Optional[int] = None, target_xy: Optional[np.ndarray] = None,
                    channel_labels: Optional[Sequence[str]] = None,
                    sensor_names: Optional[Sequence[str]] = None) -> Dict[str, object]:
    X_raw = np.asarray(X_raw, dtype=float)
    if X_raw.ndim != 2 or X_raw.shape[1] < 3:
        raise ValueError("D1-AIC localization requires Nsamples x Nchannels with at least 3 channels.")
    params.fs = float(fs)
    if trigger_index is not None:
        params.trigger_index = int(trigger_index)
    n_ch = int(X_raw.shape[1])
    if channel_labels is None:
        channel_labels = [f"CH{i+1}" for i in range(n_ch)]
    if sensor_names is None:
        sensor_names = [f"S{i+1}" for i in range(n_ch)]

    sensor_xy = np.asarray(params.sensor_xy, dtype=float)
    if sensor_xy.shape[0] != n_ch:
        raise ValueError(f"Sensor coordinate count ({sensor_xy.shape[0]}) must equal selected channel count ({n_ch}).")

    time_us, X_processed, d1_abs = prepare_signals_and_d1(X_raw, params)
    arrivals = compute_dynamic_d1_aic_results(channel_labels, time_us, d1_abs, params.d1aic)
    arrival_us = np.array([r.arrival_time_us for r in arrivals], dtype=float)
    tdoa_to_ch1_us = arrival_us - arrival_us[0]

    fft_res = compute_arrival_window_fft(
        X_processed, time_us, params.fs, arrivals,
        pre_us=params.d1aic.fft_pre_us,
        post_us=params.d1aic.fft_post_us,
        fmin_hz=params.d1aic.fft_fmin_hz,
        fmax_hz=params.d1aic.fft_fmax_hz,
        nfft_factor=params.d1aic.fft_nfft_factor,
    )

    if params.d1aic.manual_velocity_enable:
        v = float(params.d1aic.manual_velocity_m_s)
        velocity_info = {"method": "manual", "velocity_m_s": v, "fft_peak_hz": float(fft_res["peak_hz"])}
    else:
        v, velocity_info = estimate_velocity_from_lamb_or_fallback(
            float(fft_res["peak_hz"]), params.material, params.d1aic.lamb_mode, params.d1aic.velocity_type
        )
        velocity_info["velocity_m_s"] = float(v)

    loc = locate_source_toa(
        sensor_xy=sensor_xy,
        arrival_us=arrival_us,
        velocity_m_s=v,
        board_length_m=float(params.plate_xy[0]),
        board_width_m=float(params.plate_xy[1]),
        grid_n=int(params.d1aic.loc_grid_n),
        target_xy=target_xy,
    )
    loc_dict = loc.to_dict()
    final_pos = np.array([loc.pred_x_m, loc.pred_y_m], dtype=float)

    return {
        "method": "Dynamic RMS threshold + |D1| AIC + summed FFT velocity + TOA localization",
        "X_raw": X_raw,
        "X_processed": X_processed,
        "d1_abs": d1_abs,
        "time_us": time_us,
        "arrival_results": [r.to_dict() for r in arrivals],
        "arrival_us": arrival_us,
        "tdoa_to_ch1_us": tdoa_to_ch1_us,
        "fft": fft_res,
        "velocity_m_s": float(v),
        "velocity_info": velocity_info,
        "loc_result": loc_dict,
        "finalPos": final_pos,
        "target_xy": None if target_xy is None else np.asarray(target_xy, dtype=float),
        "params": params,
        "selected_channel_labels": list(channel_labels),
        "selected_sensor_names": list(sensor_names),
        "selected_channel_indices": list(range(n_ch)),
        "ref_global_channel": 1,
        "nValid": int(n_ch),
        "elapsed_s": np.nan,
    }
