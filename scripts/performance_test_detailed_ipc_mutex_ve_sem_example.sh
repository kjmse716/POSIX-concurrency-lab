#!/bin/bash

# ==============================================================================
# Detailed IPC Mutex vs Semaphore Performance Test Script
# (Based on v2.4 - Affinity & Full Metrics)
#
# 目的：
# 專門比較「Mutex+Cond」與「Semaphore」兩種 IPC 機制在綁核環境下的詳細效能差異。
#
# 功能：
# 1. 精確計時：執行多次取平均 (Phase 1)。
# 2. 硬體計數：自動解析 perf stat (Cache Misses, Context Switches, etc.)。
# 3. 系統呼叫：自動解析 strace (Futex Calls)。
# 4. 完整報告：生成 perf.data, perf report (txt), flamegraph (svg)。
# 5. 整合輸出：匯總於 CSV。
#
# 測試對象 (位於 src/04_performance_comparison/ipc_mutex_sem/):
# 1. Mutex+Cond: ipc_producer.c, ipc_consumer.c
# 2. Semaphore:  ipc_sem_producer.c, ipc_sem_consumer.c
#
# 用法:
# ./scripts/performance_test_detailed_ipc_mutex_vs_sem.sh [affinity_mode] [core_a] [core_b]
# ==============================================================================

# --- 0. 環境與安全設定 ---
export LC_NUMERIC=C
export FLAMEGRAPH_DIR="/home/kjmse716/Documents/Labs/POSIX-concurrency-lab/library/FlameGraph"

# 參數設定
NUM_RUNS=1
REST_INTERVAL_S=0.1
# 可以根據需求調整測試規模
PRODUCT_COUNTS=(100000)
BUFFER_SIZES=(1 10)
MESSAGE_LENS=(64)
PROFILING_MIN_PRODUCT_COUNT=1000

# 關鍵指標
PERF_EVENTS="cpu-clock,task-clock,context-switches,cpu-migrations,page-faults,L1-dcache-loads,L1-dcache-load-misses,L1-dcache-store-misses,cache-misses,LLC-loads,LLC-load-misses,LLC-store-misses"

# 路徑設定
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_mutex_sem"

# --- 定義原始碼與執行檔路徑 ---

# 1. Mutex + Cond 模型
MUTEX_PRODUCER_SRC="${SRC_DIR}/ipc_producer.c"
MUTEX_CONSUMER_SRC="${SRC_DIR}/ipc_consumer.c"
MUTEX_PRODUCER_EXE="${SCRIPT_DIR}/temp_mutex_producer"
MUTEX_CONSUMER_EXE="${SCRIPT_DIR}/temp_mutex_consumer"

# 2. Semaphore 模型
SEM_PRODUCER_SRC="${SRC_DIR}/ipc_sem_producer.c"
SEM_CONSUMER_SRC="${SRC_DIR}/ipc_sem_consumer.c"
SEM_PRODUCER_EXE="${SCRIPT_DIR}/temp_sem_producer"
SEM_CONSUMER_EXE="${SCRIPT_DIR}/temp_sem_consumer"

# FlameGraph 工具
STACKCOLLAPSE_SCRIPT="${FLAMEGRAPH_DIR}/stackcollapse-perf.pl"
FLAMEGRAPH_SCRIPT="${FLAMEGRAPH_DIR}/flamegraph.pl"

# --- 1. Affinity 解析 ---
AFFINITY_MODE="$1"
CORE_A="$2"
CORE_B="$3"

if [ -z "$AFFINITY_MODE" ]; then AFFINITY_MODE="unlimited"; fi

RESULTS_DIR="${SCRIPT_DIR}/results_detailed_ipc_compare_${AFFINITY_MODE}"
TIMING_CSV_FILE="${RESULTS_DIR}/timing_and_metrics.csv"

echo "===================================================="
echo ">> 模式: ${AFFINITY_MODE}"
echo ">> 比較: IPC (Mutex) vs IPC (Semaphore)"
echo ">> 結果目錄: ${RESULTS_DIR}"
echo "===================================================="

PRODUCER_CMD_PREFIX=""
CONSUMER_CMD_PREFIX=""
AFFINITY_COMPILE_FLAGS=""

