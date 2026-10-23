MODULE O5ir; (* IR tool: reads an IR text file and writes it in canonical form. *)

(* Later it also converts between the text and binary forms. *)

IMPORT Modules, Platform, Report, Sexpr, IrLayout;

CONST
  Template = "FILE/A";
  RcError = 10;

VAR
  name: ARRAY 256 OF CHAR;
  x: Sexpr.Node;

BEGIN
  IF Modules.ArgCount # 2 THEN
    Report.Refuse("o5ir", "expected one IR file");
    Report.Str("template: "); Report.Str(Template); Report.Ln;
    Platform.Exit(RcError)
  END;
  Modules.GetArg(1, name);
  x := Sexpr.Read(name);
  IF x = NIL THEN
    Report.Str("refused: "); Report.Str(name);
    IF Sexpr.errLine > 0 THEN
      Report.Str(":"); Report.Int(Sexpr.errLine);
      Report.Str(":"); Report.Int(Sexpr.errCol)
    END;
    Report.Str(": "); Report.Str(Sexpr.error); Report.Ln;
    Platform.Exit(RcError)
  END;
  Sexpr.Write(x)
END O5ir.
