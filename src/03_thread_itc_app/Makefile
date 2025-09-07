# --- Variables ---
CC = gcc
CFLAGS = -Wall -Wextra
DEBUG_FLAGS = -g -DDEBUG
LDFLAGS = -pthread -lrt # -pthread: Link with the POSIX threads library.
RM = rm -f

# Find all .c files in current directory.
SRCS = $(wildcard *.c)
TARGETS = $(patsubst %.c, %, $(SRCS)) # remove .c suffix
DEBUG_TARGETS = $(addsuffix _debug, $(TARGETS))


# --- Main Rules ---
all: $(TARGETS)
debug: $(DEBUG_TARGETS)

# --- Pattern Rules ---
%:%.c
	@echo "Compiling $< to $@"
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

%_debug: %.c
	@echo "Compiling $< to $@(Debug Mode)"
	$(CC) $(CFLAGS) $(DEBUG_FLAGS) -o $@ $< $(LDFLAGS)

clean:
	$(RM) $(TARGETS) $(DEBUG_TARGETS)

# Declare that 'all' and 'clean' are not actual files.
.PHONY: all debug clean



