#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER="${CONTROLLER:-${SCRIPT_DIR}/local_util_adapt_controller.py}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-localutil}"
OUTDIR="${OUTDIR:-}"
CGROUP_ROOT="${CGROUP_ROOT:-/sys/fs/cgroup}"
CGROUP_NAME="${CGROUP_NAME:-}"
CGROUP_PATH=""
KEEP_CGROUP=0
POLICY="${POLICY:-ours}"

CAPACITY_NODE="${CAPACITY_NODE:-0}"
CAPACITY_PAGES="${CAPACITY_PAGES:-0}"
NODE_BALANCING_ON="${NODE_BALANCING_ON:-2}"
KSWAPD_DEMOTION_ON="${KSWAPD_DEMOTION_ON:-1}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-10}"
LOCAL_FAULT_HIT_MS="${LOCAL_FAULT_HIT_MS:-2000}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-auto}"
GLOBAL_NUMA_BALANCING="${GLOBAL_NUMA_BALANCING:-}"
GLOBAL_DEMOTION_ENABLED="${GLOBAL_DEMOTION_ENABLED:-1}"
GLOBAL_DEMOTION_TARGET="${GLOBAL_DEMOTION_TARGET:-0 1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-}"
NUMA_FAST_SCAN="${NUMA_FAST_SCAN:-0}"
HOT_THRESHOLD_MS="${HOT_THRESHOLD_MS:-0}"
MGLRU_ENABLED="${MGLRU_ENABLED:-0x0007}"
CPUSET_CPUS="${CPUSET_CPUS:-}"
CPUSET_MEMS="${CPUSET_MEMS:-}"
OMP_THREADS="${OMP_THREADS:-}"
TIMEOUT_SEC="${TIMEOUT_SEC:-0}"

WINDOW_SEC="${WINDOW_SEC:-10}"
THRESHOLD_PCT="${THRESHOLD_PCT:-80}"
CONSECUTIVE="${CONSECUTIVE:-3}"
MIN_PTE_UPDATES="${MIN_PTE_UPDATES:-1000}"
REMOTE_THRESHOLD_PCT="${REMOTE_THRESHOLD_PCT:-20}"
REMOTE_CONSECUTIVE="${REMOTE_CONSECUTIVE:-0}"
MIN_HINT_FAULTS="${MIN_HINT_FAULTS:-1}"
LOCAL_FAULT_SAMPLE_PCT="${LOCAL_FAULT_SAMPLE_PCT:-0}"
REENABLE_CONSECUTIVE="${REENABLE_CONSECUTIVE:-0}"
LOCAL_ACCESS_MODE="${LOCAL_ACCESS_MODE:-round}"
LOCAL_ACCESS_SIGNAL="${LOCAL_ACCESS_SIGNAL:-fast}"
LOCAL_COMPOSITION_SLOW_WEIGHT="${LOCAL_COMPOSITION_SLOW_WEIGHT:-0.25}"
MIN_OBSERVED_ACCESSES="${MIN_OBSERVED_ACCESSES:-0}"
LOCAL_NODE="${LOCAL_NODE:-0}"
MIN_ARM_WINDOWS="${MIN_ARM_WINDOWS:-3}"
MAX_ARM_WINDOWS="${MAX_ARM_WINDOWS:-12}"
ARM_COVERAGE_PCT="${ARM_COVERAGE_PCT:-60}"
OBSERVE_WINDOWS="${OBSERVE_WINDOWS:-1}"
EVAL_LAG="${EVAL_LAG:-prev}"
USE_WINDOW_BUCKETS="${USE_WINDOW_BUCKETS:-0}"
ADVANCE_WINDOW=1
STOP_LOCAL_FAULT=0
DRY_RUN=0
SYSFS_NUMA_DIR="${SYSFS_NUMA_DIR:-/sys/kernel/mm/numa_balancing}"

WORKLOAD=()

