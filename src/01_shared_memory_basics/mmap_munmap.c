#include <sys/mman.h>
#include <fcntl.h>     // O_* constants
#include <sys/stat.h>  // mode_t and permission constants
#include <stdio.h>     // printf
#include <stdlib.h>    // macros
#include <unistd.h>    // close


#define SHARE_MEMORY_NAME "/my_share_memory"
#define SHM_SIZE 1024

int main()
{
    int file_descriptor = shm_open(SHARE_MEMORY_NAME, O_RDWR|O_CREAT, 0777);

    if(file_descriptor == -1)
    {
        perror("shm_open failed\n");
        return EXIT_FAILURE;
    }
    printf("shm_open() success.\n");

    // Set the size of shared memory object.
    if(ftruncate(file_descriptor, SHM_SIZE) < 0){
        perror("ftruncate() failed.\n");
        return EXIT_FAILURE;
    }
    printf("ftruncate() success.\n");

    // map shared memory object to virtual memory.
    void *buffer =  mmap(NULL, SHM_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, file_descriptor, 0);
    if(buffer == MAP_FAILED){
        perror("mmap() failed.\n");
        return EXIT_FAILURE;
    }
    printf("mmap() success.\n");
    
    close(file_descriptor);


    // --- Read from/write to the shared memory buffer ---

    
    // unmap shared memory object from virtual memory.
    if(munmap(buffer, SHM_SIZE) == -1){
        perror("munmap() failed.\n");
        return EXIT_FAILURE;
    }
    printf("munmap() success.\n");


    
    int r = shm_unlink(SHARE_MEMORY_NAME);

    if(r == -1)
    {
        perror("shm_unlink failed\n");
        return EXIT_FAILURE;
    } 
    printf("shm_unlink() success.\n");
    return EXIT_SUCCESS;
}