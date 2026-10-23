MODULE Report; (* Diagnostics for the compiler, written to standard error. *)

IMPORT SYSTEM, Platform;

PROCEDURE Str*(s: ARRAY OF CHAR);
  VAR n: LONGINT; res: Platform.ErrorCode;
BEGIN
  n := 0;
  WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END;
  res := Platform.Write(Platform.StdErr, SYSTEM.ADR(s), n)
END Str;

PROCEDURE Char*(ch: CHAR);
  VAR s: ARRAY 2 OF CHAR;
BEGIN
  s[0] := ch; s[1] := 0X; Str(s)
END Char;

PROCEDURE Int*(n: LONGINT);
  VAR buf: ARRAY 24 OF CHAR; i: INTEGER;
BEGIN
  (* MIN(LONGINT) has no positive counterpart to convert. *)
  IF n = MIN(LONGINT) THEN Str("-9223372036854775808"); RETURN END;
  IF n < 0 THEN Char("-"); n := -n END;
  i := 0;
  REPEAT buf[i] := CHR(ORD("0") + SHORT(n MOD 10)); n := n DIV 10; INC(i) UNTIL n = 0;
  WHILE i > 0 DO DEC(i); Char(buf[i]) END
END Int;

PROCEDURE Ln*;
BEGIN Char(0AX)
END Ln;

(* Write "refused: <what>: <why>" and a newline. *)
PROCEDURE Refuse*(what, why: ARRAY OF CHAR);
BEGIN
  Str("refused: "); Str(what); Str(": "); Str(why); Ln
END Refuse;

END Report.
