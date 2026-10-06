from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field
from datetime import datetime
from typing import Dict, Iterable, List, Optional, Sequence, Tuple, Union

import numpy as np

from .config import ControlConfig, sample_rate_hz_from_code

BytesLike = Union[bytes, bytearray, memoryview, Sequence[int], np.ndarray]


class ProtocolError(ValueError):
    pass


def _to_bytes(data: BytesLike) -> bytes:
    if isinstance(data, bytes):
        return data
    if isinstance(data, bytearray):
        return bytes(data)
    if isinstance(data, memoryview):
        return data.tobytes()
    if isinstance(data, np.ndarray):
        return data.astype(np.uint8, copy=False).tobytes()
    return bytes(int(x) & 0xFF for x in data)


def _u32be(b: bytes) -> int:
    if len(b) != 4:
        raise ProtocolError(f"be u32 requires 4 bytes, got {len(b)}")
    return int.from_bytes(b, "big", signed=False)


def _u32le(b: bytes) -> int:
    if len(b) != 4:
        raise ProtocolError(f"le u32 requires 4 bytes, got {len(b)}")
    return int.from_bytes(b, "little", signed=False)


def _i16_from_u16(u: int) -> int:
    u &= 0xFFFF
    return u - 0x10000 if u & 0x8000 else u


def _bits_be(buf: bytes, hi: int, lo: int) -> int:
    if hi < lo:
        raise ProtocolError(f"bad bit range [{hi}:{lo}]")
    total_bits = len(buf) * 8
    if hi >= total_bits or lo < 0:
        raise ProtocolError(f"bit range [{hi}:{lo}] exceeds {total_bits}-bit vector")
    val = int.from_bytes(buf, "big", signed=False)
    mask = (1 << (hi - lo + 1)) - 1
    return (val >> lo) & mask


def _range_text(values: Iterable[int], max_groups: int = 32) -> str:
    vals = sorted(int(v) for v in values)
    if not vals:
        return ""
    groups: List[str] = []
    i = 0
    while i < len(vals):
        start = vals[i]
        stop = start
        i += 1
        while i < len(vals) and vals[i] == stop + 1:
            stop = vals[i]
            i += 1
        if len(groups) >= max_groups:
            groups.append("...")
            break
        groups.append(str(start) if start == stop else f"{start}-{stop}")
    return ", ".join(groups)


def build_control_packet(ctrl: ControlConfig) -> bytes:
    """Build the 64-byte little-endian USND control packet used by the FPGA."""
    if ctrl.ae_threshold > 0xFFFF:
        raise ProtocolError("AE threshold must be <= 65535")
    if ctrl.sample_mask > 0xFFFF:
        raise ProtocolError("Channel mask must be <= 0xFFFF")
    if not isinstance(ctrl.timestamp, datetime):
        raise ProtocolError("ctrl.timestamp must be datetime")

    w = [0] * 16
    w[0] = 0x55534E44  # USND, not packed through struct below
    w[1] = ((ctrl.version & 0xFFFF) << 16)
    w[2] = ((ctrl.pulse_freq_khz & 0xFFFF) << 16) | ((ctrl.pulse_count & 0xFF) << 8) | (ctrl.duty_pct & 0xFF)
    w[3] = ((ctrl.pulse_gap_us & 0xFFFF) << 16) | (ctrl.pulse_channel_enable4 & 0x0F)
    delays = list(ctrl.delay_cycles)
    if len(delays) != 4:
        raise ProtocolError("delay_cycles must contain four integers")
    w[4:8] = [int(x) & 0xFFFFFFFF for x in delays]
    w[8] = ctrl.sample_rate_code & 0xFFFF
    w[9] = ctrl.sample_mask & 0xFFFF
    ts = ctrl.timestamp
    w[10] = ((ts.year & 0xFFFF) << 16) | ((ts.month & 0xFF) << 8) | (ts.day & 0xFF)
    w[11] = ((ts.hour & 0xFF) << 24) | ((ts.minute & 0xFF) << 16) | ((ts.second & 0xFF) << 8)
    flags = 0
    if ctrl.tx_enable:
        flags |= 1 << 24
    if ctrl.rx_enable:
        flags |= 1 << 25
    if ctrl.req_upload:
        flags |= 1 << 26
    if ctrl.time_sync_enable:
        flags |= 1 << 27
    w[12] = flags
    w[13] = ctrl.ae_threshold & 0xFFFF
    w[14] = 0
    w[15] = 0x454E4421  # END!

    pkt = bytearray(64)
    pkt[0:4] = b"USND"
    for k in range(1, 14):  # words 2..14 in MATLAB indexing
        pkt[k * 4:(k + 1) * 4] = struct.pack("<I", w[k])
    pkt[60:64] = b"END!"
    checksum = sum(pkt[0:56]) & 0xFFFFFFFF
    pkt[56:60] = struct.pack("<I", checksum)
    return bytes(pkt)


