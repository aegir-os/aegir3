MODULE IrText; (* The IR text form: S-expressions to IR records and back. *)

(* Read checks the shape of every node: its name, its number and kinds of
   operands, and that every name it uses is declared. It does not check types;
   that is the verifier's job. See specs/ir.md, "Core node set". *)

IMPORT Sexpr, Ir, IrLayout;

CONST
  MaxError = 128;

TYPE
  (* A procedure whose body is read in pass 2. *)
  Pending = POINTER TO PendingDesc;
  PendingDesc = RECORD
    proc: Ir.Proc;
    body: Sexpr.Node;  (* the (body ...) list *)
    next: Pending
  END;

VAR
  (* Set by Read when it fails; empty otherwise. *)
  error*: ARRAY MaxError OF CHAR;
  errLine*, errCol*: INTEGER;

  module: Ir.Module;

(* ---- Reading ---- *)

PROCEDURE Fail(x: Sexpr.Node; msg: ARRAY OF CHAR);
BEGIN
  IF error[0] = 0X THEN
    COPY(msg, error); errLine := x.line; errCol := x.col
  END
END Fail;

(* Fail with msg followed by a name, as in "unknown local x". *)
PROCEDURE FailName(x: Sexpr.Node; msg, name: ARRAY OF CHAR);
  VAR s: ARRAY MaxError OF CHAR; i, j: INTEGER;
BEGIN
  COPY(msg, s); i := 0;
  WHILE s[i] # 0X DO INC(i) END;
  s[i] := " "; INC(i); j := 0;
  WHILE (i < MaxError - 1) & (j < LEN(name)) & (name[j] # 0X) DO
    s[i] := name[j]; INC(i); INC(j)
  END;
  s[i] := 0X;
  Fail(x, s)
END FailName;

PROCEDURE Failed(): BOOLEAN;
BEGIN
  RETURN error[0] # 0X
END Failed;

PROCEDURE IsSymbol(x: Sexpr.Node; s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (x # NIL) & (x.kind = Sexpr.Symbol) & (x.name^ = s)
END IsSymbol;

(* The head symbol of list x, or "" if x is not a list headed by a symbol. *)
PROCEDURE Head(x: Sexpr.Node; VAR s: ARRAY OF CHAR);
BEGIN
  IF (x.kind = Sexpr.List) & (x.first # NIL) & (x.first.kind = Sexpr.Symbol) THEN
    COPY(x.first.name^, s)
  ELSE s[0] := 0X
  END
END Head;

PROCEDURE Count(e: Sexpr.Node): INTEGER;
  VAR n: INTEGER;
BEGIN
  n := 0;
  WHILE e # NIL DO INC(n); e := e.next END;
  RETURN n
END Count;

(* The operands of list x: the elements after its head and the optional source
   position, which is stored in n. *)
PROCEDURE Operands(x: Sexpr.Node; n: Ir.Node): Sexpr.Node;
  VAR e: Sexpr.Node;
BEGIN
  e := x.first.next;
  IF (e # NIL) & (e.kind = Sexpr.Position) THEN
    n.pline := e.pline; n.pcol := e.pcol; e := e.next
  END;
  RETURN e
END Operands;

PROCEDURE OpOf(s: ARRAY OF CHAR): INTEGER;
  VAR op: INTEGER;
BEGIN
  op := 1;
  WHILE (op <= Ir.MaxOp) & (Ir.opName[op] # s) DO INC(op) END;
  IF op > Ir.MaxOp THEN RETURN 0 END;
  RETURN op
END OpOf;

(* A type name; NoType after failing. *)
PROCEDURE ReadType(x: Sexpr.Node): INTEGER;
  VAR t: INTEGER;
BEGIN
  IF (x = NIL) OR (x.kind # Sexpr.Symbol) THEN
    Fail(x, "expected a type"); RETURN Ir.NoType
  END;
  t := Ir.Boolean;
  WHILE (t <= Ir.MaxType) & (Ir.typeName[t] # x.name^) DO INC(t) END;
  IF t > Ir.MaxType THEN FailName(x, "unknown type", x.name^); RETURN Ir.NoType END;
  RETURN t
END ReadType;

PROCEDURE ReadLocal(x: Sexpr.Node; p: Ir.Proc): Ir.Local;
  VAR l: Ir.Local;
BEGIN
  IF (x = NIL) OR (x.kind # Sexpr.Symbol) THEN Fail(x, "expected a name"); RETURN NIL END;
  l := Ir.FindLocal(p, x.name^);
  IF l = NIL THEN FailName(x, "unknown local", x.name^) END;
  RETURN l
END ReadLocal;

PROCEDURE ReadProcName(x: Sexpr.Node): Ir.Proc;
  VAR p: Ir.Proc;
BEGIN
  IF (x = NIL) OR (x.kind # Sexpr.Symbol) THEN Fail(x, "expected a name"); RETURN NIL END;
  p := Ir.FindProc(module, x.name^);
  IF p = NIL THEN FailName(x, "unknown procedure", x.name^) END;
  RETURN p
END ReadProcName;

PROCEDURE^ ReadExpr(x: Sexpr.Node; p: Ir.Proc): Ir.Node;

(* Expressions from e onwards, linked by next. *)
PROCEDURE ReadArgs(e: Sexpr.Node; p: Ir.Proc): Ir.Node;
  VAR first, last, a: Ir.Node;
BEGIN
  first := NIL; last := NIL;
  WHILE (e # NIL) & ~Failed() DO
    a := ReadExpr(e, p);
    IF a # NIL THEN
      IF last = NIL THEN first := a ELSE last.next := a END;
      last := a
    END;
    e := e.next
  END;
  RETURN first
END ReadArgs;

(* Check that list x has exactly n operands from e. *)
PROCEDURE Arity(x, e: Sexpr.Node; n: INTEGER): BOOLEAN;
BEGIN
  IF Count(e) # n THEN
    FailName(x, "wrong number of operands for", x.first.name^); RETURN FALSE
  END;
  RETURN TRUE
END Arity;

PROCEDURE ReadExpr(x: Sexpr.Node; p: Ir.Proc): Ir.Node;
  VAR name: ARRAY 32 OF CHAR; op: INTEGER; n: Ir.Node; e: Sexpr.Node;
BEGIN
  Head(x, name);
  IF name = "" THEN Fail(x, "expected an expression"); RETURN NIL END;
  op := OpOf(name);
  IF (op = 0) OR (op > Ir.Call) THEN FailName(x, "not an expression:", name); RETURN NIL END;
  n := Ir.NewNode(op);
  e := Operands(x, n);
  IF op = Ir.Const THEN
    IF Arity(x, e, 2) THEN
      n.type := ReadType(e);
      IF n.type = Ir.Boolean THEN
        IF IsSymbol(e.next, "true") THEN n.val := 1
        ELSIF IsSymbol(e.next, "false") THEN n.val := 0
        ELSE Fail(e.next, "expected true or false")
        END
      ELSIF e.next.kind = Sexpr.Integer THEN n.val := e.next.int
      ELSIF ~Failed() THEN Fail(e.next, "expected an integer")
      END
    END
  ELSIF op = Ir.Get THEN
    IF Arity(x, e, 1) THEN n.local := ReadLocal(e, p) END
  ELSIF (op >= Ir.FirstBinary) & (op <= Ir.LastBinary) & (op # Ir.Neg) THEN
    IF Arity(x, e, 3) THEN
      n.type := ReadType(e);
      n.a := ReadExpr(e.next, p);
      IF ~Failed() THEN n.b := ReadExpr(e.next.next, p) END
    END
  ELSIF op = Ir.Neg THEN
    IF Arity(x, e, 2) THEN n.type := ReadType(e); n.a := ReadExpr(e.next, p) END
  ELSIF (op = Ir.And) OR (op = Ir.Or) THEN
    IF Arity(x, e, 2) THEN
      n.a := ReadExpr(e, p);
      IF ~Failed() THEN n.b := ReadExpr(e.next, p) END
    END
  ELSIF op = Ir.Not THEN
    IF Arity(x, e, 1) THEN n.a := ReadExpr(e, p) END
  ELSIF op = Ir.Convert THEN
    IF Arity(x, e, 3) THEN
      n.type := ReadType(e);
      IF ~Failed() THEN n.to := ReadType(e.next) END;
      IF ~Failed() THEN n.a := ReadExpr(e.next.next, p) END
    END
  ELSIF op = Ir.Call THEN
    IF e = NIL THEN Fail(x, "call needs a procedure")
    ELSE n.proc := ReadProcName(e); n.args := ReadArgs(e.next, p)
    END
  END;
  IF Failed() THEN RETURN NIL END;
  RETURN n
END ReadExpr;

PROCEDURE^ ReadStats(e: Sexpr.Node; p: Ir.Proc): Ir.Node;

(* A (then ...) or (else ...) branch of if. *)
PROCEDURE ReadBranch(x: Sexpr.Node; name: ARRAY OF CHAR; p: Ir.Proc): Ir.Node;
  VAR h: ARRAY 8 OF CHAR;
BEGIN
  Head(x, h);
  IF h # name THEN FailName(x, "expected", name); RETURN NIL END;
  RETURN ReadStats(x.first.next, p)
END ReadBranch;

PROCEDURE ReadStat(x: Sexpr.Node; p: Ir.Proc): Ir.Node;
  VAR name: ARRAY 32 OF CHAR; op, k: INTEGER; n: Ir.Node; e: Sexpr.Node;
BEGIN
  Head(x, name);
  IF name = "" THEN Fail(x, "expected a statement"); RETURN NIL END;
  op := OpOf(name);
  IF (op # Ir.Call) & (op < Ir.Set) THEN FailName(x, "not a statement:", name); RETURN NIL END;
  n := Ir.NewNode(op);
  e := Operands(x, n);
  CASE op OF
  | Ir.Call:
    IF e = NIL THEN Fail(x, "call needs a procedure")
    ELSE n.proc := ReadProcName(e); n.args := ReadArgs(e.next, p)
    END
  | Ir.Set:
    IF Arity(x, e, 2) THEN
      n.local := ReadLocal(e, p);
      IF ~Failed() THEN n.a := ReadExpr(e.next, p) END
    END
  | Ir.If:
    k := Count(e);
    IF (k < 2) OR (k > 3) THEN Fail(x, "if needs a condition, then and an optional else")
    ELSE
      n.a := ReadExpr(e, p);
      IF ~Failed() THEN n.then := ReadBranch(e.next, "then", p) END;
      IF (k = 3) & ~Failed() THEN
        n.hasElse := TRUE; n.else := ReadBranch(e.next.next, "else", p)
      END
    END
  | Ir.While:
    IF e = NIL THEN Fail(x, "while needs a condition")
    ELSE
      n.a := ReadExpr(e, p);
      IF ~Failed() THEN n.then := ReadStats(e.next, p) END
    END
  | Ir.Return:
    k := Count(e);
    IF k > 1 THEN Fail(x, "return takes at most one value")
    ELSIF k = 1 THEN n.a := ReadExpr(e, p)
    END
  | Ir.Halt:
    IF Arity(x, e, 1) THEN n.a := ReadExpr(e, p) END
  ELSE HALT(20) (* only statement ops reach here *)
  END;
  IF Failed() THEN RETURN NIL END;
  RETURN n
END ReadStat;

(* Statements from e onwards, linked by next. *)
PROCEDURE ReadStats(e: Sexpr.Node; p: Ir.Proc): Ir.Node;
  VAR first, last, s: Ir.Node;
BEGIN
  first := NIL; last := NIL;
  WHILE (e # NIL) & ~Failed() DO
    s := ReadStat(e, p);
    IF s # NIL THEN
      IF last = NIL THEN first := s ELSE last.next := s END;
      last := s
    END;
    e := e.next
  END;
  RETURN first
END ReadStats;

(* Add a parameter or local declared by (param x T) or (local x T). *)
PROCEDURE ReadDecl(x: Sexpr.Node; p: Ir.Proc; param: BOOLEAN);
  VAR e: Sexpr.Node; l, last: Ir.Local; n: Ir.Node;
BEGIN
  n := Ir.NewNode(0); (* only holds a position, which declarations ignore *)
  e := Operands(x, n);
  IF ~Arity(x, e, 2) THEN RETURN END;
  IF e.kind # Sexpr.Symbol THEN Fail(e, "expected a name"); RETURN END;
  IF Ir.FindLocal(p, e.name^) # NIL THEN FailName(e, "duplicate local", e.name^); RETURN END;
  NEW(l); l.name := e.name; l.param := param;
  l.type := ReadType(e.next);
  IF Failed() THEN RETURN END;
  IF p.locals = NIL THEN p.locals := l; l.index := 0
  ELSE
    last := p.locals;
    WHILE last.next # NIL DO last := last.next END;
    last.next := l; l.index := last.index + 1
  END;
  IF param THEN INC(p.nparams) END
END ReadDecl;

(* Pass 1: a procedure's name, flags and declarations, so that calls can refer
   to procedures declared later. Returns the (body ...) list, or NIL. *)
PROCEDURE ReadProcHeader(x: Sexpr.Node; p: Ir.Proc): Sexpr.Node;
  CONST Params = 0; Result = 1; Locals = 2; Body = 3;
  VAR e: Sexpr.Node; h: ARRAY 8 OF CHAR; stage: INTEGER;
BEGIN
  e := x.first.next;
  IF (e = NIL) OR (e.kind # Sexpr.Symbol) THEN Fail(x, "proc needs a name"); RETURN NIL END;
  p.name := e.name; e := e.next;
  WHILE (e # NIL) & (e.kind = Sexpr.Symbol) DO
    IF IsSymbol(e, "export") THEN p.export := TRUE
    ELSIF IsSymbol(e, "blocking") THEN p.blocking := TRUE
    ELSE FailName(e, "unknown flag", e.name^); RETURN NIL
    END;
    e := e.next
  END;
  stage := Params;
  LOOP
    IF e = NIL THEN Fail(x, "proc needs a body"); RETURN NIL END;
    Head(e, h);
    IF (h = "param") & (stage = Params) THEN ReadDecl(e, p, TRUE)
    ELSIF (h = "result") & (stage = Params) THEN
      IF Arity(e, e.first.next, 1) THEN p.result := ReadType(e.first.next) END;
      stage := Result
    ELSIF (h = "local") & (stage <= Locals) THEN ReadDecl(e, p, FALSE); stage := Locals
    ELSIF h = "body" THEN
      IF e.next # NIL THEN Fail(e.next, "nothing may follow the body"); RETURN NIL END;
      RETURN e
    ELSE Fail(e, "expected param, result, local or body, in that order"); RETURN NIL
    END;
    IF Failed() THEN RETURN NIL END;
    e := e.next
  END
END ReadProcHeader;

(* Read the IR module in x. On failure, returns NIL and sets error, errLine and
   errCol. *)
PROCEDURE Read*(x: Sexpr.Node): Ir.Module;
  VAR e, body, init: Sexpr.Node; h: ARRAY 8 OF CHAR; p, last: Ir.Proc;
      pending, lastPending, q: Pending;
BEGIN
  error[0] := 0X; errLine := 0; errCol := 0;
  Head(x, h);
  IF h # "module" THEN Fail(x, "expected (module ...)"); RETURN NIL END;
  e := x.first.next;
  IF (e = NIL) OR (e.kind # Sexpr.Symbol) THEN Fail(x, "module needs a name"); RETURN NIL END;
  NEW(module); module.name := e.name; e := e.next;

  (* Pass 1: procedure headers, so that calls can name procedures declared
     later. Bodies are kept for pass 2. *)
  last := NIL; pending := NIL; lastPending := NIL; init := NIL;
  WHILE (e # NIL) & ~Failed() DO
    Head(e, h);
    IF h = "proc" THEN
      NEW(p);
      body := ReadProcHeader(e, p);
      IF body # NIL THEN
        IF Ir.FindProc(module, p.name^) # NIL THEN
          FailName(e.first.next, "duplicate procedure", p.name^)
        ELSE
          IF last = NIL THEN module.procs := p ELSE last.next := p END;
          last := p;
          NEW(q); q.proc := p; q.body := body;
          IF lastPending = NIL THEN pending := q ELSE lastPending.next := q END;
          lastPending := q
        END
      END
    ELSIF h = "init" THEN
      IF e.next # NIL THEN Fail(e.next, "nothing may follow init") END;
      init := e
    ELSE Fail(e, "expected proc or init")
    END;
    e := e.next
  END;

  (* Pass 2: procedure bodies and init. *)
  q := pending;
  WHILE (q # NIL) & ~Failed() DO
    q.proc.body := ReadStats(q.body.first.next, q.proc); q := q.next
  END;
  IF (init # NIL) & ~Failed() THEN
    module.hasInit := TRUE; module.init := ReadStats(init.first.next, NIL)
  END;
  IF Failed() THEN RETURN NIL END;
  RETURN module
END Read;

(* ---- Writing ---- *)

PROCEDURE List(head: ARRAY OF CHAR): Sexpr.Node;
  VAR x: Sexpr.Node;
BEGIN
  x := Sexpr.NewList(); Sexpr.Append(x, Sexpr.NewSymbol(head)); RETURN x
END List;

(* The list for node n, with its source position if it has one. *)
PROCEDURE NodeList(n: Ir.Node): Sexpr.Node;
  VAR x: Sexpr.Node;
BEGIN
  x := List(Ir.opName[n.op]);
  IF n.pline > 0 THEN Sexpr.Append(x, Sexpr.NewPosition(n.pline, n.pcol)) END;
  RETURN x
END NodeList;

PROCEDURE Type(t: INTEGER): Sexpr.Node;
BEGIN
  RETURN Sexpr.NewSymbol(Ir.typeName[t])
END Type;

PROCEDURE^ WriteExpr(n: Ir.Node): Sexpr.Node;

PROCEDURE AppendArgs(x: Sexpr.Node; a: Ir.Node);
BEGIN
  WHILE a # NIL DO Sexpr.Append(x, WriteExpr(a)); a := a.next END
END AppendArgs;

PROCEDURE WriteExpr(n: Ir.Node): Sexpr.Node;
  VAR x: Sexpr.Node;
BEGIN
  x := NodeList(n);
  CASE n.op OF
  | Ir.Const:
    Sexpr.Append(x, Type(n.type));
    IF n.type = Ir.Boolean THEN
      IF n.val # 0 THEN Sexpr.Append(x, Sexpr.NewSymbol("true"))
      ELSE Sexpr.Append(x, Sexpr.NewSymbol("false"))
      END
    ELSE Sexpr.Append(x, Sexpr.NewInteger(n.val))
    END
  | Ir.Get: Sexpr.Append(x, Sexpr.NewSymbol(n.local.name^))
  | Ir.Add .. Ir.Mod, Ir.Eq .. Ir.Ge:
    Sexpr.Append(x, Type(n.type));
    Sexpr.Append(x, WriteExpr(n.a)); Sexpr.Append(x, WriteExpr(n.b))
  | Ir.Neg: Sexpr.Append(x, Type(n.type)); Sexpr.Append(x, WriteExpr(n.a))
  | Ir.And, Ir.Or: Sexpr.Append(x, WriteExpr(n.a)); Sexpr.Append(x, WriteExpr(n.b))
  | Ir.Not: Sexpr.Append(x, WriteExpr(n.a))
  | Ir.Convert:
    Sexpr.Append(x, Type(n.type)); Sexpr.Append(x, Type(n.to));
    Sexpr.Append(x, WriteExpr(n.a))
  | Ir.Call: Sexpr.Append(x, Sexpr.NewSymbol(n.proc.name^)); AppendArgs(x, n.args)
  ELSE HALT(20) (* every expression op is handled above *)
  END;
  RETURN x
END WriteExpr;

PROCEDURE^ AppendStats(x: Sexpr.Node; s: Ir.Node);

PROCEDURE WriteStat(n: Ir.Node): Sexpr.Node;
  VAR x, b: Sexpr.Node;
BEGIN
  IF n.op = Ir.Call THEN RETURN WriteExpr(n) END;
  x := NodeList(n);
  CASE n.op OF
  | Ir.Set: Sexpr.Append(x, Sexpr.NewSymbol(n.local.name^)); Sexpr.Append(x, WriteExpr(n.a))
  | Ir.If:
    Sexpr.Append(x, WriteExpr(n.a));
    b := List("then"); AppendStats(b, n.then); Sexpr.Append(x, b);
    IF n.hasElse THEN b := List("else"); AppendStats(b, n.else); Sexpr.Append(x, b) END
  | Ir.While: Sexpr.Append(x, WriteExpr(n.a)); AppendStats(x, n.then)
  | Ir.Return: IF n.a # NIL THEN Sexpr.Append(x, WriteExpr(n.a)) END
  | Ir.Halt: Sexpr.Append(x, WriteExpr(n.a))
  ELSE HALT(20) (* every statement op is handled above *)
  END;
  RETURN x
END WriteStat;

PROCEDURE AppendStats(x: Sexpr.Node; s: Ir.Node);
BEGIN
  WHILE s # NIL DO Sexpr.Append(x, WriteStat(s)); s := s.next END
END AppendStats;

PROCEDURE WriteDecl(head: ARRAY OF CHAR; l: Ir.Local): Sexpr.Node;
  VAR x: Sexpr.Node;
BEGIN
  x := List(head); Sexpr.Append(x, Sexpr.NewSymbol(l.name^)); Sexpr.Append(x, Type(l.type));
  RETURN x
END WriteDecl;

PROCEDURE WriteProc(p: Ir.Proc): Sexpr.Node;
  VAR x, r, b: Sexpr.Node; l: Ir.Local;
BEGIN
  x := List("proc"); Sexpr.Append(x, Sexpr.NewSymbol(p.name^));
  IF p.export THEN Sexpr.Append(x, Sexpr.NewSymbol("export")) END;
  IF p.blocking THEN Sexpr.Append(x, Sexpr.NewSymbol("blocking")) END;
  l := p.locals;
  WHILE (l # NIL) & l.param DO Sexpr.Append(x, WriteDecl("param", l)); l := l.next END;
  IF p.result # Ir.NoType THEN
    r := List("result"); Sexpr.Append(r, Type(p.result)); Sexpr.Append(x, r)
  END;
  WHILE l # NIL DO Sexpr.Append(x, WriteDecl("local", l)); l := l.next END;
  b := List("body"); AppendStats(b, p.body); Sexpr.Append(x, b);
  RETURN x
END WriteProc;

(* Write module m in canonical text form to standard output. *)
PROCEDURE Write*(m: Ir.Module);
  VAR x, i: Sexpr.Node; p: Ir.Proc;
BEGIN
  x := List("module"); Sexpr.Append(x, Sexpr.NewSymbol(m.name^));
  p := m.procs;
  WHILE p # NIL DO Sexpr.Append(x, WriteProc(p)); p := p.next END;
  IF m.hasInit THEN i := List("init"); AppendStats(i, m.init); Sexpr.Append(x, i) END;
  Sexpr.Write(x)
END Write;

BEGIN
  error[0] := 0X
END IrText.
