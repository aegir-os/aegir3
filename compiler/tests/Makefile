# Tests for the compiler. Each test suite is a check-* target listed in CHECKS;
# all of them run as part of the build.

ROOT := ../..
include $(ROOT)/config.mk

CHECKS := check-ir-roundtrip

.PHONY: all clean $(CHECKS)

all: $(CHECKS)

# IR text files read and written back in canonical form. Each case is
# ir/NAME.o5ir, with ir/NAME.expected or ir/NAME.refused when the output is not
# the input itself. Binary round trips join when the binary form exists.
check-ir-roundtrip:
	$(LUA) $(ROOT)/tools/check-ir-roundtrip.lua $(O5IR) $(sort $(wildcard ir/*.o5ir))

clean:
