# Oberon-5 compiler (o5c) and IR tool (o5ir). Written in Oberon-2 and built with
# VOC until they move to Oberon-5. See specs/oberon.md and specs/ir.md.
# Building this directory runs its tests: check is a prerequisite of all.

ROOT := ..
include $(ROOT)/config.mk

SRC   := src
BUILD := build

# Library modules in dependency order; VOC compiles them in the order given.
LIBS    := Report Sexpr IrLayout Ir IrText Verify Scan Ast Parse
LIB_SRC := $(LIBS:%=$(SRC)/%.Mod)

.PHONY: all build check clean

all: check

build: $(O5C) $(O5IR)

$(BUILD)/libs.stamp: $(LIB_SRC)
	mkdir -p $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) $(LIB_SRC:%=../%)
	touch $@

# Link a main program: compile $< into $(BUILD), then rename the binary, which
# VOC names after the module, to the lowercase command name.
define link
	cd $(BUILD) && $(VOC) $(VOCFLAGS) ../$< $(VOC_MAIN)
	mv $(BUILD)/$(basename $(notdir $<)) $@
endef

$(O5C): $(SRC)/O5c.Mod $(BUILD)/libs.stamp
	$(link)

$(O5IR): $(SRC)/O5ir.Mod $(BUILD)/libs.stamp
	$(link)

check: build
	$(MAKE) -C tests all

clean:
	rm -rf $(BUILD)
	$(MAKE) -C tests clean
