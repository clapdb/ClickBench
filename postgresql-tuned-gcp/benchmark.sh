#!/bin/bash

# cd /tmp && sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/F-41-x86_64/pgdg-fedora-repo-latest.noarch.rpm
# sudo dnf install -y postgresql17-server
# sudo /usr/pgsql-17/bin/postgresql-17-setup initdb
# sudo dnf install postgresql17-contrib


# mkdir ./pgdata
# chown postgres:postgres ./pgdata
# chmod 700 ./pgdata
# sudo echo "data_directory = '$PWD/pgdata/data'" >> ./pgdata/data/postgresql.conf
# sudo sed -i -e '
#     s/shared_buffers = 128MB/shared_buffers = 8GB/;
#     s/#max_parallel_workers = 8/max_parallel_workers=16/;
#     s/#max_parallel_workers_per_gather = 2/max_parallel_workers_per_gather = 8/;
#     s/max_wal_size = 1GB/max_wal_size=32GB/;
# ' ./pgdata/data/postgresql.conf
# sudo vim /lib/systemd/system/postgresql-17.service 
# >> Environment=PGDATA=/data/apps/ClickBench/postgresql-tuned-gcp/pgdata/data
# sudo systemctl daemon-reload
# sudo systemctl enable --now postgresql-17

sudo -u postgres psql -t -c 'CREATE DATABASE test'
sudo -u postgres psql test -t < create.sql
sudo -u postgres psql test -t -c '\timing' -c "truncate table hits; copy hits FROM '/data/apps/hits.tsv' with freeze"

sudo -u postgres psql test -t -c 'CREATE EXTENSION pg_trgm;'
time sudo -u postgres psql test -t < index.sql

sudo -u postgres psql test -t -c 'VACUUM ANALYZE hits'

# COPY 99997497
# Time: 2341543.463 ms (39:01.543)

sudo -u postgres psql test -c 'select count(*) from hits'

./run.sh 2>&1 | tee log.txt

# sudo du -bcs /var/lib/postgresql/14/main/

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }' | tee result.txt

truncate -s -2 result.txt && jq -R -s 'split("\n")' result.txt | sed 's/,\"//g' | sed 's/\"//g' > result.array
array=$(<result.array)
time=$(date +"%F %T")
jq --argjson value "$array" --arg date "$time" --arg machine "$MACHINE" '.result = $value | .machine = $machine | .date = $date' results/c4-highcpu-32.json > result.json
# rm result.txt result.array