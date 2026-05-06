#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="${VM_IMAGE_DIR:-${SCRIPT_DIR}/images}"
RUN_DIR="${VM_RUN_DIR:-${SCRIPT_DIR}/run}"

DEFAULT_QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
DEFAULT_SSH_KEY="${SSH_KEY:-${IMAGE_DIR}/id_rsa}"
DEFAULT_SSH_USER="${SSH_USER:-root}"
DEFAULT_SSH_PORT="${SSH_PORT:-10023}"
DEFAULT_VM_NAME="${VM_NAME:-migration-friendly-cxl}"
DEFAULT_ROOT_DEVICE="${ROOT_DEVICE:-/dev/vda2}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[vmctl] %s\n' "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
Usage:
  vmctl.sh <command> [options]

Commands:
  check             Check host dependencies and NUMA topology.
  create-image      Create/download a rootfs artifact under images/.
  build-qemu        Clone/build a local QEMU binary without committing it.
  build-initrd      Build kernel/modules and create a dracut initramfs.
  boot              Boot a QEMU VM with DRAM/CXL-style NUMA placement.
  wait-ssh          Wait until the guest SSH endpoint is reachable.
  ssh               Open SSH or run a command in the guest.
  copy-to           Copy local files into the guest.
  copy-from         Copy guest files back to the host.
  prepare-guest     Mount debugfs and set common NUMA/demotion knobs.
  tmux-run          Start a long guest command in a tmux session.
  status            Print pidfile, QEMU process, and recent logs.
  stop              Stop the daemonized VM.
  verify-placement  Print host QEMU affinity/numastat and guest NUMA topology.

Boot defaults:
  fast host node: 0
  slow host node: 2
  host CPUs:      0-31
  guest CPUs:     32
  guest node0:    CPUs 0-31, 64G
  guest node1:    memory-only, 64G

Examples:
  ./vmctl.sh check
  ./vmctl.sh create-image --overlay-from /vm/base.qcow2 --output images/ubuntu.overlay.qcow2
  ./vmctl.sh build-qemu --ref v9.2.2
  ./vmctl.sh boot --kernel /path/bzImage --initrd /boot/initrd.img-6.18.0modified --rootfs images/ubuntu.overlay.qcow2
  ./vmctl.sh prepare-guest --ssh-key /tmp/reuse_vm_g28/id_rsa --ssh-port 10023 --scan-size-mb 256
  ./vmctl.sh tmux-run --ssh-key /tmp/reuse_vm_g28/id_rsa --ssh-port 10023 --session exp -- 'bash /root/run.sh'
  ./vmctl.sh wait-ssh --ssh-key /tmp/reuse_vm_g28/id_rsa --ssh-port 10023
  ./vmctl.sh verify-placement --ssh-key /tmp/reuse_vm_g28/id_rsa --ssh-port 10023
EOF
}

require_value() {
  local opt="$1"
  local val="${2:-}"
  [[ -n "${val}" ]] || die "${opt} requires a value"
}

abs_path() {
  local path="$1"
  if [[ "${path}" = /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s\n' "$(pwd)/${path}"
  fi
}

size_to_mib() {
  local raw="$1"
  local num unit

  if [[ "${raw}" =~ ^([0-9]+)([KkMmGgTt]?)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    die "invalid size '${raw}', use forms like 64G, 131072M, 1T"
  fi

  case "${unit}" in
    K|k) echo $(( (num + 1023) / 1024 )) ;;
    ""|M|m) echo "${num}" ;;
    G|g) echo $(( num * 1024 )) ;;
    T|t) echo $(( num * 1024 * 1024 )) ;;
    *) die "invalid size unit '${unit}'" ;;
  esac
}

mib_to_qemu_size() {
  local mib="$1"
  if (( mib % (1024 * 1024) == 0 )); then
    echo "$((mib / 1024 / 1024))T"
  elif (( mib % 1024 == 0 )); then
    echo "$((mib / 1024))G"
  else
    echo "${mib}M"
  fi
}

ssh_opts() {
  local key="$1"
  shift
  local opts=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=5
  )
  if [[ -n "${key}" ]]; then
    opts+=( -i "${key}" )
  fi
  printf '%s\0' "${opts[@]}" "$@"
}

append_ssh_key_opt() {
  local key="$1"
  local explicit="${2:-0}"
  local -n out_ref="$3"

  if [[ -n "${key}" && -f "${key}" ]]; then
    out_ref+=( -i "${key}" )
  elif [[ -n "${key}" && "${explicit}" == "1" ]]; then
    die "SSH key not found: ${key}"
  fi
}

run_cmd() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

run_or_print() {
  local dry_run="$1"
  shift
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  if [[ "${dry_run}" != "1" ]]; then
    "$@"
  fi
}

q() {
  printf '%q' "$1"
}

