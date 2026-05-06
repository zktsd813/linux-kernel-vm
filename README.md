# Migration-Friendly VM Harness

This directory is a small standalone VM setup repo for the NUMA/CXL experiments.
It keeps only portable host-side VM orchestration. Large rootfs images, overlays,
ISOs, and generated logs are intentionally ignored.

## Selected Inputs

The script distills the reusable parts from the existing experiment tree:

- `scripts/kernel/launch_kernel_qemu.sh`: QEMU boot flow, kernel/rootfs/initrd options, SSH port forwarding.
- `reuse_time/docs/cxl-hotset-perf-analysis-20260506.md`: corrected CXL-backed placement, where guest node0 is host node0 DRAM and guest node1 is host node2 CXL.
- `reuse_time/vm/prepare_vm.sh`: guest-side debugfs/module preparation assumptions.

Workload-specific runners are not copied here. Use this repo to boot a correctly
placed VM, then run experiment-specific scripts from their own repos.

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
