#!/bin/bash

# =====================================================================
# Performance Test Script (v1.2 - Fully Affinity-Aware)
#
# 角色:
# 這是一個「親和性感知的測試執行器」。
# 它被設計為由一個「環境設定 Wrapper」 (例如 run_with_cpu_shield.sh) 呼叫。
#
# 用法:
# ./scripts/performance_test_internal_example.sh [affinity_mode] [core_a] [core_b]
#
# 範例 (由 Wrapper 呼叫):
# (sudo ./scripts/run_with_cpu_shield.sh "6,7" ./scripts/performance_test_internal_example.sh rt-cross-core 6 7)
#
# 範例 (獨立執行，不受控):
# ./scripts/performance_test_internal_example.sh unlimited
# =====================================================================


# --- 1. 路徑設定 (強化版) ---

# 取得此腳本所在的目錄
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
# 專案根目錄 (假設此腳本在 'scripts' 資料夾中)
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"


# --- 2. 組態設定 ---

# Number of runs for each test case. average the results for accuracy.
NUM_RUNS=5

# The time in seconds to pause between each run to allow the system to cool down.
REST_INTERVAL_S=0.2

# Test cases.
PRODUCT_COUNTS=(100000000)
BUFFER_SIZES=(1 4 20) # Added buffer size test cases {1..100}
MESSAGE_LENS=(64)      # Added message length test cases

# Source code files.
THREAD_SRC="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc/itc_producer_consumer.c"
PROCESS_PRODUCER_SRC="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc/ipc_producer.c"
PROCESS_CONSUMER_SRC="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc/ipc_consumer.c"

# Names for our compiled executables (放置於 scripts 目錄下)
THREAD_EXE="${SCRIPT_DIR}/temp_thread_test"
PROCESS_PRODUCER_EXE="${SCRIPT_DIR}/temp_process_producer"
PROCESS_CONSUMER_EXE="${SCRIPT_DIR}/temp_process_consumer"


# --- 3. CPU Affinity 參數解析 ---
AFFINITY_MODE="$1" # 從第一個參數讀取模式
CORE_A="$2"
CORE_B="$3"

# 輸出檔案 (放置於 scripts 目錄下)
OUTPUT_FILE="${SCRIPT_DIR}/results_internal_${AFFINITY_MODE}.csv" 

# --- 模式驗證 ---
VALID_MODES=" unlimited single-core cross-core rt-single-core rt-cross-core "
if ! echo "${VALID_MODES}" | grep -q " ${AFFINITY_MODE} "; then
    echo "錯誤: 無效的 CPU 親和性模式 '$AFFINITY_MODE'."
    echo "用法: $0 [unlimited | single-core | cross-core | rt-single-core CORE_A | rt-cross-core CORE_A CORE_B]"
    exit 1
fi

# 檢查 RT 模式是否提供了足夠的參數
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
echo "===================================================="


# --- 4. 根據模式設定 Taskset 命令前綴與編譯旗標 ---
THREAD_CMD_PREFIX=""
PRODUCER_CMD_PREFIX=""
CONSUMER_CMD_PREFIX=""
AFFINITY_COMPILE_FLAGS="" 

case "$AFFINITY_MODE" in
    "single-core")
        echo ">> 綁定模式: (舊版) 所有工作將綁定到 CPU Core ${CORE_A}"
        THREAD_CMD_PREFIX="taskset -c ${CORE_A}"
        PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="taskset -c ${CORE_A}"
        # [修改] 傳遞核心 ID 給 C 編譯器
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "cross-core")
        echo ">> 綁定模式: (舊版) 跨核心 (Producer: ${CORE_A}, Consumer: ${CORE_B})"
        THREAD_CMD_PREFIX="taskset -c ${CORE_A},${CORE_B}" 
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
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;

    "rt-cross-core")
        echo ">> 綁定模式: Real-Time 跨核心 (Producer: ${CORE_A}, Consumer: ${CORE_B})"
        echo ">> 優先權: SCHED_FIFO (real-time)"
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A},${CORE_B}" 
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_B}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
esac
echo "----------------------------------------------------"


