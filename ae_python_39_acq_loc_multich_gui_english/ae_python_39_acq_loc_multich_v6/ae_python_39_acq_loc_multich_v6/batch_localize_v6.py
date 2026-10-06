# -*- coding: utf-8 -*-
r"""
batch_localize_v6.py

Batch localization tool for ae_python_39_acq_loc_multich_v6 saved event files.

Usage examples on Windows:

    cd C:\Users\Administrator\Downloads\ae_python_39_acq_loc_multich_v6
    E:\1.tools\py\python.exe batch_localize_v6.py --data-dir E:\AE_DATA

Specify localization channel count:

    E:\1.tools\py\python.exe batch_localize_v6.py --data-dir E:\AE_DATA --loc-channels 4
    E:\1.tools\py\python.exe batch_localize_v6.py --data-dir E:\AE_DATA --loc-channels auto

Outputs:
    E:\AE_DATA\batch_localization_results\batch_summary.csv
    E:\AE_DATA\batch_localization_results\batch_failures.csv
    E:\AE_DATA\batch_localization_results\per_file\<stem>_band_results.csv
    E:\AE_DATA\batch_localization_results\per_file\<stem>_loc_result.json

This script is independent of UDP acquisition. It only reads saved CSV/JSON files.
It follows the v6 GUI localization workflow:
    - no band-pass filtering before WPT/AIC;
    - WPT decomposition;
    - Lamb-wave group velocity per band;
    - trigger-index anchored envelope window + AIC TOA picking;
    - TDOA localization;
    - weighted fusion over valid subbands.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
import time
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
import pandas as pd

# Import v6 localization core from the current project directory.
try:
    from ae_localization.core import (
        LocalizationParams,
        MaterialParams,
        TOAOptions,
        EventWindowOptions,
        preprocess_signals,
        compute_wpt_subband_energy,
        default_band_table,
        update_band_velocity_by_lamb,
        process_ae_wpt_localization_toa,
    )
except Exception as exc:
    raise ImportError(
        "Cannot import ae_localization.core. Put this script in the root directory "
        "of ae_python_39_acq_loc_multich_v6, or run it from that directory.\n"
        "Expected structure: ./ae_localization/core.py"
    ) from exc


VALID_LOC_COUNTS = (4, 8, 12, 16)


def natural_key(path: Path):
    parts = re.split(r"(\d+)", str(path))
    return [int(p) if p.isdigit() else p.lower() for p in parts]


def safe_float(x, default=np.nan) -> float:
    try:
        v = float(x)
        return v if math.isfinite(v) else default
    except Exception:
        return default


def safe_int(x, default=0) -> int:
    try:
        return int(round(float(x)))
    except Exception:
        return default


def parse_target_from_filename(path: Path) -> Tuple[float, float]:
    """Parse Nchannel_x_y.csv style filename."""
    # Match examples: 4channel_0.17_0.269.csv, 8channel_-0.1_0.2.csv
    m = re.search(r"(?i)(\d+)channel_([+-]?\d+(?:\.\d+)?)_([+-]?\d+(?:\.\d+)?)", path.stem)
    if not m:
        return (np.nan, np.nan)
    return (float(m.group(2)), float(m.group(3)))


def load_json_sidecar(csv_path: Path) -> Dict[str, object]:
    jp = csv_path.with_suffix(".json")
    if not jp.exists():
        return {}
    with jp.open("r", encoding="utf-8") as f:
        return json.load(f)


def parse_channel_label(label: str) -> Optional[int]:
    """Return zero-based channel index from CH01 / CH1 / CH01_S1 strings."""
    m = re.search(r"(?i)CH\s*0*(\d+)", str(label))
    if not m:
        return None
    ch = int(m.group(1))
    if 1 <= ch <= 16:
        return ch - 1
    return None


def active_indices_from_mask(mask_hex: str) -> List[int]:
    try:
        s = str(mask_hex).strip()
        if not s:
            return []
        mask = int(s, 16) if s.lower().startswith("0x") else int(s, 16)
        return [i for i in range(16) if (mask >> i) & 1]
    except Exception:
        return []


def load_saved_event_csv(csv_path: Path) -> Dict[str, object]:
    """Load one saved v6 event CSV and sidecar JSON.

    CSV format from GUI normally is:
        sample_index,time_us,CH01_S1,CH02_S2,...
    """
    meta = load_json_sidecar(csv_path)

    # Read CSV. UTF-8-SIG removes BOM from the first header.
    df = pd.read_csv(csv_path, encoding="utf-8-sig")
    if df.empty:
        raise ValueError("CSV 文件为空。")

    ch_cols: List[str] = []
    ch_indices: List[int] = []
    for c in df.columns:
        idx = parse_channel_label(c)
        if idx is not None:
            ch_cols.append(c)
            ch_indices.append(idx)

    # Fallback: use JSON saved_channels to identify channel columns if needed.
    if not ch_cols:
        saved = meta.get("saved_channels", []) if isinstance(meta, dict) else []
        wanted = [parse_channel_label(x) for x in saved]
        wanted = [x for x in wanted if x is not None]
        numeric_cols = [c for c in df.columns if c not in ("sample_index", "time_us")]
        if len(wanted) == len(numeric_cols) and wanted:
            ch_cols = numeric_cols
            ch_indices = wanted

    if not ch_cols:
        # Last fallback: use all numeric columns after first two columns as channels.
        numeric_cols = []
        for c in df.columns:
            if c in ("sample_index", "time_us"):
                continue
            try:
                pd.to_numeric(df[c].iloc[:10], errors="raise")
                numeric_cols.append(c)
            except Exception:
                pass
        if not numeric_cols:
            raise ValueError("未在 CSV 中找到 CHxx 通道列。")
        ch_cols = numeric_cols
        ch_indices = list(range(len(ch_cols)))

    # Sort columns by physical channel number, so CH01,CH02,...
    order = np.argsort(ch_indices)
    ch_cols = [ch_cols[i] for i in order]
    ch_indices = [ch_indices[i] for i in order]

    samples = df[ch_cols].apply(pd.to_numeric, errors="coerce").to_numpy(dtype=float)
    finite_rows = np.all(np.isfinite(samples), axis=1)
    samples = samples[finite_rows, :]
    if samples.shape[0] < 100:
        raise ValueError(f"有效样本点过少：{samples.shape[0]}")

    # Metadata values.
    if isinstance(meta, dict) and "sample_rate_hz" in meta:
        fs = safe_float(meta.get("sample_rate_hz"), np.nan)
    else:
        # Infer from time_us column if available.
        fs = np.nan
        if "time_us" in df.columns:
            t = pd.to_numeric(df.loc[finite_rows, "time_us"], errors="coerce").to_numpy(dtype=float)
            if t.size >= 2:
                dt_us = np.nanmedian(np.diff(t))
                if math.isfinite(dt_us) and dt_us > 0:
                    fs = 1e6 / dt_us

    target_xy = None
    if isinstance(meta, dict) and "target_xy_m" in meta:
        target_xy = meta.get("target_xy_m")
    if not target_xy:
        target_xy = parse_target_from_filename(csv_path)
    target_xy = np.asarray(target_xy, dtype=float).reshape(2)

    sensor_names_all = []
    if isinstance(meta, dict):
        sensor_names_all = list(meta.get("sensor_names_all_ch1_to_ch16", []))
    if len(sensor_names_all) < 16:
        sensor_names_all = [f"S{i+1}" for i in range(16)]

    sensor_xy_all = None
    if isinstance(meta, dict) and "sensor_xy_m_all_ch1_to_ch16" in meta:
        sensor_xy_all = np.asarray(meta.get("sensor_xy_m_all_ch1_to_ch16"), dtype=float)
    if sensor_xy_all is None or sensor_xy_all.shape != (16, 2):
        # If only saved channel coordinates exist, fill all 16 with zero and place saved ones.
        sensor_xy_all = np.zeros((16, 2), dtype=float)
        saved_xy = meta.get("sensor_xy_m_saved_channels", []) if isinstance(meta, dict) else []
        saved_xy = np.asarray(saved_xy, dtype=float) if len(saved_xy) else np.empty((0, 2))
        if saved_xy.shape[0] == len(ch_indices):
            for pos, gidx in enumerate(ch_indices):
                sensor_xy_all[gidx, :] = saved_xy[pos, :]

    channel_mask_indices = []
    if isinstance(meta, dict):
        channel_mask_indices = active_indices_from_mask(str(meta.get("channel_mask_hex", "")))
    active_idx = ch_indices if ch_indices else channel_mask_indices

    trigger_offset = None
    if isinstance(meta, dict):
        trigger_offset = meta.get("trigger_offset", meta.get("pre_samples", None))
    trigger_offset = safe_int(trigger_offset, samples.shape[0] // 4)

    event_seq = safe_int(meta.get("event_seq", -1), -1) if isinstance(meta, dict) else -1

    return {
        "csv_path": str(csv_path),
        "meta_path": str(csv_path.with_suffix(".json")) if csv_path.with_suffix(".json").exists() else "",
        "meta": meta,
        "samples": samples,
        "active_channel_indices": active_idx,
        "selected_column_names": ch_cols,
        "sensor_names_all": sensor_names_all,
        "sensor_xy_all": sensor_xy_all,
        "target_xy": target_xy,
        "sample_rate_hz": fs,
        "trigger_offset": int(trigger_offset),
        "event_seq": event_seq,
    }


def choose_loc_channels(active_idx: Sequence[int], loc_channels: str) -> Tuple[int, List[int]]:
    n_active = len(active_idx)
    if n_active <= 0:
        raise ValueError("没有有效采样通道。")
    if str(loc_channels).lower() == "auto":
        # Choose the largest supported count not exceeding active channel count.
        candidates = [n for n in VALID_LOC_COUNTS if n <= n_active]
        if not candidates:
            raise ValueError(f"有效通道数 {n_active} 少于最小定位通道数 4。")
        n = max(candidates)
    else:
        n = int(loc_channels)
        if n not in VALID_LOC_COUNTS:
            raise ValueError("--loc-channels 只能是 auto / 4 / 8 / 12 / 16。")
        if n > n_active:
            raise ValueError(f"定位通道数 {n} 不能多于当前有效采样通道数 {n_active}。")
    return n, list(active_idx[:n])


def make_params(args, fs: float, selected_idx: List[int], sensor_xy_all: np.ndarray, trigger_offset: int) -> LocalizationParams:
    if not math.isfinite(fs) or fs <= 0:
        fs = float(args.default_fs)
    sensor_xy = np.asarray([sensor_xy_all[i] for i in selected_idx], dtype=float)
    if sensor_xy.shape[0] != len(selected_idx):
        raise ValueError("传感器坐标数量异常。")
    # Reference channel is specified as physical/global channel number, e.g. CH4.
    ref_global = int(args.ref_channel)
    selected_global = [i + 1 for i in selected_idx]
    if ref_global in selected_global:
        ref_relative = selected_global.index(ref_global) + 1
    else:
        # Match GUI behavior: if requested CH is not in selected set, use the last of first four.
        fallback_pos = min(3, len(selected_idx) - 1)
        ref_relative = fallback_pos + 1

    mode = str(args.mode).strip().upper() or "A0"
    if mode not in ("A0", "S0"):
        mode = "A0"

    params = LocalizationParams(
        fs=float(fs),
        wavelet_name=str(args.wavelet),
        wpt_level=int(args.wpt_level),
        ref_channel=int(ref_relative),
        sensor_xy=sensor_xy,
        plate_xy=np.array([float(args.plate_x), float(args.plate_y)], dtype=float),
        energy_threshold=float(args.energy_threshold),
        residual_threshold=float(args.residual_threshold),
        velocity_margin=float(args.velocity_margin),
        min_valid_sensors=int(args.min_valid_sensors),
        filter_low_hz=float(args.filter_low_hz),
        filter_high_hz=float(args.filter_high_hz),
        default_mode=mode,
        material=MaterialParams(
            E=float(args.E),
            nu=float(args.nu),
            rho=float(args.rho),
            thickness_m=float(args.thickness),
        ),
        toa=TOAOptions(
            method="包络事件窗+AIC",
            aic_pre_us=float(args.aic_pre_us),
            aic_post_us=float(args.aic_post_us),
            quality_threshold=float(args.toa_quality_threshold),
            aic_signal=str(args.aic_signal),
        ),
        event=EventWindowOptions(
            pre_us=float(args.aic_pre_us),
            post_us=float(args.aic_post_us),
            trigger_index=int(trigger_offset),
            min_pick_pre_samples=None,
        ),
    )
    return params


def run_one(csv_path: Path, args, out_per_file: Path) -> Dict[str, object]:
    data = load_saved_event_csv(csv_path)
    active_idx = list(data["active_channel_indices"])
    loc_n, selected_idx = choose_loc_channels(active_idx, args.loc_channels)

    samples_all = np.asarray(data["samples"], dtype=float)
    # CSV data columns are ordered by active_idx. Need positions corresponding to selected physical channels.
    active_to_pos = {gidx: pos for pos, gidx in enumerate(active_idx)}
    selected_pos = [active_to_pos[i] for i in selected_idx]
    X_raw = samples_all[:, selected_pos].astype(float, copy=True)

    fs = float(data["sample_rate_hz"]) if math.isfinite(float(data["sample_rate_hz"])) else float(args.default_fs)
    params = make_params(args, fs, selected_idx, data["sensor_xy_all"], int(data["trigger_offset"]))

    t0 = time.perf_counter()
    # v6 no-filter workflow: this only de-means and standardizes channels.
    X = preprocess_signals(X_raw, params.fs, params.filter_low_hz, params.filter_high_hz)
    subbands, energy_ratio = compute_wpt_subband_energy(X, params.wpt_level, params.wavelet_name)
    band_config = default_band_table(2 ** params.wpt_level, params.fs, params.material.thickness_m * 1000.0, params.default_mode)
    band_config["EnergyRatio"] = energy_ratio
    band_config, lamb = update_band_velocity_by_lamb(band_config, params.material)
    out = process_ae_wpt_localization_toa(X, subbands, energy_ratio, params, band_config)
    elapsed = time.perf_counter() - t0

    final_pos = np.asarray(out.get("finalPos", [np.nan, np.nan]), dtype=float)
    target_xy = np.asarray(data["target_xy"], dtype=float)
    err_m = float(np.linalg.norm(final_pos - target_xy)) if np.all(np.isfinite(final_pos)) and np.all(np.isfinite(target_xy)) else np.nan

    selected_labels = [f"CH{i+1:02d}" for i in selected_idx]
    names_all = list(data.get("sensor_names_all", []))
    selected_names = [names_all[i] if i < len(names_all) else f"S{i+1}" for i in selected_idx]
    ref_global = selected_idx[int(params.ref_channel) - 1] + 1

    stem = csv_path.stem
    band_results = out.get("bandResults")
    if isinstance(band_results, pd.DataFrame):
        band_csv = out_per_file / f"{stem}_band_results.csv"
        band_results.to_csv(band_csv, index=False, encoding="utf-8-sig")
    else:
        band_csv = ""

    # Compact result JSON, no large arrays.
    loc_json = {
        "source_csv": str(csv_path),
        "source_json": data.get("meta_path", ""),
        "event_seq": int(data.get("event_seq", -1)),
        "sample_rate_hz": float(params.fs),
        "trigger_offset": int(data.get("trigger_offset", -1)),
        "active_channels": [f"CH{i+1:02d}" for i in active_idx],
        "loc_channel_count": int(loc_n),
        "selected_channels": selected_labels,
        "selected_sensor_names": selected_names,
        "selected_sensor_xy_m": np.asarray(params.sensor_xy, dtype=float).tolist(),
        "ref_global_channel": int(ref_global),
        "target_xy_m": target_xy.tolist(),
        "estimated_xy_m": final_pos.tolist(),
        "error_m": err_m,
        "error_mm": err_m * 1000.0 if math.isfinite(err_m) else np.nan,
        "nValidBands": int(out.get("nValid", 0)),
        "elapsed_s": float(elapsed),
        "params": {
            "wpt_level": int(params.wpt_level),
            "wavelet": params.wavelet_name,
            "energy_threshold": float(params.energy_threshold),
            "residual_threshold": float(params.residual_threshold),
            "mode": params.default_mode,
            "aic_pre_us": float(params.toa.aic_pre_us),
            "aic_post_us": float(params.toa.aic_post_us),
            "toa_quality_threshold": float(params.toa.quality_threshold),
            "plate_xy_m": np.asarray(params.plate_xy, dtype=float).tolist(),
            "material": {
                "E": params.material.E,
                "nu": params.material.nu,
                "rho": params.material.rho,
                "thickness_m": params.material.thickness_m,
            },
        },
        "band_results_csv": str(band_csv),
    }
    loc_json_path = out_per_file / f"{stem}_loc_result.json"
    with loc_json_path.open("w", encoding="utf-8") as f:
        json.dump(loc_json, f, ensure_ascii=False, indent=2)

    row = {
        "status": "OK",
        "file": str(csv_path),
        "event_seq": int(data.get("event_seq", -1)),
        "sample_rate_hz": float(params.fs),
        "trigger_offset": int(data.get("trigger_offset", -1)),
        "active_channel_count": len(active_idx),
        "loc_channel_count": int(loc_n),
        "active_channels": ",".join([f"CH{i+1:02d}" for i in active_idx]),
        "selected_channels": ",".join(selected_labels),
        "ref_global_channel": int(ref_global),
        "target_x_m": target_xy[0],
        "target_y_m": target_xy[1],
        "estimated_x_m": final_pos[0],
        "estimated_y_m": final_pos[1],
        "error_m": err_m,
        "error_mm": err_m * 1000.0 if math.isfinite(err_m) else np.nan,
        "nValidBands": int(out.get("nValid", 0)),
        "elapsed_s": elapsed,
        "result_json": str(loc_json_path),
        "band_results_csv": str(band_csv),
        "message": "",
    }
    return row


def find_csv_files(root: Path, recursive: bool = True) -> List[Path]:
    pattern = "**/*.csv" if recursive else "*.csv"
    files = [p for p in root.glob(pattern) if p.is_file()]
    # Avoid processing previous result files.
    files = [p for p in files if "batch_localization_results" not in str(p)]
    # Prefer saved event files with Nchannel_x_y naming, but allow all CSV.
    files.sort(key=natural_key)
    return files


def write_rows_csv(path: Path, rows: List[Dict[str, object]]) -> None:
    if not rows:
        return
    # Keep stable column order: union all keys.
    keys: List[str] = []
    for r in rows:
        for k in r.keys():
            if k not in keys:
                keys.append(k)
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=keys)
        writer.writeheader()
        for r in rows:
            writer.writerow(r)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Batch AE source localization for v6 saved CSV/JSON data.")
    parser.add_argument("--data-dir", default=r"E:\AE_DATA", help="Directory containing saved event CSV/JSON files. Default: E:\\AE_DATA")
    parser.add_argument("--out-dir", default="", help="Output directory. Default: <data-dir>/batch_localization_results")
    parser.add_argument("--recursive", action="store_true", default=True, help="Search CSV recursively. Default: true")
    parser.add_argument("--no-recursive", dest="recursive", action="store_false", help="Only search the top-level data directory.")
    parser.add_argument("--loc-channels", default="auto", help="auto / 4 / 8 / 12 / 16. Default: auto")
    parser.add_argument("--default-fs", type=float, default=2.0e6, help="Fallback sampling rate when JSON/time_us is missing. Default: 2e6")

    # Localization defaults matching the latest v6 GUI workflow.
    parser.add_argument("--wpt-level", type=int, default=4, help="WPT level. Default: 4")
    parser.add_argument("--wavelet", default="db6", help="Wavelet name. Default: db6")
    parser.add_argument("--energy-threshold", type=float, default=0.001, help="Subband energy threshold. Default: 0.001")
    parser.add_argument("--residual-threshold", type=float, default=8e-6, help="Localization residual threshold in seconds. Default: 8e-6")
    parser.add_argument("--velocity-margin", type=float, default=1.35, help="TDOA physical check margin. Default: 1.35")
    parser.add_argument("--min-valid-sensors", type=int, default=3, help="Minimum valid sensors per band. Default: 3")
    parser.add_argument("--ref-channel", type=int, default=4, help="Reference physical channel number, e.g. 4 means CH04. Default: 4")
    parser.add_argument("--aic-pre-us", type=float, default=180.0, help="AIC search window before trigger, us. Default: 180")
    parser.add_argument("--aic-post-us", type=float, default=80.0, help="AIC search window after trigger, us. Default: 80")
    parser.add_argument("--toa-quality-threshold", type=float, default=6.0, help="TOA quality threshold. Default: 6")
    parser.add_argument("--aic-signal", default="原始子带", choices=["原始子带", "包络"], help="Signal used for AIC. Default: 原始子带")
    parser.add_argument("--mode", default="A0", choices=["A0", "S0"], help="Lamb mode. Default: A0")
    parser.add_argument("--plate-x", type=float, default=0.50, help="Plate length X in meters. Default: 0.50")
    parser.add_argument("--plate-y", type=float, default=0.40, help="Plate length Y in meters. Default: 0.40")
    parser.add_argument("--thickness", type=float, default=0.004, help="Plate thickness in meters. Default: 0.004")
    parser.add_argument("--E", type=float, default=70.0e9, help="Young's modulus. Default: 70e9")
    parser.add_argument("--nu", type=float, default=0.33, help="Poisson's ratio. Default: 0.33")
    parser.add_argument("--rho", type=float, default=2700.0, help="Density kg/m^3. Default: 2700")
    # Kept for core API compatibility; current v6 preprocess does not filter.
    parser.add_argument("--filter-low-hz", type=float, default=4.0e4, help="Kept for compatibility; v6 no-filter preprocess ignores it.")
    parser.add_argument("--filter-high-hz", type=float, default=5.0e5, help="Kept for compatibility; v6 no-filter preprocess ignores it.")

    args = parser.parse_args(argv)

    data_dir = Path(args.data_dir)
    if not data_dir.exists():
        print(f"ERROR: data directory does not exist: {data_dir}", file=sys.stderr)
        return 2
    out_dir = Path(args.out_dir) if args.out_dir else (data_dir / "batch_localization_results")
    per_file_dir = out_dir / "per_file"
    per_file_dir.mkdir(parents=True, exist_ok=True)

    csv_files = find_csv_files(data_dir, recursive=bool(args.recursive))
    if not csv_files:
        print(f"No CSV files found under: {data_dir}")
        return 1

    print(f"Found {len(csv_files)} CSV files under {data_dir}")
    print(f"Output directory: {out_dir}")

    summary_rows: List[Dict[str, object]] = []
    failure_rows: List[Dict[str, object]] = []
    for i, csv_path in enumerate(csv_files, start=1):
        print(f"[{i}/{len(csv_files)}] {csv_path.name} ...", end=" ", flush=True)
        try:
            row = run_one(csv_path, args, per_file_dir)
            summary_rows.append(row)
            err_mm = row.get("error_mm", np.nan)
            print(f"OK, est=({row['estimated_x_m']:.4f},{row['estimated_y_m']:.4f}) m, error={err_mm:.2f} mm, validBands={row['nValidBands']}")
        except Exception as exc:
            fail = {
                "status": "FAIL",
                "file": str(csv_path),
                "message": str(exc),
            }
            failure_rows.append(fail)
            summary_rows.append(fail.copy())
            print(f"FAIL: {exc}")

    summary_csv = out_dir / "batch_summary.csv"
    failures_csv = out_dir / "batch_failures.csv"
    write_rows_csv(summary_csv, summary_rows)
    write_rows_csv(failures_csv, failure_rows)

    ok_count = sum(1 for r in summary_rows if r.get("status") == "OK")
    print("\nBatch localization finished.")
    print(f"  OK:   {ok_count}")
    print(f"  FAIL: {len(failure_rows)}")
    print(f"  Summary:  {summary_csv}")
    print(f"  Failures: {failures_csv}")
    return 0 if ok_count > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
