# Migration-Friendly VM Harness

This directory is a small standalone VM setup repo for the NUMA/CXL experiments.
It keeps only portable host-side VM orchestration. Large rootfs images, overlays,
ISOs, and generated logs are intentionally ignored.

## Selected Inputs

The script distills the reusable parts from the existing experiment tree:

- `scripts/kernel/launch_kernel_qemu.sh`: QEMU boot flow, kernel/rootfs/initrd options, SSH port forwarding.
- `reuse_time/docs/cxl-hotset-perf-analysis-20260506.md`: corrected CXL-backed placement, where guest node0 is host node0 DRAM and guest node1 is host node2 CXL.
- `reuse_time/vm/prepare_vm.sh`: guest-side debugfs/module preparation assumptions.

The ICCD workload runners are kept under `scripts/` as a small reusable set.
Do not add per-experiment one-off runners; boot and stage through this repo,
then select workloads with environment variables.

## Quick Start

Check host dependencies and NUMA topology:

```bash
./vmctl.sh check
```

Create a small writable overlay from an existing rootfs image:

```bash
./vmctl.sh create-image \
  --overlay-from /path/to/base-ubuntu.qcow2 \
  --output images/ubuntu.overlay.qcow2
```

Boot the corrected DRAM/CXL layout used in the latest experiments:

```bash
./vmctl.sh boot \
  --kernel /Serverless/Migration-friendly/linux/arch/x86/boot/bzImage \
  --initrd /boot/initrd.img-6.18.0modified \
  --rootfs images/ubuntu.overlay.qcow2 \
  --rootfs-format qcow2 \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  --host-cpus 0-31 \
  --guest-cpus 32 \
  --guest-node0-cpus 0-31 \
  --fast-host-node 0 \
  --slow-host-node 2 \
  --fast-mem 64G \
  --slow-mem 64G
```

Wait for SSH and verify placement:

```bash
./vmctl.sh wait-ssh --ssh-key /tmp/reuse_vm_g28/id_rsa --ssh-port 10023
./vmctl.sh verify-placement --ssh-key /tmp/reuse_vm_g28/id_rsa --ssh-port 10023
```

Stop the VM:

```bash
./vmctl.sh stop
```

## QEMU Source Policy

QEMU source is not copied into this repo by default. The experiments used
standard QEMU features:

- `memory-backend-ram`
- `host-nodes=...,policy=bind`
- guest NUMA nodes
- KVM acceleration
- user-mode SSH forwarding

Those are available in normal distro QEMU builds. If a host does not have a
suitable QEMU, build one locally without committing it:

```bash
./vmctl.sh build-qemu --ref v9.2.2
./vmctl.sh boot --qemu-bin ./qemu-build/bin/qemu-system-x86_64 ...
```

Generated QEMU source/build directories are ignored by git.

## Supported Feature Matrix

| Feature | Supported | Command |
| --- | --- | --- |
| Dependency and NUMA topology check | yes | `check` |
| Empty qcow2 creation | yes | `create-image --size` |
| Overlay qcow2 from a base image | yes | `create-image --overlay-from` |
| Ubuntu cloud image download | yes | `create-image --download` |
| Local QEMU source clone/build | yes | `build-qemu` |
| Kernel/module build and dracut initrd creation | yes | `build-initrd` |
| KVM/TCG selection | yes | `boot --accel` |
| Kernel/initrd/direct rootfs boot | yes | `boot --kernel --initrd --rootfs` |
| Corrected host DRAM/CXL binding | yes | `boot --fast-host-node --slow-host-node` |
| QEMU CPU pinning | yes | `boot --host-cpus` |
| QMP socket, pidfile, serial log | yes | `boot`, `status` |
| SSH wait and login | yes | `wait-ssh`, `ssh` |
| Guest debugfs/cgroup/demotion prep | yes | `prepare-guest` |
| Upload/download helper | yes | `copy-to`, `copy-from` |
| Guest tmux background command | yes | `tmux-run` |
| ICCD workload matrix sweeps | yes | `scripts/run_workload_suite_guest.sh` |
| Large rootfs/ISO storage | no | generated or supplied locally |

## ICCD Ours Scripts

The active workload-side entrypoints are:

- `scripts/stage_workloads_to_vm.sh`: host-side staging into a live VM
- `scripts/run_workload_suite_guest.sh`: guest-side matrix/calibration runner
- `scripts/run_ours_experiment.sh`: one workload under `off`, `on`, or `ours`
- `scripts/run_workload_case_guest.sh`: real-world workload commands/profiles
- `scripts/local_util_adapt_controller.py`: local-fault controller

Example staging and run:

```bash
PORT=10064 WORKLOADS=scalable ./scripts/stage_workloads_to_vm.sh

./vmctl.sh tmux-run --ssh-port 10064 --session rss60 -- \
  'OUTROOT=/root/rss60-8g WORKLOADS=scalable POLICIES="off on ours" MODE=matrix /root/scripts/run_workload_suite_guest.sh'
```

