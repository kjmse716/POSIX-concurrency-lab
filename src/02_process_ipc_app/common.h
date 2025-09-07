#include <semaphore.h>
#ifdef DEBUG
    #define LOG(msg, ...) printf(msg, ##__VA_ARGS__);
#else
    #define LOG(msg, ...)
#endif

#define READY_SEMAPHORE "/ready_semaphore"
#define SHARE_MEMORY_NAME "/my_share_memory"
#define MAX_MESSAGE_LEN 1024
#ifndef NUM_PRODUCTS
    #define NUM_PRODUCTS 100000
#endif


// get the size of shared_data struct.
#define SHM_SIZE sizeof(shared_data)



typedef struct{
    sem_t semaphore;
    sem_t product;
    sem_t space;
    sem_t complete;

    // shared data
    char message[MAX_MESSAGE_LEN];

    /* --- For time measurement --- */
    sem_t consumer_ready;
    sem_t start_gun_sem; 

}shared_data;