usage() {
  cat <<'EOF'
Usage:
  run_ours_experiment.sh [options] -- <workload command...>
  run_ours_experiment.sh --example pr-g28 [options]
  run_ours_experiment.sh --print-examples

Purpose:
  Run one workload inside a cgroup with migration initially enabled, start the
  local-util Python controller, and turn migration off when local access ratio
  stays above threshold for N consecutive windows.

Common options:
  --outdir DIR                 result directory
  --run-id ID                  run identifier
  --cgroup-root DIR            default: /sys/fs/cgroup
  --cgroup-name NAME           default: localutil_${RUN_ID}
  --capacity-pages PAGES       write node_capacity as "<node> <pages>"; 0 skips
  --capacity-node NODE         default: 0
  --node-balancing VALUE       default: 2
  --kswapd-demotion VALUE      default: 1
  --local-fault-rate RATE      default: 10; writes global local_fault_rate
  --local-fault-hit-ms MS      default: 2000
  --local-fault-scan-period-ms MS
                               default: 1000; local PFN scan period
  --local-fault-scan-size-mb MB|auto
                               default: auto; auto scans one local-cap pass per
                               period. 8GiB at 10% becomes 820MiB.
  --global-numa-balancing VAL  optionally write /proc/sys/kernel/numa_balancing
  --global-demotion-enabled V   default: 1; empty skips
  --global-demotion-target STR  default: "0 1"; empty skips
  --scan-size-mb MB             optionally write debugfs scan_size_mb
  --scan-period-min-ms MS       optionally write debugfs scan_period_min_ms
  --fast-scan VALUE             default: 0; writes legacy cgroup fast-scan if present
  --hot-threshold-ms MS         default: 0; writes legacy cgroup hot threshold if present
  --mglru VALUE                default: 0x0007; empty disables write
  --cpuset-cpus LIST           optionally write cpuset.cpus
  --cpuset-mems LIST           optionally write cpuset.mems
  --omp-threads N              run workload with OMP_NUM_THREADS=N
  --timeout-sec SEC            0 means no timeout
  --keep-cgroup                do not remove cgroup after run
  --policy off|on|ours         off disables migration, on keeps migration on,
                               ours runs the controller

Controller options:
  --window-sec SEC             default: 10
  --threshold-pct PCT          default: 80
  --consecutive N              default: 3
  --min-pte-updates N          default: 1000
  --remote-threshold-pct PCT   default: 20, residual remote ratio threshold
  --remote-consecutive N       default: 0, reuses --consecutive
  --min-hint-faults N          default: 1
  --local-fault-sample-pct PCT default: 0, read cgroup knob
  --reenable-consecutive N    default: 0, one-shot stop; >0 toggles migration
  --local-access-mode MODE    default: round; round|window
  --local-access-signal SIG   default: fast; fast|access|composition
  --local-composition-slow-weight W
                               default: 0.25; composition mode slow-refault weight
  --min-observed-accesses N   default: 0; composition mode access proxy floor
  --local-node NODE           default: 0
  --min-arm-windows N         default: 3, round mode only
  --max-arm-windows N         default: 12, round mode only
  --arm-coverage-pct PCT      default: 60, round mode only
  --observe-windows N         default: 1, round mode only
  --eval-lag current|prev|prev2 default: prev
  --no-window-buckets          use raw deltas instead of kernel buckets
  --no-advance-window          do not write numa_local_fault_window=1
  --stop-local-fault           also disable local fault after migration stop
  --dry-run                    log off event without writing node_balancing=0

Example names:
  microbench-stream32
  pr-g28
  bc-g28
EOF
}

print_examples() {
  cat <<'EOF'
# Microbenchmark example: stream/read style workload.
scripts/run_ours_experiment.sh \
  --outdir /tmp/localutil-mbench \
  --capacity-pages 2097152 \
  --window-sec 5 \
  --threshold-pct 80 \
  --remote-threshold-pct 20 \
  --consecutive 3 \
  -- \
  /root/mbench --mode bw --bw-kernel read --arena-size 32G --window-size 32G \
    --threads 32 --duration 300 --sample-ms 1000 --csv

# GAPBS PageRank example.  Use a prebuilt graph with -f; do not rebuild in the
# measured path.
scripts/run_ours_experiment.sh \
  --outdir /tmp/localutil-pr-g28 \
  --capacity-pages 2097152 \
  --omp-threads 32 \
  --window-sec 5 \
  --remote-threshold-pct 20 \
  -- \
  /root/pr -f /root/gapbs_graphs/kron_g28.sg -i20 -t1e-4 -n3

# GAPBS BC example with a prebuilt graph.
scripts/run_ours_experiment.sh \
  --outdir /tmp/localutil-bc-g28 \
  --capacity-pages 2097152 \
  --omp-threads 32 \
  --window-sec 10 \
  --remote-threshold-pct 20 \
  -- \
  /root/bc -f /root/gapbs_graphs/kron_g28.sg -i1 -n10
EOF
}

