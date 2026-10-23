MODULE Scan; (* Scanner for Oberon-5 source. *)

(* The lexical grammar of Oberon-2, with the Oberon-5 differences of
   specs/oberon.md: reserved words are lowercase, and source is UTF-8.

   For now identifiers are ASCII (letter {letter | digit}); UTF-8 is accepted
   and validated in strings and comments. Integer literals, decimal or
   hexadecimal (0FFH), must fit LONGINT. Real literals are recognized and kept
   as text; their values are computed when reals reach the IR.

   Positions are line and column, both from 1; columns count characters, not
   bytes. *)

IMPORT Files;

CONST
  (* Token kinds. *)
  Eof* = 0; Ident* = 1; Int* = 2; Real* = 3; Char* = 4; String* = 5;

  (* Operators and delimiters. *)
  Plus* = 10; Minus* = 11; Times* = 12; Slash* = 13; Not* = 14; And* = 15;
  Period* = 16; Comma* = 17; Semicolon* = 18; Bar* = 19;
  LParen* = 20; RParen* = 21; LBrak* = 22; RBrak* = 23; LBrace* = 24; RBrace* = 25;
  Becomes* = 26; Arrow* = 27; Eql* = 28; Neq* = 29; Lss* = 30; Leq* = 31;
  Gtr* = 32; Geq* = 33; Upto* = 34; Colon* = 35;

  (* Reserved words, in the order of keyword[]. *)
  FirstKeyword* = 40;
  Array* = 40; Begin* = 41; By* = 42; Case* = 43; Const* = 44; Div* = 45;
  Do* = 46; Else* = 47; Elsif* = 48; End* = 49; Exit* = 50; For* = 51;
  If* = 52; Import* = 53; In* = 54; Is* = 55; Loop* = 56; Mod* = 57;
  Module* = 58; Nil* = 59; Of* = 60; Or* = 61; Pointer* = 62;
  Procedure* = 63; Record* = 64; Repeat* = 65; Return* = 66; Then* = 67;
  To* = 68; Type* = 69; Until* = 70; Var* = 71; While* = 72; With* = 73;
  LastKeyword* = 73;

  MaxIdent* = 64;
  MaxError = 128;

TYPE
  Text* = POINTER TO ARRAY OF CHAR;

