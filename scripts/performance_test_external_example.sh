#!/bin/bash

# =====================================================================
# Comprehensive Performance Test Script (v4.2 - Full Affinity-Aware)
# Objective:
#   To conduct a rigorous, large-scale performance comparison between
#   Inter-Process Communication (IPC) and Inter-Thread Communication (ITC)
#   under a wide range of workloads.
#
# Measurement Philosophy:
#   This script uses the most robust measurement method. The primary metric
#   for overall performance, "AvgCommTime", is measured EXTERNALLY using
#   `perf stat`'s 'time elapsed'. This captures the true end-to-end
#   wall-clock time for the entire task, including all scheduling and
#   synchronization overhead, ensuring a fair comparison for both models.
#
#   The "AvgInitTime" is taken from the program's internal timer,
#   representing the setup phase before the main communication loop.
#
# 修改重點 (v4.2):
#   - 引入 AFFINITY_COMPILE_FLAGS。
#   - 為 IPC (Process) 模型加入編譯旗標，支援 C 語言層級的 CPU 綁核。
#
# 用法:
# ./scripts/performance_test_external_example.sh [affinity_mode] [core_a] [core_b]
#
# 範例 (由 run_with_cpu_shield.sh 呼叫):
# (sudo ./scripts/run_with_cpu_shield.sh "6,7" ./scripts/performance_test_external_example.sh rt-cross-core 6 7)
# =====================================================================

# --- Configuration ---
NUM_RUNS=200
REST_INTERVAL_S=0.1

# --- Test Cases ---
PRODUCT_COUNTS=(10000 5000 100000)
BUFFER_SIZES=({1..100})
MESSAGE_LENS=(64 256 1500 64000)

# --- Path Configuration ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# IPC/ITC Paths (v4)
SRC_DIR="${PROJECT_ROOT_DIR}/src/04_performance_comparison/ipc_itc"
IPC_PRODUCER_SRC="${SRC_DIR}/ipc_producer.c"
IPC_CONSUMER_SRC="${SRC_DIR}/ipc_consumer.c"
ITC_SRC="${SRC_DIR}/itc_producer_consumer.c"

IPC_PRODUCER_EXE="${SRC_DIR}/ipc_producer"
IPC_CONSUMER_EXE="${SRC_DIR}/ipc_consumer"
ITC_EXE="./thread_test_batch" # Use a unique name for the temporary executable

# --- 1. Affinity 參數解析 ---
AFFINITY_MODE="$1"
CORE_A="$2"
CORE_B="$3"

PRODUCER_CMD_PREFIX=""
CONSUMER_CMD_PREFIX=""
THREAD_CMD_PREFIX=""
AFFINITY_COMPILE_FLAGS="" # [修改] 改名為通用的編譯旗標

# 預設為 unlimited
if [ -z "$AFFINITY_MODE" ]; then
    AFFINITY_MODE="unlimited"
fi

OUTPUT_FILE="results_external_${AFFINITY_MODE}.csv"

echo "=========================================================="
echo ">> 正在以模式運行: ${AFFINITY_MODE}"
echo ">> 結果將儲存至: ${OUTPUT_FILE}"
echo "=========================================================="

case "$AFFINITY_MODE" in
    "rt-single-core")
        echo "   - 綁定: Real-Time 單一核心 (Core ${CORE_A})"
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        # [修改] 設定 C 語言層級綁核巨集
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_A}"
        ;;
    "rt-cross-core")
        echo "   - 綁定: Real-Time 跨核心 (P:${CORE_A}, C:${CORE_B})"
        THREAD_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A},${CORE_B}" 
        PRODUCER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_A}"
        CONSUMER_CMD_PREFIX="chrt -f 99 taskset -c ${CORE_B}"
        # [修改] 設定 C 語言層級綁核巨集
        AFFINITY_COMPILE_FLAGS="-DPRODUCER_CORE_ID=${CORE_A} -DCONSUMER_CORE_ID=${CORE_B}"
        ;;
    "unlimited")
        echo "   - 綁定: 不限制 (unlimited)"
        AFFINITY_COMPILE_FLAGS=""
        ;;
    *)
        echo "錯誤: 不支援的模式 '$AFFINITY_MODE'"
        exit 1
        ;;
esac
echo "----------------------------------------------------"

if [[ -n "$AFFINITY_COMPILE_FLAGS" ]]; then
    echo ">> 已啟用 C 語言編譯旗標: ${AFFINITY_COMPILE_FLAGS}"
fi


