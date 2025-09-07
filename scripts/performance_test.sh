# --- Configuration ---
# Number of runs for each test case. average the results for accuracy.
NUM_RUNS=5

# Test cases.
PRODUCT_COUNTS=(1000 10000 100000 1000000 10000000 100000000)

OUTPUT_FILE="results_avg.csv"

# Source code files.
THREAD_SRC="./src/03_thread_itc_app/thread_producer_consumer_sem.c"
PROCESS_PRODUCER_SRC="./src/02_process_ipc_app/producer.c"
PROCESS_CONSUMER_SRC="./src/02_process_ipc_app/consumer.c"

# Names for our compiled executables.
THREAD_EXE="./thread_test"
PROCESS_PRODUCER_EXE="./process_producer"
PROCESS_CONSUMER_EXE="./process_consumer"



echo "IPC Performance Test Script"
echo "Each test case will run ${NUM_RUNS} times."
echo "Results will be saved to: ${OUTPUT_FILE}"

# Set up the CSV file and write the header.
echo "TestType,ProductCount,AvgInitTime,AvgCommTime" > ${OUTPUT_FILE}



for count in "${PRODUCT_COUNTS[@]}"; do
    echo "----------------------------------------------------"
    echo ">> Testing with product count: ${count}"

    # --- Test 1: Thread Model ---
    echo "   [1/2] Compiling and running the Thread model..."
    
    # Compile the thread program.
    # -DNUM_PRODUCTS=${count} sets the workload size at compile time.
    # -lpthread links the POSIX threads library.
    gcc ${THREAD_SRC} -o ${THREAD_EXE} -DNUM_PRODUCTS=${count} -lpthread
    if [ $? -ne 0 ]; then
        echo "   !! Thread model compilation failed"
        continue 
    fi

    # Initialize variables to sum up the times for averaging.
    total_init_time=0.0
    total_comm_time=0.0
    
    # Inner loop: run the actual test NUM_RUNS times.
    for j in $(seq 1 ${NUM_RUNS}); do
        echo -ne "      - Running iteration ${j}/${NUM_RUNS}...\r"
        result=$( ${THREAD_EXE} )
        
        # Use awk to handle floating point math since bash only does integers.
        init_time=$(echo "$result" | awk -F',' '{print $1}')
        comm_time=$(echo "$result" | awk -F',' '{print $2}')
        
        total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
        total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
    done
    echo "" 


    avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
    avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
    
    # Append the averaged result to our CSV file.
    echo "Thread,${count},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}
    echo "   ... Thread model test complete."


    # --- Test 2: Process Model ---
    echo "   [2/2] Compiling and running the Process model..."

    # Compile the process programs.
    # -lrt links the real-time library needed for shm_open and sem_open.
    gcc ${PROCESS_PRODUCER_SRC} -o ${PROCESS_PRODUCER_EXE} -DNUM_PRODUCTS=${count} -lpthread -lrt
    gcc ${PROCESS_CONSUMER_SRC} -o ${PROCESS_CONSUMER_EXE} -DNUM_PRODUCTS=${count} -lpthread -lrt
    if [ $? -ne 0 ]; then
        echo "   !! Process model compilation failed"
        continue
    fi

    # Reset the sum variables for this new test.
    total_init_time=0.0
    total_comm_time=0.0

    # Inner loop for averaging.
    for j in $(seq 1 ${NUM_RUNS}); do
        echo -ne "      - Running iteration ${j}/${NUM_RUNS}...\r"
        
        # Execute: Run the consumer in the background (&) first.
        ${PROCESS_CONSUMER_EXE} &

        # Then run the producer in the foreground and capture its output.
        result=$( ${PROCESS_PRODUCER_EXE} )
        
        init_time=$(echo "$result" | awk -F',' '{print $1}')
        comm_time=$(echo "$result" | awk -F',' '{print $2}')
        total_init_time=$(awk -v t1="$total_init_time" -v t2="$init_time" 'BEGIN{print t1+t2}')
        total_comm_time=$(awk -v t1="$total_comm_time" -v t2="$comm_time" 'BEGIN{print t1+t2}')
    done
    echo "" 

    # Calculate the average for the process model.
    avg_init_time=$(awk -v total="$total_init_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
    avg_comm_time=$(awk -v total="$total_comm_time" -v n="$NUM_RUNS" 'BEGIN{print total/n}')
    
    # Append the result to the CSV.
    echo "Process,${count},${avg_init_time},${avg_comm_time}" >> ${OUTPUT_FILE}
    echo "   ... Process model test complete."

done


# --- Cleanup ---
echo "----------------------------------------------------"
echo ">> Tests finished. Cleaning up compiled files..."
rm -f ${THREAD_EXE} ${PROCESS_PRODUCER_EXE} ${PROCESS_CONSUMER_EXE}

echo ">> Complete. results are in ${OUTPUT_FILE}"