# --- Variables ---
CC = gcc
CFLAGS = -Wall -Wextra
DEBUG_FLAGS = -g -DDEBUG
# Linker flags:
# -pthread: Link with the POSIX threads library.
LDFLAGS = -pthread -lrt
TARGETS = thread_producer_consumer
DEBUG_TARGETS = thread_producer_consumer_debug
RM = rm -f



# --- Rules ---
all: $(TARGETS)
debug: $(DEBUG_TARGETS)

thread_producer_consumer: thread_producer_consumer.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# --- Rule for debug (showcase) mode ---
thread_producer_consumer_debug: thread_producer_consumer.c
	$(CC) $(CFLAGS) $(DEBUG_FLAGS) -o $@ $< $(LDFLAGS)

clean:
	$(RM) $(TARGETS) $(DEBUG_TARGETS)

# Declare that 'all' and 'clean' are not actual files.
.PHONY: all clean thread_producer_consumer_debug



