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

## Modules

Module initialization. Module variables are per domain, so each module's body runs 
once in each domain that imports it. 

Module initialization occurs in the main thread, based on import order. Module 
initialization is allowed to block, where necessary, but intentionally blocking
initialization is discouraged.

### Program entry

A program starts in the body (`begin ... end`) of its root module, the module the
program object names, as a C program starts in `main`. Oberon's commands
(`Module.Procedure` invoked from outside) are not used to launch programs.

- Imported modules initialize first, in import order, then the root module's body
  runs on the main thread.
- Returning from the root body ends the program with a success code. `HALT(n)`
  ends it with `n`.
- An interactive program typically ends its body in `Ports.Run`, turning the main
  thread into its event thread.
- Initialization runs before any `Ports.Run`, while the main thread is not yet an
  event thread, so initializers may block.

### Program arguments

A program declares its arguments as a `ReadArgs` template in the program object's
metadata, beside its spawn budget: `FILE/A,LINE/N,READONLY/S`.

- The shell parses arguments with the same `ReadArgs` parser used by command
  ports, so a bad argument is refused, naming the template, before the program
  starts.
- The program reads its parsed arguments through an `Args` module.
- Because the template describes every argument, a launcher can present it as a
  form to fill in, as IBM i prompts a command's parameters with F4 and
  PowerShell's `Show-Command` does. Command-port templates allow the same for
  application commands.

### Module names

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
- The `System.` prefix is reserved for the base system, for module names and
  published port names alike. Open: how it is enforced.

## Bootstrapping