set_example_workload() {
  local name="$1"
  case "${name}" in
    microbench-stream32)
      WORKLOAD=(
        /root/mbench
        --mode bw
        --bw-kernel read
        --arena-size 32G
        --window-size 32G
        --threads 32
        --duration 300
        --sample-ms 1000
        --csv
      )
      ;;
    pr-g28)
      WORKLOAD=(/root/pr -f /root/gapbs_graphs/kron_g28.sg -i20 -t1e-4 -n3)
      ;;
    bc-g28)
      WORKLOAD=(/root/bc -f /root/gapbs_graphs/kron_g28.sg -i1 -n10)
      ;;
    *)
      echo "unknown example workload: ${name}" >&2
      exit 2
      ;;
  esac
}

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --print-examples)
      print_examples
      exit 0
      ;;
    --example)
      set_example_workload "${2:?missing --example value}"
      shift 2
      ;;
    --outdir)
      OUTDIR="${2:?missing --outdir value}"
      shift 2
      ;;
    --run-id)
      RUN_ID="${2:?missing --run-id value}"
      shift 2
      ;;
    --cgroup-root)
      CGROUP_ROOT="${2:?missing --cgroup-root value}"
      shift 2
      ;;
    --cgroup-name)
      CGROUP_NAME="${2:?missing --cgroup-name value}"
      shift 2
      ;;
    --capacity-pages)
      CAPACITY_PAGES="${2:?missing --capacity-pages value}"
      shift 2
      ;;
    --capacity-node)
      CAPACITY_NODE="${2:?missing --capacity-node value}"
      shift 2
      ;;
    --node-balancing)
      NODE_BALANCING_ON="${2:?missing --node-balancing value}"
      shift 2
      ;;
    --kswapd-demotion)
      KSWAPD_DEMOTION_ON="${2:?missing --kswapd-demotion value}"
      shift 2
      ;;
    --local-fault-rate)
      LOCAL_FAULT_RATE="${2:?missing --local-fault-rate value}"
      shift 2
      ;;
    --local-fault-hit-ms)
      LOCAL_FAULT_HIT_MS="${2:?missing --local-fault-hit-ms value}"
      shift 2
      ;;
    --local-fault-scan-period-ms)
      LOCAL_FAULT_SCAN_PERIOD_MS="${2:?missing --local-fault-scan-period-ms value}"
      shift 2
      ;;
    --local-fault-scan-size-mb)
      LOCAL_FAULT_SCAN_SIZE_MB="${2:?missing --local-fault-scan-size-mb value}"
      shift 2
      ;;
    --global-numa-balancing)
      GLOBAL_NUMA_BALANCING="${2:?missing --global-numa-balancing value}"
      shift 2
      ;;
    --global-demotion-enabled)
      if (($# < 2)); then
        echo "missing --global-demotion-enabled value" >&2
        exit 2
      fi
      GLOBAL_DEMOTION_ENABLED="$2"
      shift 2
      ;;
    --global-demotion-target)
      if (($# < 2)); then
        echo "missing --global-demotion-target value" >&2
        exit 2
      fi
      GLOBAL_DEMOTION_TARGET="$2"
      shift 2
      ;;
    --scan-size-mb)
      NUMA_SCAN_SIZE_MB="${2:?missing --scan-size-mb value}"
      shift 2
      ;;
    --scan-period-min-ms)
      NUMA_SCAN_PERIOD_MIN_MS="${2:?missing --scan-period-min-ms value}"
      shift 2
      ;;
    --fast-scan)
      NUMA_FAST_SCAN="${2:?missing --fast-scan value}"
      shift 2
      ;;
    --hot-threshold-ms)
      HOT_THRESHOLD_MS="${2:?missing --hot-threshold-ms value}"
      shift 2
      ;;
    --mglru)
      if (($# < 2)); then
        echo "missing --mglru value" >&2
        exit 2
      fi
      MGLRU_ENABLED="$2"
      shift 2
      ;;
    --cpuset-cpus)
      CPUSET_CPUS="${2:?missing --cpuset-cpus value}"
      shift 2
      ;;
    --cpuset-mems)
      CPUSET_MEMS="${2:?missing --cpuset-mems value}"
      shift 2
      ;;
    --omp-threads)
      OMP_THREADS="${2:?missing --omp-threads value}"
      shift 2
      ;;
    --timeout-sec)
      TIMEOUT_SEC="${2:?missing --timeout-sec value}"
      shift 2
      ;;
    --window-sec)
      WINDOW_SEC="${2:?missing --window-sec value}"
      shift 2
      ;;
    --threshold-pct)
      THRESHOLD_PCT="${2:?missing --threshold-pct value}"
      shift 2
      ;;
    --consecutive)
      CONSECUTIVE="${2:?missing --consecutive value}"
      shift 2
      ;;
    --min-pte-updates)
      MIN_PTE_UPDATES="${2:?missing --min-pte-updates value}"
      shift 2
      ;;
    --remote-threshold-pct)
      REMOTE_THRESHOLD_PCT="${2:?missing --remote-threshold-pct value}"
      shift 2
      ;;
    --remote-consecutive)
      REMOTE_CONSECUTIVE="${2:?missing --remote-consecutive value}"
      shift 2
      ;;
    --min-hint-faults)
      MIN_HINT_FAULTS="${2:?missing --min-hint-faults value}"
      shift 2
      ;;
    --local-fault-sample-pct)
      LOCAL_FAULT_SAMPLE_PCT="${2:?missing --local-fault-sample-pct value}"
      shift 2
      ;;
    --reenable-consecutive)
      REENABLE_CONSECUTIVE="${2:?missing --reenable-consecutive value}"
      shift 2
      ;;
    --local-access-mode)
      LOCAL_ACCESS_MODE="${2:?missing --local-access-mode value}"
      shift 2
      ;;
    --local-access-signal)
      LOCAL_ACCESS_SIGNAL="${2:?missing --local-access-signal value}"
      shift 2
      ;;
    --local-composition-slow-weight)
      LOCAL_COMPOSITION_SLOW_WEIGHT="${2:?missing --local-composition-slow-weight value}"
      shift 2
      ;;
    --min-observed-accesses)
      MIN_OBSERVED_ACCESSES="${2:?missing --min-observed-accesses value}"
      shift 2
      ;;
    --local-node)
      LOCAL_NODE="${2:?missing --local-node value}"
      shift 2
      ;;
    --min-arm-windows)
      MIN_ARM_WINDOWS="${2:?missing --min-arm-windows value}"
      shift 2
      ;;
    --max-arm-windows)
      MAX_ARM_WINDOWS="${2:?missing --max-arm-windows value}"
      shift 2
      ;;
    --arm-coverage-pct)
      ARM_COVERAGE_PCT="${2:?missing --arm-coverage-pct value}"
      shift 2
      ;;
    --observe-windows)
      OBSERVE_WINDOWS="${2:?missing --observe-windows value}"
      shift 2
      ;;
    --eval-lag)
      EVAL_LAG="${2:?missing --eval-lag value}"
      shift 2
      ;;
    --no-window-buckets)
      USE_WINDOW_BUCKETS=0
      shift
      ;;
    --no-advance-window)
      ADVANCE_WINDOW=0
      shift
      ;;
    --stop-local-fault)
      STOP_LOCAL_FAULT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --keep-cgroup)
      KEEP_CGROUP=1
      shift
      ;;
    --policy)
      POLICY="${2:?missing --policy value}"
      shift 2
      ;;
    --)
      shift
      WORKLOAD=("$@")
      break
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ${#WORKLOAD[@]} -eq 0 ]]; then
  echo "missing workload command; pass -- <command...> or --example NAME" >&2
  usage >&2
  exit 2
fi

case "${POLICY}" in
  off|on|ours) ;;
  *)
    echo "invalid --policy: ${POLICY}" >&2
    exit 2
    ;;