def unpack_control_packet(pkt: BytesLike) -> Dict[str, object]:
    b = _to_bytes(pkt)
    if len(b) != 64:
        raise ProtocolError(f"Control packet must be 64 bytes, got {len(b)}")
    if b[0:4] != b"USND":
        raise ProtocolError("Header magic must be USND")
    if b[60:64] != b"END!":
        raise ProtocolError("Tail magic must be END!")
    w = [0] * 16
    w[0] = 0x55534E44
    for k in range(1, 14):
        w[k] = _u32le(b[k * 4:(k + 1) * 4])
    w[14] = _u32le(b[56:60])
    w[15] = 0x454E4421
    checksum_calc = sum(b[0:56]) & 0xFFFFFFFF
    if checksum_calc != w[14]:
        raise ProtocolError(f"Checksum mismatch: calc=0x{checksum_calc:08X} rx=0x{w[14]:08X}")
    flags = w[12]
    code = w[8] & 0xFFFF
    return {
        "magic": "USND",
        "tail": "END!",
        "version": (w[1] >> 16) & 0xFFFF,
        "pulse_freq_khz": (w[2] >> 16) & 0xFFFF,
        "pulse_count": (w[2] >> 8) & 0xFF,
        "duty_pct": w[2] & 0xFF,
        "pulse_gap_us": (w[3] >> 16) & 0xFFFF,
        "pulse_channel_enable4": w[3] & 0x0F,
        "delay_cycles": tuple(w[4:8]),
        "sample_rate_code": code,
        "sample_rate_hz": sample_rate_hz_from_code(code),
        "sample_mask": w[9] & 0xFFFF,
        "year": (w[10] >> 16) & 0xFFFF,
        "month": (w[10] >> 8) & 0xFF,
        "day": w[10] & 0xFF,
        "hour": (w[11] >> 24) & 0xFF,
        "minute": (w[11] >> 16) & 0xFF,
        "second": (w[11] >> 8) & 0xFF,
        "flags": flags,
        "tx_enable": bool(flags & (1 << 24)),
        "rx_enable": bool(flags & (1 << 25)),
        "req_upload": bool(flags & (1 << 26)),
        "time_sync_enable": bool(flags & (1 << 27)),
        "ae_threshold": w[13],
        "checksum_rx": w[14],
        "checksum_calc": checksum_calc,
        "raw_words_u32": w,
        "raw_bytes": b,
    }


@dataclass
class SensorPacket:
    magic: str
    version: int
    packet_bytes: int
    latest_event_seq: int
    flags: int
    ds18b20_valid: bool
    ds18b20_present: bool
    aht20_valid: bool
    lsm6_valid: bool
    lsm6_ok: bool
    ds18b20_temp_raw_x16: int
    ds18b20_temp_centi: int
    aht20_humi_centi: int
    aht20_temp_centi: int
    lsm6_gx_raw: int
    lsm6_gy_raw: int
    lsm6_gz_raw: int
    year: int
    month: int
    day: int
    hour: int
    minute: int
    second: int
    current_time_tag_u64: int
    sample_rate_code: int
    channel_mask: int
    sample_rate_hz: float
    ae_threshold: int
    raw_words_u32: List[int] = field(repr=False)
    raw_bytes: bytes = field(repr=False)

    @property
    def sample_rate_mhz(self) -> float:
        return self.sample_rate_hz / 1e6 if math.isfinite(self.sample_rate_hz) else float("nan")

    @property
    def channel_en(self) -> int:
        return self.channel_mask


