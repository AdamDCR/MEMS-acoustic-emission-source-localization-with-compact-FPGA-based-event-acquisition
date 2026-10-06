# -*- coding: utf-8 -*-
"""
batch_compare_localization_v7.py

批量计算 AE 声源定位结果，并把“文件名中的真实坐标”和 V7 定位算法计算出的预计坐标进行对比。

用法：
    1) 将本文件放到 ae_python_39_acq_loc_multich_v7 工程根目录，即与 ae_gui.py 同级。
    2) 在该目录运行：
       E:\\1.tools\\py\\python.exe batch_compare_localization_v7.py --data-dir E:\\AE_DATA

输入文件命名：
    Nchannel_x_y.csv
    例如：4channel_0.17_0.269.csv

输出目录：
    默认 E:\\AE_DATA\\localization_compare_v7

输出文件：
    localization_comparison.csv          每个文件的真实坐标、预计坐标、误差
    localization_summary.json            平均误差、RMSE 等统计结果
    per_file_band_results/*.csv          每个文件的子波包定位详细结果
    plots/location_comparison.png        真实点/预计点对比图
    plots/error_hist.png                 误差直方图
    plots/error_by_file.png              各文件误差曲线

说明：
    - 定位算法直接调用当前工程中的 ae_localization.core，即 V7 版本算法。
    - 真实坐标优先从文件名 Nchannel_x_y.csv 解析；若解析失败，再尝试读取同名 JSON 中 target_xy_m。
    - 传感器坐标优先从同名 JSON 中 sensor_xy_m_all_ch1_to_ch16 读取。
    - 默认 WPT 层数 4，能量阈值 0.001，不额外做带通滤波，保持 V7 core.py 的 preprocess_signals 行为。
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np
import pandas as pd

# --------------------------------------------------------------------------------------
# Import V7 localization core from the current project.
# --------------------------------------------------------------------------------------
try:
    from ae_localization.core import (  # type: ignore
        LocalizationParams,
        MaterialParams,
        compute_wpt_subband_energy,
        default_band_table,
        preprocess_signals,
        process_ae_wpt_localization_toa,
        update_band_velocity_by_lamb,
    )
except Exception as exc:  # pragma: no cover
    raise ImportError(
        "无法导入 ae_localization.core。请把 batch_compare_localization_v7.py 放到 "
        "ae_python_39_acq_loc_multich_v7 工程根目录，即与 ae_gui.py 同级。\n"
        f"原始错误：{exc}"
    ) from exc


FILENAME_RE = re.compile(
    r"(?P<n>\d+)\s*channel[_\-](?P<x>[-+]?\d+(?:\.\d+)?)[_\-](?P<y>[-+]?\d+(?:\.\d+)?)",
    re.IGNORECASE,
)


# --------------------------------------------------------------------------------------
# Basic helpers
# --------------------------------------------------------------------------------------
def safe_float(x: Any, default: float = float("nan")) -> float:
    try:
        v = float(x)
        return v if np.isfinite(v) else default
    except Exception:
        return default


def safe_int(x: Any, default: int = 0) -> int:
    try:
        return int(round(float(x)))
    except Exception:
        return default


def parse_true_xy_from_filename(csv_path: Path) -> Tuple[Optional[int], Optional[Tuple[float, float]]]:
    m = FILENAME_RE.search(csv_path.stem)
    if not m:
        return None, None
    n = int(m.group("n"))
    x = float(m.group("x"))
    y = float(m.group("y"))
    return n, (x, y)


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
    if 1 <= ch <= 16:
        return ch
    return None


def channel_mask_to_channels(mask_value: Any) -> List[int]:
    if mask_value is None:
        return []
    if isinstance(mask_value, str):
        s = mask_value.strip().lower()
        try:
            if s.startswith("0x"):
                val = int(s, 16)
            else:
                val = int(s, 16)
        except Exception:
            return []
    else:
        try:
            val = int(mask_value)
        except Exception:
            return []
    return [i + 1 for i in range(16) if (val >> i) & 1]


def format_channels(chs: Sequence[int]) -> str:
    return ",".join(f"CH{int(c):02d}" for c in chs)


def compact_reason(exc: BaseException) -> str:
    msg = str(exc).replace("\n", " ").replace("\r", " ").strip()
    return msg[:500]


# --------------------------------------------------------------------------------------
# CSV and metadata loading
# --------------------------------------------------------------------------------------
def read_waveform_csv(csv_path: Path) -> Tuple[pd.DataFrame, Dict[int, str]]:
    """Read waveform CSV and return dataframe plus {physical_channel: column_name}."""
    # utf-8-sig handles BOM in files exported by the GUI.
    df = pd.read_csv(csv_path, encoding="utf-8-sig")
    if df.empty:
        raise ValueError("CSV 文件为空。")

    ch_col_map: Dict[int, str] = {}
    for col in df.columns:
        ch = channel_label_to_number(str(col))
        if ch is not None:
            ch_col_map[ch] = str(col)

    # Fallback: if no CHxx columns, assume columns after sample_index/time_us are channel data.
    if not ch_col_map:
        numeric_cols = []
        for col in df.columns:
            name = str(col).strip().lower()
            if name in {"sample_index", "index", "time_us", "time", "t"}:
                continue
            try:
                pd.to_numeric(df[col].iloc[: min(20, len(df))])
                numeric_cols.append(str(col))
            except Exception:
                continue
        for i, col in enumerate(numeric_cols[:16], start=1):
            ch_col_map[i] = col

    if not ch_col_map:
        raise ValueError("未在 CSV 中找到 CHxx 通道列，也无法从数值列推断通道。")

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
    # Keep only channels present in CSV.
    active = [ch for ch in active if ch in ch_col_map]
    return sorted(dict.fromkeys(active))


def get_sensor_xy_all(meta: Dict[str, Any]) -> np.ndarray:
    """Return 16x2 sensor coordinate matrix. Missing values default to (0,0)."""
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
    if arr is None:
        return np.zeros((16, 2), dtype=float)
    out = np.zeros((16, 2), dtype=float)
    a = np.asarray(arr, dtype=float)
    if a.ndim == 2 and a.shape[1] >= 2:
        n = min(16, a.shape[0])
        out[:n, :] = a[:n, :2]
    return out


def get_sensor_names_all(meta: Dict[str, Any]) -> List[str]:
    names = meta.get("sensor_names_all_ch1_to_ch16") or meta.get("sensor_names") or []
    out = [f"S{i}" for i in range(1, 17)]
    if isinstance(names, list):
        for i, v in enumerate(names[:16]):
            if str(v).strip():
                out[i] = str(v).strip()
    return out


def select_localization_channels(active_channels: List[int], filename_n: Optional[int], requested: str) -> List[int]:
    if not active_channels:
        raise ValueError("没有可用采样通道。")
    if requested.lower() == "auto":
        # Prefer N from filename.  Otherwise use all active channels, limited to 4/8/12/16 style sizes.
        n = filename_n if filename_n is not None else len(active_channels)
    else:
        n = safe_int(requested, 0)
    if n not in (4, 8, 12, 16):
        # For unusual file names, still allow using current active count if it is valid.
        if len(active_channels) in (4, 8, 12, 16):
            n = len(active_channels)
        else:
            raise ValueError(f"定位通道数必须是 4/8/12/16 或 auto，当前得到 {n}。")
    if n > len(active_channels):
        raise ValueError(f"定位通道数 {n} 大于当前采样有效通道数 {len(active_channels)}。")
    return active_channels[:n]


def build_signal_matrix(df: pd.DataFrame, ch_col_map: Dict[int, str], selected_channels: Sequence[int]) -> np.ndarray:
    cols = [ch_col_map[ch] for ch in selected_channels]
    X = df[cols].apply(pd.to_numeric, errors="coerce").to_numpy(dtype=float)
    ok = np.all(np.isfinite(X), axis=1)
    X = X[ok, :]
    if X.shape[0] < 128:
        raise ValueError(f"有效波形点数过少：{X.shape[0]}。")
    return X


# --------------------------------------------------------------------------------------
# Localization wrapper using V7 core
# --------------------------------------------------------------------------------------
def run_v7_localization_for_file(
    csv_path: Path,
    loc_channels: str = "auto",
    ref_physical_channel: int = 1,
    fs_override: Optional[float] = None,
    wpt_level: int = 4,
    energy_threshold: float = 0.001,
    aic_pre_us: float = 200.0,
    aic_post_us: float = 100.0,
    plate_x_m: float = 0.50,
    plate_y_m: float = 0.50,
    thickness_m: float = 0.006,
    mode: str = "A0",
    wavelet: str = "db6",
    residual_threshold: float = 1e-6,
    quality_threshold: float = 6.0,
) -> Tuple[Dict[str, Any], pd.DataFrame]:
    meta = load_json_sidecar(csv_path)
    filename_n, true_xy_from_name = parse_true_xy_from_filename(csv_path)
    true_xy = true_xy_from_name
    if true_xy is None and isinstance(meta.get("target_xy_m"), list) and len(meta["target_xy_m"]) >= 2:
        true_xy = (safe_float(meta["target_xy_m"][0]), safe_float(meta["target_xy_m"][1]))
    if true_xy is None or not np.all(np.isfinite(true_xy)):
        raise ValueError("无法从文件名 Nchannel_x_y 或 JSON target_xy_m 解析真实坐标。")

    df, ch_col_map = read_waveform_csv(csv_path)
    active_channels = infer_active_channels(meta, ch_col_map)
    selected_channels = select_localization_channels(active_channels, filename_n, loc_channels)
    X_raw = build_signal_matrix(df, ch_col_map, selected_channels)

    fs = fs_override if fs_override is not None else safe_float(meta.get("sample_rate_hz"), 2.0e6)
    trigger_index = meta.get("trigger_offset", None)
    if trigger_index is None:
        trigger_index = meta.get("pre_samples", None)
    trigger_index = safe_int(trigger_index, 2048)

    sensor_xy_all = get_sensor_xy_all(meta)
    sensor_names_all = get_sensor_names_all(meta)
    sensor_xy = np.vstack([sensor_xy_all[ch - 1] for ch in selected_channels]).astype(float)
    if sensor_xy.shape[0] != len(selected_channels):
        raise ValueError("传感器坐标数量与定位通道数量不一致。")
    if np.linalg.matrix_rank(sensor_xy - np.mean(sensor_xy, axis=0, keepdims=True)) < 2:
        # Not fatal, but almost always indicates default (0,0) or collinear bad coordinates.
        raise ValueError(
            "参与定位的传感器坐标退化：可能仍为默认(0,0)或共线。请检查同名 JSON 中传感器坐标。"
        )

    if ref_physical_channel in selected_channels:
        ref_idx_relative = selected_channels.index(ref_physical_channel) + 1
        ref_phy = ref_physical_channel
    else:
        ref_idx_relative = 1
        ref_phy = selected_channels[0]

    params = LocalizationParams()
    params.fs = float(fs)
    params.wavelet_name = str(wavelet)
    params.wpt_level = int(wpt_level)
    params.ref_channel = int(ref_idx_relative)  # relative 1-based channel index for selected X_raw
    params.sensor_xy = sensor_xy
    params.plate_xy = np.array([float(plate_x_m), float(plate_y_m)], dtype=float)
    params.energy_threshold = float(energy_threshold)
    params.residual_threshold = float(residual_threshold)
    params.default_mode = str(mode)
    params.material = MaterialParams(thickness_m=float(thickness_m))
    params.toa.aic_pre_us = float(aic_pre_us)
    params.toa.aic_post_us = float(aic_post_us)
    params.toa.quality_threshold = float(quality_threshold)
    params.event.pre_us = float(aic_pre_us)
    params.event.post_us = float(aic_post_us)
    params.event.trigger_index = int(trigger_index)

    # Use V7 core preprocessing.  In recent V6/V7 this should be no-filter mean/std normalization.
    X = preprocess_signals(X_raw, params.fs, params.filter_low_hz, params.filter_high_hz)
    subbands, energy_ratio = compute_wpt_subband_energy(X, params.wpt_level, params.wavelet_name)
    band_config = default_band_table(
        2 ** int(params.wpt_level),
        params.fs,
        params.material.thickness_m * 1000.0,
        params.default_mode,
    )
    band_config["EnergyRatio"] = energy_ratio
    band_config, lamb = update_band_velocity_by_lamb(band_config, params.material)

    out = process_ae_wpt_localization_toa(X, subbands, energy_ratio, params, band_config)
    final_pos = np.asarray(out.get("finalPos", [np.nan, np.nan]), dtype=float)
    n_valid = int(out.get("nValid", 0))
    band_results = out.get("bandResults")
    if not isinstance(band_results, pd.DataFrame):
        band_results = pd.DataFrame()

    dx = float(final_pos[0] - true_xy[0]) if np.all(np.isfinite(final_pos)) else float("nan")
    dy = float(final_pos[1] - true_xy[1]) if np.all(np.isfinite(final_pos)) else float("nan")
    err_m = math.hypot(dx, dy) if np.isfinite(dx) and np.isfinite(dy) else float("nan")

    row: Dict[str, Any] = {
        "file": str(csv_path),
        "file_name": csv_path.name,
        "status": "OK" if np.all(np.isfinite(final_pos)) else "NO_VALID_RESULT",
        "message": "",
        "file_channel_count": filename_n if filename_n is not None else meta.get("channel_count", ""),
        "sampled_channel_count": len(active_channels),
        "loc_channel_count": len(selected_channels),
        "active_channels": format_channels(active_channels),
        "selected_channels": format_channels(selected_channels),
        "selected_sensor_names": ",".join(sensor_names_all[ch - 1] for ch in selected_channels),
        "ref_physical_channel": f"CH{ref_phy:02d}",
        "ref_relative_index": ref_idx_relative,
        "true_x_m": float(true_xy[0]),
        "true_y_m": float(true_xy[1]),
        "pred_x_m": float(final_pos[0]),
        "pred_y_m": float(final_pos[1]),
        "error_x_m": dx,
        "error_y_m": dy,
        "error_m": err_m,
        "error_mm": err_m * 1000.0 if np.isfinite(err_m) else float("nan"),
        "n_valid_bands": n_valid,
        "fs_hz": float(fs),
        "trigger_index": int(trigger_index),
        "wpt_level": int(wpt_level),
        "energy_threshold": float(energy_threshold),
        "aic_pre_us": float(aic_pre_us),
        "aic_post_us": float(aic_post_us),
        "wavelet": str(wavelet),
        "lamb_mode": str(mode),
        "plate_x_m": float(plate_x_m),
        "plate_y_m": float(plate_y_m),
        "thickness_m": float(thickness_m),
        "event_seq": meta.get("event_seq", ""),
        "channel_mask_hex": meta.get("channel_mask_hex", ""),
        "json_sidecar": str(csv_path.with_suffix(".json")) if csv_path.with_suffix(".json").exists() else "",
    }
    return row, band_results


# --------------------------------------------------------------------------------------
# Batch execution and reporting
# --------------------------------------------------------------------------------------
def discover_csv_files(data_dir: Path, output_dir: Path) -> List[Path]:
    files: List[Path] = []
    for p in data_dir.rglob("*.csv"):
        # avoid re-processing previous output files
        try:
            if output_dir in p.parents:
                continue
        except Exception:
            pass
        if p.name.lower() in {"localization_comparison.csv", "batch_summary.csv", "batch_failures.csv"}:
            continue
        if FILENAME_RE.search(p.stem) or p.with_suffix(".json").exists():
            files.append(p)
    return sorted(files)


def write_summary(rows: List[Dict[str, Any]], out_dir: Path) -> Dict[str, Any]:
    df = pd.DataFrame(rows)
    ok = df["status"].eq("OK") if "status" in df.columns else pd.Series([], dtype=bool)
    err = pd.to_numeric(df.loc[ok, "error_mm"], errors="coerce") if ok.any() else pd.Series([], dtype=float)
    summary = {
        "total_files": int(len(df)),
        "success_files": int(ok.sum()) if len(df) else 0,
        "failed_files": int((~ok).sum()) if len(df) else 0,
        "mean_error_mm": float(err.mean()) if len(err) else None,
        "median_error_mm": float(err.median()) if len(err) else None,
        "rmse_error_mm": float(np.sqrt(np.nanmean(err.to_numpy(dtype=float) ** 2))) if len(err) else None,
        "max_error_mm": float(err.max()) if len(err) else None,
        "min_error_mm": float(err.min()) if len(err) else None,
    }
    with (out_dir / "localization_summary.json").open("w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    return summary


def make_plots(df: pd.DataFrame, out_dir: Path) -> None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as exc:
        print(f"[WARN] 无法导入 matplotlib，跳过绘图：{exc}")
        return

    plot_dir = out_dir / "plots"
    plot_dir.mkdir(parents=True, exist_ok=True)
    ok = df["status"].eq("OK") if "status" in df.columns else pd.Series([], dtype=bool)
    d = df.loc[ok].copy()
    if d.empty:
        return

    true_x = pd.to_numeric(d["true_x_m"], errors="coerce").to_numpy(float)
    true_y = pd.to_numeric(d["true_y_m"], errors="coerce").to_numpy(float)
    pred_x = pd.to_numeric(d["pred_x_m"], errors="coerce").to_numpy(float)
    pred_y = pd.to_numeric(d["pred_y_m"], errors="coerce").to_numpy(float)
    err_mm = pd.to_numeric(d["error_mm"], errors="coerce").to_numpy(float)

    plt.figure(figsize=(7.2, 5.6), dpi=160)
    plt.scatter(true_x, true_y, marker="o", label="True", s=42)
    plt.scatter(pred_x, pred_y, marker="x", label="Estimated", s=50)
    for x0, y0, x1, y1 in zip(true_x, true_y, pred_x, pred_y):
        if np.all(np.isfinite([x0, y0, x1, y1])):
            plt.plot([x0, x1], [y0, y1], "-", linewidth=0.8, alpha=0.55)
    plt.xlabel("X / m")
    plt.ylabel("Y / m")
    plt.title("Localization comparison")
    plt.grid(True, alpha=0.3)
    plt.axis("equal")
    plt.legend()
    plt.tight_layout()
    plt.savefig(plot_dir / "location_comparison.png")
    plt.close()

    if np.any(np.isfinite(err_mm)):
        plt.figure(figsize=(7.2, 4.2), dpi=160)
        plt.hist(err_mm[np.isfinite(err_mm)], bins=min(20, max(5, len(err_mm) // 2)))
        plt.xlabel("Error / mm")
        plt.ylabel("Count")
        plt.title("Localization error distribution")
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(plot_dir / "error_hist.png")
        plt.close()

        plt.figure(figsize=(9.0, 4.2), dpi=160)
        plt.plot(np.arange(1, len(err_mm) + 1), err_mm, "o-", linewidth=1.0)
        plt.xlabel("File index")
        plt.ylabel("Error / mm")
        plt.title("Localization error by file")
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(plot_dir / "error_by_file.png")
        plt.close()


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Batch localization comparison using V7 localization algorithm.")
    parser.add_argument("--data-dir", default=r"E:\ae_data0\50_50_0.6cm3", help="数据目录，默认 E:\ae_data0\50_50_0.6cm3")
    parser.add_argument("--output-dir", default="", help="输出目录，默认 data-dir/localization_compare_v7")
    parser.add_argument("--loc-channels", default="auto", choices=["auto", "4", "8", "12", "16"], help="参与定位通道数")
    parser.add_argument("--ref-channel", type=int, default=1, help="参考物理通道号，默认 CH1；若不在选中通道内则使用第一个选中通道")
    parser.add_argument("--fs", type=float, default=0.0, help="覆盖采样率 Hz；默认使用 JSON sample_rate_hz")
    parser.add_argument("--wpt-level", type=int, default=3, help="WPT 层数，默认 4")
    parser.add_argument("--energy-threshold", type=float, default=0.001, help="子波包能量阈值，默认 0.001")
    parser.add_argument("--aic-pre-us", type=float, default=3000.0, help="AIC 搜索窗前向 us，默认 180")
    parser.add_argument("--aic-post-us", type=float, default=200.0, help="AIC 搜索窗后向 us，默认 80")
    parser.add_argument("--plate-x", type=float, default=0.50, help="板长 X/m，默认 0.50")
    parser.add_argument("--plate-y", type=float, default=0.50, help="板宽 Y/m，默认 0.40")
    parser.add_argument("--thickness", type=float, default=0.006, help="板厚/m，默认 0.004")
    parser.add_argument("--mode", default="A0", choices=["A0", "S0", "A1", "S1"], help="Lamb 模态，默认 A0")
    parser.add_argument("--wavelet", default="db6", help="小波基，默认 db6")
    parser.add_argument("--residual-threshold", type=float, default=1e-5, help="残差阈值/s，默认 8e-6")
    parser.add_argument("--quality-threshold", type=float, default=6.0, help="TOA 质量阈值，默认 6")
    parser.add_argument("--no-plots", action="store_true", help="不生成 PNG 对比图")
    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir)
    if not data_dir.exists():
        print(f"[ERROR] 数据目录不存在：{data_dir}")
        return 2
    out_dir = Path(args.output_dir) if args.output_dir else data_dir / "localization_compare_v7"
    out_dir.mkdir(parents=True, exist_ok=True)
    per_dir = out_dir / "per_file_band_results"
    per_dir.mkdir(parents=True, exist_ok=True)

    csv_files = discover_csv_files(data_dir, out_dir)
    if not csv_files:
        print(f"[ERROR] 在 {data_dir} 中没有找到可处理的 CSV。要求文件名类似 4channel_0.17_0.269.csv。")
        return 3

    print(f"[INFO] 数据目录：{data_dir}")
    print(f"[INFO] 输出目录：{out_dir}")
    print(f"[INFO] 待处理文件数：{len(csv_files)}")
    print(f"[INFO] 定位算法：导入 ae_localization.core，路径={sys.modules.get('ae_localization.core').__file__}")

    rows: List[Dict[str, Any]] = []
    for idx, csv_path in enumerate(csv_files, start=1):
        print(f"[{idx}/{len(csv_files)}] {csv_path.name}")
        try:
            row, band_df = run_v7_localization_for_file(
                csv_path=csv_path,
                loc_channels=args.loc_channels,
                ref_physical_channel=args.ref_channel,
                fs_override=args.fs if args.fs and args.fs > 0 else None,
                wpt_level=args.wpt_level,
                energy_threshold=args.energy_threshold,
                aic_pre_us=args.aic_pre_us,
                aic_post_us=args.aic_post_us,
                plate_x_m=args.plate_x,
                plate_y_m=args.plate_y,
                thickness_m=args.thickness,
                mode=args.mode,
                wavelet=args.wavelet,
                residual_threshold=args.residual_threshold,
                quality_threshold=args.quality_threshold,
            )
            if not band_df.empty:
                band_path = per_dir / f"{csv_path.stem}_band_results.csv"
                band_df.to_csv(band_path, index=False, encoding="utf-8-sig")
                row["band_results_file"] = str(band_path)
            print(
                f"    OK: true=({row['true_x_m']:.4f},{row['true_y_m']:.4f}) m, "
                f"pred=({row['pred_x_m']:.4f},{row['pred_y_m']:.4f}) m, "
                f"err={row['error_mm']:.2f} mm, validBands={row['n_valid_bands']}"
            )
        except Exception as exc:
            filename_n, true_xy = parse_true_xy_from_filename(csv_path)
            row = {
                "file": str(csv_path),
                "file_name": csv_path.name,
                "status": "FAIL",
                "message": compact_reason(exc),
                "file_channel_count": filename_n if filename_n is not None else "",
                "true_x_m": true_xy[0] if true_xy else float("nan"),
                "true_y_m": true_xy[1] if true_xy else float("nan"),
                "pred_x_m": float("nan"),
                "pred_y_m": float("nan"),
                "error_m": float("nan"),
                "error_mm": float("nan"),
            }
            print(f"    FAIL: {row['message']}")
        rows.append(row)

    df_out = pd.DataFrame(rows)
    out_csv = out_dir / "localization_comparison.csv"
    df_out.to_csv(out_csv, index=False, encoding="utf-8-sig")

    fail_df = df_out[~df_out.get("status", pd.Series([], dtype=str)).eq("OK")]
    if not fail_df.empty:
        fail_df.to_csv(out_dir / "localization_failures.csv", index=False, encoding="utf-8-sig")

    summary = write_summary(rows, out_dir)
    if not args.no_plots:
        make_plots(df_out, out_dir)

    print("\n========== Batch localization comparison done ==========")
    print(f"结果对比表：{out_csv}")
    print(f"统计摘要：{out_dir / 'localization_summary.json'}")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
