# Oberon-5 IR

The IR is what the compiler emits and every translator consumes. It is the
contract between the compiler, the translators (RISC-V, AArch64, C), the
hosted backend, debug information and the native cache. It is serializable,
version-stable and documented here.

Status: outline. Items marked **Proposed** need a decision; **Open** items have
no proposal yet.

## Consumers

The IR has to serve all of these, so each one is a requirement:

- **Translators**: RISC-V and AArch64 native, and C for the host. Translation
  must be deterministic: the same IR and translator version give identical
  output.
- **The translation service on the device**: apps arrive as IR from anywhere, so
  the IR must be verifiable. See [Verification](#verification).
- **The loader**: import lists, export fingerprints, and the material for
  fixups.
- **The native cache and the module-address key**: both use a hash of the IR.
- **Debuggers**: the IR-to-source mapping, variables and types.
- **Future versions**: an IR version only changes by explicit action.

## Verification

The compiler's checks (region kinds, `{blocking}`, `{borrowed}`, type safety)
are only guarantees if the translation service re-checks them. An app's IR comes
from the app author's compiler, which the device cannot trust: hand-made IR could
store a heap pointer in a region record or call a blocking procedure from an
event handler.

- The translation service verifies every IR module before translating it. IR
  that fails is refused, naming the module, the procedure and the rule.
- The IR therefore keeps every type and flag the checks need. Nothing the checks
  depend on may be erased by the compiler.
- Verification is deterministic and linear in the size of the IR.
- Apps may import `Unsafe`, as Rust code may use `unsafe`. The verifier checks
  everything except the `Unsafe` operations themselves, and the module is marked
  in its header so a launcher can show it.
- Two layers of protection, with different jobs. Verification protects a domain
  from its own compiler's mistakes and from forged IR. The kernel protects every
  other domain: page tables, the region pointer check on every send, and the
  refusal of blocking calls on event threads. `Unsafe` and C weaken the first
  layer for the module using them, never the second.

Prior art: the Java class file verifier, and WebAssembly validation, which
structured control flow makes a single linear pass.

## Shape of the IR

A typed tree, close to the source structure, rather than a low-level register
or SSA form, or a stack machine.

- Oberon has only structured control flow (no `goto`), so a tree loses nothing.
- Verification is type checking over the tree, the same rules the compiler
  applies, so the trusted checker is a known quantity.
- Debug mapping is simple: each node carries a source position.
- Translators can be simple tree-walking code generators, as Oberon compilers
  traditionally are, which suits determinism.
- High-level structure is kept, so translators can still generate good code.

Prior art: Michael Franz's slim binaries (ETH, 1994 onwards). Oberon modules
shipped as compressed abstract syntax trees and were translated to native code
at load time, fast enough for interactive use. Juice, the Oberon plugin for
Netscape, was built on them. IBM i's MI is also high level.

## Module file

A module is one binary file of sections. Each section has a tag and a length, so
a reader can skip a section it does not need.

1. **Header**: magic, IR version, module name (dotted, full), flags (debug,
   optimization level, imports `Unsafe`), architecture-independent.
2. **Imports**: each imported module's name, and for every imported symbol, its
   fingerprint.
3. **Types**: records, arrays, pointers (with `{region}`), procedure types (with
   `{blocking}` and `{borrowed}` per parameter), and type-bound procedures.
4. **Constants**: values, including string literals as UTF-8.
5. **Module variables**: names and types. Their addresses are assigned at load.
6. **Procedures**: signature, flags, locals, and body tree.
7. **Module body**: the initializer, a tree like a procedure body.
8. **Exports**: each exported symbol with its fingerprint.
9. **Debug** (only in debug IR): node-to-source positions, source file names and
   hashes, local variable names.

Encoding: integers as LEB128 variable-length numbers, as in WebAssembly; names
and strings as UTF-8 with a length prefix.

## Data layout

Record layout is defined here, not left to each translator.

- Region records are read by different images in different domains. Their layout
  has to be identical in every image, and fixing it in the IR makes it part of
  the type and the fingerprint.
- Fields in declaration order, each at its natural alignment; record size rounded
  up to its largest alignment.
- Sizes as in [Datatypes](oberon.md#datatypes): `Byte` 1, `ShortInt` 2, `Integer`
  4, `LongInt` 8, `Real` 4, `LongReal` 8, `Set` 8, pointers 8.
- Little-endian. All three targets are little-endian.
- A fixed layout also lets a record describe a hardware register block or an
  on-disk structure.

### Packed records

**Proposed**: `record {packed}` removes all padding. Fields sit back to back in
declaration order, and the record's alignment is 1.

- For file formats and network headers, where a format puts a 4-byte field at an
  odd offset.
- Misaligned fields are accessed with code that is safe for unaligned
  addresses, on every architecture. This costs speed, which is why packing is
  opt-in.
- A packed field that is not naturally aligned cannot be passed as a `var`
  parameter: the callee would assume alignment. Copy it to a local first. Rust
  has the same rule for references to packed fields.
- `{packed}` is part of the type, the layout and the fingerprint.

### Volatile access

**Proposed**: a `{volatile}` flag on a variable, field or pointer target, for
memory-mapped hardware registers.

- Packing is rarely what hardware needs. Register blocks are usually naturally
  aligned, so the normal layout fits. What hardware needs is that every access
  happens exactly as written.
- Every read and write of a `{volatile}` location is performed, at exactly the
  field's width, in program order. None is merged, removed, split or reordered.
- A `{volatile}` field must be naturally aligned, so packed records cannot
  contain one. Hardware registers cannot be accessed unaligned.
- Pointers to device memory come from `Unsafe`, so drivers import it.

## Operations

**Open**: the full node set. It covers at least:

- Expressions: arithmetic, comparison, set operations, conversions (always
  explicit nodes; see [Core node set](#core-node-set)), designators (field, element, dereference), type tests
  and guards, procedure calls.
- Statements: assignment, `if`, `case`, `while`, `repeat`, `for`, `loop`/`exit`,
  `return`, `with`.
- Allocation: `new` on the heap, `new(p, r)` in a region, `dispose`.
- Intrinsics: `Unsafe` operations and `Atomics`, as named operations, not calls.
- Foreign procedures: calls through the FFI, marked so the translator uses the C
  calling convention.

Runtime checks are part of the semantics, so every translator traps the same
way: array bounds, `nil` dereference, type guards, `Unsafe.Region` range
checks, checked conversions, and integer arithmetic (see
[Integer arithmetic](oberon.md#integer-arithmetic)).

- Ordinary integer arithmetic nodes are checked. Wrapping, checked-with-result
  and saturating arithmetic are separate nodes, so the verifier and every
  translator agree on which is which.
- An optimizing translator may remove a check only where it proves the
  operation cannot overflow. Behavior is identical at every optimization level.
- The IR-to-C backend never emits C with signed overflow, which C leaves
  undefined. Checks use clang's `__builtin_add_overflow` family; wrapping
  arithmetic is done in unsigned C types, where C defines it.
- On RISC-V, which has no overflow flag, a checked add costs about two or three
  extra instructions and a checked multiply needs the high half of the product.
  Hot loops can use the wrapping forms where overflow is known to be harmless.

Calling conventions are not in the IR. Each translator defines its own for
Oberon-5 code, and uses the platform C convention for foreign procedures.

## Core node set

The first slice of the IR, the smallest set that runs end to end:
integer constants and arithmetic, local variables, `if`, `while`, procedure
calls and `return`. Enough for the first `check-ir-golden` test and the first
`check-run` program. Everything else is added to it.

### Principles

- **Every operation names its type.** `(add Integer a b)`, not `(add a b)`. The
  verifier checks the operands against the named type; translators never infer
  types. WebAssembly's `i32.add` works the same way.
- **No implicit conversions in the IR.** Where the source widens implicitly
  (`LongInt` from `Integer`), the compiler emits an explicit conversion node.
  The verifier then never needs the conversion rules of the source language.
- **Names in the text form, numbers in the binary form.** Locals, procedures and
  types are written by name in text and encoded as indexes in binary.

### Text syntax

S-expressions: one parenthesized list per node, the node's name first. A tree IR
maps onto them directly, and the parser is a few hundred lines. WebAssembly's
text format is the same idea.

```
(module Demo.Sum
  (proc Sum export
    (param n Integer)
    (result Integer)
    (local i Integer)
    (local s Integer)
    (body
      (set s (const Integer 0))
      (set i (const Integer 1))
      (while (le Integer (get i) (get n))
        (set s (add Integer (get s) (get i)))
        (set i (add Integer (get i) (const Integer 1))))
      (return (get s))))
  (init
    (halt (call Sum (const Integer 10)))))
```

In debug IR, any node may carry a source position after its name:
`(add @12:9 Integer (get s) (get i))`.

### Types

`Boolean`, `Byte`, `ShortInt`, `Integer`, `LongInt`. Reals, sets, characters,
strings, arrays, records and pointers come in later slices.

### Expressions

| Node | Meaning |
|---|---|
| `(const T v)` | Constant `v` of type `T`. `v` must fit `T`. |
| `(get x)` | Value of local or parameter `x`. |
| `(add T a b)`, `(sub T a b)`, `(mul T a b)` | Checked arithmetic; overflow traps. |
| `(div T a b)`, `(mod T a b)` | Oberon division: quotient rounded toward minus infinity, modulus with the sign of the divisor, so `a = (a div b) * b + a mod b`. Division by zero and `MIN(T) div -1` trap. |
| `(neg T a)` | Checked negation; `-MIN(T)` traps. |
| `(eq T a b)` `(ne ...)` `(lt ...)` `(le ...)` `(gt ...)` `(ge ...)` | Comparison, giving `Boolean`. |
| `(and a b)`, `(or a b)` | Boolean, short-circuit, as Oberon's `&` and `or`. |
| `(not a)` | Boolean negation. |
| `(convert T U a)` | Convert `a` from `T` to `U`. In this slice only widening (`Byte` to `ShortInt` and so on up); narrowing arrives with the `Conversions` forms. |
| `(call P args...)` | Call procedure `P` that has a result. |

Oberon's `div` and `mod` are not C's `/` and `%`, which round toward zero. The
IR-to-C backend must not translate them directly.

### Statements

| Node | Meaning |
|---|---|
| `(set x e)` | Assign `e` to local `x`. |
| `(if c (then s...) (else s...))` | `else` optional. `elsif` is nested `if` in the `else`. |
| `(while c s...)` | Loop while `c` is true. |
| `(call P args...)` | Call procedure `P` that has no result. |
| `(return e)`, `(return)` | Return, with a value exactly when the procedure has a result. |
| `(halt e)` | End the program with code `e` (`Integer`), as `HALT(n)`. |

`halt` is in the first slice so `check-run` programs can report a result through
their exit code before any I/O exists.

### Procedures and modules

- `(proc Name flags... (param x T)... (result T)? (local x T)... (body s...))`.
  Flags in this slice: `export`, `blocking`.
- Parameters are passed by value in this slice. `var` parameters come later.
- `(init s...)`: the module body, run at initialization. In a root module it is
  the program's entry.

### Verifier rules for this slice

Each rule gets at least one `check-verifier` file that breaks it. A refusal
names the module, the procedure (or `init`), the source position when the IR
carries one, and the rule:
`Demo.Sum.Sum at 12:9: rule 2: operand of add is LongInt, expected Integer`.

1. Every name refers to a declared local, parameter or procedure. The reader
   enforces this, since IR records cannot be built from a name that does not
   resolve.
2. Every operand's type equals the type its node names. Arithmetic and the
   ordering comparisons (`lt`, `le`, `gt`, `ge`) name an integer type; `eq` and
   `ne` may also name `Boolean`. `halt`'s operand is `Integer`.
3. `set` assigns a value of the variable's declared type.
4. Conditions of `if` and `while`, and operands of `and`, `or` and `not`, are
   `Boolean`.
5. A call has the callee's number and types of arguments. A call used as an
   expression names a procedure with a result; a call used as a statement names
   one without.
6. `return` carries a value of the result type in a procedure with a result, and
   no value otherwise. `return` does not appear in `init`, which is not a
   procedure.
7. A procedure with a result cannot reach the end of its body: its last
   statement is a `return` or a `halt`, or an `if` with an `else` where both
   branches end that way. A `while` never counts, even with a constant `true`
   condition.
8. A constant fits its type.
9. A procedure not flagged `blocking` does not call one that is. `init` may,
   since initialization may block.
10. `convert` only widens, in this slice.
11. No statement follows one that cannot complete: nothing after a `return` or a
    `halt` in the same list, or after an `if` with an `else` whose branches both
    end that way. Reachability is structural, as in rule 7: a `while` never
    counts as ending, and conditions are never evaluated. The compiler refuses
    unreachable code, so IR that contains any is a compiler bug or forged.

### Binary encoding

- Each node is an opcode byte followed by its operands, written in prefix order
  (a node before its children).
- Type references are small codes for built-in types, indexes into the type
  section for the rest.
- Locals and procedures are LEB128 indexes. Parameters are the first locals.
- Statement lists and argument lists are prefixed by their count.
- Constants are signed LEB128.
- Exact opcode numbers are fixed when the slice is agreed, and never reused
  after.

### First tests

- `check-ir-golden`: the Oberon-5 source of the `Demo.Sum` example compiles to
  exactly the text above.
- `check-run`: `Demo.Sum` exits with code 55.
- `check-run`: summing to a value that overflows `Integer` traps with the
  overflow refusal.
- `check-verifier`: one file per rule above.
- `check-ir-roundtrip`: every file above, text to binary to text.

## Hashing and fingerprints

- **Fingerprint**: a hash over the canonical encoding of an exported
  declaration's signature: its name, kind, type (structurally, including flags
  and layout) and, for constants, value.
- **IR hash**: a hash over the whole module file, used by the native cache and
  the module-address key.
- **Open**: the hash function. It should be a cryptographic hash, so a collision
  cannot be built to slip different code past the cache.

## Versioning

- The header carries the IR version. It changes only for a language addition or
  deprecation, as Java class file versions do.
- A translator accepts every IR version up to its own. Newer IR is refused,
  naming both versions.
- Adding an optional section does not change the version; readers skip sections
  they do not know.

## Text form

A readable text form of the IR, convertible to and from the binary form without
loss, after WebAssembly's text format. It is used for compiler tests (expected
IR), for reading what the compiler produced, and for writing IR by hand to test
the verifier's refusals.

## Testing

Tests are written as the IR is, not after. Each kind is a `check-*` target, and
every `check-*` is a prerequisite of the build.

- `check-ir-roundtrip`: every test file converts text to binary to text, and
  binary to text to binary, unchanged.
- `check-ir-golden`: Oberon-5 source compiled to text IR and compared with a
  stored expected file. A change in output fails until the expected file is
  updated on purpose.
- `check-verifier`: hand-written invalid IR, each with the refusal it must
  produce (module, procedure and rule). One file per rule, so every rule the
  verifier enforces has a test that breaks it.
- `check-fingerprints`: stored expected fingerprints and IR hashes for a fixed
  set of declarations and modules. Changing the canonical encoding or the hash by
  accident fails here.
- `check-determinism`: each test module translated twice, and on different
  hosts, must give byte-identical output.
- `check-ir-compat`: IR files from every released IR version, kept forever. Each
  must still verify and translate, as old Java class files still load.
- `check-run`: programs run through the IR-to-C backend on the hosted backend,
  with expected output and expected traps.
- Fuzzing: forged IR is the threat model, so the reader and verifier are fuzzed.
  Any input must give either a valid module or a refusal, never a crash or a
  hang.

## Open

- The full set of nodes and their encodings.
- The hash function.
- Whether IR is compressed. Franz's semantic dictionary encoding made slim
  binaries smaller than native code.