def unpack_sensor_packet(pkt: BytesLike) -> SensorPacket:
    b = _to_bytes(pkt)
    if len(b) != 64:
        raise ProtocolError(f"Sensor packet must be 64 bytes, got {len(b)}")
    if b[0:4] != b"SNSR":
        raise ProtocolError("Header magic must be SNSR")
    if b[60:64] != b"END!":
        raise ProtocolError("Tail magic must be END!")
    w = [_u32be(b[i * 4:(i + 1) * 4]) for i in range(16)]
    flags = w[3]
    code = (w[12] >> 16) & 0xFFFF
    return SensorPacket(
        magic="SNSR",
        version=(w[1] >> 16) & 0xFFFF,
        packet_bytes=w[1] & 0xFFFF,
        latest_event_seq=w[2],
        flags=flags,
        ds18b20_valid=bool(flags & 0x1),
        ds18b20_present=bool(flags & 0x2),
        aht20_valid=bool(flags & 0x4),
        lsm6_valid=bool(flags & 0x8),
        lsm6_ok=bool(flags & 0x10),
        ds18b20_temp_raw_x16=_i16_from_u16((w[4] >> 16) & 0xFFFF),
        ds18b20_temp_centi=_i16_from_u16(w[4] & 0xFFFF),
        aht20_humi_centi=(w[5] >> 16) & 0xFFFF,
        aht20_temp_centi=_i16_from_u16(w[5] & 0xFFFF),
        lsm6_gx_raw=_i16_from_u16((w[6] >> 16) & 0xFFFF),
        lsm6_gy_raw=_i16_from_u16(w[6] & 0xFFFF),
        lsm6_gz_raw=_i16_from_u16((w[7] >> 16) & 0xFFFF),
        year=(w[8] >> 16) & 0xFFFF,
        month=(w[8] >> 8) & 0x0F,
        day=w[8] & 0x1F,
        hour=(w[9] >> 24) & 0x1F,
        minute=(w[9] >> 16) & 0x3F,
        second=(w[9] >> 8) & 0x3F,
        current_time_tag_u64=((w[10] & 0xFFFFFFFF) << 32) | w[11],
        sample_rate_code=code,
        channel_mask=w[12] & 0xFFFF,
        sample_rate_hz=sample_rate_hz_from_code(code),
        ae_threshold=w[13] & 0xFFFF,
        raw_words_u32=w,
        raw_bytes=b,
    )


@dataclass
class FrameHeader:
    hdr0: Dict[str, object]
    hdr1: Dict[str, object]
    hdr2: Dict[str, object]
    hdr3: Dict[str, object]


def parse_frame_header_block(b: bytes) -> FrameHeader:
    if len(b) != 128:
        raise ProtocolError(f"AE frame header block must be 128 bytes, got {len(b)}")
    hdr0 = b[0:32]
    hdr1 = b[32:64]
    hdr2 = b[64:96]
    hdr3 = b[96:128]
    h0 = {
        "magic": _bits_be(hdr0, 255, 224),
        "version": _bits_be(hdr0, 223, 208),
        "header_words": _bits_be(hdr0, 207, 200),
        "event_seq": _bits_be(hdr0, 191, 160),
        "threshold": _bits_be(hdr0, 159, 144),
        "channel_mask": _bits_be(hdr0, 143, 128),
        "trigger_sample_index": _bits_be(hdr0, 127, 96),
        "payload_words": _bits_be(hdr0, 95, 64),
        "frame_words": _bits_be(hdr0, 63, 32),
        "flags": _bits_be(hdr0, 31, 0),
    }
    h1 = {
        "year": _bits_be(hdr1, 255, 240),
        "month": _bits_be(hdr1, 239, 232),
        "day": _bits_be(hdr1, 231, 224),
        "hour": _bits_be(hdr1, 223, 216),
        "minute": _bits_be(hdr1, 215, 208),
        "second": _bits_be(hdr1, 207, 200),
        "subsec_us": _bits_be(hdr1, 199, 168),
        "time_valid": bool(_bits_be(hdr1, 0, 0)),
        "raw": hdr1,
    }
    h2 = {
        "ddr_base_addr": _bits_be(hdr2, 253, 224),
        "slot_index": _bits_be(hdr2, 223, 192),
        "slot_bytes": _bits_be(hdr2, 191, 160),
        "total_bytes": _bits_be(hdr2, 159, 128),
        "raw": hdr2,
    }
    magic3 = _bits_be(hdr3, 255, 224)
    valid3 = magic3 == 0x41454D45
    h3 = {"raw": hdr3, "magic": magic3, "valid": valid3, "all_zero": all(x == 0 for x in hdr3)}
    if valid3:
        h3.update({
            "frame_samples": _bits_be(hdr3, 223, 208),
            "pre_samples": _bits_be(hdr3, 207, 192),
            "post_samples": _bits_be(hdr3, 191, 176),
            "trigger_offset": _bits_be(hdr3, 175, 160),
            "sample_rate_div": _bits_be(hdr3, 159, 144),
            "trig_mask": _bits_be(hdr3, 143, 128),
        })
    else:
        h3.update({"frame_samples": 0, "pre_samples": 0, "post_samples": 0, "trigger_offset": 0, "sample_rate_div": 0, "trig_mask": 0})
    return FrameHeader(h0, h1, h2, h3)


