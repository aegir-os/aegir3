MODULE O5c; (* Oberon-5 compiler driver. *)

(* Arguments follow the ReadArgs template below. Instead of compiling, TOKENS
   prints the source's tokens, one per line, for testing the scanner, and AST
   prints its syntax tree, for testing the parser. *)

IMPORT Modules, Platform, Out, Report, Scan, Ast, Parse;

CONST
  Template = "FILE/A,O/N,DEBUG/S,TOKENS/S,AST/S";

  (* Return codes, after AmigaDOS. *)
  RcError = 10;

VAR
  name, arg: ARRAY 256 OF CHAR;
  tokens, ast: BOOLEAN;
  m: Ast.Node;
  i: INTEGER;

PROCEDURE Usage;
BEGIN
  Report.Str("template: "); Report.Str(Template); Report.Ln;
  Platform.Exit(RcError)
END Usage;

(* Refuse with "refused: FILE:LINE:COL: msg" and exit. *)
PROCEDURE Refuse(line, col: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  Out.Flush;
  Report.Str("refused: "); Report.Str(name);
  IF line > 0 THEN
    Report.Str(":"); Report.Int(line); Report.Str(":"); Report.Int(col)
  END;
  Report.Str(": "); Report.Str(msg); Report.Ln;
  Platform.Exit(RcError)
END Refuse;

PROCEDURE DumpTokens;
  VAR s: ARRAY 16 OF CHAR;
BEGIN
  LOOP
    Out.Int(Scan.line, 0); Out.Char(":"); Out.Int(Scan.col, 0); Out.Char(" ");
    Scan.Spelling(Scan.sym, s); Out.String(s);
    CASE Scan.sym OF
    | Scan.Ident: Out.Char(" "); Out.String(Scan.id)
    | Scan.Int, Scan.Char: Out.Char(" "); Out.Int(Scan.ival, 0)
    | Scan.Real: Out.Char(" "); Out.String(Scan.text^)
    | Scan.String: Out.String(' "'); Out.String(Scan.text^); Out.Char('"')
    ELSE
    END;
    Out.Ln;
    IF Scan.sym = Scan.Eof THEN EXIT END;
    Scan.Next;
    IF Scan.error[0] # 0X THEN Refuse(Scan.errLine, Scan.errCol, Scan.error) END
  END;
  Out.Flush
END DumpTokens;

BEGIN
  IF Modules.ArgCount < 2 THEN
    Report.Refuse("o5c", "no source file"); Usage
  END;
  Modules.GetArg(1, name);
  tokens := FALSE; ast := FALSE;
  FOR i := 2 TO Modules.ArgCount - 1 DO
    Modules.GetArg(i, arg);
    IF arg = "TOKENS" THEN tokens := TRUE
    ELSIF arg = "AST" THEN ast := TRUE
    ELSE Report.Refuse("o5c", "unknown or unsupported argument"); Usage
    END
  END;
  IF ~Scan.Open(name) THEN Refuse(Scan.errLine, Scan.errCol, Scan.error) END;
  IF tokens THEN DumpTokens
  ELSIF ast THEN
    m := Parse.Module();
    IF Scan.error[0] # 0X THEN Refuse(Scan.errLine, Scan.errCol, Scan.error) END;
    IF m = NIL THEN Refuse(Parse.errLine, Parse.errCol, Parse.error) END;
    Ast.Dump(m)
  ELSE Report.Refuse("o5c", "compiling is not implemented yet"); Platform.Exit(RcError)
  END
END O5c.
