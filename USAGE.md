# vmctl.sh Usage Guide

This document is the operational manual for `vmctl.sh`. It explains what the
script supports, how to run the corrected CXL-backed VM setup, and what remains
outside this repo.

## What This Script Does

`vmctl.sh` handles VM lifecycle and common guest preparation:

- host dependency and NUMA topology checks
- local rootfs image or overlay creation
- optional local QEMU source clone/build
- optional kernel module build and dracut initrd generation
- QEMU boot with explicit host NUMA memory binding
- SSH wait/login/copy helpers
- common guest NUMA/demotion/debugfs setup
- tmux-based long-running command launch
- placement verification and VM stop/status

It does not implement workload-specific experiment matrices. Those should stay
in benchmark repos and use this repo only to boot and prepare the VM.

## Directory Layout

```text
/Serverless/VM/
  vmctl.sh          single entrypoint
  README.md         short overview
  USAGE.md          detailed usage guide
  images/           generated or supplied rootfs images, ignored
  run/              pidfiles, serial logs, QMP sockets, ignored
  kernel-artifacts/ generated initrd/module staging, ignored
  qemu-src/         optional QEMU source clone, ignored
  qemu-build/       optional QEMU install prefix, ignored
```

## Current Experiment Topology

The default `boot` command matches the corrected CXL-backed VM setup:

```text
host CPU affinity: 0-31
QEMU accel:        KVM when /dev/kvm is usable, otherwise TCG
guest CPUs:        32
guest memory:      128G total
guest node0:       CPUs 0-31, 64G, backed by host node0 DRAM
guest node1:       memory-only, 64G, backed by host node2 CXL
memory binding:    host-nodes=0/2,policy=bind,prealloc=on
SSH forwarding:    host 10023 -> guest 22
```

This is the important part of the setup. If `host-nodes=2,policy=bind` is
missing for guest node1, the experiment can silently run against normal DRAM
instead of CXL.

## 1. Check Host Readiness

```bash
./vmctl.sh check
```

Expected output:

- `qemu-system-x86_64`, `qemu-img`, `ssh`, `scp` are present.
- `/dev/kvm` is usable if KVM acceleration is expected.
- host node0 and host node2 exist.
- node2 has non-zero memory if it is the CXL/system-ram node.

Useful variants:

```bash
./vmctl.sh check --fast-host-node 0 --slow-host-node 2
./vmctl.sh check --qemu-bin ./qemu-build/bin/qemu-system-x86_64
./vmctl.sh check --kernel /path/to/bzImage --rootfs images/ubuntu.overlay.qcow2
```

## 2. Prepare a Rootfs Image

Large images are not committed. Use one of these patterns.

Create an empty qcow2 disk:

```bash
./vmctl.sh create-image --output images/rootfs.qcow2 --size 80G
```

Create a writable overlay from an existing base image:

```bash
./vmctl.sh create-image \
  --overlay-from /path/to/base-ubuntu.qcow2 \
  --output images/ubuntu.overlay.qcow2
```

Download a cloud image:

```bash
./vmctl.sh create-image \
  --download ubuntu-24.04 \
  --output images/noble-server-cloudimg-amd64.img
```

Notes:

- `create-image` does not install packages or users by itself.
- The image must already be bootable with the kernel/root device you pass to
  `boot`.
- The default root device is `/dev/vda2`; override it with `boot --root-device`
  if your image uses a different partition.

## 3. Build QEMU If Needed

Most hosts can use `/usr/bin/qemu-system-x86_64`. If a host lacks QEMU or you
want a fixed version:

```bash
./vmctl.sh build-qemu --ref v9.2.2
```

Use the built binary:

```bash
./vmctl.sh boot --qemu-bin ./qemu-build/bin/qemu-system-x86_64 ...
```

Advanced build options:

```bash
./vmctl.sh build-qemu \
  --repo https://gitlab.com/qemu-project/qemu.git \
  --ref v9.2.2 \
  --src ./qemu-src \
  --prefix ./qemu-build \
  --target-list x86_64-softmmu \
  --jobs 32
```

Dry-run without cloning/building:

```bash
./vmctl.sh build-qemu --dry-run --ref v9.2.2
```

QEMU source and build output are ignored by git.

## 4. Build Kernel Initrd If Needed

If the host already has a compatible initrd, pass it directly to `boot`. If you
need to generate one from a kernel tree:

```bash
./vmctl.sh build-initrd \
  --kernel-dir /Serverless/Migration-friendly/linux \
  --artifact-dir kernel-artifacts
```

This runs:

