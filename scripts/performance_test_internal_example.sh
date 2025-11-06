#!/bin/bash

# --- Configuration ---
# Number of runs for each test case. average the results for accuracy.
NUM_RUNS=20

# The time in seconds to pause between each run to allow the system to cool down.
REST_INTERVAL_S=0.1

# Test cases.
PRODUCT_COUNTS=(5000 100000)
BUFFER_SIZES=({1..100}) # Added buffer size test cases
MESSAGE_LENS=(64 256 1500)    # Added message length test cases

OUTPUT_FILE="results.csv"

# Source code files.
THREAD_SRC="./src/04_performance_comparison/ipc_itc/itc_producer_consumer.c"
PROCESS_PRODUCER_SRC="./src/04_performance_comparison/ipc_itc/ipc_producer.c"
PROCESS_CONSUMER_SRC="./src/04_performance_comparison/ipc_itc/ipc_consumer.c"

# Names for our compiled executables.
THREAD_EXE="./thread_test"
PROCESS_PRODUCER_EXE="./process_producer"
PROCESS_CONSUMER_EXE="./process_consumer"



echo "IPC Performance Test Script"
echo "Each test case will run ${NUM_RUNS} times."
echo "Rest interval between runs is ${REST_INTERVAL_S} seconds."
echo "Results will be saved to: ${OUTPUT_FILE}"

# Set up the CSV file and write the header with the new BufferSize + MessageLen columns.
echo "TestType,ProductCount,BufferSize,MessageLen,AvgInitTime,AvgCommTime" > ${OUTPUT_FILE}


# --- Main test loop ---
for size in "${BUFFER_SIZES[@]}"; do
    for count in "${PRODUCT_COUNTS[@]}"; do
        for msg_len in "${MESSAGE_LENS[@]}"; do
            echo "----------------------------------------------------"
            echo ">> Testing with Product Count: ${count}, Buffer Size: ${size}, Message Len: ${msg_len}"

            # --- Test 1: Thread Model ---
            echo "    [1/2] Compiling and running the Thread model..."
            
            # Compile the thread program with dynamic NUM_PRODUCTS, BUFFER_SIZE and MAX_MESSAGE_LEN.
            gcc ${THREAD_SRC} -o ${THREAD_EXE} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            if [ $? -ne 0 ]; then
                echo "    !! Thread model compilation failed"
                continue 
            fi

            total_init_time=0.0
            total_comm_time=0.0
            
            for j in $(seq 1 ${NUM_RUNS}); do
                echo -ne "       - Running iteration ${j}/${NUM_RUNS}...\r"
                sleep ${REST_INTERVAL_S}
                result=$( ${THREAD_EXE} )
                
                init_time=$(echo "$result" | awk -F',' '{print $1}')
                comm_time=$(echo "$result" | awk -F',' '{print $2}')
                
                total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
                total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
            done
            echo "" 

            avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
            
            echo "Thread,${count},${size},${msg_len},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}
            echo "    ... Thread model test complete."


            # --- Test 2: Process Model ---
            echo "    [2/2] Compiling and running the Process model..."

            # Compile the process programs with dynamic NUM_PRODUCTS, BUFFER_SIZE and MAX_MESSAGE_LEN.
            gcc ${PROCESS_PRODUCER_SRC} -o ${PROCESS_PRODUCER_EXE} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            gcc ${PROCESS_CONSUMER_SRC} -o ${PROCESS_CONSUMER_EXE} -DNUM_PRODUCTS=${count} -DBUFFER_SIZE=${size} -DMAX_MESSAGE_LEN=${msg_len} -lpthread -lrt
            if [ $? -ne 0 ]; then
                echo "    !! Process model compilation failed"
                continue
            fi

            total_init_time=0.0
            total_comm_time=0.0

            for j in $(seq 1 ${NUM_RUNS}); do
                echo -ne "       - Running iteration ${j}/${NUM_RUNS}...\r"
                sleep ${REST_INTERVAL_S}

                ${PROCESS_CONSUMER_EXE} &
                result=$( ${PROCESS_PRODUCER_EXE} )
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
            echo "    ... Process model test complete."

        done
    done
done


# --- Cleanup ---
echo "----------------------------------------------------"
echo ">> Tests finished. Cleaning up compiled files..."
rm -f ${THREAD_EXE} ${PROCESS_PRODUCER_EXE} ${PROCESS_CONSUMER_EXE}

echo ">> Complete. results are in ${OUTPUT_FILE}"