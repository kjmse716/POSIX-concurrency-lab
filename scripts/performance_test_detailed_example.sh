#!/bin/bash

# ==============================================================================
# Comprehensive IPC/ITC Performance Test Script (Final Corrected Version)
#
# It measures:
# 1. Basic Timing: For apples-to-apples comparison.
# 2. System Call Analysis (strace).
# 3. Hardware Performance Counters (perf stat).
# 4. CPU Sampling (perf record) with a larger workload for meaningful Flame Graphs.
# 5. Flame Graph Generation.
#
# Prerequisites (Ubuntu/Debian):
#   sudo apt update
#   sudo apt install strace
#   sudo apt install linux-tools-common linux-tools-generic linux-tools-$(uname -r)
#
#   # After installation, verify:
#   strace -V
#   perf --version
#   
#   if perf fail, try: sudo ln -sf /usr/lib/linux-tools/$(uname -r)/perf /usr/bin/perf
#
# Additional Setup for perf and debug symbols:
#   # 允許 perf 讀取核心 symbol 位址
#   sudo sysctl -w kernel.kptr_restrict=0
#
#   # 允許 perf 追蹤所有 CPU 和行程的事件（通常在 profiling 時需要）
#   sudo sysctl -w kernel.perf_event_paranoid=-1
#
#   # 安裝對應你核心版本的 linux-tools
#   sudo apt-get install linux-tools-$(uname -r)
#
#   # 使用 lsb_release -cs 來自動獲取你的 Ubuntu 版本代號 (例如 jammy, focal)
#   # 並將對應的 ddebs repository 設定檔寫入 /etc/apt/sources.list.d/
#   codename=$(lsb_release -cs)
#   sudo tee /etc/apt/sources.list.d/ddebs.list << EOF
#   deb http://ddebs.ubuntu.com/ ${codename} main restricted universe multiverse
#   deb http://ddebs.ubuntu.com/ ${codename}-updates main restricted universe multiverse
#   deb http://ddebs.ubuntu.com/ ${codename}-proposed main restricted universe multiverse
#   EOF
#
#   # 下載金鑰並加入到 apt 的信任清單中
#   sudo apt-get install wget -y
#   wget -O - http://ddebs.ubuntu.com/dbgsym-release-key.asc | sudo apt-key add -
#
#   sudo apt-get update
#
#   # 安裝對應核心版本的 debug symbol
#   sudo apt-get install linux-image-$(uname -r)-dbgsym
# ==============================================================================



# --- Configuration ---
export FLAMEGRAPH_DIR="/home/kjmse716/Documents/Labs/POSIX-concurrency-lab/library/FlameGraph"

NUM_RUNS=50
REST_INTERVAL_S=0.1
PRODUCT_COUNTS=(10000 100000 1000000)
BUFFER_SIZES=({1..100})
MESSAGE_LENS=(64 1500 4096 64000)

PROFILING_MIN_PRODUCT_COUNT=1000

# Source code paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
THREAD_SRC="${PROJECT_ROOT_DIR}/src/03_thread_itc_app/thread_producer_consumer.c"
PROCESS_PRODUCER_SRC="${PROJECT_ROOT_DIR}/src/02_process_ipc_app/producer.c"
PROCESS_CONSUMER_SRC="${PROJECT_ROOT_DIR}/src/02_process_ipc_app/consumer.c"
IPC_RUN_SCRIPT="${PROJECT_ROOT_DIR}/src/02_process_ipc_app/run_ipc_test.sh"

# Compiled executable names
THREAD_EXE="${SCRIPT_DIR}/temp_thread_test"
PROCESS_PRODUCER_EXE="${PROJECT_ROOT_DIR}/src/02_process_ipc_app/producer"
PROCESS_CONSUMER_EXE="${PROJECT_ROOT_DIR}/src/02_process_ipc_app/consumer"

# Output directory
RESULTS_DIR="${SCRIPT_DIR}/results"
TIMING_CSV_FILE="${RESULTS_DIR}/timing_results.csv"

# FlameGraph script paths
STACKCOLLAPSE_SCRIPT="${FLAMEGRAPH_DIR}/stackcollapse-perf.pl"
FLAMEGRAPH_SCRIPT="${FLAMEGRAPH_DIR}/flamegraph.pl"

# --- Pre-run Checks ---
if [[ $EUID -ne 0 ]]; then
    echo "!! 這個腳本需要 root 權限 (使用 sudo) 才能執行 perf。"
    exit 1
fi
AUTO_FLAMEGRAPH=true
if [ ! -f "$STACKCOLLAPSE_SCRIPT" ] || [ ! -f "$FLAMEGRAPH_SCRIPT" ]; then
     echo "!! 錯誤：找不到 FlameGraph 工具。"
     AUTO_FLAMEGRAPH=false
fi
mkdir -p "$RESULTS_DIR"
echo ">> 結果將儲存至： ${RESULTS_DIR}"

