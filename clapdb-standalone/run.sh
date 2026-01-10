#!/bin/bash

TRIES=3

CLAPDB_PORT="${CLAPDB_PORT:-8888}"
CLAPDB_HOST="${CLAPDB_HOST:-localhost}"
CLAPDB_DATABASE="${CLAPDB_DATABASE:-clickbench}"
USERNAME="${USERNAME:-admin}"
PASSWORD="${PASSWORD:-admin}"

export PGPASSWORD="$PASSWORD"

QUERY_NUM=1
echo "query_num,try,execution_time" > result.csv

while read -r query; do
    # Skip empty lines and comments
    [[ -z "$query" || "$query" =~ ^[[:space:]]*-- ]] && continue

    echo -n "["
    for i in $(seq 1 $TRIES); do
        # Run query and extract timing
        # psql with \timing returns "Time: XXX.XXX ms"
        START_TIME=$(date +%s.%N)
        OUTPUT=$(psql -h "$CLAPDB_HOST" -p "$CLAPDB_PORT" -U "$USERNAME" -d "$CLAPDB_DATABASE" \
            -c "\\timing" -c "$query" 2>&1)
        END_TIME=$(date +%s.%N)

        # Try to extract time from psql output
        TIME_MS=$(echo "$OUTPUT" | grep -oP 'Time: \K[0-9.]+' | tail -1)

        if [[ -n "$TIME_MS" ]]; then
            # Convert ms to seconds
            RES=$(echo "scale=3; $TIME_MS / 1000" | bc)
        else
            # Fallback: calculate from wall clock time
            RES=$(echo "scale=3; $END_TIME - $START_TIME" | bc)
        fi

        if [[ -n "$RES" && "$OUTPUT" != *"ERROR"* ]]; then
            echo -n "${RES}"
            echo "${QUERY_NUM},${i},${RES}" >> result.csv
        else
            echo -n "null"
            echo "${QUERY_NUM},${i},null" >> result.csv
        fi
        [[ "$i" != "$TRIES" ]] && echo -n ", "
    done
    echo "],"
    QUERY_NUM=$((QUERY_NUM + 1))
done < queries.sql
