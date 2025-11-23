#define _GNU_SOURCE  
#include <sys/mman.h>
#include <fcntl.h>     
#include <sys/stat.h>  
#include <stdio.h>     
#include <stdlib.h>    
#include <unistd.h>    
#include <pthread.h>
#include <sched.h>     
#include <semaphore.h>
#include <errno.h>
#include <string.h>    // memcpy
#include "ipc_common.h"

static volatile uint64_t final_checksum;

void pin_thread_to_core(int core_id) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core_id, &cpuset);
    pthread_t current_thread = pthread_self(); 
    if (pthread_setaffinity_np(current_thread, sizeof(cpu_set_t), &cpuset) != 0) {
        perror("pthread_setaffinity_np failed");
    } else {
        LOG("Consumer pinned to Core %d\n", core_id);
    }
}

// ---------------------------------------------------------
// [FlameGraph 重構] 獨立的業務邏輯與關鍵區函式
// ---------------------------------------------------------

/**
 * @brief 純粹的 CPU 計算負載 (Checksum)
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
 * @brief Consumer 的關鍵區操作 (IPC Read/Copy)
 * @note 將 Shared Memory 的資料複製到 Local Buffer
 */
__attribute__((noinline))
void task_consume_safe(shared_data *data_ptr, char *local_buffer) {
    // 1. Lock
    if(pthread_mutex_lock(&data_ptr->mutex) != 0){
        perror("consumer mutex_lock failed.");
        return;
    }

    // 2. Wait
    while (data_ptr->message_ready < 1) {
        if (pthread_cond_wait(&data_ptr->product_cond, &data_ptr->mutex) != 0) {
            perror("consumer pthread_cond_wait(product_cond) failed.");
        }
    }

    // 3. Read Data (Copy to local)
    // 這裡我們將資料複製出來，這樣就可以盡快釋放鎖，並在外面做耗時的 Checksum
    memcpy(local_buffer, data_ptr->message[data_ptr->curr_consumer], MAX_MESSAGE_LEN);
    LOG("Consume:%s\n", local_buffer); 

    data_ptr->curr_consumer = (data_ptr->curr_consumer + 1) % BUFFER_SIZE;
    data_ptr->message_ready -= 1;

    // 4. Signal
    if(pthread_cond_signal(&data_ptr->space_cond) != 0){
        perror("consumer cond_signal failed.");
    }
    
    // 5. Unlock
    if(pthread_mutex_unlock(&data_ptr->mutex) != 0){
        perror("consumer mutex_unlock failed.");
    }
}

// ---------------------------------------------------------

void consumer(shared_data *data_ptr){
    // 使用 malloc 分配 Local Buffer 以支援大封包 (避免 Stack Overflow)
    char *local_buffer = (char*)malloc(MAX_MESSAGE_LEN);
    if(!local_buffer) {
        perror("malloc failed");
        return;
    }

    for(int i = 0; i < NUM_PRODUCTS; i++){
        // 1. [IO/Sync] 取得資料
        task_consume_safe(data_ptr, local_buffer);

        // 2. [Compute] 計算 Checksum
        // 這會是 Flame Graph 中的瓶頸柱子，優化時只需移除這行即可
        long long cs = task_compute_checksum(local_buffer, MAX_MESSAGE_LEN);
        final_checksum = cs;
    }    
    
    free(local_buffer);
    sem_post(&data_ptr->complete);
}


int main()
{   
    #ifdef CONSUMER_CORE_ID
        pin_thread_to_core(CONSUMER_CORE_ID);
    #endif

    sem_t * ready;
    for(;;) {
        ready = sem_open(READY_SEMAPHORE, 0);
        if(ready != SEM_FAILED) break;
        LOG("waiting for producer.\n");
        if(errno == ENOENT) continue;
        perror("sem_open(ready) failed");
        break;
    }
    sem_wait(ready);
    sem_close(ready);

    int file_descriptor = shm_open(SHARE_MEMORY_NAME, O_RDWR, 0600);
    if(file_descriptor == -1) { perror("shm_open failed."); return EXIT_FAILURE; }

    void *buffer =  mmap(NULL, SHM_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, file_descriptor, 0);
    if(buffer == MAP_FAILED){ perror("mmap() failed."); return EXIT_FAILURE; }
    close(file_descriptor);

    shared_data *data_ptr = (shared_data*)buffer;

    sem_post(&data_ptr->consumer_ready);
    sem_wait(&data_ptr->start_gun_sem);

    consumer(data_ptr);

    if(munmap(buffer, SHM_SIZE) == -1){ perror("munmap() failed."); return EXIT_FAILURE; }
    return EXIT_SUCCESS;
}