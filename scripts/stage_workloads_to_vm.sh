#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-10030}"
HOST="${HOST:-127.0.0.1}"
SSH_KEY="${SSH_KEY:-}"
BENCHMARK_DIR="${BENCHMARK_DIR:-/Serverless/benchmark}"
WORKLOADS="${WORKLOADS:-core}"
CLEAN="${CLEAN:-0}"
CLEAN_SCRIPTS="${CLEAN_SCRIPTS:-1}"
STAGE_JDK="${STAGE_JDK:-auto}"
STAGE_JDK17="${STAGE_JDK17:-auto}"
STAGE_DOTNET="${STAGE_DOTNET:-auto}"
STAGE_DLRM_VENV="${STAGE_DLRM_VENV:-1}"
STAGE_FRAMEWORKS="${STAGE_FRAMEWORKS:-0}"
SSH_CONTROL_MASTER="${SSH_CONTROL_MASTER:-1}"
SSH_CONTROL_PATH="${SSH_CONTROL_PATH:-/tmp/iccd-realworld-${PORT}.sock}"

SSH_OPTS=(-p "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SCP_OPTS=(-P "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if [[ -n "${SSH_KEY}" ]]; then
  SSH_OPTS+=(-i "${SSH_KEY}")
  SCP_OPTS+=(-i "${SSH_KEY}")
fi
if [[ "${SSH_CONTROL_MASTER}" == "1" ]]; then
  SSH_OPTS+=(
    -o LogLevel=ERROR
    -o ControlMaster=auto
    -o ControlPersist=600
    -o ControlPath="${SSH_CONTROL_PATH}"
  )
  SCP_OPTS+=(
    -o LogLevel=ERROR
    -o ControlMaster=auto
    -o ControlPersist=600
    -o ControlPath="${SSH_CONTROL_PATH}"
  )
  trap 'ssh -p "${PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlPath="${SSH_CONTROL_PATH}" -O exit "root@${HOST}" >/dev/null 2>&1 || true; rm -f "${SSH_CONTROL_PATH}"' EXIT
fi

remote() {
  ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

copy_file() {
  local src="$1"
  local dst="$2"
  if [[ ! -e "${src}" ]]; then
    echo "missing local file: ${src}" >&2
    return 1
  fi
  remote "mkdir -p '$(dirname "${dst}")'"
  scp "${SCP_OPTS[@]}" "${src}" "root@${HOST}:${dst}" >/dev/null
}

stream_dir() {
  local src="$1"
  local dst_parent="$2"
  if [[ ! -d "${src}" ]]; then
    echo "missing local directory: ${src}" >&2
    return 1
  fi
  remote "mkdir -p '${dst_parent}'"
  tar -C "$(dirname "${src}")" -czf - "$(basename "${src}")" | \
    ssh "${SSH_OPTS[@]}" "root@${HOST}" "tar -xzf - -C '${dst_parent}'"
}

stream_files_from_benchmark() {
  remote "mkdir -p /root/benchmark"
  tar -C "${BENCHMARK_DIR}" -czf - "$@" | \
    ssh "${SSH_OPTS[@]}" "root@${HOST}" "tar -xzf - -C /root/benchmark"
}

stream_ycsb_binding() {
  local binding="$1"
  local tarball="${BENCHMARK_DIR}/YCSB/${binding}/target/ycsb-${binding}-binding-0.18.0-SNAPSHOT.tar.gz"
  local dst="/root/benchmark/ycsb-${binding}"
  if [[ "${binding}" == "memcached" ]]; then
    local jar="${BENCHMARK_DIR}/YCSB/memcached/target/memcached-binding-0.18.0-SNAPSHOT.jar"
    if [[ ! -f "${jar}" ]]; then
      echo "missing YCSB memcached jar: ${jar}" >&2
      return 1
    fi
    remote "rm -rf '${dst}' && mkdir -p '${dst}/memcached-binding/lib'"
    tar -C "${BENCHMARK_DIR}/YCSB" -czf - bin workloads LICENSE.txt NOTICE.txt | \
      ssh "${SSH_OPTS[@]}" "root@${HOST}" "tar -xzf - -C '${dst}'"
    tar -C "${BENCHMARK_DIR}/YCSB/memcached/target" -czf - \
      memcached-binding-0.18.0-SNAPSHOT.jar dependency | \
      ssh "${SSH_OPTS[@]}" "root@${HOST}" "\
        tmp=\$(mktemp -d) && \
        tar -xzf - -C \"\$tmp\" && \
        mv \"\$tmp\"/memcached-binding-0.18.0-SNAPSHOT.jar '${dst}/memcached-binding/lib/' && \
        find \"\$tmp\"/dependency -type f -name '*.jar' -exec mv {} '${dst}/memcached-binding/lib/' \\; && \
        rm -rf \"\$tmp\""
    remote "chmod +x '${dst}/bin/ycsb'"
    return 0
  fi
  if [[ ! -f "${tarball}" ]]; then
    echo "missing YCSB ${binding} tarball: ${tarball}" >&2
    return 1
  fi
  remote "rm -rf '${dst}' && mkdir -p '${dst}'"
  cat "${tarball}" | ssh "${SSH_OPTS[@]}" "root@${HOST}" \
    "tar -xzf - -C '${dst}' --strip-components=1 && chmod +x '${dst}/bin/ycsb'"
}

copy_ldd_libs() {
  local bin="$1"
  local dst_dir="${2:-/usr/local/lib/iccd-realworld-deps}"
  if [[ ! -x "${bin}" ]]; then
    return 0
  fi
  while read -r lib; do
    [[ -n "${lib}" && -f "${lib}" ]] || continue
    local lib_base
    local lib_src
    lib_base="$(basename "${lib}")"
    case "$(basename "${lib}")" in
      ld-linux*|libanl.so.*|libBrokenLocale.so.*|libc.so.*|libcrypt.so.*|libdl.so.*|libm.so.*|libmvec.so.*|libnsl.so.*|libnss_*.so.*|libpthread.so.*|libresolv.so.*|librt.so.*|libthread_db.so.*|libutil.so.*)
        continue
        ;;
    esac
    lib_src="$(readlink -f "${lib}")"
    copy_file "${lib_src}" "${dst_dir}/${lib_base}"
  done < <(ldd "${bin}" 2>/dev/null | awk '
    $2 == "=>" && $3 ~ /^\// { print $3 }
    $1 ~ /^\// { print $1 }
  ' | sort -u)
}

expand_workloads() {
  local out=()
  local w
  for w in "$@"; do
    case "${w}" in
      core)
        out+=(
          redis_uniform redis_ycsb_a rocksdb_ycsb_uniform memcached_ycsb_uniform
          faster_uniform faster_ycsb_a dlrm_synth npb_cg npb_mg npb_ua
          spec_bwaves canneal_synth
        )
        ;;
      scalable)
        out+=(
          redis_uniform redis_ycsb_a rocksdb_ycsb_uniform memcached_ycsb_uniform
          faster_uniform faster_ycsb_a dlrm_synth
        )
        ;;
      candidate|candidates)
        out+=(pr bc gups graph500 btree xsbench gapbs_bfs gapbs_cc gapbs_sssp)
        ;;
      all)
        out+=(
          redis_uniform redis_ycsb_a rocksdb_ycsb_uniform memcached_ycsb_uniform
          faster_uniform faster_ycsb_a dlrm_synth npb_cg npb_mg npb_ua
          spec_bwaves spec_fotonik3d spec_roms canneal_synth
          hibench_repartition hibench_sql_join cloudsuite_data_caching
          cloudsuite_web_search cloudsuite_als duckdb_tpch clickbench hnsw_faiss
          pr bc gups graph500 btree xsbench gapbs_bfs gapbs_cc gapbs_sssp
        )
        ;;
      *)
        out+=("${w}")
        ;;
    esac
  done
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}

