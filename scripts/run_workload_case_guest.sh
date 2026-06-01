#!/usr/bin/env bash
set -euo pipefail

WORKLOAD="${1:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="${BENCHMARK_DIR:-/root/benchmark}"
TOOLS_DIR="${TOOLS_DIR:-/root/tools}"
WORKDIR="${WORKDIR:-/root/realworld-work}"
OMP_THREADS="${OMP_THREADS:-32}"

realworld_apply_rss60_profile() {
  local workload="$1"

  case "${workload}" in
    redis_uniform)
      : "${REDIS_KEYSPACE:=1880000}"
      : "${REDIS_LOAD_REQUESTS:=4300000}"
      : "${REDIS_RUN_REQUESTS:=500000}"
      : "${REDIS_VALUE_SIZE:=32768}"
      : "${REDIS_CLIENTS:=128}"
      : "${REDIS_TESTS:=get,set}"
      export REDIS_KEYSPACE REDIS_LOAD_REQUESTS REDIS_RUN_REQUESTS
      export REDIS_VALUE_SIZE REDIS_CLIENTS REDIS_TESTS
      ;;
    redis_ycsb_a)
      : "${YCSB_RECORDCOUNT:=1200000}"
      : "${YCSB_OPERATIONCOUNT:=250000}"
      : "${YCSB_FIELDCOUNT:=10}"
      : "${YCSB_FIELDLENGTH:=4096}"
      : "${YCSB_HEAP:=8g}"
      : "${YCSB_WORKLOAD:=workloada}"
      : "${YCSB_DISTRIBUTION:=uniform}"
      export YCSB_RECORDCOUNT YCSB_OPERATIONCOUNT YCSB_FIELDCOUNT
      export YCSB_FIELDLENGTH YCSB_HEAP YCSB_WORKLOAD YCSB_DISTRIBUTION
      ;;
    rocksdb_ycsb_uniform)
      : "${YCSB_RECORDCOUNT:=1350000}"
      : "${YCSB_OPERATIONCOUNT:=250000}"
      : "${YCSB_FIELDCOUNT:=10}"
      : "${YCSB_FIELDLENGTH:=4096}"
      : "${YCSB_HEAP:=8g}"
      : "${YCSB_WORKLOAD:=workloadc}"
      : "${ROCKSDB_DIR:=/dev/shm/rocksdb-data-rss60}"
      : "${ROCKSDB_SHM_SIZE:=80G}"
      export YCSB_RECORDCOUNT YCSB_OPERATIONCOUNT YCSB_FIELDCOUNT
      export YCSB_FIELDLENGTH YCSB_HEAP YCSB_WORKLOAD ROCKSDB_DIR
      export ROCKSDB_SHM_SIZE
      ;;
    memcached_ycsb_uniform)
      : "${MEMCACHED_MEMORY_MB:=65536}"
      : "${YCSB_RECORDCOUNT:=1425000}"
      : "${YCSB_OPERATIONCOUNT:=250000}"
      : "${YCSB_FIELDCOUNT:=10}"
      : "${YCSB_FIELDLENGTH:=4096}"
      : "${YCSB_HEAP:=8g}"
      : "${YCSB_WORKLOAD:=workloada}"
      export MEMCACHED_MEMORY_MB YCSB_RECORDCOUNT YCSB_OPERATIONCOUNT
      export YCSB_FIELDCOUNT YCSB_FIELDLENGTH YCSB_HEAP YCSB_WORKLOAD
      ;;
    faster_uniform|faster_ycsb_a)
      : "${FASTER_RUNSEC:=30}"
      : "${FASTER_ITERATIONS:=1}"
      : "${FASTER_DISTRIBUTION:=uniform}"
      export FASTER_RUNSEC FASTER_ITERATIONS FASTER_DISTRIBUTION
      ;;
    dlrm_synth)
      : "${DLRM_TABLES:=8}"
      : "${DLRM_ROWS_PER_TABLE:=21000000}"
      : "${DLRM_SPARSE_FEATURE:=64}"
      : "${DLRM_MINI_BATCH:=16}"
      : "${DLRM_NUM_BATCHES:=1}"
      : "${DLRM_INDICES_PER_LOOKUP:=100}"
      export DLRM_TABLES DLRM_ROWS_PER_TABLE DLRM_SPARSE_FEATURE
      export DLRM_MINI_BATCH DLRM_NUM_BATCHES DLRM_INDICES_PER_LOOKUP
      ;;
    canneal_synth)
      : "${CANNEAL_ELEMENTS:=5000000}"
      : "${CANNEAL_GRID_X:=4096}"
      : "${CANNEAL_GRID_Y:=4096}"
      : "${CANNEAL_FANIN:=4}"
      : "${CANNEAL_SWAPS:=1000000}"
      export CANNEAL_ELEMENTS CANNEAL_GRID_X CANNEAL_GRID_Y
      export CANNEAL_FANIN CANNEAL_SWAPS
      ;;
  esac
}

