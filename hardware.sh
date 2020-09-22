#!/bin/bash -e

mkdir -p clickhouse-benchmark
pushd clickhouse-benchmark

TABLE="hits_100m_obfuscated"
DATASET="${TABLE}_v1.tar.xz"
QUERIES_FILE="queries.sql"
TRIES=3

FASTER_DOWNLOAD=wget
if command -v axel >/dev/null; then
    FASTER_DOWNLOAD=axel
fi

if [[ ! -f clickhouse ]]; then
    CPU=$(uname -m)
    if [[ ($CPU == x86_64) || ($CPU == amd64) ]]; then
        $FASTER_DOWNLOAD "https://clickhouse-builds.s3.yandex.net/0/e29c4c3cc47ab2a6c4516486c1b77d57e7d42643/clickhouse_build_check/gcc-10_relwithdebuginfo_none_bundled_unsplitted_disable_False_binary/clickhouse"
    elif [[ $CPU == aarch64 ]]; then
        $FASTER_DOWNLOAD "https://clickhouse-builds.s3.yandex.net/0/e29c4c3cc47ab2a6c4516486c1b77d57e7d42643/clickhouse_special_build_check/clang-10-aarch64_relwithdebuginfo_none_bundled_unsplitted_disable_False_binary/clickhouse"
    else
        echo "Unsupported CPU type: $CPU"
        exit 1
    fi
fi

chmod a+x clickhouse

if [[ ! -f $QUERIES_FILE ]]; then
    wget "https://raw.githubusercontent.com/ClickHouse/ClickHouse/master/benchmark/clickhouse/$QUERIES_FILE"
fi

if [[ ! -d data ]]; then
    if [[ ! -f $DATASET ]]; then
        $FASTER_DOWNLOAD "https://clickhouse-datasets.s3.yandex.net/hits/partitions/$DATASET"
    fi
    
    tar --strip-components=1 --directory=. -x -v -f $DATASET
fi

echo "Starting clickhouse-server"

./clickhouse server > server.log 2>&1 &
PID=$!

function finish {
    kill $PID
    wait
}
trap finish EXIT

echo "Waiting for clickhouse-server to start"

for i in {1..30}; do
    sleep 1
    ./clickhouse client --query "SELECT 'The dataset size is: ', count() FROM $TABLE" && break
    if [[ $i == 30 ]]; then exit 1; fi
done

echo
echo "Will perform benchmark. Results:"
echo

cat "$QUERIES_FILE" | sed "s/{table}/${TABLE}/g" | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(./clickhouse client --max_memory_usage 100000000000 --time --format=Null --query="$query" 2>&1)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
    done
    echo "],"
done


echo
echo "Benchmark complete. System info:"

echo '----version and build id--------'
./clickhouse local --query "SELECT version(), buildId()"
echo '----CPU-------------------------'
lscpu
echo '----Block Devices---------------'
lsblk
echo '----Disk Free and Total--------'
df -h .
echo '----Memory Free and Total-------'
free -h
echo '----Physical Memory Amount------'
cat /proc/meminfo | grep MemTotal
echo '----RAID Info-------------------'
cat /proc/mdstat
#echo '----PCI-------------------------'
#lspci
#echo '----All Hardware Info-----------'
#lshw
echo '--------------------------------'

echo