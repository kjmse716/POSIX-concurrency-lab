#include <sys/mman.h>
#include <fcntl.h>     // O_* 常數
#include <sys/stat.h>  // mode_t 與權限常數
#include <stdio.h>     // printf
#include <stdlib.h>    // macros
#include <unistd.h>    // close

#define SHARE_MEMORY_NAME "/my_share_memory"
int main()
{
    int file_descriptor = shm_open(SHARE_MEMORY_NAME, O_RDWR|O_CREAT, 0777);

    if(file_descriptor == -1)
    {
        perror("shm_open failed\n");
        return EXIT_FAILURE;
    }
    printf("shm_open() success.\n");
    close(file_descriptor);
    int r = shm_unlink(SHARE_MEMORY_NAME);

    if(r == -1)
    {
        perror("shm_unlink failed\n");
        return EXIT_FAILURE;
    } 
    printf("shm_unlink() success.\n");
    return EXIT_SUCCESS;
}