cmd_check() {
  local kernel="" rootfs="" qemu_bin="${DEFAULT_QEMU_BIN}" fast_node="0" slow_node="2"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kernel) require_value "$1" "${2:-}"; kernel="$2"; shift 2 ;;
      --rootfs) require_value "$1" "${2:-}"; rootfs="$2"; shift 2 ;;
      --qemu-bin) require_value "$1" "${2:-}"; qemu_bin="$2"; shift 2 ;;
      --fast-host-node) require_value "$1" "${2:-}"; fast_node="$2"; shift 2 ;;
      --slow-host-node) require_value "$1" "${2:-}"; slow_node="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown check option: $1" ;;
    esac
  done

  log "dependency check"
  for cmd in "${qemu_bin}" qemu-img ssh scp; do
    if have_cmd "${cmd}"; then
      printf '  %-18s OK (%s)\n' "${cmd}" "$(command -v "${cmd}")"
    else
      printf '  %-18s MISSING\n' "${cmd}"
    fi
  done

  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    printf '  %-18s OK\n' "/dev/kvm"
  else
    printf '  %-18s unavailable, boot will use TCG unless permissions change\n' "/dev/kvm"
  fi

  log "host NUMA topology"
  if have_cmd numactl; then
    numactl -H
  else
    for node in /sys/devices/system/node/node[0-9]*; do
      [[ -d "${node}" ]] || continue
      printf '%s ' "$(basename "${node}")"
      awk '/MemTotal/ {printf "MemTotal=%s %s\n", $4, $5}' "${node}/meminfo" 2>/dev/null || true
    done
  fi

  for node in "${fast_node}" "${slow_node}"; do
    if [[ -d "/sys/devices/system/node/node${node}" ]]; then
      printf '  host node %-5s present\n' "${node}"
    else
      printf '  host node %-5s MISSING\n' "${node}"
    fi
  done

  [[ -z "${kernel}" ]] || [[ -f "${kernel}" ]] || die "kernel not found: ${kernel}"
  [[ -z "${rootfs}" ]] || [[ -f "${rootfs}" ]] || die "rootfs not found: ${rootfs}"
}

ubuntu_cloud_url() {
  local name="$1"
  case "${name}" in
    ubuntu-22.04|jammy)
      echo "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" ;;
    ubuntu-24.04|noble)
      echo "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
    *)
      die "unknown cloud image '${name}', supported: ubuntu-22.04, ubuntu-24.04" ;;
  esac
}

cmd_create_image() {
  local output="" size="80G" overlay_from="" download="" force="0" backing_format="qcow2"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) require_value "$1" "${2:-}"; output="$2"; shift 2 ;;
      --size) require_value "$1" "${2:-}"; size="$2"; shift 2 ;;
      --overlay-from) require_value "$1" "${2:-}"; overlay_from="$2"; shift 2 ;;
      --backing-format) require_value "$1" "${2:-}"; backing_format="$2"; shift 2 ;;
      --download) require_value "$1" "${2:-}"; download="$2"; shift 2 ;;
      --force) force="1"; shift ;;
      -h|--help)
        cat <<'EOF'
Usage:
  vmctl.sh create-image --output images/rootfs.qcow2 --size 80G
  vmctl.sh create-image --overlay-from /path/base.qcow2 --output images/overlay.qcow2
  vmctl.sh create-image --download ubuntu-24.04 --output images/ubuntu-24.04.img
EOF
        exit 0 ;;
      *) die "unknown create-image option: $1" ;;
    esac
  done

  [[ -n "${output}" ]] || output="${IMAGE_DIR}/rootfs.qcow2"
  mkdir -p "$(dirname "${output}")"

  if [[ -e "${output}" && "${force}" != "1" ]]; then
    die "output exists: ${output} (use --force to overwrite)"
  fi

  if [[ -n "${download}" ]]; then
    have_cmd curl || die "curl is required for --download"
    local url
    url="$(ubuntu_cloud_url "${download}")"
    log "downloading ${download}: ${url}"
    curl -L --fail --output "${output}" "${url}"
    return 0
  fi

  have_cmd qemu-img || die "qemu-img is required"
  if [[ -n "${overlay_from}" ]]; then
    overlay_from="$(abs_path "${overlay_from}")"
    [[ -f "${overlay_from}" ]] || die "backing image not found: ${overlay_from}"
    log "creating qcow2 overlay ${output} from ${overlay_from}"
    qemu-img create -f qcow2 -F "${backing_format}" -b "${overlay_from}" "${output}"
  else
    log "creating empty qcow2 image ${output} size=${size}"
    qemu-img create -f qcow2 "${output}" "${size}"
  fi
}

cmd_build_qemu() {
  local repo="https://gitlab.com/qemu-project/qemu.git"
  local ref="v9.2.2"
  local src="${SCRIPT_DIR}/qemu-src"
  local prefix="${SCRIPT_DIR}/qemu-build"
  local jobs
  local target_list="x86_64-softmmu"
  local dry_run="0"
  local configure_only="0"
  local -a configure_extra=()

  jobs="$(nproc 2>/dev/null || echo 8)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) require_value "$1" "${2:-}"; repo="$2"; shift 2 ;;
      --ref) require_value "$1" "${2:-}"; ref="$2"; shift 2 ;;
      --src) require_value "$1" "${2:-}"; src="$2"; shift 2 ;;
      --prefix) require_value "$1" "${2:-}"; prefix="$2"; shift 2 ;;
      --jobs|-j) require_value "$1" "${2:-}"; jobs="$2"; shift 2 ;;
      --target-list) require_value "$1" "${2:-}"; target_list="$2"; shift 2 ;;
      --configure-extra) require_value "$1" "${2:-}"; configure_extra+=( "$2" ); shift 2 ;;
      --configure-only) configure_only="1"; shift ;;
      --dry-run) dry_run="1"; shift ;;
      -h|--help)
        cat <<'EOF'
Usage:
  vmctl.sh build-qemu [options]

Options:
  --repo URL             QEMU git repo (default: upstream GitLab)
  --ref REF              QEMU tag/branch/commit (default: v9.2.2)
  --src DIR              Source directory (default: ./qemu-src)
  --prefix DIR           Install prefix (default: ./qemu-build)
  --target-list LIST     Configure target list (default: x86_64-softmmu)
  --configure-extra ARG  Extra configure argument, repeatable
  --configure-only       Stop after configure
  --dry-run              Print commands only