The intent is that VM placement and workload policy are both reusable here,
with workload selection controlled through environment variables.

## ICCD PR Smoke Test

From a fresh machine, clone this repo and point these variables at local
artifacts. The rootfs, kernel, initrd, SSH key, and benchmark cache are supplied
locally and are intentionally not committed.

```bash
git clone git@github.com:zktsd813/linux-kernel-vm.git
cd linux-kernel-vm

export QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
export KERNEL=/path/to/bzImage
export INITRD=/path/to/initramfs.img
export ROOTFS=/path/to/ubuntu.img
export SSH_KEY=/path/to/id_rsa
export BENCHMARK_DIR=/Serverless/benchmark
export PORT=10084

./vmctl.sh boot \
  --qemu-bin "$QEMU_BIN" \
  --kernel "$KERNEL" \
  --initrd "$INITRD" \
  --rootfs "$ROOTFS" \
  --rootfs-format raw \
  --ssh-port "$PORT" \
  --name iccd-pr-script-smoke \
  --host-cpus 0-31 \
  --guest-cpus 32 \
  --guest-node0-cpus 0-31 \
  --fast-host-node 0 \
  --slow-host-node 2 \
  --fast-mem 8G \
  --slow-mem 160G \
  --accel kvm

./vmctl.sh wait-ssh --ssh-key "$SSH_KEY" --ssh-port "$PORT"
./vmctl.sh verify-placement --ssh-key "$SSH_KEY" --ssh-port "$PORT" \
  --name iccd-pr-script-smoke

PORT="$PORT" SSH_KEY="$SSH_KEY" WORKLOADS=pr \
  BENCHMARK_DIR="$BENCHMARK_DIR" ./scripts/stage_workloads_to_vm.sh

./vmctl.sh ssh --ssh-key "$SSH_KEY" --ssh-port "$PORT" -- \
  'OUTROOT=/root/script-smoke-pr WORKLOADS=pr POLICIES="off ours" \
   CAPS=physical:0 MODE=matrix PR_ITERATIONS=1 PR_TRIALS=1 \
   TIMEOUT_SEC=1200 OMP_THREADS=32 WINDOW_SEC=2 MIN_ARM_WINDOWS=1 \
   MAX_ARM_WINDOWS=2 OBSERVE_WINDOWS=1 \
   /root/scripts/run_workload_suite_guest.sh'

./vmctl.sh ssh --ssh-key "$SSH_KEY" --ssh-port "$PORT" -- \
  'cat /root/script-smoke-pr/summary.csv'

./vmctl.sh stop --name iccd-pr-script-smoke
```

For full PR runs, use the same flow with `POLICIES="off on ours"`,
`PR_ITERATIONS=20`, and the desired `--fast-mem` value such as `8G`, `16G`, or
`32G`. The GAPBS graph should already exist at
`${BENCHMARK_DIR}/gapbs/benchmark/graphs/kron_g28.sg`; the staging script copies
it into the guest as `/root/gapbs_graphs/kron_g28.sg`.

## Corrected Default Topology

The default `boot` topology is:

```text
host CPU affinity: 0-31
guest node0: CPUs 0-31, 64G memory, host node0 bind, DRAM fast tier
guest node1: no CPUs, 64G memory, host node2 bind, CXL slow tier
QEMU memory backends: host-nodes=0/2, policy=bind, prealloc=on
```

This avoids the earlier invalid setup where the guest remote node was not bound
to host CXL memory.

## Image Policy

No large image is committed. `vmctl.sh create-image` can:

- create an empty qcow2 disk,
- create a qcow2 overlay from an existing base image,
- download an Ubuntu cloud image on demand.

Downloaded/generated images stay under `images/` by default and are ignored.

## Useful Commands

For the full operational manual, including command options and an end-to-end
experiment flow, see [USAGE.md](USAGE.md).

Print the QEMU command without running it:

```bash
./vmctl.sh boot --dry-run --kernel /path/bzImage --rootfs /path/rootfs.qcow2
```

Open SSH into the guest:

```bash
./vmctl.sh ssh --ssh-key /tmp/reuse_vm_g28/id_rsa --ssh-port 10023
```

Run a command in the guest:

```bash
./vmctl.sh ssh --ssh-key /tmp/reuse_vm_g28/id_rsa --ssh-port 10023 -- 'numactl -H'
```

Prepare common guest knobs:

```bash
./vmctl.sh prepare-guest \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  --global-numa-balancing 2 \
  --demotion-enabled true \
  --demotion-target '0 1' \
  --scan-size-mb 256
```

Run a long guest command under tmux:

```bash
./vmctl.sh tmux-run \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  --session perf_cap_sweep \
  --log /tmp/perf_cap_sweep_tmux.log \
  -- 'bash /root/run_perf_cap_sweep_inner.sh'
```
