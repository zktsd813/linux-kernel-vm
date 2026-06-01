#!/usr/bin/env python3
"""Userspace controller for local-fault based NUMA migration control.

The controller is workload agnostic.  It uses the target cgroup for process
membership and memory stats, while NUMA balancing/local-fault knobs may come
from either the old cgroup files or the current global sysfs/proc files.
"""

from __future__ import annotations

import argparse
import csv
import os
import signal
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, Optional, TextIO


MIGRATE_STATE_KEYS = (
    "numa_local_fault_pte_updates",
    "numa_local_fault_refault",
    "numa_local_fault_refault_hit",
    "numa_local_fault_refault_total_ms",
    "numa_local_fault_lost",
    "numa_remote_hint_faults",
    "numa_remote_hint_fault_latency_total_ms",
)


@dataclass
class WindowStats:
    seq: int = 0
    pte_updates: int = 0
    refault: int = 0
    refault_hit: int = 0
    local_refault_latency_total_ms: int = 0
    lost: int = 0
    hint_faults: int = 0
    remote_hint_faults: int = 0
    remote_hint_latency_total_ms: int = 0


@dataclass
class NumaNodeStats:
    bytes_by_node: Dict[int, int]

    def pages(self, node: int) -> int:
        return self.bytes_by_node.get(node, 0) // 4096


VMSTAT_KEYS = (
    "numa_hint_faults",
    "numa_hint_faults_local",
    "numa_pages_migrated",
    "pgmigrate_success",
    "pgpromote_candidate",
    "pgpromote_success",
    "pgdemote_kswapd",
    "pgdemote_direct",
)


@dataclass
class VmstatStats:
    numa_hint_faults: int = 0
    numa_hint_faults_local: int = 0
    numa_pages_migrated: int = 0
    pgmigrate_success: int = 0
    pgpromote_candidate: int = 0
    pgpromote_success: int = 0
    pgdemote_kswapd: int = 0
    pgdemote_direct: int = 0


SYSFS_NUMA_DIR = Path("/sys/kernel/mm/numa_balancing")
GLOBAL_KNOB_PATHS = {
    "node_balancing": Path("/proc/sys/kernel/numa_balancing"),
    "numa_local_fault_on_tiering": SYSFS_NUMA_DIR / "local_fault_rate",
    "numa_local_fault_scan_period_ms": SYSFS_NUMA_DIR / "local_fault_scan_period_ms",
    "numa_local_fault_scan_size_mb": SYSFS_NUMA_DIR / "local_fault_scan_size_mb",
    "numa_local_fault_refault_hit_ms": SYSFS_NUMA_DIR / "local_fault_refault_hit_ms",
    "numa_local_fault_window": SYSFS_NUMA_DIR / "local_fault_window",
    "numa_migrate_state": SYSFS_NUMA_DIR / "local_fault_stats",
}

GLOBAL_STATE_ALIASES = {
    "local_fault_pte_updates": "numa_local_fault_pte_updates",
    "local_fault_refault": "numa_local_fault_refault",
    "local_fault_refault_hit": "numa_local_fault_refault_hit",
    "local_fault_refault_total_ms": "numa_local_fault_refault_total_ms",
    "local_fault_lost": "numa_local_fault_lost",
    "local_fault_window_seq": "numa_local_fault_window_seq",
    "local_fault_window_pte_updates": "numa_local_fault_window_current_pte_updates",
    "local_fault_window_refault": "numa_local_fault_window_current_refault",
    "local_fault_window_refault_hit": "numa_local_fault_window_current_refault_hit",
    "local_fault_window_lost": "numa_local_fault_window_current_lost",
}


class CgroupKnobs:
    def __init__(self, cgroup: Path):
        self.cgroup = cgroup

    def knob_path(self, name: str, *, required: bool = True) -> Optional[Path]:
        candidates = (self.cgroup / name, self.cgroup / f"memory.{name}")
        for candidate in candidates:
            if candidate.exists():
                return candidate
        global_candidate = GLOBAL_KNOB_PATHS.get(name)
        if global_candidate is not None and global_candidate.exists():
            return global_candidate
        if required:
            raise FileNotFoundError(
                f"missing knob '{name}' or 'memory.{name}' under {self.cgroup}"
            )
        return None

    def read_knob(self, name: str, default: Optional[str] = None) -> str:
        path = self.knob_path(name, required=default is None)
        if path is None:
            return default if default is not None else ""
        try:
            return path.read_text(encoding="ascii").strip()
        except OSError:
            if default is not None:
                return default
            raise

    def write_knob(self, name: str, value: object, *, required: bool = True) -> bool:
        path = self.knob_path(name, required=required)
        if path is None:
            return False
        path.write_text(f"{value}\n", encoding="ascii")
        return True

    def migrate_state(self) -> Dict[str, int]:
        raw = self.read_knob("numa_migrate_state")
        state: Dict[str, int] = {}
        for line in raw.splitlines():
            fields = line.split()
            if len(fields) < 2:
                continue
            try:
                key = GLOBAL_STATE_ALIASES.get(fields[0], fields[0])
                state[key] = int(fields[1])
            except ValueError:
                continue
        return state

    def memory_stat(self) -> Dict[str, int]:
        raw = self.read_knob("stat", default="")
        state: Dict[str, int] = {}
        for line in raw.splitlines():
            fields = line.split()
            if len(fields) < 2:
                continue
            try:
                state[fields[0]] = int(fields[1])
            except ValueError:
                continue
        return state

    def memory_numa_stat(self) -> NumaNodeStats:
        raw = self.read_knob("numa_stat", default="")
        bytes_by_node: Dict[int, int] = {}
        for line in raw.splitlines():
            fields = line.split()
            if not fields:
                continue
            name = fields[0]
            if name not in {"anon", "file", "shmem"}:
                continue
            for field in fields[1:]:
                if not field.startswith("N") or "=" not in field:
                    continue
                node_text, value_text = field[1:].split("=", 1)
                try:
                    node = int(node_text)
                    value = int(value_text)
                except ValueError:
                    continue
                bytes_by_node[node] = bytes_by_node.get(node, 0) + value
        return NumaNodeStats(bytes_by_node)

    def node_balancing(self) -> str:
        return self.read_knob("node_balancing", default="")


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def monotonic_ms() -> int:
    return int(time.monotonic() * 1000)