```text
make -C <kernel-dir> bzImage modules
make -C <kernel-dir> modules_install INSTALL_MOD_PATH=<artifact-dir>/mod-stage
depmod -b <artifact-dir>/mod-stage <kernelrelease>
dracut --kver <kernelrelease> --kmoddir <staged-modules> <initrd>
```

Useful variants:

```bash
./vmctl.sh build-initrd --kernel-dir /path/linux --jobs 64
./vmctl.sh build-initrd --kernel-dir /path/linux --no-strip-modules
./vmctl.sh build-initrd --kernel-dir /path/linux --hostonly
./vmctl.sh build-initrd --dry-run --kernel-dir /path/linux
```

## 5. Boot the Corrected CXL VM

Minimal corrected setup:

```bash
./vmctl.sh boot \
  --kernel /Serverless/Migration-friendly/linux/arch/x86/boot/bzImage \
  --initrd /boot/initrd.img-6.18.0modified \
  --rootfs images/ubuntu.overlay.qcow2 \
  --rootfs-format qcow2
```

Fully explicit version:

```bash
./vmctl.sh boot \
  --qemu-bin /usr/bin/qemu-system-x86_64 \
  --kernel /Serverless/Migration-friendly/linux/arch/x86/boot/bzImage \
  --initrd /boot/initrd.img-6.18.0modified \
  --rootfs images/ubuntu.overlay.qcow2 \
  --rootfs-format qcow2 \
  --root-device /dev/vda2 \
  --ssh-port 10023 \
  --name reuse-time-kernel-cxl \
  --host-cpus 0-31 \
  --guest-cpus 32 \
  --guest-node0-cpus 0-31 \
  --fast-host-node 0 \
  --slow-host-node 2 \
  --fast-mem 64G \
  --slow-mem 64G \
  --accel kvm
```

Print the exact QEMU command without starting it:

```bash
./vmctl.sh boot --dry-run --kernel /path/bzImage --rootfs /path/rootfs.qcow2
```

Important boot options:

| Option | Meaning | Default |
| --- | --- | --- |
| `--kernel PATH` | Kernel `bzImage` to boot | required |
| `--initrd PATH` | Optional initrd | none |
| `--rootfs PATH` | Rootfs image | required |
| `--rootfs-format qcow2|raw` | QEMU drive format | `qcow2` |
| `--root-device PATH` | Kernel root device | `/dev/vda2` |
| `--ssh-port PORT` | Host SSH forward port | `10023` |
| `--name NAME` | VM name and pid/log prefix | `migration-friendly-cxl` |
| `--host-cpus LIST` | Host CPU affinity via `taskset` | `0-31` |
| `--guest-cpus N` | Guest vCPU count | `32` |
| `--guest-node0-cpus LIST` | Guest node0 CPU list | `0-31` |
| `--fast-host-node N` | Host NUMA node for guest node0 | `0` |
| `--slow-host-node N` | Host NUMA node for guest node1 | `2` |
| `--fast-mem SIZE` | Guest node0 memory | `64G` |
| `--slow-mem SIZE` | Guest node1 memory | `64G` |
| `--no-prealloc` | Disable QEMU memory preallocation | off |
| `--foreground` | Run QEMU in foreground | off |
| `--qemu-extra ARG` | Append one raw QEMU arg, repeatable | none |

Generated files:

```text
run/<name>.pid
run/<name>.serial.log
run/<name>.qmp.sock
```

## 6. Wait for SSH and Log In

Wait:

```bash
./vmctl.sh wait-ssh \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023
```

Open shell:

```bash
./vmctl.sh ssh \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023
```

Run a single command:

```bash
./vmctl.sh ssh \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  -- 'numactl -H'
```

If no `--ssh-key` is provided and `images/id_rsa` does not exist, SSH falls
back to the default SSH authentication behavior.

## 7. Verify Placement

```bash
./vmctl.sh verify-placement \
  --name reuse-time-kernel-cxl \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023
```

This prints:

- host QEMU PID
- host CPU affinity from `taskset -pc`
- host per-node QEMU memory usage from `numastat -p`, if installed
- guest `numactl -H`
- guest node meminfo

What to check:

- QEMU CPU affinity should be only host node0 CPUs, for example `0-31`.
- QEMU memory should show roughly `64G` on host node0 and `64G` on host node2.
- Guest node0 should have CPUs; guest node1 should be memory-only.

## 8. Prepare Common Guest Knobs

```bash
./vmctl.sh prepare-guest \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  --global-numa-balancing 2 \
  --demotion-enabled true \
  --demotion-target '0 1' \
  --scan-size-mb 256 \
  --reuse-time-enable 0
```

This can:

