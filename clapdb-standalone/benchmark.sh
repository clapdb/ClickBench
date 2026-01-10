#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
DATA_DIR="${DATA_DIR:-/data/apps}"
CLAPDB_PORT="${CLAPDB_PORT:-8888}"
CLAPDB_HOST="${CLAPDB_HOST:-localhost}"
CLAPDB_DATABASE="${CLAPDB_DATABASE:-clickbench}"

# Path to clapdb release build directory (set this or pass as env)
CLAPDB_BUILD_DIR="${CLAPDB_BUILD_DIR:-}"

if [[ -z "$CLAPDB_BUILD_DIR" ]]; then
    echo "Error: CLAPDB_BUILD_DIR must be set to the clapdb release build directory"
    echo "Example: CLAPDB_BUILD_DIR=/path/to/clapdb/build.release ./benchmark.sh"
    exit 1
fi

# Download data
HITS_TSV_GZ="${DATA_DIR}/hits.tsv.gz"
if [[ ! -f "$HITS_TSV_GZ" ]]; then
    echo "Downloading hits.tsv.gz..."
    mkdir -p "$DATA_DIR"
    wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz' -O "$HITS_TSV_GZ"
fi

HITS_TSV="${DATA_DIR}/hits.tsv"
if [[ ! -f "$HITS_TSV" ]]; then
    echo "Decompressing hits.tsv.gz..."
    if command -v pv &> /dev/null; then
        pv -cN source "$HITS_TSV_GZ" | gzip -d > "$HITS_TSV"
    else
        gzip -dc "$HITS_TSV_GZ" > "$HITS_TSV"
    fi
fi

# Copy necessary files
cp "${CLAPDB_BUILD_DIR}/clapdb_standalone/createdb" .
cp "${CLAPDB_BUILD_DIR}/clapdb_standalone/clapdb_standalone" .

# Find stdb.toml - check multiple locations
if [[ -f "${CLAPDB_BUILD_DIR}/../stdb.toml" ]]; then
    cp "${CLAPDB_BUILD_DIR}/../stdb.toml" .
elif [[ -f "${CLAPDB_BUILD_DIR}/stdb.toml" ]]; then
    cp "${CLAPDB_BUILD_DIR}/stdb.toml" .
else
    echo "Error: Cannot find stdb.toml"
    exit 1
fi

# Clean up previous data directories
rm -rf SCHEMA_ROOT FST_ROOT SEGMENT_ROOT DTID_ROOT

# Create database
TENANT="benchmark"
DATABASE="$CLAPDB_DATABASE"
USERNAME="admin"
PASSWORD="admin"

echo "Creating database..."
./createdb --config stdb.toml --tenant "$TENANT" --database "$DATABASE" --user "$USERNAME" --passwd "$PASSWORD"

# Start clapdb_standalone server
echo "Starting clapdb_standalone server..."
./clapdb_standalone --config ./stdb.toml --port "$CLAPDB_PORT" &>/dev/null &
CLAPDB_PID=$!
sleep 3

# Check if server started
if ! kill -0 $CLAPDB_PID 2>/dev/null; then
    echo "Error: clapdb_standalone failed to start"
    exit 1
fi

# Cleanup function
cleanup() {
    echo "Stopping clapdb_standalone..."
    kill $CLAPDB_PID 2>/dev/null || true
    wait $CLAPDB_PID 2>/dev/null || true
}
trap cleanup EXIT

# Connection string for psql
export PGPASSWORD="$PASSWORD"
PSQL_CMD="psql -h $CLAPDB_HOST -p $CLAPDB_PORT -U $USERNAME -d $DATABASE"

# Wait for server to be ready
echo "Waiting for server to be ready..."
for i in {1..30}; do
    if $PSQL_CMD -c "SELECT 1" &>/dev/null; then
        echo "Server is ready"
        break
    fi
    sleep 1
done

# Create table
echo "Creating hits table..."
$PSQL_CMD -f create.sql

# Load data using server-side COPY (server reads the file directly)
echo "Loading data from $HITS_TSV..."
echo "This may take several minutes for 100M rows..."
time $PSQL_CMD -c "COPY hits FROM '$HITS_TSV' DELIMITER E'\t' CSV;"

# Verify data loaded
echo "Verifying data..."
$PSQL_CMD -c "SELECT COUNT(*) FROM hits;"

# Stop and restart for cold cache benchmark
echo "Restarting server for benchmark..."
kill $CLAPDB_PID 2>/dev/null || true
wait $CLAPDB_PID 2>/dev/null || true
sleep 2

./clapdb_standalone --config ./stdb.toml --port "$CLAPDB_PORT" &>/dev/null &
CLAPDB_PID=$!
sleep 2

# Run the benchmark queries
echo "Running benchmark queries..."
CLAPDB_PORT=$CLAPDB_PORT CLAPDB_HOST=$CLAPDB_HOST CLAPDB_DATABASE=$CLAPDB_DATABASE \
    USERNAME=$USERNAME PASSWORD=$PASSWORD \
    ./run.sh 2>&1 | tee result.txt

# Process results
if [[ -f result.txt ]]; then
    # Remove trailing comma and newline, convert to JSON array
    sed 's/,$//' result.txt | tr '\n' ',' | sed 's/,$//' | sed 's/^/[/' | sed 's/$/]/' > result.json
    echo ""
    echo "Results saved to result.json"
fi

echo "Benchmark completed!"