case "$AFFINITY_MODE" in
    "rt-single-core")
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "rt-cross-core")
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_B}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
    "single-core")
        PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="taskset -c ${CORE_A}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "cross-core")
        PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="taskset -c ${CORE_B}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
    "unlimited")
        PRODUCER_CMD_PREFIX=""
        CONSUMER_CMD_PREFIX=""
        AFFINITY_COMPILE_FLAGS=""
        ;;
    *)
        echo "錯誤: 不支援的模式 '$AFFINITY_MODE'"
        exit 1
        ;;
esac

if [[ -n "$AFFINITY_COMPILE_FLAGS" ]]; then
    echo ">> 已啟用 C 語言層級綁核旗標: ${AFFINITY_COMPILE_FLAGS}"
fi

# --- Checks ---
if [[ $EUID -ne 0 ]]; then echo "!! 需要 root 權限。"; exit 1; fi
AUTO_FLAMEGRAPH=true
if [ ! -f "$STACKCOLLAPSE_SCRIPT" ]; then AUTO_FLAMEGRAPH=false; fi
mkdir -p "$RESULTS_DIR"

cleanup() {
    rm -f "$MUTEX_PRODUCER_EXE" "$MUTEX_CONSUMER_EXE" "$SEM_PRODUCER_EXE" "$SEM_CONSUMER_EXE"
}
trap cleanup EXIT
cleanup

# --- CSV Header ---
echo "TestType,ProductCount,BufferSize,MessageLen,AvgInitTime,AvgCommTime,L1_dcache_load_misses,L1_dcache_store_misses,LLC_load_misses,LLC_store_misses,Context_Switches,Futex_Calls" > "$TIMING_CSV_FILE"

# --- Helpers (安全增強版) ---
extract_perf_val() {
    local event="$1"
    local file="$2"
    local val=$(grep "$event" "$file" | awk '{print $1}' | sed 's/,//g')
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then echo "0"; else echo "$val"; fi
}

extract_strace_futex() {
    local file="$1"
    local val=$(grep "futex" "$file" | awk '{sum+=$4} END {print sum}')
    if [ -z "$val" ]; then echo "0"; else echo "$val"; fi
}

