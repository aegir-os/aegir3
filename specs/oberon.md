# Oberon-5

Oberon-2 (a derivative thereof) will be the primary development language
for Aegir.

## Differences from Oberon-2

- All reserved words are lowercase
  - This is more of a usability change than anything else
- First class Unicode support - UTF-8
  - A proper `String` type supporting Unicode
  - Unicode supporting `Char` type
  - Source files can be Unicode-encoded
- Region pointers: `pointer {region} to T`, a distinct pointer kind for shared
  and IPC memory, with checked conversion only through `Unsafe`. See
  [Pointers across domains](#pointers-across-domains).
- Oberon's `SYSTEM` pseudo-module is renamed `Unsafe`. Importing it is the
  visible sign that a module does unchecked things, and it leaves `System` free
  as an ordinary namespace root.
- Standard library module and procedure names are CamelCase: `Unsafe.Region`,
  not `UNSAFE.REGION`. Reserved words and predeclared procedures (`new`)
  stay lowercase.
- Dotted module names: `System.Foo`. See [Module names](#module-names).
- Blocking procedures are flagged `{blocking}`, checked by the compiler. See
  [Blocking is explicit](#blocking-is-explicit).

## Module names

Module names may be dotted, so a provided module and a library are less likely to
collide. The dots are for naming only.

- On disk, each dot is a directory and the last component is the file. A module
  with children is still a file named after the module, never a `mod.rs`-style
  file inside its directory:

  ```
  System.ob5            module System
  System/Foo.ob5        module System.Foo
  System/Foo/Bar.ob5    module System.Foo.Bar
  ```

  Rust 2018 also allows this layout, but keeps `mod.rs` as an alternative. Here it
  is the only layout.
- A directory without a matching file is allowed: `Net/Http.ob5` without
  `Net.ob5` gives `Net.Http` and no `Net` module.
- The source declares its full name, `module System.Foo;`, and it must match the
  path. A mismatch is a loud failure naming both.
- Naming only: `System.Foo` gets no access to `System`'s unexported declarations
  and does not import it implicitly. They are separate modules with separate
  fingerprints.
- Imports use the full name and bind the last component: `import System.Foo;`
  makes `Foo.Proc` available. Two imports binding the same name
  (`import System.Foo, Net.Foo;`) are a compile error naming both; alias one with
  Oberon-2's existing syntax: `import NetFoo := Net.Foo;`.
- A qualified identifier in code has exactly one dot, `Foo.Proc`, so a module
  name can never be confused with an export of its parent.
- The loader, import lists, fingerprints, `OpenLibrary` and the module-address
  key all use the full dotted name.
- Module names are unique ignoring case, so a case-insensitive file system cannot
  make two modules collide.

## Bootstrapping

The language will be bootstrapped with [Vishap Oberon Compiler](https://github.com/vishapoberon/compiler).

The compiler will build in stages:

1. VOC will be used to build the first compiler in plain Oberon-2.
2. Move the compiler to Oberon-5 once it can compile itself.

## Refusals

Refusals come in a few forms:

- Exhausting a domain terminates a running program with an explicit system return
  code.
- Functions that can fail will return a result code (Oberon standard)
- HALT will terminate a domain with an explicit system return code.
- ASSERT failures will terminate a domain, when running with assertions enabled.
  Assertion enablement is a compiler flag, and are non-op when this flag is disabled.

## Codegen

Codegen will follow a mixture of the Native Oberon and IBM TIMI-style. Codegen 
will emit an IR.

Taken from Native Oberon’s module loader, compiled module objects with import lists 
and fixup lists, and resolved imports at load time by patching call targets. No ELF, 
no relocations, no PLT/GOT, dynamic linking is the Oberon-style.

The IR is serializable and version-stable. It will be well-documented. IR version
increases by explicit action, say a language addition, or deprecation. Java is
prior art for this - see class versioning.

Also from Native Oberon, use fingerprinting - hash computed over each exported
declaration’s signature, and the loader checks that a module’s imports match the
fingerprints of what it’s loading against. Failing a fingerprint is a loud failure -
refuse to load, name the module and mismatching symbols.

Drivers and the base system: translate at build time, ship native, keep the 
IR for porting.

Apps: ship IR, translate at first run, cache native in the program object. This does
mean an initial performance hit. That is accepted until a greater "installation" story
exists within Aegir. 

This supports an `OpenLibrary` / `CloseLibrary` like implementation like the Amiga.
Reference-counted load, resolve by name and version, unload when the count hits zero. 
A cycle is possible, and when detected should be loudly indicated, name the offending
libraries, but continue to execute. This should be considered a design flaw in
libraries that cause these cycles.

## Memory model

One global address space with protection domains to isolate programs.

This isn't full SASOS. Addresses are assigned globally, but each domain has its
own page table. "Global" means two domains that can both see a thing see it at the
same address, not that every domain sees everything.

- Shared code modules at fixed system-wide addresses. Identical frames everywhere.
- Shared data regions used for IPC at globally unique addresses, so pointers in 
  messages work.
- Private heap and stack per-domain, allowed to overlap between domains, since 
  nobody passes those pointers anyway.

Prior art is IBM i (System/38): never-reused addresses, and the lesson that
never-reuse is a *rate* problem, not a size problem. Allocations per second times
uptime, against the number of reservations, decides when it runs out. IBM i ends
the partition when temporary addresses hit 100% and resets them at IPL. We keep
their temporary/permanent split and their gauge, and reject their cliff.

### Address width

Design to 39 bits on every architecture. Sv39 is the RISC-V floor; AArch64
and x86-64 use the low 256 GiB of their larger spaces and leave the rest unmapped.
One layout, one table, no per-platform growth path. The domain-visible half is
256 GiB.

### Address classes

Every address belongs to exactly one class. A class is a fixed range, set at build
time, with its own reuse policy. Classifying an address is a range compare.

| Class      | Range                               | Size    | Reuse                         | Contents                          |
|------------|-------------------------------------|---------|-------------------------------|-----------------------------------|
| null guard | `0x00_0000_0000` – `0x00_0001_0000` | 64 KiB  | never mapped                  | catches `nil` + small offset      |
| private    | `0x00_0001_0000` – `0x10_0000_0000` | 64 GiB  | freely, per domain            | heap, stacks                      |
| module     | `0x10_0000_0000` – `0x18_0000_0000` | 32 GiB  | keyed by image, see below     | code, constants, module variables |
| shared     | `0x18_0000_0000` – `0x20_0000_0000` | 32 GiB  | never (until reboot)          | long-lived shared regions         |
| ipc        | `0x20_0000_0000` – `0x40_0000_0000` | 128 GiB | epoch drain, see below        | transient message regions         |

Sizes are first guesses. The rates that follow are assumptions to be replaced with
measurements from the gauge.

#### Private

- Overlaps between domains. Heap and stack reservations are placed at spawn from
  the domain's budget and never move or grow.
- Reclaimed wholesale when the domain dies. No identity, no reuse restriction.

#### Module

- Each loaded image gets one reservation: code (RX), constants (R), variables (RW),
  rounded to 64 KiB, followed by a 64 KiB unmapped guard.
- The reservation is keyed by (module name, content hash of the image). When an
  image's count hits zero and it is later reloaded unchanged, it gets the same
  address back. A different image never gets an address any other image has held
  since boot.
- Consequence: a stale procedure pointer into an unloaded module either points at
  that exact code (same image, reloaded) or faults. It never lands in different code.
- Consequence: consumption scales with *distinct images loaded since boot*, not with
  `OpenLibrary`/`CloseLibrary` calls. Refcounted unload plus plain never-reuse
  would repeat IBM's file open/close exhaustion; keying removes it.
- Code and constant frames are shared by every domain.
- Module variables are per domain: the same address in every domain, private
  frames, allocated and initialized when the domain first imports the module,
  charged to that domain's budget. Writable data shared across domains goes in a
  shared region, never in module variables.
- Module addresses do not survive reboot. The class is reset every boot, and
  native code cached in program objects is fixed up at load like everything else.
  Images change far more often than on IBM i, so a persistent address would mostly
  pin stale versions.
- Budget: 32 GiB / (256 KiB average image + 64 KiB guard) ≈ 100,000 distinct images
  per boot.

#### Shared

- Never reused until reboot. For regions with stable identity and long life:
  service state, framebuffers, published tables.
- Creation is charged to the creating domain as a cumulative quota fixed at spawn
  and not refunded on free, so one domain looping create/destroy hits its own
  refusal before it exhausts the class.
- Budget: 32 GiB / 64 KiB granularity = 524,288 creations per boot.

#### IPC

- Divided into 64 epochs of 2 GiB, used in ring order.
- Allocation bumps through the current epoch. When it is full, advance to the
  next epoch in the ring that has no live regions, skipping pinned ones.
- An epoch with no live regions becomes reusable as a whole. An address is not
  reused until the ring has gone all the way round, roughly 128 GiB of other IPC
  allocation, minus pinned epochs.
- Granularity is 4 KiB pages plus a 4 KiB unmapped guard per region:
  262,144 minimum-size regions per epoch.
- A region lives while any domain maps it. Domain death unmaps everything it held.
- A live region pins its epoch. If every epoch is pinned, allocation is refused.
  Regions expected to outlive a ring cycle belong in shared.
- This is IBM i's IPL reset, made local: the quiesce point is one 2 GiB window
  draining, not the machine restarting.

### Pointers across domains

Private ranges overlap, so a private pointer that leaks into a message does not
fault in the receiver. It silently names the receiver's own heap. The kernel
cannot cheaply check this, so the type system must:

- Pointers into regions are a distinct pointer kind from heap pointers, spelled
  with an Active Oberon style flag: `pointer {region} to T`. Flags are not reserved
  words, so `region` stays usable as an identifier, and the braces leave room for
  later flags.
- Records reachable through a region pointer may contain only region pointers.
- Allocation names the region: `new(p, r)`. `new(p)` on a region pointer is a
  compile-time error.
- Assigning between kinds is a compile-time error in either direction. `nil`
  belongs to both.
- No implicit conversion exists. Converting a raw address goes through `Unsafe`,
  with the other unchecked operations: `Unsafe.Region(T, adr)` checks the address
  class (range compare) and traps unless `adr` is in shared or ipc. It does not
  check that the domain has the region mapped; an unmapped address faults on use.
  The goal is that a wrong address faults instead of silently aliasing, not that
  every error is caught before runtime.
- Type tests (`is`, type guards) work on region pointers across domains. Type tags
  live in the module class, so the same image gives the same tag in every domain,
  and a different image fails the test instead of misreading.

```oberon
var
  h: pointer to Node;
  p: pointer {region} to Msg;
  r: Region;

new(p, r);                     (* ok *)
new(p);                        (* error: region pointer needs a region *)
p := h;                        (* error: different pointer kinds *)
p.next := h;                   (* error: heap pointer in region memory *)
p := Unsafe.Region(Msg, adr);  (* traps unless adr is shared or ipc *)
```

### Memory management

A garbage collector, and traditional memory management will be available.
Garbage collection is the default, but is opt-out to support low-level code 
like kernel and drivers.

#### Explicit memory management

Drivers and kernel will use explicit allocation. This means `new` and `dispose` 
will be supported for this use case. A zero allocation model should be the default
in drivers and kernel, but the explicit management is present when needed.

#### Garbage collection

Garbage collection is a first-class citizen of the runtime. Initial version is
a simple conservative GC, per domain. 

- Scans the domain's private heap. Roots: stacks, registers, the domain's module
  variable instances.
- A word is a candidate pointer only if it falls in the domain's heap range.
- Never frees anything outside the private heap. Region lifetime is explicit
  (map, unmap, count), never traced.
- The heap is fixed at spawn and never grows. When a collection cannot satisfy an
  allocation, the allocation is refused with the numbers:
  `heap exhausted: 48 MiB of 48 MiB live after collection, request 64 KiB`.

### Spawn budget

A domain receives at spawn, and dies with a refusal naming the number:

- Heap bytes.
- Thread slots and stack bytes per thread. See [Concurrency](#concurrency).
- Worker pool size and job queue length.
- Module-variable bytes for everything it may import.
- Live IPC regions; live shared-region mappings.
- Cumulative shared-class creation quota.

The program declares these, after the Amiga's stack setting in a program's
icon:

- The budget is metadata in the program object, written at build. Changing it
  does not change any fingerprint and needs no recompile.
- An item the program does not declare takes the system default.
- The launcher may override any item for one launch, as Workbench Tool Types
  and the CLI `Stack` command do. The override applies to that launch only and
  is never written back.
- A budget the system cannot grant refuses the spawn, naming the item, the
  request and what is available: `refused: spawn: heap 512 MiB requested, 384 MiB
  available`. Nothing is granted partially.

### Exhaustion and the gauge

- Exhaustion of any class is a refusal in the domain that asked, naming class,
  used, total and request:
  `refused: ipc class: 64 of 64 epochs pinned, request 16 KiB`.
  Never a system-wide abort.
- The gauge exists from the first commit of the allocator. Per class: total, in
  use, high-water, consumed since boot (non-reused classes), rate over 1 minute and
  1 hour, projected exhaustion time at current rate. For ipc: epochs empty, active
  and pinned, and for each pinned epoch the oldest live region's owner and age.
- The hosted backend runs the same allocator over the same table, so exhaustion
  reproduces there.
- `check-layout`, a build prerequisite: the class table is contiguous,
  non-overlapping, granularity-aligned and fits 39 bits.

### Open

- Class sizes are build-time constants and cheap to change. Only one class can
  run out from rate alone: ipc reclaims by epoch, and module consumption counts
  distinct images rather than loads. Shared is the one to watch: 524,288
  creations per boot lasts about 6 days at 1 per second and about a year at 1 per
  minute. The assumption is that shared regions are created about as often as
  services start, not per request. The gauge on the hosted backend is the first
  place to check it.

## Concurrency

The driving case: an operation started by a button must never hang the
application. The thread handling events must never be the one doing the work, and
when it is, that is an error at compile time where possible and a refusal at
runtime otherwise.

### Threads

- Kernel threads, scheduled across all cores. Green threads are rejected: they
  use one core, and a single blocking call stalls every thread in the domain.
- Thread slots and stack size are fixed at spawn, from the program's declared
  budget (see [Spawn budget](#spawn-budget)). Starting a thread past the limit
  is a refusal: `refused: threads: 8 of 8 in use`.
- GC stops every thread in the domain and scans all of their stacks. Other
  domains are unaffected.

### Ports

Communication is by message ports, after Exec.

- A thread owns ports and waits on a set of them at once.
- Messages between threads of one domain may carry heap pointers. Messages
  between domains carry region pointers.
- The intended pattern: a handler sends work to a worker and returns. The worker
  replies with progress and completion messages to the event thread's port.
  Changing state is not shared between the two, so the event thread never waits
  on a lock the worker holds.

### Blocking is explicit

- A procedure that may block is flagged: `procedure Read* {blocking} (...)`. Not
  flagged means it does not block.
- A procedure that calls a `{blocking}` procedure must itself be `{blocking}`.
  The compiler rejects it otherwise, naming the call.
- The flag is part of the procedure type, so procedure variables and type-bound
  procedures carry it, and it is part of the exported fingerprint. Making a
  procedure blocking is an interface change and fails loudly at load.
- The flag is in the IR from its first version, so translated apps keep the
  check.
- Every operation that waits has two forms, after Exec's `DoIO` and `SendIO`:
  - `Send...` starts the operation and returns at once. Completion arrives as a
    message on a reply port. `Abort...` cancels it.
  - `Do...` is `{blocking}`: the same request, then a wait for its reply.

  The kernel and drivers implement only the `Send` form. `Do` is a library
  wrapper, so the non-blocking form costs nothing extra to provide.

A non-blocking procedure should be accepted wherever a blocking one is expected, 
but not the other way round. An override must not add {blocking} when the base 
method doesn't have it. Attempting to do so is a compiler refusal.

### Event threads

- An event thread is one whose loop is run by the runtime:
  `Ports.Run(port, handler)`. The handler's procedure type is not `{blocking}`,
  so passing a blocking procedure is a compile-time error.
- Waiting on its ports between messages is the only blocking an event thread
  does, and the runtime does it, not the handler.
- Backstop for what the compiler cannot see (`Unsafe`, a wrong flag): a blocking
  kernel call from an event thread is refused, naming the procedure.
- Watchdog for what neither can see, long computation: an event thread that has
  not returned to its port wait within a fixed limit is reported, naming the
  running procedure.

### Work pool

- Each domain has a fixed pool of worker threads and a fixed-length job queue,
  set at spawn. `Tasks.Run(Proc, replyPort)` queues a job. A full queue is a
  refusal naming the length.
- Every job gets a cancel flag that the worker checks. Cancellation is
  cooperative, and present from the start.

### Shared memory between threads

At minimum: an `Atomics` module. A data race isn't memory-safe but is otherwise 
unspecified.

## Open

- The watchdog limit. 200 ms is a starting guess.
- GC pauses on an event thread look like hangs. Measure pause time early;
  incremental collection may be needed sooner than planned.
- Whether lock-based code is common enough to want Active Oberon's `{exclusive}`
  and `await`. Start with library modules only (`Threads`, `Ports`, `Tasks`).
  Adding them later is a language addition and bumps the IR version.

## Cross-domain concerns

### Finding ports by name

Exec's `FindPort(name)` searched one system-wide list of public ports. It had
two flaws: no protection, so any task could write to any public port, and a race,
because the port could vanish between `FindPort` and `PutMsg`. Callers wrapped
the pair in `Forbid()`/`Permit()`, stopping multitasking to get around it.

- A domain publishes a port under a name: `Ports.Publish(port, "Editor")`.
  Publishing is opt-in; an unpublished port cannot be found.
- `Ports.Find(name)` returns a handle, not the port. The kernel checks the handle
  on every send.
- Sending to a handle whose port is gone returns a result code naming the port.
  It never crashes and never needs the system stopped.
- A name is unique while its port lives. A second publish of a live name gets
  an instance suffix, as ARexx ports did: `Editor.1`, `Editor.2`.
- Handles are slots, counted in the spawn budget.

### Command ports

After ARexx: an application exposes commands on a published port, and anything
can drive it without sharing types. The protocol is the stable part. The
scripting language comes later and sits on top.

Two levels of cross-domain communication:

1. Typed messages between Oberon-5 programs: records through region pointers,
   type tags checked across domains. Fast, and checked by the compiler.
2. Command ports, for scripts, the shell and anything without shared types.

The command protocol:

- A command is a name and arguments. Arguments are plain values: strings,
  integers, lists and keyed tables.
- A reply is a result code and values, after ARexx's return code and `RESULT`.
- Commands are described with `ReadArgs` templates, as in AmigaDOS:
  `OPEN FILE/A,LINE/N,READONLY/S`. One parser serves the shell, scripts and the
  application.
- Every command port answers a standard query listing its commands and their
  templates. A port that cannot describe itself is incomplete.
- Command handlers run on the event thread and are not `{blocking}`. A slow
  command keeps the message and replies when its worker finishes.
- Small messages are copied inline by the kernel, up to a fixed size. Only larger
  payloads use an ipc region, so a script sending many small commands does not
  consume ipc address space.
- Each command port has a fixed queue length. A full queue returns a result code
  to the sender, naming the length.

Scripts:

- A running script is its own domain with its own budget. A runaway script hits
  its own limits, not the application's.
- A script is not an event thread, so a command call from a script may wait for
  its reply.
- First: the command protocol, templates and the shell. A scripting language
  follows once the base system runs.
- The language is Lua, the reference C implementation through the
  [FFI](#foreign-function-interface-ffi). It is not rewritten in Oberon-5.
- Lua's allocator hook (`lua_Alloc`) is backed by the script domain's explicit
  allocator, so Lua's own GC works inside the domain's budget and a script that
  runs out of memory gets Lua's normal memory error.

## Foreign function interface (FFI)

C code will be needed: FreeType and Lua, for two. Not fully designed yet; any
design must meet these rules:

- C is compiled at build time with a cross compiler and converted to Aegir's
  module object format. No on-device linking, no ELF at runtime.
- Importing a C module is visible, as importing `Unsafe` is: C is not memory-safe.
- C memory comes from an explicit allocator charged to the domain's budget, never
  the GC heap. The conservative GC does not scan it, so a heap pointer handed to
  C must be kept alive from the Oberon side for as long as C holds it.
- C procedures are declared in an Oberon-5 interface module that states their
  types and whether they are `{blocking}`. The compiler trusts the declaration.
- C code counts against the base system's size budget like everything else.
- No `longjmp` across Oberon frames. C libraries that unwind this way (Lua's
  `lua_error`) call Oberon only through a C shim: the Oberon procedure returns a
  result code and the shim raises the C-side error.

### Open

- Which C library C code gets. Lua and FreeType both expect parts of the C
  standard library (`malloc`, `string.h`, Lua's `io` and `os` on `stdio`). A small
  libc subset over Aegir modules is likely; how much of it, and whether Lua's `io`
  and `os` are replaced by Aegir-specific modules, is undecided.
- The cross compiler and the object conversion step.

## Cleanup

When a domain terminates, cleanup will walk the table and dispose of any resources.
This includes ports, messages still in flight to a dead port, outstanding `Send...`
requests, library reference counts, worker jobs.

Outstanding requests to a dead domain need to complete with an error result code.

## Datatypes

A 64 bit address space is assumed.

1. Boolean - the truth values True and False

### Numeric

1. Byte - a single byte (8 bit)
1. ShortInt - the integers between min(ShortInt) and max(ShortInt)
1. Integer - the integers between min(Integer) and max(Integer)
1. LongInt - the integers between min(LongInt) and max(LongInt)
1. Real - the real numbers between min(Real) and max(Real)
1. LongReal - the real numbers between min(LongReal) and max(LongReal)
1. Set - the sets of integers between 0 and max(Set)

They form a hierarchy; the larger type includes (the values of) the smaller type:

  LongReal ⊇ Real ⊇ LongInt ⊇ Integer ⊇ ShortInt ⊇ Byte

Loss of precision requires explicit conversions, provided in the `Unsafe` module.
There is no implicit loss of precision, that would be a compiler refusal.

### Pointers

Pointers are 64-bit values (same as LongInt)

### Character and String

1. Char - Unicode codepoint / rune
1. String - Immutable, heap allocated "list" of Unicode codepoints / runes.
   A Strings module will include methods for formatting strings, working with
   buffers to build strings.

## Gaps

Library versions versus fingerprints. OpenLibrary resolves "by name and version", but the spec never relates a version number to fingerprints. Is a version just a label, with fingerprints doing the actual compatibility check?

Module initialization per domain. Module variables are per domain, so each module's body runs once in each domain that imports it. The spec doesn't say on which thread, in what order, or whether the body is allowed to block.

Library cycles. Oberon already forbids import cycles at compile time, so a cycle can only come from OpenLibrary at runtime. Libraries in a cycle never reach a count of zero, so they stay loaded until reboot. That's a consequence worth stating.

First-run translation. The spec doesn't say whose budget the translation runs on, or whether the module-address key hashes the IR or the native code.

Stack overflow. Fixed stacks need an unmapped guard page each, so an overflow traps with the numbers instead of corrupting memory.

Base system size budget. AGENTS.md requires a size budget that the build enforces. The
spec ships both native code and IR for the base system. Does the IR count against that
budget?
