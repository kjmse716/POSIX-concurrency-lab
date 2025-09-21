POSIX-concurrency-lab  
於 Hackmd 上閱讀 https://hackmd.io/@kjmse716/SJGGZvNqge

# 專案介紹
## 專案目標：
* 透過 POSIX 實作：
    *  Inter-process 的記憶體共享`shm` + `mmap` + `sem` (Semaphore)
    *  Inter-thread 資料交換，並使用`pthread_mutex`, `pthread_cond`來進行同步

* 比較兩種方式的資料交換時間(同步原語開銷 + context switch 成本)

## 專案架構：

```
.
├── 📊 results/               # 實驗數據
│   └── results_ipcSemaphore_itcMutex.csv
├── 📜 scripts/               # 效能測試自動化腳本
│   └── performance_test.sh
├── 💻 src/                   
│   ├── 📁 01_shared_memory_basics/ # POSIX 共享記憶體基礎
│   │   ├── mmap_munmap         # (執行檔)
│   │   ├── mmap_munmap.c
│   │   ├── shm_open_unlink     # (執行檔)
│   │   └── shm_open_unlink.c
│   ├── 📁 02_process_ipc_app/  # 基於行程 (Process) 的 IPC 實作
│   │   ├── common.h
│   │   ├── consumer.c
│   │   ├── producer.c
│   │   └── Makefile
│   └── 📁 03_thread_itc_app/   # 基於執行緒 (Thread) 的 ITC 實作
│       ├── thread_producer_consumer.c
│       ├── thread_producer_consumer_sem.c
│       └── Makefile
├── .gitignore             
├── 📄 LICENSE                
├── 📖 README.md              
└── 📈 results_avg.csv        
```





# 共享記憶體（Process-Shared Memory）
reference :Shared memory 部分介紹參考:https://www.bigcatblog.com/shared_memory/
## shm_open()、shm_unlink()建立一個共用記憶體物件(由tmpfs管理的檔案)

Shared memory by (POSIX API):

```c
#include <sys/mman.h>
int shm_open(const char *name, int oflag, mode_t mode);
int shm_unlink(const char *name);
```
* shm_open: 新增一個共用記憶體object
用於創建或打開一個 POSIX 共享記憶體物件(類似於一個虛擬的檔案)。這個物件在核心中表現得像一個檔案，但實際內容存放在記憶體中，允許多個行程透過 mmap 將其映射到自己的位址空間。
    * name: 參數設定這個共用記憶體object的名稱(POSIX 標準建議以單一 `/` 開頭)
    * oflag: 這個參數透過位元旗標的方式來設定這個共享記憶體物件的存取全縣，可以透過
    包含: `O_RDONLY`、`O_RDWR`、`O_CREAT:若不存在則新建`、`O_EXCL:若存在則回傳錯誤`、`O_TRUNC:若存在則清除元內容`
    位元旗標的使用ex:`|` - 用於組合或設定旗標、`&` - 用於檢查或測試旗標
    * mode: 若需要新建一個新的共享記憶體物件時，要為這個物件的設定的Linux檔案權限等級
    定義在 `<sys/stat.h>`中
* shm_unlink: 刪除一個共用記憶體object

:::success
**使用shm_open()創建的共享記憶體物件(虛擬檔案)會交由`tmpfs` (Temporary File System)這個特殊的File system處理，這個file system的特色是他所管理的檔案內容完全存放於記憶體中**。
:::

```c=
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
```
:::info
補充
* 有關file_descripter:
分配檔案描述符 (File Descriptor Allocation) → 在當前行程的「檔案描述符表（File Descriptor Table）」新增一個File Descriptor(指向系統Open file table(整個系統唯一)中的一個entry)，一個entry對應一個被開啟的file。
* shm_open() 只是建立或打開這個共享記憶體物件，並不會馬上分配實際的資料空間。
在使用前必須先進行以下操作:
用 ftruncate(fd, size) 設定它的大小
用 mmap() 把它映射到行程的位址空間
之後才可對映射後的記憶體做讀寫

:::

## ftruncate 設定共用記憶體物件的大小
由shm_open()建立的共享記憶體檔案的大小會是0，在進行下一步操作前需要過`fturncate`來設置其大小
```c
#include <unistd.h>
int truncate(const char *path, off_t length);
int ftruncate(int fildes, off_t length);
```
>fildes: 傳入file_descriptor
>return value: 執行正確會回傳`0`若執行錯誤會回傳`-1`


## 使用mmap()將這個共享記憶體物件實際映射到此process的虛擬記憶體空間
雖然透過'shm_open'建立，由`tmpfs`管理的虛擬檔案內容預設就會存在記憶體中，但是我們的process仍還無法直接去存取到該記憶體區塊。
這時我們就要透過`mmap()`:將檔案的內容映射到此process的virtual memory中


:::success
透過`mmap()`指令，作業系統會透過Paging機制，將存放該共用記憶體物件的page frame透過page table也映射到此process的virtual memory中。
* 利用了paging機制中，一個實體記憶體中的page frame可以由多個不同process的page table來索引到的機制，實現了記憶體的共享。

:::
mmap() 成功後會回傳一個 void * 指標，這個指標就是共享記憶體區段在此 process 虛擬位址空間中的起始位址，後續所有讀寫操作都將透過這個指標進行。


```
+-------------------+      +--------------------+
| Process A         |      | Physical Memory    |
| [ Page Table ] ---|----->| [ Page Frame X ]   |
|                   |      | (Shared Data)      |
|-------------------|      |                    |
| Process B         |      |                    |
| [ Page Table ] ---|----->|                    |
+-------------------+      +--------------------+
```