def read_totals(knobs: CgroupKnobs) -> WindowStats:
    state = knobs.migrate_state()
    memory = knobs.memory_stat()
    return WindowStats(
        pte_updates=state.get("numa_local_fault_pte_updates", 0),
        refault=state.get("numa_local_fault_refault", 0),
        refault_hit=state.get("numa_local_fault_refault_hit", 0),
        local_refault_latency_total_ms=state.get(
            "numa_local_fault_refault_total_ms", 0
        ),
        lost=state.get("numa_local_fault_lost", 0),
        hint_faults=memory.get("numa_hint_faults", 0),
        remote_hint_faults=state.get("numa_remote_hint_faults", 0),
        remote_hint_latency_total_ms=state.get(
            "numa_remote_hint_fault_latency_total_ms", 0
        ),
    )


def diff_stats(cur: WindowStats, base: WindowStats) -> WindowStats:
    return WindowStats(
        pte_updates=max(0, cur.pte_updates - base.pte_updates),
        refault=max(0, cur.refault - base.refault),
        refault_hit=max(0, cur.refault_hit - base.refault_hit),
        local_refault_latency_total_ms=max(
            0,
            cur.local_refault_latency_total_ms
            - base.local_refault_latency_total_ms,
        ),
        lost=max(0, cur.lost - base.lost),
        hint_faults=max(0, cur.hint_faults - base.hint_faults),
        remote_hint_faults=max(0, cur.remote_hint_faults - base.remote_hint_faults),
        remote_hint_latency_total_ms=max(
            0,
            cur.remote_hint_latency_total_ms - base.remote_hint_latency_total_ms,
        ),
    )


def read_bucket(knobs: CgroupKnobs, prefix: str) -> Optional[WindowStats]:
    state = knobs.migrate_state()
    key_prefix = f"numa_local_fault_window_{prefix}_"
    seq = state.get(f"{key_prefix}seq", 0)
    if seq <= 0:
        return None
    return WindowStats(
        seq=seq,
        pte_updates=state.get(f"{key_prefix}pte_updates", 0),
        refault=state.get(f"{key_prefix}refault", 0),
        refault_hit=state.get(f"{key_prefix}refault_hit", 0),
        lost=state.get(f"{key_prefix}lost", 0),
    )


def read_vmstat() -> VmstatStats:
    values = {key: 0 for key in VMSTAT_KEYS}
    try:
        with Path("/proc/vmstat").open(encoding="ascii") as fp:
            for line in fp:
                fields = line.split()
                if len(fields) != 2 or fields[0] not in values:
                    continue
                try:
                    values[fields[0]] = int(fields[1])
                except ValueError:
                    pass
    except OSError:
        pass
    return VmstatStats(**values)


def diff_vmstat(cur: VmstatStats, base: VmstatStats) -> VmstatStats:
    return VmstatStats(
        **{
            key: max(0, getattr(cur, key) - getattr(base, key))
            for key in VMSTAT_KEYS
        }
    )


def sleep_interruptible(seconds: float, stop_file: Optional[Path], stop_flag) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if stop_flag["stop"]:
            return False
        if stop_file is not None and stop_file.exists():
            return False
        time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))
    return True


def ratio_pct(numerator: int, denominator: int) -> float:
    if denominator <= 0:
        return 0.0
    return numerator * 100.0 / denominator


def expected_sampled_pages(knobs: CgroupKnobs, local_node: int,
                           sample_percent: float) -> int:
    if sample_percent <= 0:
        return 0
    local_pages = knobs.memory_numa_stat().pages(local_node)
    return int(local_pages * sample_percent / 100.0)


def sample_pct(args, knobs: CgroupKnobs) -> float:
    if args.local_fault_sample_pct > 0:
        return args.local_fault_sample_pct
    try:
        return float(knobs.read_knob("numa_local_fault_on_tiering", default="0") or 0)
    except ValueError:
        return 0.0


def estimated_local_accesses(local_faults: float, sample_percent: float) -> float:
    if sample_percent <= 0:
        return 0.0
    return local_faults * 100.0 / sample_percent


def local_signal_faults(args: argparse.Namespace, stats: WindowStats) -> int:
    if args.local_access_signal == "fast":
        return stats.refault_hit
    return stats.refault


def weighted_local_accesses(
    args: argparse.Namespace, stats: WindowStats, sample_percent: float
) -> float:
    slow_refaults = max(0, stats.refault - stats.refault_hit)
    weighted_faults = (
        stats.refault_hit + args.local_composition_slow_weight * slow_refaults
    )
    return estimated_local_accesses(weighted_faults, sample_percent)


