#!/bin/bash
# 設置 -e，確保任何指令失敗時腳本都會立即停止
set -e

# =====================================================================
# Golden Validation Script (v4.0 - Affinity-Aware, v4-Source Aligned)
#
# 角色:
# 驗證腳本，已與 v4 測試套件 (internal, detailed, offcpu) 對齊，
# 使用 src/04_... 中的 C 原始碼，並完整支援 CPU 親和性綁定。
#
# 用法 (由 run_with_cpu_shield.sh 呼叫):
# sudo ./scripts/run_with_cpu_shield.sh "6,7" ./scripts/validate.sh rt-cross-core 6 7
#
# 用法 (獨立執行):
# ./scripts/validate.sh unlimited
# =====================================================================

# --- CONFIG ---
PRODUCT_COUNT=100000
MSG_LEN=256
NUM_RUNS=11 # 跑 11 次，去掉頭尾取中間值

# --- 路徑設定 ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# --- 【修正】: 統一使用 v4 (04_...) 版本的 C 原始碼 ---
V4_SRC_DIR="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc"
IPC_PRODUCER_SRC="${V4_SRC_DIR}/ipc_producer.c"
IPC_CONSUMER_SRC="${V4_SRC_DIR}/ipc_consumer.c"
ITC_SRC="${V4_SRC_DIR}/itc_producer_consumer.c"

# --- 【修正】: 修正遺失的變數，並使用 ${SCRIPT_DIR} 確保路徑正確 ---
# (使用 'val_' 前綴避免與其他腳本的暫存檔衝突)
IPC_PRODUCER_EXE="${SCRIPT_DIR}/val_ipc_producer"
IPC_CONSUMER_EXE="${SCRIPT_DIR}/val_ipc_consumer"
ITC_EXE="${SCRIPT_DIR}/val_itc_thread"

# --- 1. Affinity 參數解析 ---
AFFINITY_MODE="$1"
CORE_A="$2"
CORE_B="$3"

PRODUCER_CMD_PREFIX=""
CONSUMER_CMD_PREFIX=""
THREAD_CMD_PREFIX=""
THREAD_COMPILE_FLAGS=""

# 預設為 unlimited
if [ -z "$AFFINITY_MODE" ]; then
    AFFINITY_MODE="unlimited"
fi

echo ">> Golden Validation: 運行模式 ${AFFINITY_MODE}"

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
        # 保持前綴為空
        ;;
    *)
        echo "錯誤: 不支援的模式 '$AFFINITY_MODE'"
        exit 1
        ;;
esac


# --- 2. 修改測試函數以使用 `gcc` 和 Affinity 前綴 ---

# (IPC 測試函式)
run_ipc_test() {
    local bsize=$1
    echo "--- 測試 IPC (Process): Buffer Size = ${bsize} ---"

    # 【修正】: 不再使用 make，改用 gcc 直接編譯 v4 原始碼
    echo "    - Compiling IPC v4 source..."
    gcc "${IPC_PRODUCER_SRC}" -o "${IPC_PRODUCER_EXE}" -DNUM_PRODUCTS=${PRODUCT_COUNT} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${MSG_LEN} -lpthread -lrt
    gcc "${IPC_CONSUMER_SRC}" -o "${IPC_CONSUMER_EXE}" -DNUM_PRODUCTS=${PRODUCT_COUNT} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${MSG_LEN} -lpthread -lrt
    if [ $? -ne 0 ]; then echo "IPC 編譯失敗！"; exit 1; fi

    # 2. 執行並收集數據
    echo "    - Running test..."
    echo "Run, Internal_Init_Time, Internal_Comm_Time, Perf_Elapsed_Time"
    for i in $(seq 1 ${NUM_RUNS}); do
        PERF_OUTPUT=$(mktemp)
        
        # 【修改】: 拆開 IPC_RUN_SCRIPT，分別啟動並綁定
        
        # 啟動 Consumer (綁定)
        ${CONSUMER_CMD_PREFIX} "${IPC_CONSUMER_EXE}" &
        CONSUMER_PID=$!

        # 啟動 Producer (綁定)，並用 perf stat 測量
        # Producer 輸出的 "X.XXX,Y.YYY" 會被 INTERNAL_TIME 捕獲
        INTERNAL_TIME=$(sudo perf stat -o ${PERF_OUTPUT} ${PRODUCER_CMD_PREFIX} "${IPC_PRODUCER_EXE}")
        
        wait $CONSUMER_PID # 確保 consumer 結束
        
        PERF_TIME=$(grep "seconds time elapsed" ${PERF_OUTPUT} | awk '{print $1}')
        INTERNAL_INIT_TIME=$(echo ${INTERNAL_TIME} | awk -F',' '{print $1}')
        INTERNAL_COMM_TIME=$(echo ${INTERNAL_TIME} | awk -F',' '{print $2}')
        
        echo "${i}, ${INTERNAL_INIT_TIME}, ${INTERNAL_COMM_TIME}, ${PERF_TIME}"
        rm ${PERF_OUTPUT}
        sleep 0.5
    done
    echo "--------------------------------------"
}

# (ITC 測試函式)
run_itc_test() {
    local bsize=$1
    echo "--- 測試 ITC (Thread): Buffer Size = ${bsize} ---"

    # 【修正】: 傳入 C 語言層級的綁定旗標 (v4 C 程式碼支援此功能)
    echo "    - Compiling ITC v4 source..."
    gcc "${ITC_SRC}" -o "${ITC_EXE}" ${THREAD_COMPILE_FLAGS} -DNUM_PRODUCTS=${PRODUCT_COUNT} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${MSG_LEN} -lpthread -lrt
    if [ $? -ne 0 ]; then echo "ITC 編譯失敗！"; exit 1; fi

    # 2. 執行並收集數據
    echo "    - Running test..."
    echo "Run, Internal_Init_Time, Internal_Comm_Time, Perf_Elapsed_Time"
    for i in $(seq 1 ${NUM_RUNS}); do
        PERF_OUTPUT=$(mktemp)
        
        # 【修改】: 在 sudo perf stat 和執行檔之間加上 THREAD_CMD_PREFIX
        # 【修正】: 移除 CWD 相對路徑 "./"
        INTERNAL_TIME=$(sudo perf stat -o ${PERF_OUTPUT} ${THREAD_CMD_PREFIX} "${ITC_EXE}")
        
        PERF_TIME=$(grep "seconds time elapsed" ${PERF_OUTPUT} | awk '{print $1}')
        INTERNAL_INIT_TIME=$(echo ${INTERNAL_TIME} | awk -F',' '{print $1}')
        INTERNAL_COMM_TIME=$(echo ${INTERNAL_TIME} | awk -F',' '{print $2}')

        echo "${i}, ${INTERNAL_INIT_TIME}, ${INTERNAL_COMM_TIME}, ${PERF_TIME}"
        rm ${PERF_OUTPUT}
        sleep 0.5
    done
    echo "--------------------------------------"
}


# --- 3. MAIN EXECUTION ---
echo "=========================================================="
echo "執行黃金驗證腳本 (Workload: ${PRODUCT_COUNT}, Runs: ${NUM_RUNS})"
echo "=========================================================="

run_ipc_test 4
run_itc_test 4

run_ipc_test 6
run_itc_test 6

# --- 4. 清理 ---
echo "測試完成，清理執行檔..."
rm -f ${IPC_PRODUCER_EXE} ${IPC_CONSUMER_EXE} ${ITC_EXE}
echo "完成！"