esac

if [[ -z "${OUTDIR}" ]]; then
  OUTDIR="$(pwd)/localutil-runs/${RUN_ID}"
fi
if [[ -z "${CGROUP_NAME}" ]]; then
  CGROUP_NAME="localutil_${RUN_ID}"
fi

if [[ ! -x "${CONTROLLER}" ]]; then
  echo "controller is not executable: ${CONTROLLER}" >&2
  exit 1
fi

mkdir -p "${OUTDIR}"
CGROUP_PATH="${CGROUP_ROOT%/}/${CGROUP_NAME}"
STOP_FILE="${OUTDIR}/stop-controller"
CONTROLLER_CSV="${OUTDIR}/controller.csv"
STDOUT_LOG="${OUTDIR}/workload.stdout.log"
STDERR_LOG="${OUTDIR}/workload.stderr.log"
STATUS_FILE="${OUTDIR}/status.txt"
CONFIG_FILE="${OUTDIR}/run_config.txt"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${OUTDIR}/run.log" >&2
}

pick_knob_file() {
  local cg="$1"
  local knob="$2"
  if [[ -e "${cg}/${knob}" ]]; then
    printf '%s\n' "${cg}/${knob}"
  elif [[ -e "${cg}/memory.${knob}" ]]; then
    printf '%s\n' "${cg}/memory.${knob}"
  else
    return 1
  fi
}

write_file_optional() {
  local file="$1"
  local value="$2"
  [[ -e "${file}" ]] || return 0
  printf '%s\n' "${value}" > "${file}" || true
}

set_global_numa_balancing() {
  local value="$1"
  if [[ -e /proc/sys/kernel/numa_balancing ]]; then
    if [[ -z "${ORIG_GLOBAL_NUMA_BALANCING:-}" ]]; then
      ORIG_GLOBAL_NUMA_BALANCING="$(cat /proc/sys/kernel/numa_balancing)"
    fi
    printf '%s\n' "${value}" > /proc/sys/kernel/numa_balancing
  fi
}

write_local_fault_optional() {
  local name="$1"
  local value="$2"
  write_file_optional "${SYSFS_NUMA_DIR}/${name}" "${value}"
}

