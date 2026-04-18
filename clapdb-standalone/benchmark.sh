#!/bin/bash
#
# ClickBench driver for ClapDB standalone (PostgreSQL wire protocol).
#
# `clapdb_standalone` auto-bootstraps an empty data directory on first startup
# (see --init-* flags), so no separate initdb step is needed.
#
# Required env:
#   CLAPDB_BUILD_DIR   e.g. /path/to/clapdb/out/release (must contain clapdb_standalone)
#
# Optional env:
#   DATA_DIR           Dir holding hits.tsv[.gz]          (default: /data/apps)
#   RUN_DIR            Working directory for data/logs    (default: ./.run)
#   CLEAN_RUN_DIR      Set to 1 to wipe RUN_DIR before    (default: 0)
#                      launch (forces a full reload)
#   CLAPDB_BIND_ADDRESS  Server --address (bind)          (default: 127.0.0.1)
#   CLAPDB_HOST          psql -h (client connect)         (default: 127.0.0.1)
#   CLAPDB_PORT          PostgreSQL wire port             (default: 8888)
#   CLAPDB_DATABASE      Database name (--init-database)  (default: clickbench)
#   CLAPDB_TENANT        Tenant name (--init-tenant)      (default: default)
#   CLAPDB_USER          Superuser name (--init-user)     (default: admin)
#   CLAPDB_PASSWORD      Superuser password (--init-password) (default: admin)
#   CLAPDB_CPUSET        seastar --cpuset                 (default: 0-3)
#   CLAPDB_MEMORY        seastar --memory                 (default: 16G)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Configuration ──────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/data/apps}"
CLAPDB_HOST="${CLAPDB_HOST:-127.0.0.1}"
# Bind address for the server — defaults to CLAPDB_HOST so the simple local
# case Just Works. Override with 0.0.0.0 (or an NIC address) when you want
# the server reachable from other hosts; psql will still connect via
# CLAPDB_HOST, so set that to a routable address in that case too.
CLAPDB_BIND_ADDRESS="${CLAPDB_BIND_ADDRESS:-$CLAPDB_HOST}"
CLAPDB_PORT="${CLAPDB_PORT:-8888}"
CLAPDB_DATABASE="${CLAPDB_DATABASE:-clickbench}"
CLAPDB_TENANT="${CLAPDB_TENANT:-default}"
CLAPDB_USER="${CLAPDB_USER:-admin}"
CLAPDB_PASSWORD="${CLAPDB_PASSWORD:-admin}"
CLAPDB_CPUSET="${CLAPDB_CPUSET:-0-3}"
CLAPDB_MEMORY="${CLAPDB_MEMORY:-16G}"
RUN_DIR="${RUN_DIR:-${SCRIPT_DIR}/.run}"

CLAPDB_BUILD_DIR="${CLAPDB_BUILD_DIR:-}"
if [[ -z "$CLAPDB_BUILD_DIR" ]]; then
    echo "Error: CLAPDB_BUILD_DIR must be set." >&2
    echo "Example: CLAPDB_BUILD_DIR=/path/to/clapdb/out/release $0" >&2
    exit 1
fi

CLAPDB_STANDALONE="${CLAPDB_BUILD_DIR}/clapdb_standalone"
if [[ ! -x "$CLAPDB_STANDALONE" ]]; then
    echo "Error: missing binary $CLAPDB_STANDALONE" >&2
    echo "Build it from the clapdb source tree:" >&2
    echo "  ./build.sh release -t clapdb_standalone" >&2
    exit 1
fi

mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"

# ── Download / decompress data ────────────────────────────────
HITS_TSV_GZ="${DATA_DIR}/hits.tsv.gz"
HITS_TSV="${DATA_DIR}/hits.tsv"
if [[ ! -f "$HITS_TSV" ]]; then
    if [[ ! -f "$HITS_TSV_GZ" ]]; then
        echo "Downloading hits.tsv.gz..."
        mkdir -p "$DATA_DIR"
        wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz' -O "$HITS_TSV_GZ"
    fi
    echo "Decompressing hits.tsv.gz..."
    if command -v pv >/dev/null 2>&1; then
        pv -cN source "$HITS_TSV_GZ" | gzip -d > "$HITS_TSV"
    else
        gzip -dc "$HITS_TSV_GZ" > "$HITS_TSV"
    fi