realworld_dump_profile_env() {
  env | LC_ALL=C sort | grep -E '^(REDIS_|YCSB_|MEMCACHED_|FASTER_|DLRM_|CANNEAL_|ROCKSDB_)' || true
}

if [[ "${REALWORLD_SIZE_PROFILE:-}" == "rss60" ]]; then
  realworld_apply_rss60_profile "${WORKLOAD}"
fi

mkdir -p "${WORKDIR}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

need_exec() {
  local path="$1"
  if [[ ! -x "${path}" ]]; then
    echo "missing executable: ${path}" >&2
    exit 77
  fi
}

need_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "missing file: ${path}" >&2
    exit 77
  fi
}

wait_tcp() {
  local port="$1"
  local deadline=$((SECONDS + 60))
  until bash -c ":</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1; do
    if (( SECONDS > deadline )); then
      echo "timeout waiting for 127.0.0.1:${port}" >&2
      return 1
    fi
    sleep 1
  done
}

start_redis() {
  REDIS_PORT="${REDIS_PORT:-6380}"
  REDIS_DIR="${WORKDIR}/redis-${REDIS_PORT}"
  REDIS_PIDFILE="${REDIS_DIR}/redis.pid"
  mkdir -p "${REDIS_DIR}"
  need_exec "${BENCHMARK_DIR}/redis/src/redis-server"
  "${BENCHMARK_DIR}/redis/src/redis-server" \
    --bind 127.0.0.1 \
    --protected-mode no \
    --port "${REDIS_PORT}" \
    --save "" \
    --appendonly no \
    --daemonize yes \
    --pidfile "${REDIS_PIDFILE}" \
    --dir "${REDIS_DIR}" \
    --dbfilename dump.rdb \
    --logfile "${REDIS_DIR}/redis.log" \
    --maxmemory 0 \
    --io-threads "${REDIS_IO_THREADS:-1}"
  wait_tcp "${REDIS_PORT}"
}

stop_redis() {
  if [[ -n "${REDIS_PORT:-}" && -x "${BENCHMARK_DIR}/redis/src/redis-cli" ]]; then
    "${BENCHMARK_DIR}/redis/src/redis-cli" -p "${REDIS_PORT}" shutdown nosave >/dev/null 2>&1 || true
  fi
  if [[ -n "${REDIS_PIDFILE:-}" && -f "${REDIS_PIDFILE}" ]]; then
    kill "$(cat "${REDIS_PIDFILE}")" >/dev/null 2>&1 || true
  fi
}

start_memcached() {
  MEMCACHED_PORT="${MEMCACHED_PORT:-11211}"
  MEMCACHED_MEMORY_MB="${MEMCACHED_MEMORY_MB:-49152}"
  MEMCACHED_PIDFILE="${WORKDIR}/memcached-${MEMCACHED_PORT}.pid"
  need_exec "${BENCHMARK_DIR}/memcached/memcached"
  "${BENCHMARK_DIR}/memcached/memcached" \
    -u root \
    -l 127.0.0.1 \
    -p "${MEMCACHED_PORT}" \
    -m "${MEMCACHED_MEMORY_MB}" \
    -t "${MEMCACHED_THREADS:-${OMP_THREADS}}" \
    -I "${MEMCACHED_ITEM_MAX:-32m}" \
    -P "${MEMCACHED_PIDFILE}" \
    -d
  wait_tcp "${MEMCACHED_PORT}"
}

