#!/bin/bash

# =====================================================================
# Golden Validation Script (v3 - 完整版)
# 目標：在完全一致的受控環境下，對比 IPC 與 ITC 的效能差異，
#      特別是針對 Buffer Size = 4 vs 50 的關鍵案例。
# =====================================================================

# --- CONFIG ---
PRODUCT_COUNT=100000
MSG_LEN=256
NUM_RUNS=11 # 跑 11 次，去掉頭尾取中間值，避免冷啟動或系統突波干擾

# --- 路徑設定 ---
# 確保我們總是在腳本所在的目錄下執行，避免路徑問題
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# IPC 相關路徑
IPC_SRC_DIR="${SCRIPT_DIR}/src/02_process_ipc_app"
IPC_PRODUCER_SRC="${IPC_SRC_DIR}/producer.c"
IPC_CONSUMER_SRC="${IPC_SRC_DIR}/consumer.c"
IPC_PRODUCER_EXE="${IPC_SRC_DIR}/producer" # 執行檔必須放在 source dir
IPC_CONSUMER_EXE="${IPC_SRC_DIR}/consumer" # 這樣 run_ipc_test.sh 才能找到
IPC_RUN_SCRIPT="${IPC_SRC_DIR}/run_ipc_test.sh"

# ITC 相關路徑
ITC_SRC_DIR="${SCRIPT_DIR}/src/03_thread_itc_app"
ITC_SRC="${ITC_SRC_DIR}/thread_producer_consumer.c" # 使用 Mutex + Cond 的版本
ITC_EXE="./thread_golden" # 暫存的執行檔放在當前目錄

# --- FUNCTIONS ---

# --- IPC 測試函式 ---
run_ipc_test() {
    local bsize=$1
    echo "--- 測試 IPC (Process): Buffer Size = ${bsize} ---"

    # 1. 編譯
    gcc "${IPC_PRODUCER_SRC}" -o ${IPC_PRODUCER_EXE} -DNUM_PRODUCTS=${PRODUCT_COUNT} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${MSG_LEN} -lpthread -lrt
    gcc "${IPC_CONSUMER_SRC}" -o ${IPC_CONSUMER_EXE} -DNUM_PRODUCTS=${PRODUCT_COUNT} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${MSG_LEN} -lpthread -lrt
    if [ $? -ne 0 ]; then
        echo "IPC 編譯失敗！"
        exit 1
    fi

    # 2. 執行並收集數據
    echo "Run, Internal_Init_Time, Internal_Comm_Time, Perf_Elapsed_Time"
    for i in $(seq 1 ${NUM_RUNS}); do
        PERF_OUTPUT=$(mktemp)
        INTERNAL_TIME=$(sudo perf stat -o ${PERF_OUTPUT} ${IPC_RUN_SCRIPT})
        PERF_TIME=$(grep "seconds time elapsed" ${PERF_OUTPUT} | awk '{print $1}')
        INTERNAL_INIT_TIME=$(echo ${INTERNAL_TIME} | awk -F',' '{print $1}')
        INTERNAL_COMM_TIME=$(echo ${INTERNAL_TIME} | awk -F',' '{print $2}')
        echo "${i}, ${INTERNAL_INIT_TIME}, ${INTERNAL_COMM_TIME}, ${PERF_TIME}"
        rm ${PERF_OUTPUT}
        sleep 0.5
    done
    echo "--------------------------------------"
}

# --- ITC 測試函式 ---
run_itc_test() {
    local bsize=$1
    echo "--- 測試 ITC (Thread): Buffer Size = ${bsize} ---"

    # 1. 編譯
    gcc "${ITC_SRC}" -o ${ITC_EXE} -DNUM_PRODUCTS=${PRODUCT_COUNT} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${MSG_LEN} -lpthread -lrt
    if [ $? -ne 0 ]; then
        echo "ITC 編譯失敗！"
        exit 1
    fi

    # 2. 執行並收集數據
    echo "Run, Internal_Init_Time, Internal_Comm_Time, Perf_Elapsed_Time"
    for i in $(seq 1 ${NUM_RUNS}); do
        PERF_OUTPUT=$(mktemp)
        INTERNAL_TIME=$(sudo perf stat -o ${PERF_OUTPUT} ./${ITC_EXE})
        PERF_TIME=$(grep "seconds time elapsed" ${PERF_OUTPUT} | awk '{print $1}')
        INTERNAL_INIT_TIME=$(echo ${INTERNAL_TIME} | awk -F',' '{print $1}')
        INTERNAL_COMM_TIME=$(echo ${INTERNAL_TIME} | awk -F',' '{print $2}')
        echo "${i}, ${INTERNAL_INIT_TIME}, ${INTERNAL_COMM_TIME}, ${PERF_TIME}"
        rm ${PERF_OUTPUT}
        sleep 0.5
    done
    echo "--------------------------------------"
}


# --- MAIN EXECUTION ---
echo "=========================================================="
echo "執行黃金驗證腳本 (Workload: ${PRODUCT_COUNT}, Runs: ${NUM_RUNS})"
echo "=========================================================="

run_ipc_test 4
run_itc_test 4

run_ipc_test 6
run_itc_test 6

# --- 清理 ---
echo "測試完成，清理執行檔..."
rm -f ${IPC_PRODUCER_EXE} ${IPC_CONSUMER_EXE} ${ITC_EXE}
echo "完成！"