def estimated_total_accesses(
    local_stats: WindowStats, remote_stats: WindowStats, sample_percent: float
) -> float:
    return (
        estimated_local_accesses(local_stats.refault, sample_percent)
        + remote_stats.remote_hint_faults
    )


def local_composition_pct(
    args: argparse.Namespace,
    local_stats: WindowStats,
    remote_stats: WindowStats,
    sample_percent: float,
) -> float:
    total = estimated_total_accesses(local_stats, remote_stats, sample_percent)
    if total <= 0:
        return 0.0
    return weighted_local_accesses(args, local_stats, sample_percent) * 100.0 / total


def estimated_remote_accesses(
    args: argparse.Namespace, stats: WindowStats, sample_percent: float
) -> float:
    if stats.hint_faults <= 0:
        return 0.0
    local_estimate = estimated_local_accesses(
        local_signal_faults(args, stats), sample_percent
    )
    return max(0.0, float(stats.hint_faults) - local_estimate)


def remote_ratio_pct(
    args: argparse.Namespace, stats: WindowStats, sample_percent: float
) -> float:
    if stats.hint_faults <= 0 or sample_percent <= 0:
        return 0.0
    return (
        estimated_remote_accesses(args, stats, sample_percent)
        * 100.0
        / stats.hint_faults
    )


def avg_latency_us(total_ms: int, count: int) -> float:
    if count <= 0:
        return 0.0
    return total_ms * 1000.0 / count