@dataclass
class AEUPPacket:
    magic: str
    version: int
    header_bytes: int
    event_seq: int
    packet_index: int
    packet_count: int
    payload_offset: int
    payload_bytes: int
    flags: int
    is_first: bool
    is_last: bool
    event_total_bytes: int
    event_payload_total_bytes: int
    sensor_bytes: bytes
    sensor: SensorPacket
    frame_header_bytes: bytes
    frame_header: FrameHeader
    payload: bytes
    udp_payload_bytes: int
    raw_header_words_u32: List[int]
    raw_bytes: bytes = field(repr=False)


def unpack_ae_unified_packet(pkt: BytesLike) -> AEUPPacket:
    b = _to_bytes(pkt)
    if len(b) < 224:
        raise ProtocolError(f"AEUP packet must be at least 224 bytes, got {len(b)}")
    hdr = b[0:32]
    w = [_u32be(hdr[i * 4:(i + 1) * 4]) for i in range(8)]
    if hdr[0:4] != b"AEUP":
        raise ProtocolError("Header magic must be AEUP")
    version = (w[1] >> 16) & 0xFFFF
    header_bytes = w[1] & 0xFFFF
    payload_bytes = (w[5] >> 16) & 0xFFFF
    flags = w[5] & 0xFFFF
    expect_len = header_bytes + payload_bytes
    if version != 1:
        raise ProtocolError(f"AEUP version must be 1, got {version}")
    if header_bytes != 224:
        raise ProtocolError(f"AEUP header_bytes must be 224, got {header_bytes}")
    if len(b) != expect_len:
        raise ProtocolError(f"AEUP packet length mismatch: header expects {expect_len}, actual {len(b)}")
    event_seq = w[2]
    packet_index = (w[3] >> 16) & 0xFFFF
    packet_count = w[3] & 0xFFFF
    payload_offset = w[4]
    event_total_bytes = w[6]
    event_payload_total_bytes = w[7]
    if packet_count == 0:
        raise ProtocolError("AEUP packet_count must not be zero")
    if packet_index >= packet_count:
        raise ProtocolError(f"AEUP packet_index {packet_index} exceeds packet_count {packet_count}")
    if event_total_bytes != event_payload_total_bytes + 128:
        raise ProtocolError("event_total_bytes must equal event_payload_total_bytes + 128")
    if payload_offset % 32 != 0 or payload_bytes % 32 != 0 or event_payload_total_bytes % 32 != 0:
        raise ProtocolError("AEUP payload offset/length/total must be 32-byte aligned")
    if payload_offset + payload_bytes > event_payload_total_bytes:
        raise ProtocolError("AEUP payload range exceeds event size")
    sensor_bytes = b[32:96]
    try:
        sensor = unpack_sensor_packet(sensor_bytes)
    except ProtocolError as exc:
        if sensor_bytes[1:4] == b"NSR":
            sensor_bytes = b"S" + sensor_bytes[1:]
            sensor = unpack_sensor_packet(sensor_bytes)
        else:
            raise exc
    frame_header_bytes = b[96:224]
    frame_header = parse_frame_header_block(frame_header_bytes)
    payload = b[224:]
    if len(payload) != payload_bytes:
        raise ProtocolError("Internal payload slice mismatch")
    return AEUPPacket(
        magic="AEUP",
        version=version,
        header_bytes=header_bytes,
        event_seq=event_seq,
        packet_index=packet_index,
        packet_count=packet_count,
        payload_offset=payload_offset,
        payload_bytes=payload_bytes,
        flags=flags,
        is_first=bool(flags & 0x1),
        is_last=bool(flags & 0x2),
        event_total_bytes=event_total_bytes,
        event_payload_total_bytes=event_payload_total_bytes,
        sensor_bytes=sensor_bytes,
        sensor=sensor,
        frame_header_bytes=frame_header_bytes,
        frame_header=frame_header,
        payload=payload,
        udp_payload_bytes=len(b),
        raw_header_words_u32=w,
        raw_bytes=b,
    )


