# Aegir top-level build. Each directory has its own Makefile; this one chains
# them in dependency order. Every check-* target is a prerequisite of the build.

ROOT := .
include $(ROOT)/config.mk

SUBDIRS := tools compiler libs kernel apps

.PHONY: all clean check-tools $(SUBDIRS)

all: $(SUBDIRS)

$(SUBDIRS): check-tools
	$(MAKE) -C $@ all

compiler: tools
libs: compiler
kernel: compiler
apps: compiler libs

check-tools:
	@missing=0; \
	for t in $(REQUIRED_TOOLS); do \
		command -v $$t >/dev/null 2>&1 || { echo "refused: check-tools: $$t not found" >&2; missing=1; }; \
	done; \
	exit $$missing

clean:
	@for d in $(SUBDIRS); do $(MAKE) -C $$d clean || exit 1; done
