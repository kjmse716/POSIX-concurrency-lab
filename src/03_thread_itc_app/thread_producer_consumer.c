#define _POSIX_C_SOURCE 200809L // CLOCK_MONOTONIC 
#include <stdio.h>
#include <string.h>
#include <stdlib.h>     // macros
#include <unistd.h>     // sleep
#include <pthread.h>
#include <semaphore.h> // for time measurement (wait until threads are ready).
#include <time.h> 
#include <stdint.h>


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
    pthread_cond_t  product_cond;
    pthread_cond_t  space_cond;
    
    // --- Circular buffer ---
    int message_ready;
    char message[BUFFER_SIZE][MAX_MESSAGE_LEN];
    int curr_producer, curr_consumer;

    /* --- For time measurement --- */
    sem_t ready_sem; 
    sem_t start_gun_sem; 

} shared_data;

double get_elapsed_seconds(struct timespec start, struct timespec end) {
    return (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
}


// Producer thread function
void* producer(void* arg) {
    shared_data *data_ptr = (shared_data*)arg;

    // --- For time measurement ---
    sem_post(&data_ptr->ready_sem);
    sem_wait(&data_ptr->start_gun_sem);


    for (int i = 0; i < NUM_PRODUCTS; i++) {
        // lock the mutex before write
        if (pthread_mutex_lock(&data_ptr->mutex) != 0) {
            perror("pthread_mutex_lock in producer");
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
            sprintf(data_ptr->message[data_ptr->curr_producer], "Product:%d", i);
        #else
            memcpy(data_ptr->message[data_ptr->curr_producer],template_message, MAX_MESSAGE_LEN);
        #endif
        LOG("Producer created: %s\n", data_ptr->message[data_ptr->curr_producer]);
        data_ptr->curr_producer = (data_ptr->curr_producer + 1) % BUFFER_SIZE;
        data_ptr->message_ready += 1;
        
        
        // signal that a product is ready
        if (pthread_cond_signal(&data_ptr->product_cond) != 0) {
            perror("pthread_cond_signal for product");
        }

        // unlock the mutex
        if (pthread_mutex_unlock(&data_ptr->mutex) != 0) {
            perror("pthread_mutex_unlock");
            break;
        }
    }
    return NULL;
}

// Consumer thread function
void* consumer(void* arg) {
    shared_data *data_ptr = (shared_data*)arg;

    // --- For time measurement ---
    sem_post(&data_ptr->ready_sem);
    sem_wait(&data_ptr->start_gun_sem);

    for (int i = 0; i < NUM_PRODUCTS; i++) {
        if (pthread_mutex_lock(&data_ptr->mutex) != 0) {
            perror("pthread_mutex_lock");
            break;
        }
        
        // wait for a product 
        while (data_ptr->message_ready < 1) {
            if (pthread_cond_wait(&data_ptr->product_cond, &data_ptr->mutex) != 0) {
                perror("pthread_cond_wait(product_cond)");
            }
        }

        // read data from shared memory
        LOG("Consumer got:   %s\n", data_ptr->message[data_ptr->curr_consumer]);
        uint64_t total_checksum = 0;
        for (int j = 0; j < MAX_MESSAGE_LEN; j++) {
            total_checksum += data_ptr->message[data_ptr->curr_consumer][j];
        }
        final_checksum = total_checksum;


        data_ptr->curr_consumer = (data_ptr->curr_consumer + 1) % BUFFER_SIZE;
        data_ptr->message_ready -= 1;

        // signal that a space is available
        if (pthread_cond_signal(&data_ptr->space_cond) != 0) {
            perror("pthread_cond_signal for spac"); 
        }

        // unlock the mutex
        if (pthread_mutex_unlock(&data_ptr->mutex) != 0) {
            perror("pthread_mutex_unlock");
            break;
        }
        
    }
    return NULL;
}


int main() {
    pthread_t producer_thread, consumer_thread;
    shared_data data;

    data.curr_producer = 0;
    data.curr_consumer = 0;

    sem_init(&data.ready_sem, 0, 0); // pshared mode 0:shared between threads, initial value 0.
    sem_init(&data.start_gun_sem, 0, 0); 

    // create the template message for each product
    memset(template_message, 'A', MAX_MESSAGE_LEN);
    template_message[MAX_MESSAGE_LEN - 1] = '\0';



    // timespec for time measurement.
    struct timespec start_time, communication_start_time, communication_end_time;

    // start run-time measurement.
    clock_gettime(CLOCK_MONOTONIC, &start_time);

    // --- Initialize mutex and condition variables ---
    if (pthread_mutex_init(&data.mutex, NULL) != 0 ||
        pthread_cond_init(&data.product_cond, NULL) != 0 ||
        pthread_cond_init(&data.space_cond, NULL) != 0) {
        perror("init failed!!");
        return EXIT_FAILURE;
    }

    // no product at start.
    data.message_ready = 0; 
    LOG("pthread mutex & condvars init OK.\n");

    // create threads
    if (pthread_create(&producer_thread, NULL, producer, &data) != 0) {
        perror("pthread_create(producer) failed.");
        return EXIT_FAILURE;
    }
    LOG("pthread_create(producer) success.\n");

    if (pthread_create(&consumer_thread, NULL, consumer, &data) != 0) {
        perror("pthread_create(consumer) failed.");
        return EXIT_FAILURE;
    }
    LOG("pthread_create(consumer) success.\n");

    // wait until threads are ready.
    sem_wait(&data.ready_sem);
    sem_wait(&data.ready_sem);

    // start communication time measurement.
    clock_gettime(CLOCK_MONOTONIC, &communication_start_time);
    sem_post(&data.start_gun_sem);
    sem_post(&data.start_gun_sem);


    // --- Wait for threads to complete ---
    if (pthread_join(producer_thread, NULL) != 0) {
        perror("pthread_join (producer) failed.");
        return EXIT_FAILURE;
    }
    LOG("producer thread joined.\n");

    if (pthread_join(consumer_thread, NULL) != 0) {
        perror("pthread_join (consumer) failed.");
        return EXIT_FAILURE;
    }

    LOG("consumer thread joined.\n");

    // communication end time measurement.
    clock_gettime(CLOCK_MONOTONIC, &communication_end_time);

    
    // --- Destroy mutex and condition variables ---
    pthread_mutex_destroy(&data.mutex);
    pthread_cond_destroy(&data.product_cond);
    pthread_cond_destroy(&data.space_cond);
    LOG("pthread mutex and cond destroyed successfully.\n");


    // --- Show measurement result --
    double initialize_time = get_elapsed_seconds(start_time, communication_start_time);
    double communication_time = get_elapsed_seconds(communication_start_time, communication_end_time);
    LOG("Total run time: %.9f seconds\n", initialize_time);
    LOG("Total communication time: %.9f seconds\n", communication_time);
    printf("%.9f,%.9f\n",initialize_time,communication_time);


    // --- Destroy sem use for time measurement ---
    sem_destroy(&data.ready_sem); 
    sem_destroy(&data.start_gun_sem); 


    return EXIT_SUCCESS;
}