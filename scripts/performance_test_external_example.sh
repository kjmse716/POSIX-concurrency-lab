#!/bin/bash

# =====================================================================
# Comprehensive Performance Test Script (v4 - Batch Edition)
#
# Author: Gemini (as 資深聯發科韌體主管)
# Date: 2025-10-30
#
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
# =====================================================================

# --- Configuration ---
NUM_RUNS=200
REST_INTERVAL_S=0.1
OUTPUT_FILE="results.csv"

# --- Test Cases ---
PRODUCT_COUNTS=(10000 5000 100000)
BUFFER_SIZES=({1..100})
MESSAGE_LENS=(64 256 1500 64000)

# --- Path Configuration ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# IPC Paths
IPC_SRC_DIR="${SCRIPT_DIR}/../src/02_process_ipc_app"
IPC_PRODUCER_SRC="${IPC_SRC_DIR}/producer.c"
IPC_CONSUMER_SRC="${IPC_SRC_DIR}/consumer.c"
IPC_PRODUCER_EXE="${IPC_SRC_DIR}/producer"
IPC_CONSUMER_EXE="${IPC_SRC_DIR}/consumer"
IPC_RUN_SCRIPT="${IPC_SRC_DIR}/run_ipc_test.sh"

# ITC Paths
ITC_SRC_DIR="${SCRIPT_DIR}/../src/03_thread_itc_app"
ITC_SRC="${ITC_SRC_DIR}/thread_producer_consumer.c"
ITC_EXE="./thread_test_batch" # Use a unique name for the temporary executable

# --- Pre-run Checks ---
if [[ $EUID -ne 0 ]]; then
    echo "!! ERROR: This script requires root privileges (use sudo) to run 'perf stat'."
    exit 1
fi

echo "=========================================================="
echo "Starting Comprehensive IPC vs. ITC Performance Test..."
echo "Number of runs per test case: ${NUM_RUNS}"
echo "Results will be saved to: ${OUTPUT_FILE}"
echo "=========================================================="

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
      gcc "${ITC_SRC}" -o ${ITC_EXE} -DNUM_PRODUCTS=${pcount} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${mlen} -lpthread -lrt
      if [ $? -ne 0 ]; then
          echo "  !! ITC compilation failed. Skipping."
          continue
      fi

      total_init_time=0.0
      total_comm_time=0.0
      for ((j=1; j<=NUM_RUNS; j++)); do
          echo -ne "    - ITC Iteration ${j}/${NUM_RUNS}...\r"
          PERF_OUTPUT=$(mktemp)
          INTERNAL_TIME=$(sudo perf stat -o ${PERF_OUTPUT} ./${ITC_EXE})
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
      gcc "${IPC_PRODUCER_SRC}" -o ${IPC_PRODUCER_EXE} -DNUM_PRODUCTS=${pcount} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${mlen} -lpthread -lrt
      gcc "${IPC_CONSUMER_SRC}" -o ${IPC_CONSUMER_EXE} -DNUM_PRODUCTS=${pcount} -DBUFFER_SIZE=${bsize} -DMAX_MESSAGE_LEN=${mlen} -lpthread -lrt
      if [ $? -ne 0 ]; then
          echo "  !! IPC compilation failed. Skipping."
          continue
      fi

      total_init_time=0.0
      total_comm_time=0.0
      for ((j=1; j<=NUM_RUNS; j++)); do
          echo -ne "    - IPC Iteration ${j}/${NUM_RUNS}...\r"
          PERF_OUTPUT=$(mktemp)
          INTERNAL_TIME=$(sudo perf stat -o ${PERF_OUTPUT} ${IPC_RUN_SCRIPT})
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