@dataclass
class AEFrame:
    hdr0: Dict[str, object]
    hdr1: Dict[str, object]
    hdr2: Dict[str, object]
    hdr3: Dict[str, object]
    payload_bytes: bytes
    samples_i16: np.ndarray
    samples_full_i16: np.ndarray
    frame_samples: int
    pre_samples: int
    post_samples: int
    trigger_offset: int
    sample_rate_div: int
    sample_rate_hz: float
    sample_index: np.ndarray
    trigger_relative_index: np.ndarray
    time_s: np.ndarray
    time_us: np.ndarray
    frame_duration_us: float
    pre_duration_us: float
    post_duration_us: float
    raw_bytes: bytes = field(repr=False)
    raw_header_bytes: bytes = field(repr=False)


def parse_ae_event_frame(frame_bytes: BytesLike) -> AEFrame:
    b = _to_bytes(frame_bytes)
    if len(b) < 128:
        raise ProtocolError(f"Event frame must be at least 128 bytes, got {len(b)}")
    if len(b) % 32 != 0:
        raise ProtocolError(f"Event frame length must be multiple of 32 bytes, got {len(b)}")
    fh = parse_frame_header_block(b[:128])
    payload = b[128:]
    if len(payload) % 32 != 0:
        raise ProtocolError(f"Event payload length must be multiple of 32 bytes, got {len(payload)}")
    n_samples = len(payload) // 32
    samples = np.zeros((n_samples, 16), dtype=np.int16)
    for n in range(n_samples):
        word = payload[n * 32:(n + 1) * 32]
        for ch in range(16):
            off = 32 - 2 * (ch + 1)  # ch0 is low 16 bits, which are last two bytes in the big-endian 256-bit word
            samples[n, ch] = int.from_bytes(word[off:off + 2], "big", signed=True)
    h0 = dict(fh.hdr0)
    payload_words_actual = n_samples
    frame_words_actual = len(b) // 32
    h0["payload_words_header"] = h0["payload_words"]
    h0["frame_words_header"] = h0["frame_words"]
    h0["payload_words_actual"] = payload_words_actual
    h0["frame_words_actual"] = frame_words_actual
    h0["payload_words_repaired"] = h0["payload_words"] != payload_words_actual
    h0["frame_words_repaired"] = h0["frame_words"] != frame_words_actual
    h3 = dict(fh.hdr3)
    if h3.get("valid") and h3.get("pre_samples", 0) > 0 and h3.get("post_samples", 0) > 0 and h3["pre_samples"] + h3["post_samples"] == n_samples:
        pre = int(h3["pre_samples"])
        post = int(h3["post_samples"])
    else:
        pre = n_samples // 2
        post = n_samples - pre
    trigger_offset = int(h3.get("trigger_offset", 0)) if h3.get("valid") and 0 < int(h3.get("trigger_offset", 0)) < n_samples else pre
    div = int(h3.get("sample_rate_div", 0)) if h3.get("valid") else 0
    sample_rate_hz = 40e6 / div if div > 0 else float("nan")
    idx = np.arange(n_samples, dtype=float)
    rel = idx - float(trigger_offset)
    if math.isfinite(sample_rate_hz):
        time_s = rel / sample_rate_hz
        time_us = time_s * 1e6
        frame_duration_us = n_samples / sample_rate_hz * 1e6
        pre_duration_us = trigger_offset / sample_rate_hz * 1e6
        post_duration_us = (n_samples - trigger_offset - 1) / sample_rate_hz * 1e6
    else:
        time_s = np.array([], dtype=float)
        time_us = np.array([], dtype=float)
        frame_duration_us = pre_duration_us = post_duration_us = float("nan")
    return AEFrame(
        hdr0=h0,
        hdr1=fh.hdr1,
        hdr2=fh.hdr2,
        hdr3=h3,
        payload_bytes=payload,
        samples_i16=samples,
        samples_full_i16=samples,
        frame_samples=n_samples,
        pre_samples=pre,
        post_samples=post,
        trigger_offset=trigger_offset,
        sample_rate_div=div,
        sample_rate_hz=sample_rate_hz,
        sample_index=idx,
        trigger_relative_index=rel,
        time_s=time_s,
        time_us=time_us,
        frame_duration_us=frame_duration_us,
        pre_duration_us=pre_duration_us,
        post_duration_us=post_duration_us,
        raw_bytes=b,
        raw_header_bytes=b[:128],
    )


