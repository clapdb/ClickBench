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
        "${RUN_DIR}/WAL_ROOT"
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
        echo "Stopping clapdb_standalone (pid $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
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
# Skip create/load on reruns: if hits already exists with data, reuse it.
existing_rows=$("${PSQL[@]}" -tAXc \
    "SELECT COALESCE((SELECT COUNT(*) FROM hits), 0);" 2>/dev/null || echo "")
if [[ -z "$existing_rows" || "$existing_rows" == "0" ]]; then
    echo "Creating hits table..."
    "${PSQL[@]}" -f "${SCRIPT_DIR}/create.sql"

    echo "Loading $HITS_TSV (this takes a while for 100M rows)..."
    # Use client-side \copy so HITS_TSV is read by the local psql process
    # running this benchmark script. psql variable substitution does not
    # expand inside \copy, so interpolate the path at the shell level.
    # Use PostgreSQL text format (default) to match the ClickBench TSV
    # layout: it honours \N as NULL and avoids the CSV
    # quoting/escape differences that other Postgres-wire drivers in this
    # repo already side-step.
    time "${PSQL[@]}" -c "\\copy hits FROM '${HITS_TSV}' WITH (FORMAT text, DELIMITER E'\t');"
else
    echo "Reusing existing hits table ($existing_rows rows); set CLEAN_RUN_DIR=1 to force reload."
fi

echo "Row count:"
"${PSQL[@]}" -c "SELECT COUNT(*) FROM hits;"

# ── Restart for cold cache ────────────────────────────────────
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
