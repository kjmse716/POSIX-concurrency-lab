#!/bin/bash

# ==============================================================================
# Detailed Throughput & FlameGraph Analysis Script
# (Based on performance_test_detailed_example.sh & throughput_test_example.sh)
#
# 目的：
# 1. 測量 IPC vs ITC 的 Throughput (MB/s)。
# 2. 生成詳細效能指標 (Cache Misses, Context Switches, Futex Calls)。
# 3. 自動生成 FlameGraph 以分析效能瓶頸。
#
# 特點：
# - 固定總傳輸量 (TOTAL_BYTES)，動態計算 count。
# - 針對重構後的 "ipc_itc_flamegraph" 原始碼進行測試。
# - 自動解除 Stack 限制 (`ulimit -s unlimited`)。
#
# 用法:
# ./scripts/performance_test_detailed_throughput.sh [affinity_mode] [core_a] [core_b]
# ==============================================================================

# --- 0. 環境與安全設定 ---
export LC_NUMERIC=C
# 請根據您的環境修改 FlameGraph 路徑
export FLAMEGRAPH_DIR="/home/kjmse716/Documents/Labs/POSIX-concurrency-lab/library/FlameGraph"

# --- 測試參數設定 (參考 throughput_test_example.sh) ---
NUM_RUNS=2
REST_INTERVAL_S=0.2

# [設定 A] 總傳輸量固定為 1GB (1024^3 bytes)
TOTAL_BYTES=$((1024 * 1024 * 1024))

# [設定 B] 固定 Buffer Slot 數量 (建議 256)
BUFFER_SIZES=(256)

# [設定 C] 封包大小掃描範圍 (可在此調整)
# 預設範例：從 256B 到 8KB，間距 256B (您可以改為 1MB~8MB 進行壓力測試)
MSG_MIN=256
MSG_MAX=65536
MSG_STEP=256
# 若要測大封包 (DRAM bound)，可取消註解下面這組：
# MSG_MIN=1048576
# MSG_MAX=8388608
# MSG_STEP=1048576

# 關鍵指標 (Perf Events)
PERF_EVENTS="cpu-clock,task-clock,context-switches,cpu-migrations,page-faults,L1-dcache-loads,L1-dcache-load-misses,L1-dcache-store-misses,cache-misses,LLC-loads,LLC-load-misses,LLC-store-misses"

# --- 路徑設定 ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# [修改] 指向重構後的原始碼目錄
SRC_DIR="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc_flamegraph"

# 原始碼檔案
THREAD_SRC="${SRC_DIR}/itc_producer_consumer.c"
PROCESS_PRODUCER_SRC="${SRC_DIR}/ipc_producer.c"
PROCESS_CONSUMER_SRC="${SRC_DIR}/ipc_consumer.c"

# 編譯輸出檔名
THREAD_EXE="${SCRIPT_DIR}/temp_thread_throughput"
PROCESS_PRODUCER_EXE="${SCRIPT_DIR}/temp_process_producer_throughput"
PROCESS_CONSUMER_EXE="${SCRIPT_DIR}/temp_process_consumer_throughput"

# FlameGraph 工具路徑
STACKCOLLAPSE_SCRIPT="${FLAMEGRAPH_DIR}/stackcollapse-perf.pl"
FLAMEGRAPH_SCRIPT="${FLAMEGRAPH_DIR}/flamegraph.pl"

# --- 1. Affinity 參數解析 ---
AFFINITY_MODE="$1"
CORE_A="$2"
CORE_B="$3"

if [ -z "$AFFINITY_MODE" ]; then AFFINITY_MODE="unlimited"; fi

RESULTS_DIR="${SCRIPT_DIR}/results_detailed_throughput_${AFFINITY_MODE}"
TIMING_CSV_FILE="${RESULTS_DIR}/throughput_metrics.csv"

echo "===================================================="
echo ">> 模式: ${AFFINITY_MODE}"
echo ">> 測試範圍: ${MSG_MIN} ~ ${MSG_MAX} (Step: ${MSG_STEP})"
echo ">> 結果目錄: ${RESULTS_DIR}"
echo "===================================================="

# 設定 Affinity 命令與編譯旗標
PRODUCER_CMD_PREFIX=""
CONSUMER_CMD_PREFIX=""
THREAD_CMD_PREFIX=""
AFFINITY_COMPILE_FLAGS=""

