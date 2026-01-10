# ClapDB Standalone ClickBench

Run ClickBench benchmark on ClapDB standalone server.

## Prerequisites

- ClapDB built with `clapdb_standalone` target
- `psql` PostgreSQL client
- `wget`, `gzip` for downloading data

## Usage

```bash
# Set the path to your ClapDB build directory
export CLAPDB_BUILD_DIR=/path/to/clapdb/build.dev

# Run the full benchmark
./benchmark.sh
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAPDB_BUILD_DIR` | (required) | Path to ClapDB build directory |
| `DATA_DIR` | `/data/apps` | Directory for storing hits.tsv data |
| `CLAPDB_PORT` | `8888` | PostgreSQL protocol port |
| `CLAPDB_HOST` | `localhost` | Server host |
| `CLAPDB_DATABASE` | `clickbench` | Database name |

## Files

- `benchmark.sh` - Main script that downloads data, starts server, loads data, and runs queries
- `run.sh` - Executes benchmark queries and measures timing
- `create.sql` - Table schema for hits table
- `queries.sql` - 43 ClickBench benchmark queries

## Results

After running, results are saved to:
- `result.csv` - CSV format with query number, try number, and execution time
- `result.json` - JSON array format compatible with ClickBench website
