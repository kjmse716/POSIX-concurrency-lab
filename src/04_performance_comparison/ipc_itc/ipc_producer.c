#define _POSIX_C_SOURCE 200809L // CLOCK_MONOTONIC 
#include <sys/mman.h>
#include <fcntl.h>     // O_* constants
#include <sys/stat.h>  // mode_t and permission constants
#include <stdio.h>     // printf
#include <stdlib.h>    // macros
#include <unistd.h>    // close
#include <pthread.h>
#include <semaphore.h>
#include "ipc_common.h"
#include <time.h> // Measure time
#include <string.h> // for memcpy

static char template_message[MAX_MESSAGE_LEN];

void producer(shared_data *data_ptr){

    for(int i = 0;i<NUM_PRODUCTS;i++){
        // look for a space.
        if(sem_wait(&data_ptr->space) == -1){
            perror("sem_wait(&data_ptr->space).");
            break;
        }
        // protect read/write critical region
        if(sem_wait(&data_ptr->semaphore) == -1){
            perror("sem_wait(&data_ptr->semaphore).");
            break;
        }
        
        // write data into shared memory
        #ifdef DEBUG
            snprintf(data_ptr->message[data_ptr->curr_producer], sizeof(data_ptr->message[data_ptr->curr_producer]), "Product:%d", i);
        #else
            memcpy(data_ptr->message[data_ptr->curr_producer], template_message, MAX_MESSAGE_LEN);
        #endif

        data_ptr->curr_producer = (data_ptr->curr_producer + 1) % BUFFER_SIZE;

        if(sem_post(&data_ptr->semaphore) == -1){
            perror("sem_post(&data_ptr->semaphore)");
            break;
        }

        if(sem_post(&data_ptr->product) == -1){
            perror("sem_post(&data_ptr->product)");
            break;
        }
    
    }    


}


double get_elapsed_seconds(struct timespec start, struct timespec end) {
    return (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
}


int main()
{
    // create the template message for each product
    memset(template_message, 'A', MAX_MESSAGE_LEN);
    template_message[MAX_MESSAGE_LEN - 1] = '\0';

    // named semaphore for initialization check.
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


    // --- Init semaphores for time measurement ---
    // pshared mode 1:shared between process, initial value 0.
    if( sem_init(&data_ptr->consumer_ready, 1, 0)== -1||
        sem_init(&data_ptr->start_gun_sem, 1, 0)== -1||
        sem_init(&data_ptr->complete, 1, 0)== -1){
        perror("sem_init failed.");
        return EXIT_FAILURE;
    }


    // --- Initialize semaphore ---
    if(sem_init(&data_ptr->semaphore, 1, 1) == -1 ||
       sem_init(&data_ptr->space, 1, BUFFER_SIZE) == -1 ||
       sem_init(&data_ptr->product, 1, 0) == -1){
        perror("sem_init failed.");
        return EXIT_FAILURE;
    }



    LOG("sem_init() success.\n");
    sem_post(ready);
    sem_close(ready);
    
    // Wait for consumer (to handle possible OS scheduling delays).
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
    
    if(sem_destroy(&data_ptr->semaphore) == -1||
    sem_destroy(&data_ptr->space) == -1 ||
    sem_destroy(&data_ptr->product) == -1 ||
    sem_destroy(&data_ptr->complete) == -1){
        perror("sem_destroy failed.");
        return EXIT_FAILURE;
    }
    
    // --- Destroy sem use for time measurement ---
    sem_destroy(&data_ptr->consumer_ready); 
    sem_destroy(&data_ptr->start_gun_sem); 


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