- mount debugfs at `/sys/kernel/debug`
- enable cgroup v2 memory controller under `/sys/fs/cgroup`
- set `/proc/sys/kernel/numa_balancing`
- set `/sys/kernel/mm/numa/demotion_enabled`
- set `/sys/kernel/mm/numa/demotion_target`
- set debugfs NUMA scan size if that knob exists
- set debugfs reuse-time enable if that knob exists

All guest knob writes are conditional on file existence/writability. Missing
experimental knobs do not fail the whole command unless SSH itself fails.

## 9. Copy Files

Upload files:

```bash
./vmctl.sh copy-to \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  -- ./local-script.sh /root/
```

Download files:

```bash
./vmctl.sh copy-from \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  -- /tmp/guest-output ./artifacts/
```

Both commands use recursive `scp`.

## 10. Run Long Experiments in Guest tmux

```bash
./vmctl.sh tmux-run \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  --session perf_cap_sweep \
  --log /tmp/perf_cap_sweep_tmux.log \
  -- bash /root/run_perf_cap_sweep_inner.sh
```

Behavior:

- kills the existing session with the same name by default
- starts a detached tmux session
- appends stdout/stderr to `--log` if provided

Keep existing session:

```bash
./vmctl.sh tmux-run \
  --no-kill-existing \
  --session another_exp \
  -- bash /root/run.sh
```

Dry-run the remote tmux command:

```bash
./vmctl.sh tmux-run --dry-run --session exp -- bash /root/run.sh
```

Check from host:

```bash
./vmctl.sh ssh --ssh-port 10023 -- 'tmux ls'
./vmctl.sh ssh --ssh-port 10023 -- 'tail -f /tmp/perf_cap_sweep_tmux.log'
```

## 11. Status and Stop

Status:

```bash
./vmctl.sh status --name reuse-time-kernel-cxl
```

Stop:

```bash
./vmctl.sh stop --name reuse-time-kernel-cxl
```

`stop` uses the pidfile under `run/`. It sends `TERM`, waits up to 30 seconds,
then sends `KILL` if the process is still alive.

## 12. Full Current Experiment Flow

```bash
cd /Serverless/VM

./vmctl.sh check --fast-host-node 0 --slow-host-node 2

./vmctl.sh create-image \
  --overlay-from /path/to/base-ubuntu.qcow2 \
  --output images/ubuntu.overlay.qcow2

./vmctl.sh boot \
  --name reuse-time-kernel-cxl \
  --kernel /Serverless/Migration-friendly/linux/arch/x86/boot/bzImage \
  --initrd /boot/initrd.img-6.18.0modified \
  --rootfs images/ubuntu.overlay.qcow2 \
  --rootfs-format qcow2 \
  --ssh-port 10023 \
  --host-cpus 0-31 \
  --guest-cpus 32 \
  --guest-node0-cpus 0-31 \
  --fast-host-node 0 \
  --slow-host-node 2 \
  --fast-mem 64G \
  --slow-mem 64G

./vmctl.sh wait-ssh --ssh-key /tmp/reuse_vm_g28/id_rsa --ssh-port 10023

./vmctl.sh verify-placement \
  --name reuse-time-kernel-cxl \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023

./vmctl.sh prepare-guest \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  --global-numa-balancing 2 \
  --demotion-enabled true \
  --demotion-target '0 1' \
  --scan-size-mb 256 \
  --reuse-time-enable 0

./vmctl.sh copy-to \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  -- /path/to/run_experiment.sh /root/

./vmctl.sh tmux-run \
  --ssh-key /tmp/reuse_vm_g28/id_rsa \
  --ssh-port 10023 \
  --session experiment \
  --log /tmp/experiment.log \
  -- bash /root/run_experiment.sh
```

## Troubleshooting

`host SSH forward port already in use`

Use another port:

```bash
./vmctl.sh boot --ssh-port 10024 ...
```

`fast host node missing` or `slow host node missing`

Run:

```bash
numactl -H
ls /sys/devices/system/node/
```

Then choose valid nodes with `--fast-host-node` and `--slow-host-node`.

QEMU starts but guest SSH never comes up:

- check `run/<name>.serial.log`
- verify `--root-device`
- verify the rootfs has SSH enabled and accepts the provided key/password
- verify the kernel/initrd has virtio disk and virtio/e1000 NIC drivers

Placement looks wrong:

- verify `boot` output includes `host-nodes=0` and `host-nodes=2`
- verify `prealloc=on` is present unless intentionally disabled
- rerun `verify-placement`
- check `numastat -p <qemu-pid>` on the host

Guest node1 is not CXL:

- host node2 must already be online as system RAM before booting QEMU
- run `./vmctl.sh check --slow-host-node 2`
- if node2 has zero memory, online/reconfigure CXL memory on the host first

