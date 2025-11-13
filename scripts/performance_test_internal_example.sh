#!/bin/bash

# --- Configuration ---

# Number of runs for each test case. average the results for accuracy.
NUM_RUNS=5

# The time in seconds to pause between each run to allow the system to cool down.
REST_INTERVAL_S=0.2

# Test cases.
PRODUCT_COUNTS=(100000000)
BUFFER_SIZES=({1..100}) # Added buffer size test cases
MESSAGE_LENS=(64)      # Added message length test cases

OUTPUT_FILE="results_${AFFINITY_MODE}.csv" # 讓不同模式的結果保存在不同檔案

# Source code files.
THREAD_SRC="./src/04_performance_comparison/ipc_itc/itc_producer_consumer.c"
PROCESS_PRODUCER_SRC="./src/04_performance_comparison/ipc_itc/ipc_producer.c"
PROCESS_CONSUMER_SRC="./src/04_performance_comparison/ipc_itc/ipc_consumer.c"

# Names for our compiled executables.
THREAD_EXE="./thread_test"
PROCESS_PRODUCER_EXE="./process_producer"
PROCESS_CONSUMER_EXE="./process_consumer"


# --- CPU Affinity Configuration ---
AFFINITY_MODE="$1" # 從第一個參數讀取模式
CORE_A=0           # (舊版 cross-core/single-core) 測試用的第一個 CPU 核心
CORE_B=1           # (舊版 cross-core) 測試用的第二個 CPU 核心

# 'rt-*' 模式會從 $2 和 $3 讀取核心
CORE_RT_A="$2"
CORE_RT_B="$3"

# --- 模式驗證 (更穩健的版本) ---
VALID_MODES=" unlimited single-core cross-core rt-single-core rt-cross-core "
if ! echo "${VALID_MODES}" | grep -q " ${AFFINITY_MODE} "; then
    echo "錯誤: 無效的 CPU 親和性模式 '$AFFINITY_MODE'."
    echo "用法: $0 [unlimited | single-core | cross-core | rt-single-core CORE_A | rt-cross-core CORE_A CORE_B]"
    exit 1
fi

# 檢查 RT 模式是否提供了足夠的參數
if [[ "$AFFINITY_MODE" == "rt-cross-core" && ( -z "$CORE_RT_A" || -z "$CORE_RT_B" ) ]]; then
    echo "錯誤: rt-cross-core 模式需要提供兩個核心 ID。"
    echo "用法: (此腳本應由 run_rt_test.sh 呼叫)"
    exit 1
fi

if [[ "$AFFINITY_MODE" == "rt-single-core" && -z "$CORE_RT_A" ]]; then
    echo "錯誤: rt-single-core 模式需要提供一個核心 ID。"
    echo "用法: (此腳本應由 run_rt_test.sh 呼叫)"
    exit 1
fi


echo "===================================================="
echo ">> 正在以模式運行: ${AFFINITY_MODE}"
echo "===================================================="


# --- 根據模式設定 Taskset 命令前綴 ---
THREAD_CMD_PREFIX=""
PRODUCER_CMD_PREFIX=""
CONSUMER_CMD_PREFIX=""
THREAD_COMPILE_FLAGS="" # C 語言編譯旗標

case "$AFFINITY_MODE" in
    "single-core")
        echo ">> 綁定模式: (舊版) 所有工作將綁定到 CPU Core ${CORE_A}"
        THREAD_CMD_PREFIX="taskset -c ${CORE_A}"
        PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="taskset -c ${CORE_A}"
        THREAD_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "cross-core")
        echo ">> 綁定模式: (舊版) 跨核心 (Producer: ${CORE_A}, Consumer: ${CORE_B})"
        THREAD_CMD_PREFIX="taskset -c ${CORE_A},${CORE_B}" 
        PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="taskset -c ${CORE_B}"
        THREAD_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
    "unlimited")
        echo ">> 綁定模式: 不限制 (由 Linux 排程器自行決定)"
        THREAD_COMPILE_FLAGS=""
        ;;

    # --- (新) Real-Time 模式 ---

    "rt-single-core")
        echo ">> 綁定模式: Real-Time 單一核心 (CPU Core ${CORE_RT_A})"
        echo ">> 優先權: SCHED_FIFO (real-time)"
        # chrt -f 99: 將程式設為 SCHED_FIFO (即時排程)，優先權 99 (最高)
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_RT_A}"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_RT_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_RT_A}"
        THREAD_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_RT_A} -DCONSUMER_CORE_ID=${CORE_RT_A}"
        ;;

    "rt-cross-core")
        echo ">> 綁定模式: Real-Time 跨核心 (Producer: ${CORE_RT_A}, Consumer: ${CORE_RT_B})"
        echo ">> 優先權: SCHED_FIFO (real-time)"
        
        # chrt -f 99: 將程式設為 SCHED_FIFO (即時排程)，優先權 99 (最高)
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_RT_A},${CORE_RT_B}" 
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_RT_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_RT_B}"
        THREAD_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_RT_A} -DCONSUMER_CORE_ID=${CORE_RT_B}"
        ;;