needs_jdk() {
  local w="$1"
  case "${w}" in
    redis_ycsb_a|rocksdb_ycsb_uniform|memcached_ycsb_uniform|hibench_*|cloudsuite_als)
      return 0
      ;;
  esac
  return 1
}

needs_dotnet() {
  local w="$1"
  case "${w}" in
    faster_uniform|faster_ycsb_a)
      return 0
      ;;
  esac
  return 1
}

needs_jdk17() {
  local w="$1"
  case "${w}" in
    rocksdb_ycsb_uniform)
      return 0
      ;;
  esac
  return 1
}

stage_common_scripts() {
  remote "mkdir -p /root/scripts /root/benchmark /root/tools /root/realworld-work"
  if [[ "${CLEAN_SCRIPTS}" == "1" ]]; then
    remote "find /root/scripts -mindepth 1 -maxdepth 1 -type f -delete"
  fi
  copy_file "${SCRIPT_DIR}/run_ours_experiment.sh" \
    /root/scripts/run_ours_experiment.sh
  copy_file "${SCRIPT_DIR}/local_util_adapt_controller.py" \
    /root/scripts/local_util_adapt_controller.py
  copy_file "${SCRIPT_DIR}/run_workload_suite_guest.sh" \
    /root/scripts/run_workload_suite_guest.sh
  copy_file "${SCRIPT_DIR}/run_workload_case_guest.sh" \
    /root/scripts/run_workload_case_guest.sh
  remote "chmod +x /root/scripts/run_ours_experiment.sh /root/scripts/local_util_adapt_controller.py /root/scripts/run_workload_suite_guest.sh /root/scripts/run_workload_case_guest.sh"
}

