#!/bin/bash

# ==============================================================================
# Comprehensive IPC/ITC Performance Test Script (v2.3 - Restored Metrics)
#
# 功能：
# 1. 精確計時：執行多次取平均 (Phase 1)。
# 2. 硬體計數：自動解析 perf stat (Cache Misses, False Sharing, Ratios)。
# 3. 系統呼叫：自動解析 strace (Futex Calls)。
# 4. 完整報告：生成 perf.data, perf report (txt), flamegraph (svg)。
# 5. 整合輸出：匯總於 CSV。
#
# 修改重點 (v2.3):
# - 恢復 PERF_EVENTS 中遺漏的 cpu-clock, task-clock, L1-dcache-loads, LLC-loads。
# - 藉由補全 Event，讓 perf stat 報告能重新顯示詳細比例 (如 cache miss rate, CPU utilization)。
#
# 用法:
# ./scripts/performance_test_detailed_example.sh [affinity_mode] [core_a] [core_b]
# ==============================================================================

# --- 0. 環境與安全設定 ---
export LC_NUMERIC=C
export FLAMEGRAPH_DIR="/home/kjmse716/Documents/Labs/POSIX-concurrency-lab/library/FlameGraph"

# 參數設定
NUM_RUNS=1
REST_INTERVAL_S=0.1
PRODUCT_COUNTS=(1000000)
BUFFER_SIZES=(1 20)
MESSAGE_LENS=(64)
PROFILING_MIN_PRODUCT_COUNT=1000

# 關鍵指標 (已補全以支援詳細 Ratio 計算)
PERF_EVENTS="cpu-clock,task-clock,context-switches,cpu-migrations,page-faults,L1-dcache-loads,L1-dcache-load-misses,L1-dcache-store-misses,cache-misses,LLC-loads,LLC-load-misses,LLC-store-misses"

# 路徑設定
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
V4_SRC_DIR="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc"

# 原始碼
THREAD_SRC="${V4_SRC_DIR}/itc_producer_consumer.c"
PROCESS_PRODUCER_SRC="${V4_SRC_DIR}/ipc_producer.c"
PROCESS_CONSUMER_SRC="${V4_SRC_DIR}/ipc_consumer.c"

# 執行檔
THREAD_EXE="${SCRIPT_DIR}/temp_thread_test"
PROCESS_PRODUCER_EXE="${V4_SRC_DIR}/ipc_producer"
PROCESS_CONSUMER_EXE="${V4_SRC_DIR}/ipc_consumer"

# FlameGraph
STACKCOLLAPSE_SCRIPT="${FLAMEGRAPH_DIR}/stackcollapse-perf.pl"
FLAMEGRAPH_SCRIPT="${FLAMEGRAPH_DIR}/flamegraph.pl"

# --- 1. Affinity 解析 ---
AFFINITY_MODE="$1"
CORE_A="$2"
CORE_B="$3"

if [ -z "$AFFINITY_MODE" ]; then AFFINITY_MODE="unlimited"; fi

RESULTS_DIR="${SCRIPT_DIR}/results_detailed_${AFFINITY_MODE}"
TIMING_CSV_FILE="${RESULTS_DIR}/timing_and_metrics.csv"

echo "===================================================="
echo ">> 模式: ${AFFINITY_MODE}"
echo ">> 結果目錄: ${RESULTS_DIR}"
echo "===================================================="

case "$AFFINITY_MODE" in
    "rt-single-core")
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        THREAD_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "rt-cross-core")
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A},${CORE_B}"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_B}"
        THREAD_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
    "unlimited")
        THREAD_CMD_PREFIX=""
        PRODUCER_CMD_PREFIX=""
        CONSUMER_CMD_PREFIX=""
        THREAD_COMPILE_FLAGS=""
        ;;
    *)
        echo "錯誤: 不支援的模式 '$AFFINITY_MODE'"
        exit 1
        ;;
esac

# --- Checks ---
if [[ $EUID -ne 0 ]]; then echo "!! 需要 root 權限。"; exit 1; fi
AUTO_FLAMEGRAPH=true
if [ ! -f "$STACKCOLLAPSE_SCRIPT" ]; then AUTO_FLAMEGRAPH=false; fi
mkdir -p "$RESULTS_DIR"

cleanup() {
    rm -f "$THREAD_EXE" "$PROCESS_PRODUCER_EXE" "$PROCESS_CONSUMER_EXE"
}
trap cleanup EXIT
cleanup

# --- CSV Header ---
echo "TestType,ProductCount,BufferSize,MessageLen,AvgInitTime,AvgCommTime,L1_dcache_load_misses,L1_dcache_store_misses,LLC_load_misses,LLC_store_misses,Context_Switches,Futex_Calls" > "$TIMING_CSV_FILE"

