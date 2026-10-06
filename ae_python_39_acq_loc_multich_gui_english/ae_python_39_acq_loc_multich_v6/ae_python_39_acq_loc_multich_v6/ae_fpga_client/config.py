from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import List, Tuple


@dataclass
class ControlConfig:
    version: int = 1
    pulse_freq_khz: int = 1000
    pulse_count: int = 1
    duty_pct: int = 50
    pulse_gap_us: int = 1000
    pulse_channel_enable4: int = 15
    delay_cycles: Tuple[int, int, int, int] = (0, 0, 0, 0)
    sample_rate_code: int = 4
    sample_rate_label: str = "10MHz"
    sample_mask: int = 0xFFFF
    time_sync_enable: bool = True
    timestamp: datetime = field(default_factory=datetime.now)
    tx_enable: bool = False
    rx_enable: bool = True
    req_upload: bool = False
    ae_threshold: int = 4000


@dataclass
class AEConfig:
    local_ip: str = "192.168.100.145"
    local_port: int = 1234
    remote_ip: str = "192.168.100.234"
    remote_port: int = 1234

    timeout_s: float = 10.0
    max_packets_per_read: int = 4096
    max_event_packets: int = 4096

    frame_samples: int = 8192
    pre_samples: int = 4096
    post_samples: int = 4096
    trigger_offset: int = 4096

    full_rate_hz: float = 40e6
    aeup_header_bytes: int = 224
    aeup_udp_payload_max: int = 1024
    aeup_event_payload_max: int = 800

    allow_localhost_fallback: bool = False
    sample_rate_labels: Tuple[str, ...] = (
        "40MHz", "20MHz", "10MHz", "5MHz", "2.5MHz", "2MHz", "1MHz", "500kHz"
    )
    sample_rate_codes: Tuple[int, ...] = (1, 2, 4, 8, 16, 20, 40, 80)
    control: ControlConfig = field(default_factory=ControlConfig)


def default_config() -> AEConfig:
    return AEConfig()


def sample_rate_options() -> Tuple[Tuple[str, ...], Tuple[int, ...]]:
    cfg = default_config()
    return cfg.sample_rate_labels, cfg.sample_rate_codes


def sample_rate_hz_from_code(code: int) -> float:
    if code > 0:
        return 40e6 / float(code)
    return float("nan")