stage_jdk8() {
  if remote "test -x /root/tools/jdk8/bin/java"; then
    echo "skip existing /root/tools/jdk8"
    return 0
  fi
  echo "stage jdk8"
  stream_dir "${BENCHMARK_DIR}/HiBench/.tools/jdk8" /root/tools
}

stage_dotnet7() {
  if remote "test -x /root/tools/dotnet7/dotnet"; then
    echo "skip existing /root/tools/dotnet7"
    return 0
  fi
  echo "stage dotnet7"
  stream_dir "${BENCHMARK_DIR}/.tools/dotnet7" /root/tools
}

stage_jdk17() {
  if remote "test -x /root/tools/jdk17/bin/java"; then
    echo "skip existing /root/tools/jdk17"
    return 0
  fi
  echo "stage jdk17"
  stream_dir /usr/lib/jvm/java-17-openjdk-amd64 /root/tools
  stream_dir /etc/java-17-openjdk /etc
  remote "ln -sfn /root/tools/java-17-openjdk-amd64 /root/tools/jdk17"
}

stage_redis() {
  echo "stage redis binaries"
  stream_files_from_benchmark \
    redis/src/redis-server \
    redis/src/redis-benchmark \
    redis/src/redis-cli
  remote "chmod +x /root/benchmark/redis/src/redis-server /root/benchmark/redis/src/redis-benchmark /root/benchmark/redis/src/redis-cli"
  copy_ldd_libs "${BENCHMARK_DIR}/redis/src/redis-server"
  copy_ldd_libs "${BENCHMARK_DIR}/redis/src/redis-benchmark"
}

stage_memcached() {
  echo "stage memcached binary"
  copy_file /usr/bin/memcached /root/benchmark/memcached/memcached
  remote "chmod +x /root/benchmark/memcached/memcached"
  copy_ldd_libs /usr/bin/memcached
  for lib in \
    /usr/lib/x86_64-linux-gnu/libevent-2.1.so.7 \
    /usr/lib/x86_64-linux-gnu/libsasl2.so.2 \
    /usr/lib/x86_64-linux-gnu/libssl.so.3; do
    if [[ -e "${lib}" ]]; then
      copy_file "$(readlink -f "${lib}")" \
        "/usr/local/lib/iccd-realworld-deps/$(basename "${lib}")"
    fi
  done
}

stage_ycsb() {
  local binding="$1"
  echo "stage ycsb ${binding}"
  stream_ycsb_binding "${binding}"
}

stage_faster() {
  echo "stage FASTER benchmark"
  remote "mkdir -p /root/benchmark/FASTER/cs/benchmark/bin/x64/Release"
  stream_dir "${BENCHMARK_DIR}/FASTER/cs/benchmark/bin/x64/Release/net7.0" \
    /root/benchmark/FASTER/cs/benchmark/bin/x64/Release
  remote "chmod +x /root/benchmark/FASTER/cs/benchmark/bin/x64/Release/net7.0/FASTER.benchmark"
}

stage_dlrm() {
  echo "stage DLRM source"
  remote "rm -rf /root/benchmark/DLRM"
  stream_dir "${BENCHMARK_DIR}/DLRM" /root/benchmark
  if [[ "${STAGE_DLRM_VENV}" == "1" ]]; then
    echo "stage DLRM Python venv"
    copy_file /usr/bin/python3.10 /usr/bin/python3.10
    stream_dir /usr/lib/python3.10 /usr/lib
    stream_dir "${BENCHMARK_DIR}/.tools/dlrm-venv" /root/tools
    remote "ln -sfn /usr/bin/python3.10 /root/tools/dlrm-venv/bin/python3 && ln -sfn python3 /root/tools/dlrm-venv/bin/python && ln -sfn python3 /root/tools/dlrm-venv/bin/python3.10"
  else
    echo "skip DLRM venv because STAGE_DLRM_VENV=0"
  fi
}