def write_event(writer: csv.DictWriter, event: str, started_ms: int, window: int,
                window_seq: int, args, stats: WindowStats, remote_stats: WindowStats,
                vmstat_stats: VmstatStats,
                local_consecutive: int,
                remote_consecutive: int, node_balancing: str, sample_percent: float,
                stop_reason: str = "", reenable_consecutive: int = 0,
                controller_state: str = "", phase: str = "",
                round_seq: int = 0, round_window: int = 0,
                round_expected_pte: int = 0,
                round_coverage_pct: float = 0.0) -> None:
    access_pct = ratio_pct(stats.refault, stats.pte_updates)
    fast_pct = ratio_pct(stats.refault_hit, stats.pte_updates)
    remote_pct = remote_ratio_pct(args, remote_stats, sample_percent)
    weighted_local = weighted_local_accesses(args, stats, sample_percent)
    total_accesses = estimated_total_accesses(stats, remote_stats, sample_percent)
    composition_pct = local_composition_pct(
        args, stats, remote_stats, sample_percent
    )
    writer.writerow(
        {
            "event": event,
            "timestamp": now_iso(),
            "elapsed_ms": monotonic_ms() - started_ms,
            "window": window,
            "window_seq": window_seq,
            "window_sec": args.window_sec,
            "threshold_pct": args.threshold_pct,
            "remote_threshold_pct": args.remote_threshold_pct,
            "min_pte_updates": args.min_pte_updates,
            "min_hint_faults": args.min_hint_faults,
            "sample_pct": f"{sample_percent:.2f}",
            "phase": phase,
            "access_signal": args.local_access_signal,
            "round_seq": round_seq,
            "round_window": round_window,
            "round_expected_pte": round_expected_pte,
            "round_coverage_pct": f"{round_coverage_pct:.2f}",
            "pte_delta": stats.pte_updates,
            "hit_delta": stats.refault_hit,
            "refault_delta": stats.refault,
            "local_refault_latency_total_ms_delta": stats.local_refault_latency_total_ms,
            "local_refault_latency_avg_us": f"{avg_latency_us(stats.local_refault_latency_total_ms, stats.refault):.2f}",
            "lost_delta": stats.lost,
            "remote_refault_delta": remote_stats.refault,
            "hint_fault_delta": remote_stats.hint_faults,
            "remote_hint_fault_delta": remote_stats.remote_hint_faults,
            "remote_hint_latency_total_ms_delta": remote_stats.remote_hint_latency_total_ms,
            "remote_hint_latency_avg_us": f"{avg_latency_us(remote_stats.remote_hint_latency_total_ms, remote_stats.remote_hint_faults):.2f}",
            "estimated_local_accesses": f"{estimated_local_accesses(local_signal_faults(args, remote_stats), sample_percent):.2f}",
            "estimated_remote_accesses": f"{estimated_remote_accesses(args, remote_stats, sample_percent):.2f}",
            "weighted_local_accesses": f"{weighted_local:.2f}",
            "estimated_total_accesses": f"{total_accesses:.2f}",
            "access_pct": f"{access_pct:.2f}",
            "fast_pct": f"{fast_pct:.2f}",
            "local_composition_pct": f"{composition_pct:.2f}",
            "remote_ratio_pct": f"{remote_pct:.2f}",
            "vmstat_numa_hint_faults_delta": vmstat_stats.numa_hint_faults,
            "vmstat_numa_hint_faults_local_delta": vmstat_stats.numa_hint_faults_local,
            "vmstat_numa_pages_migrated_delta": vmstat_stats.numa_pages_migrated,
            "vmstat_pgmigrate_success_delta": vmstat_stats.pgmigrate_success,
            "vmstat_pgpromote_candidate_delta": vmstat_stats.pgpromote_candidate,
            "vmstat_pgpromote_success_delta": vmstat_stats.pgpromote_success,
            "vmstat_pgdemote_kswapd_delta": vmstat_stats.pgdemote_kswapd,
            "vmstat_pgdemote_direct_delta": vmstat_stats.pgdemote_direct,
            "local_consecutive": local_consecutive,
            "remote_consecutive": remote_consecutive,
            "reenable_consecutive": reenable_consecutive,
            "consecutive": local_consecutive,
            "stop_reason": stop_reason,
            "controller_state": controller_state,
            "node_balancing": node_balancing,
        }
    )


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Disable cgroup NUMA migration after repeated high local-fault access windows."
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--cgroup", type=Path, help="target cgroup directory")
    target.add_argument("--cgroup-name", help="target cgroup name under --cgroup-root")
    parser.add_argument("--cgroup-root", type=Path, default=Path("/sys/fs/cgroup"))
    parser.add_argument("--window-sec", type=float, default=10.0)
    parser.add_argument("--threshold-pct", type=float, default=80.0)
    parser.add_argument("--consecutive", type=int, default=3)
    parser.add_argument("--min-pte-updates", type=int, default=1000)
    parser.add_argument(
        "--local-access-mode",
        choices=("round", "window"),
        default="round",
        help="round arms a broader local sampled set before evaluating; window keeps the legacy per-window ratio",
    )
    parser.add_argument(
        "--local-access-signal",
        choices=("access", "fast", "composition"),
        default="fast",
        help=(
            "local stop signal: access=refault/pte, fast=hit-refault/pte, "
            "composition=weighted local share of observed access proxy"
        ),
    )
    parser.add_argument(
        "--local-composition-slow-weight",
        type=float,
        default=0.25,
        help="composition mode weight for non-fast local refaults; fast refaults always count as 1.0",
    )
    parser.add_argument(
        "--min-observed-accesses",
        type=float,
        default=0.0,
        help="composition mode minimum estimated local+remote access proxy events before a window/round can stop",
    )
    parser.add_argument(
        "--local-node",
        type=int,
        default=0,
        help="NUMA node used to estimate local sampled coverage in round mode",
    )
    parser.add_argument(
        "--min-arm-windows",
        type=int,
        default=3,
        help="minimum arming windows before a round can be evaluated",
    )
    parser.add_argument(
        "--max-arm-windows",
        type=int,
        default=12,
        help="maximum arming windows before observing the current round",
    )
    parser.add_argument(
        "--arm-coverage-pct",
        type=float,
        default=60.0,
        help="target percent of estimated sampled local pages to arm before observation; 0 disables",
    )
    parser.add_argument(
        "--observe-windows",
        type=int,
        default=1,
        help="observation windows after arming freezes new local probes",
    )
    parser.add_argument(
        "--remote-threshold-pct",
        type=float,
        default=20.0,
        help="stop when estimated residual remote ratio is <= this value",
    )
    parser.add_argument(
        "--remote-consecutive",
        type=int,
        default=0,
        help="remote-ratio consecutive target; 0 reuses --consecutive",
    )
    parser.add_argument("--min-hint-faults", type=int, default=1)
    parser.add_argument(
        "--local-fault-sample-pct",
        type=float,
        default=0.0,
        help="local fault sampling percentage; 0 reads numa_local_fault_on_tiering",
    )
    parser.add_argument(
        "--eval-lag",
        choices=("current", "prev", "prev2"),
        default="prev",
        help="which kernel window bucket to evaluate when available",
    )
    parser.add_argument(
        "--no-window-buckets",
        action="store_true",
        help="use raw counter deltas instead of kernel window buckets",
    )
    parser.add_argument(
        "--no-advance-window",
        action="store_true",
        help="do not write numa_local_fault_window=1 at each interval start",
    )
    parser.add_argument("--stop-file", type=Path, help="exit when this file appears")
    parser.add_argument("--max-windows", type=int, default=0, help="0 means unlimited")
    parser.add_argument("--output", type=Path, help="CSV output path, default stdout")
    parser.add_argument("--dry-run", action="store_true", help="log off event but do not write node_balancing=0")
    parser.add_argument(
        "--node-balancing-on",
        default="2",
        help="value written to node_balancing when migration is re-enabled",
    )
    parser.add_argument(
        "--reenable-consecutive",
        type=int,
        default=0,
        help="0 keeps old one-shot stop behavior; >0 re-enables after this many windows without the stop condition",
    )
    parser.add_argument(
        "--stop-local-fault",
        action="store_true",
        help="also write numa_local_fault_on_tiering=0 when stopping",
    )
    return parser.parse_args(argv)