write_local_fault_required() {
  local cgroup_name="$1"
  local sysfs_name="$2"
  local value="$3"
  local wrote=0

  if pick_knob_file "${CGROUP_PATH}" "${cgroup_name}" >/dev/null 2>&1; then
    write_knob_optional "${CGROUP_PATH}" "${cgroup_name}" "${value}"
    wrote=1
  fi
  if [[ -e "${SYSFS_NUMA_DIR}/${sysfs_name}" ]]; then
    printf '%s\n' "${value}" > "${SYSFS_NUMA_DIR}/${sysfs_name}"
    wrote=1
  fi
  if [[ "${wrote}" == "0" ]]; then
    echo "missing local-fault knob: ${cgroup_name} or ${SYSFS_NUMA_DIR}/${sysfs_name}" >&2
    return 1
  fi
}

write_knob() {
  local cg="$1"
  local knob="$2"
  local value="$3"
  local file
  file="$(pick_knob_file "${cg}" "${knob}")" || {
    echo "missing required cgroup knob: ${knob}" >&2
    return 1
  }
  printf '%s\n' "${value}" > "${file}"
}

write_knob_optional() {
  local cg="$1"
  local knob="$2"
  local value="$3"
  local file
  file="$(pick_knob_file "${cg}" "${knob}")" || return 0
  printf '%s\n' "${value}" > "${file}" || true
}

node_memtotal_kb() {
  local nid="$1"
  local file="/sys/devices/system/node/node${nid}/meminfo"
  [[ -r "${file}" ]] || return 1
  awk -v node="Node ${nid} MemTotal:" '$1" "$2" "$3 == node { print $4; exit }' "${file}"
}

compute_local_fault_scan_size_mb() {
  local cap_pages="$1"
  local rate="$2"
  local node="$3"
  local node_kb
  local node_mb

  if [[ "${rate}" == "0" ]]; then
    printf '0\n'
    return 0
  fi

  if [[ "${cap_pages}" != "0" ]]; then
    printf '%d\n' $(( (cap_pages * rate + 25599) / 25600 ))
    return 0
  fi

  node_kb="$(node_memtotal_kb "${node}" || true)"
  if [[ -n "${node_kb}" && "${node_kb}" =~ ^[0-9]+$ ]]; then
    node_mb=$(( (node_kb + 1023) / 1024 ))
    printf '%d\n' $(( (node_mb * rate + 99) / 100 ))
    return 0
  fi

  printf '0\n'
}

snapshot_cgroup() {
  local out="$1"
  {
    if [[ -d "${SYSFS_NUMA_DIR}" ]]; then
      printf '### sysfs.numa_balancing\n'
      for name in \
        local_fault_rate \
        local_fault_scan_period_ms \
        local_fault_scan_size_mb \
        local_fault_refault_hit_ms \
        local_fault_window \
        local_fault_stats; do
        if [[ -e "${SYSFS_NUMA_DIR}/${name}" ]]; then
          printf '## %s\n' "${SYSFS_NUMA_DIR}/${name}"
          cat "${SYSFS_NUMA_DIR}/${name}" || true
        fi
      done
    fi
    for name in \
      node_balancing \
      node_capacity \
      kswapd_demotion_enabled \
      numa_local_fault_on_tiering \
      numa_local_fault_scan_period_ms \
      numa_local_fault_scan_size_mb \
      numa_local_fault_refault_hit_ms \
      numa_migrate_state \
      memory.numa_stat \
      memory.current; do
      if [[ -e "${CGROUP_PATH}/${name}" ]]; then
        printf '### %s\n' "${name}"
        cat "${CGROUP_PATH}/${name}" || true
      elif [[ -e "${CGROUP_PATH}/memory.${name}" ]]; then
        printf '### memory.%s\n' "${name}"
        cat "${CGROUP_PATH}/memory.${name}" || true
      fi
    done
  } > "${out}"
}

cleanup() {
  local rc=$?
  touch "${STOP_FILE}" 2>/dev/null || true
  if [[ -n "${CONTROLLER_PID:-}" ]]; then
    wait "${CONTROLLER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${ORIG_GLOBAL_NUMA_BALANCING:-}" && -e /proc/sys/kernel/numa_balancing ]]; then
    printf '%s\n' "${ORIG_GLOBAL_NUMA_BALANCING}" > /proc/sys/kernel/numa_balancing || true
  fi
  if [[ -n "${ORIG_GLOBAL_DEMOTION_ENABLED:-}" && -e /sys/kernel/mm/numa/demotion_enabled ]]; then
    printf '%s\n' "${ORIG_GLOBAL_DEMOTION_ENABLED}" > /sys/kernel/mm/numa/demotion_enabled || true
  fi
  if [[ -n "${ORIG_GLOBAL_DEMOTION_TARGET:-}" && -e /sys/kernel/mm/numa/demotion_target ]]; then
    printf '%s\n' "${ORIG_GLOBAL_DEMOTION_TARGET%%$'\n'*}" > /sys/kernel/mm/numa/demotion_target || true
  fi
  if [[ "${KEEP_CGROUP}" != "1" && -d "${CGROUP_PATH}" ]]; then
    rmdir "${CGROUP_PATH}" 2>/dev/null || true
  fi
  exit "${rc}"
}
trap cleanup EXIT