stage_npb_extra() {
  echo "stage NPB CG/MG/UA"
  stream_files_from_benchmark \
    NPB3.4.3/NPB3.4-OMP/bin/cg.D.x \
    NPB3.4.3/NPB3.4-OMP/bin/mg.D.x \
    NPB3.4.3/NPB3.4-OMP/bin/ua.D.x
  remote "chmod +x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/cg.D.x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/mg.D.x /root/benchmark/NPB3.4.3/NPB3.4-OMP/bin/ua.D.x"
  copy_ldd_libs "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/cg.D.x"
  copy_ldd_libs "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/mg.D.x"
  copy_ldd_libs "${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/ua.D.x"
}

stage_spec() {
  local spec="$1"
  case "${spec}" in
    spec_bwaves)
      echo "stage SPEC 603.bwaves_s runnable refspeed directory"
      remote "mkdir -p /root/benchmark/spec/603.bwaves_s/run"
      stream_dir "${BENCHMARK_DIR}/spec/benchspec/CPU/603.bwaves_s/run/run_base_refspeed_mytest-m64.0000" \
        /root/benchmark/spec/603.bwaves_s/run
      copy_ldd_libs "${BENCHMARK_DIR}/spec/benchspec/CPU/603.bwaves_s/exe/speed_bwaves_base.mytest-m64"
      ;;
    spec_fotonik3d)
      echo "stage SPEC 649.fotonik3d_s binary/source snapshot; ref input is not present locally"
      remote "mkdir -p /root/benchmark/spec"
      stream_dir "${BENCHMARK_DIR}/spec/benchspec/CPU/649.fotonik3d_s" /root/benchmark/spec
      copy_ldd_libs "${BENCHMARK_DIR}/spec/benchspec/CPU/649.fotonik3d_s/exe/fotonik3d_s_base.mytest-m64"
      ;;
    spec_roms)
      echo "stage SPEC 654.roms_s binary/source snapshot; complete ref run directory is not present locally"
      remote "mkdir -p /root/benchmark/spec"
      stream_dir "${BENCHMARK_DIR}/spec/benchspec/CPU/654.roms_s" /root/benchmark/spec
      copy_ldd_libs "${BENCHMARK_DIR}/spec/benchspec/CPU/654.roms_s/exe/sroms_base.mytest-m64"
      ;;
  esac
}

stage_canneal() {
  echo "stage canneal binary"
  stream_files_from_benchmark vmitosis-workloads/bin/bench_canneal_mt
  remote "chmod +x /root/benchmark/vmitosis-workloads/bin/bench_canneal_mt"
  copy_ldd_libs "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_canneal_mt"
}

stage_candidate_microbench() {
  local w="$1"
  remote "mkdir -p /root/benchmark/vmitosis-workloads/bin /root/benchmark/XSBench/openmp-threading /root/benchmark/gapbs /root/gapbs_graphs"
  case "${w}" in
    pr|bc)
      copy_file "${BENCHMARK_DIR}/gapbs/${w}" "/root/benchmark/gapbs/${w}"
      remote "chmod +x /root/benchmark/gapbs/${w}"
      if ! remote "test -s /root/gapbs_graphs/kron_g28.sg"; then
        copy_file "${BENCHMARK_DIR}/gapbs/benchmark/graphs/kron_g28.sg" \
          /root/gapbs_graphs/kron_g28.sg
      fi
      ;;
    gups)
      copy_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_gups_mt" \
        /root/benchmark/vmitosis-workloads/bin/bench_gups_mt
      remote "chmod +x /root/benchmark/vmitosis-workloads/bin/bench_gups_mt"
      copy_ldd_libs "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_gups_mt"
      ;;
    graph500)
      copy_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_graph500_mt" \
        /root/benchmark/vmitosis-workloads/bin/bench_graph500_mt
      remote "chmod +x /root/benchmark/vmitosis-workloads/bin/bench_graph500_mt"
      copy_ldd_libs "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_graph500_mt"
      ;;
    btree)
      copy_file "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_btree_mt" \
        /root/benchmark/vmitosis-workloads/bin/bench_btree_mt
      remote "chmod +x /root/benchmark/vmitosis-workloads/bin/bench_btree_mt"
      copy_ldd_libs "${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_btree_mt"
      ;;
    xsbench)
      copy_file "${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench" \
        /root/benchmark/XSBench/openmp-threading/XSBench
      remote "chmod +x /root/benchmark/XSBench/openmp-threading/XSBench"
      copy_ldd_libs "${BENCHMARK_DIR}/XSBench/openmp-threading/XSBench"
      ;;
    gapbs_bfs|gapbs_cc|gapbs_sssp)
      copy_file "${BENCHMARK_DIR}/gapbs/${w#gapbs_}" "/root/benchmark/gapbs/${w#gapbs_}"
      remote "chmod +x /root/benchmark/gapbs/${w#gapbs_}"
      if ! remote "test -s /root/gapbs_graphs/kron_g28.sg"; then
        copy_file "${BENCHMARK_DIR}/gapbs/benchmark/graphs/kron_g28.sg" \
          /root/gapbs_graphs/kron_g28.sg
      fi
      ;;
  esac
}

