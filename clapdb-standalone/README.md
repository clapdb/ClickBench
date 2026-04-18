# ClapDB Standalone ClickBench

Run the ClickBench benchmark against a ClapDB standalone server.

## Prerequisites

- ClapDB built with the `clapdb_standalone` and `clapdb_initdb` targets (release mode recommended)
- `psql` PostgreSQL client
- `wget`, `gzip` for downloading the dataset

## Build ClapDB

From the ClapDB source tree:

```bash
./build.sh release -t clapdb_standalone -t clapdb_initdb
```

Binaries land under `out/release/`.

## Usage

```bash
# Point to the directory that contains clapdb_standalone + clapdb_initdb
export CLAPDB_BUILD_DIR=/path/to/clapdb/out/release

./benchmark.sh
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAPDB_BUILD_DIR` | (required) | Directory containing `clapdb_standalone` + `clapdb_initdb` |
| `DATA_DIR` | `/data/apps` | Directory where `hits.tsv[.gz]` is stored |
| `RUN_DIR` | `./.run` | Scratch directory for config, data roots, logs |
| `CLAPDB_HOST` | `127.0.0.1` | Server bind / connect host |
| `CLAPDB_PORT` | `8888` | PostgreSQL wire port |
| `CLAPDB_DATABASE` | `clickbench` | Database name |
| `CLAPDB_TENANT` | `default` | Tenant name passed to `clapdb_initdb` |
| `CLAPDB_USER` | `admin` | Superuser name |
| `CLAPDB_PASSWORD` | `admin` | Superuser password |
| `CLAPDB_CPUSET` | `0-3` | Seastar `--cpuset` |
| `CLAPDB_MEMORY` | `16G` | Seastar `--memory` |

## Files

- `benchmark.sh` - Downloads data, runs `clapdb_initdb`, starts the server, loads data, and runs queries
- `run.sh` - Executes benchmark queries and records timing
- `create.sql` - Schema for the `hits` table
- `queries.sql` - 43 ClickBench benchmark queries

## Results

After running, results are saved alongside the scripts:

- `result.csv` - CSV format with query number, try number, and execution time
- `result.txt` - Raw per-query bracketed rows (one per query)
- `result.json` - JSON array format compatible with the ClickBench website