# --- Main Loop ---
for bsize in "${BUFFER_SIZES[@]}"; do
    for pcount in "${PRODUCT_COUNTS[@]}"; do
        for mlen in "${MESSAGE_LENS[@]}"; do
            TEST_CASE_TAG="P${pcount}_B${bsize}_M${mlen}"
            echo "----------------------------------------------------"
            echo ">> [Buffer: ${bsize}, Count: ${pcount}] 測試開始..."

            # =================================================
            # Test 1: IPC Mutex + Cond Model
            # =================================================
            MODEL_TYPE="IPC_Mutex"
            OUTPUT_PREFIX="${RESULTS_DIR}/${MODEL_TYPE}_${TEST_CASE_TAG}"

            echo "         [1/2] IPC Mutex Model: Compiling & Measuring..."
            
            # 1. 編譯
            gcc "${MUTEX_PRODUCER_SRC}" -o ${MUTEX_PRODUCER_EXE} -g -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
            gcc "${MUTEX_CONSUMER_SRC}" -o ${MUTEX_CONSUMER_EXE} -g -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
            if [ $? -ne 0 ]; then echo "!! IPC Mutex 編譯失敗"; continue; fi

            # 2. Phase 1: 計時 (Timing)
            total_init=0.0; total_comm=0.0
            for j in $(seq 1 ${NUM_RUNS}); do
                ${CONSUMER_CMD_PREFIX} ${MUTEX_CONSUMER_EXE} &
                consumer_pid=$!
                result=$( ${PRODUCER_CMD_PREFIX} ${MUTEX_PRODUCER_EXE} )
                wait $consumer_pid
                
                i_time=$(echo "$result" | cut -d',' -f1); c_time=$(echo "$result" | cut -d',' -f2)
                total_init=$(awk -v t1="$total_init" -v t2="$i_time" 'BEGIN{print t1+t2}')
                total_comm=$(awk -v t1="$total_comm" -v t2="$c_time" 'BEGIN{print t1+t2}')
                sleep ${REST_INTERVAL_S}
            done
            avg_init=$(awk -v t="$total_init" -v n="$NUM_RUNS" 'BEGIN{print t/n}')
            avg_comm=$(awk -v t="$total_comm" -v n="$NUM_RUNS" 'BEGIN{print t/n}')

            # 3. Phase 2: Perf & Strace (Metrics)
            # 注意：這裡使用 bash -c 同時啟動兩者來進行監測
            perf stat -e "$PERF_EVENTS" -o "${OUTPUT_PREFIX}_perf_stat.txt" \
                bash -c "${CONSUMER_CMD_PREFIX} ${MUTEX_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${MUTEX_PRODUCER_EXE}; wait" > /dev/null 2>&1
            
            strace -c -f -e trace=futex -o "${OUTPUT_PREFIX}_strace_summary.txt" \
                bash -c "${CONSUMER_CMD_PREFIX} ${MUTEX_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${MUTEX_PRODUCER_EXE}; wait" > /dev/null 2>&1

            # 4. 寫入 CSV
            p_l1_load=$(extract_perf_val "L1-dcache-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_l1_store=$(extract_perf_val "L1-dcache-store-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_llc_load=$(extract_perf_val "LLC-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_llc_store=$(extract_perf_val "LLC-store-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_csw=$(extract_perf_val "context-switches" "${OUTPUT_PREFIX}_perf_stat.txt")
            s_futex=$(extract_strace_futex "${OUTPUT_PREFIX}_strace_summary.txt")
            echo "${MODEL_TYPE},${pcount},${bsize},${mlen},${avg_init},${avg_comm},${p_l1_load},${p_l1_store},${p_llc_load},${p_llc_store},${p_csw},${s_futex}" >> "$TIMING_CSV_FILE"

            # 5. Phase 3: Profiling (FlameGraph)
            perf_pcount=$pcount
            if (( pcount < PROFILING_MIN_PRODUCT_COUNT )); then
                 perf_pcount=$PROFILING_MIN_PRODUCT_COUNT
                 # 重新編譯以符合 Profiling 需求
                 gcc "${MUTEX_PRODUCER_SRC}" -o ${MUTEX_PRODUCER_EXE} -g -DNUM_PRODUCTS="$perf_pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
                 gcc "${MUTEX_CONSUMER_SRC}" -o ${MUTEX_CONSUMER_EXE} -g -DNUM_PRODUCTS="$perf_pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
                 if [ $? -ne 0 ]; then echo "!! IPC Mutex Profiling 編譯失敗"; continue; fi
            fi
            
            perf record -m 1024 -F 99 --call-graph dwarf -g -o "${OUTPUT_PREFIX}_perf.data" -- \
                bash -c "${CONSUMER_CMD_PREFIX} ${MUTEX_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${MUTEX_PRODUCER_EXE}; wait" > /dev/null 2>&1
            
            if [ -s "${OUTPUT_PREFIX}_perf.data" ]; then
                perf report --stdio -i "${OUTPUT_PREFIX}_perf.data" > "${OUTPUT_PREFIX}_perf_report.txt" 2>/dev/null
                if [ "$AUTO_FLAMEGRAPH" = true ]; then
                    perf script -i "${OUTPUT_PREFIX}_perf.data" | "$STACKCOLLAPSE_SCRIPT" | "$FLAMEGRAPH_SCRIPT" > "${OUTPUT_PREFIX}_flamegraph.svg"
                fi
            fi


            # =================================================
            # Test 2: IPC Semaphore Model
            # =================================================
            MODEL_TYPE="IPC_Sem"
            OUTPUT_PREFIX="${RESULTS_DIR}/${MODEL_TYPE}_${TEST_CASE_TAG}"

            echo "         [2/2] IPC Sem Model: Compiling & Measuring..."
            
            # 1. 編譯
            gcc "${SEM_PRODUCER_SRC}" -o ${SEM_PRODUCER_EXE} -g -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
            gcc "${SEM_CONSUMER_SRC}" -o ${SEM_CONSUMER_EXE} -g -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
            if [ $? -ne 0 ]; then echo "!! IPC Semaphore 編譯失敗"; continue; fi

            # 2. Phase 1: 計時 (Timing)
            total_init=0.0; total_comm=0.0
            for j in $(seq 1 ${NUM_RUNS}); do
                ${CONSUMER_CMD_PREFIX} ${SEM_CONSUMER_EXE} &
                consumer_pid=$!
                result=$( ${PRODUCER_CMD_PREFIX} ${SEM_PRODUCER_EXE} )
                wait $consumer_pid
                
                i_time=$(echo "$result" | cut -d',' -f1); c_time=$(echo "$result" | cut -d',' -f2)
                total_init=$(awk -v t1="$total_init" -v t2="$i_time" 'BEGIN{print t1+t2}')
                total_comm=$(awk -v t1="$total_comm" -v t2="$c_time" 'BEGIN{print t1+t2}')
                sleep ${REST_INTERVAL_S}
            done
            avg_init=$(awk -v t="$total_init" -v n="$NUM_RUNS" 'BEGIN{print t/n}')
            avg_comm=$(awk -v t="$total_comm" -v n="$NUM_RUNS" 'BEGIN{print t/n}')

            # 3. Phase 2: Perf & Strace (Metrics)
            perf stat -e "$PERF_EVENTS" -o "${OUTPUT_PREFIX}_perf_stat.txt" \
                bash -c "${CONSUMER_CMD_PREFIX} ${SEM_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${SEM_PRODUCER_EXE}; wait" > /dev/null 2>&1
            
            strace -c -f -e trace=futex -o "${OUTPUT_PREFIX}_strace_summary.txt" \
                bash -c "${CONSUMER_CMD_PREFIX} ${SEM_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${SEM_PRODUCER_EXE}; wait" > /dev/null 2>&1

            # 4. 寫入 CSV
            p_l1_load=$(extract_perf_val "L1-dcache-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_l1_store=$(extract_perf_val "L1-dcache-store-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_llc_load=$(extract_perf_val "LLC-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_llc_store=$(extract_perf_val "LLC-store-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_csw=$(extract_perf_val "context-switches" "${OUTPUT_PREFIX}_perf_stat.txt")
            s_futex=$(extract_strace_futex "${OUTPUT_PREFIX}_strace_summary.txt")
            echo "${MODEL_TYPE},${pcount},${bsize},${mlen},${avg_init},${avg_comm},${p_l1_load},${p_l1_store},${p_llc_load},${p_llc_store},${p_csw},${s_futex}" >> "$TIMING_CSV_FILE"

            # 5. Phase 3: Profiling (FlameGraph)
            perf_pcount=$pcount
            if (( pcount < PROFILING_MIN_PRODUCT_COUNT )); then
                 perf_pcount=$PROFILING_MIN_PRODUCT_COUNT
                 gcc "${SEM_PRODUCER_SRC}" -o ${SEM_PRODUCER_EXE} -g -DNUM_PRODUCTS="$perf_pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
                 gcc "${SEM_CONSUMER_SRC}" -o ${SEM_CONSUMER_EXE} -g -DNUM_PRODUCTS="$perf_pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
                 if [ $? -ne 0 ]; then echo "!! IPC Semaphore Profiling 編譯失敗"; continue; fi
            fi
            
            perf record -m 1024 -F 99 --call-graph dwarf -g -o "${OUTPUT_PREFIX}_perf.data" -- \
                bash -c "${CONSUMER_CMD_PREFIX} ${SEM_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${SEM_PRODUCER_EXE}; wait" > /dev/null 2>&1
            
            if [ -s "${OUTPUT_PREFIX}_perf.data" ]; then
                perf report --stdio -i "${OUTPUT_PREFIX}_perf.data" > "${OUTPUT_PREFIX}_perf_report.txt" 2>/dev/null
                if [ "$AUTO_FLAMEGRAPH" = true ]; then
                    perf script -i "${OUTPUT_PREFIX}_perf.data" | "$STACKCOLLAPSE_SCRIPT" | "$FLAMEGRAPH_SCRIPT" > "${OUTPUT_PREFIX}_flamegraph.svg"
                fi
            fi
        done
    done
done

echo "####################################################"
echo "# 測試完成"
echo ">> CSV 報告: ${TIMING_CSV_FILE}"
echo "####################################################"