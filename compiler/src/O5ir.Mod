MODULE O5ir; (* IR tool: reads an IR text file and writes it in canonical form. *)

(* By default the file is read as an IR module, so its shape is checked. With
   VERIFY the module is also verified, as the translation service does before
   translating. With SEXPR it is read only as an S-expression, which tests the
   text syntax on its own. Later this tool also converts between the text and
   binary forms. *)

IMPORT Modules, Platform, Report, Sexpr, Ir, IrText, Verify;

CONST
  Template = "FILE/A,SEXPR/S,VERIFY/S";
  RcError = 10;

VAR
  name, opt: ARRAY 256 OF CHAR;
  sexprOnly, verify: BOOLEAN;
  x: Sexpr.Node;
  m: Ir.Module;

PROCEDURE Usage;
BEGIN
  Report.Str("template: "); Report.Str(Template); Report.Ln;
  Platform.Exit(RcError)
END Usage;

(* Refuse with "refused: FILE:LINE:COL: msg" and exit. *)
PROCEDURE Refuse(line, col: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  Report.Str("refused: "); Report.Str(name);
  IF line > 0 THEN
    Report.Str(":"); Report.Int(line); Report.Str(":"); Report.Int(col)
  END;
  Report.Str(": "); Report.Str(msg); Report.Ln;
  Platform.Exit(RcError)
END Refuse;

BEGIN
  IF (Modules.ArgCount < 2) OR (Modules.ArgCount > 3) THEN
    Report.Refuse("o5ir", "expected one IR file"); Usage
  END;
  Modules.GetArg(1, name);
  sexprOnly := FALSE; verify := FALSE;
  IF Modules.ArgCount = 3 THEN
    Modules.GetArg(2, opt);
    IF opt = "SEXPR" THEN sexprOnly := TRUE
    ELSIF opt = "VERIFY" THEN verify := TRUE
    ELSE Report.Refuse("o5ir", "unknown argument"); Usage
    END
  END;
  x := Sexpr.Read(name);
  IF x = NIL THEN Refuse(Sexpr.errLine, Sexpr.errCol, Sexpr.error) END;
  IF sexprOnly THEN
    Sexpr.Write(x)
  ELSE
    m := IrText.Read(x);
    IF m = NIL THEN Refuse(IrText.errLine, IrText.errCol, IrText.error) END;
    IF verify & ~Verify.Module(m) THEN Refuse(0, 0, Verify.error) END;
    IrText.Write(m)
  END
END O5ir.