EOF
        exit 0 ;;
      *) die "unknown build-qemu option: $1" ;;
    esac
  done

  for cmd in git python3; do
    have_cmd "${cmd}" || die "${cmd} is required"
  done

  src="$(abs_path "${src}")"
  prefix="$(abs_path "${prefix}")"

  if [[ ! -d "${src}/.git" ]]; then
    run_or_print "${dry_run}" git clone "${repo}" "${src}"
  fi

  run_or_print "${dry_run}" git -C "${src}" fetch --tags origin
  run_or_print "${dry_run}" git -C "${src}" checkout "${ref}"
  run_or_print "${dry_run}" git -C "${src}" submodule update --init --recursive
  run_or_print "${dry_run}" mkdir -p "${src}/build"

  local -a configure_cmd=(
    "${src}/configure"
    "--target-list=${target_list}"
    "--prefix=${prefix}"
    --disable-docs
  )
  configure_cmd+=( "${configure_extra[@]}" )
  printf '+ cd %q && ' "${src}/build"
  printf '%q ' "${configure_cmd[@]}"
  printf '\n'
  if [[ "${dry_run}" != "1" ]]; then
    (cd "${src}/build" && "${configure_cmd[@]}")
  fi

  if [[ "${configure_only}" == "1" ]]; then
    return 0
  fi

  if have_cmd ninja; then
    run_or_print "${dry_run}" ninja -C "${src}/build" -j"${jobs}"
    run_or_print "${dry_run}" ninja -C "${src}/build" install
  else
    have_cmd make || die "ninja or make is required"
    run_or_print "${dry_run}" make -C "${src}/build" -j"${jobs}"
    run_or_print "${dry_run}" make -C "${src}/build" install
  fi

  log "QEMU binary: ${prefix}/bin/qemu-system-x86_64"
}

cmd_build_initrd() {
  local kernel_dir="" artifact_dir="${SCRIPT_DIR}/kernel-artifacts"
  local jobs dracut_bin="dracut" hostonly="0" strip_modules="1"
  local initrd_name="" dry_run="0"

  jobs="$(nproc 2>/dev/null || echo 8)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kernel-dir) require_value "$1" "${2:-}"; kernel_dir="$2"; shift 2 ;;
      --artifact-dir) require_value "$1" "${2:-}"; artifact_dir="$2"; shift 2 ;;
      --jobs|-j) require_value "$1" "${2:-}"; jobs="$2"; shift 2 ;;
      --dracut-bin) require_value "$1" "${2:-}"; dracut_bin="$2"; shift 2 ;;
      --hostonly) hostonly="1"; shift ;;
      --strip-modules) strip_modules="1"; shift ;;
      --no-strip-modules) strip_modules="0"; shift ;;
      --initrd-name) require_value "$1" "${2:-}"; initrd_name="$2"; shift 2 ;;
      --dry-run) dry_run="1"; shift ;;
      -h|--help)
        cat <<'EOF'
Usage:
  vmctl.sh build-initrd --kernel-dir /path/linux [options]

Builds bzImage/modules, installs modules into a temporary staging directory,
and creates a dracut initramfs under ./kernel-artifacts by default.
EOF
        exit 0 ;;
      *) die "unknown build-initrd option: $1" ;;
    esac
  done

  [[ -n "${kernel_dir}" ]] || die "--kernel-dir is required"
  if [[ "${dry_run}" != "1" ]]; then
    [[ -d "${kernel_dir}" ]] || die "kernel dir not found: ${kernel_dir}"
    have_cmd "${dracut_bin}" || die "dracut binary not found: ${dracut_bin}"
  fi

  local kernel_dir_abs artifact_dir_abs mod_stage krel initrd_path
  kernel_dir_abs="$(abs_path "${kernel_dir}")"
  artifact_dir_abs="$(abs_path "${artifact_dir}")"
  mod_stage="${artifact_dir_abs}/mod-stage"

  run_or_print "${dry_run}" mkdir -p "${artifact_dir_abs}"
  run_or_print "${dry_run}" rm -rf "${mod_stage}"
  run_or_print "${dry_run}" mkdir -p "${mod_stage}"
  run_or_print "${dry_run}" make -C "${kernel_dir_abs}" -j"${jobs}" bzImage modules

  if [[ "${dry_run}" == "1" ]]; then
    krel="<kernelrelease>"
  else
    krel="$(make -s -C "${kernel_dir_abs}" kernelrelease)"
  fi

  if [[ -z "${initrd_name}" ]]; then
    initrd_name="initramfs-${krel}.img"
  fi
  initrd_path="${artifact_dir_abs}/${initrd_name}"

  if [[ "${strip_modules}" == "1" ]]; then
    run_or_print "${dry_run}" make -C "${kernel_dir_abs}" modules_install INSTALL_MOD_PATH="${mod_stage}" INSTALL_MOD_STRIP=1
  else
    run_or_print "${dry_run}" make -C "${kernel_dir_abs}" modules_install INSTALL_MOD_PATH="${mod_stage}"
  fi
  run_or_print "${dry_run}" depmod -b "${mod_stage}" "${krel}"

  local -a dracut_args=(
    --force
    --kver "${krel}"
    --kmoddir "${mod_stage}/lib/modules/${krel}"
    --add-drivers "virtio virtio_pci virtio_ring virtio_net e1000 e1000e"
  )
  if [[ "${hostonly}" == "0" ]]; then
    dracut_args+=( --no-hostonly )
  fi
  run_or_print "${dry_run}" "${dracut_bin}" "${dracut_args[@]}" "${initrd_path}"
  log "initrd: ${initrd_path}"
}