esac
echo "----------------------------------------------------"






echo "IPC Performance Test Script"
echo "Each test case will run ${NUM_RUNS} times."
echo "Rest interval between runs is ${REST_INTERVAL_S} seconds."
echo "Results will be saved to: ${OUTPUT_FILE}"

# Set up the CSV file and write the header with the new BufferSize + MessageLen columns.
# 替換掉舊檔案
echo "TestType,ProductCount,BufferSize,MessageLen,AvgInitTime,AvgCommTime" > ${OUTPUT_FILE}


# --- Main test loop ---
for size in "${BUFFER_SIZES[@]}"; do
    for count in "${PRODUCT_COUNTS[@]}"; do
        for msg_len in "${MESSAGE_LENS[@]}"; do
            echo "----------------------------------------------------"
            echo ">> Testing with Product Count: ${count}, Buffer Size: ${size}, Message Len: ${msg_len}"

            # --- Test 1: Thread Model ---
            if [[ -n "$THREAD_COMPILE_FLAGS" ]]; then
                echo "         [i] 資訊: Thread 模型將啟用 C 語言層級 CPU 綁定 ($THREAD_COMPILE_FLAGS)"
            else
                echo "         [i] 資訊: Thread 模型將不使用 C 語言層級 CPU 綁定。"
            fi
            echo "         [1/2] Compiling and running the Thread model..."
            
            # Compile the thread program with dynamic NUM_PRODUCTS, BUFFER_SIZE and MAX_MESSAGE_LEN.
            gcc ${THREAD_SRC} -o ${THREAD_EXE} ${THREAD_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            
            if [ $? -ne 0 ]; then
                echo "         !! Thread model compilation failed"
                continue 
            fi

            total_init_time=0.0
            total_comm_time=0.0
            
            for j in $(seq 1 ${NUM_RUNS}); do
                echo -ne "               - Running iteration ${j}/${NUM_RUNS}...\r"
                sleep ${REST_INTERVAL_S}
                
                # *** MODIFICATION: Added command prefix ***
                result=$( ${THREAD_CMD_PREFIX} ${THREAD_EXE} )
                
                init_time=$(echo "$result" | awk -F',' '{print $1}')
                comm_time=$(echo "$result" | awk -F',' '{print $2}')
                
                # 【修正】: 原本這裡是 t1+t1+t2，已修正為 t1+t2
                total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
                total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
            done
            echo "" 

            avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            
            echo "Thread,${count},${size},${msg_len},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}
            echo "         ... Thread model test complete."


            # --- Test 2: Process Model ---
            echo "         [2/2] Compiling and running the Process model..."

            # Compile the process programs with dynamic NUM_PRODUCTS, BUFFER_SIZE and MAX_MESSAGE_LEN.
            gcc ${PROCESS_PRODUCER_SRC} -o ${PROCESS_PRODUCER_EXE} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            gcc ${PROCESS_CONSUMER_SRC} -o ${PROCESS_CONSUMER_EXE} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            if [ $? -ne 0 ]; then
                echo "         !! Process model compilation failed"
                continue
            fi

            total_init_time=0.0
            total_comm_time=0.0

            for j in $(seq 1 ${NUM_RUNS}); do
                echo -ne "               - Running iteration ${j}/${NUM_RUNS}...\r"
                sleep ${REST_INTERVAL_S}

                # *** MODIFICATION: Added command prefixes ***
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


# --- Cleanup ---
echo "----------------------------------------------------"
echo ">> Tests finished. Cleaning up compiled files..."
rm -f ${THREAD_EXE} ${PROCESS_PRODUCER_EXE} ${PROCESS_CONSUMER_EXE}


# $SECONDS 會自動回報從腳本開始到現在所經過的秒數

echo "-------------------------------------"

hours=$((SECONDS / 3600))
minutes=$(((SECONDS % 3600) / 60))
seconds=$((SECONDS % 60))

echo "所有測試完成，總共花費：${hours} 小時 ${minutes} 分 ${seconds} 秒"

echo ">> Complete. results are in ${OUTPUT_FILE}"