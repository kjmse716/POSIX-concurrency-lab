#include <semaphore.h>
#ifdef DEBUG
    #define LOG(msg, ...) printf(msg, ##__VA_ARGS__);
#else
    #define LOG(msg, ...)
#endif

#define READY_SEMAPHORE "/ready_semaphore"
#define SHARE_MEMORY_NAME "/my_share_memory"

// --- Workload setting ---
#ifndef NUM_PRODUCTS
    #define NUM_PRODUCTS 10
#endif

// --- Buffer setting --- 
#ifndef BUFFER_SIZE
    #define BUFFER_SIZE 10
#endif
#define MAX_MESSAGE_LEN 1024

// get the size of shared_data struct.
#define SHM_SIZE sizeof(shared_data)



typedef struct{
    sem_t semaphore;
    sem_t product;
    sem_t space;
    sem_t complete;

    // shared data
    char message[BUFFER_SIZE][MAX_MESSAGE_LEN];
    int curr_producer, curr_consumer;


    /* --- For time measurement --- */
    sem_t consumer_ready;
    sem_t start_gun_sem; 

}shared_data;


