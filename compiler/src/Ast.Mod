MODULE Ast; (* Syntax trees of Oberon-5 source, as the parser builds them. *)

(* The tree records what was written, with its position; names are not yet
   resolved and nothing is type checked. Dump prints a tree as S-expressions,
   for testing the parser. *)

IMPORT Sexpr, Scan;

CONST
  (* Node kinds. *)
  Module* = 1; Procedure* = 2; Param* = 3; Var* = 4;
  Assign* = 10; Call* = 11; If* = 12; Elsif* = 13; While* = 14; Return* = 15;
  Binary* = 20; Unary* = 21; Number* = 22; Ident* = 23;

TYPE
  Name* = Sexpr.Name;

  Node* = POINTER TO NodeDesc;
  NodeDesc* = RECORD
    kind*: INTEGER;
    line*, col*: INTEGER;
    op*: INTEGER;            (* Binary, Unary: the operator's Scan token *)
    name*: Name;             (* Module, Procedure, Param, Var, Assign, Call, Ident *)
    type*: Name;             (* Param, Var: type name; Procedure: result type, or NIL *)
    value*: LONGINT;         (* Number *)
    export*, blocking*: BOOLEAN;  (* Procedure *)
    a*, b*: Node;            (* operands; If, Elsif, While: condition in a; Assign, Return: value in a *)
    params*: Node;           (* Procedure: Param list; Call: argument list *)
    vars*: Node;             (* Procedure: Var list; Module: Procedure list *)
    stats*: Node;            (* Module, Procedure: body; If, Elsif: then; While: body *)
    elsifs*: Node;           (* If: Elsif list *)
    else*: Node;             (* If: else statements *)
    hasBody*, hasElse*: BOOLEAN;
    next*: Node
  END;

PROCEDURE New*(kind, line, col: INTEGER): Node;
  VAR x: Node;
BEGIN
  NEW(x); x.kind := kind; x.line := line; x.col := col; RETURN x
END New;

PROCEDURE NewName*(s: ARRAY OF CHAR): Name;
  VAR n: Name; len, i: LONGINT;
BEGIN
  len := 0; WHILE (len < LEN(s)) & (s[len] # 0X) DO INC(len) END;
  NEW(n, len + 1);
  FOR i := 0 TO len - 1 DO n[i] := s[i] END;
  n[len] := 0X;
  RETURN n
END NewName;

(* Append x to the list starting at first. *)
PROCEDURE Append*(VAR first: Node; x: Node);
  VAR p: Node;
BEGIN
  IF first = NIL THEN first := x
  ELSE p := first; WHILE p.next # NIL DO p := p.next END; p.next := x
  END
END Append;

(* ---- Dumping ---- *)

PROCEDURE List(head: ARRAY OF CHAR; x: Node): Sexpr.Node;
  VAR s: Sexpr.Node;
BEGIN
  s := Sexpr.NewList(); Sexpr.Append(s, Sexpr.NewSymbol(head));
  Sexpr.Append(s, Sexpr.NewPosition(x.line, x.col));
  RETURN s
END List;

PROCEDURE Sym(s: Sexpr.Node; name: ARRAY OF CHAR);
BEGIN
  Sexpr.Append(s, Sexpr.NewSymbol(name))
END Sym;

PROCEDURE^ Tree(x: Node): Sexpr.Node;

PROCEDURE AppendAll(s: Sexpr.Node; x: Node);
BEGIN
  WHILE x # NIL DO Sexpr.Append(s, Tree(x)); x := x.next END
END AppendAll;

(* A block of statements headed by head, with no position of its own. *)
PROCEDURE Block(head: ARRAY OF CHAR; stats: Node): Sexpr.Node;
  VAR s: Sexpr.Node;
BEGIN
  s := Sexpr.NewList(); Sexpr.Append(s, Sexpr.NewSymbol(head)); AppendAll(s, stats);
  RETURN s
END Block;

PROCEDURE Tree(x: Node): Sexpr.Node;
  VAR s, r: Sexpr.Node; op: ARRAY 16 OF CHAR;
BEGIN
  CASE x.kind OF
  | Module:
    s := List("module", x); Sym(s, x.name^); AppendAll(s, x.vars);
    IF x.hasBody THEN Sexpr.Append(s, Block("begin", x.stats)) END
  | Procedure:
    s := List("procedure", x); Sym(s, x.name^);
    IF x.export THEN Sym(s, "export") END;
    IF x.blocking THEN Sym(s, "blocking") END;
    AppendAll(s, x.params);
    IF x.type # NIL THEN
      r := Sexpr.NewList(); Sym(r, "result"); Sym(r, x.type^); Sexpr.Append(s, r)
    END;
    AppendAll(s, x.vars);
    IF x.hasBody THEN Sexpr.Append(s, Block("begin", x.stats)) END
  | Param: s := List("param", x); Sym(s, x.name^); Sym(s, x.type^)
  | Var: s := List("var", x); Sym(s, x.name^); Sym(s, x.type^)
  | Assign: s := List("assign", x); Sym(s, x.name^); Sexpr.Append(s, Tree(x.a))
  | Call: s := List("call", x); Sym(s, x.name^); AppendAll(s, x.params)
  | If:
    s := List("if", x); Sexpr.Append(s, Tree(x.a));
    Sexpr.Append(s, Block("then", x.stats));
    AppendAll(s, x.elsifs);
    IF x.hasElse THEN Sexpr.Append(s, Block("else", x.else)) END
  | Elsif:
    s := List("elsif", x); Sexpr.Append(s, Tree(x.a)); Sexpr.Append(s, Block("then", x.stats))
  | While: s := List("while", x); Sexpr.Append(s, Tree(x.a)); AppendAll(s, x.stats)
  | Return: s := List("return", x); IF x.a # NIL THEN Sexpr.Append(s, Tree(x.a)) END
  | Binary, Unary:
    Scan.Spelling(x.op, op);
    s := List(op, x); Sexpr.Append(s, Tree(x.a));
    IF x.kind = Binary THEN Sexpr.Append(s, Tree(x.b)) END
  | Number: s := List("number", x); Sexpr.Append(s, Sexpr.NewInteger(x.value))
  | Ident: s := List("ident", x); Sym(s, x.name^)
  ELSE HALT(20) (* every kind is handled above *)
  END;
  RETURN s
END Tree;

(* Print the tree of module m to standard output. *)
PROCEDURE Dump*(m: Node);
BEGIN
  Sexpr.Block("module", -1); Sexpr.Block("procedure", -1);
  Sexpr.Block("begin", 0); Sexpr.Block("then", 0); Sexpr.Block("else", 0);
  Sexpr.Block("if", 1); Sexpr.Block("elsif", 1); Sexpr.Block("while", 1);
  Sexpr.Write(Tree(m))
END Dump;

END Ast.