rm -f "${STOP_FILE}"
mkdir -p "${CGROUP_PATH}"

if [[ -e "${CGROUP_PATH}/cpuset.cpus" && -n "${CPUSET_CPUS}" ]]; then
  printf '%s\n' "${CPUSET_CPUS}" > "${CGROUP_PATH}/cpuset.cpus"
fi
if [[ -e "${CGROUP_PATH}/cpuset.mems" && -n "${CPUSET_MEMS}" ]]; then
  printf '%s\n' "${CPUSET_MEMS}" > "${CGROUP_PATH}/cpuset.mems"
fi

ORIG_GLOBAL_NUMA_BALANCING=""
if [[ -n "${GLOBAL_NUMA_BALANCING}" && -e /proc/sys/kernel/numa_balancing ]]; then
  set_global_numa_balancing "${GLOBAL_NUMA_BALANCING}"
fi
ORIG_GLOBAL_DEMOTION_ENABLED=""
if [[ -n "${GLOBAL_DEMOTION_ENABLED}" && -e /sys/kernel/mm/numa/demotion_enabled ]]; then
  ORIG_GLOBAL_DEMOTION_ENABLED="$(cat /sys/kernel/mm/numa/demotion_enabled)"
  printf '%s\n' "${GLOBAL_DEMOTION_ENABLED}" > /sys/kernel/mm/numa/demotion_enabled || true
fi
ORIG_GLOBAL_DEMOTION_TARGET=""
if [[ -n "${GLOBAL_DEMOTION_TARGET}" && -e /sys/kernel/mm/numa/demotion_target ]]; then
  ORIG_GLOBAL_DEMOTION_TARGET="$(cat /sys/kernel/mm/numa/demotion_target)"
  printf '%s\n' "${GLOBAL_DEMOTION_TARGET}" > /sys/kernel/mm/numa/demotion_target || true
fi
if [[ -n "${NUMA_SCAN_SIZE_MB}${NUMA_SCAN_PERIOD_MIN_MS}" ]]; then
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
fi
if [[ -n "${NUMA_SCAN_SIZE_MB}" ]]; then
  write_file_optional /sys/kernel/debug/sched/numa_balancing/scan_size_mb "${NUMA_SCAN_SIZE_MB}"
fi
if [[ -n "${NUMA_SCAN_PERIOD_MIN_MS}" ]]; then
  write_file_optional /sys/kernel/debug/sched/numa_balancing/scan_period_min_ms "${NUMA_SCAN_PERIOD_MIN_MS}"
fi
if [[ -n "${MGLRU_ENABLED}" && -e /sys/kernel/mm/lru_gen/enabled ]]; then
  printf '%s\n' "${MGLRU_ENABLED}" > /sys/kernel/mm/lru_gen/enabled || true
fi

if [[ "${CAPACITY_PAGES}" != "0" ]]; then
  write_knob_optional "${CGROUP_PATH}" node_capacity "${CAPACITY_NODE} ${CAPACITY_PAGES}" || true
fi
case "${POLICY}" in
  off)
    write_knob_optional "${CGROUP_PATH}" node_balancing 0 || true
    set_global_numa_balancing 0
    ;;
  on|ours)
    write_knob_optional "${CGROUP_PATH}" node_balancing "${NODE_BALANCING_ON}" || true
    set_global_numa_balancing "${NODE_BALANCING_ON}"
    ;;
esac
write_knob_optional "${CGROUP_PATH}" kswapd_demotion_enabled "${KSWAPD_DEMOTION_ON}"
write_knob_optional "${CGROUP_PATH}" numa_balancing_fast_scan "${NUMA_FAST_SCAN}"
write_knob_optional "${CGROUP_PATH}" numa_balancing_hot_threshold_ms "${HOT_THRESHOLD_MS}"
case "${POLICY}" in
  ours)
    write_local_fault_required numa_local_fault_on_tiering local_fault_rate "${LOCAL_FAULT_RATE}"
    ;;
  off|on)
    write_knob_optional "${CGROUP_PATH}" numa_local_fault_on_tiering 0
    write_local_fault_optional local_fault_rate 0
    ;;