parse_boot_args() {
  QEMU_BIN="${DEFAULT_QEMU_BIN}"
  KERNEL_IMAGE=""
  INITRD_IMAGE=""
  ROOTFS_IMAGE=""
  ROOTFS_FORMAT="qcow2"
  ROOT_DEVICE="${DEFAULT_ROOT_DEVICE}"
  DRIVE_IF="virtio"
  NET_DEVICE="virtio-net-pci"
  SSH_PORT="${DEFAULT_SSH_PORT}"
  VM_NAME="${DEFAULT_VM_NAME}"
  SSH_KEY="${DEFAULT_SSH_KEY}"
  ACCEL="auto"
  HOST_CPUS="0-31"
  GUEST_CPUS="32"
  GUEST_NODE0_CPUS="0-31"
  FAST_HOST_NODE="0"
  SLOW_HOST_NODE="2"
  FAST_MEM="64G"
  SLOW_MEM="64G"
  TOTAL_MEM=""
  PREALLOC="1"
  DAEMON="1"
  DRY_RUN="0"
  EXTRA_CMDLINE=""
  CMDLINE=""
  EXTRA_QEMU_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --qemu-bin) require_value "$1" "${2:-}"; QEMU_BIN="$2"; shift 2 ;;
      --kernel) require_value "$1" "${2:-}"; KERNEL_IMAGE="$2"; shift 2 ;;
      --initrd) require_value "$1" "${2:-}"; INITRD_IMAGE="$2"; shift 2 ;;
      --rootfs) require_value "$1" "${2:-}"; ROOTFS_IMAGE="$2"; shift 2 ;;
      --rootfs-format) require_value "$1" "${2:-}"; ROOTFS_FORMAT="$2"; shift 2 ;;
      --root-device) require_value "$1" "${2:-}"; ROOT_DEVICE="$2"; shift 2 ;;
      --drive-if) require_value "$1" "${2:-}"; DRIVE_IF="$2"; shift 2 ;;
      --net-device) require_value "$1" "${2:-}"; NET_DEVICE="$2"; shift 2 ;;
      --ssh-port) require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
      --ssh-key) require_value "$1" "${2:-}"; SSH_KEY="$2"; shift 2 ;;
      --name) require_value "$1" "${2:-}"; VM_NAME="$2"; shift 2 ;;
      --accel) require_value "$1" "${2:-}"; ACCEL="$2"; shift 2 ;;
      --host-cpus) require_value "$1" "${2:-}"; HOST_CPUS="$2"; shift 2 ;;
      --guest-cpus) require_value "$1" "${2:-}"; GUEST_CPUS="$2"; shift 2 ;;
      --guest-node0-cpus) require_value "$1" "${2:-}"; GUEST_NODE0_CPUS="$2"; shift 2 ;;
      --fast-host-node) require_value "$1" "${2:-}"; FAST_HOST_NODE="$2"; shift 2 ;;
      --slow-host-node) require_value "$1" "${2:-}"; SLOW_HOST_NODE="$2"; shift 2 ;;
      --fast-mem) require_value "$1" "${2:-}"; FAST_MEM="$2"; shift 2 ;;
      --slow-mem) require_value "$1" "${2:-}"; SLOW_MEM="$2"; shift 2 ;;
      --memory) require_value "$1" "${2:-}"; TOTAL_MEM="$2"; shift 2 ;;
      --cmdline) require_value "$1" "${2:-}"; CMDLINE="$2"; shift 2 ;;
      --cmdline-extra) require_value "$1" "${2:-}"; EXTRA_CMDLINE="${EXTRA_CMDLINE} $2"; shift 2 ;;
      --qemu-extra) require_value "$1" "${2:-}"; EXTRA_QEMU_ARGS+=( "$2" ); shift 2 ;;
      --no-prealloc) PREALLOC="0"; shift ;;
      --foreground) DAEMON="0"; shift ;;
      --dry-run) DRY_RUN="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown boot option: $1" ;;
    esac
  done
}

select_accel() {
  case "${ACCEL}" in
    auto)
      if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        ACCEL="kvm"
      else
        ACCEL="tcg"
      fi ;;
    kvm|tcg) ;;
    *) die "--accel must be auto, kvm, or tcg" ;;
  esac
}

port_in_use() {
  local port="$1"
  if have_cmd ss; then
    ss -ltn "( sport = :${port} )" 2>/dev/null | tail -n +2 | grep -q .
  else
    return 1
  fi
}