echo "Performance Test Script"
echo "Each test case will run ${NUM_RUNS} times."
echo "Rest interval between runs is ${REST_INTERVAL_S} seconds."
echo "Results will be saved to: ${OUTPUT_FILE}"

# Set up the CSV file and write the header.
echo "TestType,ProductCount,BufferSize,MessageLen,AvgInitTime,AvgCommTime" > ${OUTPUT_FILE}


# --- 5. Main test loop ---
for size in "${BUFFER_SIZES[@]}"; do
    for count in "${PRODUCT_COUNTS[@]}"; do
        for msg_len in "${MESSAGE_LENS[@]}"; do
            echo "----------------------------------------------------"
            echo ">> Testing with Product Count: ${count}, Buffer Size: ${size}, Message Len: ${msg_len}"
            
            if [[ -n "$AFFINITY_COMPILE_FLAGS" ]]; then
                echo "         [i] 資訊: 已啟用 C 語言層級 CPU 綁定 ($AFFINITY_COMPILE_FLAGS)"
            else
                echo "         [i] 資訊: 不使用 C 語言層級 CPU 綁定。"
            fi

            # --- Test 1: Thread Model (ITC) ---
            echo "         [1/2] Compiling and running the Thread model..."
            
            # [修改] Compile with AFFINITY_COMPILE_FLAGS
            gcc ${THREAD_SRC} -o ${THREAD_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            
            if [ $? -ne 0 ]; then
                echo "         !! Thread model compilation failed"
                continue 
            fi

            total_init_time=0.0
            total_comm_time=0.0
            
            for j in $(seq 1 ${NUM_RUNS}); do
                echo -ne "               - Running iteration ${j}/${NUM_RUNS}...\r"
                sleep ${REST_INTERVAL_S}
                
                # *** 執行綁定 ***
                result=$( ${THREAD_CMD_PREFIX} ${THREAD_EXE} )
                
                init_time=$(echo "$result" | awk -F',' '{print $1}')
                comm_time=$(echo "$result" | awk -F',' '{print $2}')
                
                total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
                total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
            done
            echo "" 

            avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            
            echo "Thread,${count},${size},${msg_len},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}
            echo "         ... Thread model test complete."


            # --- Test 2: Process Model (IPC) ---
            echo "         [2/2] Compiling and running the Process model..."

            # Compile with AFFINITY_COMPILE_FLAGS (之前沒有加這個)
            gcc ${PROCESS_PRODUCER_SRC} -o ${PROCESS_PRODUCER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            gcc ${PROCESS_CONSUMER_SRC} -o ${PROCESS_CONSUMER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            
            if [ $? -ne 0 ]; then
                echo "         !! Process model compilation failed"
                continue
            fi

            total_init_time=0.0
            total_comm_time=0.0

            for j in $(seq 1 ${NUM_RUNS}); do
                echo -ne "               - Running iteration ${j}/${NUM_RUNS}...\r"
                sleep ${REST_INTERVAL_S}

                # *** 執行綁定 (外部 taskset 仍保留作為雙重保障) ***
                ${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} &
                result=$( ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE} )
                
                wait # Ensure the background consumer has finished before the next iteration
                
                init_time=$(echo "$result" | awk -F',' '{print $1}')
                comm_time=$(echo "$result" | awk -F',' '{print $2}')
                total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
                total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
            done
            echo "" 

            avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            
            echo "Process,${count},${size},${msg_len},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}
            echo "         ... Process model test complete."

        done
    done
done


# --- 6. Cleanup ---
echo "----------------------------------------------------"
echo ">> Tests finished. Cleaning up compiled files..."
rm -f ${THREAD_EXE} ${PROCESS_PRODUCER_EXE} ${PROCESS_CONSUMER_EXE}

echo "-------------------------------------"
hours=$((SECONDS / 3600))
minutes=$(((SECONDS % 3600) / 60))
seconds=$((SECONDS % 60))
echo "所有測試完成，總共花費：${hours} 小時 ${minutes} 分 ${seconds} 秒"

echo ">> Complete. results are in ${OUTPUT_FILE}"