case "$AFFINITY_MODE" in
    "rt-single-core")
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "rt-cross-core")
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A},${CORE_B}"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_B}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
    "unlimited")
        THREAD_CMD_PREFIX=""
        PRODUCER_CMD_PREFIX=""
        CONSUMER_CMD_PREFIX=""
        AFFINITY_COMPILE_FLAGS=""
        ;;
    *) # 簡單的單核/跨核支援
        if [[ "$AFFINITY_MODE" == "single-core" ]]; then
            THREAD_CMD_PREFIX="taskset -c ${CORE_A}"
            PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
            CONSUMER_CMD_PREFIX="taskset -c ${CORE_A}"
            AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        elif [[ "$AFFINITY_MODE" == "cross-core" ]]; then
            THREAD_CMD_PREFIX="taskset -c ${CORE_A},${CORE_B}"
            PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
            CONSUMER_CMD_PREFIX="taskset -c ${CORE_B}"
            AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        else
            echo "錯誤: 不支援的模式 '$AFFINITY_MODE'"
            exit 1
        fi
        ;;
esac

if [[ -n "$AFFINITY_COMPILE_FLAGS" ]]; then
    echo ">> 已啟用 C 語言層級綁核旗標: ${AFFINITY_COMPILE_FLAGS}"
fi

# --- Checks ---
if [[ $EUID -ne 0 ]]; then echo "!! 需要 root 權限 (perf stat/record)。"; exit 1; fi
AUTO_FLAMEGRAPH=true
if [ ! -f "$STACKCOLLAPSE_SCRIPT" ]; then AUTO_FLAMEGRAPH=false; fi
mkdir -p "$RESULTS_DIR"

# 解除 Stack 限制 (針對大封包測試至關重要)
ulimit -s unlimited

cleanup() {
    rm -f "$THREAD_EXE" "$PROCESS_PRODUCER_EXE" "$PROCESS_CONSUMER_EXE"
}
trap cleanup EXIT
cleanup

# --- CSV Header (新增 Throughput) ---
echo "TestType,ProductCount,BufferSize,MessageLen,AvgInitTime,AvgCommTime,Throughput(MB/s),L1_misses,LLC_misses,Context_Switches,Futex_Calls" > "$TIMING_CSV_FILE"