esac
if [[ "${POLICY}" == "ours" ]]; then
  if [[ -n "${LOCAL_FAULT_SCAN_PERIOD_MS}" ]]; then
    write_knob_optional "${CGROUP_PATH}" \
      numa_local_fault_scan_period_ms "${LOCAL_FAULT_SCAN_PERIOD_MS}"
    write_local_fault_optional \
      local_fault_scan_period_ms "${LOCAL_FAULT_SCAN_PERIOD_MS}"
  fi
  if [[ "${LOCAL_FAULT_SCAN_SIZE_MB}" == "auto" ]]; then
    LOCAL_FAULT_SCAN_SIZE_MB_EFFECTIVE="$(
      compute_local_fault_scan_size_mb \
        "${CAPACITY_PAGES}" "${LOCAL_FAULT_RATE}" "${LOCAL_NODE}"
    )"
  else
    LOCAL_FAULT_SCAN_SIZE_MB_EFFECTIVE="${LOCAL_FAULT_SCAN_SIZE_MB}"
  fi
  if [[ "${LOCAL_FAULT_SCAN_SIZE_MB_EFFECTIVE}" != "0" ]]; then
    write_knob_optional "${CGROUP_PATH}" \
      numa_local_fault_scan_size_mb "${LOCAL_FAULT_SCAN_SIZE_MB_EFFECTIVE}"
    write_local_fault_optional \
      local_fault_scan_size_mb "${LOCAL_FAULT_SCAN_SIZE_MB_EFFECTIVE}"
  fi
else
  LOCAL_FAULT_SCAN_SIZE_MB_EFFECTIVE="${LOCAL_FAULT_SCAN_SIZE_MB}"
fi
write_knob_optional "${CGROUP_PATH}" numa_local_fault_refault_hit_ms "${LOCAL_FAULT_HIT_MS}"
write_local_fault_optional local_fault_refault_hit_ms "${LOCAL_FAULT_HIT_MS}"
write_knob_optional "${CGROUP_PATH}" numa_migration_stop_enabled 0
write_knob_optional "${CGROUP_PATH}" numa_pingpong_stat_enabled 0
write_knob_optional "${CGROUP_PATH}" numa_promote_sample_stat_enabled 0

{
  echo "run_id=${RUN_ID}"
  echo "policy=${POLICY}"
  echo "outdir=${OUTDIR}"
  echo "cgroup=${CGROUP_PATH}"
  echo "capacity_node=${CAPACITY_NODE}"
  echo "capacity_pages=${CAPACITY_PAGES}"
  echo "node_balancing_on=${NODE_BALANCING_ON}"
  echo "kswapd_demotion_on=${KSWAPD_DEMOTION_ON}"
  echo "global_demotion_enabled=${GLOBAL_DEMOTION_ENABLED}"
  echo "global_demotion_target=${GLOBAL_DEMOTION_TARGET}"
  echo "scan_size_mb=${NUMA_SCAN_SIZE_MB}"
  echo "scan_period_min_ms=${NUMA_SCAN_PERIOD_MIN_MS}"
  echo "fast_scan=${NUMA_FAST_SCAN}"
  echo "hot_threshold_ms=${HOT_THRESHOLD_MS}"
  echo "local_fault_rate=${LOCAL_FAULT_RATE}"
  echo "local_fault_hit_ms=${LOCAL_FAULT_HIT_MS}"
  echo "local_fault_scan_period_ms=${LOCAL_FAULT_SCAN_PERIOD_MS}"
  echo "local_fault_scan_size_mb=${LOCAL_FAULT_SCAN_SIZE_MB}"
  echo "local_fault_scan_size_mb_effective=${LOCAL_FAULT_SCAN_SIZE_MB_EFFECTIVE:-}"
  echo "window_sec=${WINDOW_SEC}"
  echo "threshold_pct=${THRESHOLD_PCT}"
  echo "consecutive=${CONSECUTIVE}"
  echo "min_pte_updates=${MIN_PTE_UPDATES}"
  echo "remote_threshold_pct=${REMOTE_THRESHOLD_PCT}"
  echo "remote_consecutive=${REMOTE_CONSECUTIVE}"
  echo "min_hint_faults=${MIN_HINT_FAULTS}"
  echo "local_fault_sample_pct=${LOCAL_FAULT_SAMPLE_PCT}"
  echo "reenable_consecutive=${REENABLE_CONSECUTIVE}"
  echo "local_access_mode=${LOCAL_ACCESS_MODE}"
  echo "local_access_signal=${LOCAL_ACCESS_SIGNAL}"
  echo "local_composition_slow_weight=${LOCAL_COMPOSITION_SLOW_WEIGHT}"
  echo "min_observed_accesses=${MIN_OBSERVED_ACCESSES}"
  echo "local_node=${LOCAL_NODE}"
  echo "min_arm_windows=${MIN_ARM_WINDOWS}"
  echo "max_arm_windows=${MAX_ARM_WINDOWS}"
  echo "arm_coverage_pct=${ARM_COVERAGE_PCT}"
  echo "observe_windows=${OBSERVE_WINDOWS}"
  echo "eval_lag=${EVAL_LAG}"
  echo "use_window_buckets=${USE_WINDOW_BUCKETS}"
  echo "advance_window=${ADVANCE_WINDOW}"
  echo "stop_local_fault=${STOP_LOCAL_FAULT}"
  echo "dry_run=${DRY_RUN}"
  echo "timeout_sec=${TIMEOUT_SEC}"
  echo "omp_threads=${OMP_THREADS}"
  printf 'workload='
  printf '%q ' "${WORKLOAD[@]}"
  printf '\n'
} > "${CONFIG_FILE}"