fi

# ── Write a local config + clean data dirs ────────────────────
STDB_TOML="${RUN_DIR}/stdb.toml"
cat > "$STDB_TOML" <<EOF
[aws.credentials]
access_key_id = ""
secret_key = ""
region = ""
[aws.s3]
endpoint = "http://127.0.0.1:9000"
[hardy.ssl]
ssl_enable = false
[clapdb_standalone]
servers = ["hardy"]
timezone = "UTC"
[segment]
segment_rawdata_size = 268435456
segment_rawdata_nrows = 1000000
[euler]
mode = "single"
wal_dir = "${RUN_DIR}/WAL_ROOT"
[storage]
type = "file"
file.fst_root = "${RUN_DIR}/FST_ROOT"
file.schema_root = "${RUN_DIR}/SCHEMA_ROOT"
file.segment_root = "${RUN_DIR}/SEGMENT_ROOT"
file.del_marker_root = "${RUN_DIR}/DEL_MARKER_ROOT"
coldcache.enable = false
[shannon]
port = 0
[gauss]
port = 0
EOF

# Opt-in full wipe: set CLEAN_RUN_DIR=1 to force a fresh load. Default is to
# keep existing data so reruns against the same RUN_DIR skip the COPY and just
# re-run the query suite.
if [[ "${CLEAN_RUN_DIR:-0}" == "1" ]]; then
    echo "CLEAN_RUN_DIR=1: wiping previous data roots under ${RUN_DIR}..."
    rm -rf \
        "${RUN_DIR}/SCHEMA_ROOT" \
        "${RUN_DIR}/FST_ROOT" \
        "${RUN_DIR}/SEGMENT_ROOT" \
        "${RUN_DIR}/DEL_MARKER_ROOT" \
        "${RUN_DIR}/WAL_ROOT" \
        "${RUN_DIR}/.hits_loaded"
fi

# ── Start server (auto-bootstraps the empty data dir via --init-*) ─
SERVER_PID=""
SERVER_LOG="${RUN_DIR}/clapdb_standalone.log"

start_server() {
    # --init-* flags are applied only on first launch: clapdb_standalone checks
    # tenant.json before running the bootstrap path, so passing them every time
    # is idempotent (no-op once the data dir exists).
    local init_args=(--init-tenant "$CLAPDB_TENANT"
                     --init-database "$CLAPDB_DATABASE"
                     --init-user "$CLAPDB_USER"
                     --init-password "$CLAPDB_PASSWORD")
    echo "Starting clapdb_standalone (log: $SERVER_LOG)..."
    "$CLAPDB_STANDALONE" \
        --config "$STDB_TOML" \
        --cpuset "$CLAPDB_CPUSET" \
        --memory "$CLAPDB_MEMORY" \
        --address "$CLAPDB_BIND_ADDRESS" \
        --port "$CLAPDB_PORT" \
        "${init_args[@]}" \
        >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    sleep 2
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Error: clapdb_standalone failed to start. See $SERVER_LOG" >&2
        tail -40 "$SERVER_LOG" >&2 || true
        exit 1
    fi
}

stop_server() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        local shutdown_timeout=10
        local waited=0
        echo "Stopping clapdb_standalone (pid $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
        # Bounded wait: if the server ignores SIGTERM, escalate to SIGKILL so
        # neither the benchmark nor the EXIT trap can hang indefinitely.
        while kill -0 "$SERVER_PID" 2>/dev/null; do
            if (( waited >= shutdown_timeout )); then
                echo "Warning: clapdb_standalone (pid $SERVER_PID) did not stop within ${shutdown_timeout}s; sending SIGKILL." >&2
                kill -9 "$SERVER_PID" 2>/dev/null || true
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    SERVER_PID=""
}
trap stop_server EXIT

start_server

export PGPASSWORD="$CLAPDB_PASSWORD"
PSQL=(psql -h "$CLAPDB_HOST" -p "$CLAPDB_PORT" -U "$CLAPDB_USER" -d "$CLAPDB_DATABASE")

echo "Waiting for server to be ready..."
for _ in $(seq 1 60); do
    if "${PSQL[@]}" -c "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
