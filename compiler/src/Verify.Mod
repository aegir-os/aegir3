MODULE Verify; (* The IR verifier for the core slice. See specs/ir.md. *)

(* Rule numbers are those of "Verifier rules for this slice" in specs/ir.md.
   Rule 1, that every name refers to a declaration, is enforced by the reader:
   records cannot be built from a name that does not resolve.

   A refusal names the module, the procedure (or init), the source position
   when the IR carries one, and the rule:

     Demo.Sum.Sum at 12:9: rule 2: operand of add is LongInt, expected Integer *)

IMPORT Ir;

CONST
  MaxError = 192;

VAR
  (* Set by Module when it fails; empty otherwise. *)
  error*: ARRAY MaxError OF CHAR;

  module: Ir.Module;
  proc: Ir.Proc;  (* the procedure being verified; NIL in init *)

(* ---- Messages ---- *)

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO INC(i) END;
  j := 0;
  WHILE (i < LEN(s) - 1) & (j < LEN(t)) & (t[j] # 0X) DO s[i] := t[j]; INC(i); INC(j) END;
  s[i] := 0X
END Append;

PROCEDURE IntStr(v: LONGINT; VAR s: ARRAY OF CHAR);
  VAR buf: ARRAY 24 OF CHAR; i, j: INTEGER;
BEGIN
  (* MIN(LONGINT) has no positive counterpart to convert. *)
  IF v = MIN(LONGINT) THEN COPY("-9223372036854775808", s); RETURN END;
  j := 0;
  IF v < 0 THEN s[0] := "-"; j := 1; v := -v END;
  i := 0;
  REPEAT buf[i] := CHR(ORD("0") + SHORT(v MOD 10)); v := v DIV 10; INC(i) UNTIL v = 0;
  WHILE i > 0 DO DEC(i); s[j] := buf[i]; INC(j) END;
  s[j] := 0X
END IntStr;

PROCEDURE Failed(): BOOLEAN;
BEGIN
  RETURN error[0] # 0X
END Failed;

(* Refuse under rule, at node n (NIL if none), with the message a b c d. Only
   the first refusal is kept. *)
PROCEDURE Fail(n: Ir.Node; rule: INTEGER; a, b, c, d: ARRAY OF CHAR);
  VAR s: ARRAY 24 OF CHAR;
BEGIN
  IF Failed() THEN RETURN END;
  COPY(module.name^, error);
  IF proc # NIL THEN Append(error, "."); Append(error, proc.name^)
  ELSE Append(error, " init")
  END;
  IF (n # NIL) & (n.pline > 0) THEN
    Append(error, " at "); IntStr(n.pline, s); Append(error, s);
    Append(error, ":"); IntStr(n.pcol, s); Append(error, s)
  END;
  Append(error, ": rule "); IntStr(rule, s); Append(error, s); Append(error, ": ");
  Append(error, a); Append(error, b); Append(error, c); Append(error, d)
END Fail;

(* ---- Types ---- *)

PROCEDURE IsInteger(t: INTEGER): BOOLEAN;
BEGIN
  RETURN (t >= Ir.Byte) & (t <= Ir.LongInt)
END IsInteger;

(* Size in bytes of an integer type; widening means a larger size. *)
PROCEDURE Width(t: INTEGER): INTEGER;
BEGIN
  CASE t OF
  | Ir.Byte: RETURN 1
  | Ir.ShortInt: RETURN 2
  | Ir.Integer: RETURN 4
  | Ir.LongInt: RETURN 8
  ELSE RETURN 0
  END
END Width;

(* Whether v is a value of type t. *)
PROCEDURE Fits(t: INTEGER; v: LONGINT): BOOLEAN;
BEGIN
  CASE t OF
  | Ir.Boolean: RETURN (v = 0) OR (v = 1)
  | Ir.Byte: RETURN (v >= -128) & (v <= 127)
  | Ir.ShortInt: RETURN (v >= -32768) & (v <= 32767)
  | Ir.Integer: RETURN (v >= -2147483647 - 1) & (v <= 2147483647)
  | Ir.LongInt: RETURN TRUE
  ELSE RETURN FALSE
  END
END Fits;

(* ---- Expressions ---- *)

PROCEDURE^ Expr(e: Ir.Node): INTEGER;

(* Rule 2: operand x of node n has type want. *)
PROCEDURE Operand(n, x: Ir.Node; want: INTEGER);
  VAR t: INTEGER;
BEGIN
  t := Expr(x);
  IF ~Failed() & (t # want) THEN
    Fail(n, 2, "operand of ", Ir.opName[n.op], " is ", Ir.typeName[t]);
    Append(error, ", expected "); Append(error, Ir.typeName[want])
  END
END Operand;

(* Rule 4: x, the condition or Boolean operand of node n, is Boolean. *)
PROCEDURE Condition(n, x: Ir.Node);
  VAR t: INTEGER;
BEGIN
  t := Expr(x);
  IF ~Failed() & (t # Ir.Boolean) THEN
    IF (n.op = Ir.If) OR (n.op = Ir.While) THEN
      Fail(n, 4, "condition of ", Ir.opName[n.op], " is ", Ir.typeName[t])
    ELSE Fail(n, 4, "operand of ", Ir.opName[n.op], " is ", Ir.typeName[t])
    END;
    Append(error, ", expected Boolean")
  END
END Condition;

(* Rule 2: node n names an integer type. *)
PROCEDURE NeedInteger(n: Ir.Node);
BEGIN
  IF ~IsInteger(n.type) THEN
    Fail(n, 2, Ir.opName[n.op], " needs an integer type, not ", Ir.typeName[n.type], "")
  END
END NeedInteger;

(* Rules 5 and 9 for call n: the arguments match the parameters, and a
   procedure that is not blocking does not call one that is. *)
PROCEDURE Call(n: Ir.Node);
  VAR p: Ir.Proc; a: Ir.Node; l: Ir.Local; k, t: INTEGER; s: ARRAY 24 OF CHAR;
BEGIN
  p := n.proc;
  k := 0; a := n.args;
  WHILE a # NIL DO INC(k); a := a.next END;
  IF k # p.nparams THEN
    IntStr(p.nparams, s);
    Fail(n, 5, p.name^, " takes ", s, " argument");
    IF p.nparams # 1 THEN Append(error, "s") END;
    Append(error, ", given "); IntStr(k, s); Append(error, s);
    RETURN
  END;
  a := n.args; l := p.locals; k := 1;
  WHILE (a # NIL) & ~Failed() DO
    t := Expr(a);
    IF ~Failed() & (t # l.type) THEN
      IntStr(k, s);
      Fail(n, 5, "argument ", s, " of ", p.name^);
      Append(error, " is "); Append(error, Ir.typeName[t]);
      Append(error, ", expected "); Append(error, Ir.typeName[l.type])
    END;
    a := a.next; l := l.next; INC(k)
  END;
  IF ~Failed() & p.blocking & (proc # NIL) & ~proc.blocking THEN
    Fail(n, 9, proc.name^, " is not blocking, so it cannot call blocking ", p.name^, "")
  END
END Call;

(* Verify expression e; return its type, or NoType after failing. *)
PROCEDURE Expr(e: Ir.Node): INTEGER;
  VAR s: ARRAY 24 OF CHAR;
BEGIN
  CASE e.op OF
  | Ir.Const:
    IF ~Fits(e.type, e.val) THEN
      IntStr(e.val, s); Fail(e, 8, "constant ", s, " does not fit ", Ir.typeName[e.type])
    END
  | Ir.Get: RETURN e.local.type
  | Ir.Add .. Ir.Mod:
    NeedInteger(e);
    IF ~Failed() THEN Operand(e, e.a, e.type) END;
    IF ~Failed() THEN Operand(e, e.b, e.type) END
  | Ir.Neg:
    NeedInteger(e);
    IF ~Failed() THEN Operand(e, e.a, e.type) END
  | Ir.Eq, Ir.Ne:
    Operand(e, e.a, e.type);
    IF ~Failed() THEN Operand(e, e.b, e.type) END;
    RETURN Ir.Boolean
  | Ir.Lt .. Ir.Ge:
    NeedInteger(e);
    IF ~Failed() THEN Operand(e, e.a, e.type) END;
    IF ~Failed() THEN Operand(e, e.b, e.type) END;
    RETURN Ir.Boolean
  | Ir.And, Ir.Or:
    Condition(e, e.a);
    IF ~Failed() THEN Condition(e, e.b) END;
    RETURN Ir.Boolean
  | Ir.Not:
    Condition(e, e.a);
    RETURN Ir.Boolean
  | Ir.Convert:
    IF ~IsInteger(e.type) OR ~IsInteger(e.to) OR (Width(e.to) <= Width(e.type)) THEN
      Fail(e, 10, "convert only widens; ", Ir.typeName[e.type], " to ", Ir.typeName[e.to])
    ELSE Operand(e, e.a, e.type)
    END;
    RETURN e.to
  | Ir.Call:
    IF e.proc.result = Ir.NoType THEN
      Fail(e, 5, e.proc.name^, " has no result, so it cannot be used in an expression", "", "")
    ELSE Call(e)
    END;
    RETURN e.proc.result
  ELSE HALT(20) (* the reader builds only expression ops here *)
  END;
  RETURN e.type
END Expr;

(* ---- Statements ---- *)

PROCEDURE^ Stats(s: Ir.Node);

PROCEDURE Stat(s: Ir.Node);
  VAR t: INTEGER;
BEGIN
  CASE s.op OF
  | Ir.Set:
    t := Expr(s.a);
    IF ~Failed() & (t # s.local.type) THEN
      Fail(s, 3, "value assigned to ", s.local.name^, " is ", Ir.typeName[t]);
      Append(error, ", expected "); Append(error, Ir.typeName[s.local.type])
    END
  | Ir.If:
    Condition(s, s.a);
    IF ~Failed() THEN Stats(s.then) END;
    IF ~Failed() THEN Stats(s.else) END
  | Ir.While:
    Condition(s, s.a);
    IF ~Failed() THEN Stats(s.then) END
  | Ir.Call:
    IF s.proc.result # Ir.NoType THEN
      Fail(s, 5, s.proc.name^, " has a result, so it cannot be called as a statement", "", "")
    ELSE Call(s)
    END
  | Ir.Return:
    IF proc = NIL THEN Fail(s, 6, "return outside a procedure", "", "", "")
    ELSIF proc.result = Ir.NoType THEN
      IF s.a # NIL THEN Fail(s, 6, proc.name^, " has no result, so return takes no value", "", "") END
    ELSIF s.a = NIL THEN
      Fail(s, 6, proc.name^, " returns ", Ir.typeName[proc.result], ", so return needs a value")
    ELSE
      t := Expr(s.a);
      IF ~Failed() & (t # proc.result) THEN
        Fail(s, 6, "return value is ", Ir.typeName[t], ", expected ", Ir.typeName[proc.result])
      END
    END
  | Ir.Halt:
    Operand(s, s.a, Ir.Integer)
  ELSE HALT(20) (* the reader builds only statement ops here *)
  END
END Stat;

PROCEDURE^ Terminates(s: Ir.Node): BOOLEAN;

(* Whether statement s cannot complete: it is a return or a halt, or an if with
   an else whose two branches both cannot. A while never counts, whatever its
   condition: reachability here is structural, and conditions are never
   evaluated. *)
PROCEDURE Ends(s: Ir.Node): BOOLEAN;
BEGIN
  CASE s.op OF
  | Ir.Return, Ir.Halt: RETURN TRUE
  | Ir.If: RETURN s.hasElse & Terminates(s.then) & Terminates(s.else)
  ELSE RETURN FALSE
  END
END Ends;

(* Rule 7: the statement list s cannot reach its end, because its last
   statement cannot complete. *)
PROCEDURE Terminates(s: Ir.Node): BOOLEAN;
BEGIN
  IF s = NIL THEN RETURN FALSE END;
  WHILE s.next # NIL DO s := s.next END;
  RETURN Ends(s)
END Terminates;

(* Verify a statement list. Rule 11: no statement follows one that cannot
   complete, since it could never run. *)
PROCEDURE Stats(s: Ir.Node);
BEGIN
  WHILE (s # NIL) & ~Failed() DO
    Stat(s);
    IF ~Failed() & (s.next # NIL) & Ends(s) THEN
      IF s.op = Ir.If THEN
        Fail(s.next, 11, Ir.opName[s.next.op],
          " can never run: every branch of the if before it ends", "", "")
      ELSE
        Fail(s.next, 11, Ir.opName[s.next.op], " can never run: it follows ",
          Ir.opName[s.op], "")
      END
    END;
    s := s.next
  END
END Stats;

(* ---- Modules ---- *)

(* Verify module m. On failure, returns FALSE and sets error. *)
PROCEDURE Module*(m: Ir.Module): BOOLEAN;
BEGIN
  error[0] := 0X; module := m;
  proc := m.procs;
  WHILE (proc # NIL) & ~Failed() DO
    Stats(proc.body);
    IF ~Failed() & (proc.result # Ir.NoType) & ~Terminates(proc.body) THEN
      Fail(NIL, 7, proc.name^, " can reach the end of its body without returning a value",
        "", "")
    END;
    IF ~Failed() THEN proc := proc.next END
  END;
  IF ~Failed() THEN proc := NIL; Stats(m.init) END;
  RETURN ~Failed()
END Module;

BEGIN
  error[0] := 0X
END Verify.