def validate_args(args: argparse.Namespace) -> None:
    if args.cgroup_name:
        args.cgroup = args.cgroup_root / args.cgroup_name
    if args.window_sec <= 0:
        raise ValueError("--window-sec must be > 0")
    if args.threshold_pct < 0:
        raise ValueError("--threshold-pct must be >= 0")
    if args.remote_threshold_pct < 0:
        raise ValueError("--remote-threshold-pct must be >= 0")
    if args.consecutive < 1:
        raise ValueError("--consecutive must be >= 1")
    if args.remote_consecutive < 0:
        raise ValueError("--remote-consecutive must be >= 0")
    if args.min_pte_updates < 0:
        raise ValueError("--min-pte-updates must be >= 0")
    if args.local_node < 0:
        raise ValueError("--local-node must be >= 0")
    if not 0.0 <= args.local_composition_slow_weight <= 1.0:
        raise ValueError("--local-composition-slow-weight must be between 0 and 1")
    if args.min_observed_accesses < 0:
        raise ValueError("--min-observed-accesses must be >= 0")
    if args.min_arm_windows < 1:
        raise ValueError("--min-arm-windows must be >= 1")
    if args.max_arm_windows < args.min_arm_windows:
        raise ValueError("--max-arm-windows must be >= --min-arm-windows")
    if args.arm_coverage_pct < 0:
        raise ValueError("--arm-coverage-pct must be >= 0")
    if args.observe_windows < 1:
        raise ValueError("--observe-windows must be >= 1")
    if args.min_hint_faults < 0:
        raise ValueError("--min-hint-faults must be >= 0")
    if args.local_fault_sample_pct < 0:
        raise ValueError("--local-fault-sample-pct must be >= 0")
    if args.max_windows < 0:
        raise ValueError("--max-windows must be >= 0")
    if args.reenable_consecutive < 0:
        raise ValueError("--reenable-consecutive must be >= 0")
    if args.remote_consecutive == 0:
        args.remote_consecutive = args.consecutive
    if not args.cgroup.is_dir():
        raise FileNotFoundError(f"cgroup directory does not exist: {args.cgroup}")


def open_output(path: Optional[Path]) -> tuple[TextIO, bool]:
    if path is None:
        return sys.stdout, False
    path.parent.mkdir(parents=True, exist_ok=True)
    return path.open("w", encoding="ascii", newline=""), True


def run_window_controller(args: argparse.Namespace) -> int:
    knobs = CgroupKnobs(args.cgroup)
    stop_flag = {"stop": False}

    def handle_signal(signum, frame):  # noqa: ARG001
        stop_flag["stop"] = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    out, should_close = open_output(args.output)
    fields = (
        "event",
        "timestamp",
        "elapsed_ms",
        "window",
        "window_seq",
        "window_sec",
        "threshold_pct",
        "remote_threshold_pct",
        "min_pte_updates",
        "min_hint_faults",
        "sample_pct",
        "phase",
        "access_signal",
        "round_seq",
        "round_window",
        "round_expected_pte",
        "round_coverage_pct",
        "pte_delta",
        "hit_delta",
        "refault_delta",
        "local_refault_latency_total_ms_delta",
        "local_refault_latency_avg_us",
        "lost_delta",
        "remote_refault_delta",
        "hint_fault_delta",
        "remote_hint_fault_delta",
        "remote_hint_latency_total_ms_delta",
        "remote_hint_latency_avg_us",
        "estimated_local_accesses",
        "estimated_remote_accesses",
        "weighted_local_accesses",
        "estimated_total_accesses",
        "access_pct",
        "fast_pct",
        "local_composition_pct",
        "remote_ratio_pct",
        "vmstat_numa_hint_faults_delta",
        "vmstat_numa_hint_faults_local_delta",
        "vmstat_numa_pages_migrated_delta",
        "vmstat_pgmigrate_success_delta",
        "vmstat_pgpromote_candidate_delta",
        "vmstat_pgpromote_success_delta",
        "vmstat_pgdemote_kswapd_delta",
        "vmstat_pgdemote_direct_delta",
        "local_consecutive",
        "remote_consecutive",
        "reenable_consecutive",
        "consecutive",
        "stop_reason",
        "controller_state",
        "node_balancing",
    )
    writer = csv.DictWriter(out, fieldnames=fields)
    writer.writeheader()

    try:
        started_ms = monotonic_ms()
        local_consecutive = 0
        remote_consecutive = 0
        reenable_consecutive = 0
        controller_state = "on"
        window = 0
        initial_seq = int(knobs.read_knob("numa_local_fault_window", default="0") or 0)
        current_sample_pct = sample_pct(args, knobs)
        configured_sample_pct = current_sample_pct
        write_event(
            writer,
            "start",
            started_ms,
            0,
            initial_seq,
            args,
            WindowStats(),
            WindowStats(),
            VmstatStats(),
            0,
            0,
            knobs.node_balancing(),
            current_sample_pct,
            "",
            reenable_consecutive,
            controller_state,
        )
        out.flush()

        while not stop_flag["stop"]:
            if args.stop_file is not None and args.stop_file.exists():
                break
            if args.max_windows and window >= args.max_windows:
                break

            window += 1
            if not args.no_advance_window:
                knobs.write_knob("numa_local_fault_window", 1, required=False)

            try:
                window_seq = int(knobs.read_knob("numa_local_fault_window", default="0") or 0)
            except ValueError:
                window_seq = 0

            base = read_totals(knobs)
            vmstat_base = read_vmstat()
            if not sleep_interruptible(args.window_sec, args.stop_file, stop_flag):
                break
            cur = read_totals(knobs)
            vmstat_cur = read_vmstat()
            raw_stats = diff_stats(cur, base)
            vmstat_stats = diff_vmstat(vmstat_cur, vmstat_base)
            stats = raw_stats

            if not args.no_window_buckets:
                bucket = read_bucket(knobs, args.eval_lag)
                if bucket is not None:
                    window_seq = bucket.seq
                    stats = bucket

            current_sample_pct = sample_pct(args, knobs)
            access = local_access_value(args, stats, raw_stats, current_sample_pct)
            remote = remote_ratio_pct(args, raw_stats, current_sample_pct)
            local_condition = local_condition_met(
                args, stats, raw_stats, current_sample_pct
            )
            remote_condition = raw_stats.hint_faults >= args.min_hint_faults and remote <= args.remote_threshold_pct
            stop_reason = ""
            if local_condition:
                stop_reason = "local_access"
            elif remote_condition:
                stop_reason = "remote_ratio"

            if local_condition:
                local_consecutive += 1
            else:
                local_consecutive = 0
            if remote_condition:
                remote_consecutive += 1
            else:
                remote_consecutive = 0

            if controller_state == "off":
                if stop_reason:
                    reenable_consecutive = 0
                else:
                    reenable_consecutive += 1

            node_balancing = knobs.node_balancing()
            write_event(
                writer,
                "sample",
                started_ms,
                window,
                window_seq,
                args,
                stats,
                raw_stats,
                vmstat_stats,
                local_consecutive,
                remote_consecutive,
                node_balancing,
                current_sample_pct,
                "",
                reenable_consecutive,
                controller_state,
            )
            out.flush()

            should_stop = (
                controller_state == "on"
                and (
                    local_consecutive >= args.consecutive
                    or remote_consecutive >= args.remote_consecutive
                )
            )
            if should_stop:
                if local_consecutive >= args.consecutive:
                    stop_reason = "local_access"
                else:
                    stop_reason = "remote_ratio"
                if not args.dry_run:
                    knobs.write_knob("node_balancing", 0)
                    if args.stop_local_fault:
                        knobs.write_knob("numa_local_fault_on_tiering", 0, required=False)
                controller_state = "off"
                reenable_consecutive = 0
                node_balancing = knobs.node_balancing()
                write_event(
                    writer,
                    "off",
                    started_ms,
                    window,
                    window_seq,
                    args,
                    stats,
                    raw_stats,
                    vmstat_stats,
                    local_consecutive,
                    remote_consecutive,
                    node_balancing,
                    current_sample_pct,
                    stop_reason,
                    reenable_consecutive,
                    controller_state,
                )
                out.flush()
                if args.reenable_consecutive == 0:
                    return 0
                local_consecutive = 0
                remote_consecutive = 0

            should_reenable = (
                controller_state == "off"
                and args.reenable_consecutive > 0
                and reenable_consecutive >= args.reenable_consecutive
            )
            if should_reenable:
                if not args.dry_run:
                    knobs.write_knob("node_balancing", args.node_balancing_on)
                    if configured_sample_pct > 0:
                        knobs.write_knob(
                            "numa_local_fault_on_tiering",
                            int(configured_sample_pct),
                            required=False,
                        )
                controller_state = "on"
                node_balancing = knobs.node_balancing()
                write_event(
                    writer,
                    "on",
                    started_ms,
                    window,
                    window_seq,
                    args,
                    stats,
                    raw_stats,
                    vmstat_stats,
                    local_consecutive,
                    remote_consecutive,
                    node_balancing,
                    current_sample_pct,
                    "reenable",
                    reenable_consecutive,
                    controller_state,
                )
                out.flush()
                local_consecutive = 0
                remote_consecutive = 0
                reenable_consecutive = 0

        write_event(
            writer,
            "exit",
            started_ms,
            window,
            0,
            args,
            WindowStats(),
            WindowStats(),
            VmstatStats(),
            local_consecutive,
            remote_consecutive,
            knobs.node_balancing(),
            sample_pct(args, knobs),
            "",
            reenable_consecutive,
            controller_state,
        )
        out.flush()
        return 0
    finally:
        if should_close:
            out.close()


