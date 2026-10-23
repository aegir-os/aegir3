# Tests for the compiler. Each test suite is a check-* target listed in CHECKS;
# all of them run as part of the build.
#
# Suites run tools/check-golden.lua: each case is a file, with NAME.expected or
# NAME.refused beside it when the output is not the file itself.

ROOT := ../..
include $(ROOT)/config.mk

GOLDEN := $(LUA) $(ROOT)/tools/check-golden.lua

CHECKS := check-sexpr check-ir-roundtrip check-verifier

.PHONY: all clean $(CHECKS)

all: $(CHECKS)

# The S-expression syntax of the IR text form, read and written back.
check-sexpr:
	$(GOLDEN) $@ '$(O5IR) {} SEXPR' $(sort $(wildcard sexpr/*.o5ir))

# IR modules read into IR records, shape-checked, and written back in canonical
# form. Binary round trips join when the binary form exists.
check-ir-roundtrip:
	$(GOLDEN) $@ '$(O5IR) {}' $(sort $(wildcard ir/*.o5ir))

# IR modules verified as the translation service will: the cases in verify/,
# one or more per verifier rule, and every case in ir/, which must verify or be
# refused by the reader exactly as before.
check-verifier:
	$(GOLDEN) $@ '$(O5IR) {} VERIFY' $(sort $(wildcard verify/*.o5ir ir/*.o5ir))

clean:
