from __future__ import annotations

import select
import socket
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Dict, List, Optional, Tuple

from .config import AEConfig, ControlConfig
from .protocol import (
    AEEvent,
    AEUPPacket,
    ProtocolError,
    build_control_packet,
    decode_fpga_udp_packet,
    reassemble_ae_unified_packets,
)


@dataclass
class ReceiveStats:
    raw_datagrams: int = 0
    decoded_aeup: int = 0
    decode_errors: int = 0
    ignored_type: int = 0
    ignored_seq: int = 0
    target_key: str = ""
    expected_packets: int = 0
    received_unique: int = 0
    missing_indexes: str = ""
    collect_s: float = 0.0
    decode_s: float = 0.0
    total_s: float = 0.0
    last_decode_error: str = ""


class AEUdpClient:
    """UDP client for the FPGA AE protocol.

    The receiver is optimized for FPGA burst traffic: it drains raw datagrams into
    memory first, then decodes and reassembles after the burst is over. This is
    intentionally different from a packet-by-packet GUI logger, because logging
    during the burst is a common source of UDP socket overflow.
    """

    def __init__(self, cfg: AEConfig, recv_buffer_bytes: int = 8 * 1024 * 1024):
        self.cfg = cfg
        self.recv_buffer_bytes = int(recv_buffer_bytes)
        self.sock: Optional[socket.socket] = None

    def open(self) -> None:
        self.close()
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, self.recv_buffer_bytes)
        except OSError:
            pass
        try:
            s.bind((self.cfg.local_ip, int(self.cfg.local_port)))
        except OSError as exc:
            if not self.cfg.allow_localhost_fallback:
                s.close()
                raise RuntimeError(
                    f"Cannot bind UDP {self.cfg.local_ip}:{self.cfg.local_port}. "
                    f"Configure the PC NIC IPv4 address or free the port. Original error: {exc}"
                ) from exc
            s.bind(("", int(self.cfg.local_port)))
        s.setblocking(False)
        self.sock = s

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    @property
    def is_open(self) -> bool:
        return self.sock is not None

    def require_open(self) -> socket.socket:
        if self.sock is None:
            self.open()
        assert self.sock is not None
        return self.sock

    def flush_input(self, max_datagrams: int = 20000, idle_s: float = 0.01) -> int:
        """Drain stale UDP datagrams already queued for the socket."""
        s = self.require_open()
        count = 0
        last_rx = time.perf_counter()
        while count < max_datagrams:
            r, _, _ = select.select([s], [], [], 0.0)
            if not r:
                if time.perf_counter() - last_rx >= idle_s:
                    break
                time.sleep(0.0005)
                continue
            try:
                while count < max_datagrams:
                    s.recvfrom(65535)
                    count += 1
                    last_rx = time.perf_counter()
            except BlockingIOError:
                pass
        return count

    def send_control(self, ctrl: Optional[ControlConfig] = None) -> bytes:
        if ctrl is None:
            ctrl = self.cfg.control
        ctrl.timestamp = datetime.now()
        pkt = build_control_packet(ctrl)
        s = self.require_open()
        s.sendto(pkt, (self.cfg.remote_ip, int(self.cfg.remote_port)))
        return pkt

    def send_upload_request(self, ctrl: Optional[ControlConfig] = None) -> bytes:
        if ctrl is None:
            base = self.cfg.control
            ctrl = ControlConfig(**base.__dict__)
        else:
            ctrl = ControlConfig(**ctrl.__dict__)
        ctrl.req_upload = True
        ctrl.time_sync_enable = False
        ctrl.timestamp = datetime.now()
        return self.send_control(ctrl)

    def collect_raw_datagrams(
        self,
        timeout_s: float,
        idle_gap_s: float = 0.20,
        max_datagrams: int = 4096,
        recv_size: int = 4096,
    ) -> Tuple[List[bytes], float]:
        """Collect a burst of raw datagrams as fast as possible.

        Collection stops when no new datagram arrives for `idle_gap_s` after at
        least one datagram has been received, or when `timeout_s` expires.
        """
        s = self.require_open()
        raw: List[bytes] = []
        t0 = time.perf_counter()
        last_rx: Optional[float] = None
        while time.perf_counter() - t0 < timeout_s and len(raw) < max_datagrams:
            r, _, _ = select.select([s], [], [], 0.001)
            now = time.perf_counter()
            if not r:
                if last_rx is not None and now - last_rx >= idle_gap_s:
                    break
                continue
            # Drain all currently available datagrams with minimal Python work.
            while len(raw) < max_datagrams:
                try:
                    data, _addr = s.recvfrom(recv_size)
                except BlockingIOError:
                    break
                raw.append(data)
                last_rx = time.perf_counter()
        return raw, time.perf_counter() - t0

    def receive_event(
        self,
        timeout_s: Optional[float] = None,
        merge_seq_lower24: bool = False,
        expected_samples: int = 8192,
        expected_channels: int = 16,
        strict_frame_size: bool = True,
        idle_gap_s: float = 0.20,
        max_datagrams: int = 4096,
    ) -> Tuple[AEEvent, ReceiveStats]:
        """Receive one complete AE event from queued UDP datagrams.

        This function performs silent raw collection first and decodes afterwards.
        """
        if timeout_s is None:
            timeout_s = self.cfg.timeout_s
        total_start = time.perf_counter()
        raw, collect_s = self.collect_raw_datagrams(timeout_s, idle_gap_s, max_datagrams)
        stats = ReceiveStats(raw_datagrams=len(raw), collect_s=collect_s)
        decode_start = time.perf_counter()

        groups: Dict[str, Dict[str, object]] = {}
        for data in raw:
            try:
                decoded = decode_fpga_udp_packet(data)
            except Exception as exc:
                stats.decode_errors += 1
                stats.last_decode_error = str(exc)
                continue
            if decoded["type"] != "ae_upload":
                stats.ignored_type += 1
                continue
            pkt: AEUPPacket = decoded["data"]  # type: ignore[assignment]
            stats.decoded_aeup += 1
            key = f"{pkt.event_seq & 0xFFFFFF:06X}" if merge_seq_lower24 else f"{pkt.event_seq & 0xFFFFFFFF:08X}"
            if key not in groups:
                groups[key] = {"packets": [], "packet_count": pkt.packet_count}
            groups[key]["packets"].append(pkt)  # type: ignore[index]
            groups[key]["packet_count"] = pkt.packet_count

        if not groups:
            stats.decode_s = time.perf_counter() - decode_start
            stats.total_s = time.perf_counter() - total_start
            raise TimeoutError(
                f"No AEUP packets received. raw_datagrams={stats.raw_datagrams}, "
                f"decode_errors={stats.decode_errors}, last_decode_error={stats.last_decode_error}"
            )

        # Prefer a complete group; otherwise pick the group with most unique indexes.
        best_key = ""
        best_score = -1
        complete_keys: List[str] = []
        for key, g in groups.items():
            pkts: List[AEUPPacket] = g["packets"]  # type: ignore[assignment]
            expected = int(g["packet_count"])
            unique = len({p.packet_index for p in pkts})
            if expected > 0 and unique >= expected:
                complete_keys.append(key)
            score = unique
            if score > best_score:
                best_key = key
                best_score = score
        target_key = complete_keys[0] if complete_keys else best_key
        target_pkts: List[AEUPPacket] = groups[target_key]["packets"]  # type: ignore[index,assignment]
        expected_packets = int(groups[target_key]["packet_count"])  # type: ignore[index]
        unique_indexes = sorted({p.packet_index for p in target_pkts})
        missing = [i for i in range(expected_packets) if i not in set(unique_indexes)]
        stats.target_key = target_key
        stats.expected_packets = expected_packets
        stats.received_unique = len(unique_indexes)
        stats.missing_indexes = _range_text(missing, 64)

        if missing:
            stats.decode_s = time.perf_counter() - decode_start
            stats.total_s = time.perf_counter() - total_start
            raise TimeoutError(
                f"Timed out waiting for full AE event. target_key={target_key}, "
                f"packets={len(unique_indexes)}/{expected_packets}, raw_datagrams={stats.raw_datagrams}, "
                f"aeup={stats.decoded_aeup}, decode_errors={stats.decode_errors}, "
                f"missing_indexes={stats.missing_indexes}, last_decode_error={stats.last_decode_error}"
            )

        event = reassemble_ae_unified_packets(target_pkts, merge_seq_lower24=merge_seq_lower24)
        if strict_frame_size and event.samples_full_i16.shape != (expected_samples, expected_channels):
            stats.decode_s = time.perf_counter() - decode_start
            stats.total_s = time.perf_counter() - total_start
            raise ProtocolError(
                f"Received complete AEUP packets but frame size is wrong. "
                f"Expected {expected_samples} x {expected_channels}, got "
                f"{event.samples_full_i16.shape[0]} x {event.samples_full_i16.shape[1]}, "
                f"payload_bytes={len(event.payload_bytes)}, event_payload_total_bytes={event.event_payload_total_bytes}"
            )
        stats.decode_s = time.perf_counter() - decode_start
        stats.total_s = time.perf_counter() - total_start
        return event, stats

    def request_and_receive_event(
        self,
        ctrl: Optional[ControlConfig] = None,
        timeout_s: Optional[float] = None,
        expected_samples: int = 8192,
        expected_channels: int = 16,
        idle_gap_s: float = 0.20,
    ) -> Tuple[AEEvent, ReceiveStats]:
        # Robust stale packet cleanup before the FPGA starts sending.
        self.flush_input()
        time.sleep(0.02)
        self.flush_input()
        self.send_upload_request(ctrl)
        return self.receive_event(
            timeout_s=timeout_s,
            expected_samples=expected_samples,
            expected_channels=expected_channels,
            strict_frame_size=True,
            idle_gap_s=idle_gap_s,
        )


def _range_text(values: List[int], max_groups: int = 32) -> str:
    if not values:
        return ""
    groups: List[str] = []
    i = 0
    while i < len(values):
        start = values[i]
        stop = start
        i += 1
        while i < len(values) and values[i] == stop + 1:
            stop = values[i]
            i += 1
        if len(groups) >= max_groups:
            groups.append("...")
            break
        groups.append(str(start) if start == stop else f"{start}-{stop}")
    return ", ".join(groups)