# --- Helpers (安全增強版) ---

extract_perf_val() {
    local event="$1"
    local file="$2"
    # 1. 取第一欄 2. 刪除逗號
    local val=$(grep "$event" "$file" | awk '{print $1}' | sed 's/,//g')
    
    # 【安全修正】確保 val 是純數字。如果抓到 "<not" (supported) 或空值，回傳 0
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "$val"
    fi
}

extract_strace_futex() {
    local file="$1"
    # 【安全修正】加總所有包含 futex 的行 (避免多行導致變數含換行符號)
    local val=$(grep "futex" "$file" | awk '{sum+=$4} END {print sum}')
    
    if [ -z "$val" ]; then echo "0"; else echo "$val"; fi
}

# --- Main Loop ---
for bsize in "${BUFFER_SIZES[@]}"; do
    for pcount in "${PRODUCT_COUNTS[@]}"; do
        for mlen in "${MESSAGE_LENS[@]}"; do
            TEST_CASE_TAG="P${pcount}_B${bsize}_M${mlen}"
            echo ">> [${bsize} Buffer] 測試開始..."

            # ==================== ITC (Thread) ====================
            MODEL_TYPE="ITC"
            OUTPUT_PREFIX="${RESULTS_DIR}/${MODEL_TYPE}_${TEST_CASE_TAG}"

            # 1. 編譯
            gcc "$THREAD_SRC" -o "$THREAD_EXE" -g -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${THREAD_COMPILE_FLAGS} -lpthread -lrt
            if [ $? -ne 0 ]; then echo "!! ITC 編譯失敗"; continue; fi

            # 2. Phase 1: 計時
            total_init=0.0; total_comm=0.0
            for j in $(seq 1 ${NUM_RUNS}); do
                result=$( ${THREAD_CMD_PREFIX} "$THREAD_EXE" )
                i_time=$(echo "$result" | cut -d',' -f1); c_time=$(echo "$result" | cut -d',' -f2)
                total_init=$(awk -v t1="$total_init" -v t2="$i_time" 'BEGIN{print t1+t2}')
                total_comm=$(awk -v t1="$total_comm" -v t2="$c_time" 'BEGIN{print t1+t2}')
                sleep ${REST_INTERVAL_S}
            done
            avg_init=$(awk -v t="$total_init" -v n="$NUM_RUNS" 'BEGIN{print t/n}')
            avg_comm=$(awk -v t="$total_comm" -v n="$NUM_RUNS" 'BEGIN{print t/n}')

            # 3. Phase 2: Perf & Strace
            perf stat -e "$PERF_EVENTS" -o "${OUTPUT_PREFIX}_perf_stat.txt" \
                ${THREAD_CMD_PREFIX} "$THREAD_EXE" > /dev/null 2>&1
            
            strace -c -f -e trace=futex -o "${OUTPUT_PREFIX}_strace_summary.txt" \
                ${THREAD_CMD_PREFIX} "$THREAD_EXE" > /dev/null 2>&1

            # 4. 寫入 CSV (使用安全增強版的 helpers)
            p_l1_load=$(extract_perf_val "L1-dcache-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_l1_store=$(extract_perf_val "L1-dcache-store-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_llc_load=$(extract_perf_val "LLC-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_llc_store=$(extract_perf_val "LLC-store-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_csw=$(extract_perf_val "context-switches" "${OUTPUT_PREFIX}_perf_stat.txt")
            s_futex=$(extract_strace_futex "${OUTPUT_PREFIX}_strace_summary.txt")
            echo "${MODEL_TYPE},${pcount},${bsize},${mlen},${avg_init},${avg_comm},${p_l1_load},${p_l1_store},${p_llc_load},${p_llc_store},${p_csw},${s_futex}" >> "$TIMING_CSV_FILE"

            # 5. Phase 3: Profiling
            perf_pcount=$pcount
            if (( pcount < PROFILING_MIN_PRODUCT_COUNT )); then
                perf_pcount=$PROFILING_MIN_PRODUCT_COUNT
                gcc "$THREAD_SRC" -o "$THREAD_EXE" -g -DNUM_PRODUCTS="$perf_pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${THREAD_COMPILE_FLAGS} -lpthread -lrt
                if [ $? -ne 0 ]; then echo "!! ITC Profiling 編譯失敗"; continue; fi
            fi
            
            perf record -m 1024 -F 99 --call-graph dwarf -g -o "${OUTPUT_PREFIX}_perf.data" -- ${THREAD_CMD_PREFIX} "$THREAD_EXE" > /dev/null 2>&1
            
            if [ -s "${OUTPUT_PREFIX}_perf.data" ]; then
                perf report --stdio -i "${OUTPUT_PREFIX}_perf.data" > "${OUTPUT_PREFIX}_perf_report.txt" 2>/dev/null
                perf report --stdio --no-children -i "${OUTPUT_PREFIX}_perf.data" > "${OUTPUT_PREFIX}_perf_report_flat.txt" 2>/dev/null
                if [ "$AUTO_FLAMEGRAPH" = true ]; then
                    perf script -i "${OUTPUT_PREFIX}_perf.data" | "$STACKCOLLAPSE_SCRIPT" | "$FLAMEGRAPH_SCRIPT" > "${OUTPUT_PREFIX}_flamegraph.svg"
                fi
            fi

            # ==================== IPC (Process) ====================
            MODEL_TYPE="IPC"
            OUTPUT_PREFIX="${RESULTS_DIR}/${MODEL_TYPE}_${TEST_CASE_TAG}"

            # 1. 編譯
            gcc "${PROCESS_PRODUCER_SRC}" -o ${PROCESS_PRODUCER_EXE} -g -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" -lpthread -lrt
            gcc "${PROCESS_CONSUMER_SRC}" -o ${PROCESS_CONSUMER_EXE} -g -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" -lpthread -lrt
            if [ $? -ne 0 ]; then echo "!! IPC 編譯失敗"; continue; fi

            # 2. Phase 1: 計時
            total_init=0.0; total_comm=0.0
            for j in $(seq 1 ${NUM_RUNS}); do
                ${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} &
                consumer_pid=$!
                result=$( ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE} )
                wait $consumer_pid
                
                i_time=$(echo "$result" | cut -d',' -f1); c_time=$(echo "$result" | cut -d',' -f2)
                total_init=$(awk -v t1="$total_init" -v t2="$i_time" 'BEGIN{print t1+t2}')
                total_comm=$(awk -v t1="$total_comm" -v t2="$c_time" 'BEGIN{print t1+t2}')
                sleep ${REST_INTERVAL_S}
            done
            avg_init=$(awk -v t="$total_init" -v n="$NUM_RUNS" 'BEGIN{print t/n}')
            avg_comm=$(awk -v t="$total_comm" -v n="$NUM_RUNS" 'BEGIN{print t/n}')

            # 3. Phase 2: Perf & Strace
            perf stat -e "$PERF_EVENTS" -o "${OUTPUT_PREFIX}_perf_stat.txt" \
                bash -c "${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE}; wait" > /dev/null 2>&1
            
            strace -c -f -e trace=futex -o "${OUTPUT_PREFIX}_strace_summary.txt" \
                bash -c "${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE}; wait" > /dev/null 2>&1

            # 4. 寫入 CSV
            p_l1_load=$(extract_perf_val "L1-dcache-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_l1_store=$(extract_perf_val "L1-dcache-store-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_llc_load=$(extract_perf_val "LLC-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_llc_store=$(extract_perf_val "LLC-store-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
            p_csw=$(extract_perf_val "context-switches" "${OUTPUT_PREFIX}_perf_stat.txt")
            s_futex=$(extract_strace_futex "${OUTPUT_PREFIX}_strace_summary.txt")
            echo "${MODEL_TYPE},${pcount},${bsize},${mlen},${avg_init},${avg_comm},${p_l1_load},${p_l1_store},${p_llc_load},${p_llc_store},${p_csw},${s_futex}" >> "$TIMING_CSV_FILE"

            # 5. Phase 3: Profiling
            perf_pcount=$pcount
            if (( pcount < PROFILING_MIN_PRODUCT_COUNT )); then
                 perf_pcount=$PROFILING_MIN_PRODUCT_COUNT
                 gcc "${PROCESS_PRODUCER_SRC}" -o ${PROCESS_PRODUCER_EXE} -g -DNUM_PRODUCTS="$perf_pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" -lpthread -lrt
                 gcc "${PROCESS_CONSUMER_SRC}" -o ${PROCESS_CONSUMER_EXE} -g -DNUM_PRODUCTS="$perf_pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" -lpthread -lrt
                 if [ $? -ne 0 ]; then echo "!! IPC Profiling 編譯失敗"; continue; fi
            fi
            
            perf record -m 1024 -F 99 --call-graph dwarf -g -o "${OUTPUT_PREFIX}_perf.data" -- \
                bash -c "${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE}; wait" > /dev/null 2>&1
            
            if [ -s "${OUTPUT_PREFIX}_perf.data" ]; then
                perf report --stdio -i "${OUTPUT_PREFIX}_perf.data" > "${OUTPUT_PREFIX}_perf_report.txt" 2>/dev/null
                perf report --stdio --no-children -i "${OUTPUT_PREFIX}_perf.data" > "${OUTPUT_PREFIX}_perf_report_flat.txt" 2>/dev/null
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