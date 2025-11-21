#include <semaphore.h>
#include <stdint.h>
#include <stdalign.h>

#ifdef DEBUG
    #define LOG(msg, ...) printf(msg, ##__VA_ARGS__);
#else
    #define LOG(msg, ...)
#endif

#define READY_SEMAPHORE "/ready_semaphore"
#define SHARE_MEMORY_NAME "/my_share_memory"

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


typedef struct{
    pthread_mutex_t mutex;
    pthread_cond_t product_cond;
    pthread_cond_t space_cond;
    

    // --- Circular buffer ---
    int message_ready;
    int curr_producer, curr_consumer;
    alignas(64) char message[BUFFER_SIZE][MAX_MESSAGE_LEN];


    /* --- For time measurement --- */
    sem_t consumer_ready;
    sem_t start_gun_sem; 
    sem_t complete;

}shared_data;

// get the size of shared_data struct.
#define SHM_SIZE sizeof(shared_data)
