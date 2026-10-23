MODULE Ir; (* The IR as records: the core node set of specs/ir.md. *)

IMPORT Sexpr;

CONST
  (* Types. NoType marks a procedure without a result. *)
  NoType* = 0;
  Boolean* = 1; Byte* = 2; ShortInt* = 3; Integer* = 4; LongInt* = 5;
  MaxType* = LongInt;

  (* Expressions. *)
  Const* = 1; Get* = 2;
  Add* = 3; Sub* = 4; Mul* = 5; Div* = 6; Mod* = 7;
  Neg* = 8;
  Eq* = 9; Ne* = 10; Lt* = 11; Le* = 12; Gt* = 13; Ge* = 14;
  And* = 15; Or* = 16; Not* = 17;
  Convert* = 18;
  Call* = 19;           (* also a statement *)

  (* Statements. *)
  Set* = 20; If* = 21; While* = 22; Return* = 23; Halt* = 24;
  MaxOp* = Halt;

  (* Ranges of operators sharing a shape. *)
  FirstBinary* = Add; LastBinary* = Ge;  (* (op T a b) *)

TYPE
  Name* = Sexpr.Name;

  Local* = POINTER TO LocalDesc;
  LocalDesc* = RECORD
    name*: Name;
    type*: INTEGER;
    param*: BOOLEAN;
    index*: INTEGER;     (* parameters first, from 0 *)
    next*: Local
  END;

  Proc* = POINTER TO ProcDesc;

  (* An expression or a statement. Which fields are used depends on op. *)
  Node* = POINTER TO NodeDesc;
  NodeDesc* = RECORD
    op*: INTEGER;
    type*: INTEGER;      (* the type an operation names; convert's source *)
    to*: INTEGER;        (* convert's target *)
    val*: LONGINT;       (* const *)
    local*: Local;       (* get, set *)
    proc*: Proc;         (* call *)
    a*, b*: Node;        (* operands; set's value and return's value in a *)
    args*: Node;         (* call's arguments, linked by next *)
    then*, else*: Node;  (* if's branches; while's body in then *)
    hasElse*: BOOLEAN;
    next*: Node;         (* next statement or argument *)
    pline*, pcol*: INTEGER (* source position in debug IR; 0 if none *)
  END;

  ProcDesc* = RECORD
    name*: Name;
    export*, blocking*: BOOLEAN;
    result*: INTEGER;    (* NoType if none *)
    locals*: Local;      (* parameters first *)
    nparams*: INTEGER;
    body*: Node;
    next*: Proc
  END;

  Module* = POINTER TO ModuleDesc;
  ModuleDesc* = RECORD
    name*: Name;
    procs*: Proc;
    init*: Node;
    hasInit*: BOOLEAN
  END;

VAR
  opName*: ARRAY MaxOp + 1, 8 OF CHAR;
  typeName*: ARRAY MaxType + 1, 12 OF CHAR;

PROCEDURE NewNode*(op: INTEGER): Node;
  VAR x: Node;
BEGIN
  NEW(x); x.op := op; RETURN x
END NewNode;

PROCEDURE FindLocal*(p: Proc; name: ARRAY OF CHAR): Local;
  VAR l: Local;
BEGIN
  IF p = NIL THEN RETURN NIL END;
  l := p.locals;
  WHILE (l # NIL) & (l.name^ # name) DO l := l.next END;
  RETURN l
END FindLocal;

PROCEDURE FindProc*(m: Module; name: ARRAY OF CHAR): Proc;
  VAR p: Proc;
BEGIN
  p := m.procs;
  WHILE (p # NIL) & (p.name^ # name) DO p := p.next END;
  RETURN p
END FindProc;

BEGIN
  opName[0] := "";
  opName[Const] := "const"; opName[Get] := "get";
  opName[Add] := "add"; opName[Sub] := "sub"; opName[Mul] := "mul";
  opName[Div] := "div"; opName[Mod] := "mod"; opName[Neg] := "neg";
  opName[Eq] := "eq"; opName[Ne] := "ne"; opName[Lt] := "lt";
  opName[Le] := "le"; opName[Gt] := "gt"; opName[Ge] := "ge";
  opName[And] := "and"; opName[Or] := "or"; opName[Not] := "not";
  opName[Convert] := "convert"; opName[Call] := "call";
  opName[Set] := "set"; opName[If] := "if"; opName[While] := "while";
  opName[Return] := "return"; opName[Halt] := "halt";

  typeName[NoType] := "";
  typeName[Boolean] := "Boolean"; typeName[Byte] := "Byte";
  typeName[ShortInt] := "ShortInt"; typeName[Integer] := "Integer";
  typeName[LongInt] := "LongInt"
END Ir.