VAR
  (* The current token. *)
  sym*: INTEGER;
  line*, col*: INTEGER;
  id*: ARRAY MaxIdent OF CHAR;  (* Ident *)
  ival*: LONGINT;               (* Int, and Char's code point *)
  text*: Text;                  (* String's contents, Real's spelling *)

  (* Set when scanning fails; empty otherwise. Scanning then returns Eof. *)
  error*: ARRAY MaxError OF CHAR;
  errLine*, errCol*: INTEGER;

  keyword: ARRAY LastKeyword - FirstKeyword + 1, 12 OF CHAR;
  src: Text;
  len, pos: LONGINT;
  cline, ccol: INTEGER;  (* position of src[pos] *)

(* ---- Characters ---- *)

PROCEDURE Fail(msg: ARRAY OF CHAR; l, c: INTEGER);
BEGIN
  IF error[0] = 0X THEN COPY(msg, error); errLine := l; errCol := c END
END Fail;

PROCEDURE Ch(): CHAR;
BEGIN
  IF pos < len THEN RETURN src[pos] ELSE RETURN 0X END
END Ch;

PROCEDURE Peek(): CHAR;
BEGIN
  IF pos + 1 < len THEN RETURN src[pos + 1] ELSE RETURN 0X END
END Peek;

(* Advance one byte. UTF-8 continuation bytes do not advance the column. *)
PROCEDURE Advance;
BEGIN
  IF src[pos] = 0AX THEN INC(cline); ccol := 1
  ELSIF (ORD(src[pos]) < 80H) OR (ORD(src[pos]) >= 0C0H) THEN INC(ccol)
  END;
  INC(pos)
END Advance;

(* Advance over one UTF-8 encoded character, checking that it is well formed:
   no stray continuation bytes, no overlong forms, no surrogates, nothing above
   U+10FFFF. Returns FALSE after failing. *)
PROCEDURE AdvanceUtf8(): BOOLEAN;
  VAR b, n, i, lo, hi: INTEGER; l, c: INTEGER;
BEGIN
  l := cline; c := ccol;
  b := ORD(Ch());
  IF b < 80H THEN Advance; RETURN TRUE END;
  lo := 80H; hi := 0BFH;
  IF (b >= 0C2H) & (b <= 0DFH) THEN n := 1
  ELSIF (b >= 0E0H) & (b <= 0EFH) THEN
    n := 2;
    IF b = 0E0H THEN lo := 0A0H ELSIF b = 0EDH THEN hi := 9FH END
  ELSIF (b >= 0F0H) & (b <= 0F4H) THEN
    n := 3;
    IF b = 0F0H THEN lo := 90H ELSIF b = 0F4H THEN hi := 8FH END
  ELSE Fail("malformed UTF-8", l, c); RETURN FALSE
  END;
  Advance;
  FOR i := 1 TO n DO
    b := ORD(Ch());
    IF (pos >= len) OR (b < lo) OR (b > hi) THEN Fail("malformed UTF-8", l, c); RETURN FALSE END;
    lo := 80H; hi := 0BFH;
    Advance
  END;
  RETURN TRUE
END AdvanceUtf8;

PROCEDURE IsLetter(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch >= "a") & (ch <= "z") OR (ch >= "A") & (ch <= "Z")
END IsLetter;

PROCEDURE IsDigit(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch >= "0") & (ch <= "9")
END IsDigit;

PROCEDURE IsHexDigit(ch: CHAR): BOOLEAN;
BEGIN
  RETURN IsDigit(ch) OR (ch >= "A") & (ch <= "F")
END IsHexDigit;

(* ---- Tokens ---- *)

(* A comment, which may nest; pos is at its opening parenthesis. *)
PROCEDURE Comment;
  VAR depth, l, c: INTEGER;
BEGIN
  l := cline; c := ccol;
  Advance; Advance;
  depth := 1;
  WHILE depth > 0 DO
    IF pos >= len THEN Fail("comment is not closed", l, c); RETURN END;
    IF (Ch() = "(") & (Peek() = "*") THEN Advance; Advance; INC(depth)
    ELSIF (Ch() = "*") & (Peek() = ")") THEN Advance; Advance; DEC(depth)
    ELSIF ~AdvanceUtf8() THEN RETURN
    END
  END
END Comment;

PROCEDURE Identifier;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE IsLetter(Ch()) OR IsDigit(Ch()) DO
    IF i = MaxIdent - 1 THEN Fail("identifier is too long", line, col); RETURN END;
    id[i] := Ch(); INC(i); Advance
  END;
  id[i] := 0X;
  sym := Ident;
  i := 0;
  WHILE (i <= LastKeyword - FirstKeyword) & (keyword[i] # id) DO INC(i) END;
  IF i <= LastKeyword - FirstKeyword THEN sym := FirstKeyword + i END
END Identifier;

(* A string between quote characters q, which cannot contain q. *)
PROCEDURE Str(q: CHAR);
  VAR start, n, i: LONGINT;
BEGIN
  Advance;
  start := pos;
  WHILE Ch() # q DO
    IF (pos >= len) OR (Ch() = 0AX) THEN Fail("string is not closed", line, col); RETURN END;
    IF ~AdvanceUtf8() THEN RETURN END
  END;
  n := pos - start;
  NEW(text, n + 1);
  FOR i := 0 TO n - 1 DO text[i] := src[start + i] END;
  text[n] := 0X;
  Advance;
  sym := String
END Str;

(* Value of the digits src[start .. end-1] in base 10 or 16; FALSE if it does
   not fit LONGINT. Nothing here divides a negative number: VOC computes
   MIN(LONGINT) DIV 10 wrongly. *)
PROCEDURE Value(start, end: LONGINT; base: INTEGER; VAR v: LONGINT): BOOLEAN;
  VAR d: INTEGER; i: LONGINT;
BEGIN
  v := 0;
  FOR i := start TO end - 1 DO
    IF IsDigit(src[i]) THEN d := ORD(src[i]) - ORD("0")
    ELSE d := ORD(src[i]) - ORD("A") + 10
    END;
    IF v > (MAX(LONGINT) - d) DIV base THEN RETURN FALSE END;
    v := v * base + d
  END;
  RETURN TRUE
END Value;

(* A number: digit {hexDigit} ["H" | "X"], or a real. *)
PROCEDURE Number;
  VAR start, end, i: LONGINT;
BEGIN
  start := pos;
  WHILE IsHexDigit(Ch()) DO Advance END;
  end := pos;
  IF (Ch() = ".") & (Peek() # ".") THEN
    (* A real: digit {digit} "." {digit} [("E" | "D") ["+" | "-"] digit {digit}]. *)
    FOR i := start TO end - 1 DO
      IF ~IsDigit(src[i]) THEN Fail("malformed number", line, col); RETURN END
    END;
    Advance;
    WHILE IsDigit(Ch()) DO Advance END;
    IF (Ch() = "E") OR (Ch() = "D") THEN
      Advance;
      IF (Ch() = "+") OR (Ch() = "-") THEN Advance END;
      IF ~IsDigit(Ch()) THEN Fail("malformed number", line, col); RETURN END;
      WHILE IsDigit(Ch()) DO Advance END
    END;
    NEW(text, pos - start + 1);
    FOR i := start TO pos - 1 DO text[i - start] := src[i] END;
    text[pos - start] := 0X;
    sym := Real
  ELSIF (Ch() = "H") OR (Ch() = "X") THEN
    IF ~Value(start, end, 16, ival) THEN Fail("number is too large", line, col); RETURN END;
    IF Ch() = "H" THEN sym := Int
    ELSIF (ival > 10FFFFH) OR (ival >= 0D800H) & (ival <= 0DFFFH) THEN
      Fail("not a Unicode code point", line, col); RETURN
    ELSE sym := Char
    END;
    Advance
  ELSE
    FOR i := start TO end - 1 DO
      IF ~IsDigit(src[i]) THEN Fail("malformed number", line, col); RETURN END
    END;
    IF ~Value(start, end, 10, ival) THEN Fail("number is too large", line, col); RETURN END;
    sym := Int
  END;
  IF IsLetter(Ch()) OR IsDigit(Ch()) THEN Fail("malformed number", line, col) END
END Number;

(* Scan the next token into sym and its fields. *)
PROCEDURE Next*;
  VAR ch: CHAR;
BEGIN
  LOOP
    WHILE (pos < len) & ((Ch() = " ") OR (Ch() = 9X) OR (Ch() = 0AX) OR (Ch() = 0DX)) DO
      Advance
    END;
    IF (Ch() = "(") & (Peek() = "*") THEN Comment ELSE EXIT END;
    IF error[0] # 0X THEN EXIT END
  END;
  line := cline; col := ccol;
  IF error[0] # 0X THEN sym := Eof; RETURN END;
  IF pos >= len THEN sym := Eof; RETURN END;
  ch := Ch();
  IF IsLetter(ch) THEN Identifier
  ELSIF IsDigit(ch) THEN Number
  ELSIF (ch = 22X) OR (ch = "'") THEN Str(ch)
  ELSE
    Advance;
    CASE ch OF
    | "+": sym := Plus
    | "-": sym := Minus
    | "*": sym := Times
    | "/": sym := Slash
    | "~": sym := Not
    | "&": sym := And
    | ",": sym := Comma
    | ";": sym := Semicolon
    | "|": sym := Bar
    | "(": sym := LParen
    | ")": sym := RParen
    | "[": sym := LBrak
    | "]": sym := RBrak
    | "{": sym := LBrace
    | "}": sym := RBrace
    | "^": sym := Arrow
    | "=": sym := Eql
    | "#": sym := Neq
    | ".": IF Ch() = "." THEN Advance; sym := Upto ELSE sym := Period END
    | ":": IF Ch() = "=" THEN Advance; sym := Becomes ELSE sym := Colon END
    | "<": IF Ch() = "=" THEN Advance; sym := Leq ELSE sym := Lss END
    | ">": IF Ch() = "=" THEN Advance; sym := Geq ELSE sym := Gtr END
    ELSE Fail("unexpected character", line, col)
    END
  END;
  IF error[0] # 0X THEN sym := Eof END
END Next;

(* The spelling of token kind s, for messages and token dumps. *)
PROCEDURE Spelling*(s: INTEGER; VAR t: ARRAY OF CHAR);
BEGIN
  IF (s >= FirstKeyword) & (s <= LastKeyword) THEN COPY(keyword[s - FirstKeyword], t)
  ELSE
    CASE s OF
    | Eof: COPY("end of file", t)
    | Ident: COPY("ident", t)
    | Int: COPY("int", t)
    | Real: COPY("real", t)
    | Char: COPY("char", t)
    | String: COPY("string", t)
    | Plus: COPY("+", t)
    | Minus: COPY("-", t)
    | Times: COPY("*", t)
    | Slash: COPY("/", t)
    | Not: COPY("~", t)
    | And: COPY("&", t)
    | Period: COPY(".", t)
    | Comma: COPY(",", t)
    | Semicolon: COPY(";", t)
    | Bar: COPY("|", t)
    | LParen: COPY("(", t)
    | RParen: COPY(")", t)
    | LBrak: COPY("[", t)
    | RBrak: COPY("]", t)
    | LBrace: COPY("{", t)
    | RBrace: COPY("}", t)
    | Becomes: COPY(":=", t)
    | Arrow: COPY("^", t)
    | Eql: COPY("=", t)
    | Neq: COPY("#", t)
    | Lss: COPY("<", t)
    | Leq: COPY("<=", t)
    | Gtr: COPY(">", t)
    | Geq: COPY(">=", t)
    | Upto: COPY("..", t)
    | Colon: COPY(":", t)
    ELSE COPY("?", t)
    END
  END
END Spelling;

(* Open the source file name and scan its first token. On failure, returns
   FALSE and sets error. *)
PROCEDURE Open*(name: ARRAY OF CHAR): BOOLEAN;
  VAR f: Files.File; r: Files.Rider;
BEGIN
  error[0] := 0X; errLine := 0; errCol := 0;
  f := Files.Old(name);
  IF f = NIL THEN Fail("cannot open file", 0, 0); RETURN FALSE END;
  len := Files.Length(f);
  NEW(src, len + 1);
  Files.Set(r, f, 0);
  Files.ReadBytes(r, src^, len);
  src[len] := 0X;
  pos := 0; cline := 1; ccol := 1;
  Next;
  RETURN error[0] = 0X
END Open;

BEGIN
  keyword[Array - FirstKeyword] := "array"; keyword[Begin - FirstKeyword] := "begin";
  keyword[By - FirstKeyword] := "by"; keyword[Case - FirstKeyword] := "case";
  keyword[Const - FirstKeyword] := "const"; keyword[Div - FirstKeyword] := "div";
  keyword[Do - FirstKeyword] := "do"; keyword[Else - FirstKeyword] := "else";
  keyword[Elsif - FirstKeyword] := "elsif"; keyword[End - FirstKeyword] := "end";
  keyword[Exit - FirstKeyword] := "exit"; keyword[For - FirstKeyword] := "for";
  keyword[If - FirstKeyword] := "if"; keyword[Import - FirstKeyword] := "import";
  keyword[In - FirstKeyword] := "in"; keyword[Is - FirstKeyword] := "is";
  keyword[Loop - FirstKeyword] := "loop"; keyword[Mod - FirstKeyword] := "mod";
  keyword[Module - FirstKeyword] := "module"; keyword[Nil - FirstKeyword] := "nil";
  keyword[Of - FirstKeyword] := "of"; keyword[Or - FirstKeyword] := "or";
  keyword[Pointer - FirstKeyword] := "pointer"; keyword[Procedure - FirstKeyword] := "procedure";
  keyword[Record - FirstKeyword] := "record"; keyword[Repeat - FirstKeyword] := "repeat";
  keyword[Return - FirstKeyword] := "return"; keyword[Then - FirstKeyword] := "then";
  keyword[To - FirstKeyword] := "to"; keyword[Type - FirstKeyword] := "type";
  keyword[Until - FirstKeyword] := "until"; keyword[Var - FirstKeyword] := "var";
  keyword[While - FirstKeyword] := "while"; keyword[With - FirstKeyword] := "with";
  error[0] := 0X
END Scan.
