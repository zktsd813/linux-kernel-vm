# ICCD Ours Scripts

The active script set is intentionally small. Do not add per-experiment
`run_*.sh` files under `experiments/`; use these scripts with environment
variables instead.

## Files

- `run_ours_experiment.sh`: one workload execution wrapper. It creates a
  cgroup for process containment, applies global NUMA/demotion/local-fault
  knobs, runs `off`, `on`, or `ours`, and writes logs/counters.
- `local_util_adapt_controller.py`: userspace controller for `ours`. It reads
  local-fault stats and toggles global NUMA balancing when the configured local
  access condition is met.
- `run_workload_case_guest.sh`: workload command implementations and RSS60
  profiles for real-world cases.
- `run_workload_suite_guest.sh`: reusable guest-side orchestrator for matrix or
  calibration runs. Configure with `WORKLOADS`, `POLICIES`, `CAPS`, `OUTROOT`,
  and `MODE`.
- `stage_workloads_to_vm.sh`: host-side staging helper. It copies the active
  scripts and selected workload payloads into a live VM.

## Examples

Stage scalable RSS60 workloads:

```bash
PORT=10064 WORKLOADS=scalable ./stage_workloads_to_vm.sh
```

Stage only GAPBS PR into a live VM:

```bash
PORT=10084 SSH_KEY=/path/to/id_rsa WORKLOADS=pr \
BENCHMARK_DIR=/Serverless/benchmark ./stage_workloads_to_vm.sh
```

Run one matrix inside the guest:

```bash
OUTROOT=/root/rss60-8g WORKLOADS=scalable POLICIES="off on ours" \
CAPS=physical:0 MODE=matrix /root/scripts/run_workload_suite_guest.sh
```

Run a short PR smoke matrix inside the guest:

```bash
OUTROOT=/root/script-smoke-pr WORKLOADS=pr POLICIES="off ours" \
CAPS=physical:0 MODE=matrix PR_ITERATIONS=1 PR_TRIALS=1 \
TIMEOUT_SEC=1200 OMP_THREADS=32 WINDOW_SEC=2 MIN_ARM_WINDOWS=1 \
MAX_ARM_WINDOWS=2 OBSERVE_WINDOWS=1 \
/root/scripts/run_workload_suite_guest.sh
```

Calibrate RSS:

```bash
OUTROOT=/root/rss60-cal WORKLOADS=scalable MODE=calibrate \
/root/scripts/run_workload_suite_guest.sh
```
