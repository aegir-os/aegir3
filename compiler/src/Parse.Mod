MODULE Parse; (* Parser for the subset of Oberon-5 the core IR slice covers. *)

(* Grammar of the subset, in Oberon's EBNF; reserved words are lowercase.

     Module     = "module" QualIdent ";" {ProcDecl ";"}
                  ["begin" StatSeq] "end" QualIdent ".".
     QualIdent  = ident {"." ident}.
     ProcDecl   = "procedure" ident ["*"] [Flags] [FormalPars] ";"
                  {"var" {IdentList ":" Type ";"}}
                  ["begin" StatSeq] "end" ident.
     Flags      = "{" ident {"," ident} "}".
     FormalPars = "(" [Section {";" Section}] ")" [":" Type].
     Section    = IdentList ":" Type.
     IdentList  = ident {"," ident}.
     Type       = ident.
     StatSeq    = Stat {";" Stat}.
     Stat       = [ident ":=" Expr | ident [Args] | IfStat | WhileStat
                  | "return" [Expr]].
     IfStat     = "if" Expr "then" StatSeq {"elsif" Expr "then" StatSeq}
                  ["else" StatSeq] "end".
     WhileStat  = "while" Expr "do" StatSeq "end".
     Expr       = SimpleExpr [Relation SimpleExpr].
     Relation   = "=" | "#" | "<" | "<=" | ">" | ">=".
     SimpleExpr = ["+" | "-"] Term {("+" | "-" | "or") Term}.
     Term       = Factor {("*" | "div" | "mod" | "&") Factor}.
     Factor     = number | ident [Args] | "(" Expr ")" | "~" Factor.
     Args       = "(" [Expr {"," Expr}] ")".

   Other Oberon-5 constructs are refused by name, as not supported yet. The
   first error ends parsing. *)

IMPORT Scan, Ast;

CONST
  MaxError = 128;
  MaxName = 256;

VAR
  (* Set when parsing fails; empty otherwise. *)
  error*: ARRAY MaxError OF CHAR;
  errLine*, errCol*: INTEGER;

(* ---- Errors ---- *)

