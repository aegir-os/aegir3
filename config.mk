# Shared build settings, included by every Makefile in the tree.

# Host tools. Override on the command line, e.g. `make LUA=lua5.4`.
LUA ?= lua
VOC ?= voc
CC  := clang

# VOC flag for a main program. -M links statically, so binaries do not need
# the libvoc shared library, which Fedora's loader does not find in /usr/local/lib.
VOC_MAIN := -M

# VOC flags for every module:
#   -OC  Component Pascal sizes: SHORTINT 16, INTEGER 32, LONGINT 64 bits,
#        matching Oberon-5's ShortInt, Integer and LongInt.
#   -r   halt on range check failures (off by default in VOC).
#   -s   allow new symbol files.
# VOC does not check integer overflow; the compiler checks it explicitly where
# it matters, such as constant folding.
VOCFLAGS := -OC -r -s

# The compiler and the IR tool, as built by compiler/Makefile.
O5C  := $(ROOT)/compiler/build/o5c
O5IR := $(ROOT)/compiler/build/o5ir

# Tools the build cannot run without, checked by check-tools.
REQUIRED_TOOLS := $(LUA) $(VOC) $(CC)
