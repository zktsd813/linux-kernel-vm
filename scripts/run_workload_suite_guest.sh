#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${RUNNER:-${SCRIPT_DIR}/run_ours_experiment.sh}"
CASE_RUNNER="${CASE_RUNNER:-${SCRIPT_DIR}/run_workload_case_guest.sh}"
OUTROOT="${OUTROOT:-/root/ours-workloads}"
MODE="${MODE:-matrix}"
WORKLOADS="${WORKLOADS:-scalable}"
POLICIES="${POLICIES:-off on ours}"
CAPS="${CAPS:-physical:0}"
BENCHMARK_DIR="${BENCHMARK_DIR:-/root/benchmark}"
GRAPH="${GRAPH:-/root/gapbs_graphs/kron_g28.sg}"
OMP_THREADS="${OMP_THREADS:-32}"
TIMEOUT_SEC="${TIMEOUT_SEC:-7200}"
RESUME="${RESUME:-1}"
REALWORLD_SIZE_PROFILE="${REALWORLD_SIZE_PROFILE:-rss60}"

CPUSET_CPUS="${CPUSET_CPUS:-0-31}"
CPUSET_MEMS="${CPUSET_MEMS:-0,1}"
NUMA_SCAN_SIZE_MB="${NUMA_SCAN_SIZE_MB:-256}"
NUMA_SCAN_PERIOD_MIN_MS="${NUMA_SCAN_PERIOD_MIN_MS:-1000}"
LOCAL_FAULT_RATE="${LOCAL_FAULT_RATE:-10}"
LOCAL_FAULT_HIT_MS="${LOCAL_FAULT_HIT_MS:-2000}"
LOCAL_FAULT_SCAN_PERIOD_MS="${LOCAL_FAULT_SCAN_PERIOD_MS:-1000}"
LOCAL_FAULT_SCAN_SIZE_MB="${LOCAL_FAULT_SCAN_SIZE_MB:-auto}"
WINDOW_SEC="${WINDOW_SEC:-5}"
THRESHOLD_PCT="${THRESHOLD_PCT:-80}"
CONSECUTIVE="${CONSECUTIVE:-3}"
MIN_PTE_UPDATES="${MIN_PTE_UPDATES:-1}"
REMOTE_THRESHOLD_PCT="${REMOTE_THRESHOLD_PCT:-20}"
REMOTE_CONSECUTIVE="${REMOTE_CONSECUTIVE:-3}"
MIN_HINT_FAULTS="${MIN_HINT_FAULTS:-1}"
REENABLE_CONSECUTIVE="${REENABLE_CONSECUTIVE:-2}"
USE_WINDOW_BUCKETS="${USE_WINDOW_BUCKETS:-0}"

GUPS_MEMORY_GB="${GUPS_MEMORY_GB:-64}"
GRAPH500_SCALE="${GRAPH500_SCALE:-28}"
XSBENCH_GRID="${XSBENCH_GRID:-130000}"
XSBENCH_PARTICLES="${XSBENCH_PARTICLES:-90000000}"
GAPBS_TRIALS="${GAPBS_TRIALS:-16}"
PR_ITERATIONS="${PR_ITERATIONS:-20}"
PR_TRIALS="${PR_TRIALS:-1}"
PR_TOLERANCE="${PR_TOLERANCE:-1e-4}"
BC_TRIALS="${BC_TRIALS:-1}"
BC_ITERATIONS="${BC_ITERATIONS:-1}"
TARGET_GIB="${TARGET_GIB:-60}"
SAMPLE_SEC="${SAMPLE_SEC:-1}"

mkdir -p "${OUTROOT}"
export REALWORLD_SIZE_PROFILE OMP_THREADS

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${OUTROOT}/orchestrator.log"
}

expand_workloads() {
  local out=()
  local item
  for item in "$@"; do
    case "${item}" in
      scalable)
        out+=(redis_uniform redis_ycsb_a rocksdb_ycsb_uniform memcached_ycsb_uniform faster_uniform faster_ycsb_a dlrm_synth)
        ;;
      realworld|core)
        out+=(redis_uniform redis_ycsb_a rocksdb_ycsb_uniform memcached_ycsb_uniform faster_uniform faster_ycsb_a dlrm_synth npb_cg npb_mg npb_ua spec_bwaves canneal_synth)
        ;;
      candidate|candidates)
        out+=(pr bc gups graph500 btree xsbench gapbs_bfs gapbs_cc gapbs_sssp)
        ;;
      all)
        out+=(redis_uniform redis_ycsb_a rocksdb_ycsb_uniform memcached_ycsb_uniform faster_uniform faster_ycsb_a dlrm_synth npb_cg npb_mg npb_ua spec_bwaves canneal_synth pr bc gups graph500 btree xsbench gapbs_bfs gapbs_cc gapbs_sssp)
        ;;
      *)
        out+=("${item}")
        ;;
    esac
  done
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}

