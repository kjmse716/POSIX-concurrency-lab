#include <sys/mman.h>
#include <fcntl.h>     // O_* constants
#include <sys/stat.h>  // mode_t and permission constants
#include <stdio.h>     // printf
#include <stdlib.h>    // macros
#include <unistd.h>    // close
#include <pthread.h>
#include <semaphore.h>
#include <errno.h>
#include "common.h"


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
    sem_post(&data_ptr->consumer_ready);
    sem_wait(&data_ptr->start_gun_sem);

    // --- Read from/write to the shared memory buffer ---
    consumer(data_ptr);

    
    // unmap shared memory object from virtual memory.s
    if(munmap(buffer, SHM_SIZE) == -1){
        perror("munmap() failed.");
        return EXIT_FAILURE;
    }
    LOG("munmap() success.\n");


    return EXIT_SUCCESS;
}