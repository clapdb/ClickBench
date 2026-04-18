#!/bin/bash

TRIES=3

CLAPDB_PORT="${CLAPDB_PORT:-8888}"
CLAPDB_HOST="${CLAPDB_HOST:-localhost}"
CLAPDB_DATABASE="${CLAPDB_DATABASE:-clickbench}"
USERNAME="${USERNAME:-admin}"
PASSWORD="${PASSWORD:-admin}"

export PGPASSWORD="$PASSWORD"

# Fail fast if \`bc\` isn't installed: we use it to normalise psql's \timing
# output to seconds and silent \`null\` rows would otherwise be the only
# signal that it's missing.
if ! command -v bc >/dev/null 2>&1; then
    echo "Error: 'bc' is required for timing normalisation but was not found on PATH." >&2
    echo "Install bc (e.g. 'apt-get install bc' or 'dnf install bc') and retry." >&2
    exit 1
fi

QUERY_NUM=1
echo "query_num,try,execution_time" > result.csv

while read -r query; do
    # Skip empty lines and comments
    [[ -z "$query" || "$query" =~ ^[[:space:]]*-- ]] && continue

    echo -n "["
    for i in $(seq 1 $TRIES); do
        # Run query and extract timing. We only keep psql's \timing output
        # ("Time: <n> ms|s"); wall-clock fallback was intentionally removed
        # in an earlier revision because it conflated connection overhead
        # and, worse, masked dead-server retries as legitimate timings.
        # -X skips ~/.psqlrc for reproducibility; -v ON_ERROR_STOP=1 makes
        # server-side SQL errors surface as a non-zero psql exit status so
        # we don't have to scrape OUTPUT for "ERROR"/"FATAL" substrings
        # (which can also appear inside legitimate result rows).
        OUTPUT=$(psql -X -v ON_ERROR_STOP=1 \
            -h "$CLAPDB_HOST" -p "$CLAPDB_PORT" -U "$USERNAME" -d "$CLAPDB_DATABASE" \
            -c "\\timing" -c "$query" 2>&1)
        PSQL_STATUS=$?

        RES=""
        if [[ $PSQL_STATUS -eq 0 ]]; then
            # psql \timing prints either "Time: <n> ms" or "Time: <n> s".
            # grep -oE + sed keeps this portable (avoids PCRE \K, which needs
            # -P and isn't available on BusyBox grep).
            TIMING_LINE=$(echo "$OUTPUT" \
                | grep -oE 'Time: [0-9]+(\.[0-9]+)? (ms|s)' \
                | tail -1)
            if [[ -n "$TIMING_LINE" ]]; then
                TIME_VALUE=$(echo "$TIMING_LINE" \
                    | sed -E 's/^Time: ([0-9]+(\.[0-9]+)?) (ms|s)$/\1/')
                TIME_UNIT=$(echo "$TIMING_LINE" \
                    | sed -E 's/^Time: ([0-9]+(\.[0-9]+)?) (ms|s)$/\3/')
                if [[ "$TIME_UNIT" == "ms" ]]; then
                    RES=$(echo "scale=3; $TIME_VALUE / 1000" | bc)
                else
                    RES=$(echo "scale=3; $TIME_VALUE / 1" | bc)
                fi
            fi
        fi

        if [[ $PSQL_STATUS -eq 0 && -n "$RES" ]]; then
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