def local_access_value(
    args: argparse.Namespace,
    stats: WindowStats,
    remote_stats: Optional[WindowStats] = None,
    sample_percent: float = 0.0,
) -> float:
    if args.local_access_signal == "composition":
        if remote_stats is None:
            remote_stats = stats
        return local_composition_pct(args, stats, remote_stats, sample_percent)
    if args.local_access_signal == "fast":
        return ratio_pct(stats.refault_hit, stats.pte_updates)
    return ratio_pct(stats.refault, stats.pte_updates)


def local_condition_met(
    args: argparse.Namespace,
    stats: WindowStats,
    remote_stats: WindowStats,
    sample_percent: float,
) -> bool:
    if args.local_access_signal == "composition":
        total = estimated_total_accesses(stats, remote_stats, sample_percent)
        return (
            total >= args.min_observed_accesses
            and local_access_value(args, stats, remote_stats, sample_percent)
            >= args.threshold_pct
        )
    return (
        stats.pte_updates >= args.min_pte_updates
        and local_access_value(args, stats) >= args.threshold_pct
    )


def round_arm_done(args: argparse.Namespace, stats: WindowStats, arm_windows: int,
                   expected_pte: int) -> bool:
    if arm_windows < args.min_arm_windows:
        return False
    if stats.pte_updates < args.min_pte_updates:
        return arm_windows >= args.max_arm_windows
    if args.arm_coverage_pct <= 0 or expected_pte <= 0:
        return True
    target = int(expected_pte * args.arm_coverage_pct / 100.0)
    if target <= 0:
        return True
    return stats.pte_updates >= target or arm_windows >= args.max_arm_windows


