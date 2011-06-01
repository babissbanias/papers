(* modules *) (* {{{ *)
open Format

module U = Util

(* }}} *)

type value = int
type variable = string

(* AST types shared by programs and automata (towards leaves) *) (* {{{ *)
type binop = Eq | Ne
type acop = Or | And

type 'a with_line = { ast : 'a; line : int }

type type_ =
  | Class of string
  | Bool
  | Unit
  | AnyType of type_ option ref (* used while typechecking Nondet *)

(* Expressions have no side-effects, so they don't include method calls. *)
type expression =
    Ac of acop * expression list
  | Bin of expression * binop * expression
  | Not of expression
  | Deref of expression * variable
  | Ref of variable
  | Literal of value option * type_ option ref

(* }}} *)
(* AST (types) only for programs. *) (* {{{ *)

type declaration =
  { declaration_type : type_
  ; declaration_variable : string }

type call_statement =
  { call_lhs : string option
  ; call_receiver : expression
  ; mutable call_class : string option
  ; call_method : string
  ; call_arguments : expression list }

type allocate_statement =
  { allocate_lhs : string
  ; mutable allocate_type : type_ option }

type statement =
    Return of expression
  | Assignment of string * expression
  | Call of call_statement
  | Allocate of allocate_statement
  | While of while_
  | If of expression * body

and while_ =
  { while_pre_body : body
  ; while_condition : expression
  ; while_post_body : body }

and body = Body of declaration list * statement with_line list

type method_ =
  { method_return_type : type_
  ; method_name : string
  ; method_formals : declaration list
  ; method_body : body }

type member =
    Field of declaration
  | Method of method_

type class_ = string * member list

(* }}} *)
(* AST (types) only for automata *) (* {{{ *)
module PropertyAst = struct

  (* Since there's another [expression], you're asking for trouble if you
     open this module. *)
  type expression =
      Constant of value
    | Pattern of variable option
    | Guard of variable

  let any = Pattern None (* short name, because it's used often *)

  type 'a label_data =
    | Call of 'a list  (* the first element is the receiver *)
    | Return of 'a * int (* second is argument count *)
    | Call_return of 'a * 'a list

  type 'a label =
    { label_method : string
    ; label_data : 'a label_data }

  type edge =
    { edge_source : string
    ; edge_target : string
    ; edge_label : expression label }

  type t =
    { message : string
    ; edges: edge list }

  (* utilities *) (* {{{ *)
  let labels_of_edge f e =
    let ls = match e.edge_label.label_data with
      | Call es -> es
      | Return (e, _) -> [e]
      | Call_return (e, es) -> e :: es in
    U.map_option f ls

  let get_guard = function
    | Guard x -> Some x
    | _ -> None

  let get_pattern = function
    | Pattern (Some x) -> Some x
    | _ -> None

  let guards e = labels_of_edge get_guard e
  let patterns e = labels_of_edge get_pattern e

  let arg_count = function
    | Call es | Call_return (_, es) -> List.length es
    | Return (_, n) -> n

  let mk_edge s t m ld =
    { edge_source = s
    ; edge_target = t
    ; edge_label =
      { label_method = m
      ; label_data = ld } }

  (* }}} *)
end
(* }}} *)
(* Root of AST, see common.mly. *) (* {{{ *)

type program =
  { program_globals : declaration list
  ; program_classes : class_ list
  ; program_main : body option
  ; program_properties : PropertyAst.t with_line list }

(* }}} *)
(* utilities *) (* {{{ *)

let ok_automaton =
  { PropertyAst.message =
      "internal error: ok_automaton should be happy with all programs"
  ; PropertyAst.edges = [] }

let mk_allocate v = Allocate { allocate_lhs = v; allocate_type = None }
let mk_call l r m a = Call
  { call_lhs = l
  ; call_receiver = r
  ; call_class = None
  ; call_method = m
  ; call_arguments = a }

let default_body line =
  Body ([], [{ ast = Return(Literal (None, ref None)); line = line }])
let empty_body = Body ([], [])

let rec pp_type ppf = function
  | Class n -> fprintf ppf "%s" n
  | Bool -> fprintf ppf "[Bool]"
  | Unit -> fprintf ppf "[Unit]"
  | AnyType {contents=t} -> fprintf ppf "<%a>" (U.pp_option pp_type) t

(* }}} *)