stage_framework_placeholder() {
  local w="$1"
  if [[ "${STAGE_FRAMEWORKS}" != "1" ]]; then
    echo "skip ${w}: framework/data staging disabled; runner will report rc=77"
    return 0
  fi
  case "${w}" in
    hibench_repartition|hibench_sql_join)
      echo "stage HiBench tree"
      stream_dir "${BENCHMARK_DIR}/HiBench" /root/benchmark
      ;;
    cloudsuite_data_caching|cloudsuite_web_search|cloudsuite_als)
      echo "stage CloudSuite scripts only; Docker images/datasets still need explicit preparation"
      stream_dir "${BENCHMARK_DIR}/cloudsuite" /root/benchmark
      ;;
  esac
}

stage_workload() {
  local w="$1"
  case "${w}" in
    redis_uniform)
      stage_redis
      ;;
    redis_ycsb_a)
      stage_redis
      stage_ycsb redis
      ;;
    rocksdb_ycsb_uniform)
      stage_ycsb rocksdb
      ;;
    memcached_ycsb_uniform)
      stage_memcached
      stage_ycsb memcached
      ;;
    faster_uniform|faster_ycsb_a)
      stage_faster
      ;;
    dlrm_synth)
      stage_dlrm
      ;;
    npb_cg|npb_mg|npb_ua)
      stage_npb_extra
      ;;
    spec_bwaves|spec_fotonik3d|spec_roms)
      stage_spec "${w}"
      ;;
    canneal_synth)
      stage_canneal
      ;;
    pr|bc|gups|graph500|btree|xsbench|gapbs_bfs|gapbs_cc|gapbs_sssp)
      stage_candidate_microbench "${w}"
      ;;
    hibench_repartition|hibench_sql_join|cloudsuite_data_caching|cloudsuite_web_search|cloudsuite_als)
      stage_framework_placeholder "${w}"
      ;;
    duckdb_tpch|clickbench|hnsw_faiss)
      echo "skip ${w}: external install/data recipe only; runner will report rc=77"
      ;;
    *)
      echo "unknown workload: ${w}" >&2
      return 1
      ;;
  esac
}

if [[ "${CLEAN}" == "1" ]]; then
  remote "rm -rf /root/benchmark /root/tools/dotnet7 /root/tools/dlrm-venv /root/realworld-work && mkdir -p /root/benchmark /root/tools /root/realworld-work"
fi

mapfile -t workload_list < <(expand_workloads ${WORKLOADS})

stage_common_scripts

for w in "${workload_list[@]}"; do
  if needs_jdk "${w}"; then
    if [[ "${STAGE_JDK}" == "1" || "${STAGE_JDK}" == "auto" ]]; then
      stage_jdk8
    fi
  fi
  if needs_dotnet "${w}"; then
    if [[ "${STAGE_DOTNET}" == "1" || "${STAGE_DOTNET}" == "auto" ]]; then
      stage_dotnet7
    fi
  fi
  if needs_jdk17 "${w}"; then
    if [[ "${STAGE_JDK17}" == "1" || "${STAGE_JDK17}" == "auto" ]]; then
      stage_jdk17
    fi
  fi
  stage_workload "${w}"
done

remote "printf '%s\n' /usr/local/lib/iccd-realworld-deps > /etc/ld.so.conf.d/iccd-realworld-deps.conf 2>/dev/null || true; ldconfig 2>/dev/null || true"

remote "df -h / /root 2>/dev/null || true; du -sh /root/benchmark /root/tools /root/realworld-work 2>/dev/null || true; find /root/scripts -maxdepth 1 -type f -printf '%p\n' | sort"