stop_memcached() {
  if [[ -n "${MEMCACHED_PIDFILE:-}" && -f "${MEMCACHED_PIDFILE}" ]]; then
    local pid
    pid="$(cat "${MEMCACHED_PIDFILE}")"
    kill "${pid}" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.1
    done
    kill -9 "${pid}" >/dev/null 2>&1 || true
  fi
}

ycsb_bin() {
  local binding="$1"
  local dir="${BENCHMARK_DIR}/ycsb-${binding}"
  need_exec "${dir}/bin/ycsb"
  printf '%s\n' "${dir}/bin/ycsb"
}

java_env() {
  if [[ -n "${YCSB_JAVA_HOME:-}" && -x "${YCSB_JAVA_HOME}/bin/java" ]]; then
    export JAVA_HOME="${YCSB_JAVA_HOME}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
  elif [[ -x "${TOOLS_DIR}/jdk8/bin/java" ]]; then
    export JAVA_HOME="${TOOLS_DIR}/jdk8"
    export PATH="${JAVA_HOME}/bin:${PATH}"
  fi
}

run_redis_uniform() {
  trap stop_redis EXIT
  start_redis
  local bench="${BENCHMARK_DIR}/redis/src/redis-benchmark"
  need_exec "${bench}"

  local keyspace="${REDIS_KEYSPACE:-2000000}"
  local load_requests="${REDIS_LOAD_REQUESTS:-3000000}"
  local run_requests="${REDIS_RUN_REQUESTS:-3000000}"
  local value_size="${REDIS_VALUE_SIZE:-16384}"
  local clients="${REDIS_CLIENTS:-128}"
  local threads="${REDIS_CLIENT_THREADS:-${OMP_THREADS}}"
  local tests="${REDIS_TESTS:-get,set}"

  log "redis preload: requests=${load_requests} keyspace=${keyspace} value_size=${value_size}"
  "${bench}" -p "${REDIS_PORT}" -c "${clients}" --threads "${threads}" \
    -n "${load_requests}" -r "${keyspace}" -d "${value_size}" -t set --csv
  log "redis run: tests=${tests} requests=${run_requests}"
  "${bench}" -p "${REDIS_PORT}" -c "${clients}" --threads "${threads}" \
    -n "${run_requests}" -r "${keyspace}" -d "${value_size}" -t "${tests}" --csv
}

run_redis_ycsb_a() {
  trap stop_redis EXIT
  java_env
  start_redis
  local ycsb
  ycsb="$(ycsb_bin redis)"

  local records="${YCSB_RECORDCOUNT:-800000}"
  local ops="${YCSB_OPERATIONCOUNT:-1600000}"
  local fieldlength="${YCSB_FIELDLENGTH:-4096}"
  local fieldcount="${YCSB_FIELDCOUNT:-10}"
  local threads="${YCSB_THREADS:-${OMP_THREADS}}"
  local dist="${YCSB_DISTRIBUTION:-uniform}"
  local heap="${YCSB_HEAP:-4g}"
  local workload="${YCSB_WORKLOAD:-workloada}"

  log "redis ycsb load: workload=${workload} records=${records} fieldcount=${fieldcount} fieldlength=${fieldlength} dist=${dist}"
  "${ycsb}" load redis -s -P "${BENCHMARK_DIR}/ycsb-redis/workloads/${workload}" \
    -threads "${threads}" -jvm-args="-Xmx${heap}" \
    -p "redis.host=127.0.0.1" -p "redis.port=${REDIS_PORT}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=${dist}"

  log "redis ycsb run: ops=${ops}"
  "${ycsb}" run redis -s -P "${BENCHMARK_DIR}/ycsb-redis/workloads/${workload}" \
    -threads "${threads}" -jvm-args="-Xmx${heap}" \
    -p "redis.host=127.0.0.1" -p "redis.port=${REDIS_PORT}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=${dist}"
}

