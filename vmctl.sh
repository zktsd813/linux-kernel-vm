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
  boot              Boot a QEMU VM with DRAM/CXL-style NUMA placement.
  wait-ssh          Wait until the guest SSH endpoint is reachable.
  ssh               Open SSH or run a command in the guest.
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
  ./vmctl.sh boot --kernel /path/bzImage --initrd /boot/initrd.img-6.18.0modified --rootfs images/ubuntu.overlay.qcow2
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
    boot) cmd_boot "$@" ;;
    wait-ssh) cmd_wait_ssh "$@" ;;
    ssh) cmd_ssh "$@" ;;
    status) cmd_status "$@" ;;
    stop) cmd_stop "$@" ;;
    verify-placement) cmd_verify_placement "$@" ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
