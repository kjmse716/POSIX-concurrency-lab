#!/bin/bash

# =====================================================================
# Performance Test Script: IPC Mutex vs. IPC Semaphore
# (Affinity-Aware Executor)
#
# 目的:
# 專門比較「Mutex+Cond」與「Semaphore」兩種 IPC 機制在綁核環境下的效能差異。
#
# 測試對象 (位於 src/04_performance_comparison/ipc_mutex_sem/):
# 1. Mutex+Cond: ipc_producer.c, ipc_consumer.c
# 2. Semaphore:  ipc_sem_producer.c, ipc_sem_consumer.c
#
# 用法:
# ./scripts/performance_test_ipc_mutex_vs_sem.sh [affinity_mode] [core_a] [core_b]
#
# 範例 (由 Wrapper 呼叫):
# (sudo ./scripts/run_with_cpu_shield.sh "6,7" ./scripts/performance_test_ipc_mutex_vs_sem.sh rt-cross-core 6 7)
# =====================================================================


# --- 1. 路徑設定 ---

# 取得此腳本所在的目錄
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
# 專案根目錄 (假設此腳本在 'scripts' 資料夾中)
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# 原始碼目錄 (根據您的需求修改)
SRC_DIR="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_mutex_sem"


# --- 2. 組態設定 ---

# 每個測試案例的執行次數 (取平均)
NUM_RUNS=5

# 每次執行間的冷卻時間 (秒)
REST_INTERVAL_S=0.2

# 測試參數 (可依需求調整)
PRODUCT_COUNTS=(100000)
BUFFER_SIZES=({1..5}) # 測試 Buffer Size 1 到 10{1..10}
MESSAGE_LENS=(64)     # 訊息長度

# --- 原始碼檔案定義 ---
# 1. Mutex + Cond 模型
MUTEX_PRODUCER_SRC="${SRC_DIR}/ipc_producer.c"
MUTEX_CONSUMER_SRC="${SRC_DIR}/ipc_consumer.c"

# 2. Semaphore 模型
SEM_PRODUCER_SRC="${SRC_DIR}/ipc_sem_producer.c"
SEM_CONSUMER_SRC="${SRC_DIR}/ipc_sem_consumer.c"

# --- 編譯輸出檔名 (暫存於 scripts 目錄) ---
MUTEX_PRODUCER_EXE="${SCRIPT_DIR}/temp_mutex_producer"
MUTEX_CONSUMER_EXE="${SCRIPT_DIR}/temp_mutex_consumer"
SEM_PRODUCER_EXE="${SCRIPT_DIR}/temp_sem_producer"
SEM_CONSUMER_EXE="${SCRIPT_DIR}/temp_sem_consumer"


# --- 3. CPU Affinity 參數解析 ---
AFFINITY_MODE="$1"
CORE_A="$2"
CORE_B="$3"

# 輸出檔案
OUTPUT_FILE="${SCRIPT_DIR}/results_ipc_mutex_vs_sem_${AFFINITY_MODE}.csv" 

# --- 模式驗證 ---
VALID_MODES=" unlimited single-core cross-core rt-single-core rt-cross-core "
if ! echo "${VALID_MODES}" | grep -q " ${AFFINITY_MODE} "; then
    echo "錯誤: 無效的 CPU 親和性模式 '$AFFINITY_MODE'."
    echo "用法: $0 [unlimited | single-core | cross-core | rt-single-core CORE_A | rt-cross-core CORE_A CORE_B]"
    exit 1
fi

if [[ "$AFFINITY_MODE" == "rt-cross-core" && ( -z "$CORE_A" || -z "$CORE_B" ) ]]; then
    echo "錯誤: rt-cross-core 模式需要提供兩個核心 ID。"
    exit 1
fi

if [[ "$AFFINITY_MODE" == "rt-single-core" && -z "$CORE_A" ]]; then
    echo "錯誤: rt-single-core 模式需要提供一個核心 ID。"
    exit 1
fi


echo "===================================================="
echo ">> 正在以模式運行: ${AFFINITY_MODE}"
echo ">> 比較對象: IPC (Mutex+Cond) vs IPC (Semaphore)"
echo "===================================================="


# --- 4. 根據模式設定 Taskset 命令與編譯參數 ---
# 注意: 這裡設定的 AFFINITY_COMPILE_FLAGS 對於您新改的 C 程式碼至關重要，
# 因為程式碼內使用 #ifdef PRODUCER_CORE_ID 來決定是否呼叫 pin_thread_to_core。

PRODUCER_CMD_PREFIX=""
CONSUMER_CMD_PREFIX=""
AFFINITY_COMPILE_FLAGS="" 

case "$AFFINITY_MODE" in
    "single-core")
        echo ">> 綁定模式: (舊版) 所有工作將綁定到 CPU Core ${CORE_A}"
        PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="taskset -c ${CORE_A}"
        # 傳遞核心 ID 給 C 編譯器
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "cross-core")
        echo ">> 綁定模式: (舊版) 跨核心 (Producer: ${CORE_A}, Consumer: ${CORE_B})"
        PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="taskset -c ${CORE_B}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
    "unlimited")
        echo ">> 綁定模式: 不限制 (由 Linux 排程器自行決定)"
        AFFINITY_COMPILE_FLAGS=""
        ;;

    "rt-single-core")
        echo ">> 綁定模式: Real-Time 單一核心 (CPU Core ${CORE_A})"
        echo ">> 優先權: SCHED_FIFO (real-time)"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;

    "rt-cross-core")
        echo ">> 綁定模式: Real-Time 跨核心 (Producer: ${CORE_A}, Consumer: ${CORE_B})"
        echo ">> 優先權: SCHED_FIFO (real-time)"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_B}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
