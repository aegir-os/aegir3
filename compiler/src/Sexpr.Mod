MODULE Sexpr; (* S-expressions: the syntax of the IR text form. *)

(* A text holds one expression. An expression is an atom or a list:

     list      ( expr ... )
     symbol    a run of characters other than space, parentheses and ';'
     integer   optional '-', then decimal digits; must fit LONGINT
     position  '@' line ':' column, a source position in debug IR

   ';' starts a comment that runs to the end of the line.

   Write prints the canonical form: one space between the elements of a list,
   except for lists whose head is registered with Block, which put each element
   after the header on its own line. *)

IMPORT Files, Out;

CONST
  (* Node kinds. *)
  Symbol* = 0; Integer* = 1; Position* = 2; List* = 3;

  MaxBlocks = 32;
  MaxError = 128;

TYPE
  Name* = POINTER TO ARRAY OF CHAR;

  Node* = POINTER TO NodeDesc;
  NodeDesc* = RECORD
    kind*: INTEGER;
    line*, col*: INTEGER;  (* where the node starts in the text *)
    name*: Name;           (* Symbol *)
    int*: LONGINT;         (* Integer *)
    pline*, pcol*: INTEGER;(* Position *)
    first*: Node;          (* List: first element *)
    next*: Node            (* next element of the enclosing list *)
  END;

  Text = POINTER TO ARRAY OF CHAR;

  BlockDesc = RECORD
    head: ARRAY 32 OF CHAR;
    keep: INTEGER
  END;

VAR
  (* Set by Read when it fails; empty otherwise. *)
  error*: ARRAY MaxError OF CHAR;
  errLine*, errCol*: INTEGER;

  text: Text;
  len, pos, line, col: LONGINT;

  blocks: ARRAY MaxBlocks OF BlockDesc;
  nblocks: INTEGER;

(* ---- Reading ---- *)

PROCEDURE Fail(msg: ARRAY OF CHAR; l, c: LONGINT);
BEGIN
  IF error[0] = 0X THEN
    COPY(msg, error); errLine := SHORT(l); errCol := SHORT(c)
  END
END Fail;

PROCEDURE Ch(): CHAR;
BEGIN
  IF pos < len THEN RETURN text[pos] ELSE RETURN 0X END
END Ch;

PROCEDURE Advance;
BEGIN
  IF text[pos] = 0AX THEN INC(line); col := 1 ELSE INC(col) END;
  INC(pos)
END Advance;