build_qemu_cmd() {
  local fast_mib slow_mib total_mib cpu_model prealloc_arg serial_log qmp_sock pidfile

  [[ -n "${KERNEL_IMAGE}" ]] || die "--kernel is required"
  [[ -n "${ROOTFS_IMAGE}" ]] || die "--rootfs is required"
  if [[ "${DRY_RUN}" != "1" ]]; then
    have_cmd "${QEMU_BIN}" || die "qemu binary not found: ${QEMU_BIN}"
    [[ -f "${KERNEL_IMAGE}" ]] || die "kernel not found: ${KERNEL_IMAGE}"
    [[ -f "${ROOTFS_IMAGE}" ]] || die "rootfs not found: ${ROOTFS_IMAGE}"
    [[ -z "${INITRD_IMAGE}" || -f "${INITRD_IMAGE}" ]] || die "initrd not found: ${INITRD_IMAGE}"
    [[ -d "/sys/devices/system/node/node${FAST_HOST_NODE}" ]] || die "fast host node missing: ${FAST_HOST_NODE}"
    [[ -d "/sys/devices/system/node/node${SLOW_HOST_NODE}" ]] || die "slow host node missing: ${SLOW_HOST_NODE}"
  fi

  [[ "${ROOTFS_FORMAT}" == "qcow2" || "${ROOTFS_FORMAT}" == "raw" ]] || die "--rootfs-format must be qcow2 or raw"
  [[ "${DRIVE_IF}" == "virtio" || "${DRIVE_IF}" == "ide" || "${DRIVE_IF}" == "scsi" ]] || die "--drive-if must be virtio, ide, or scsi"
  [[ "${NET_DEVICE}" == "virtio-net-pci" || "${NET_DEVICE}" == "e1000" || "${NET_DEVICE}" == "rtl8139" ]] || die "--net-device must be virtio-net-pci, e1000, or rtl8139"
  [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "--ssh-port must be a number"

  select_accel
  if [[ "${DRY_RUN}" != "1" ]] && port_in_use "${SSH_PORT}"; then
    die "host SSH forward port already in use: ${SSH_PORT}"
  fi

  mkdir -p "${RUN_DIR}"
  fast_mib="$(size_to_mib "${FAST_MEM}")"
  slow_mib="$(size_to_mib "${SLOW_MEM}")"
  if [[ -n "${TOTAL_MEM}" ]]; then
    total_mib="$(size_to_mib "${TOTAL_MEM}")"
  else
    total_mib="$((fast_mib + slow_mib))"
  fi

  if [[ -z "${CMDLINE}" ]]; then
    CMDLINE="console=ttyS0 root=${ROOT_DEVICE} rw loglevel=7 nokaslr${EXTRA_CMDLINE}"
  fi

  cpu_model="host"
  [[ "${ACCEL}" == "kvm" ]] || cpu_model="max"
  prealloc_arg="prealloc=on"
  [[ "${PREALLOC}" == "1" ]] || prealloc_arg="prealloc=off"

  PIDFILE="${RUN_DIR}/${VM_NAME}.pid"
  SERIAL_LOG="${RUN_DIR}/${VM_NAME}.serial.log"
  QMP_SOCK="${RUN_DIR}/${VM_NAME}.qmp.sock"
  rm -f "${QMP_SOCK}"

  QEMU_CMD=(
    "${QEMU_BIN}"
    -pidfile "${PIDFILE}"
    -name "${VM_NAME}"
    -machine q35
    -cpu "${cpu_model}"
    -accel "${ACCEL}"
    -smp "${GUEST_CPUS},maxcpus=${GUEST_CPUS}"
    -m "$(mib_to_qemu_size "${total_mib}")"
    -kernel "${KERNEL_IMAGE}"
    -append "${CMDLINE}"
    -drive "file=${ROOTFS_IMAGE},if=${DRIVE_IF},format=${ROOTFS_FORMAT}"
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22"
    -device "${NET_DEVICE},netdev=net0"
    -object "memory-backend-ram,id=ram0,size=${FAST_MEM},host-nodes=${FAST_HOST_NODE},policy=bind,${prealloc_arg}"
    -object "memory-backend-ram,id=ram1,size=${SLOW_MEM},host-nodes=${SLOW_HOST_NODE},policy=bind,${prealloc_arg}"
    -numa "node,nodeid=0,cpus=${GUEST_NODE0_CPUS},memdev=ram0"
    -numa "node,nodeid=1,memdev=ram1"
    -display none
    -serial "file:${SERIAL_LOG}"
    -monitor none
    -qmp "unix:${QMP_SOCK},server=on,wait=off"
  )

  if [[ -n "${INITRD_IMAGE}" ]]; then
    QEMU_CMD+=( -initrd "${INITRD_IMAGE}" )
  fi

  if [[ "${DAEMON}" == "1" ]]; then
    QEMU_CMD+=( -daemonize )
  else
    QEMU_CMD+=( -nographic )
  fi

  if [[ "${#EXTRA_QEMU_ARGS[@]}" -gt 0 ]]; then
    QEMU_CMD+=( "${EXTRA_QEMU_ARGS[@]}" )
  fi

  HOST_LAUNCH_CMD=( "${QEMU_CMD[@]}" )
  if [[ -n "${HOST_CPUS}" ]]; then
    HOST_LAUNCH_CMD=( taskset -c "${HOST_CPUS}" "${HOST_LAUNCH_CMD[@]}" )
  fi
}

print_boot_plan() {
  cat <<EOF
QEMU launch plan
  qemu       : ${QEMU_BIN}
  kernel     : ${KERNEL_IMAGE}
  initrd     : ${INITRD_IMAGE:-<none>}
  rootfs     : ${ROOTFS_IMAGE}
  rootfs fmt : ${ROOTFS_FORMAT}
  vm name    : ${VM_NAME}
  accel      : ${ACCEL}
  host CPUs  : ${HOST_CPUS:-<not pinned>}
  guest CPUs : ${GUEST_CPUS}
  node0      : guest cpus=${GUEST_NODE0_CPUS}, mem=${FAST_MEM}, host node=${FAST_HOST_NODE}
  node1      : memory-only, mem=${SLOW_MEM}, host node=${SLOW_HOST_NODE}
  ssh        : host ${SSH_PORT} -> guest 22
  pidfile    : ${PIDFILE}
  serial log : ${SERIAL_LOG}
  qmp socket : ${QMP_SOCK}
  cmdline    : ${CMDLINE}

Command:
EOF
  printf '  '
  printf '%q ' "${HOST_LAUNCH_CMD[@]}"
  printf '\n'
}

cmd_boot() {
  parse_boot_args "$@"
  build_qemu_cmd
  print_boot_plan
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "dry run only"
    return 0
  fi
  "${HOST_LAUNCH_CMD[@]}"
  log "started ${VM_NAME}; pidfile=${PIDFILE}"
}

parse_ssh_args() {
  SSH_USER_ARG="${DEFAULT_SSH_USER}"
  SSH_PORT_ARG="${DEFAULT_SSH_PORT}"
  SSH_KEY_ARG="${DEFAULT_SSH_KEY}"
  SSH_KEY_EXPLICIT="0"
  SSH_HOST_ARG="127.0.0.1"
  SSH_VM_NAME="${DEFAULT_VM_NAME}"
  SSH_COMMAND=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-user|--user) require_value "$1" "${2:-}"; SSH_USER_ARG="$2"; shift 2 ;;
      --ssh-port|--port) require_value "$1" "${2:-}"; SSH_PORT_ARG="$2"; shift 2 ;;
      --ssh-key|--key) require_value "$1" "${2:-}"; SSH_KEY_ARG="$2"; SSH_KEY_EXPLICIT="1"; shift 2 ;;
      --host) require_value "$1" "${2:-}"; SSH_HOST_ARG="$2"; shift 2 ;;
      --name) require_value "$1" "${2:-}"; SSH_VM_NAME="$2"; shift 2 ;;
      --) shift; SSH_COMMAND=( "$@" ); break ;;
      -h|--help) usage; exit 0 ;;
      *) SSH_COMMAND+=( "$1" ); shift ;;
    esac
  done
}

