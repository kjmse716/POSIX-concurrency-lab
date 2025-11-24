#!/bin/bash

# =====================================================================
# Performance Test Script (v2.1 - Parametric Throughput Analysis)
#
# 用法:
# ./script_name.sh [affinity_mode] [core_a] [core_b]
# =====================================================================

# --- 1. 路徑設定 ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# --- 2. 組態設定 ---

# 執行次數 (取平均以求準確)
NUM_RUNS=5
# 每次執行間的冷卻時間 (秒)
REST_INTERVAL_S=0.2

# [設定 A] 總傳輸量固定為 1GB (1024^3 bytes)
# 用途：確保無論封包大小為何，總工作量一致，便於比較 Throughput
TOTAL_BYTES=$((1024 * 1024 * 1024))

# [設定 B] 固定 Buffer Slot 數量
# 建議值 256 (甜蜜點)，避免過多 Context Switch 或 Cache Miss
BUFFER_SIZES=(256)

# [設定 C] 封包大小掃描範圍 (單位: Bytes)
# 將會使用 seq 指令產生序列
MSG_MIN=256     # 起始大小
MSG_MAX=65536    # 結束大小 (8KB)
MSG_STEP=256    # 間距 (Step)

# 原始碼路徑
THREAD_SRC="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc_flamegraph/itc_producer_consumer.c"
PROCESS_PRODUCER_SRC="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc_flamegraph/ipc_producer.c"
PROCESS_CONSUMER_SRC="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc_flamegraph/ipc_consumer.c"

# 編譯後執行檔名稱
THREAD_EXE="${SCRIPT_DIR}/temp_thread_test"
PROCESS_PRODUCER_EXE="${SCRIPT_DIR}/temp_process_producer"
PROCESS_CONSUMER_EXE="${SCRIPT_DIR}/temp_process_consumer"

# --- 3. CPU Affinity 參數解析 ---
AFFINITY_MODE="$1"
CORE_A="$2"
CORE_B="$3"

OUTPUT_FILE="${SCRIPT_DIR}/results_throughput_${AFFINITY_MODE}.csv"

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
echo "===================================================="

# --- 4. 根據模式設定 Taskset 命令前綴與編譯旗標 ---
THREAD_CMD_PREFIX=""
PRODUCER_CMD_PREFIX=""
CONSUMER_CMD_PREFIX=""
AFFINITY_COMPILE_FLAGS=""

case "$AFFINITY_MODE" in
    "single-core")
        THREAD_CMD_PREFIX="taskset -c ${CORE_A}"
        PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="taskset -c ${CORE_A}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "cross-core")
        THREAD_CMD_PREFIX="taskset -c ${CORE_A},${CORE_B}"
        PRODUCER_CMD_PREFIX="taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="taskset -c ${CORE_B}"
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
    "unlimited")
        AFFINITY_COMPILE_FLAGS=""
        ;;
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
esac
echo "----------------------------------------------------"
echo "Performance Test Script (Throughput Analysis)"
echo "Range: ${MSG_MIN} to ${MSG_MAX} bytes, Step: ${MSG_STEP}"
echo "Results will be saved to: ${OUTPUT_FILE}"

# 寫入 CSV Header (包含 Throughput 欄位)
echo "TestType,BufferSize,MessageLen,ProductCount,AvgCommTime(s),Throughput(MB/s)" > ${OUTPUT_FILE}

# 解除 Stack Size 限制
ulimit -s unlimited

# --- 5. Main test loop ---
for size in "${BUFFER_SIZES[@]}"; do

    # 使用 seq 指令動態產生封包大小序列
    # 替代原本寫死的 {256..8192..256}
    for msg_len in $(seq ${MSG_MIN} ${MSG_STEP} ${MSG_MAX}); do
        
        # [關鍵計算] 動態計算需要傳輸多少次才能達到 1GB
        count=$((TOTAL_BYTES / msg_len))

        echo "----------------------------------------------------"
        echo ">> Testing Packet Size: ${msg_len} Bytes | Count: ${count} | Buffer: ${size}"
        
        if [[ -n "$AFFINITY_COMPILE_FLAGS" ]]; then
             echo "         [i] Affinity Flags: $AFFINITY_COMPILE_FLAGS"
        fi

        # --- Test 1: Thread Model (ITC) ---
        # echo "         [1/2] Running Thread model..."
        
        gcc ${THREAD_SRC} -o ${THREAD_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
        
        if [ $? -ne 0 ]; then 
            echo "!! Compilation Failed for Thread Model"; continue; 
        fi

        total_comm_time=0.0
        
        for j in $(seq 1 ${NUM_RUNS}); do
            result=$( ${THREAD_CMD_PREFIX} ${THREAD_EXE} )
            comm_time=$(echo "$result" | awk -F',' '{print $2}')
            total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
            sleep ${REST_INTERVAL_S}
        done

        avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
        
        # 計算 Throughput (MB/s) = (1024MB) / Time
        throughput=$(awk -v bytes="$TOTAL_BYTES" -v time="$avg_comm_time" 'BEGIN { if(time>0) print (bytes/1024/1024)/time; else print 0 }')

        echo "Thread,${size},${msg_len},${count},${avg_comm_time},${throughput}" >> ${OUTPUT_FILE}


        # --- Test 2: Process Model (IPC) ---
        # echo "         [2/2] Running Process model..."

        gcc ${PROCESS_PRODUCER_SRC} -o ${PROCESS_PRODUCER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
        gcc ${PROCESS_CONSUMER_SRC} -o ${PROCESS_CONSUMER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
        
        if [ $? -ne 0 ]; then 
            echo "!! Compilation Failed for Process Model"; continue; 
        fi

        total_comm_time=0.0

        for j in $(seq 1 ${NUM_RUNS}); do
            # 啟動 Consumer (背景)
            ${CONSUMER_CMD_PREFIX} ${PROCESS_CONSUMER_EXE} &
            # 啟動 Producer (前景等待)
            result=$( ${PRODUCER_CMD_PREFIX} ${PROCESS_PRODUCER_EXE} )
            wait # 等待背景 Consumer 結束
            
            comm_time=$(echo "$result" | awk -F',' '{print $2}')
            total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
            sleep ${REST_INTERVAL_S}
        done

        avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
        
        # 計算 Throughput
        throughput=$(awk -v bytes="$TOTAL_BYTES" -v time="$avg_comm_time" 'BEGIN { if(time>0) print (bytes/1024/1024)/time; else print 0 }')

        echo "Process,${size},${msg_len},${count},${avg_comm_time},${throughput}" >> ${OUTPUT_FILE}

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
echo ">> Complete. Results in ${OUTPUT_FILE}"