# --- Pre-run Checks ---
if [[ $EUID -ne 0 ]]; then
    echo "!! ERROR: This script requires root privileges (use sudo) to run 'perf stat'."
    exit 1
fi

# Setup CSV file header
echo "TestType,ProductCount,NumberOfBufferSlots,MessageLen,AvgInitTime,AvgCommTime" > ${OUTPUT_FILE}

# --- Main Test Loop ---
for pcount in "${PRODUCT_COUNTS[@]}"; do
  for bsize in "${BUFFER_SIZES[@]}"; do
    for mlen in "${MESSAGE_LENS[@]}"; do
      echo "----------------------------------------------------"
      echo ">> Testing: P=${pcount}, B=${bsize}, M=${mlen}"

      # --- ITC (Thread) Model Test ---
      echo "  [1/2] Running ITC (Thread) Model..."
      # [修改] 使用 AFFINITY_COMPILE_FLAGS
      gcc "${ITC_SRC}" -o ${ITC_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${pcount} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${mlen} -lpthread -lrt
      if [ $? -ne 0 ]; then
          echo "  !! ITC compilation failed. Skipping."
          continue
      fi

      total_init_time=0.0
      total_comm_time=0.0
      for ((j=1; j<=NUM_RUNS; j++)); do
          echo -ne "    - ITC Iteration ${j}/${NUM_RUNS}...\r"
          PERF_OUTPUT=$(mktemp)
          
          # 外部綁定 (taskset) 仍保留作為雙重保障
          INTERNAL_TIME=$(sudo perf stat -o ${PERF_OUTPUT} ${THREAD_CMD_PREFIX} ./${ITC_EXE})
          
          PERF_TIME=$(grep "seconds time elapsed" ${PERF_OUTPUT} | awk '{print $1}')
          
          init_time=$(echo ${INTERNAL_TIME} | awk -F',' '{print $1}')
          comm_time=${PERF_TIME}

          total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
          total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')

          rm ${PERF_OUTPUT}
          sleep ${REST_INTERVAL_S}
      done
      echo ""
      avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{printf "%.9f", total/n}')
      avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{printf "%.9f", total/n}')
      echo "Thread,${pcount},${bsize},${mlen},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}


      # --- IPC (Process) Model Test ---
      echo "  [2/2] Running IPC (Process) Model..."
      
      # [修改] 加入 AFFINITY_COMPILE_FLAGS 以支援 C 語言層級綁核
      gcc "${IPC_PRODUCER_SRC}" -o ${IPC_PRODUCER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${pcount} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${mlen} -lpthread -lrt
      gcc "${IPC_CONSUMER_SRC}" -o ${IPC_CONSUMER_EXE} ${AFFINITY_COMPILE_FLAGS} -DNUM_PRODUCTS=${pcount} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${mlen} -lpthread -lrt
      
      if [ $? -ne 0 ]; then
          echo "  !! IPC compilation failed. Skipping."
          continue
      fi

      total_init_time=0.0
      total_comm_time=0.0
      for ((j=1; j<=NUM_RUNS; j++)); do
          echo -ne "    - IPC Iteration ${j}/${NUM_RUNS}...\r"
          PERF_OUTPUT=$(mktemp)

          # 手動分離 consumer 和 producer
          ${CONSUMER_CMD_PREFIX} ${IPC_CONSUMER_EXE} &
          CONSUMER_PID=$!
          
          # Producer 會印出內部時間
          INTERNAL_TIME=$(sudo perf stat -o ${PERF_OUTPUT} ${PRODUCER_CMD_PREFIX} ${IPC_PRODUCER_EXE})
          
          wait $CONSUMER_PID # 等待 consumer 結束
          
          PERF_TIME=$(grep "seconds time elapsed" ${PERF_OUTPUT} | awk '{print $1}')

          init_time=$(echo ${INTERNAL_TIME} | awk -F',' '{print $1}')
          comm_time=${PERF_TIME}
          
          total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
          total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
          
          rm ${PERF_OUTPUT}
          sleep ${REST_INTERVAL_S}
      done
      echo ""
      avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{printf "%.9f", total/n}')
      avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{printf "%.9f", total/n}')
      echo "Process,${pcount},${bsize},${mlen},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}
    done
  done
done

# --- Cleanup ---
echo "----------------------------------------------------"
echo ">> Tests finished. Cleaning up compiled files..."
rm -f ${IPC_PRODUCER_EXE} ${IPC_CONSUMER_EXE} ${ITC_EXE}

echo ">> Complete. Results are in ${OUTPUT_FILE}"