@dataclass
class AEEvent:
    event_seq: int
    event_seq_key: str
    packet_count: int
    received_packet_count: int
    event_total_bytes: int
    event_payload_total_bytes: int
    sensor: SensorPacket
    frame_header: FrameHeader
    frame_bytes: bytes
    payload_bytes: bytes
    packets: List[AEUPPacket]
    frame: AEFrame
    samples_full_i16: np.ndarray
    sample_count: int
    channel_count: int


def _event_seq_key(seq: int, merge_lower24: bool) -> str:
    return f"{seq & 0xFFFFFF:06X}" if merge_lower24 else f"{seq & 0xFFFFFFFF:08X}"


def reassemble_ae_unified_packets(packets: Sequence[Union[AEUPPacket, BytesLike]], merge_seq_lower24: bool = False) -> AEEvent:
    items: List[AEUPPacket] = []
    for p in packets:
        items.append(p if isinstance(p, AEUPPacket) else unpack_ae_unified_packet(p))
    if not items:
        raise ProtocolError("No AEUP packets were provided")
    seq_key0 = _event_seq_key(items[0].event_seq, merge_seq_lower24)
    for p in items:
        if _event_seq_key(p.event_seq, merge_seq_lower24) != seq_key0:
            raise ProtocolError("All AEUP packets must have the same event_seq key")
    items.sort(key=lambda x: x.packet_index)
    header_item = next((p for p in items if p.packet_index == 0), items[0])
    count = int(header_item.packet_count)
    total_bytes = int(header_item.event_total_bytes)
    payload_total_bytes = int(header_item.event_payload_total_bytes)
    if count <= 0 or count > 4096:
        raise ProtocolError(f"Bad packet_count={count}")
    if payload_total_bytes < 0 or payload_total_bytes % 32 != 0:
        raise ProtocolError(f"Bad event_payload_total_bytes={payload_total_bytes}")
    if total_bytes != payload_total_bytes + 128:
        raise ProtocolError("event_total_bytes must be payload_total_bytes + 128")
    expect_count = math.ceil(payload_total_bytes / 800) if payload_total_bytes else 1
    if count != expect_count:
        # Not fatal, but important for diagnostics.
        pass
    payload_buf = bytearray(payload_total_bytes)
    written = bytearray(payload_total_bytes)
    seen = [False] * count
    for p in items:
        if 0 <= p.packet_index < count:
            seen[p.packet_index] = True
        off = int(p.payload_offset)
        n = len(p.payload)
        if n == 0:
            continue
        if off < 0 or off % 32 != 0 or n % 32 != 0:
            raise ProtocolError(f"Packet {p.packet_index} offset={off} payload_len={n} is not 32B aligned")
        if off + n > payload_total_bytes:
            raise ProtocolError(f"Packet {p.packet_index} payload range exceeds event payload")
        payload_buf[off:off + n] = p.payload
        written[off:off + n] = b"\x01" * n
    if not all(seen):
        missing = [i for i, ok in enumerate(seen) if not ok]
        raise ProtocolError(f"Missing AEUP packet indexes: {_range_text(missing, 64)}")
    if payload_total_bytes and any(v == 0 for v in written):
        missing = [i for i, v in enumerate(written) if v == 0]
        raise ProtocolError(f"Payload reconstruction has missing byte ranges: {_range_text(missing, 32)}")
    frame_bytes = header_item.frame_header_bytes + bytes(payload_buf)
    if len(frame_bytes) != total_bytes:
        raise ProtocolError(f"Reassembled frame length mismatch: expect {total_bytes}, got {len(frame_bytes)}")
    frame = parse_ae_event_frame(frame_bytes)
    # Prefer SNSR sample rate if hdr3 did not contain it.
    if frame.sample_rate_div <= 0 and header_item.sensor.sample_rate_code > 0:
        div = int(header_item.sensor.sample_rate_code)
        frame.sample_rate_div = div
        frame.sample_rate_hz = 40e6 / div
        n = frame.samples_i16.shape[0]
        frame.frame_samples = n
        if frame.trigger_offset >= n:
            frame.trigger_offset = n // 2
        idx = np.arange(n, dtype=float)
        frame.sample_index = idx
        frame.trigger_relative_index = idx - float(frame.trigger_offset)
        frame.time_s = frame.trigger_relative_index / frame.sample_rate_hz
        frame.time_us = frame.time_s * 1e6
        frame.frame_duration_us = n / frame.sample_rate_hz * 1e6
        frame.pre_duration_us = frame.trigger_offset / frame.sample_rate_hz * 1e6
        frame.post_duration_us = (n - frame.trigger_offset - 1) / frame.sample_rate_hz * 1e6
    return AEEvent(
        event_seq=header_item.event_seq,
        event_seq_key=_event_seq_key(header_item.event_seq, merge_seq_lower24),
        packet_count=count,
        received_packet_count=sum(1 for x in seen if x),
        event_total_bytes=total_bytes,
        event_payload_total_bytes=payload_total_bytes,
        sensor=header_item.sensor,
        frame_header=header_item.frame_header,
        frame_bytes=frame_bytes,
        payload_bytes=bytes(payload_buf),
        packets=items,
        frame=frame,
        samples_full_i16=frame.samples_full_i16,
        sample_count=frame.samples_i16.shape[0],
        channel_count=frame.samples_i16.shape[1],
    )