run_ycsb_rocksdb_uniform() {
  if [[ -z "${YCSB_JAVA_HOME:-}" && -x "${TOOLS_DIR}/jdk17/bin/java" ]]; then
    export YCSB_JAVA_HOME="${TOOLS_DIR}/jdk17"
  fi
  java_env
  local ycsb
  ycsb="$(ycsb_bin rocksdb)"
  local dbdir="${ROCKSDB_DIR:-/dev/shm/rocksdb-data-$$}"
  if [[ -n "${ROCKSDB_SHM_SIZE:-}" && "${dbdir}" == /dev/shm/* ]]; then
    mount -o "remount,size=${ROCKSDB_SHM_SIZE}" /dev/shm || true
  fi
  rm -rf "${dbdir}"
  mkdir -p "${dbdir}"
  trap "rm -rf '${dbdir}'" EXIT

  local records="${YCSB_RECORDCOUNT:-800000}"
  local ops="${YCSB_OPERATIONCOUNT:-1600000}"
  local fieldlength="${YCSB_FIELDLENGTH:-4096}"
  local fieldcount="${YCSB_FIELDCOUNT:-10}"
  local threads="${YCSB_THREADS:-${OMP_THREADS}}"
  local heap="${YCSB_HEAP:-4g}"
  local workload="${YCSB_WORKLOAD:-workloadc}"

  log "rocksdb ycsb load: records=${records} fieldcount=${fieldcount} fieldlength=${fieldlength}"
  "${ycsb}" load rocksdb -s -P "${BENCHMARK_DIR}/ycsb-rocksdb/workloads/${workload}" \
    -threads "${threads}" -jvm-args="-Xmx${heap}" \
    -p "rocksdb.dir=${dbdir}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=uniform"

  log "rocksdb ycsb run: ops=${ops}"
  "${ycsb}" run rocksdb -s -P "${BENCHMARK_DIR}/ycsb-rocksdb/workloads/${workload}" \
    -threads "${threads}" -jvm-args="-Xmx${heap}" \
    -p "rocksdb.dir=${dbdir}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=uniform"
}

run_memcached_ycsb_uniform() {
  trap stop_memcached EXIT
  java_env
  start_memcached
  local ycsb
  ycsb="$(ycsb_bin memcached)"

  local records="${YCSB_RECORDCOUNT:-800000}"
  local ops="${YCSB_OPERATIONCOUNT:-1600000}"
  local fieldlength="${YCSB_FIELDLENGTH:-4096}"
  local fieldcount="${YCSB_FIELDCOUNT:-10}"
  local threads="${YCSB_THREADS:-${OMP_THREADS}}"
  local heap="${YCSB_HEAP:-4g}"
  local workload="${YCSB_WORKLOAD:-workloada}"

  log "memcached ycsb load: mem=${MEMCACHED_MEMORY_MB}MB records=${records}"
  "${ycsb}" load memcached -s -P "${BENCHMARK_DIR}/ycsb-memcached/workloads/${workload}" \
    -threads "${threads}" -jvm-args="-Xmx${heap}" \
    -p "memcached.hosts=127.0.0.1:${MEMCACHED_PORT}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=uniform"

  log "memcached ycsb run: ops=${ops}"
  "${ycsb}" run memcached -s -P "${BENCHMARK_DIR}/ycsb-memcached/workloads/${workload}" \
    -threads "${threads}" -jvm-args="-Xmx${heap}" \
    -p "memcached.hosts=127.0.0.1:${MEMCACHED_PORT}" \
    -p "recordcount=${records}" -p "operationcount=${ops}" \
    -p "fieldcount=${fieldcount}" -p "fieldlength=${fieldlength}" \
    -p "requestdistribution=uniform"
}

run_faster() {
  local mix="$1"
  local dotnet="${TOOLS_DIR}/dotnet7/dotnet"
  local dll="${BENCHMARK_DIR}/FASTER/cs/benchmark/bin/x64/Release/net7.0/FASTER.benchmark.dll"
  need_exec "${dotnet}"
  need_file "${dll}"
  export DOTNET_ROOT="${TOOLS_DIR}/dotnet7"
  export PATH="${DOTNET_ROOT}:${PATH}"
  "${dotnet}" "${dll}" \
    --benchmark "${FASTER_BENCHMARK:-1}" \
    --threads "${FASTER_THREADS:-${OMP_THREADS}}" \
    --iterations "${FASTER_ITERATIONS:-1}" \
    --distribution "${FASTER_DISTRIBUTION:-uniform}" \
    --synth \
    --runsec "${FASTER_RUNSEC:-180}" \
    --rumd "${mix}" \
    ${FASTER_EXTRA_ARGS:-}
}

run_dlrm_synth() {
  local py="${TOOLS_DIR}/dlrm-venv/bin/python"
  local app="${BENCHMARK_DIR}/DLRM/dlrm_s_pytorch.py"
  need_exec "${py}"
  need_file "${app}"
  export PYTHONPATH="${TOOLS_DIR}/dlrm-venv/lib/python3.10/site-packages:${PYTHONPATH:-}"
  local tables="${DLRM_TABLES:-8}"
  local rows="${DLRM_ROWS_PER_TABLE:-22000000}"
  local emb
  emb="$("${py}" - <<PY
tables = int("${tables}")
rows = int("${rows}")
print("-".join([str(rows)] * tables))
PY
)"
  cd "${BENCHMARK_DIR}/DLRM"
  "${py}" "${app}" \
    --mini-batch-size="${DLRM_MINI_BATCH:-16}" \
    --num-batches="${DLRM_NUM_BATCHES:-1}" \
    --nepochs="${DLRM_EPOCHS:-1}" \
    --test-freq=0 \
    --data-generation=random \
    --arch-embedding-size="${emb}" \
    --arch-sparse-feature-size="${DLRM_SPARSE_FEATURE:-64}" \
    --arch-mlp-bot="${DLRM_MLP_BOT:-13-512-64}" \
    --arch-mlp-top="${DLRM_MLP_TOP:-1024-1024-1024-1}" \
    --num-indices-per-lookup="${DLRM_INDICES_PER_LOOKUP:-100}" \
    --print-freq="${DLRM_PRINT_FREQ:-1}" \
    --print-time
}

run_npb() {
  local name="$1"
  local bin="${BENCHMARK_DIR}/NPB3.4.3/NPB3.4-OMP/bin/${name}.D.x"
  need_exec "${bin}"
  "${bin}"
}

run_spec_bwaves() {
  local dir="${BENCHMARK_DIR}/spec/603.bwaves_s/run/run_base_refspeed_mytest-m64.0000"
  need_exec "${dir}/speed_bwaves_base.mytest-m64"
  need_file "${dir}/bwaves_1.in"
  need_file "${dir}/bwaves_2.in"
  cd "${dir}"
  ./speed_bwaves_base.mytest-m64 bwaves_1 < bwaves_1.in
  ./speed_bwaves_base.mytest-m64 bwaves_2 < bwaves_2.in
}

run_spec_fotonik3d() {
  local dir="${BENCHMARK_DIR}/spec/649.fotonik3d_s"
  need_exec "${dir}/exe/fotonik3d_s_base.mytest-m64"
  if [[ ! -f "${dir}/run/yee.dat" && ! -f "${dir}/yee.dat" ]]; then
    echo "649.fotonik3d_s binary is staged, but SPEC ref input yee.dat is missing in this local tree" >&2
    exit 77
  fi
  cd "${dir}/run"
  ../exe/fotonik3d_s_base.mytest-m64
}

run_spec_roms() {
  local dir="${BENCHMARK_DIR}/spec/654.roms_s"
  need_exec "${dir}/exe/sroms_base.mytest-m64"
  if [[ ! -f "${dir}/run/ocean_benchmark3.in" || ! -f "${dir}/run/ROMS/External/varinfo.dat" ]]; then
    echo "654.roms_s binary is staged, but complete SPEC ref run directory is missing in this local tree" >&2
    exit 77
  fi
  cd "${dir}/run"
  ./sroms_base.mytest-m64 < ocean_benchmark3.in
}

generate_canneal_netlist() {
  local out="$1"
  local elems="${CANNEAL_ELEMENTS:-500000}"
  local grid_x="${CANNEAL_GRID_X:-1024}"
  local grid_y="${CANNEAL_GRID_Y:-1024}"
  local fanin="${CANNEAL_FANIN:-4}"
  if [[ -f "${out}" ]]; then
    return 0
  fi
  log "generating canneal netlist: elems=${elems} grid=${grid_x}x${grid_y} fanin=${fanin}"
  awk -v n="${elems}" -v x="${grid_x}" -v y="${grid_y}" -v fanin="${fanin}" '
    BEGIN {
      print n, x, y;
      for (i = 0; i < n; i++) {
        printf "n%d 1", i;
        for (j = 1; j <= fanin; j++) {
          printf " n%d", (i + j * 2654435761) % n;
        }
        print " END";
      }
    }
  ' > "${out}"
}

run_canneal_synth() {
  local bin="${BENCHMARK_DIR}/vmitosis-workloads/bin/bench_canneal_mt"
  local netlist="${WORKDIR}/canneal-${CANNEAL_ELEMENTS:-500000}.net"
  need_exec "${bin}"
  generate_canneal_netlist "${netlist}"
  "${bin}" \
    "${CANNEAL_THREADS:-${OMP_THREADS}}" \
    "${CANNEAL_SWAPS:-1000000}" \
    "${CANNEAL_TEMP:-2000}" \
    "${netlist}" \
    "${CANNEAL_STEPS:-1}"
}

unavailable() {
  echo "$1 is recognized but not locally runnable yet: $2" >&2
  exit 77
}

case "${WORKLOAD}" in
  redis_uniform) run_redis_uniform ;;
  redis_ycsb_a) run_redis_ycsb_a ;;
  rocksdb_ycsb_uniform) run_ycsb_rocksdb_uniform ;;
  memcached_ycsb_uniform) run_memcached_ycsb_uniform ;;
  faster_uniform) run_faster "${FASTER_RUMD:-100,0,0,0}" ;;
  faster_ycsb_a) run_faster "${FASTER_RUMD:-50,50,0,0}" ;;
  dlrm_synth) run_dlrm_synth ;;
  npb_cg) run_npb cg ;;
  npb_mg) run_npb mg ;;
  npb_ua) run_npb ua ;;
  spec_bwaves) run_spec_bwaves ;;
  spec_fotonik3d) run_spec_fotonik3d ;;
  spec_roms) run_spec_roms ;;
  canneal_synth) run_canneal_synth ;;
  hibench_repartition) unavailable "${WORKLOAD}" "Spark/Hadoop runtime is not staged by the lightweight default path" ;;
  hibench_sql_join) unavailable "${WORKLOAD}" "Spark/Hadoop runtime is not staged by the lightweight default path" ;;
  cloudsuite_data_caching) unavailable "${WORKLOAD}" "CloudSuite Docker image/dataset is not staged by the lightweight default path" ;;
  cloudsuite_web_search) unavailable "${WORKLOAD}" "Solr Docker image and 14GB index dataset are not staged by the lightweight default path" ;;
  cloudsuite_als) unavailable "${WORKLOAD}" "Spark runtime and MovieLens dataset are not staged by the lightweight default path" ;;
  duckdb_tpch) unavailable "${WORKLOAD}" "DuckDB binary/data are external; install/stage per run to avoid bloating the VM image" ;;
  clickbench) unavailable "${WORKLOAD}" "ClickBench data/engine are external; install/stage per run to avoid bloating the VM image" ;;
  hnsw_faiss) unavailable "${WORKLOAD}" "FAISS/hnswlib package and vector dataset are external; install/stage per run" ;;
  *)
    echo "unknown real-world workload: ${WORKLOAD}" >&2
    exit 2
    ;;
esac