snapshot_cgroup "${OUTDIR}/cgroup.before"
[[ -e /proc/vmstat ]] && cat /proc/vmstat > "${OUTDIR}/vmstat.before"

controller_args=(
  "${CONTROLLER}"
  --cgroup "${CGROUP_PATH}"
  --window-sec "${WINDOW_SEC}"
  --threshold-pct "${THRESHOLD_PCT}"
  --consecutive "${CONSECUTIVE}"
  --min-pte-updates "${MIN_PTE_UPDATES}"
  --remote-threshold-pct "${REMOTE_THRESHOLD_PCT}"
  --remote-consecutive "${REMOTE_CONSECUTIVE}"
  --min-hint-faults "${MIN_HINT_FAULTS}"
  --local-fault-sample-pct "${LOCAL_FAULT_SAMPLE_PCT}"
  --node-balancing-on "${NODE_BALANCING_ON}"
  --reenable-consecutive "${REENABLE_CONSECUTIVE}"
  --local-access-mode "${LOCAL_ACCESS_MODE}"
  --local-access-signal "${LOCAL_ACCESS_SIGNAL}"
  --local-composition-slow-weight "${LOCAL_COMPOSITION_SLOW_WEIGHT}"
  --min-observed-accesses "${MIN_OBSERVED_ACCESSES}"
  --local-node "${LOCAL_NODE}"
  --min-arm-windows "${MIN_ARM_WINDOWS}"
  --max-arm-windows "${MAX_ARM_WINDOWS}"
  --arm-coverage-pct "${ARM_COVERAGE_PCT}"
  --observe-windows "${OBSERVE_WINDOWS}"
  --eval-lag "${EVAL_LAG}"
  --stop-file "${STOP_FILE}"
  --output "${CONTROLLER_CSV}"
)
if [[ "${USE_WINDOW_BUCKETS}" == "0" ]]; then
  controller_args+=(--no-window-buckets)
fi
if [[ "${ADVANCE_WINDOW}" == "0" ]]; then
  controller_args+=(--no-advance-window)
fi
if [[ "${STOP_LOCAL_FAULT}" == "1" ]]; then
  controller_args+=(--stop-local-fault)
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  controller_args+=(--dry-run)
fi

if [[ "${POLICY}" == "ours" ]]; then
  log "starting controller"
  "${controller_args[@]}" &
  CONTROLLER_PID="$!"
else
  log "controller disabled for policy=${POLICY}"
  CONTROLLER_PID=""
fi

workload_env=(env)
if [[ -n "${OMP_THREADS}" ]]; then
  workload_env+=(OMP_NUM_THREADS="${OMP_THREADS}" OMP_PROC_BIND=true OMP_PLACES=cores)
fi

log "running workload"
start_s="$(date +%s)"
set +e
if [[ "${TIMEOUT_SEC}" != "0" ]]; then
  timeout "${TIMEOUT_SEC}" bash -c \
    'echo $$ > "$1/cgroup.procs"; shift; exec "$@"' \
    _ "${CGROUP_PATH}" "${workload_env[@]}" "${WORKLOAD[@]}" \
    > "${STDOUT_LOG}" 2> "${STDERR_LOG}"
else
  bash -c \
    'echo $$ > "$1/cgroup.procs"; shift; exec "$@"' \
    _ "${CGROUP_PATH}" "${workload_env[@]}" "${WORKLOAD[@]}" \
    > "${STDOUT_LOG}" 2> "${STDERR_LOG}"
fi
workload_rc=$?
set -e
end_s="$(date +%s)"

touch "${STOP_FILE}"
if [[ -n "${CONTROLLER_PID}" ]]; then
  wait "${CONTROLLER_PID}" 2>/dev/null || true
  CONTROLLER_PID=""
fi

snapshot_cgroup "${OUTDIR}/cgroup.after"
[[ -e /proc/vmstat ]] && cat /proc/vmstat > "${OUTDIR}/vmstat.after"

{
  echo "returncode=${workload_rc}"
  echo "elapsed_s=$((end_s - start_s))"
  echo "controller_csv=${CONTROLLER_CSV}"
  echo "stdout=${STDOUT_LOG}"
  echo "stderr=${STDERR_LOG}"
} > "${STATUS_FILE}"

log "done rc=${workload_rc} elapsed_s=$((end_s - start_s)) outdir=${OUTDIR}"
exit "${workload_rc}"