```c
#include <sys/mman.h>
void* mmap(void* addr, size_t length, int prot, int flags, int fd, off_t offset);
int munmap(void* addr, size_t length);
```
* `addr` : 設定映射到此process virtual address space的記憶體位置，傳入`NULL`為自動分配
* `length` : mapping 大小(byte)
* `prot` : (memory protection flags)的位元旗標。
`PROT_EXEC`(可以執行), `PROT_READ`, `PROT_WRITE`, `PROT_NONE`(不可存取)
* `flags` : 設定當對這塊記憶體進行寫入時，這個變動是否會影響到磁碟上的原始檔案以及其他也對映了此檔案的process。
    * `MAP_SHARED` : 修改這塊記憶體中的內容時，這個修改會被「寫回」(write back) 到磁碟上被對映的那個檔案(在此是共享記憶體物件中的資料)。同時，其他也使用 MAP_SHARED 對映了同一個檔案的行程可以看到修改。
    * `MAP_PRIVATE` : 使用**「寫入時複製」(Copy-on-Write, COW)** 技術。一開始，所有行程都共享同一個實體記憶體分頁。但當某個行程第一次嘗試寫入某個分頁時，核心會先攔截這個操作，為該行程複製一份該分頁的「私有副本」，然後讓該行程對這個副本進行寫入。之後的讀寫都發生在這個私有副本上，不會寫回原檔。

* `fd` : File descriptor
* `offset` : 映射起點的位移量（以byte為單位）

若`mmap()`發生錯誤時回傳的是一個特殊的pointer，其值剛好等於`-1`:
`<mman.h>`中的MAP_FAILED macro :
```c=43
/* Return value of `mmap' in case of an error.  */
#define MAP_FAILED	((void *) -1)
```

## 記憶體共享實作:

流程:`shm_open() → ftruncate() → mmap() → [read/write] → munmap() → shm_unlink()`

```c=1
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

    // --- Read from/write to the shared memory buffer ---

    
    // unmap shared memory object from virtual memory.
    if(munmap(buffer, SHM_SIZE) == -1){
        perror("munmap() failed.\n");
        return EXIT_FAILURE;
    }
    printf("munmap() success.\n");


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
```
使用共享記憶體buffer的方法通常是透過宣告出包含鎖的struct來進行資料與同步狀態的管理。


# POSIX 同步機制
## POSIX Semaphore

reference: https://man7.org/linux/man-pages/man7/sem_overview.7.html
透過POSIX API來使用Semaphore的主要流程如下:
1. 建立Semaphore: 
具名Semaphore : `sem_open()`
匿名Semaphore : `sem_init()`
3. 透過`sem_post()` 、 `sem_wait()` 進行鎖的操作
4. 解構semaphore:
具名Semaphore : `sem_close()+sem_unlink()`
匿名Semaphore : `sem_destroy()`

而透過`sem_getvalue(sem_t *sem, int *sval)`則可以取得當前Semaphore的計量，常用於debug.

:::info
具名Semaphore的創建`sem_open()`會額外建立一個由tmpfs管理的共享鎖檔案(與我們先前建立的shm_open()共享記憶體物件的原理相同)，並藉此來實現讓不同process可以共享這個鎖，而在我們的producer and consumer案例中由於已經有宣告共享記憶體區段了，就不需要使用有具名的Semaphore。
:::


```c
#include <semaphore.h>
#include <fcntl.h>           /* For O_* constants */
#include <sys/stat.h>        /* For mode constants */

// --- create semaphore ---
int sem_init(sem_t *sem, int pshared, unsigned int value);
sem_t *sem_open(const char *name, int oflag, ...
                       /* mode_t mode, unsigned int value */ );

// --- semaphore oprations ---
int sem_post(sem_t *sem);
int sem_wait(sem_t *sem);

// --- destroy semaphore ---
// for named semaphore
int sem_close(sem_t *sem);
int sem_unlink(const char *name);
// for unnamed semaphore
int sem_destroy(sem_t *sem);
```

## POSIX Mutex, Condition Variable
pthread_mutex_t: Pthreads 提供的互斥鎖。
* `pthread_mutex_t mutex`
    * `pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr)`
    初始化一個 mutex。
    * `pthread_mutex_lock(pthread_mutex_t *mutex)`: 
    獲取鎖，如果鎖已被其他執行緒持有，則當前執行緒阻塞。
    * `pthread_mutex_unlock(pthread_mutex_t *mutex)`: 
    釋放鎖。
    * `pthread_mutex_destroy(pthread_mutex_t *mutex)`: 
    銷毀一個 mutex。
* `pthread_cond_t`
    * `pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr)`: 
    初始化一個條件變數。
    * `pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex)`: 
    以 Atomic 操作解鎖 mutex 並等待條件變數被觸發；當被喚醒時會重新鎖定 mutex。
    * `pthread_cond_signal(pthread_cond_t *cond)`: 
    喚醒至少一個正在此條件變數的執行緒。
    * `pthread_cond_destroy(pthread_cond_t *cond)`
    銷毀一個條件變數。
* `pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start_routine) (void *), void *arg)`: 
建立一個新的執行緒。
* `pthread_join(pthread_t thread, void **retval)`: 
等待一個執行緒執行結束。

簡單的 IPC + Mutex + Cond 實例:
```c=
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h> // For sleep()
#include <pthread.h>


typedef struct {
    pthread_mutex_t mutex; 
    pthread_cond_t  cond;
    int             is_ready;
} shared_data;


