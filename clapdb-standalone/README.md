# ClapDB Standalone ClickBench

Run the ClickBench benchmark against a ClapDB standalone server.

## Prerequisites

- ClapDB built with the `clapdb_standalone` target (release mode recommended); the server auto-bootstraps an empty data directory on first launch, so no separate `clapdb_initdb` step is required
- `psql` PostgreSQL client
- `wget`, `gzip` for downloading the dataset

## Build ClapDB

From the ClapDB source tree:

```bash
./build.sh release -t clapdb_standalone
```

Binary lands at `out/release/clapdb_standalone`.

## Usage

```bash
# Point to the directory that contains clapdb_standalone
export CLAPDB_BUILD_DIR=/path/to/clapdb/out/release

./benchmark.sh
```

Reruns against the same `RUN_DIR` reuse the previously loaded `hits` table. Pass `CLEAN_RUN_DIR=1 ./benchmark.sh` to force a full wipe + reload.

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAPDB_BUILD_DIR` | (required) | Directory containing the `clapdb_standalone` binary |
| `DATA_DIR` | `/data/apps` | Directory where `hits.tsv[.gz]` is stored |
| `RUN_DIR` | `./.run` | Scratch directory for config, data roots, logs |
| `CLEAN_RUN_DIR` | `0` | Set to `1` to wipe `RUN_DIR` data roots before launch |
| `CLAPDB_HOST` | `127.0.0.1` | Server bind / connect host |
| `CLAPDB_PORT` | `8888` | PostgreSQL wire port |
| `CLAPDB_DATABASE` | `clickbench` | Database name (forwarded as `--init-database`) |
| `CLAPDB_TENANT` | `default` | Tenant name (forwarded as `--init-tenant`) |
| `CLAPDB_USER` | `admin` | Superuser name (forwarded as `--init-user`) |
| `CLAPDB_PASSWORD` | `admin` | Superuser password (forwarded as `--init-password`) |
| `CLAPDB_CPUSET` | `0-3` | Seastar `--cpuset` |
| `CLAPDB_MEMORY` | `16G` | Seastar `--memory` |

## Files

- `benchmark.sh` - Downloads data, starts the server with `--init-*` auto-bootstrap, loads data via `psql \copy`, and runs queries
- `run.sh` - Executes benchmark queries and records timing
- `create.sql` - Schema for the `hits` table
- `queries.sql` - 43 ClickBench benchmark queries

## Results

After running, results are saved alongside the scripts:

- `result.csv` - CSV format with query number, try number, and execution time
- `result.txt` - Raw per-query bracketed rows (one per query)
- `result.json` - JSON array format compatible with the ClickBench website