def run_round_controller(args: argparse.Namespace) -> int:
    knobs = CgroupKnobs(args.cgroup)
    stop_flag = {"stop": False}

    def handle_signal(signum, frame):  # noqa: ARG001
        stop_flag["stop"] = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    out, should_close = open_output(args.output)
    fields = (
        "event",
        "timestamp",
        "elapsed_ms",
        "window",
        "window_seq",
        "window_sec",
        "threshold_pct",
        "remote_threshold_pct",
        "min_pte_updates",
        "min_hint_faults",
        "sample_pct",
        "phase",
        "access_signal",
        "round_seq",
        "round_window",
        "round_expected_pte",
        "round_coverage_pct",
        "pte_delta",
        "hit_delta",
        "refault_delta",
        "local_refault_latency_total_ms_delta",
        "local_refault_latency_avg_us",
        "lost_delta",
        "remote_refault_delta",
        "hint_fault_delta",
        "remote_hint_fault_delta",
        "remote_hint_latency_total_ms_delta",
        "remote_hint_latency_avg_us",
        "estimated_local_accesses",
        "estimated_remote_accesses",
        "weighted_local_accesses",
        "estimated_total_accesses",
        "access_pct",
        "fast_pct",
        "local_composition_pct",
        "remote_ratio_pct",
        "vmstat_numa_hint_faults_delta",
        "vmstat_numa_hint_faults_local_delta",
        "vmstat_numa_pages_migrated_delta",
        "vmstat_pgmigrate_success_delta",
        "vmstat_pgpromote_candidate_delta",
        "vmstat_pgpromote_success_delta",
        "vmstat_pgdemote_kswapd_delta",
        "vmstat_pgdemote_direct_delta",
        "local_consecutive",
        "remote_consecutive",
        "reenable_consecutive",
        "consecutive",
        "stop_reason",
        "controller_state",
        "node_balancing",
    )
    writer = csv.DictWriter(out, fieldnames=fields)
    writer.writeheader()

    try:
        started_ms = monotonic_ms()
        local_consecutive = 0
        remote_consecutive = 0
        reenable_consecutive = 0
        controller_state = "on"
        window = 0
        current_sample_pct = sample_pct(args, knobs)
        configured_sample_pct = current_sample_pct
        initial_seq = int(knobs.read_knob("numa_local_fault_window", default="0") or 0)

        write_event(
            writer,
            "start",
            started_ms,
            0,
            initial_seq,
            args,
            WindowStats(),
            WindowStats(),
            VmstatStats(),
            0,
            0,
            knobs.node_balancing(),
            current_sample_pct,
            "",
            reenable_consecutive,
            controller_state,
            "start",
            initial_seq,
        )
        out.flush()

        while not stop_flag["stop"]:
            if args.stop_file is not None and args.stop_file.exists():
                break
            if args.max_windows and window >= args.max_windows:
                break

            if configured_sample_pct > 0:
                knobs.write_knob(
                    "numa_local_fault_on_tiering",
                    int(configured_sample_pct),
                    required=False,
                )
            if not args.no_advance_window:
                knobs.write_knob("numa_local_fault_window", 1, required=False)
            try:
                round_seq = int(knobs.read_knob("numa_local_fault_window", default="0") or 0)
            except ValueError:
                round_seq = 0

            current_sample_pct = sample_pct(args, knobs)
            expected_pte = expected_sampled_pages(
                knobs, args.local_node, current_sample_pct
            )
            raw_round_base = read_totals(knobs)
            raw_remote_base = raw_round_base
            vmstat_round_base = read_vmstat()
            round_stats = WindowStats(seq=round_seq)
            remote_raw = WindowStats()
            vmstat_stats = VmstatStats()
            arm_windows = 0

            while not stop_flag["stop"]:
                if args.stop_file is not None and args.stop_file.exists():
                    break
                if args.max_windows and window >= args.max_windows:
                    break
                window += 1
                arm_windows += 1
                if not sleep_interruptible(args.window_sec, args.stop_file, stop_flag):
                    break

                cur = read_totals(knobs)
                vmstat_cur = read_vmstat()
                remote_raw = diff_stats(cur, raw_remote_base)
                vmstat_stats = diff_vmstat(vmstat_cur, vmstat_round_base)
                round_stats = diff_stats(cur, raw_round_base)
                if not args.no_window_buckets:
                    bucket = read_bucket(knobs, "current")
                    if bucket is not None and bucket.seq == round_seq:
                        round_stats = bucket
                coverage = ratio_pct(round_stats.pte_updates, expected_pte)

                write_event(
                    writer,
                    "sample",
                    started_ms,
                    window,
                    round_seq,
                    args,
                    round_stats,
                    remote_raw,
                    vmstat_stats,
                    local_consecutive,
                    remote_consecutive,
                    knobs.node_balancing(),
                    current_sample_pct,
                    "",
                    reenable_consecutive,
                    controller_state,
                    "arm",
                    round_seq,
                    arm_windows,
                    expected_pte,
                    coverage,
                )
                out.flush()

                if round_arm_done(args, round_stats, arm_windows, expected_pte):
                    break

            if stop_flag["stop"] or (args.stop_file is not None and args.stop_file.exists()):
                break
            if args.max_windows and window >= args.max_windows:
                break

            knobs.write_knob("numa_local_fault_on_tiering", 0, required=False)
            coverage = ratio_pct(round_stats.pte_updates, expected_pte)
            write_event(
                writer,
                "freeze",
                started_ms,
                window,
                round_seq,
                args,
                round_stats,
                remote_raw,
                vmstat_stats,
                local_consecutive,
                remote_consecutive,
                knobs.node_balancing(),
                current_sample_pct,
                "",
                reenable_consecutive,
                controller_state,
                "freeze",
                round_seq,
                arm_windows,
                expected_pte,
                coverage,
            )
            out.flush()

            observe_windows = 0
            local_condition = False
            remote_condition = False
            stop_reason = ""
            while observe_windows < args.observe_windows and not stop_flag["stop"]:
                if args.stop_file is not None and args.stop_file.exists():
                    break
                if args.max_windows and window >= args.max_windows:
                    break
                window += 1
                observe_windows += 1
                if not sleep_interruptible(args.window_sec, args.stop_file, stop_flag):
                    break

                cur = read_totals(knobs)
                vmstat_cur = read_vmstat()
                remote_raw = diff_stats(cur, raw_remote_base)
                vmstat_stats = diff_vmstat(vmstat_cur, vmstat_round_base)
                round_stats = diff_stats(cur, raw_round_base)
                if not args.no_window_buckets:
                    bucket = read_bucket(knobs, "current")
                    if bucket is not None and bucket.seq == round_seq:
                        round_stats = bucket
                coverage = ratio_pct(round_stats.pte_updates, expected_pte)
                access = local_access_value(
                    args, round_stats, remote_raw, current_sample_pct
                )
                remote = remote_ratio_pct(args, remote_raw, current_sample_pct)
                local_condition = local_condition_met(
                    args, round_stats, remote_raw, current_sample_pct
                )
                remote_condition = (
                    remote_raw.hint_faults >= args.min_hint_faults
                    and remote <= args.remote_threshold_pct
                )
                stop_reason = ""
                if local_condition:
                    stop_reason = "local_access"
                elif remote_condition:
                    stop_reason = "remote_ratio"

                write_event(
                    writer,
                    "sample",
                    started_ms,
                    window,
                    round_seq,
                    args,
                    round_stats,
                    remote_raw,
                    vmstat_stats,
                    local_consecutive,
                    remote_consecutive,
                    knobs.node_balancing(),
                    current_sample_pct,
                    "",
                    reenable_consecutive,
                    controller_state,
                    "observe",
                    round_seq,
                    observe_windows,
                    expected_pte,
                    coverage,
                )
                out.flush()

            if stop_flag["stop"] or (args.stop_file is not None and args.stop_file.exists()):
                break

            if local_condition:
                local_consecutive += 1
            else:
                local_consecutive = 0
            if remote_condition:
                remote_consecutive += 1
            else:
                remote_consecutive = 0

            if controller_state == "off":
                if local_condition or remote_condition:
                    reenable_consecutive = 0
                else:
                    reenable_consecutive += 1

            should_stop = (
                controller_state == "on"
                and (
                    local_consecutive >= args.consecutive
                    or remote_consecutive >= args.remote_consecutive
                )
            )
            if should_stop:
                if local_consecutive >= args.consecutive:
                    stop_reason = "local_access"
                else:
                    stop_reason = "remote_ratio"
                if not args.dry_run:
                    knobs.write_knob("node_balancing", 0)
                    if args.stop_local_fault:
                        knobs.write_knob("numa_local_fault_on_tiering", 0, required=False)
                controller_state = "off"
                reenable_consecutive = 0
                write_event(
                    writer,
                    "off",
                    started_ms,
                    window,
                    round_seq,
                    args,
                    round_stats,
                    remote_raw,
                    vmstat_stats,
                    local_consecutive,
                    remote_consecutive,
                    knobs.node_balancing(),
                    current_sample_pct,
                    stop_reason,
                    reenable_consecutive,
                    controller_state,
                    "decision",
                    round_seq,
                    observe_windows,
                    expected_pte,
                    ratio_pct(round_stats.pte_updates, expected_pte),
                )
                out.flush()
                if args.reenable_consecutive == 0:
                    return 0
                local_consecutive = 0
                remote_consecutive = 0

            should_reenable = (
                controller_state == "off"
                and args.reenable_consecutive > 0
                and reenable_consecutive >= args.reenable_consecutive
            )
            if should_reenable:
                if not args.dry_run:
                    knobs.write_knob("node_balancing", args.node_balancing_on)
                controller_state = "on"
                write_event(
                    writer,
                    "on",
                    started_ms,
                    window,
                    round_seq,
                    args,
                    round_stats,
                    remote_raw,
                    vmstat_stats,
                    local_consecutive,
                    remote_consecutive,
                    knobs.node_balancing(),
                    current_sample_pct,
                    "reenable",
                    reenable_consecutive,
                    controller_state,
                    "decision",
                    round_seq,
                    observe_windows,
                    expected_pte,
                    ratio_pct(round_stats.pte_updates, expected_pte),
                )
                out.flush()
                local_consecutive = 0
                remote_consecutive = 0
                reenable_consecutive = 0

        knobs.write_knob(
            "numa_local_fault_on_tiering",
            int(configured_sample_pct),
            required=False,
        )
        write_event(
            writer,
            "exit",
            started_ms,
            window,
            0,
            args,
            WindowStats(),
            WindowStats(),
            VmstatStats(),
            local_consecutive,
            remote_consecutive,
            knobs.node_balancing(),
            sample_pct(args, knobs),
            "",
            reenable_consecutive,
            controller_state,
            "exit",
        )
        out.flush()
        return 0
    finally:
        if should_close:
            out.close()


def run_controller(args: argparse.Namespace) -> int:
    if args.local_access_mode == "window":
        return run_window_controller(args)
    return run_round_controller(args)


def main(argv: Optional[Iterable[str]] = None) -> int:
    try:
        args = parse_args(argv)
        validate_args(args)
        return run_controller(args)
    except Exception as exc:  # pragma: no cover - keeps guest logs readable.
        print(f"local_util_adapt_controller: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
