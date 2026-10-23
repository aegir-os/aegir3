MODULE O5c; (* Oberon-5 compiler driver. *)

IMPORT Modules, Platform, Report;

CONST
  (* Arguments, as a ReadArgs template. *)
  Template = "FILE/A,O/N,DEBUG/S";

  (* Return codes, after AmigaDOS. *)
  RcOk = 0;
  RcError = 10;

BEGIN
  IF Modules.ArgCount < 2 THEN
    Report.Refuse("o5c", "no source file");
    Report.Str("template: "); Report.Str(Template); Report.Ln;
    Platform.Exit(RcError)
  END;
  Report.Refuse("o5c", "compiling is not implemented yet");
  Platform.Exit(RcError)
END O5c.