cmd_wait_ssh() {
  local timeout="300" deadline
  parse_ssh_args "$@"
  timeout="${SSH_TIMEOUT:-300}"
  deadline=$((SECONDS + timeout))

  log "waiting for SSH ${SSH_USER_ARG}@${SSH_HOST_ARG}:${SSH_PORT_ARG}"
  local -a cmd_base=( ssh
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
    -p "${SSH_PORT_ARG}"
  )
  append_ssh_key_opt "${SSH_KEY_ARG}" "${SSH_KEY_EXPLICIT}" cmd_base
  while (( SECONDS < deadline )); do
    if "${cmd_base[@]}" "${SSH_USER_ARG}@${SSH_HOST_ARG}" true >/dev/null 2>&1; then
      log "SSH is ready"
      return 0
    fi
    sleep 2
  done
  die "timed out waiting for SSH after ${timeout}s"
}

cmd_ssh() {
  parse_ssh_args "$@"
  local -a cmd=( ssh
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -p "${SSH_PORT_ARG}"
  )
  append_ssh_key_opt "${SSH_KEY_ARG}" "${SSH_KEY_EXPLICIT}" cmd
  cmd+=( "${SSH_USER_ARG}@${SSH_HOST_ARG}" )
  if [[ "${#SSH_COMMAND[@]}" -gt 0 ]]; then
    cmd+=( "${SSH_COMMAND[@]}" )
  fi
  "${cmd[@]}"
}

cmd_copy_to() {
  local user="${DEFAULT_SSH_USER}" port="${DEFAULT_SSH_PORT}"
  local key="${DEFAULT_SSH_KEY}" key_explicit="0" host="127.0.0.1"
  local -a paths=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-user|--user) require_value "$1" "${2:-}"; user="$2"; shift 2 ;;
      --ssh-port|--port) require_value "$1" "${2:-}"; port="$2"; shift 2 ;;
      --ssh-key|--key) require_value "$1" "${2:-}"; key="$2"; key_explicit="1"; shift 2 ;;
      --host) require_value "$1" "${2:-}"; host="$2"; shift 2 ;;
      --) shift; paths+=( "$@" ); break ;;
      -h|--help)
        echo "Usage: vmctl.sh copy-to [ssh options] -- SRC... GUEST_DST"
        exit 0 ;;
      *) paths+=( "$1" ); shift ;;
    esac
  done

  (( ${#paths[@]} >= 2 )) || die "copy-to requires SRC... and GUEST_DST"
  local dst="${paths[$((${#paths[@]} - 1))]}"
  local -a srcs=( "${paths[@]:0:$((${#paths[@]} - 1))}" )
  local -a cmd=( scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "${port}" )
  append_ssh_key_opt "${key}" "${key_explicit}" cmd
  cmd+=( "${srcs[@]}" "${user}@${host}:${dst}" )
  "${cmd[@]}"
}

cmd_copy_from() {
  local user="${DEFAULT_SSH_USER}" port="${DEFAULT_SSH_PORT}"
  local key="${DEFAULT_SSH_KEY}" key_explicit="0" host="127.0.0.1"
  local -a paths=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-user|--user) require_value "$1" "${2:-}"; user="$2"; shift 2 ;;
      --ssh-port|--port) require_value "$1" "${2:-}"; port="$2"; shift 2 ;;
      --ssh-key|--key) require_value "$1" "${2:-}"; key="$2"; key_explicit="1"; shift 2 ;;
      --host) require_value "$1" "${2:-}"; host="$2"; shift 2 ;;
      --) shift; paths+=( "$@" ); break ;;
      -h|--help)
        echo "Usage: vmctl.sh copy-from [ssh options] -- GUEST_SRC... LOCAL_DST"
        exit 0 ;;
      *) paths+=( "$1" ); shift ;;
    esac
  done

  (( ${#paths[@]} >= 2 )) || die "copy-from requires GUEST_SRC... and LOCAL_DST"
  local dst="${paths[$((${#paths[@]} - 1))]}"
  local -a srcs=()
  local i
  for ((i = 0; i < ${#paths[@]} - 1; i++)); do
    srcs+=( "${user}@${host}:${paths[$i]}" )
  done
  local -a cmd=( scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "${port}" )
  append_ssh_key_opt "${key}" "${key_explicit}" cmd
  cmd+=( "${srcs[@]}" "${dst}" )
  "${cmd[@]}"
}

cmd_prepare_guest() {
  local user="${DEFAULT_SSH_USER}" port="${DEFAULT_SSH_PORT}"
  local key="${DEFAULT_SSH_KEY}" key_explicit="0" host="127.0.0.1"
  local mount_debugfs="1" cgroup_memory="1"
  local global_numa="" demotion_enabled="" demotion_target=""
  local scan_size_mb="" reuse_time_enable=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-user|--user) require_value "$1" "${2:-}"; user="$2"; shift 2 ;;
      --ssh-port|--port) require_value "$1" "${2:-}"; port="$2"; shift 2 ;;
      --ssh-key|--key) require_value "$1" "${2:-}"; key="$2"; key_explicit="1"; shift 2 ;;
      --host) require_value "$1" "${2:-}"; host="$2"; shift 2 ;;
      --global-numa-balancing) require_value "$1" "${2:-}"; global_numa="$2"; shift 2 ;;
      --demotion-enabled) require_value "$1" "${2:-}"; demotion_enabled="$2"; shift 2 ;;
      --demotion-target) require_value "$1" "${2:-}"; demotion_target="$2"; shift 2 ;;
      --scan-size-mb) require_value "$1" "${2:-}"; scan_size_mb="$2"; shift 2 ;;
      --reuse-time-enable) require_value "$1" "${2:-}"; reuse_time_enable="$2"; shift 2 ;;
      --no-debugfs) mount_debugfs="0"; shift ;;
      --no-cgroup-memory) cgroup_memory="0"; shift ;;
      -h|--help)
        cat <<'EOF'