def decode_fpga_udp_packet(pkt: BytesLike) -> Dict[str, object]:
    b = _to_bytes(pkt)
    if len(b) < 4:
        raise ProtocolError("Packet length must be at least 4 bytes")
    magic = b[0:4]
    if magic == b"USND":
        return {"type": "control", "data": unpack_control_packet(b)}
    if magic == b"AEUP":
        return {"type": "ae_upload", "data": unpack_ae_unified_packet(b)}
    if magic == b"SNSR":
        return {"type": "sensor", "data": unpack_sensor_packet(b)}
    head = " ".join(f"{x:02X}" for x in b[:4])
    raise ProtocolError(f"Unsupported packet magic {magic!r}, first4={head}")


def get_full_samples(evt: AEEvent, expected_samples: int = 8192, expected_channels: int = 16, strict: bool = False) -> Tuple[np.ndarray, Dict[str, object]]:
    samples = evt.samples_full_i16.astype(float)
    info = {
        "samples": samples.shape[0],
        "channels": samples.shape[1],
        "expected_samples": expected_samples,
        "expected_channels": expected_channels,
        "ok": samples.shape == (expected_samples, expected_channels),
        "payload_bytes": len(evt.payload_bytes),
        "event_payload_total_bytes": evt.event_payload_total_bytes,
        "hdr_payload_words_header": evt.frame.hdr0.get("payload_words_header", evt.frame.hdr0.get("payload_words")),
        "hdr_payload_words_actual": evt.frame.hdr0.get("payload_words_actual", samples.shape[0]),
    }
    if strict and not info["ok"]:
        raise ProtocolError(f"Expected {expected_samples} x {expected_channels} AE samples, got {samples.shape[0]} x {samples.shape[1]}")
    return samples, info