# --- Helpers ---
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
    
    # 使用 seq 動態產生封包大小序列
    for mlen in $(seq ${MSG_MIN} ${MSG_STEP} ${MSG_MAX}); do
        
        # [關鍵] 動態計算 Count
        pcount=$((TOTAL_BYTES / mlen))
        
        TEST_CASE_TAG="P${pcount}_B${bsize}_M${mlen}"
        echo "----------------------------------------------------"
        echo ">> [Buffer: ${bsize}, Size: ${mlen}, Count: ${pcount}] 測試開始..."

        # =================================================
        # Test 1: ITC (Thread) Model
        # =================================================
        MODEL_TYPE="ITC"
        OUTPUT_PREFIX="${RESULTS_DIR}/${MODEL_TYPE}_${TEST_CASE_TAG}"

        # 1. 編譯 (加入 -fno-omit-frame-pointer 優化 FlameGraph)
        gcc "${THREAD_SRC}" -o "${THREAD_EXE}" -g -fno-omit-frame-pointer -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
        if [ $? -ne 0 ]; then echo "!! ITC 編譯失敗"; continue; fi

        # 2. Phase 1: 計時 & Throughput
        total_comm=0.0
        # 跑第一次預熱，不計入
        ${THREAD_CMD_PREFIX} "${THREAD_EXE}" > /dev/null
        
        for j in $(seq 1 ${NUM_RUNS}); do
            result=$( ${THREAD_CMD_PREFIX} "${THREAD_EXE}" )
            c_time=$(echo "$result" | cut -d',' -f2)
            total_comm=$(awk -v t1="$total_comm" -v t2="$c_time" 'BEGIN{print t1+t2}')
            sleep ${REST_INTERVAL_S}
        done
        avg_comm=$(awk -v t="$total_comm" -v n="$NUM_RUNS" 'BEGIN{print t/n}')
        # 計算 Throughput
        throughput=$(awk -v bytes="$TOTAL_BYTES" -v time="$avg_comm" 'BEGIN { if(time>0) print (bytes/1024/1024)/time; else print 0 }')

        # 3. Phase 2: Metrics (Perf & Strace)
        perf stat -e "$PERF_EVENTS" -o "${OUTPUT_PREFIX}_perf_stat.txt" \
            ${THREAD_CMD_PREFIX} "${THREAD_EXE}" > /dev/null 2>&1
        
        strace -c -f -e trace=futex -o "${OUTPUT_PREFIX}_strace_summary.txt" \
            ${THREAD_CMD_PREFIX} "${THREAD_EXE}" > /dev/null 2>&1

        # 4. 寫入 CSV
        p_l1=$(extract_perf_val "L1-dcache-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
        p_llc=$(extract_perf_val "LLC-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
        p_csw=$(extract_perf_val "context-switches" "${OUTPUT_PREFIX}_perf_stat.txt")
        s_futex=$(extract_strace_futex "${OUTPUT_PREFIX}_strace_summary.txt")
        # Init time 暫時填 0 或從 result 解析，這裡簡化專注於 CommTime
        echo "${MODEL_TYPE},${pcount},${bsize},${mlen},0,${avg_comm},${throughput},${p_l1},${p_llc},${p_csw},${s_futex}" >> "$TIMING_CSV_FILE"

        # 5. Phase 3: FlameGraph
        # 由於 Total Bytes 固定 1GB，時間足夠長，直接採樣即可
        perf record -m 1024 -F 99 --call-graph dwarf -g -o "${OUTPUT_PREFIX}_perf.data" -- \
             ${THREAD_CMD_PREFIX} "${THREAD_EXE}" > /dev/null 2>&1
        
        if [ -s "${OUTPUT_PREFIX}_perf.data" ]; then
            perf report --stdio -i "${OUTPUT_PREFIX}_perf.data" > "${OUTPUT_PREFIX}_perf_report.txt" 2>/dev/null
            if [ "$AUTO_FLAMEGRAPH" = true ]; then
                perf script -i "${OUTPUT_PREFIX}_perf.data" | "$STACKCOLLAPSE_SCRIPT" | "$FLAMEGRAPH_SCRIPT" > "${OUTPUT_PREFIX}_flamegraph.svg"
            fi
        fi

        # =================================================
        # Test 2: IPC (Process) Model
        # =================================================
        MODEL_TYPE="IPC"
        OUTPUT_PREFIX="${RESULTS_DIR}/${MODEL_TYPE}_${TEST_CASE_TAG}"

        # 1. 編譯
        gcc "${PROCESS_PRODUCER_SRC}" -o ${PROCESS_PRODUCER_EXE} -g -fno-omit-frame-pointer -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
        gcc "${PROCESS_CONSUMER_SRC}" -o ${PROCESS_CONSUMER_EXE} -g -fno-omit-frame-pointer -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" ${AFFINITY_COMPILE_FLAGS} -lpthread -lrt
        if [ $? -ne 0 ]; then echo "!! IPC 編譯失敗"; continue; fi

        # 2. Phase 1: 計時 & Throughput
        total_comm=0.0
        for j in $(seq 1 ${NUM_RUNS}); do
            ${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} &
            consumer_pid=$!
            result=$( ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE} )
            wait $consumer_pid
            
            c_time=$(echo "$result" | cut -d',' -f2)
            total_comm=$(awk -v t1="$total_comm" -v t2="$c_time" 'BEGIN{print t1+t2}')
            sleep ${REST_INTERVAL_S}
        done
        avg_comm=$(awk -v t="$total_comm" -v n="$NUM_RUNS" 'BEGIN{print t/n}')
        throughput=$(awk -v bytes="$TOTAL_BYTES" -v time="$avg_comm" 'BEGIN { if(time>0) print (bytes/1024/1024)/time; else print 0 }')

        # 3. Phase 2: Metrics
        perf stat -e "$PERF_EVENTS" -o "${OUTPUT_PREFIX}_perf_stat.txt" \
            bash -c "${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE}; wait" > /dev/null 2>&1
        
        strace -c -f -e trace=futex -o "${OUTPUT_PREFIX}_strace_summary.txt" \
            bash -c "${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE}; wait" > /dev/null 2>&1

        # 4. 寫入 CSV
        p_l1=$(extract_perf_val "L1-dcache-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
        p_llc=$(extract_perf_val "LLC-load-misses" "${OUTPUT_PREFIX}_perf_stat.txt")
        p_csw=$(extract_perf_val "context-switches" "${OUTPUT_PREFIX}_perf_stat.txt")
        s_futex=$(extract_strace_futex "${OUTPUT_PREFIX}_strace_summary.txt")
        echo "${MODEL_TYPE},${pcount},${bsize},${mlen},0,${avg_comm},${throughput},${p_l1},${p_llc},${p_csw},${s_futex}" >> "$TIMING_CSV_FILE"

        # 5. Phase 3: FlameGraph
        perf record -m 1024 -F 99 --call-graph dwarf -g -o "${OUTPUT_PREFIX}_perf.data" -- \
             bash -c "${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} & ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE}; wait" > /dev/null 2>&1
        
        if [ -s "${OUTPUT_PREFIX}_perf.data" ]; then
            perf report --stdio -i "${OUTPUT_PREFIX}_perf.data" > "${OUTPUT_PREFIX}_perf_report.txt" 2>/dev/null
            if [ "$AUTO_FLAMEGRAPH" = true ]; then
                perf script -i "${OUTPUT_PREFIX}_perf.data" | "$STACKCOLLAPSE_SCRIPT" | "$FLAMEGRAPH_SCRIPT" > "${OUTPUT_PREFIX}_flamegraph.svg"
            fi
        fi

    done
done

echo "####################################################"
echo "# 測試完成"
echo ">> CSV 報告: ${TIMING_CSV_FILE}"
echo ">> 結果目錄: ${RESULTS_DIR}"
echo "####################################################"