Usage:
  vmctl.sh prepare-guest [ssh options] [guest knob options]

Options:
  --global-numa-balancing N   Write /proc/sys/kernel/numa_balancing.
  --demotion-enabled VALUE    Write /sys/kernel/mm/numa/demotion_enabled.
  --demotion-target "A B"     Write /sys/kernel/mm/numa/demotion_target.
  --scan-size-mb N            Write debugfs sched scan_size_mb if present.
  --reuse-time-enable 0|1     Write debugfs reuse_time/enable if present.
EOF
        exit 0 ;;
      *) die "unknown prepare-guest option: $1" ;;
    esac
  done

  local -a ssh_args=( --ssh-user "${user}" --ssh-port "${port}" --host "${host}" )
  if [[ -f "${key}" || "${key_explicit}" == "1" ]]; then
    ssh_args+=( --ssh-key "${key}" )
  fi

  local remote_cmd="MOUNT_DEBUGFS=$(q "${mount_debugfs}") CGROUP_MEMORY=$(q "${cgroup_memory}") GLOBAL_NUMA_BALANCING=$(q "${global_numa}") DEMOTION_ENABLED=$(q "${demotion_enabled}") DEMOTION_TARGET=$(q "${demotion_target}") SCAN_SIZE_MB=$(q "${scan_size_mb}") REUSE_TIME_ENABLE=$(q "${reuse_time_enable}") bash -s"
  cmd_ssh "${ssh_args[@]}" -- "${remote_cmd}" <<'EOS'
set -euo pipefail

if [[ "${MOUNT_DEBUGFS}" == "1" ]]; then
  mkdir -p /sys/kernel/debug
  mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
fi

if [[ "${CGROUP_MEMORY}" == "1" && -w /sys/fs/cgroup/cgroup.subtree_control ]]; then
  printf '+memory\n' > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
fi

if [[ -n "${GLOBAL_NUMA_BALANCING}" && -w /proc/sys/kernel/numa_balancing ]]; then
  echo "${GLOBAL_NUMA_BALANCING}" > /proc/sys/kernel/numa_balancing
fi

if [[ -n "${DEMOTION_ENABLED}" && -w /sys/kernel/mm/numa/demotion_enabled ]]; then
  echo "${DEMOTION_ENABLED}" > /sys/kernel/mm/numa/demotion_enabled
fi

if [[ -n "${DEMOTION_TARGET}" && -w /sys/kernel/mm/numa/demotion_target ]]; then
  echo "${DEMOTION_TARGET}" > /sys/kernel/mm/numa/demotion_target
fi

if [[ -n "${SCAN_SIZE_MB}" && -w /sys/kernel/debug/sched/numa_balancing/scan_size_mb ]]; then
  echo "${SCAN_SIZE_MB}" > /sys/kernel/debug/sched/numa_balancing/scan_size_mb
fi

if [[ -n "${REUSE_TIME_ENABLE}" && -w /sys/kernel/debug/reuse_time/enable ]]; then
  echo "${REUSE_TIME_ENABLE}" > /sys/kernel/debug/reuse_time/enable
fi

echo "[guest] uname: $(uname -a)"
echo "[guest] numa_balancing: $(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo NA)"
echo "[guest] demotion_enabled: $(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo NA)"
echo "[guest] demotion_target: $(tr '\n' ';' < /sys/kernel/mm/numa/demotion_target 2>/dev/null || echo NA)"
echo "[guest] scan_size_mb: $(cat /sys/kernel/debug/sched/numa_balancing/scan_size_mb 2>/dev/null || echo NA)"
echo "[guest] reuse_time_enable: $(cat /sys/kernel/debug/reuse_time/enable 2>/dev/null || echo NA)"
EOS
}

