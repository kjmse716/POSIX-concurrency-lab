#define _GNU_SOURCE            // 為了 pthread_setaffinity_np
#define _POSIX_C_SOURCE 200809L // CLOCK_MONOTONIC 
#include <stdio.h>
#include <string.h>
#include <stdlib.h>      // macros
#include <unistd.h>      // sleep
#include <pthread.h>
#include <sched.h>             // 為了 cpu_set_t 和 sched_setaffinity
#include <semaphore.h> // for time measurement (wait until threads are ready).
#include <time.h> 
#include <stdint.h>
#include <stdalign.h>

#ifdef DEBUG
    #define LOG(msg, ...) printf(msg, ##__VA_ARGS__);
#else
    #define LOG(msg, ...)
#endif


// --- Workload setting ---
#ifndef NUM_PRODUCTS
    #define NUM_PRODUCTS 100000
#endif

// --- Buffer setting --- 
#ifndef BUFFER_SIZE
    #define BUFFER_SIZE 1
#endif

#ifndef MAX_MESSAGE_LEN
    #define MAX_MESSAGE_LEN 1024
#endif  
static volatile uint64_t final_checksum;
static char template_message[MAX_MESSAGE_LEN];

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t product_cond;
    pthread_cond_t space_cond;
    
    // --- Circular buffer ---
    int message_ready;
    int curr_producer, curr_consumer;
    alignas(64) char message[BUFFER_SIZE][MAX_MESSAGE_LEN];

    /* --- For time measurement --- */
    sem_t ready_sem; 
    sem_t start_gun_sem; 
    sem_t complete;

} shared_data;