"${PSQL[@]}" -c "SELECT 1" >/dev/null

# ── Create table + load data ──────────────────────────────────
# Reuse existing data only when (a) the `hits` table is present in the catalog
# AND (b) a local completion marker shows the last load actually finished.
# Probing pg_tables is an O(1) catalog lookup (no row scan, no cache warming
# before the cold-cache restart below). Table presence alone is insufficient:
# a prior run may have created `hits` and then died mid-COPY, leaving the
# table empty/partial.
HITS_LOAD_MARKER="${RUN_DIR}/.hits_loaded"
table_exists=$("${PSQL[@]}" -tAXc \
    "SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'hits' LIMIT 1;" 2>/dev/null || echo "")
if [[ -n "$table_exists" && -f "$HITS_LOAD_MARKER" ]]; then
    echo "Reusing existing hits table; set CLEAN_RUN_DIR=1 to force reload."
else
    rm -f "$HITS_LOAD_MARKER"

    if [[ -n "$table_exists" ]]; then
        echo "Found hits table without a successful-load marker; dropping and reloading..."
        "${PSQL[@]}" -c "DROP TABLE IF EXISTS public.hits;"
    fi
    echo "Creating hits table and loading $HITS_TSV (this takes a while for 100M rows)..."
    # Use client-side \copy so HITS_TSV is read by the local psql process
    # running this benchmark script. Run create.sql and \copy in the same
    # psql invocation under --single-transaction so a failed load does not
    # leave a half-populated `hits` behind. -v ON_ERROR_STOP=1 + -X make
    # SQL errors surface as a non-zero exit status (and ignore ~/.psqlrc
    # for reproducibility), so a failed/partial load can never write the
    # success marker. psql variable substitution does not expand inside
    # \copy, so interpolate the path at the shell level. Use PostgreSQL
    # text format (default) to match the ClickBench TSV layout: it honours
    # \N as NULL and avoids the CSV quoting/escape differences that other
    # Postgres-wire drivers in this repo already side-step.
    if time "${PSQL[@]}" -X -v ON_ERROR_STOP=1 --single-transaction \
        -f "${SCRIPT_DIR}/create.sql" \
        -c "\\copy hits FROM '${HITS_TSV}' WITH (FORMAT text, DELIMITER E'\t');"; then
        : > "$HITS_LOAD_MARKER"
    else
        echo "Error: failed to create or load public.hits; not writing success marker." >&2
        exit 1
    fi
fi

# ── Restart for cold cache ────────────────────────────────────
# Intentionally no COUNT(*) before restart — it warms caches and defeats the
# cold-cache benchmark. If you want a row count, run it yourself after.
echo "Restarting server for cold-cache benchmark..."
stop_server
sleep 2
start_server
for _ in $(seq 1 60); do
    "${PSQL[@]}" -c "SELECT 1" >/dev/null 2>&1 && break
    sleep 1
done
if ! "${PSQL[@]}" -c "SELECT 1" >/dev/null 2>&1; then
    echo "Error: server did not become ready after cold-cache restart. See $SERVER_LOG" >&2
    tail -40 "$SERVER_LOG" >&2 || true
    exit 1
fi

# ── Run queries ───────────────────────────────────────────────
echo "Running benchmark queries..."
CLAPDB_PORT="$CLAPDB_PORT" \
CLAPDB_HOST="$CLAPDB_HOST" \
CLAPDB_DATABASE="$CLAPDB_DATABASE" \
USERNAME="$CLAPDB_USER" \
PASSWORD="$CLAPDB_PASSWORD" \
    "${SCRIPT_DIR}/run.sh" 2>&1 | tee "${SCRIPT_DIR}/result.txt"

# ── Build JSON array from the bracketed per-query rows ────────
if [[ -f "${SCRIPT_DIR}/result.txt" ]]; then
    grep -E '^\[' "${SCRIPT_DIR}/result.txt" \
        | sed 's/,$//' \
        | tr '\n' ',' \
        | sed 's/,$//' \
        | sed 's/^/[/' \
        | sed 's/$/]/' > "${SCRIPT_DIR}/result.json"
    echo ""
    echo "Results: ${SCRIPT_DIR}/result.{csv,txt,json}"
fi

echo "Benchmark completed!"
