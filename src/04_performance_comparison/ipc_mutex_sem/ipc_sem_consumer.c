#define _GNU_SOURCE  // [新增] 為了 CPU affinity
#include <sys/mman.h>
#include <fcntl.h>     // O_* constants
#include <sys/stat.h>  // mode_t and permission constants
#include <stdio.h>     // printf
#include <stdlib.h>    // macros
#include <unistd.h>    // close
#include <pthread.h>
#include <sched.h>     // [新增] 為了 cpu_set_t
#include <semaphore.h>
#include <errno.h>
#include "ipc_sem_common.h"

static volatile uint64_t final_checksum;

/**
 * @brief [新增] 將當前 process/thread 綁定到指定的 CPU 核心
 */
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

void consumer(shared_data *data_ptr){

    for(int i = 0;i<NUM_PRODUCTS;i++){
        // look for a product.
        if(sem_wait(&data_ptr->product) == -1){
            perror("sem_wait(&data_ptr->product).");
            break;
        }
        // protect read/write critical region
        if(sem_wait(&data_ptr->semaphore) == -1){
            perror("sem_wait(&data_ptr->semaphore).");
            break;
        }

        // Read and print data from shared memory
        LOG("Consume:%s\n", data_ptr->message[data_ptr->curr_consumer]); 

        uint64_t total_checksum = 0;
        for (int j = 0; j < MAX_MESSAGE_LEN; j++) {
            total_checksum += data_ptr->message[data_ptr->curr_consumer][j];
        }
        final_checksum = total_checksum;


        data_ptr->curr_consumer = (data_ptr->curr_consumer + 1) % BUFFER_SIZE;


        if(sem_post(&data_ptr->semaphore) == -1){
            perror("em_post(&data_ptr->semaphore)");
            break;
        }

        if(sem_post(&data_ptr->space) == -1){
            perror("sem_post(&data_ptr->space)");
            break;
        }
    
    }    
    sem_post(&data_ptr->complete);
}


int main()
{   
    // [新增] CPU Affinity Binding (儘早設定)
    #ifdef CONSUMER_CORE_ID
        pin_thread_to_core(CONSUMER_CORE_ID);
    #endif

    sem_t * ready;
    for(;;)
    {
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

    if(file_descriptor == -1)
    {
        perror("shm_open failed.");
        return EXIT_FAILURE;
    }
    LOG("shm_open() success.\n");
    

    // map shared memory object to virtual memory.
    void *buffer =  mmap(NULL, SHM_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, file_descriptor, 0);
    if(buffer == MAP_FAILED){
        perror("mmap() failed.");
        return EXIT_FAILURE;
    }
    LOG("mmap() success.\n");
    close(file_descriptor);


    // --- Initialize semaphore ---
    shared_data *data_ptr = (shared_data*)buffer;

    // --- For time Measurement ---
    // [關鍵] 在發送 consumer_ready 信號前，必須確保已經完成 Pinning
    // 這樣 Producer 在收到信號後開始計時，才不會包含到 Pinning 的時間
    sem_post(&data_ptr->consumer_ready);
    
    // 等待 Producer 鳴槍開始
    sem_wait(&data_ptr->start_gun_sem);

    // --- Read from/write to the shared memory buffer ---
    consumer(data_ptr);

    
    // unmap shared memory object from virtual memory.
    if(munmap(buffer, SHM_SIZE) == -1){
        perror("munmap() failed.");
        return EXIT_FAILURE;
    }
    LOG("munmap() success.\n");


    return EXIT_SUCCESS;
}