resolve_existing_file() {
  local path="$1"
  [[ -e "${path}" ]] || return 1
  printf '%s\n' "${path}"
}

set_workload_cmd() {
  local workload="$1"
  CMD=()
  CMD_DISPLAY=""

  case "${workload}" in
    pr|gapbs_pr)
      CMD=("$(resolve_existing_file "${BENCHMARK_DIR}/gapbs/pr")" -f "${GRAPH}" -i "${PR_ITERATIONS}" -t "${PR_TOLERANCE}" -n "${PR_TRIALS}")
      ;;
    bc|gapbs_bc)
      CMD=("$(resolve_existing_file "${BENCHMARK_DIR}/gapbs/bc")" -f "${GRAPH}" -i "${BC_ITERATIONS}" -n "${BC_TRIALS}")
      ;;
    gups|gups_64g)
      CMD=("$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_gups_mt")" "${GUPS_MEMORY_GB}")
      ;;
    graph500|graph500_s28)
      CMD=("$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_graph500_mt")" -s "${GRAPH500_SCALE}")
      ;;
    btree|btree_lookup)
      CMD=("$(resolve_existing_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_btree_mt")")
      ;;
    xsbench|xsbench_grid130k_p90m)
      CMD=("$(resolve_existing_file "${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench")" -t "${OMP_THREADS}" -g "${XSBENCH_GRID}" -p "${XSBENCH_PARTICLES}")
      ;;
    gapbs_bfs|bfs)
      CMD=("$(resolve_existing_file "${BENCHMARK_DIR}/gapbs/bfs")" -f "${GRAPH}" -n "${GAPBS_BFS_TRIALS:-${GAPBS_TRIALS}}")
      ;;
    gapbs_cc|cc)
      CMD=("$(resolve_existing_file "${BENCHMARK_DIR}/gapbs/cc")" -f "${GRAPH}" -n "${GAPBS_CC_TRIALS:-${GAPBS_TRIALS}}")
      ;;
    gapbs_sssp|sssp)
      CMD=("$(resolve_existing_file "${BENCHMARK_DIR}/gapbs/sssp")" -f "${GRAPH}" -n "${GAPBS_SSSP_TRIALS:-${GAPBS_TRIALS}}")
      ;;
    *)
      CMD=("${CASE_RUNNER}" "${workload}")
      ;;
  esac

  printf -v CMD_DISPLAY '%q ' "${CMD[@]}"
}