void* assistant_routine(void* arg) {
    shared_data* data = (shared_data*)arg;

    printf("assistant_routine ready\n");

    // Lock mutex before checking condition variable
    pthread_mutex_lock(&data->mutex);

    // if is_ready == 0:
    // 1. unlock mutex
    // 2. go to wait queue, sleep until receive signal
    // 3. once awakened, lock the mutex again and continue
    while (data->is_ready == 0) {
        pthread_cond_wait(&data->cond, &data->mutex);
    }

    printf("Data received ！\n");

    // Critical region end
    pthread_mutex_unlock(&data->mutex);

    return NULL;
}


int main() {
    pthread_t assistant_thread; 
    shared_data data;           

    // --- Initialization ---
    pthread_mutex_init(&data.mutex, NULL);
    pthread_cond_init(&data.cond, NULL);
    data.is_ready = 0;


    // Start `assistant_routine` thread
    if (pthread_create(&assistant_thread, NULL, assistant_routine, &data) != 0) {
        perror("pthread_create()");
        return 1;
    }

    // --- Data Preparation ---
    sleep(2); // simulate

    // --- Lock critical region before updating shared data ---
    pthread_mutex_lock(&data.mutex);
    /* Critical region start */
    
    printf("Updating data！\n");
    
    data.is_ready = 1;
    pthread_cond_signal(&data.cond);
    /* Critical region end */
    pthread_mutex_unlock(&data.mutex);


    // --- Wait for sub-thread to complete. ---
    if (pthread_join(assistant_thread, NULL) != 0) {
        perror("pthread_join(assistant_thread, NULL)");
        return 1;
    }

    printf("Complete！\n");

    // --- Destroy mutex, cond ---
    pthread_mutex_destroy(&data.mutex);
    pthread_cond_destroy(&data.cond);

    return 0;
}
```
:::danger
注意：
---
`pthread_cond_wait()` 在被叫醒後，不會再次檢查其等待之 conditional variable 條件是否成立，故安全地使用方法通常是用 `while( !condition_variable ){pthread_cond_wait()}` 而不是`if( !condition_variable ){pthread_cond_wait()}`，為了預防以下兩種情況：

* 虛假喚醒 (Spurious Wakeup)：
在極少數情況下，執行緒可能在沒有任何 `pthread_cond_signal()` 被呼叫的情況下被意外喚醒。如果使用 `if`，執行緒將會錯誤地繼續執行。而 `while` 迴圈能確保執行緒在被喚醒後重新檢查條件，若條件不滿足，則會安全地繼續回去等待。

* 多等待者下的 Race Condition：
當多個執行緒在等待同一個條件時，即使有 signal 發生，也不能保證輪到自己時條件依然為真。例如，執行緒 A 被喚醒並消耗了資源（使條件變回 false），此時若執行緒 B 也被喚醒，使用 `if`的 B 將不會重新檢查，並在錯誤的條件下繼續執行。`while` 迴圈則能完美處理這種「條件被搶先」的情況。。
:::

## Semaphore vs Mutex

:::info
一個計數為 1 的 Semaphore，是否等同於一個 Mutex?
---
答案：否
1. 所有權 (Ownership) 的概念：
    * Mutex： 具有明確的「所有權」概念。誰鎖定 (lock)，就必須由誰解鎖 (unlock)。這個設計是為了保護臨界區，確保資源狀態的改變由同一個執行緒完整負責。
    * Semaphore： 沒有所有權概念。任何執行緒都可以對一個 Semaphore 執行 sem_wait()和 sem_post()。一個執行緒可以等待 (wait)，而由另一個執行緒來發信號 (post) 喚醒它。

2. 核心用途的差異：
    * Mutex (Mutual Exclusion)： 其核心目的是「互斥」，保護一段程式碼（臨界區）在同一時間只能被一個執行緒執行，防止 race condition。
    * Semaphore： 其核心目的是「同步 (Synchronization)」，用於協調多個執行緒/行程的執行順序。例如，一個執行緒完成某項任務後，透過 sem_post() 通知另一個正在 sem_wait() 等待的執行緒可以開始工作了。

:::


優先權反轉 (Priority Inversion)
---
這是一個在即時系統 (Real-time Systems) 中致命，在普通系統中也可能導致嚴重效能問題的。

* 一個高優先權的執行緒 (H) 正在等待一個被低優先權執行緒 (L) 持有的 Mutex。此時，如果一個中優先權的執行緒 (M) 就緒了，它會搶佔 (preempt) 低優先權執行緒 (L) 的 CPU 時間，導致 L 無法執行也就無法釋放 Mutex。結果就是，高優先權的 H 反而被無關緊要的 M 給間接阻塞了。

與 Mutex/Semaphore 的關聯：

* Mutex： 由於 Mutex 有「所有權」概念，作業系統可以辨識出是「誰」持有了鎖，「誰」在等待鎖。因此，許多 Mutex 的實作提供了優先權繼承 (Priority Inheritance) 機制來解決此問題。當 H 等待 L 持有的鎖時，系統會暫時將 L 的優先權提升到和 H 一樣高，確保 L 能盡快執行並釋放鎖，防止被 M 插隊。
* Semaphore： 因為沒有所有權概念，系統很難知道是哪個執行緒「應該」被提升優先權來解決等待問題。因此，標準的 Semaphore 通常不提供優先權繼承的解決方案。

:::info
1997 年火星探路者號 (Mars Pathfinder) 的著名案例。當時探測器就因為優先權反轉導致了週期性的系統重置，工程師們最後透過遠端上傳補丁，開啟了 VxWorks 作業系統中 Mutex 的優先權繼承選項才解決了問題。
:::

遞迴鎖定 (Recursive Locking) 與可重入性 (Re-entrancy)
---
一個已經持有某個 Mutex 的執行緒，能否再次對同一個 Mutex 進行鎖定操作？

* Mutex：
    * 標準 Mutex： 不允許。如果嘗試這樣做，會立即導致死鎖 (Deadlock)，因為執行緒會永遠等待自己釋放鎖。
    * 遞迴 Mutex (Recursive Mutex)： 允許。它會維護一個計數器，記錄同一個執行緒鎖定了多少次，需要解鎖同樣次數後，鎖才會被真正釋放給其他執行緒。這在某些遞迴函式或複雜的呼叫鏈中很有用。
    * Semaphore： 如果一個計數為 1 的 Semaphore 被同一個執行緒 wait 兩次，結果和標準 Mutex 一樣，會直接死鎖。它沒有遞迴的概念。

穩健性 (Robustness) 與行程/執行緒崩潰
---
如果一個持有鎖的執行緒/行程 crash 了，會發生什麼？

* Mutex： 因為有「所有權」，這個問題非常明確。如果持有鎖的執行緒崩潰了，這個鎖將永遠不會被釋放，所有等待這個鎖的執行緒都會被永久阻塞。為了解決這個問題，POSIX 提供了一種特殊的「穩健 Mutex」(Robust Mutexes)，它能在下一個嘗試獲取鎖的執行緒中返回一個特殊的錯誤碼 (EOWNERDEAD)，告知它前一個擁有者已經死亡，讓應用程式有機會去清理資源狀態。

* Semaphore： 問題同樣存在，但表現形式不同。如果一個預期要執行 sem_post 的執行緒崩潰了，那麼 Semaphore 的計數將永遠無法增加，同樣會導致其他等待的執行緒被永久阻塞。但因為沒有所有權，系統層面無法提供像穩健 Mutex 那樣的自動化解決方案。




# Inter-Process Producer Consumer
為了確保生產者 (Producer) 與消費者 (Consumer) 之間資料讀寫的正確性，必須引入一個同步機制。
## 鎖的選擇 Semaphore
`int sem_init(sem_t *sem, int pshared, unsigned int value);`

為什麼這裡選擇 Semaphore：
* 擴充性：使用 Semaphore 更符合 product 與 space 的概念，可以更好的應對 buffer size > 1 的情況下（例如環形 buffer）。
* POSIX 的 sem_init() 函式設計時就考量到 process 間共享的需求，透過 pshared 參數即可指定同步範圍，比起 `pthread_mutex` 的 attr 設定流程方便：
    * `pshared== 0`：告訴系統，這個信號量只在目前行程的執行緒之間共享。
    * `pshared!= 0`：告訴系統，這個信號量將被多個行程共享，請為它建立一個能跨越行程邊界的、更持久的內核物件。

## 為甚麼鎖會需要區分 thread 間共享模式與跨 process 共享模式:
同步機制不僅僅是共享一塊資料，更關鍵的是如何有效率地管理「等待」和「喚醒」。而因為執行緒和行程在這方面的管理機制和成本不同，故也有對應的實作方法。

### thread shared 與 process shared 模式最大的差別在於作用域與等待機制:
* 這個鎖是只有同個 process 底下的 threads 才看到或是多個 process 底下的 threads 都可以看到
* 等待中的 process 進入的是 process 專屬的 wait queue 還是一個多個 process 共用的 wait queue

Thread-shared (專屬佇列)：可以被高度優化。因為大家都是「自己人」（同一個行程的執行緒），很多協調工作可以在使用者空間完成，只有在真正需要「睡覺等待」時才需要呼叫核心，成本極低。

Process-shared (公共佇列)：必須由核心來扮演絕對公正的管理者。每一次鎖定和解鎖，幾乎都需要進入核心，由核心來進行控制，成本相對較高，但這是確保跨行程安全與正確性的唯一方法。




## 實作
在producer、consumer情境中，有兩個地方會需要鎖:
1. 互斥 (Mutual Exclusion) - 同一時間只允許一個執行緒/行程進入臨界區（critical region）操作共享資源。
2. 同步 (Synchronization) - 確保在 buffer 為空時 consumer 不會讀取，在 buffer 滿時 producer 不會寫入。

* 使用一個具名 semaphore (READY_SEMAPHORE)確保共享記憶體物件與三個匿名 semaphore 已由 Producer.c 初始化完成，才允許 Consumer.c 進行存取。
* 在Producer, consumer的操作部分使用3個 unnamed semephore 分別保護
    * 對 message 讀寫這個 critical region。
    * 確保 Producer 確保 producer 僅在 buffer 有空位時寫入新訊息。
    * 確保 Consumer 確保 consumer 僅在 buffer 有新訊息時讀取資料。

producer.c
```c=1
#include <sys/mman.h>
#include <fcntl.h>     // O_* constants
#include <sys/stat.h>  // mode_t and permission constants
#include <stdio.h>     // printf
#include <stdlib.h>    // macros
#include <unistd.h>    // close
#include <pthread.h>
#include <semaphore.h>
#include "common.h"