esac
echo "----------------------------------------------------"


echo "IPC Mutex vs Sem Performance Test"
echo "Each test case will run ${NUM_RUNS} times."
echo "Results will be saved to: ${OUTPUT_FILE}"

# 設定 CSV 檔頭
echo "SyncMechanism,ProductCount,BufferSize,MessageLen,AvgInitTime,AvgCommTime" > ${OUTPUT_FILE}


# --- 5. Main test loop ---
for size in "${BUFFER_SIZES[@]}"; do
    for count in "${PRODUCT_COUNTS[@]}"; do
        for msg_len in "${MESSAGE_LENS[@]}"; do
            echo "----------------------------------------------------"
            echo ">> Testing with Product Count: ${count}, Buffer Size: ${size}, Message Len: ${msg_len}"
            
            if [[ -n "$AFFINITY_COMPILE_FLAGS" ]]; then
                echo "         [i] 資訊: 已啟用 C 語言層級 CPU 綁定 ($AFFINITY_COMPILE_FLAGS)"
            fi

            # =================================================
            # Test 1: IPC Mutex + Cond Model
            # =================================================
            echo "         [1/2] Compiling and running IPC Mutex+Cond model..."

            # 編譯 (注意: 加入了 AFFINITY_COMPILE_FLAGS)
            gcc ${MUTEX_PRODUCER_SRC} -o ${MUTEX_PRODUCER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            gcc ${MUTEX_CONSUMER_SRC} -o ${MUTEX_CONSUMER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            
            if [ $? -ne 0 ]; then
                echo "         !! IPC Mutex compilation failed"
                continue
            fi

            total_init_time=0.0
            total_comm_time=0.0

            for j in $(seq 1 ${NUM_RUNS}); do
                echo -ne "               - Running iteration ${j}/${NUM_RUNS}...\r"
                sleep ${REST_INTERVAL_S}

                # 執行 Mutex 模型
                ${CONSUMER_CMD_PREFIX} ${MUTEX_CONSUMER_EXE} &
                result=$( ${PRODUCER_CMD_PREFIX} ${MUTEX_PRODUCER_EXE} )
                
                wait # 等待 Consumer 結束
                
                init_time=$(echo "$result" | awk -F',' '{print $1}')
                comm_time=$(echo "$result" | awk -F',' '{print $2}')
                total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
                total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
            done
            echo "" 

            avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            
            # 寫入結果: Type 為 "IPC_Mutex"
            echo "IPC_Mutex,${count},${size},${msg_len},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}
            echo "         ... IPC Mutex test complete."


            # =================================================
            # Test 2: IPC Semaphore Model
            # =================================================
            echo "         [2/2] Compiling and running IPC Semaphore model..."

            # 編譯 (注意: 加入了 AFFINITY_COMPILE_FLAGS)
            gcc ${SEM_PRODUCER_SRC} -o ${SEM_PRODUCER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            gcc ${SEM_CONSUMER_SRC} -o ${SEM_CONSUMER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            
            if [ $? -ne 0 ]; then
                echo "         !! IPC Semaphore compilation failed"
                continue
            fi

            total_init_time=0.0
            total_comm_time=0.0

            for j in $(seq 1 ${NUM_RUNS}); do
                echo -ne "               - Running iteration ${j}/${NUM_RUNS}...\r"
                sleep ${REST_INTERVAL_S}

                # 執行 Semaphore 模型
                ${CONSUMER_CMD_PREFIX} ${SEM_CONSUMER_EXE} &
                result=$( ${PRODUCER_CMD_PREFIX} ${SEM_PRODUCER_EXE} )
                
                wait # 等待 Consumer 結束
                
                init_time=$(echo "$result" | awk -F',' '{print $1}')
                comm_time=$(echo "$result" | awk -F',' '{print $2}')
                total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
                total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
            done
            echo "" 

            avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            
            # 寫入結果: Type 為 "IPC_Sem"
            echo "IPC_Sem,${count},${size},${msg_len},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}
            echo "         ... IPC Semaphore test complete."

        done
    done
done


# --- 6. Cleanup ---
echo "----------------------------------------------------"
echo ">> Tests finished. Cleaning up compiled files..."
rm -f ${MUTEX_PRODUCER_EXE} ${MUTEX_CONSUMER_EXE} ${SEM_PRODUCER_EXE} ${SEM_CONSUMER_EXE}

echo "-------------------------------------"
hours=$((SECONDS / 3600))
minutes=$(((SECONDS % 3600) / 60))
seconds=$((SECONDS % 60))
echo "所有測試完成，總共花費：${hours} 小時 ${minutes} 分 ${seconds} 秒"

echo ">> Complete. results are in ${OUTPUT_FILE}"