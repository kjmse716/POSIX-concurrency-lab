# --- Variables ---
CC = gcc
CFLAGS = -Wall -Wextra
DEBUG_FLAGS = -g -DDEBUG
# Linker flags:
# -lrt: Link with the real-time library (for shm_open, sem_open)
# -pthread: Link with the POSIX threads library (for semaphores)
LDFLAGS = -lrt -pthread
TARGETS = producer consumer
DEBUG_TARGETS = producer_debug consumer_debug
RM = rm -f



# --- Rules ---
all: $(TARGETS)
debug: $(DEBUG_TARGETS)

producer: producer.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
consumer: consumer.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
clean:
	$(RM) $(TARGETS) $(DEBUG_TARGETS)

# ---Rules for debug (showcase) mode.
producer_debug: producer.c
	$(CC) $(CFLAGS) $(DEBUG_FLAGS) -o $@ $< $(LDFLAGS) 
consumer_debug: consumer.c
	$(CC) $(CFLAGS) $(DEBUG_FLAGS) -o $@ $< $(LDFLAGS) 


# Declare that 'all' and 'clean' are not actual files.
.PHONY: all clean debug