void producer(shared_data *data_ptr){

    for(int i = 0;i<10;i++){
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
        sprintf(data_ptr->message, "Product:%d", i);


        if(sem_post(&data_ptr->semaphore) == -1){
            perror("em_post(&data_ptr->semaphore)");
            break;
        }

        if(sem_post(&data_ptr->product) == -1){
            perror("sem_post(&data_ptr->product)");
            break;
        }
    }    
}


int main()
{
    sem_t* ready = sem_open(READY_SEMAPHORE, O_CREAT, 0666, 0);

    int file_descriptor = shm_open(SHARE_MEMORY_NAME, O_RDWR|O_CREAT, 0777);

    if(file_descriptor == -1)
    {
        perror("shm_open failed.");
        return EXIT_FAILURE;
    }
    printf("shm_open() success.\n");


    // Set the size of shared memory object.
    if(ftruncate(file_descriptor, SHM_SIZE) < 0){
        perror("ftruncate() failed.");
        return EXIT_FAILURE;
    }
    printf("ftruncate() success.\n");

    // map shared memory object to virtual memory.
    void *buffer =  mmap(NULL, SHM_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, file_descriptor, 0);
    if(buffer == MAP_FAILED){
        perror("mmap() failed.");
        return EXIT_FAILURE;
    }
    printf("mmap() success.\n");
    close(file_descriptor);


    // --- Initialize semaphore ---
    shared_data *data_ptr = (shared_data*)buffer;
    if(sem_init(&data_ptr->semaphore, 1, 1) == -1 ||
       sem_init(&data_ptr->space, 1, 1) == -1 ||
       sem_init(&data_ptr->product, 1, 0) == -1||
       sem_init(&data_ptr->complete, 1, 0)== -1){
        perror("sem_init failed.");
        return EXIT_FAILURE;
    }
    printf("sem_init() success.\n");
    sem_post(ready);
    sem_close(ready);
    
    

    // --- Read from/write to the shared memory buffer ---
    producer(data_ptr);

    if(sem_wait(&data_ptr->complete) == -1){
        perror("sem_wait(complete) fail.");
        return EXIT_FAILURE;
    }
    sem_unlink(READY_SEMAPHORE);
    
    if(sem_destroy(&data_ptr->semaphore) == -1||
    sem_destroy(&data_ptr->space) == -1 ||
    sem_destroy(&data_ptr->product) == -1 ||
    sem_destroy(&data_ptr->complete) == -1){
        perror("sem_destroy failed.");
        return EXIT_FAILURE;
    }
    
    // unmap shared memory object from virtual memory.
    if(munmap(buffer, SHM_SIZE) == -1){
        perror("munmap() failed.");
        return EXIT_FAILURE;
    }
    printf("munmap() success.\n");


    
    int r = shm_unlink(SHARE_MEMORY_NAME);

    if(r == -1)
    {
        perror("shm_unlink failed.");
        return EXIT_FAILURE;
    } 
    printf("shm_unlink() success.\n");
    return EXIT_SUCCESS;
}
```




consumer.c
```c=1
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

    for(int i = 0;i<10;i++){
        // look for a space.
        if(sem_wait(&data_ptr->product) == -1){
            perror("sem_wait(&data_ptr->space).");
            break;
        }
        // protect read/write critical region
        if(sem_wait(&data_ptr->semaphore) == -1){
            perror("sem_wait(&data_ptr->semaphore).");
            break;
        }
        // Read and print data from shared memory
        printf("Consume:%s\n", data_ptr->message);

        if(sem_post(&data_ptr->semaphore) == -1){
            perror("em_post(&data_ptr->semaphore)");
            break;
        }

        if(sem_post(&data_ptr->space) == -1){
            perror("sem_post(&data_ptr->product)");
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
        printf("waiting for producer.\n");
        if(errno == ENOENT) continue;
        perror("sem_open(ready) failed");
        break;
    }
    sem_wait(ready);
    sem_close(ready);


    int file_descriptor = shm_open(SHARE_MEMORY_NAME, O_RDWR, 0777);

    if(file_descriptor == -1)
    {
        perror("shm_open failed.");
        return EXIT_FAILURE;
    }
    printf("shm_open() success.\n");
    

    // map shared memory object to virtual memory.
    void *buffer =  mmap(NULL, SHM_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, file_descriptor, 0);
    if(buffer == MAP_FAILED){
        perror("mmap() failed.");
        return EXIT_FAILURE;
    }
    printf("mmap() success.\n");
    close(file_descriptor);


    // --- Initialize semaphore ---
    shared_data *data_ptr = (shared_data*)buffer;
    
    // --- Read from/write to the shared memory buffer ---
    consumer(data_ptr);

    
    // unmap shared memory object from virtual memory.s
    if(munmap(buffer, SHM_SIZE) == -1){
        perror("munmap() failed.");
        return EXIT_FAILURE;
    }
    printf("munmap() success.\n");


    return EXIT_SUCCESS;
}
```
:::success
在 Linux 中，POSIX 共享記憶體（shm_open）與具名 semaphore（sem_open）的底層實作原理相似，都是透過 tmpfs（記憶體檔案系統）實現，會在/dev/shm下建立對應這些物件的虛擬的檔案。
![image](https://hackmd.io/_uploads/SyagvAI5xl.png)

:::
執行結果:![image](https://hackmd.io/_uploads/SJJmYev9gl.png)





# Inter-Thread Producer Consumer

使用POSIX Threads (Pthreads) 函式庫來進行實作。



# 觀察性能

實驗平台：
> CPU：i7 6700
> RAM：16GB
> OS：Ubuntu 24.04.3 LTS (6.14.0-29-generic)

每個 Workload 測試 5 次取平均數值。
:::warning
目前的測試程式中實際傳輸的資料是`"product:%d"`，這是為了 debug mode 時可以清楚的看出傳遞的訊息編號，但這也代表傳輸 product 的訊息長度是會變化的，會讓量測結果有些微的誤差，建議在測試時改為 `"product"` 或是任何固定字串，或是手動將剩餘的空間統一填滿至`MAX_MESSAGE_LEN`/改使用 `memcpy` 的方式來測試。
:::

測試目標：
* 不同 workload (總共交換的 product 數量)下，IPC + Semaphore 的實作與 ITC + mutex + cond 的實作的 communication performance.

## IPC vs ITC -Initialization time
![image](https://hackmd.io/_uploads/Bk8dq-Wsgx.png)

* 可以看到，ITC (Mutex + Cond) 的 Initialization 時間要快於IPC (Semaphore)。
* Initialization time 穩定偏向 ITC (40% faster)，且幾乎不受 workload 影響。
    * ITC 的 `pthread_mutex_init` 和 `pthread_cond_init` 主要是在 Process 自己的記憶體中進行初始化，幾乎不涉及核心較為輕量。
    * IPC 的 shm_open 和具名 sem_open 則需要請求核心建立一個可跨行程共享的物件（ /dev/shm 下的 tmpfs 檔案）。這個過程需要多次系統呼叫和核心的介入，因此開銷大於 ITC。
* 在有一定 workload 的情況下 Initialication time 由於其量級近乎可以被忽略。
![image](https://hackmd.io/_uploads/S1MPv-Woll.png)


## IPC vs ITC -不同 workload 下的 Commucation time

>綠色為 ITC Communication 所花的時間。
>藍色為 IPC Communication 所花的時間。


**Buffer Size == 1**
| 1000 | 10000 | 100000 | 1000000 |
| -------- | -------- | -------- | -------
| ![image](https://hackmd.io/_uploads/rkoNVZxsee.png)     |![image](https://hackmd.io/_uploads/BJnmEbeolg.png)| ![image](https://hackmd.io/_uploads/rk3f4Wlsge.png)|![image](https://hackmd.io/_uploads/BysbNWlseg.png)|

**Buffer Size == 10**

| 1000 | 10000 | 100000 | 1000000 |
| -------- | -------- | -------- | -------
| ![image](https://hackmd.io/_uploads/r1Fwx-esex.png)     | ![image](https://hackmd.io/_uploads/H1Zuebeslx.png)     | ![image](https://hackmd.io/_uploads/SJi_ebxiel.png)    |![image](https://hackmd.io/_uploads/ByVFgbxolg.png)|

**Buffer Size == 100**

| 1000 | 10000 | 100000 | 1000000 |
| -------- | -------- | -------- | -------
| ![image](https://hackmd.io/_uploads/SyZrG-lslg.png)| ![image](https://hackmd.io/_uploads/r1gGzWxslg.png)| ![image](https://hackmd.io/_uploads/rkEWGblslx.png)|![image](https://hackmd.io/_uploads/Hk_eGbeiex.png)|

**Buffer Size == 1000**

| 1000 | 10000 | 100000 | 1000000 |
| -------- | -------- | -------- | -------
| ![image](https://hackmd.io/_uploads/HygoGbgiel.png)| ![image](https://hackmd.io/_uploads/H1khf-ejxg.png)|![image](https://hackmd.io/_uploads/BkAnf-xsxl.png)|![image](https://hackmd.io/_uploads/ryopG-eseg.png)|



### ITC Communication performance 較好:
* 除了 Buffer size=1 的案例外，ITC (Inter thread communication) 的 Communication Time 在不同 workload 下皆短於 IPC (Inter Process communication)。

### Buffer size 必須要夠大 ITC Communication的性能優勢才會體現
* 當 Buffer size 極小 ex: 1 時，幾乎每一次鎖的 wait 與 post 都會進入 slow path (每次操作都會觸發阻塞與喚醒，實際需要進入睡眠/進行喚醒)，而 ITC (Mutex + Cond)的 slow path 開銷大於 IPC (Semaphore) 的slow path 開銷，故當 Buffer size 過小時會出現 IPC 性能反超 ITC 的現象(後面會進行觀察)。

### 在 Buffer size 與 workload 夠大的情況下，ITC communication time 可以比 IPC 快 60% 以上
![image](https://hackmd.io/_uploads/SJF6qeZsee.png)



#### **情境一：緩衝區較小 (BufferSize = 10)**

在此情境下，ITC 的優勢無法完全發揮，尤其是在低負載時。但隨著交換總量的增加，效能提升率開始顯現。

| 交換總量 (ProductCount) | ITC 通訊時間 (秒) | IPC 通訊時間 (秒) | **ITC 效能提升 (Time Saved)** |
| :--- | :--- | :--- | :--- |
| 1,000 | 0.001627 | 0.001646 | 1.2% |
| 10,000 | 0.010887 | 0.015045 | 27.6% |
| 100,000 | 0.086277 | 0.133758 | 35.5% |
| 1,000,000 | 0.890124 | 1.301820 | 31.6% |



#### **情境二：緩衝區適中 (BufferSize = 100)**

當緩衝區增大到 100 時，ITC 的效能優勢變得很明顯。**在所有負載情況下，效能提升率都穩定地超過了 60%。**

| 交換總量 (ProductCount) | ITC 通訊時間 (秒) | IPC 通訊時間 (秒) | **ITC 效能提升率 (Time Saved)** |
| :--- | :--- | :--- | :--- |
| 1,000 | 0.000495 | 0.001912 | **74.1%** |
| 10,000 | 0.004817 | 0.013624 | **64.6%** |
| 100,000 | 0.037909 | 0.120903 | **68.6%** |
| 1,000,000 | 0.431316 | 1.219870 | **64.6%** |


#### **情境三：緩衝區充裕 (BufferSize = 1000)**

當緩衝區大到一定的等級後，ITC 比起 IPC 性能的差距大致都維持在相同的水準，相較於 Buffer size = 100沒有顯著的提升。**在所有負載情況下，效能提升率都穩定地超過了 65%。**

| 交換總量 (ProductCount) | ITC 通訊時間 (秒) | IPC 通訊時間 (秒) | **ITC 效能提升率 (Time Saved)** |
| :--- | :--- | :--- | :--- |
| 1,000 | 0.000564 | 0.002242 | **74.8%** |
| 10,000 | 0.004485 | 0.013192 | **66.0%** |
| 100,000 | 0.040875 | 0.123916 | **67.0%** |
| 1,000,000 | 0.401186 | 1.162030 | **65.5%** |

-----



---
## Buffer size 對於 IPC, ITC 性能的影響

| 1000 | 10000 | 100000 | 1000000 |
| -------- | -------- | -------- | -------
|![image](https://hackmd.io/_uploads/Syirrfeslx.png)| ![image](https://hackmd.io/_uploads/S1aIrfxigl.png)|![image](https://hackmd.io/_uploads/BJWdHfgsxx.png)|![image](https://hackmd.io/_uploads/Sk0dSfejge.png)|


### buffer size(橫軸 1~100 ) 對於不同 work load, 「ITC 比起 IPC 的效率提升」(縱軸%)。

>**ITC 相對 IPC 的加速百分比（Time-based 計算公式）：**

$$
\% \text{Faster} = \frac{T_{\text{IPC}} - T_{\text{ITC}}}{T_{\text{IPC}}} \times 100\%
$$
- 結果為正值 → ITC 較快  
- 結果為負值 → ITC 較慢


![image](https://hackmd.io/_uploads/r1DQmg-iex.png)
* 由上圖可以看到 Buffer size 對於 「ITC 比起 IPC 的效率提升」，在 Buffer size 為 1~ 20 的範圍影響最為明顯。
* 隨著 workload 的增加，Buffer size 對於 「ITC 比起 IPC 的效率提升」影響的趨勢會越為明顯。

### buffer size 影響最大( 1~20 )的區間。
![image](https://hackmd.io/_uploads/B1NbUeWoeg.png)
* 可以看到，在 workload 夠大的情況下，在 Buffer size > 7 時 ITC 的性能才會高於 IPC。
* 反之在 Buffer size < 6 的情況下，IPC 由於比較輕量的 slow path, 效率會比 ITC 高。



### 綜合所有 work load, 「buffer size (橫軸 1~100 ) 對於communication time 的影響」(縱軸s)。
觀察隨workload，兩種類型的時間的成長趨勢
![image](https://hackmd.io/_uploads/HkpSrl-sxe.png)
![image](https://hackmd.io/_uploads/SyU2veWslx.png)





## Throughput
![image](https://hackmd.io/_uploads/Bkc0GfZsxl.png)
橫軸每一個區域代表不同 workload ，每個 workload 下有4種不同 Buffer size 的 throughput 測試結果.
* 可以看到在 Buffer size 足夠大(>10)的情況下，ITC 可以達到 200萬的 throughput，相較於 IPC 難以超過80萬 throughput。


| 圖1 | 圖2 |
| --- | --- |
| ![image](https://hackmd.io/_uploads/BJxHvVWogl.png) | ![image](https://hackmd.io/_uploads/ry75w4Zjeg.png) |




上圖橫軸為 Workload，縱軸回 Throughput，測試 IPC 與 ITC 在 buffer size = 50 情況下的表現。
* 由圖一可以看到 IPC 的 Throughput 上限(65.9萬)顯著低於 ITC (179萬)，差距可以到近3倍
* 由圖二可以看到 ITC 在 Buffer 數量足夠(ex: 20, 50)的情況下表現優於 IPC。




## 總結

### Buffer size 與 快/慢路徑：
* 小 Buffer（1–6）：高阻塞機率→頻繁慢路徑→IPC 慢路徑較直接，常見 IPC ≤ ITC。
* 中 Buffer（≥7）：阻塞顯著下降→ITC 優勢開始浮現（約 1–36%）。
* 大 Buffer（≥100）：快路徑占比近飽和→ITC 節省率穩定 65–75%，Buffer 再增益有限。

---

* POSIX 中當進入 slow path（需要阻塞等待）時，IPC + Semaphore 的喚醒與排程開銷可能比 ITC + Mutex + Cond 的更低。
* 當 Buffer 容量足夠大（例如 > 7），阻塞機率降低，多數操作可走 fast path，ITC 較輕量 context switch 以及 `pthread_mutex`、`pthread_cond` 等用戶態同步原語，在 fast path 情況下可以直接於 user space 完成所有操作的優勢就會體現出來，ITC 的溝通性能將會明顯超過 IPC。





### Initialization time vs Communication time 的量級：
在大部分工作負載下，InitTime < 1% CommTime，可忽略。
![image](https://hackmd.io/_uploads/S1MPv-Woll.png)




## 透過strace 觀察呼叫 futex system call 的情況
### workload = 100000：
1. IPC + Semaphore
    ```bash
    strace -f -c -e trace=futex ./run_ipc_test.sh
    ```
    * Buffer size=1
![image](https://hackmd.io/_uploads/B1SCWSbsge.png)



    | Buffer size=10 | Buffer size=50 | Buffer size=100 |
    | -------- | -------- | -------- |
    | ![image](https://hackmd.io/_uploads/BJnUGB-sgx.png)    | ![image](https://hackmd.io/_uploads/rJYBmHWogg.png)    | ![image](https://hackmd.io/_uploads/SkkcrHZoxg.png)     |




2. ITC + Mutex + Cond
    ```bash
    strace -f -e trace=futex -c ./thread_producer_consumer
    ```

    * Buffer size=1
    ![image](https://hackmd.io/_uploads/ryCNtqtcgx.png)
    
    

    | Buffer size=10 | Buffer size=50 | Buffer size=100 |
    | -------- | -------- | -------- |
    | ![image](https://hackmd.io/_uploads/r1SjfB-olx.png)     | ![image](https://hackmd.io/_uploads/rJ1GQSboxg.png)     | ![image](https://hackmd.io/_uploads/BJ44Ur-sxe.png)    |


    

:::info
關於 strace 的觀測結果
---
strace 這裡給出的 time 與 "µs/call" 通常包含 syscall 在 kernel 裡等待的 wall-clock 時間（例如 futex/cond_wait 因等待被喚醒而花的時間會算到該 syscall 上）。因此較高的 µs/call 不一定表示 syscall 本身 CPU 開銷大，可能是「等待被 signal 的時間長」。
因此，ITC 的 11–14 µs/call 很可能包含了大量 sleep/wake（blocking）時間；小 buffer 時更會頻繁 block/wake，累積大量 wall-time。

:::



| Buffer Size | IPC + Semaphore Calls / Sec / µs/call | ITC + Mutex+Cond Calls / Sec / µs/call | ITC / IPC Calls (%) |
|-------------|---------------------------------------|-----------------------------------------|---------------------|
| 1           | 280,845 / 0.590 s / 2 µs              | 350,278 / 4.634 s / 13 µs               | 124.7%              |
| 10          | 167,499 / 0.506 s / 3 µs              | 69,023  / 0.843 s / 12 µs               | 41.2%               |
| 50          | 166,389 / 0.547 s / 3 µs              | 19,467  / 0.280 s / 14 µs               | 11.7%               |
| 100         | 160,236 / 0.507 s / 3 µs              | 10,665  / 0.121 s / 11 µs               | 6.7%                |

觀察 strace 的結果：
* 隨著 buffer size 增加，整體同步相關的時間(futex system call耗時)有明顯下降
當 buffer = 1 時，IPC（semaphore）和 ITC（mutex + cond）加起來的同步時間大約是 5.224 秒，而到 buffer = 100 時已經降到 0.628 秒，減少了將近 88%。 
* system call 次數
    * IPC 大致維持在 16 萬到 28 萬之間，變化不大
    * ITC 從 35 萬次一路降到大約 1 萬次，下降幅度非常明顯。
* 平均每次呼叫的耗時，ITC 在所有測試點都比 IPC 高
    * ITC 約落在 11–14 µs/call
    * IPC 則在 2–3 µs/call 左右。


## 使用 perf 來觀察 context switch 總數：
1. IPC + Semaphore
    ```bash
    sudo perf stat -e context-switches,cpu-migrations,minor-faults,major-faults bash -c "./consumer & ./producer"
    ```
    * buffer size = 1
    ![image](https://hackmd.io/_uploads/S1FC-wWjeg.png)
    
    

    | buffer size = 10 | buffer size = 50 | buffer size = 100 |
    | -------- | -------- | -------- |
    | ![image](https://hackmd.io/_uploads/r1tYZD-sel.png)     | ![image](https://hackmd.io/_uploads/H1-7fvbilx.png)     | ![image](https://hackmd.io/_uploads/S1eXWvWieg.png)    |


    

2. ITC + Mutex + Cond
    ```bash
    sudo perf stat -e context-switches,cpu-migrations,minor-faults,major-faults ./thread_producer_consumer 
    ```
    * buffer size = 1
    ![image](https://hackmd.io/_uploads/SytHZiYqxg.png)
    
    | buffer size = 10 | buffer size = 50 | buffer size = 100 |
    | -------- | -------- | -------- |
    | ![image](https://hackmd.io/_uploads/HJciMvZogg.png)|![image](https://hackmd.io/_uploads/SkXgmDboll.png)     | ![image](https://hackmd.io/_uploads/HyXJZvZjee.png)     |
    


| Buffer Size | IPC + Semaphore (context-switches) | ITC + Mutex + Cond (context-switches) | ITC / IPC (%) |
|-------------|------------------------------------|----------------------------------------|---------------|
| 1           | 184,242                            | 199,538                                | 108.3%        |
| 10          | 7,790                              | 19,398                                 | 249.0%        |
| 50          | 5,320                              | 2,135                                  | 40.1%         |
| 100         | 4,087                              | 752                                    | 18.4%         |

透過 perf 來觀察 context-switch：
* 結果與 strace 同樣顯示，buffer size 增加會讓同步相關的負擔下降。
    * 當 buffer = 1 時，IPC 約有 184,242 次 context switch，ITC 約 199,538 次
    * 到 buffer = 100 時，IPC 降到 4,087 次，ITC 則只剩 752 次。 
* ITC 的 context switch 次數隨 buffer 增加下降得更快，從 20 萬級別直接掉到不到一千次
* IPC 的context switch 次數隨 buffer 增加下降幅度相對較小。

整體來說，小 buffer 時兩者的 context switch 數量差不多，但在 buffer 變大後，ITC 的數字明顯比 IPC 少很多。



# NPTL (Native POSIX Thread Library)
reference: bootlin, [codebrowser.dev](https://codebrowser.dev/glibc/glibc/nptl/sem_wait.c.html#23)

現代 glibc 的 NPTL (Native POSIX Thread Library) 實作中，sem_wait 通常是一個弱符號 (weak alias)，它指向一個強符號的內部實作函式。這個真正的實作就是 __new_sem_wait。

這種設計允許 glibc 在內部更新或替換實作，而無需改變標準的 API 介面，提供了很好的向後相容性和靈活性。

設是透過`versioned_symbol()`這個 MACRO 來實現的:
`sem_wait.c`
```c=45
versioned_symbol (libc, __new_sem_wait, sem_wait, GLIBC_2_34);
```

(待更新...)