PROCEDURE SkipBlank;
BEGIN
  LOOP
    IF pos >= len THEN EXIT END;
    CASE text[pos] OF
    | " ", 9X, 0AX, 0DX: Advance
    | ";": WHILE (pos < len) & (text[pos] # 0AX) DO Advance END
    ELSE EXIT
    END
  END
END SkipBlank;

PROCEDURE IsDelimiter(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch = 0X) OR (ch = " ") OR (ch = 9X) OR (ch = 0AX) OR (ch = 0DX)
      OR (ch = "(") OR (ch = ")") OR (ch = ";")
END IsDelimiter;

PROCEDURE IsDigit(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch >= "0") & (ch <= "9")
END IsDigit;

(* Read the digits of a non-negative number into n; FALSE if malformed or too
   large for INTEGER. Used for positions. *)
PROCEDURE SmallNumber(VAR n: INTEGER): BOOLEAN;
  VAR d: INTEGER;
BEGIN
  IF ~IsDigit(Ch()) THEN RETURN FALSE END;
  n := 0;
  WHILE IsDigit(Ch()) DO
    d := ORD(Ch()) - ORD("0");
    IF n > (MAX(INTEGER) - d) DIV 10 THEN RETURN FALSE END;
    n := n * 10 + d; Advance
  END;
  RETURN TRUE
END SmallNumber;

(* An integer atom. The magnitude is accumulated as a positive number and
   checked against MAX(LONGINT). MIN(LONGINT), whose magnitude is one more than
   MAX(LONGINT), is recognized as a special case. Nothing here divides a
   negative number: VOC computes MIN(LONGINT) DIV 10 wrongly. *)
PROCEDURE ReadInteger(x: Node);
  CONST limit = MAX(LONGINT) DIV 10; lastd = MAX(LONGINT) MOD 10;
  VAR neg, min: BOOLEAN; v: LONGINT; d: INTEGER;
BEGIN
  neg := Ch() = "-";
  IF neg THEN Advance END;
  v := 0; min := FALSE;
  WHILE IsDigit(Ch()) DO
    d := ORD(Ch()) - ORD("0");
    IF min THEN Fail("integer out of range", x.line, x.col); RETURN END;
    IF (v > limit) OR (v = limit) & (d > lastd) THEN
      IF neg & (v = limit) & (d = lastd + 1) THEN min := TRUE
      ELSE Fail("integer out of range", x.line, x.col); RETURN
      END
    ELSE v := v * 10 + d
    END;
    Advance
  END;
  IF ~IsDelimiter(Ch()) THEN Fail("malformed number", x.line, x.col); RETURN END;
  IF min THEN v := MIN(LONGINT) ELSIF neg THEN v := -v END;
  x.kind := Integer; x.int := v
END ReadInteger;

PROCEDURE ReadPosition(x: Node);
BEGIN
  Advance; (* '@' *)
  IF SmallNumber(x.pline) & (Ch() = ":") THEN
    Advance;
    IF SmallNumber(x.pcol) & IsDelimiter(Ch()) THEN x.kind := Position; RETURN END
  END;
  Fail("malformed position", x.line, x.col)
END ReadPosition;

PROCEDURE ReadSymbol(x: Node);
  VAR start, n, i: LONGINT;
BEGIN
  start := pos;
  WHILE ~IsDelimiter(Ch()) DO Advance END;
  n := pos - start;
  NEW(x.name, n + 1);
  FOR i := 0 TO n - 1 DO x.name[i] := text[start + i] END;
  x.name[n] := 0X;
  x.kind := Symbol
END ReadSymbol;

PROCEDURE^ ReadExpr(): Node;

PROCEDURE ReadList(x: Node);
  VAR last, e: Node;
BEGIN
  Advance; (* '(' *)
  x.kind := List; last := NIL;
  LOOP
    SkipBlank;
    IF error[0] # 0X THEN EXIT END;
    IF pos >= len THEN Fail("list is not closed", x.line, x.col); EXIT END;
    IF Ch() = ")" THEN Advance; EXIT END;
    e := ReadExpr();
    IF e = NIL THEN EXIT END;
    IF last = NIL THEN x.first := e ELSE last.next := e END;
    last := e
  END
END ReadList;

(* Read one expression at pos; NIL on error. *)
PROCEDURE ReadExpr(): Node;
  VAR x: Node; ch: CHAR;
BEGIN
  NEW(x); x.line := SHORT(line); x.col := SHORT(col);
  ch := Ch();
  IF ch = "(" THEN ReadList(x)
  ELSIF ch = ")" THEN Fail("unexpected ')'", line, col)
  ELSIF ch = "@" THEN ReadPosition(x)
  ELSIF IsDigit(ch) OR (ch = "-") & (pos + 1 < len) & IsDigit(text[pos + 1]) THEN
    ReadInteger(x)
  ELSE ReadSymbol(x)
  END;
  IF error[0] # 0X THEN RETURN NIL END;
  RETURN x
END ReadExpr;

(* Read the file name, which must hold exactly one expression. On failure,
   returns NIL and sets error, errLine and errCol. *)
PROCEDURE Read*(name: ARRAY OF CHAR): Node;
  VAR f: Files.File; r: Files.Rider; x: Node;
BEGIN
  error[0] := 0X; errLine := 0; errCol := 0;
  f := Files.Old(name);
  IF f = NIL THEN Fail("cannot open file", 0, 0); RETURN NIL END;
  len := Files.Length(f);
  NEW(text, len + 1);
  Files.Set(r, f, 0);
  Files.ReadBytes(r, text^, len);
  text[len] := 0X;
  pos := 0; line := 1; col := 1;
  SkipBlank;
  IF pos >= len THEN Fail("no expression", line, col); RETURN NIL END;
  x := ReadExpr();
  IF x = NIL THEN RETURN NIL END;
  SkipBlank;
  IF pos < len THEN Fail("text after the end of the expression", line, col); RETURN NIL END;
  RETURN x
END Read;

(* ---- Writing ---- *)

(* Lists headed by the symbol head are written as blocks: the header holds the
   head and the next keep elements (keep < 0: all leading atoms), and each
   remaining element goes on its own line, indented two more spaces. *)
PROCEDURE Block*(head: ARRAY OF CHAR; keep: INTEGER);
BEGIN
  ASSERT(nblocks < MaxBlocks);
  COPY(head, blocks[nblocks].head); blocks[nblocks].keep := keep;
  INC(nblocks)
END Block;

(* The keep count of x's head if x is a block list, otherwise -2. *)
PROCEDURE BlockKeep(x: Node): INTEGER;
  VAR i: INTEGER;
BEGIN
  IF (x.kind = List) & (x.first # NIL) & (x.first.kind = Symbol) THEN
    FOR i := 0 TO nblocks - 1 DO
      IF blocks[i].head = x.first.name^ THEN RETURN blocks[i].keep END
    END
  END;
  RETURN -2
END BlockKeep;

PROCEDURE WriteInt(v: LONGINT);
  VAR buf: ARRAY 24 OF CHAR; i: INTEGER;
BEGIN
  (* MIN(LONGINT) has no positive counterpart to convert. *)
  IF v = MIN(LONGINT) THEN Out.String("-9223372036854775808"); RETURN END;
  IF v < 0 THEN Out.Char("-"); v := -v END;
  i := 0;
  REPEAT
    buf[i] := CHR(ORD("0") + SHORT(v MOD 10)); v := v DIV 10; INC(i)
  UNTIL v = 0;
  WHILE i > 0 DO DEC(i); Out.Char(buf[i]) END
END WriteInt;

PROCEDURE Indent(n: INTEGER);
BEGIN
  WHILE n > 0 DO Out.Char(" "); DEC(n) END
END Indent;

PROCEDURE WriteNode(x: Node; indent: INTEGER);
  VAR keep, k: INTEGER; e: Node;
BEGIN
  CASE x.kind OF
  | Symbol: Out.String(x.name^)
  | Integer: WriteInt(x.int)
  | Position: Out.Char("@"); WriteInt(x.pline); Out.Char(":"); WriteInt(x.pcol)
  | List:
    Out.Char("(");
    keep := BlockKeep(x);
    e := x.first;
    IF keep = -2 THEN
      WHILE e # NIL DO
        WriteNode(e, indent);
        IF e.next # NIL THEN Out.Char(" ") END;
        e := e.next
      END
    ELSE
      WriteNode(e, indent); e := e.next; (* the head *)
      k := 0;
      WHILE (e # NIL) & ((keep < 0) & (e.kind # List) OR (k < keep)) DO
        Out.Char(" "); WriteNode(e, indent); e := e.next; INC(k)
      END;
      WHILE e # NIL DO
        Out.Ln; Indent(indent + 2); WriteNode(e, indent + 2); e := e.next
      END
    END;
    Out.Char(")")
  ELSE HALT(20) (* every kind is handled above *)
  END
END WriteNode;

(* Write x in canonical form to standard output, with a final newline. *)
PROCEDURE Write*(x: Node);
BEGIN
  WriteNode(x, 0); Out.Ln; Out.Flush
END Write;

BEGIN
  nblocks := 0; error[0] := 0X
END Sexpr.