drop_caches() {
  sync || true
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

run_case() {
  local cap_label="$1"
  local capacity_pages="$2"
  local workload="$3"
  local policy="$4"
  local outdir="${OUTROOT}/${cap_label}/${workload}/${policy}"
  local demotion_enabled=1
  local kswapd_demotion=1

  mkdir -p "${outdir}"
  if [[ "${RESUME}" == "1" && -e "${outdir}/status.txt" ]] && grep -q '^returncode=0$' "${outdir}/status.txt"; then
    log "skip existing successful cap=${cap_label} workload=${workload} policy=${policy}"
    return 0
  fi

  if [[ "${policy}" == "off" ]]; then
    demotion_enabled=0
    kswapd_demotion=0
  fi

  set_workload_cmd "${workload}"
  drop_caches
  log "start cap=${cap_label} workload=${workload} policy=${policy}"

  set +e
  USE_WINDOW_BUCKETS="${USE_WINDOW_BUCKETS}" CONTROLLER="${SCRIPT_DIR}/local_util_adapt_controller.py" "${RUNNER}" \
    --outdir "${outdir}" \
    --run-id "${workload}-${policy}-${cap_label}" \
    --cgroup-name "ours_${workload}_${policy}_${cap_label}_$$" \
    --policy "${policy}" \
    --capacity-node 0 \
    --capacity-pages "${capacity_pages}" \
    --node-balancing 2 \
    --kswapd-demotion "${kswapd_demotion}" \
    --global-demotion-enabled "${demotion_enabled}" \
    --global-demotion-target "0 1" \
    --scan-size-mb "${NUMA_SCAN_SIZE_MB}" \
    --scan-period-min-ms "${NUMA_SCAN_PERIOD_MIN_MS}" \
    --fast-scan 0 \
    --hot-threshold-ms 0 \
    --mglru 0x0007 \
    --cpuset-cpus "${CPUSET_CPUS}" \
    --cpuset-mems "${CPUSET_MEMS}" \
    --omp-threads "${OMP_THREADS}" \
    --timeout-sec "${TIMEOUT_SEC}" \
    --window-sec "${WINDOW_SEC}" \
    --threshold-pct "${THRESHOLD_PCT}" \
    --consecutive "${CONSECUTIVE}" \
    --min-pte-updates "${MIN_PTE_UPDATES}" \
    --remote-threshold-pct "${REMOTE_THRESHOLD_PCT}" \
    --remote-consecutive "${REMOTE_CONSECUTIVE}" \
    --min-hint-faults "${MIN_HINT_FAULTS}" \
    --local-fault-rate "${LOCAL_FAULT_RATE}" \
    --local-fault-hit-ms "${LOCAL_FAULT_HIT_MS}" \
    --local-fault-scan-period-ms "${LOCAL_FAULT_SCAN_PERIOD_MS}" \
    --local-fault-scan-size-mb "${LOCAL_FAULT_SCAN_SIZE_MB}" \
    --local-fault-sample-pct "${LOCAL_FAULT_RATE}" \
    --reenable-consecutive "${REENABLE_CONSECUTIVE}" \
    --eval-lag prev \
    -- \
    "${CMD[@]}"
  local rc=$?
  set -e

  {
    echo "cap_label=${cap_label}"
    echo "capacity_pages=${capacity_pages}"
    echo "workload_name=${workload}"
    echo "policy_label=${policy}"
    echo "command=${CMD_DISPLAY}"
  } >> "${outdir}/run_config.txt"
  log "done cap=${cap_label} workload=${workload} policy=${policy} rc=${rc}"
}

read_memstat_field() {
  local cg="$1"
  local key="$2"
  awk -v key="${key}" '$1 == key { print $2; found=1 } END { if (!found) print 0 }' \
    "${cg}/memory.stat" 2>/dev/null || printf '0\n'
}

sum_cgroup_rss_bytes() {
  local cg="$1"
  local pid
  local total_kb=0
  [[ -r "${cg}/cgroup.procs" ]] || {
    printf '0\n'
    return 0
  }
  while read -r pid; do
    [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/status" ]] || continue
    local rss
    rss="$(awk '$1 == "VmRSS:" { print $2; exit }' "/proc/${pid}/status" 2>/dev/null || true)"
    [[ "${rss}" =~ ^[0-9]+$ ]] || rss=0
    total_kb=$((total_kb + rss))
  done < "${cg}/cgroup.procs"
  printf '%s\n' $((total_kb * 1024))
}

calibrate_one() {
  local workload="$1"
  local safe="${workload//[^A-Za-z0-9_]/_}"
  local outdir="${OUTROOT}/calibrate/${safe}"
  local cgroup_name="rsscal_${safe}_$$"
  local cg="/sys/fs/cgroup/${cgroup_name}"

  rm -rf "${outdir}"
  mkdir -p "${outdir}"
  set_workload_cmd "${workload}"
  log "calibrate workload=${workload}"

  set +e
  USE_WINDOW_BUCKETS=0 "${RUNNER}" \
    --outdir "${outdir}/run" \
    --run-id "rsscal_${safe}" \
    --cgroup-name "${cgroup_name}" \
    --keep-cgroup \
    --policy off \
    --capacity-pages 0 \
    --global-demotion-enabled 0 \
    --cpuset-cpus "${CPUSET_CPUS}" \
    --cpuset-mems "${CPUSET_MEMS}" \
    --omp-threads "${OMP_THREADS}" \
    --timeout-sec "${TIMEOUT_SEC}" \
    -- \
    "${CMD[@]}" &
  local runner_pid="$!"

  {
    echo "timestamp,elapsed_s,memory_current_bytes,process_rss_bytes,anon_bytes,file_bytes,shmem_bytes"
    local start_s now elapsed mem rss anon file shmem
    start_s="$(date +%s)"
    while kill -0 "${runner_pid}" >/dev/null 2>&1; do
      now="$(date +%s)"
      elapsed=$((now - start_s))
      mem="$(cat "${cg}/memory.current" 2>/dev/null || echo 0)"
      rss="$(sum_cgroup_rss_bytes "${cg}")"
      anon="$(read_memstat_field "${cg}" anon)"
      file="$(read_memstat_field "${cg}" file)"
      shmem="$(read_memstat_field "${cg}" shmem)"
      printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${elapsed}" "${mem}" "${rss}" "${anon}" "${file}" "${shmem}"
      sleep "${SAMPLE_SEC}"
    done
  } > "${outdir}/rss_samples.csv"

  wait "${runner_pid}"
  local rc=$?
  set -e
  summarize_calibration_one "${outdir}" "${workload}" "${rc}"
  rmdir "${cg}" 2>/dev/null || true
}

summarize_calibration_one() {
  python3 - <<'PY' "$1" "$2" "$3" "${TARGET_GIB}"
from pathlib import Path
import csv
import sys

outdir = Path(sys.argv[1])
workload, rc, target = sys.argv[2], sys.argv[3], float(sys.argv[4])
peak = {k: 0 for k in ("memory_current", "process_rss", "anon", "file", "shmem")}
samples = outdir / "rss_samples.csv"
if samples.exists():
    for row in csv.DictReader(samples.open()):
        for k in peak:
            try:
                peak[k] = max(peak[k], int(row.get(k + "_bytes", 0) or 0))
            except ValueError:
                pass
def gib(v): return v / 1024 / 1024 / 1024
with (outdir / "rss_summary.txt").open("w") as f:
    f.write(f"workload={workload}\nreturncode={rc}\ntarget_gib={target:.3f}\n")
    for k, v in peak.items():
        f.write(f"peak_{k}_gib={gib(v):.3f}\n")
PY
}

summarize_matrix() {
  python3 - <<'PY' "${OUTROOT}"
from pathlib import Path
import csv
import re
import sys

root = Path(sys.argv[1])
rows = []

def read_kv(path):
    vals = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                vals[k] = v
    return vals

def vmstat_delta(case_dir, key):
    vals = {}
    path = case_dir / "vmstat.after"
    before = {}
    for target, out in ((case_dir / "vmstat.before", before), (path, vals)):
        if target.exists():
            for line in target.read_text(errors="replace").splitlines():
                fields = line.split()
                if len(fields) == 2:
                    try:
                        out[fields[0]] = int(fields[1])
                    except ValueError:
                        pass
    return vals.get(key, 0) - before.get(key, 0)

def parse_stdout(path):
    text = path.read_text(errors="replace") if path.exists() else ""
    m = re.search(r"Average Time:\s*([0-9.]+)", text)
    avg = m.group(1) if m else ""
    m = re.search(r"Read Time:\s*([0-9.]+)", text)
    read = m.group(1) if m else ""
    m = re.findall(r"Took:\s*([0-9.]+)", text)
    took = m[-1] if m else ""
    m = re.search(r"\[OVERALL\], Throughput\(ops/sec\),\s*([0-9.]+)", text)
    ycsb = m.group(1) if m else ""
    return avg, read, took, ycsb

for case_dir in sorted(p for p in root.glob("*/*/*") if (p / "status.txt").exists()):
    cap, workload, policy = case_dir.parts[-3:]
    status = read_kv(case_dir / "status.txt")
    config = read_kv(case_dir / "run_config.txt")
    avg, read, took, ycsb = parse_stdout(case_dir / "workload.stdout.log")
    rows.append({
        "cap": cap,
        "workload": workload,
        "policy": policy,
        "returncode": status.get("returncode", ""),
        "elapsed_s": status.get("elapsed_s", ""),
        "avg_trial_s": avg,
        "read_s": read,
        "took_s": took,
        "ycsb_throughput_ops": ycsb,
        "numa_hint_faults": vmstat_delta(case_dir, "numa_hint_faults"),
        "pgpromote_success": vmstat_delta(case_dir, "pgpromote_success"),
        "pgdemote_kswapd": vmstat_delta(case_dir, "pgdemote_kswapd"),
        "pgdemote_direct": vmstat_delta(case_dir, "pgdemote_direct"),
        "command": config.get("command", ""),
    })

out = root / "summary.csv"
fields = list(rows[0].keys()) if rows else ["cap", "workload", "policy"]
with out.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
print(out)
PY
}

main() {
  mapfile -t workload_list < <(expand_workloads ${WORKLOADS})
  case "${MODE}" in
    matrix)
      local cap
      for cap in ${CAPS}; do
        local cap_label="${cap%%:*}"
        local capacity_pages="${cap#*:}"
        local workload policy
        for workload in "${workload_list[@]}"; do
          for policy in ${POLICIES}; do
            run_case "${cap_label}" "${capacity_pages}" "${workload}" "${policy}"
          done
        done
      done
      summarize_matrix
      ;;
    calibrate)
      local workload
      for workload in "${workload_list[@]}"; do
        calibrate_one "${workload}"
      done
      ;;
    *)
      echo "unknown MODE=${MODE}; expected matrix or calibrate" >&2
      exit 2
      ;;
  esac
}

main "$@"
