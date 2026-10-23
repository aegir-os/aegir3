# Aegir kernel, hosted and bare metal. See specs/kernel.md.
# Building this directory runs its tests: check is a prerequisite of all.

ROOT := ..
include $(ROOT)/config.mk

.PHONY: all build check clean

all: check

build:

check: build
	$(MAKE) -C tests all

clean:
	$(MAKE) -C tests clean