# --- Initialization ---
cleanup() {
    echo ">> 清理暫存檔案..."
    rm -f "$THREAD_EXE"
    if [ -f "${PROJECT_ROOT_DIR}/src/02_process_ipc_app/Makefile" ]; then
        (cd "${PROJECT_ROOT_DIR}/src/02_process_ipc_app" && make clean) > /dev/null 2>&1
    fi
}
trap cleanup EXIT # This trap ensures cleanup runs at the very end of the script
cleanup # Initial cleanup

echo "TestType,ProductCount,BufferSize,MessageLen,AvgInitTime_s,AvgCommTime_s" > "$TIMING_CSV_FILE"

# --- Main Test Loop ---
echo "####################################################"
echo "# 開始綜合效能測試                               #"
echo "####################################################"

for bsize in "${BUFFER_SIZES[@]}"; do
    for pcount in "${PRODUCT_COUNTS[@]}"; do
        for mlen in "${MESSAGE_LENS[@]}"; do
            TEST_CASE_TAG="P${pcount}_B${bsize}_M${mlen}"
            STRACE_IPC_EVENTS="trace=futex,mmap,openat"
            STRACE_ITC_EVENTS="trace=futex,clone"
            PERF_EVENTS="context-switches,cpu-migrations,page-faults,cpu-clock,task-clock"

            echo "----------------------------------------------------"
            echo ">> 測試設定：ProductCount=${pcount}, BufferSize=${bsize}, MessageLen=${mlen}"
            echo "----------------------------------------------------"

            # ==================== ITC (Thread) Model Test ====================
            echo "   [1/2] 測試 ITC (執行緒) 模型..."
            MODEL_TYPE="ITC"
            OUTPUT_PREFIX="${RESULTS_DIR}/${MODEL_TYPE}_${TEST_CASE_TAG}"
            PERF_DATA_FILE="${OUTPUT_PREFIX}_perf.data"
            FLAMEGRAPH_SVG_FILE="${OUTPUT_PREFIX}_flamegraph.svg"
            PERF_REPORT_FILE="${OUTPUT_PREFIX}_perf_report.txt"
            PERF_REPORT_FLAT_FILE="${OUTPUT_PREFIX}_perf_report_flat.txt"

            echo "       - 編譯 ITC 原始碼 (帶有除錯資訊)..."
            gcc "$THREAD_SRC" -o "$THREAD_EXE" -g -DNUM_PRODUCTS="$pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" -lpthread -lrt
            if [ $? -ne 0 ]; then echo "       !! ITC 編譯失敗。"; continue; fi

            echo "       - 執行基本計時測試 (${NUM_RUNS} 次)..."
            result=$("$THREAD_EXE"); init_time=$(echo "$result" | cut -d',' -f1); comm_time=$(echo "$result" | cut -d',' -f2)
            echo "${MODEL_TYPE},${pcount},${bsize},${mlen},${init_time},${comm_time}" >> "$TIMING_CSV_FILE"
            echo "         平均 Init: ${init_time}s, Comm: ${comm_time}s"

            echo "       - 執行 strace 和 perf stat..."
            strace -T -c -f -e "$STRACE_ITC_EVENTS" "$THREAD_EXE" > "${OUTPUT_PREFIX}_strace_summary.txt" 2>&1
            perf stat -e "$PERF_EVENTS" "$THREAD_EXE" > "${OUTPUT_PREFIX}_perf_stat.txt" 2>&1

            perf_pcount=$pcount
            if (( pcount < PROFILING_MIN_PRODUCT_COUNT )); then
                perf_pcount=$PROFILING_MIN_PRODUCT_COUNT
                echo "       - 為了 profiling，使用更大的工作負載 (${perf_pcount}) 重新編譯..."
                gcc "$THREAD_SRC" -o "$THREAD_EXE" -g -DNUM_PRODUCTS="$perf_pcount" -DBUFFER_SIZE="$bsize" -DMAX_MESSAGE_LEN="$mlen" -lpthread -lrt
            fi

            echo "       - 執行 perf record..."
            perf record -F 99 --call-graph dwarf -g -o "$PERF_DATA_FILE" -- "$THREAD_EXE" > /dev/null 2>&1

            if [ -s "$PERF_DATA_FILE" ]; then
                echo "       - 生成 perf report 文字報告 (標準 & 平坦)..."
                perf report --stdio -i "$PERF_DATA_FILE" > "$PERF_REPORT_FILE"
                perf report --stdio --no-children -i "$PERF_DATA_FILE" > "$PERF_REPORT_FLAT_FILE"
                if [ "$AUTO_FLAMEGRAPH" = true ]; then
                    echo "       - 生成火焰圖..."
                    perf script -i "$PERF_DATA_FILE" | "$STACKCOLLAPSE_SCRIPT" | "$FLAMEGRAPH_SCRIPT" > "$FLAMEGRAPH_SVG_FILE"
                fi
            else
                echo "       !! Perf record 未能採集到足夠數據，跳過報告和火焰圖生成。"
            fi
            echo "   ... ITC 測試完成。"
            
            # ==================== IPC (Process) Model Test ===================
            echo "   [2/2] 測試 IPC (行程) 模型..."
            MODEL_TYPE="IPC"
            OUTPUT_PREFIX="${RESULTS_DIR}/${MODEL_TYPE}_${TEST_CASE_TAG}"
            PERF_DATA_FILE="${OUTPUT_PREFIX}_perf.data"
            FLAMEGRAPH_SVG_FILE="${OUTPUT_PREFIX}_flamegraph.svg"
            PERF_REPORT_FILE="${OUTPUT_PREFIX}_perf_report.txt"
            PERF_REPORT_FLAT_FILE="${OUTPUT_PREFIX}_perf_report_flat.txt"

            echo "       - 清理並編譯 IPC 原始碼 (帶有除錯資訊)..."
            # --- FIX STARTS HERE ---
            # 關鍵修正：在編譯前先執行 'make clean'，強制重新生成執行檔
            (cd "${PROJECT_ROOT_DIR}/src/02_process_ipc_app" && \
             make clean && \
             make CFLAGS+="-g -DNUM_PRODUCTS=$pcount -DBUFFER_SIZE=$bsize -DMAX_MESSAGE_LEN=$mlen")
            # --- FIX ENDS HERE ---
            
            if [ ! -f "$PROCESS_PRODUCER_EXE" ] || [ ! -f "$PROCESS_CONSUMER_EXE" ]; then
                echo "       !! IPC 編譯失敗。"; continue;
            fi
            
            echo "       - 執行基本計時測試 (${NUM_RUNS} 次)..."
            result=$("$IPC_RUN_SCRIPT" 2>/dev/null | grep '^[0-9\.]\+,[0-9\.]\+$'); init_time=$(echo "$result" | cut -d',' -f1); comm_time=$(echo "$result" | cut -d',' -f2)
            echo "${MODEL_TYPE},${pcount},${bsize},${mlen},${init_time},${comm_time}" >> "$TIMING_CSV_FILE"
            echo "         平均 Init: ${init_time}s, Comm: ${comm_time}s"
            
            echo "       - 執行 strace 和 perf stat..."
            strace -T -c -f -e "$STRACE_IPC_EVENTS" "$IPC_RUN_SCRIPT" > "${OUTPUT_PREFIX}_strace_summary.txt" 2>&1
            perf stat -e "$PERF_EVENTS" "$IPC_RUN_SCRIPT" > "${OUTPUT_PREFIX}_perf_stat.txt" 2>&1

            perf_pcount=$pcount
            if (( pcount < PROFILING_MIN_PRODUCT_COUNT )); then
                perf_pcount=$PROFILING_MIN_PRODUCT_COUNT
                echo "       - 為了 profiling，使用更大的工作負載 (${perf_pcount}) 重新編譯..."
                # --- FIX STARTS HERE ---
                # 同樣地，profiling 的部分也要先 clean
                (cd "${PROJECT_ROOT_DIR}/src/02_process_ipc_app" && \
                 make clean && \
                 make CFLAGS+="-g -DNUM_PRODUCTS=$perf_pcount -DBUFFER_SIZE=$bsize -DMAX_MESSAGE_LEN=$mlen")
                # --- FIX ENDS HERE ---
            fi

            echo "       - 執行 perf record..."
            perf record -F 99 --call-graph dwarf -g -o "$PERF_DATA_FILE" -- "$IPC_RUN_SCRIPT" > /dev/null 2>&1
            
            if [ -s "$PERF_DATA_FILE" ]; then
                echo "       - 生成 perf report 文字報告 (標準 & 平坦)..."
                perf report --stdio -i "$PERF_DATA_FILE" > "$PERF_REPORT_FILE"
                perf report --stdio --no-children -i "$PERF_DATA_FILE" > "$PERF_REPORT_FLAT_FILE"

                if [ "$AUTO_FLAMEGRAPH" = true ]; then
                    echo "       - 生成火焰圖..."
                    perf script -i "$PERF_DATA_FILE" | "$STACKCOLLAPSE_SCRIPT" | "$FLAMEGRAPH_SCRIPT" > "$FLAMEGRAPH_SVG_FILE"
                fi
            else
                 echo "       !! Perf record 未能採集到足夠數據，跳過報告和火焰圖生成。"
            fi
            
            echo "   ... IPC 測試完成。"

        done
    done
done

echo "####################################################"
echo "# 測試完成                                       #"
echo "####################################################"
echo ">> 計時結果儲存於： ${TIMING_CSV_FILE}"
echo ">> Strace, Perf Stat, Perf Report (標準 & 平坦 .txt), Perf Data (.data), 和火焰圖 (.svg) 儲存於： ${RESULTS_DIR}"

exit 0