The language will be bootstrapped with [Vishap Oberon Compiler](https://github.com/vishapoberon/compiler).

The compiler will build in stages:

1. VOC will be used to build the first compiler in plain Oberon-2.
2. Move the compiler to Oberon-5 once it can compile itself.

Neither stage needs an x86-64 native backend. VOC turns Oberon-2 into C, which the
host's C compiler builds. For stage 2, the compiler's own IR goes through an
IR-to-C backend and the host's clang, the same trick VOC uses.

The IR-to-C backend also serves as:

- The hosted backend: Aegir's runtime as a program on the development machine,
  with the address classes, budgets, slot tables and ports in a runtime library.
- Host debugging of the hosted backend: the generated C carries `#line`
  directives pointing at the Oberon-5 source, so host gdb shows Oberon-5 lines.

Its output only ever runs on the host. Native code on the device comes from the
deterministic translator, so the trust rules are unaffected.

Order of work: the IR specification ([ir.md](ir.md)), the front end in Oberon-2
under VOC, the IR-to-C backend and hosted runtime, self-hosting, then the RISC-V
translator and the kernel on QEMU.

## Refusals

Refusals come in a few forms:

- Exhausting a domain terminates a running program with an explicit system return
  code.
- Functions that can fail will return a result code (Oberon standard)
- HALT will terminate a domain with an explicit system return code.
- ASSERT failures will terminate a domain, when running with assertions enabled.
  Assertion enablement is a compiler flag, and are non-op when this flag is disabled.
- Thread limits, worker queue, job and port refusals occur at runtime via a returned 
  error code.

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

Drivers and the base system: translate at build time, ship native only. The base
IR stays in the build and the distribution, where porting happens, and is not
installed on the device. See [Base system](#base-system).

Apps: ship IR, translate at first run, keep native in the [native cache](#native-cache). This does
mean an initial performance hit. That is accepted until a greater "installation" story
exists within Aegir. 

This supports an `OpenLibrary` / `CloseLibrary` like implementation like the Amiga.
Reference-counted load, resolve by name and version, unload when the count hits zero. 
A cycle is possible, and when detected should be loudly indicated, name the offending
libraries, but continue to execute. This should be considered a design flaw in
libraries that cause these cycles. In this case the libraries in the cycle stay
loaded for as long as the domains using them live. Library opens are recorded in
the opening domain's table, including opens made by library code, so when those
domains end, cleanup releases every count they held and the cycle is freed.

A library runs inside the domains that open it and cannot be killed on its own.
Code that needs its own state, threads or lifetime is a service: a domain of its
own, reached through a published port.

### Translation service

First-run translation is done by a translation service, a domain of its own with
its own budget, not by the app's domain.

- On the device, the service is the only domain that writes translated native
  code. The other sources of native code are the build and an app's own C
  objects (see [Apps with C code](#apps-with-c-code)). An app never has write
  access to its own code.
- The service verifies an app's IR before translating it, since the app's
  compiler cannot be trusted. See [Verification](ir.md#verification).
- An app's spawn budget covers running it, never translating it.
- The service runs the same translator the build uses for the base system.
- Spawning a program that needs translation waits on the service. The launcher
  uses the `Send` form and gets a completion message, so its event thread does not
  block.
- The service has a fixed worker pool and job queue. A full queue, or a program
  too large for the service's budget, is a refusal naming the numbers, returned to
  whoever requested the spawn.
- Cached native code is valid while its stored IR hash and translator version
  match. If either differs, the program is translated again.

### Native cache

Translated native code for apps lives in a system-owned cache, never in the
program object. A program object holds IR, its spawn budget, its metadata, and
any C objects the app ships.

- The cache is keyed by IR hash, translator version and architecture. Entries
  are native code before fixups; fixups are applied at load, so the cache key
  needs no import keys (the module-address key does).
- Only the translation service writes to the cache. A program object arriving
  from another machine has nowhere to carry translated code, so provenance needs
  no signing, keys or machine identifier. Copying an app does not copy its native
  code; the copy is translated once on first run.
- Two copies of the same app share one entry, because the key is content-based.
- The cache has a fixed size budget. When a new entry does not fit, the least
  recently used entries are evicted. Entries for loaded images are pinned and
  never evicted. If pinned entries alone fill the cache, the translation is
  refused, naming the cache size, the pinned total and the request, to whoever
  requested the spawn.
- Deleting a program (`delete Foo`) does not touch the cache. Its entries are no
  longer used and age out through eviction. Deletion hooks would miss programs
  deleted from another system or on removable media; ageing out covers every
  case, and an app on removable media keeps its entries until they are evicted.
- The service also removes entries unused for a fixed period (a starting guess:
  30 days), so dangling entries do not sit in a cache that never fills.
- After a translator upgrade, entries for the old translator version can never be
  used again. The service removes them at once.
- The cache is disposable. Clearing it is always safe and costs retranslation.
- The base system's native code is not in this cache. It ships from the build in
  its own system-owned location and is never evicted.

### Base system

The translator is part of the base system, so a new translator only ever arrives in
a base upgrade, which also carries base native code built by that translator. The
device never holds a translator newer than its base native code, and never
translates the base system.

- The build translates the base system for every target architecture. First boot
  and development translate nothing on the device.
- The translator is deterministic: the same IR and translator version always give
  identical native code. Native code from the build is exactly what the
  translation service would produce, so it is trusted for the same reason.
- The base size budget counts the native base system on the device. Base IR is
  not installed, so it does not count.
- Module objects carry a table of procedure names, so refusals, traps and the
  watchdog can name the procedure. The names count against the size budget. Line
  tables and other debug information stay in the build.
- After a base upgrade brings a new translator, cached app native code no longer
  matches. The translation service retranslates apps in the background at low
  priority. An app launched before its turn is translated on demand.

Prior art: Android once compiled every app after each system update, behind a
minutes-long "Optimizing apps" screen, and moved the work to the background
before and after the reboot. Here the base system never needs it, and apps get it
in the background.

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
- The reservation is keyed by the image: module name, IR hash, translator version,
  and the keys of the modules it was fixed up against. When an image's count hits
  zero and it is later reloaded unchanged, it gets the same address back. A
  different image never gets an address any other image has held since boot.
- The IR hash alone is not enough. A new translator turns the same IR into
  different code, and fixups patch in the addresses of the modules imported, so
  the same IR linked against a different version of an import is different code.
  Both versions can be loaded at once, so they need different addresses.
- Because each import's key includes its own imports, a module's key covers
  everything below it. Updating a low-level library gives everything that imports
  it a new image, and a new address, the next time it loads.
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
  native code from the cache is fixed up at load like everything else.
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

#### Region strings

`String` is a reference, so it follows the same rule as pointers: a string stored
in region memory must itself be in a region.

- `String {region}` is the region string kind. Records reachable through a region
  pointer may contain `String {region}` fields, never plain `String`.
- Assigning between `String` and `String {region}` is a compile-time error in
  either direction, as with pointers.
- A heap string is copied into a region explicitly: `Strings.ToRegion(s, r)`
  returns a `String {region}` allocated in `r`. There is no implicit copy.
- Strings are immutable, so sharing a region string is safe: the receiver can
  never see it change, and no locking is needed.
- Strings short enough to fit in an inline message are copied with the message
  and need no region. See [Passing regions](#passing-regions).

```oberon
type
  Msg = record
    name: String {region};
    next: pointer {region} to Msg
  end;
var
  s: String;
  p: pointer {region} to Msg;

p.name := s;                      (* error: heap string in region memory *)
p.name := Strings.ToRegion(s, r); (* ok: copied into r *)
```

#### Borrowed parameters

Procedures that only read a string, most of `Strings`, accept either kind rather
than exist twice. The parameter is flagged `{borrowed}`, after the name as
Active Oberon places variable flags:

```oberon
procedure Length*(s {borrowed}: String): Integer;
procedure Equal*(a {borrowed}, b {borrowed}: String): Boolean;
```

- A flag applies only to the single name it follows. In a grouped declaration
  each name carries its own flag: `a {borrowed}, b {borrowed}: String`. In
  `a, b {borrowed}: String`, only `b` is borrowed.
- A `{borrowed}` `String` parameter accepts `String` and `String {region}`.
- The procedure may read, index, compare and explicitly copy it, and pass it to
  another `{borrowed}` parameter.
- It may never store the reference: not in a variable, not in a record field,
  not as the return value. The procedure cannot know which kind it holds, so any
  store could put a heap string in region memory or the reverse. Storing is a
  compile-time error.
- Oberon already has this rule for open array parameters, which can be read and
  passed on but never assigned.
- The flag is part of the procedure type and its fingerprint, like
  `{blocking}`.
- Strings only for now. Extending `{borrowed}` to pointers, so one procedure can
  read a record through either pointer kind, is possible later and would be a
  language addition.

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
- C heap bytes, for domains that use the [FFI](#foreign-function-interface-ffi).
- Thread slots and stack bytes per thread. See [Concurrency](#concurrency).
- Worker pool size and job queue length.
- Module-variable bytes for everything it may import.
- Live IPC regions; live shared-region mappings.
- Cumulative shared-class creation quota.
- Port slots, and the queue length of each port. A full port queue returns a
  result code to the sender naming the length, for every port, not only command
  ports.
- Handle slots, for ports found by name.

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

### Stack

Stack overflow. Fixed stacks need an unmapped guard page each, so an overflow traps 
with the numbers instead of corrupting memory, resulting in a loud refusal which
terminates the domain.

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
- Each thread has a thread-local storage pointer, set by the kernel. C code
  needs it for per-thread `errno`; see [C library](#c-library).

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
  running procedure. It is paused for a domain a debugger has stopped.

### Work pool

- Each domain has a fixed pool of worker threads and a fixed-length job queue,
  set at spawn. `Tasks.Run(Proc, replyPort)` queues a job. A full queue is a
  refusal naming the length.
- Every job gets a cancel flag that the worker checks. Cancellation is
  cooperative, and present from the start.

### Shared memory between threads

At minimum: an `Atomics` module. A data race isn't memory-safe but is otherwise 
unspecified.

## Libraries

`OpenLibrary` resolves by name and version. A version is manually incremented by the
library author. The version is effectively a label, but fingerprints perform the real
compatibility checks. The version is provided as a convenience to developers to as a
means to express an accepted set of fingerprints.

- The requested version is a minimum, as on the Amiga: requesting version 3 accepts
  version 3 or anything later.
- A version that breaks compatibility gets a new name instead of a higher number,
  as `foo.library` became `foo2.library`: `Foo2` beside `Foo`. Both can be
  installed and loaded at once.
- If an author breaks compatibility without renaming, fingerprints still catch
  it: the load fails loudly, naming the module and the mismatching symbols.
- `OpenLibrary` is `{blocking}`, since loading reads from disk. Following the
  `Send`/`Do` rule it also has a `Send` form, completing with a message.
- A library's initializer runs on the thread that loaded it: the calling thread
  for the `Do` form, a worker from the domain's pool for the `Send` form. An event
  handler cannot call the blocking form, so an initializer never runs on an event
  thread.

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
- Names starting with `System.` are reserved for the base system. See
  [Module names](#module-names).
- A name is unique while its port lives. A second publish of a live name gets
  an instance suffix, as ARexx ports did: `Editor.1`, `Editor.2`.
- Handles are slots, counted in the spawn budget.

### Passing regions

A region pointer only works in a domain that has the region mapped. Sending one
therefore moves the mapping with the message, as Mach's out-of-line memory did.

- A cross-domain send lists the regions the message refers to:
  `Ports.Send(handle, msg, regions)`.
- The kernel checks the message against the list. Type descriptors already record
  where a record's pointers are (the GC uses them), so the kernel finds every
  region pointer in the message and range-compares it against the listed
  regions. A region pointer outside them refuses the send, naming the pointer's
  field.
- On delivery the kernel maps each listed region into the receiver. Each mapping
  is charged to the receiver's live shared-region mappings budget. A receiver
  over budget refuses the message, and the sender gets a result code naming the
  receiver's limit.
- Mappings are read-only by default. The sender grants write access explicitly,
  per region, per send.
- The domain that creates a region holds it read-write. Only it may grant write
  access.
- The receiver unmaps a region when done, or when it dies. A region lives while
  any domain maps it, so the receiver's mapping keeps it alive after the sender
  unmaps.
- Inline messages, those under the fixed inline size, are copied by the kernel.
  They may still carry region pointers, which are checked and mapped the same way.

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
- C in the base system counts against the base system's size budget like
  everything else.
- No `longjmp` across Oberon frames. C libraries that unwind this way (Lua's
  `lua_error`) call Oberon only through a C shim: the Oberon procedure returns a
  result code and the shim raises the C-side error.

### Apps with C code

Apps may ship their own C, not only use C from the base system.

- The app author compiles it with the same pipeline (host clang, `ld -r`, the
  converter) and ships the module objects in the program object, one per
  architecture the app supports.
- Launching on an architecture the app ships no C objects for is refused, naming
  the architecture and the module.
- C objects are native code from outside the translator. They are not verified
  and are loaded as they are. A program object containing them is marked, and a
  launcher can show it, as with modules importing `Unsafe`.
- This does not weaken other domains. Isolation between domains is enforced by
  the kernel: page tables, the region pointer check on every send, the refusal of
  blocking calls on event threads. Unverified code can only damage its own
  domain, and any domain that chooses to load it as a library.
- The interface module's declarations, including `{blocking}`, are trusted. A
  wrong `{blocking}` is caught by the kernel's event-thread backstop.

### C library

C code gets [picolibc](https://keithp.com/picolibc/). musl assumes a POSIX
kernel underneath, newlib is painful to port, and writing our own means
re-solving `printf`, `strtod`, the math library and locales.

- picolibc tests on 64-bit ARM, 64-bit RISC-V and x86_64.
- Its `malloc` takes memory through `sbrk`, and its bundled `sbrk` hands out a
  fixed area between `__heap_start` and `__heap_end` and refuses past it. That
  area is the C heap reserved in the domain's spawn budget, so C memory is
  budgeted with no allocator of our own.
- Its stdio ("tinystdio", from avr-libc) is to be backed by Aegir modules
  through a shim, not by POSIX calls. To be confirmed against its documentation
  before relying on it.
- tinystdio needs atomics, which `Atomics` provides.
- C expects per-thread `errno` through thread-local storage. picolibc supports
  it; the kernel sets a thread-local storage pointer for each thread. See
  [Threads](#threads).

### Compiler and conversion

- C is compiled by the build host's clang. The build does not build or carry its
  own compiler. One clang targets every architecture.
- On-device C compilation is a non-goal (no on-device linking), so a small
  compiler such as TinyCC has no role.
- Pipeline, all at build time: clang compiles each file to a relocatable ELF
  object; the host linker combines a library's objects into one with `ld -r`; the
  converter turns that object's ELF relocations into Aegir fixup lists and emits
  a module object.
- The module class starts at 64 GiB, so code models that assume everything sits
  in the low 2 GiB do not work. Code must address relative to the instruction:
  - RISC-V: `-mcmodel=medany`, and `-mno-relax` so linker relaxation cannot
    change code after the converter reads it.
  - AArch64: the default small model (`ADRP`) already works.
  - x86-64: open, see below.

### Open

- Whether Lua's `io` and `os` libraries are kept over the picolibc shim or
  replaced by Aegir-specific modules.
- x86-64 code model. The default model assumes the low 2 GiB. The choices are
  the large model (bigger, slower code) or position-independent code, which
  reaches other modules through a GOT. The converter could fill that GOT as the
  module's import table, which arguably keeps the spirit of "no PLT/GOT". Deferred
  until a native x86-64 target is wanted; x86-64's range of devices puts it well
  behind RISC-V and AArch64.

## Cleanup

When a domain terminates, cleanup will walk the table and dispose of any resources.
This includes ports, messages still in flight to a dead port, outstanding `Send...`
requests, library reference counts, worker jobs.

Outstanding requests to a dead domain need to complete with an error result code.

## Datatypes

A 64 bit address space is assumed.

1. Boolean - the truth values `true` and `false`

### Numeric

1. Byte - a signed single byte (8 bit)
1. ShortInt - the signed integers between min(ShortInt) and max(ShortInt) (16 bit)
1. Integer - the signed integers between min(Integer) and max(Integer) (32 bit)
1. LongInt - the signed integers between min(LongInt) and max(LongInt) (64 bit)
1. UByte - a unsigned single byte (8 bit)
1. UShortInt - the unsigned integers between min(ShortInt) and max(ShortInt) (16 bit)
1. UInteger - the unsigned integers between min(Integer) and max(Integer) (32 bit)
1. ULongInt - the unsigned integers between min(LongInt) and max(LongInt) (64 bit)
1. Real - the real numbers between min(Real) and max(Real) (32 bit)
1. LongReal - the real numbers between min(LongReal) and max(LongReal) (64 bit)
1. Set - the sets of integers between 0 and max(Set) (64 bit)

They form a hierarchy; the larger type includes (the values of) the smaller type:

  LongReal ⊇ Real
  
  LongInt ⊇ Integer ⊇ ShortInt ⊇ Byte

  ULongInt ⊇ UInteger ⊇ UShortInt ⊇ UByte

Implicit type conversions that lose precision will be refused as an error by the
compiler, and explicit conversions are provided by the `Conversions` module. This
module will include functions that trap on overflow, and explicit truncating
conversion functions will be provided.

### Integer arithmetic

Integer overflow is never undefined and never silent. Prior art: Ada and Swift
trap in every build. Rust panics only in debug builds, so its programs behave
differently once optimized; with debug symbols requiring `O=0`, that would mean a
program behaves differently while being debugged, so it is not followed here.

- Integer arithmetic that overflows traps, in every build and at every
  optimization level. The domain ends with a refusal naming the operation, type,
  operands and procedure:
  `refused: overflow: Integer 2147483647 + 1 in Parser.Count`.
- Integer division by zero traps.
- `MIN(T) div -1` traps, since the result does not fit.
- A shift by a count outside `0` to the type's width minus one traps.
- Explicit forms, in an `Arithmetic` module, for code that wants other behavior.
  The translator compiles them to instructions, with no call cost:
  - Wrapping (two's complement), for hashes, checksums and random number
    generators.
  - Checked with a result, returning a result code instead of trapping.
  - Saturating, clamping at the type's limits, for graphics and audio.
- `Real` and `LongReal` follow IEEE 754: overflow gives infinity, invalid
  operations give NaN, and nothing traps.

### Pointers

Pointers are 64-bit values to match the platform.

### Character and String

1. Char - Unicode codepoint / rune
1. String - an immutable sequence of code points, stored as UTF-8.
   1. A Strings module will include methods for formatting strings, working with
      buffers to build strings.
   1. Stored as UTF-8, always followed by a NUL byte. The header holds the byte
      length, the code-point count and an "all ASCII" flag, computed once when
      the string is created, since strings are immutable.
   1. Strings cannot be indexed: there is no `s[i]`. With UTF-8 storage, reaching
      the i-th code point means scanning from the start, and hiding that cost
      behind `s[i]` would make an ordinary loop quadratic.
   1. Strings are read with a cursor that moves one code point at a time, each
      step O(1):

      ```oberon
      c := Strings.First(s);
      while Strings.Next(s, c, ch) do (* ch is the next Char *) end
      ```

   1. Positions are cursors, not integers. Searching returns a cursor, and
      slicing takes two cursors, so a position can never fall inside a code
      point.
   1. `Strings.Length(s)` is the code-point count and `Strings.Size(s)` the byte
      count, both O(1) from the header.
   1. An algorithm that needs random access copies the string out explicitly,
      into an `array of Char`.
   1. A `{borrowed}` string passes to C as a `char*` with no copy, since it is
      already UTF-8 and NUL-terminated. C must not keep the pointer. A string
      containing U+0000 is refused at the FFI boundary, since C would read it as
      the end of the string.
   1. What users see as one character can be several code points (an accented
      letter, an emoji with modifiers). Grapheme clusters belong in a later
      `Text` module for editing and display, not in `String`.
   1. When the GC is disabled, allocation occurs on the heap. Their lifecycle is 
      managed by the user with the `new` and `dispose` functions.
   1. With the GC enabled, allocations occur on the managed heap. They must still be
      allocated with `new` and the GC can be hinted with `dispose` but their collection
      will happen as part of the standard GC cycles.
   1. String literals are part of the module's constant section. A string literal
      must be copied into a region.

## Source level debugging

When the user enables debug symbols on the compiler command line, the compiler
will include debug symbols with the IR, which will carry forward to the native
code.

Lack of debug symbols doesn't preclude the use of the debugger, but it means
the user will be debugging against native code as opposed to seeing the original
source code.

A debugger needs five things from debug information: a line table (native
address to source line and back, for breakpoints and the current position),
each procedure's variables and where they live, type descriptions (record fields
and offsets, to display values), unwind information (to find the caller's frame,
for backtraces) and source file names. Prior art: Native Oberon's compiler always
emitted a small reference block per object file, with each procedure's variables,
types and frame offsets, enough to show local variable values on a trap.

### Debug builds are unoptimized

- Debug symbols require optimization off: `O=0`. Asking for both, as in
  `o5c Foo.ob5 O=3 DEBUG`, is a loud refusal by the compiler.
- Unoptimized, every variable has a fixed stack slot and every statement is a
  valid breakpoint position. That keeps the debug information close to Oberon's
  reference block instead of the full complexity of DWARF, most of which exists
  for optimized code.
- The compiler emits the IR-to-source mapping. The translator emits the
  native-to-IR mapping. Together they give native address to source line.
- The optimization level and debug flag are recorded in the IR, so the IR hash,
  and with it the native cache key, already tells debug code from release code.

### Frame pointers

All code keeps frame pointers, the base system included. Backtraces then work
everywhere, including trap reports on the device, with no unwind tables on the
device. The cost is one register and a few instructions per call.

### Host debugging first

The compiler exists long before most of Aegir, so the first debugger is gdb or
lldb on the development machine. A debugger on Aegir comes later, over the same
kernel interface.

- The kernel provides a debug interface: stop and resume a domain's threads, read
  and write its memory, set breakpoints.
- The interface speaks GDB's remote serial protocol over the serial console. QEMU
  provides the same protocol for kernel bring-up, and gdb or lldb, and editors
  driving them, work unchanged.
- For host debugging, debug information stays on the development machine, as line
  tables do for the base system. The translator is deterministic, so the host runs it over an app's
  IR, gets exactly the native code the device produced, and generates DWARF from
  it for gdb or lldb.
- Module addresses are assigned at load, so the device reports where each module
  was loaded, as a shared-library list does on other systems.

### Debugging on Aegir

Once the editor, compiler and debugger run on Aegir, debug information has to be
on the device. This is where symbols carry forward from the IR to the native code.

- The IR carries the IR-to-source mapping, variables and types, as emitted by the
  compiler.
- When the translation service translates debug IR, it writes the native-to-IR
  mapping into the native cache entry beside the code. Release IR carries no debug
  information and gets none.
- The debugger on Aegir uses the same kernel debug interface as the host debugger.
- An app's debug information counts against its own size, never the base size
  budget.
- The base system ships without debug information, as before. Debugging the base
  system on the device needs a separate debug information package from the build,
  installed only when wanted and not counted in the base size budget.

### Breakpoints in shared code

Module code is the same physical memory in every domain. A breakpoint written
into it would stop every domain running that module.

- Setting a breakpoint gives the target domain its own copy of that code page, at
  the same address, in its own page table. Only the debugged domain sees the
  breakpoint.
- The copy is charged to the debugger's budget, not the target's.
- The copy is dropped when the breakpoint is removed or the debugger detaches.

### The watchdog

A domain stopped by a debugger is not hung. The event-thread watchdog is paused
for any domain a debugger has stopped.

### Who may debug

Controlling another domain is the most powerful permission in the system.

- A domain can be debugged if it was started under the debugger, or if the user
  approves attaching to it.
- Attaching always asks the user. A program can request an attach, but never
  grant one: the prompt is shown by the base system, and the requester cannot
  answer it, as with Windows' User Account Control.
- Attaching to a `System.` domain asks the user too, and says plainly that it is
  part of the base system.
- Before the GUI exists, there is no prompt. Every attach, including one from a
  debugger on the serial console, proceeds and writes a warning to the serial
  console naming the debugger and the target domain. The prompt arrives with the
  GUI.
- A boot option turns attaching off entirely. With it set, every attach is
  refused, naming the option. Starting a program under the debugger still works:
  launching it from the debugger is the user's approval. This is the safety
  margin while attaching needs no prompt.

### Open

- How the GUI prompt is protected from a program answering it with synthetic
  input.

## Open

- The watchdog limit. 200 ms is a starting guess.
- GC pauses on an event thread look like hangs. Measure pause time early;
  incremental collection may be needed sooner than planned.
- Whether lock-based code is common enough to want Active Oberon's `{exclusive}`
  and `await`. Start with library modules only (`Threads`, `Ports`, `Tasks`).
  Adding them later is a language addition and bumps the IR version.

## Glossary

### Aegir terms

- **Address class**: one of the fixed ranges the address space is divided into
  (null guard, private, module, shared, ipc). Each has its own reuse policy.
  See [Address classes](#address-classes).
- **Blocking procedure**: a procedure flagged `{blocking}`, meaning it may wait.
  The compiler requires its callers to be flagged too. See
  [Blocking is explicit](#blocking-is-explicit).
- **Borrowed parameter**: a parameter flagged `{borrowed}`. It accepts either
  string kind and may be read or passed on, never stored. See
  [Borrowed parameters](#borrowed-parameters).
- **Command port**: a published port that accepts text-style commands with
  `ReadArgs` templates, for scripts and the shell. See
  [Command ports](#command-ports).
- **Domain**: short for protection domain. One running program's isolated set of
  private memory, threads, ports and budget, with its own page table. Close to
  what other systems call a process, except that code and regions appear at the
  same address in every domain that can see them. A domain dies as a unit, and
  cleanup reclaims everything it held.
- **Epoch**: one of the 64 windows of 2 GiB that the ipc class is divided into.
  Its addresses become reusable once every region in it is gone. A **pinned**
  epoch still holds a live region. See [IPC](#ipc).
- **Event thread**: a thread whose loop is run by the runtime with
  `Ports.Run`, dispatching messages to a handler that may not block. See
  [Event threads](#event-threads).
- **FFI**: the foreign function interface, for calling C code. See
  [Foreign function interface (FFI)](#foreign-function-interface-ffi).
- **Fingerprint**: a hash over an exported declaration's signature. The loader
  refuses to load a module whose imports don't match the fingerprints of what it
  loads against. See [Codegen](#codegen).
- **Gauge**: the per-class report of address-space use: in use, high-water, rate
  and projected exhaustion. See
  [Exhaustion and the gauge](#exhaustion-and-the-gauge).
- **Guard**: unmapped address space placed after a reservation or stack, so
  running off the end faults instead of corrupting a neighbour.
- **Handle**: what `Ports.Find` returns. The kernel checks it on every send, and
  a send to a port that is gone returns a result code. See
  [Finding ports by name](#finding-ports-by-name).
- **Heap pointer**: an ordinary `pointer to T`, into the domain's private heap.
  It means nothing in any other domain.
- **Hosted backend**: Aegir's runtime running as a program on another operating
  system, for development. It runs the same allocators and budgets as the real
  system, so exhaustion reproduces there.
- **Image**: one specific build of a module, identified by its module name, IR
  hash, translator version and the images it was fixed up against. Module
  addresses are keyed by image. See [Module](#module).
- **IR**: the serializable, version-stable intermediate representation the
  compiler emits. Apps ship as IR. See [Codegen](#codegen).
- **Job**: a unit of work queued on a domain's worker pool with `Tasks.Run`,
  with a cancel flag. See [Work pool](#work-pool).
- **Library**: a module loaded at runtime with `OpenLibrary`, reference
  counted, and unloaded when the count reaches zero. It runs inside the domains
  that open it and has no domain of its own. See [Libraries](#libraries).
- **Module variables**: a module's global variables. Each domain gets its own
  copy, at the same address in every domain.
- **Port**: a message queue owned by a thread. Threads wait on sets of ports.
  A **published** port can be found by name from other domains. See
  [Ports](#ports).
- **Native cache**: the system-owned store of translated app code, keyed by IR
  hash, translator version and architecture. See [Native cache](#native-cache).
- **Program object**: the file holding a program's IR, its spawn budget, its
  metadata and any C objects it ships. Never translated code.
- **Refusal**: a failure that names the quantity involved. Either a result code
  returned to the caller or, for exhausting a budget, termination of the domain.
  See [Refusals](#refusals).
- **Region**: a block of memory for sharing between domains, at the same address
  in every domain that maps it. It lives in the shared or ipc class, lives while
  any domain maps it, and is never traced by the garbage collector.
- **Region pointer**: `pointer {region} to T`, the only pointer kind allowed to
  point into a region. See [Pointers across domains](#pointers-across-domains).
- **Region string**: `String {region}`, an immutable string allocated in a
  region, so it can be shared between domains. See [Region strings](#region-strings).
- **Result code**: the value a procedure that can fail returns, in Oberon's `res`
  tradition.
- **Service**: code running in a domain of its own, reached through a published
  port. What a library becomes when it needs its own state, threads or
  lifetime.
- **Shim**: a small piece of C code between a C library and Oberon, for example
  turning a result code into a Lua error.
- **Slot**: an entry in a fixed-size kernel table (threads, ports, handles),
  taken from the domain's budget.
- **Spawn budget**: the fixed amounts of memory and slots a domain receives when
  it starts, never grown. See [Spawn budget](#spawn-budget).
- **Translation**: converting IR to native code. At build time for drivers and
  the base system, at first run for apps by the translation service. See
  [Translation service](#translation-service).
- **Translation service**: the trusted domain that translates apps on first run
  and after translator upgrades. On the device it is the only writer of native
  code, into the native cache.
- **Unsafe**: the module holding unchecked operations, Oberon's `SYSTEM` renamed.
  Importing it marks a module as doing unchecked things.
- **Watchdog**: the check that reports an event thread which has not returned to
  waiting on its ports within a time limit.

### Prior art

- **Active Oberon**: an Oberon dialect from ETH Zürich with concurrency built in
  and `{flag}` syntax, the source of `{region}` and `{blocking}`.
- **ARexx**: the Amiga's scripting system. Apps exposed named ports accepting
  command strings, which REXX scripts drove.
- **Exec**: the AmigaOS kernel, with message ports, `FindPort`, `DoIO` and
  `SendIO`.
- **IBM i**: IBM's midrange operating system, descended from the System/38, with
  a single-level store whose addresses are never reused.
- **IPL**: initial program load, IBM's term for a reboot.
- **Native Oberon**: the ETH Oberon operating system, source of the module
  loader, fixups and fingerprints.
- **ReadArgs**: AmigaDOS's argument parser, driven by templates such as
  `FILE/A,LINE/N`.
- **SASOS**: single address space operating system, where every program shares
  one address space.
- **Sv39**: RISC-V's virtual memory mode with 39-bit addresses.
- **TIMI**: IBM i's Technology Independent Machine Interface. Programs ship in a
  machine-independent form and are translated to native code on the machine.
- **Tool Types**: settings stored in an Amiga program's icon, such as its stack
  size.
- **VOC**: the Vishap Oberon Compiler, used to bootstrap.