cmd_tmux_run() {
  local user="${DEFAULT_SSH_USER}" port="${DEFAULT_SSH_PORT}"
  local key="${DEFAULT_SSH_KEY}" key_explicit="0" host="127.0.0.1"
  local session="vm_experiment" remote_log="" kill_existing="1"
  local dry_run="0"
  local -a guest_cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-user|--user) require_value "$1" "${2:-}"; user="$2"; shift 2 ;;
      --ssh-port|--port) require_value "$1" "${2:-}"; port="$2"; shift 2 ;;
      --ssh-key|--key) require_value "$1" "${2:-}"; key="$2"; key_explicit="1"; shift 2 ;;
      --host) require_value "$1" "${2:-}"; host="$2"; shift 2 ;;
      --session) require_value "$1" "${2:-}"; session="$2"; shift 2 ;;
      --log) require_value "$1" "${2:-}"; remote_log="$2"; shift 2 ;;
      --no-kill-existing) kill_existing="0"; shift ;;
      --dry-run) dry_run="1"; shift ;;
      --) shift; guest_cmd=( "$@" ); break ;;
      -h|--help)
        echo "Usage: vmctl.sh tmux-run [ssh options] --session NAME [--log PATH] -- COMMAND..."
        exit 0 ;;
      *) guest_cmd+=( "$1" ); shift ;;
    esac
  done

  (( ${#guest_cmd[@]} > 0 )) || die "tmux-run requires a guest command after --"

  local -a ssh_args=( --ssh-user "${user}" --ssh-port "${port}" --host "${host}" )
  if [[ -f "${key}" || "${key_explicit}" == "1" ]]; then
    ssh_args+=( --ssh-key "${key}" )
  fi

  local inner remote
  inner="$(printf '%q ' "${guest_cmd[@]}")"
  if [[ -n "${remote_log}" ]]; then
    inner="${inner}2>&1 | tee -a $(q "${remote_log}")"
  fi

  if [[ "${kill_existing}" == "1" ]]; then
    remote="tmux has-session -t $(q "${session}") 2>/dev/null && tmux kill-session -t $(q "${session}") || true; tmux new-session -d -s $(q "${session}") -- bash -lc $(q "${inner}")"
  else
    remote="tmux new-session -d -s $(q "${session}") -- bash -lc $(q "${inner}")"
  fi

  if [[ "${dry_run}" == "1" ]]; then
    printf 'Remote command:\n  %s\n' "${remote}"
    return 0
  fi

  cmd_ssh "${ssh_args[@]}" -- "${remote}"
  log "started tmux session '${session}'"
}

cmd_status() {
  local name="${DEFAULT_VM_NAME}" pidfile
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) require_value "$1" "${2:-}"; name="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown status option: $1" ;;
    esac
  done
  pidfile="${RUN_DIR}/${name}.pid"
  log "name=${name}"
  log "pidfile=${pidfile}"
  if [[ -s "${pidfile}" ]] && kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
    log "running pid=$(cat "${pidfile}")"
    ps -o pid,psr,comm,args -p "$(cat "${pidfile}")"
  else
    log "not running"
  fi
  [[ ! -f "${RUN_DIR}/${name}.serial.log" ]] || tail -n 20 "${RUN_DIR}/${name}.serial.log"
}

cmd_stop() {
  local name="${DEFAULT_VM_NAME}" pidfile pid
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) require_value "$1" "${2:-}"; name="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown stop option: $1" ;;
    esac
  done
  pidfile="${RUN_DIR}/${name}.pid"
  [[ -s "${pidfile}" ]] || die "pidfile not found: ${pidfile}"
  pid="$(cat "${pidfile}")"
  if kill -0 "${pid}" 2>/dev/null; then
    log "stopping ${name} pid=${pid}"
    kill -TERM "${pid}"
    for _ in {1..30}; do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "${pid}" 2>/dev/null; then
      log "pid still alive after TERM; sending KILL"
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  fi
  rm -f "${pidfile}"
}

cmd_verify_placement() {
  local name pidfile pid
  parse_ssh_args "$@"
  name="${SSH_VM_NAME}"
  pidfile="${RUN_DIR}/${name}.pid"
  if [[ -s "${pidfile}" ]]; then
    pid="$(cat "${pidfile}")"
  else
    pid="$(pgrep -f "qemu-system.*-name ${name}" | head -n 1 || true)"
  fi
  [[ -n "${pid}" ]] || die "QEMU pid not found for ${name}"

  log "host QEMU pid=${pid}"
  taskset -pc "${pid}" 2>/dev/null || true
  if have_cmd numastat; then
    numastat -p "${pid}" || true
  fi

  log "guest NUMA topology"
  cmd_ssh --ssh-user "${SSH_USER_ARG}" --ssh-port "${SSH_PORT_ARG}" --ssh-key "${SSH_KEY_ARG}" --host "${SSH_HOST_ARG}" -- \
    "numactl -H 2>/dev/null || true; for n in /sys/devices/system/node/node*/meminfo; do echo === \$n; sed -n '1,6p' \$n; done"
}

main() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { usage; exit 1; }
  shift || true

  case "${cmd}" in
    help|-h|--help) usage ;;
    check) cmd_check "$@" ;;
    create-image) cmd_create_image "$@" ;;
    build-qemu) cmd_build_qemu "$@" ;;
    build-initrd) cmd_build_initrd "$@" ;;
    boot) cmd_boot "$@" ;;
    wait-ssh) cmd_wait_ssh "$@" ;;
    ssh) cmd_ssh "$@" ;;
    copy-to) cmd_copy_to "$@" ;;
    copy-from) cmd_copy_from "$@" ;;
    prepare-guest) cmd_prepare_guest "$@" ;;
    tmux-run) cmd_tmux_run "$@" ;;
    status) cmd_status "$@" ;;
    stop) cmd_stop "$@" ;;
    verify-placement) cmd_verify_placement "$@" ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
