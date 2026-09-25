# Tests hote d'ASOS : make -C asos/tests
ASOS := ..
CC   ?= cc
CFLAGS := -std=c11 -O2 -Wall -Wextra -Werror \
          -I$(ASOS)/include -I$(ASOS)/event_processing -I$(ASOS)/security_context \
          -I$(ASOS)/supervision_unit -I$(ASOS)/update_unit
SRCS := $(ASOS)/asos.c \
        $(ASOS)/event_processing/event_processing.c \
        $(ASOS)/security_context/security_context.c \
        $(ASOS)/supervision_unit/supervision_unit.c \
        $(ASOS)/update_unit/update_unit.c
LOGS ?= $(wildcard $(ASOS)/../results/*.log)

all: test

replay: replay.c $(SRCS)
	$(CC) $(CFLAGS) -o $@ replay.c $(SRCS)

unit: unit.c $(SRCS)
	$(CC) $(CFLAGS) -o $@ unit.c $(SRCS)

test: unit replay
	@./unit
	@python3 replay_logs.py ./replay $(LOGS)

clean:
	rm -f replay unit

.PHONY: all test clean