PROCEDURE Failed(): BOOLEAN;
BEGIN
  RETURN (error[0] # 0X) OR (Scan.error[0] # 0X)
END Failed;

(* Fail at the current token. A scanner error takes precedence. *)
PROCEDURE Fail(msg: ARRAY OF CHAR);
BEGIN
  IF Failed() THEN RETURN END;
  COPY(msg, error); errLine := Scan.line; errCol := Scan.col
END Fail;

PROCEDURE Append(VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := 0; WHILE s[i] # 0X DO INC(i) END;
  j := 0;
  WHILE (i < LEN(s) - 1) & (j < LEN(t)) & (t[j] # 0X) DO s[i] := t[j]; INC(i); INC(j) END;
  s[i] := 0X
END Append;

(* Fail with "expected <what>, found <current token>". *)
PROCEDURE Expected(what: ARRAY OF CHAR);
  VAR msg: ARRAY MaxError OF CHAR; found: ARRAY 16 OF CHAR;
BEGIN
  msg := "expected "; Append(msg, what); Append(msg, ", found ");
  Scan.Spelling(Scan.sym, found); Append(msg, found);
  Fail(msg)
END Expected;

(* Fail with "not supported yet: <what>". *)
PROCEDURE Unsupported(what: ARRAY OF CHAR);
  VAR msg: ARRAY MaxError OF CHAR;
BEGIN
  msg := "not supported yet: "; Append(msg, what); Fail(msg)
END Unsupported;

(* Fail at line, col rather than at the current token. *)
PROCEDURE FailAt(msg: ARRAY OF CHAR; line, col: INTEGER);
BEGIN
  IF Failed() THEN RETURN END;
  COPY(msg, error); errLine := line; errCol := col
END FailAt;

(* Consume token sym, or fail. *)
PROCEDURE Expect(sym: INTEGER);
  VAR s: ARRAY 16 OF CHAR;
BEGIN
  IF Scan.sym = sym THEN Scan.Next
  ELSE Scan.Spelling(sym, s); Expected(s)
  END
END Expect;

(* An identifier, consumed into name; NIL after failing. *)
PROCEDURE Ident(): Ast.Name;
  VAR n: Ast.Name;
BEGIN
  IF Scan.sym # Scan.Ident THEN Expected("an identifier"); RETURN NIL END;
  n := Ast.NewName(Scan.id); Scan.Next;
  RETURN n
END Ident;

(* ---- Expressions ---- *)

PROCEDURE^ Expr(): Ast.Node;

(* Arguments in parentheses, appended to x.params. *)
PROCEDURE Args(x: Ast.Node);
BEGIN
  Scan.Next; (* ( *)
  IF Scan.sym # Scan.RParen THEN
    LOOP
      Ast.Append(x.params, Expr());
      IF Failed() OR (Scan.sym # Scan.Comma) THEN EXIT END;
      Scan.Next
    END
  END;
  Expect(Scan.RParen)
END Args;

(* Refuse selectors, which this subset does not have. *)
PROCEDURE NoSelector;
BEGIN
  CASE Scan.sym OF
  | Scan.Period: Unsupported("qualified names and record fields")
  | Scan.LBrak: Unsupported("array indexing")
  | Scan.Arrow: Unsupported("pointer dereference")
  ELSE
  END
END NoSelector;

PROCEDURE Factor(): Ast.Node;
  VAR x: Ast.Node;
BEGIN
  x := Ast.New(0, Scan.line, Scan.col);
  CASE Scan.sym OF
  | Scan.Int: x.kind := Ast.Number; x.value := Scan.ival; Scan.Next
  | Scan.Ident:
    x.kind := Ast.Ident; x.name := Ident();
    NoSelector;
    IF Scan.sym = Scan.LParen THEN x.kind := Ast.Call; Args(x) END
  | Scan.LParen: Scan.Next; x := Expr(); Expect(Scan.RParen)
  | Scan.Not: x.kind := Ast.Unary; x.op := Scan.Not; Scan.Next; x.a := Factor()
  | Scan.Real: Unsupported("real numbers")
  | Scan.Char: Unsupported("character constants")
  | Scan.String: Unsupported("strings")
  | Scan.Nil: Unsupported("nil")
  | Scan.LBrace: Unsupported("sets")
  ELSE Expected("an expression")
  END;
  RETURN x
END Factor;

PROCEDURE Term(): Ast.Node;
  VAR x, y: Ast.Node;
BEGIN
  x := Factor();
  WHILE ~Failed() & ((Scan.sym = Scan.Times) OR (Scan.sym = Scan.Div)
      OR (Scan.sym = Scan.Mod) OR (Scan.sym = Scan.And) OR (Scan.sym = Scan.Slash)) DO
    IF Scan.sym = Scan.Slash THEN Unsupported("real division /")
    ELSE
      y := Ast.New(Ast.Binary, Scan.line, Scan.col); y.op := Scan.sym; Scan.Next;
      y.a := x; y.b := Factor(); x := y
    END
  END;
  RETURN x
END Term;

PROCEDURE SimpleExpr(): Ast.Node;
  VAR x, y: Ast.Node;
BEGIN
  IF (Scan.sym = Scan.Plus) OR (Scan.sym = Scan.Minus) THEN
    x := Ast.New(Ast.Unary, Scan.line, Scan.col); x.op := Scan.sym; Scan.Next;
    x.a := Term()
  ELSE x := Term()
  END;
  WHILE ~Failed() & ((Scan.sym = Scan.Plus) OR (Scan.sym = Scan.Minus) OR (Scan.sym = Scan.Or)) DO
    y := Ast.New(Ast.Binary, Scan.line, Scan.col); y.op := Scan.sym; Scan.Next;
    y.a := x; y.b := Term(); x := y
  END;
  RETURN x
END SimpleExpr;

PROCEDURE Expr(): Ast.Node;
  VAR x, y: Ast.Node;
BEGIN
  x := SimpleExpr();
  IF ~Failed() THEN
    CASE Scan.sym OF
    | Scan.Eql, Scan.Neq, Scan.Lss, Scan.Leq, Scan.Gtr, Scan.Geq:
      y := Ast.New(Ast.Binary, Scan.line, Scan.col); y.op := Scan.sym; Scan.Next;
      y.a := x; y.b := SimpleExpr(); x := y
    | Scan.In: Unsupported("set membership in")
    | Scan.Is: Unsupported("type tests")
    ELSE
    END
  END;
  RETURN x
END Expr;

(* ---- Statements ---- *)

PROCEDURE^ StatSeq(): Ast.Node;

PROCEDURE IfStat(): Ast.Node;
  VAR x, e: Ast.Node;
BEGIN
  x := Ast.New(Ast.If, Scan.line, Scan.col); Scan.Next;
  x.a := Expr(); Expect(Scan.Then); x.stats := StatSeq();
  WHILE ~Failed() & (Scan.sym = Scan.Elsif) DO
    e := Ast.New(Ast.Elsif, Scan.line, Scan.col); Scan.Next;
    e.a := Expr(); Expect(Scan.Then); e.stats := StatSeq();
    Ast.Append(x.elsifs, e)
  END;
  IF ~Failed() & (Scan.sym = Scan.Else) THEN
    Scan.Next; x.hasElse := TRUE; x.else := StatSeq()
  END;
  Expect(Scan.End);
  RETURN x
END IfStat;

PROCEDURE WhileStat(): Ast.Node;
  VAR x: Ast.Node;
BEGIN
  x := Ast.New(Ast.While, Scan.line, Scan.col); Scan.Next;
  x.a := Expr(); Expect(Scan.Do); x.stats := StatSeq(); Expect(Scan.End);
  RETURN x
END WhileStat;

(* A statement, or NIL for an empty one. *)
PROCEDURE Stat(): Ast.Node;
  VAR x: Ast.Node; name: Ast.Name; line, col: INTEGER;
BEGIN
  x := NIL;
  CASE Scan.sym OF
  | Scan.Ident:
    line := Scan.line; col := Scan.col;
    name := Ident();
    NoSelector;
    IF Scan.sym = Scan.Becomes THEN
      x := Ast.New(Ast.Assign, line, col); x.name := name; Scan.Next; x.a := Expr()
    ELSE
      x := Ast.New(Ast.Call, line, col); x.name := name;
      IF Scan.sym = Scan.LParen THEN Args(x) END
    END
  | Scan.If: x := IfStat()
  | Scan.While: x := WhileStat()
  | Scan.Return:
    x := Ast.New(Ast.Return, Scan.line, Scan.col); Scan.Next;
    IF (Scan.sym # Scan.Semicolon) & (Scan.sym # Scan.End) & (Scan.sym # Scan.Else)
        & (Scan.sym # Scan.Elsif) THEN
      x.a := Expr()
    END
  | Scan.Case: Unsupported("case")
  | Scan.Repeat: Unsupported("repeat")
  | Scan.For: Unsupported("for")
  | Scan.Loop: Unsupported("loop")
  | Scan.Exit: Unsupported("exit")
  | Scan.With: Unsupported("with")
  ELSE (* the empty statement *)
  END;
  RETURN x
END Stat;

PROCEDURE StatSeq(): Ast.Node;
  VAR first, s: Ast.Node;
BEGIN
  first := NIL;
  LOOP
    s := Stat();
    IF s # NIL THEN Ast.Append(first, s) END;
    IF Failed() OR (Scan.sym # Scan.Semicolon) THEN EXIT END;
    Scan.Next
  END;
  RETURN first
END StatSeq;

(* ---- Declarations ---- *)

(* IdentList ":" Type, appended to list as nodes of kind. *)
PROCEDURE Section(VAR list: Ast.Node; kind: INTEGER);
  VAR first, x: Ast.Node; type: Ast.Name;
BEGIN
  first := NIL;
  LOOP
    x := Ast.New(kind, Scan.line, Scan.col); x.name := Ident();
    IF Failed() THEN RETURN END;
    Ast.Append(first, x);
    IF Scan.sym # Scan.Comma THEN EXIT END;
    Scan.Next
  END;
  Expect(Scan.Colon);
  IF Scan.sym = Scan.Array THEN Unsupported("arrays")
  ELSIF Scan.sym = Scan.Record THEN Unsupported("records")
  ELSIF Scan.sym = Scan.Pointer THEN Unsupported("pointers")
  ELSIF Scan.sym = Scan.Procedure THEN Unsupported("procedure types")
  END;
  type := Ident();
  IF Scan.sym = Scan.Period THEN Unsupported("qualified type names") END;
  IF Failed() THEN RETURN END;
  x := first;
  WHILE x # NIL DO x.type := type; x := x.next END;
  Ast.Append(list, first)
END Section;

PROCEDURE FormalPars(p: Ast.Node);
BEGIN
  Scan.Next; (* ( *)
  IF Scan.sym # Scan.RParen THEN
    LOOP
      IF Scan.sym = Scan.Var THEN Unsupported("var parameters"); RETURN END;
      Section(p.params, Ast.Param);
      IF Failed() OR (Scan.sym # Scan.Semicolon) THEN EXIT END;
      Scan.Next
    END
  END;
  Expect(Scan.RParen);
  IF ~Failed() & (Scan.sym = Scan.Colon) THEN Scan.Next; p.type := Ident() END
END FormalPars;

PROCEDURE Flags(p: Ast.Node);
  VAR msg: ARRAY MaxError OF CHAR;
BEGIN
  Scan.Next; (* { *)
  LOOP
    IF Scan.sym # Scan.Ident THEN Expected("a flag"); RETURN END;
    IF Scan.id = "blocking" THEN p.blocking := TRUE
    ELSE
      msg := "unknown procedure flag "; Append(msg, Scan.id); Fail(msg); RETURN
    END;
    Scan.Next;
    IF Scan.sym # Scan.Comma THEN EXIT END;
    Scan.Next
  END;
  Expect(Scan.RBrace)
END Flags;

PROCEDURE ProcDecl(): Ast.Node;
  VAR p: Ast.Node; end: Ast.Name; line, col: INTEGER;
BEGIN
  p := Ast.New(Ast.Procedure, Scan.line, Scan.col); Scan.Next;
  IF Scan.sym = Scan.Arrow THEN Unsupported("forward declarations"); RETURN p END;
  p.line := Scan.line; p.col := Scan.col;
  p.name := Ident();
  IF Scan.sym = Scan.Times THEN p.export := TRUE; Scan.Next END;
  IF ~Failed() & (Scan.sym = Scan.LBrace) THEN Flags(p) END;
  IF ~Failed() & (Scan.sym = Scan.LParen) THEN FormalPars(p) END;
  Expect(Scan.Semicolon);
  WHILE ~Failed() & (Scan.sym = Scan.Var) DO
    Scan.Next;
    WHILE ~Failed() & (Scan.sym = Scan.Ident) DO Section(p.vars, Ast.Var); Expect(Scan.Semicolon) END
  END;
  IF ~Failed() THEN
    CASE Scan.sym OF
    | Scan.Const: Unsupported("const declarations")
    | Scan.Type: Unsupported("type declarations")
    | Scan.Procedure: Unsupported("nested procedures")
    ELSE
    END
  END;
  IF ~Failed() & (Scan.sym = Scan.Begin) THEN
    Scan.Next; p.hasBody := TRUE; p.stats := StatSeq()
  END;
  Expect(Scan.End);
  IF Failed() THEN RETURN p END;
  line := Scan.line; col := Scan.col;
  end := Ident();
  IF ~Failed() & (end^ # p.name^) THEN
    FailAt("the name after end must be the procedure's name", line, col)
  END;
  RETURN p
END ProcDecl;

(* QualIdent into name; FALSE after failing. *)
PROCEDURE QualIdent(VAR name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF Scan.sym # Scan.Ident THEN Expected("an identifier"); RETURN FALSE END;
  COPY(Scan.id, name); Scan.Next;
  WHILE Scan.sym = Scan.Period DO
    Scan.Next;
    IF Scan.sym # Scan.Ident THEN Expected("an identifier"); RETURN FALSE END;
    Append(name, "."); Append(name, Scan.id); Scan.Next
  END;
  RETURN TRUE
END QualIdent;

(* The module's name after its final end, then the period that ends the
   module. The name is read only as far as it matches the module's name, so
   that in "end Demo.Sum." the last period ends the module, not the name. *)
PROCEDURE EndName(m: Ast.Node);
  VAR name: ARRAY MaxName OF CHAR; line, col: INTEGER;
BEGIN
  line := Scan.line; col := Scan.col;
  IF Scan.sym # Scan.Ident THEN Expected("an identifier"); RETURN END;
  COPY(Scan.id, name); Scan.Next;
  LOOP
    IF name = m.name^ THEN Expect(Scan.Period); RETURN END;
    IF Scan.sym # Scan.Period THEN EXIT END;
    Scan.Next;
    IF Scan.sym # Scan.Ident THEN EXIT END;
    Append(name, "."); Append(name, Scan.id); Scan.Next
  END;
  FailAt("the name after end must be the module's name", line, col)
END EndName;

(* Parse the module in the open source file. On failure, returns NIL and sets
   error, errLine and errCol, or the scanner's error. *)
PROCEDURE Module*(): Ast.Node;
  VAR m: Ast.Node; name: ARRAY MaxName OF CHAR;
BEGIN
  error[0] := 0X; errLine := 0; errCol := 0;
  m := Ast.New(Ast.Module, Scan.line, Scan.col);
  Expect(Scan.Module);
  IF Failed() THEN RETURN NIL END;
  m.line := Scan.line; m.col := Scan.col;
  IF ~QualIdent(name) THEN RETURN NIL END;
  m.name := Ast.NewName(name);
  Expect(Scan.Semicolon);
  IF ~Failed() THEN
    CASE Scan.sym OF
    | Scan.Import: Unsupported("import")
    | Scan.Const: Unsupported("const declarations")
    | Scan.Type: Unsupported("type declarations")
    | Scan.Var: Unsupported("module variables")
    ELSE
    END
  END;
  WHILE ~Failed() & (Scan.sym = Scan.Procedure) DO
    Ast.Append(m.vars, ProcDecl()); Expect(Scan.Semicolon)
  END;
  IF ~Failed() & (Scan.sym = Scan.Begin) THEN
    Scan.Next; m.hasBody := TRUE; m.stats := StatSeq()
  END;
  Expect(Scan.End);
  IF ~Failed() THEN EndName(m) END;
  IF ~Failed() & (Scan.sym # Scan.Eof) THEN Fail("text after the end of the module") END;
  IF Failed() THEN RETURN NIL END;
  RETURN m
END Module;

BEGIN
  error[0] := 0X
END Parse.
