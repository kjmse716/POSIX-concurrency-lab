#define _GNU_SOURCE             // [新增] 為了 CPU affinity
#define _POSIX_C_SOURCE 200809L // CLOCK_MONOTONIC 
#include <sys/mman.h>
#include <fcntl.h>     // O_* constants
#include <sys/stat.h>  // mode_t and permission constants
#include <stdio.h>     // printf
#include <stdlib.h>    // macros
#include <unistd.h>    // close
#include <pthread.h>
#include <sched.h>     // [新增] 為了 cpu_set_t
#include <semaphore.h>
#include "ipc_common.h"
#include <time.h> // Measure time
#include <string.h> // for memcpy

static char template_message[MAX_MESSAGE_LEN];

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
        LOG("Producer pinned to Core %d\n", core_id);
    }
}

void producer(shared_data *data_ptr){

    for(int i = 0;i<NUM_PRODUCTS;i++){
        // protect read/write critical region
        if(pthread_mutex_lock(&data_ptr->mutex) != 0){
            perror("producer mutex_lock failed.");
            break;
        }

        // wait for a space.
        while (data_ptr->message_ready >= BUFFER_SIZE) {
            if (pthread_cond_wait(&data_ptr->space_cond, &data_ptr->mutex) != 0) {
                perror("producer cond_wait space fail.");
            }
        }
        
        // write data into shared memory
        #ifdef DEBUG
            snprintf(data_ptr->message[data_ptr->curr_producer], sizeof(data_ptr->message[data_ptr->curr_producer]), "Product:%d", i);
        #else
            memcpy(data_ptr->message[data_ptr->curr_producer], template_message, MAX_MESSAGE_LEN);
        #endif

        data_ptr->curr_producer = (data_ptr->curr_producer + 1) % BUFFER_SIZE;
        data_ptr->message_ready += 1;

        if(pthread_cond_signal(&data_ptr->product_cond) != 0){
            perror("producer cond signal failed.");
            break;
        }
        
        if(pthread_mutex_unlock(&data_ptr->mutex) != 0){
            perror("producer mutex_unlock failed.");
            break;
        }
    }    
}


double get_elapsed_seconds(struct timespec start, struct timespec end) {
    return (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
}


int main()
{
    // [新增] CPU Affinity Binding
    #ifdef PRODUCER_CORE_ID
        pin_thread_to_core(PRODUCER_CORE_ID);
    #endif

    // create the template message for each product_cond
    memset(template_message, 'A', MAX_MESSAGE_LEN);
    template_message[MAX_MESSAGE_LEN - 1] = '\0';

    // named mutex for initialization check.
    sem_t* ready = sem_open(READY_SEMAPHORE, O_CREAT, 0600, 0);
    if(ready == SEM_FAILED){
        perror("sem_open() failed.");
        return EXIT_FAILURE;
    }

    struct timespec start_time, communication_start_time, communication_end_time;

    // startup time measurement start.
    clock_gettime(CLOCK_MONOTONIC, &start_time);


    // --- Init share memory ---
    int file_descriptor = shm_open(SHARE_MEMORY_NAME, O_RDWR|O_CREAT, 0600);

    if(file_descriptor == -1)
    {
        perror("shm_open failed.");
        return EXIT_FAILURE;
    }
    LOG("shm_open() success.\n");


    // Set the size of shared memory object.
    if(ftruncate(file_descriptor, SHM_SIZE) < 0){
        perror("ftruncate() failed.");
        return EXIT_FAILURE;
    }
    LOG("ftruncate() success.\n");

    // map shared memory object to virtual memory.
    void *buffer =  mmap(NULL, SHM_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, file_descriptor, 0);
    if(buffer == MAP_FAILED){
        perror("mmap() failed.");
        return EXIT_FAILURE;
    }
    LOG("mmap() success.\n");
    close(file_descriptor);

    shared_data *data_ptr = (shared_data*)buffer;

    // --- Initialize circular buffer index ---
    data_ptr->curr_producer = 0;
    data_ptr->curr_consumer = 0;

    data_ptr->message_ready = 0;  // no product at start.

    // --- Init semaphores for time measurement ---
    if( sem_init(&data_ptr->consumer_ready, 1, 0)== -1||
        sem_init(&data_ptr->start_gun_sem, 1, 0)== -1||
        sem_init(&data_ptr->complete, 1, 0)== -1){
        perror("sem_init failed.");
        return EXIT_FAILURE;
    }

    
    // --- Initialize mutex ---
    pthread_mutexattr_t mattr;
    pthread_condattr_t cattr;

    pthread_mutexattr_init(&mattr);
    pthread_mutexattr_setpshared(&mattr, PTHREAD_PROCESS_SHARED);

    pthread_condattr_init(&cattr);
    pthread_condattr_setpshared(&cattr, PTHREAD_PROCESS_SHARED);

    if (pthread_mutex_init(&data_ptr->mutex, &mattr)!= 0 ||
        pthread_cond_init(&data_ptr->product_cond, &cattr)!= 0 ||
        pthread_cond_init(&data_ptr->space_cond, &cattr)!= 0) {
        perror("init failed!!");
        return EXIT_FAILURE;
    }
    pthread_mutexattr_destroy(&mattr);
    pthread_condattr_destroy(&cattr);


    LOG("mutex, cond init success.\n");
    
    // 通知 Consumer 初始化完成
    sem_post(ready);
    sem_close(ready);
    
    // Wait for consumer (包含等待 Consumer 的綁核完成)
    sem_wait(&data_ptr->consumer_ready);

    // start communication time measurement.
    clock_gettime(CLOCK_MONOTONIC, &communication_start_time);
    sem_post(&data_ptr->start_gun_sem);

    // --- Read from/write to the shared memory buffer ---
    producer(data_ptr);

    if(sem_wait(&data_ptr->complete) == -1){
        perror("sem_wait(complete) fail.");
        return EXIT_FAILURE;
    }
    // end conmunication time measurement.
    clock_gettime(CLOCK_MONOTONIC, &communication_end_time);


    sem_unlink(READY_SEMAPHORE);

    // --- Destroy mutex and condition variables ---
    if( pthread_mutex_destroy(&data_ptr->mutex) != 0||
        pthread_cond_destroy(&data_ptr->space_cond) != 0 ||
        pthread_cond_destroy(&data_ptr->product_cond) != 0){
        perror("mutex, cond destroy failed.");
        return EXIT_FAILURE;
    }
    
    // --- Destroy sem use for time measurement ---
    sem_destroy(&data_ptr->consumer_ready); 
    sem_destroy(&data_ptr->start_gun_sem);
    sem_destroy(&data_ptr->complete); 


    // unmap shared memory object from virtual memory.
    if(munmap(buffer, SHM_SIZE) == -1){
        perror("munmap() failed.");
        return EXIT_FAILURE;
    }
    LOG("munmap() success.\n");
    
    int r = shm_unlink(SHARE_MEMORY_NAME);

    if(r == -1)
    {
        perror("shm_unlink failed.");
        return EXIT_FAILURE;
    } 
    LOG("shm_unlink() success.\n");

    // --- Show measurement result ---
    double initialize_time = get_elapsed_seconds(start_time, communication_start_time);
    double communication_time = get_elapsed_seconds(communication_start_time, communication_end_time);
    LOG("Total run time: %.9f seconds\n", initialize_time);
    LOG("Total communication time: %.9f seconds\n", communication_time);
    printf("%.9f,%.9f\n",initialize_time,communication_time);

    return EXIT_SUCCESS;
}