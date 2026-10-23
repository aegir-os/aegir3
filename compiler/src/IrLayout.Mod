MODULE IrLayout; (* Canonical layout of the IR text form. *)

(* Registers the IR nodes that Sexpr writes as blocks: nodes holding statements
   or declarations put each of them on its own line. See specs/ir.md. *)

IMPORT Sexpr;

BEGIN
  Sexpr.Block("module", -1); (* (module Name *)
  Sexpr.Block("proc", -1);   (* (proc Name flags... *)
  Sexpr.Block("body", 0);
  Sexpr.Block("init", 0);
  Sexpr.Block("then", 0);
  Sexpr.Block("else", 0);
  Sexpr.Block("while", 1);   (* (while condition *)
  Sexpr.Block("if", 1)       (* (if condition *)
END IrLayout.