double get_elapsed_seconds(struct timespec start, struct timespec end) {
    return (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
}

void pin_thread_to_core(int core_id) {
    cpu_set_t cpuset;       
    CPU_ZERO(&cpuset);      
    CPU_SET(core_id, &cpuset); 

    pthread_t current_thread = pthread_self(); 
    
    if (pthread_setaffinity_np(current_thread, sizeof(cpu_set_t), &cpuset) != 0) {
        perror("pthread_setaffinity_np failed");
    } else {
        LOG("Thread %lu pinned to Core %d\n", (unsigned long)current_thread, core_id);
    }
}

// ---------------------------------------------------------
// [FlameGraph 重構] 獨立的業務邏輯與關鍵區函式
// ---------------------------------------------------------

/**
 * @brief 純粹的 CPU 計算負載 (Checksum)
 * @note 使用 noinline 防止編譯器優化，確保在 FlameGraph 中可見
 */
__attribute__((noinline))
long long task_compute_checksum(const char *buffer, size_t len) {
    long long sum = 0;
    for (size_t i = 0; i < len; i++) {
        sum += buffer[i];
    }
    return sum;
}

/**
 * @brief Producer 的關鍵區操作 (Lock -> Wait -> Write -> Signal -> Unlock)
 * @note 這代表 "IPC 通訊開銷" (Synchronization + Memory Copy)
 */
__attribute__((noinline))
void task_produce_safe(shared_data *data_ptr, const char *src_buffer) {
    // 1. Lock
    if (pthread_mutex_lock(&data_ptr->mutex) != 0) {
        perror("pthread_mutex_lock in producer");
        return;
    }

    // 2. Wait for space
    while (data_ptr->message_ready >= BUFFER_SIZE) {
        if (pthread_cond_wait(&data_ptr->space_cond, &data_ptr->mutex) != 0) {
            perror("producer cond_wait space fail.");
        }
    }
    
    // 3. Write data (I/O)
    memcpy(data_ptr->message[data_ptr->curr_producer], src_buffer, MAX_MESSAGE_LEN);
    
    #ifdef DEBUG
        // DEBUG 模式下額外寫入識別字串 (稍微影響效能但方便除錯)
        sprintf(data_ptr->message[data_ptr->curr_producer], "Product");
    #endif

    LOG("Producer created: %s\n", data_ptr->message[data_ptr->curr_producer]);
    data_ptr->curr_producer = (data_ptr->curr_producer + 1) % BUFFER_SIZE;
    data_ptr->message_ready += 1;

    // 4. Signal
    if (pthread_cond_signal(&data_ptr->product_cond) != 0) {
        perror("pthread_cond_signal for product");
    }

    // 5. Unlock
    if (pthread_mutex_unlock(&data_ptr->mutex) != 0) {
        perror("pthread_mutex_unlock");
    }
}

/**
 * @brief Consumer 的關鍵區操作 (Lock -> Wait -> Read/Copy -> Signal -> Unlock)
 * @note 將資料從 Shared Memory 複製到 Local Buffer，以便盡快釋放鎖
 */
__attribute__((noinline))
void task_consume_safe(shared_data *data_ptr, char *local_buffer) {
    // 1. Lock
    if (pthread_mutex_lock(&data_ptr->mutex) != 0) {
        perror("consumer pthread_mutex_lock failed.");
        return;
    }
    
    // 2. Wait for product
    while (data_ptr->message_ready < 1) {
        if (pthread_cond_wait(&data_ptr->product_cond, &data_ptr->mutex) != 0) {
            perror("pthread_cond_wait(product_cond)");
        }
    }

    // 3. Read data (Copy to local buffer)
    memcpy(local_buffer, data_ptr->message[data_ptr->curr_consumer], MAX_MESSAGE_LEN);
    
    LOG("Consumer got: %s\n", local_buffer);

    data_ptr->curr_consumer = (data_ptr->curr_consumer + 1) % BUFFER_SIZE;
    data_ptr->message_ready -= 1;

    // 4. Signal
    if (pthread_cond_signal(&data_ptr->space_cond) != 0) {
        perror("pthread_cond_signal for spac"); 
    }

    // 5. Unlock
    if (pthread_mutex_unlock(&data_ptr->mutex) != 0) {
        perror("pthread_mutex_unlock");
    }
}

// ---------------------------------------------------------

// Producer thread function
void* producer(void* arg) {

    #ifdef PRODUCER_CORE_ID
        pin_thread_to_core(PRODUCER_CORE_ID);
    #endif

    shared_data *data_ptr = (shared_data*)arg;

    sem_post(&data_ptr->ready_sem);
    sem_wait(&data_ptr->start_gun_sem);

    for (int i = 0; i < NUM_PRODUCTS; i++) {
        // [FlameGraph] 呼叫封裝好的通訊函式
        task_produce_safe(data_ptr, template_message);
    }
    return NULL;
}

// Consumer thread function
void* consumer(void* arg) {
    
    #ifdef CONSUMER_CORE_ID
        pin_thread_to_core(CONSUMER_CORE_ID);
    #endif
    
    shared_data *data_ptr = (shared_data*)arg;

    // 分配 Local Buffer，避免大封包撐爆 Stack
    char *local_buffer = (char*)malloc(MAX_MESSAGE_LEN);
    if (!local_buffer) {
        perror("Failed to allocate local buffer");
        return NULL;
    }

    sem_post(&data_ptr->ready_sem);
    sem_wait(&data_ptr->start_gun_sem);

    for (int i = 0; i < NUM_PRODUCTS; i++) {
        // 1. [IO/Sync] 從共享記憶體讀取資料 (持有鎖)
        task_consume_safe(data_ptr, local_buffer);

        // 2. [Compute] 計算 Checksum (無鎖狀態，純 CPU 運算)
        // 這在 Flame Graph 中會顯示為獨立的一根柱子
        long long cs = task_compute_checksum(local_buffer, MAX_MESSAGE_LEN);
        
        // 防止編譯器將計算優化移除
        final_checksum = cs; 
    }
    
    sem_post(&data_ptr->complete);
    free(local_buffer);

    return NULL;
}


int main() {
    memset(template_message, 'A', MAX_MESSAGE_LEN);
    template_message[MAX_MESSAGE_LEN - 1] = '\0';

    struct timespec start_time, communication_start_time, communication_end_time;
    clock_gettime(CLOCK_MONOTONIC, &start_time);

    pthread_t producer_thread, consumer_thread;
    shared_data data; // Stack allocation is risky for large buffer, but shared_data is passed by pointer usually. 
                      // Wait, here 'data' IS the shared memory structure including the huge buffer.
                      // For ITC with large buffers (e.g. 8MB), stack allocation WILL crash.
                      // Ideally this should be malloc'd too, but preserving original structure for now unless requested.
                      // Note: Standard stack is ~8MB. If MAX_MESSAGE_LEN * BUFFER_SIZE > 8MB, this crashes.
                      // Suggestion: Use static or malloc for 'data' if getting segfaults.

    data.curr_producer = 0;
    data.curr_consumer = 0;
    data.message_ready = 0; 

    if( sem_init(&data.ready_sem, 0, 0)== -1||
        sem_init(&data.start_gun_sem, 0, 0)== -1||
        sem_init(&data.complete,0 ,0)== -1){
        perror("sem_init failed.");
        return EXIT_FAILURE;
    }

    if (pthread_mutex_init(&data.mutex, NULL) != 0 ||
        pthread_cond_init(&data.product_cond, NULL) != 0 ||
        pthread_cond_init(&data.space_cond, NULL) != 0) {
        perror("init failed!!");
        return EXIT_FAILURE;
    }

    LOG("pthread mutex & condvars init OK.\n");

    if (pthread_create(&producer_thread, NULL, producer, &data) != 0) {
        perror("pthread_create(producer) failed.");
        return EXIT_FAILURE;
    }
    if (pthread_create(&consumer_thread, NULL, consumer, &data) != 0) {
        perror("pthread_create(consumer) failed.");
        return EXIT_FAILURE;
    }

    sem_wait(&data.ready_sem);
    sem_wait(&data.ready_sem);

    clock_gettime(CLOCK_MONOTONIC, &communication_start_time);
    sem_post(&data.start_gun_sem);
    sem_post(&data.start_gun_sem);

    if(sem_wait(&data.complete) == -1){
        perror("sem_wait(&data>complete) fail.");
        return EXIT_FAILURE;
    }
    clock_gettime(CLOCK_MONOTONIC, &communication_end_time);

    if (pthread_join(producer_thread, NULL) != 0) perror("pthread_join (producer) failed.");
    if (pthread_join(consumer_thread, NULL) != 0) perror("pthread_join (consumer) failed.");

    if( pthread_mutex_destroy(&data.mutex) != 0||
        pthread_cond_destroy(&data.space_cond) != 0 ||
        pthread_cond_destroy(&data.product_cond) != 0){
        perror("mutex, cond destroy failed.");
        return EXIT_FAILURE;
    }

    double initialize_time = get_elapsed_seconds(start_time, communication_start_time);
    double communication_time = get_elapsed_seconds(communication_start_time, communication_end_time);
    LOG("Total run time: %.9f seconds\n", initialize_time);
    LOG("Total communication time: %.9f seconds\n", communication_time);
    printf("%.9f,%.9f\n",initialize_time,communication_time);

    sem_destroy(&data.ready_sem); 
    sem_destroy(&data.start_gun_sem); 
    sem_destroy(&data.complete);

    return EXIT_SUCCESS;
}