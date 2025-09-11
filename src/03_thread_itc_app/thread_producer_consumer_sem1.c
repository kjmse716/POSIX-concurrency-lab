#define _POSIX_C_SOURCE 200809L // For CLOCK_MONOTONIC
#include <stdio.h>
#include <stdlib.h>     // For exit macros
#include <unistd.h>
#include <pthread.h>
#include <semaphore.h>
#include <time.h>       // For time measurement
#include <sys/mman.h>   // For mmap and munmap


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
    #define BUFFER_SIZE 10
#endif
#define MAX_MESSAGE_LEN 1024


typedef struct{
    sem_t semaphore;
    sem_t product;
    sem_t space;


    char message[BUFFER_SIZE][MAX_MESSAGE_LEN];
    int curr_producer, curr_consumer;

    /* --- For time measurement --- */
    sem_t complete;
    sem_t producer_ready;
    sem_t consumer_ready;
    sem_t start_gun_sem;
} shared_data;




double get_elapsed_seconds(struct timespec start, struct timespec end) {
    return (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
}



void* producer(void* arg){
    shared_data *data_ptr = (shared_data*)arg;

    // --- For time measurement: Signal that producer is ready ---
    sem_post(&data_ptr->producer_ready);
    sem_wait(&data_ptr->start_gun_sem);

    for(int i = 0; i < NUM_PRODUCTS; i++){
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
        snprintf(data_ptr->message[data_ptr->curr_producer], sizeof(data_ptr->message[data_ptr->curr_producer]), "Product:%d", i);
        LOG("Producer created: %s\n", data_ptr->message[data_ptr->curr_producer]);
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
    return NULL;
}



void* consumer(void* arg){
    shared_data *data_ptr = (shared_data*)arg;
    
    // --- For time measurement: Signal that consumer is ready ---
    sem_post(&data_ptr->consumer_ready);
    sem_wait(&data_ptr->start_gun_sem);

    for(int i = 0; i < NUM_PRODUCTS; i++){
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
            perror("sem_post(&data_ptr->semaphore)");
            break;
        }

        if(sem_post(&data_ptr->space) == -1){
            perror("sem_post(&data_ptr->space)");
            break;
        }
    }
    // Signal that the consumer has finished all its work
    sem_post(&data_ptr->complete);
    return NULL;
}


int main()
{
    struct timespec start_time, communication_start_time, communication_end_time;
    pthread_t producer_thread, consumer_thread;
    
    // Allocate shared_data in shared memory for pshared=1 semaphores.
    shared_data *data_ptr = mmap(NULL, sizeof(shared_data), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (data_ptr == MAP_FAILED) {
        perror("mmap failed");
        return EXIT_FAILURE;
    }
    data_ptr->curr_consumer = 0;
    data_ptr->curr_producer = 0;

    // startup time measurement start.
    clock_gettime(CLOCK_MONOTONIC, &start_time);

    // --- Initialize unnamed semaphores with pshared=1 ---
    if(sem_init(&data_ptr->semaphore, 1, 1) == -1 ||
       sem_init(&data_ptr->space, 1, BUFFER_SIZE) == -1 ||
       sem_init(&data_ptr->product, 1, 0) == -1 ||
       sem_init(&data_ptr->complete, 1, 0) == -1){
        perror("sem_init failed.");
        munmap(data_ptr, sizeof(shared_data)); // Clean up on failure
        return EXIT_FAILURE;
    }


    // --- For time measurement ---
    sem_init(&data_ptr->producer_ready, 1, 0);
    sem_init(&data_ptr->consumer_ready, 1, 0);
    sem_init(&data_ptr->start_gun_sem, 1, 0);

    LOG("sem_init() success.\n");

    // --- Create producer and consumer threads ---
    if (pthread_create(&producer_thread, NULL, producer, data_ptr) != 0) {
        perror("pthread_create(producer) failed.");
        munmap(data_ptr, sizeof(shared_data)); // Clean up on failure
        return EXIT_FAILURE;
    }
    LOG("pthread_create(producer) success.\n");

    if (pthread_create(&consumer_thread, NULL, consumer, data_ptr) != 0) {
        perror("pthread_create(consumer) failed.");
        munmap(data_ptr, sizeof(shared_data)); // Clean up on failure
        return EXIT_FAILURE;
    }
    LOG("pthread_create(consumer) success.\n");

    // Wait for both threads to be ready (to handle possible OS scheduling delays).
    sem_wait(&data_ptr->producer_ready);
    sem_wait(&data_ptr->consumer_ready);

    // start communication time measurement.
    clock_gettime(CLOCK_MONOTONIC, &communication_start_time);
    sem_post(&data_ptr->start_gun_sem);
    sem_post(&data_ptr->start_gun_sem);

    // --- Wait for threads to complete ---
    if (pthread_join(producer_thread, NULL) != 0) {
        perror("pthread_join (producer) failed.");
        // continue cleanup
    }
    LOG("producer thread joined.\n");

    if (pthread_join(consumer_thread, NULL) != 0) {
        perror("pthread_join (consumer) failed.");
        // continue cleanup
    }
    LOG("consumer thread joined.\n");


    if(sem_wait(&data_ptr->complete) == -1){
        perror("sem_wait(complete) fail.");
        // continue cleanup
    }
    
    // end communication time measurement.
    clock_gettime(CLOCK_MONOTONIC, &communication_end_time);

    // --- Destroy semaphores ---
    if(sem_destroy(&data_ptr->semaphore) == -1 ||
       sem_destroy(&data_ptr->space) == -1 ||
       sem_destroy(&data_ptr->product) == -1 ||
       sem_destroy(&data_ptr->complete) == -1){
        perror("sem_destroy failed.");
    }
    
    // --- Destroy semaphores used for time measurement ---
    sem_destroy(&data_ptr->producer_ready);
    sem_destroy(&data_ptr->consumer_ready);
    sem_destroy(&data_ptr->start_gun_sem);

    // --- Clean up shared memory ---
    if (munmap(data_ptr, sizeof(shared_data)) == -1) {
        perror("munmap failed");
    }

    // --- Show measurement result ---
    double initialize_time = get_elapsed_seconds(start_time, communication_start_time);
    double communication_time = get_elapsed_seconds(communication_start_time, communication_end_time);
    LOG("Total run time: %.9f seconds\n", initialize_time);
    LOG("Total communication time: %.9f seconds\n", communication_time);
    printf("%.9f,%.9f\n", initialize_time, communication_time);

    return EXIT_SUCCESS;
}