(* modules *) (* {{{ *)
open Debug
open Format
open Util.Operators

module B = BaristaLibrary
module BA = B.HighClass.HighAttribute
module BC = B.HighClass
module BI = B.HighClass.HighInstruction
module BM = B.HighClass.HighMethod
module PA = PropAst
module SA = SoolAst
module U = Util

(* }}} *)
(* globals *) (* {{{ *)
let out_dir = ref "out"

(* }}} *)
(* used to communicate between conversion and instrumentation *) (* {{{ *)
type method_ =  (* TODO: Use [PropAst.event_tag] instead? *)
  { method_name : string
  ; method_arity : int }

(* }}} *)
(* representation of automata in Java *) (* {{{ *)

(*
  The instrumenter has three phases:
    - convert the automaton to an intermediate representation
    - instrument the bytecode
    - emit the Java representation of the automaton
  A pattern like "c.m()" in the property matches method m in all classes that
  extend c (including c itself). For efficiency, the Java automaton does not
  know anything about inheritance. SA.While the bytecode is instrumented all the
  methods m in classes extending c get unique identifiers and the pattern
  "c.m()" is mapped to the set of those identifiers.

  The (first) conversion
    - goes from edge list to adjacency list
    - glues all input properties into one
    - changes the vertex representation from strings to integers
    - changes automaton variable representation from strings to integers
    - normalizes method patterns (by processing "using prefix", ... )
    - collects all patterns
  During printing a bit more processing is needed to go to the Java
  representation, but only very simple stuff.
 *)

(* shorthands for old types, those that come from prop.mly *)
type property = (string, string) PA.t
type tag_guard = Str.regexp PA.tag_guard

(* shorthands for new types, those used in Java *)
type tag = int
type vertex = int
type variable = int
type value = string (* Java literal *)

type transition =
  { steps : (Str.regexp, variable, value) PA.label list
  ; target : vertex }

type vertex_data =
  { vertex_property : property
  ; vertex_name : PA.vertex
  ; outgoing_transitions : transition list }

type automaton =
  { vertices : vertex_data array
  ; observables : (property, tag_guard) Hashtbl.t
  ; pattern_tags : (tag_guard, tag list) Hashtbl.t }
  (* The keys of [pattern_tags] are filled in during the initial conversion,
    but the values (the tag list) is filled in while the code is being
    instrumented. *)

(* }}} *)
(* small functions that help handling automata *) (* {{{ *)
let to_ints xs =
  let h = Hashtbl.create 101 in
  let c = ref (-1) in
  let f x = if not (Hashtbl.mem h x) then (incr c; Hashtbl.add h x !c) in
  List.iter f xs; h

let inverse_index f h =
  let r = Array.make (Hashtbl.length h) None in
  let one k v = assert (r.(v) = None); r.(v) <- Some (f k) in
  Hashtbl.iter one h;
  Array.map U.from_some r

let get_properties x =
  x.vertices >> Array.map (function {vertex_property=p;_} -> p) >> Array.to_list

let get_vertices p =
  let f acc t = t.PA.source :: t.PA.target :: acc in
  "start" :: "error" :: List.fold_left f [] p.PA.transitions

let get_variables p =
  let f = function PA.Variable (v, _) -> Some v | _ -> None in
  U.map_option f (PA.get_value_guards p)

(* }}} *)
(* pretty printing to Java *) (* {{{ *)

let array_foldi f z xs =
  let r = ref z in
  for i = 0 to Array.length xs - 1 do r := f !r i xs.(i) done;
  !r

let starts x =
  let f ks k = function
    | {vertex_name="start";_} -> k :: ks
    | _ -> ks in
  array_foldi f [] x.vertices

let escape_java_string s = s (* TODO *)

let errors x =
  let f = function
    | {vertex_name="error"; vertex_property={PA.message=e;_};_} ->
        "\"" ^ escape_java_string e ^ "\""
    | _ -> "null" in
  x.vertices >> Array.map f >> Array.to_list

let compute_pov x =
  let iop = to_ints (get_properties x) in
    Array.map (fun v -> Hashtbl.find iop v.vertex_property) x.vertices

let pp_array pe ppf a =
  let l = Array.length a in
  if l > 0 then fprintf ppf "@\n%a" pe (0, a.(0));
  for i = 1 to l - 1 do fprintf ppf ",@\n%a" pe (i, a.(i)) done

let pp_h_list pe f xs = U.pp_list ", " pe f xs

let rec pp_v_list pe ppf = function
  | [] -> ()
  | [x] -> fprintf ppf "@\n%a" pe x
  | x :: xs -> fprintf ppf "@\n%a,%a" pe x (pp_v_list pe) xs

let pp_int f x = fprintf f "%d" x
let pp_string f x = fprintf f "%s" x

let pp_int_list f xs =
  fprintf f "@[<2>new int[]{%a}@]" (pp_h_list pp_int) xs

let pp_int_list_display n f xs =
  let l = List.length xs in
  if l > n then fprintf f "@[<2>new int[]{%d elements (more than %d)}@]" l n
  else pp_int_list f xs

let pp_pattern tags f p = pp_int_list f (Hashtbl.find tags p)

let pp_value_guard f = function
  | PA.Variable (v, i) -> fprintf f "new StoreEqualityGuard(%d, %d)" i v
  | PA.Constant (c, i) -> fprintf f "new ConstantEqualityGuard(%d, %s)" i c

let pp_assignment f (x, i) =
  fprintf f "new Action.Assignment(%d, %d)" x i

let pp_condition f a =
  fprintf f "@[<2>new AndGuard(new Guard[]{%a})@]" (pp_h_list pp_value_guard) a

let pp_guard tags f {PA.tag_guard=p; PA.value_guards=cs} =
  fprintf f "@[<2>%a@],@\n@[<2>%a@]" (pp_pattern tags) p pp_condition cs

let pp_action f a =
  fprintf f "@[<2>new Action(new Action.Assignment[]{%a})@]" (pp_h_list pp_assignment) a

let pp_step tags f {PA.guard=g; PA.action=a} =
  fprintf f "@[<2>new TransitionStep(@\n%a,@\n%a)@]" (pp_guard tags) g pp_action a

let pp_transition tags f {steps=ss;target=t} =
  fprintf f "@[<2>new Transition(@\n@[<2>new TransitionStep[]{%a@]@\n}, %d)@]" (pp_v_list (pp_step tags)) ss t

let pp_vertex tags f (vi, {outgoing_transitions=ts;_}) =
  fprintf f "@[<2>new Transition[]{ /* from %d */%a@]@\n}"
    vi
    (pp_v_list (pp_transition tags)) ts

let pp_automaton f x =
  let pov = compute_pov x in
  let obs_p p = Hashtbl.find x.pattern_tags (Hashtbl.find x.observables p) in
  let obs_tags = List.map obs_p (U.unique (get_properties x)) in
  fprintf f "package topl;@\n@\n";
  fprintf f "import static topl.Checker.*;@\n@\n";
  fprintf f "@[<2>public class Property {@\n";
  fprintf f   "@[<2>public static Checker checker = new Checker(new Automaton(@\n";
  fprintf f     "/* start nodes, one for each property */@\n";
  fprintf f     "%a,@\n" pp_int_list (starts x);
  fprintf f     "/* error messages, one non-null for each property */@\n";
  fprintf f     "@[<2>new String[]{%a}@],@\n" (pp_h_list pp_string) (errors x);
  fprintf f     "/* transitions as an adjacency list */@\n";
  fprintf f     "@[<2>new Transition[][]{%a@]@\n},@\n" (pp_array (pp_vertex x.pattern_tags)) x.vertices;
  fprintf f     "/* property the vertex comes from */@\n";
  fprintf f     "%a,@\n" pp_int_list (Array.to_list pov);
  fprintf f     "/* events each property is observing */@\n";
  fprintf f     "@[<2>new int[][]{%a@]@\n}" (pp_v_list pp_int_list) obs_tags;
  fprintf f   "@]));@\n";
  fprintf f "@]@\n}@\n"

(* }}} *)
(* pretty printing of Java representation in a raw text file *) (* {{{ *)
(* NOTE: The prefix pq comes after pp; it means nothing otherwise. *)
let pq_string ios f s = pp_int f (Hashtbl.find ios s)
let pq_list pe f x =
  fprintf f "@[<2>%d@ %a@]" (List.length x) (U.pp_list " " pe) x
let pq_array pe f x = pq_list pe f (Array.to_list x)

let pq_value_guard ioc f = function
  | PA.Variable (v, i) -> fprintf f "0 %d %d" i v
  | PA.Constant (c, i) -> fprintf f "1 %d %a" i (pq_string ioc) c

let pq_pattern tags f p =
  fprintf f "%a" (pq_list pp_int) (Hashtbl.find tags p)

let pq_condition ioc = pq_list (pq_value_guard ioc)

let pq_assignment f (x, i) =
  fprintf f "%d %d" x i

let pq_guard tags ioc f { PA.tag_guard = p; PA.value_guards = cs } =
  fprintf f "%a %a" (pq_pattern tags) p (pq_condition ioc) cs

let pq_action = pq_list pq_assignment

let pq_step tags ioc f { PA.guard = g; PA.action = a } =
  fprintf f "%a %a" (pq_guard tags ioc) g pq_action a

let pq_transition tags ioc f { steps = ss; target = t } =
  fprintf f "%a %d" (pq_list (pq_step tags ioc)) ss t

let pq_vertex tags ioc f v =
  fprintf f "%a" (pq_list (pq_transition tags ioc)) v.outgoing_transitions

let pq_automaton ioc f x =
  let pov = compute_pov x in
  let obs_p p = Hashtbl.find x.pattern_tags (Hashtbl.find x.observables p) in
  let obs_tags = List.map obs_p (U.unique (get_properties x)) in
  fprintf f "%a@\n" (pq_list pp_int) (starts x);
  fprintf f "%a@\n" (pq_list (pq_string ioc)) (errors x);
  fprintf f "%a@\n" (pq_array (pq_vertex x.pattern_tags ioc)) x.vertices;
  fprintf f "%a@\n" (pq_array pp_int) pov;
  fprintf f "%a@\n" (pq_list (pq_list pp_int)) obs_tags

let index_constants p =
  let r = Hashtbl.create 13 in (* maps constants to their index *)
  let i = ref (-1) in
  let add c = if not (Hashtbl.mem r c) then Hashtbl.add r c (incr i; !i) in
  let value_guard = function PA.Constant (c, _) -> add c | _ -> () in
  let event_guard g = List.iter value_guard g.PA.value_guards in
  let label l = event_guard l.PA.guard in
  let transition t = List.iter label t.steps in
  let vertex_data v = List.iter transition v.outgoing_transitions in
  let automaton a = Array.iter vertex_data a.vertices in
  automaton p;
  List.iter add (errors p);
  r

let pq_constants j constants =
  let constants = Array.to_list constants in
  fprintf j "@[";
  fprintf j "package topl;@\n";
  fprintf j "@[<2>public class Property {";
  fprintf j "@\n@[<2>public static final Object[] constants =@ ";
  fprintf j   "new Object[]{%a@]};" (pp_v_list pp_string) constants;
  fprintf j "@\n@[<2>public static final Checker checker =@ ";
  fprintf j   "Checker.parseAutomaton(\"Property.text\",@ constants);@]";
  fprintf j "@]@\n}@]"

let generate_checkers out_dir p =
  let o n =
    let c = open_out (Filename.concat out_dir ("Property." ^ n)) in
    let f = formatter_of_out_channel c in
    (c, f) in
  let (jc, j), (tc, t) = o "java", o "text" in
  let ioc = index_constants p in
  let coi = inverse_index (fun x -> x) ioc in
  pq_constants j coi;
  pq_automaton ioc t p;
  List.iter close_out_noerr [jc; tc]

(* }}} *)
(* conversion to Java representation *) (* {{{ *)

let index_for_var ifv v =
  try
    Hashtbl.find ifv v
  with Not_found ->
    let i = Hashtbl.length ifv in
      Hashtbl.replace ifv v i; i

let transform_tag_guard ptags tg =
  Hashtbl.replace ptags tg []; tg

let transform_value_guard ifv = function
  | PA.Variable (v, i) -> PA.Variable (index_for_var ifv v, i)
  | PA.Constant (c, i) -> PA.Constant (c, i)

let transform_guard ifv ptags {PA.tag_guard=tg; PA.value_guards=vgs} =
  { PA.tag_guard = transform_tag_guard ptags tg
  ; PA.value_guards = List.map (transform_value_guard ifv) vgs }

let transform_condition ifv (store_var, event_index) =
  let store_index = index_for_var ifv store_var in
    (store_index, event_index)

let transform_action ifv a = List.map (transform_condition ifv) a

let transform_label ifv ptags {PA.guard=g; PA.action=a} =
  { PA.guard = transform_guard ifv ptags g
  ; PA.action = transform_action ifv a }

let transform_properties ps =
  let vs p = p >> get_vertices >> List.map (fun v -> (p, v)) in
  let iov = to_ints (ps >>= vs) in
  let mk_vd (p, v) =
    { vertex_property = p
    ; vertex_name = v
    ; outgoing_transitions = [] } in
  let full_p =
    { vertices = inverse_index mk_vd iov
    ; observables = Hashtbl.create 13
    ; pattern_tags = Hashtbl.create 13 } in
  let add_obs_tags p =
    let obs_tag =
      { PA.event_type = None
      ; PA.method_name = p.PA.observable
      ; PA.method_arity = None } in
    Hashtbl.replace full_p.pattern_tags obs_tag [];
    Hashtbl.replace full_p.observables p obs_tag in
  List.iter add_obs_tags ps;
  let add_transition vi t =
    let ts = full_p.vertices.(vi).outgoing_transitions in
    full_p.vertices.(vi) <- {full_p.vertices.(vi) with outgoing_transitions = t :: ts} in
  let ifv = Hashtbl.create 101 in (* variable, string -> integer *)
  let pe p {PA.source=s;PA.target=t;PA.labels=ls} =
    let s = Hashtbl.find iov (p, s) in
    let t = Hashtbl.find iov (p, t) in
    let ls = List.map (transform_label ifv full_p.pattern_tags) ls in
    add_transition s {steps=ls; target=t} in
  List.iter (fun p -> List.iter (pe p) p.PA.transitions) ps;
  full_p

(* }}} *)
(* bytecode instrumentation *) (* {{{ *)

(* InstrumentationMap *) (* {{{ *)

module InstrumentationMap : sig
  type t
  val insert : t -> int -> BI.t list -> t
  val apply : t -> BI.t list -> BI.t list
  val size : t -> int -> int -> int
end
= struct
  type t = (int * int * BI.t list) list
  let code_size _ = failwith "todo"
  let insert t pos code = (pos, code_size code, code) :: t
  let size t a b =
    let f acc (pos, sz, _) = acc + (if a <= pos && pos < b then sz else 0) in
    List.fold_left f 0 t
  let apply t code =
    let cnt = ref (-1) in
    let code = List.sort compare (List.concat (
      (List.map (fun x -> incr cnt; (!cnt, 0, x)) code) ::
      (List.map (fun (i, _, xs) ->
        cnt := 0; List.map (fun x -> incr cnt; (i, !cnt, x)) xs) t))) in
    List.map (fun (_, _, x) -> x) code
end

(* }}} *)

let string_of_method_name mn =
  B.Utils.UTF8.to_string (B.Name.utf8_for_method mn)

let mk_method mn ma =
  { method_name = string_of_method_name mn
  ; method_arity = ma }

let utf8 = B.Utils.UTF8.of_string
let utf8_for_class x = B.Name.make_for_class_from_external (utf8 x)
let utf8_for_field x = B.Name.make_for_field (utf8 x)
let utf8_for_method x = B.Name.make_for_method (utf8 x)
let java_lang_Object = utf8_for_class "java.lang.Object"
let java_lang_System = utf8_for_class "java.lang.System"
let java_lang_String = utf8_for_class "java.lang.String"
let java_io_PrintStream = utf8_for_class "java.io.PrintStream"
let out = utf8_for_field "out"
let println = utf8_for_method "println"
let event = utf8_for_class "topl.Checker$Event"
(* let event_init = utf8_for_method "topl.Checker$Event.<init>" *)
let init = utf8_for_method "<init>"
let property = utf8_for_class "topl.Property"
let property_checker = utf8_for_field "checker"
let checker = utf8_for_class "topl.Checker"
let check = utf8_for_method "check"

(* bytecode generating helpers *) (* {{{ *)
let bc_print_utf8 us = [
  BI.GETSTATIC (java_lang_System, out, `Class java_io_PrintStream);
  BI.LDC (`String us);
  BI.INVOKEVIRTUAL (`Class_or_interface java_io_PrintStream,
			     println,
			     ([`Class java_lang_String], `Void));
]
let bc_print s = bc_print_utf8 (utf8 s)
let bc_print_par p = bc_print_utf8 (p.B.Signature.identifier)

let bc_push = function
  | 0 -> BI.ICONST_0
  | 1 -> BI.ICONST_1
  | 2 -> BI.ICONST_2
  | 3 -> BI.ICONST_3
  | 4 -> BI.ICONST_4
  | 5 -> BI.ICONST_5
  | i -> BI.LDC (`Int (Int32.of_int i))

let bc_new_object_array size =
  [
    bc_push size;
    BI.ANEWARRAY (`Class_or_interface java_lang_Object)
  ]

let bc_box = function
  | `Class _ | `Array _ -> []
  | t ->
      let c = utf8_for_class ("java.lang." ^ (match t with
        | `Boolean -> "Boolean"
        | `Byte -> "Byte"
        | `Char -> "Character"
        | `Double -> "Double"
        | `Float -> "Float"
        | `Int -> "Integer"
        | `Long -> "Long"
        | `Short -> "Short"
        | _ -> failwith "foo"))
        in
      [BI.INVOKESTATIC
          (c,
	  utf8_for_method "valueOf",
          ([t], `Class c))]

let bc_load i = function
  | `Class _ | `Array _ -> BI.ALOAD i
  | `Boolean -> BI.ILOAD i
  | `Byte -> BI.ILOAD i
  | `Char -> BI.ILOAD i
  | `Double -> BI.DLOAD i
  | `Float -> BI.FLOAD i
  | `Int -> BI.ILOAD i
  | `Long -> BI.LLOAD i
  | `Short -> BI.ILOAD i

let bc_array_set index t =
  [
    BI.DUP;
    bc_push index;
    bc_load index t
  ] @
    bc_box t @
  [
    BI.AASTORE
  ]

let bc_new_event id =
  [
    BI.NEW event;
    BI.DUP_X1;
    BI.SWAP;
    bc_push id;
    BI.SWAP;
    BI.INVOKESPECIAL (event,
			       init,
			       ([`Int; `Array (`Class java_lang_Object)], `Void)
			      )
  ]

let bc_check =
  [
    BI.GETSTATIC (property, property_checker, `Class checker);
    BI.SWAP;
    BI.INVOKEVIRTUAL (`Class_or_interface checker,
			       check,
			       ([`Class event], `Void)
			      )
  ]

(* }}} *)

let does_method_match
  ({ method_name=mn; method_arity=ma }, mt)
  { PA.event_type=t; PA.method_name=re; PA.method_arity=a }
=
  let ba = U.option true ((=) ma) a in
  let bt = U.option true ((=) mt) t in
  let bn = Str.string_match re mn 0 in
  if ba && bt && bn && log log_cp then fprintf logf "@[match %s@." mn;
(*    printf "@[(%s, %d) matches: mn: %b, ma: %b, mt: %b@." mn ma bn ba bt; *)
    ba && bt && bn

let get_tag x =
  let cnt = ref (-1) in fun t (mns, ma) ->
  let fp s p1 p2 acc =
    let p = s (p1, p2) in
    let cm mn = does_method_match ({method_name=mn; method_arity=ma}, t) p in
    if List.exists cm mns then p :: acc else acc in
  if Hashtbl.fold (fp snd) x.observables [] <> [] then begin
    match Hashtbl.fold (fp fst) x.pattern_tags [] with
      | [] -> None
      | ps ->
          incr cnt;
          let at p =
            let ts = Hashtbl.find x.pattern_tags p in
            (* printf "added tag %d\n" !cnt; *)
            Hashtbl.replace x.pattern_tags p (!cnt :: ts) in
          List.iter at ps;
          Some !cnt
  end else None

let bc_send_event id param_types is_static =
  (* this is ugly, it should just receive the arity *)
  let dummy = checker in
  let params = if is_static then param_types else (`Class dummy)::param_types in
  let fold (instructions, i) t =
    bc_array_set i t :: instructions, succ i in
  let (inst_lists, _) = List.fold_left fold ([], 0) params in
  let instructions = List.flatten (List.rev inst_lists) in
    (bc_new_object_array (List.length params)) @
    instructions @
    (bc_new_event id) @
    bc_check

let bc_send_return_event id return_type =
  let bc_save_return_value,
      return_arity,
      bc_store_return_value
   = match return_type with
    | `Void -> [], 0, []
    | t -> [BI.DUP],
           1,
           [BI.DUP_X1;
            BI.SWAP;
            bc_push 0;
            BI.SWAP] @
            (bc_box (B.Descriptor.filter_void
                B.Descriptor.Invalid_method_parameter_type t)) @
            [BI.AASTORE] in
  bc_save_return_value @
  (bc_new_object_array return_arity) @
  bc_store_return_value @
  (bc_new_event id) @
  bc_check

(* Taken from disassembler.ml *)
let (++) = B.UTF8Impl.(++)
let space = B.UTF8Impl.of_string " "
let comma = B.UTF8Impl.of_string ","
let opening_parenthesis = B.UTF8Impl.of_string "("
let closing_parenthesis = B.UTF8Impl.of_string ")"
let utf8_of_method_desc name desc =
  let params, return = desc in
  (B.Descriptor.external_utf8_of_java_type return)
    ++ space
    ++ (B.Name.utf8_for_method name)
    ++ opening_parenthesis
    ++ (B.UTF8Impl.concat_sep_map comma B.Descriptor.external_utf8_of_java_type (params :> B.Descriptor.java_type list))
    ++ closing_parenthesis

let put_labels_on =
  List.map (fun x -> (BI.fresh_label (), x))

let rec add_return_code return_code = function
  | [] -> []
  | ((_, BI.ARETURN) as r) :: xs
  | ((_, BI.DRETURN) as r) :: xs
  | ((_, BI.FRETURN) as r) :: xs
  | ((_, BI.IRETURN) as r) :: xs
  | ((_, BI.LRETURN) as r) :: xs
  | ((_, BI.RETURN) as r) :: xs ->
      put_labels_on return_code
        @ (r :: (add_return_code return_code xs))
  (* do not instrument RET or WIDERET *)
  | x :: xs -> x :: (add_return_code return_code xs)

let instrument_code call_id return_id param_types return_types is_static code =
  let bc_send_call_event = match call_id with
    | None -> []
    | Some id -> bc_send_event id param_types is_static in
  let bc_send_ret_event = match return_id with
    | None -> []
    | Some id -> bc_send_return_event id return_types in
(*
  (bc_print (method_name ^ " : ")) @
  (bc_print_utf8 (utf8_of_method_desc method_name param_types)) @
*)
  put_labels_on bc_send_call_event @
  (add_return_code bc_send_ret_event code)

let has_static_flag flags =
  let is_static_flag = function
    | `Static -> true
    | _ -> false in
  List.exists is_static_flag flags

let rec get_ancestors h m c =
  try
    let (ms, parents) = Hashtbl.find h c in
    let here = if List.mem m ms then [c] else [] in
    here @ (parents >>= get_ancestors h m)
  with Not_found -> []

let get_overrides h c ({method_name=n; method_arity=a} as m) =
  let ancestors = get_ancestors h m c in
  let uts = B.Utils.UTF8.to_string in
  let cts c = uts (B.Name.external_utf8_for_class c) in
  let qualify c =  (cts c) ^ "." ^ n in
  (List.map qualify ancestors, a)

let raise_stack n x =
  B.Utils.u2 ((x : B.Utils.u2 :> int) + n)

let not_debug : BA.code_attribute -> bool = function
  | `LineNumberTable _
  | `LocalVariableTable _ -> false
  | _ -> true

let remove_debug =
  let rm_c c = { c with BA.attributes = List.filter not_debug c.BA.attributes } in
  let rm_a : BA.for_method -> BA.for_method = function
    | `Code c -> `Code (rm_c c)
    | x -> x in
  let rm_mr mr = { mr with BM.attributes      = List.map rm_a mr.BM.attributes } in
  let rm_mc mc = { mc with BM.cstr_attributes = List.map rm_a mc.BM.cstr_attributes } in
  let rm_mi mi = { mi with BM.init_attributes = List.map rm_a mi.BM.init_attributes } in
  function
    | BM.Regular mr     -> BM.Regular (rm_mr mr)
    | BM.Constructor mc -> BM.Constructor (rm_mc mc)
    | BM.Initializer mi -> BM.Initializer (rm_mi mi)

let instrument_method get_tag h c = function
  | BM.Regular r as m -> begin
      (* printf "Found regular method %s\n" (B.Utils.UTF8.to_string (B.Name.utf8_for_method r.BM.name)); *)
      let param_types, return_types = r.BM.descriptor in
      let is_static = has_static_flag r.BM.flags in
      let nr_params = List.length param_types + if is_static then 0 else 1 in
      let overrides =
        get_overrides h c (mk_method r.BM.name nr_params) in
      (* printf "  number of overrides: %d\n" (List.length (fst overrides)); *)
      let call_id = get_tag PA.Call overrides in
      let return_id = get_tag PA.Return overrides in
	match call_id, return_id with
	  | None, None -> remove_debug m
	  | _ -> begin
	      let inst_code = instrument_code call_id return_id param_types return_types is_static in
	      let inst_attrs = function
		| `Code code ->
		    let new_instructions = inst_code code.BA.code in
                    let new_attributes = List.filter not_debug code.BA.attributes in
		    let instrumented_code =
		      { code with
                        BA.code = new_instructions
                      ; BA.attributes = new_attributes } in
		    `Code instrumented_code
		| a -> a in
	      let instrumented_attributes = List.map inst_attrs r.BM.attributes in
	      BM.Regular {r with BM.attributes = instrumented_attributes}
          end
    end
  | m -> remove_debug m

let pp_class f c =
    fprintf f "@[%s@]" (B.Utils.UTF8.to_string (B.Name.internal_utf8_for_class c.BC.name))

let instrument_class get_tags h c =
  if log log_cp then fprintf logf "@[instrument %a@]" pp_class c;
  let instrumented_methods = List.map (instrument_method get_tags h c.BC.name) c.BC.methods in
  if log log_cp then fprintf logf "@[...done@.";
    {c with BC.methods = instrumented_methods}

let compute_inheritance in_dir =
  let h = Hashtbl.create 101 in
  let record_class c =
    let name = c.BC.name in
    let fold mns = function
      | BM.Regular r ->
	  let is_static = has_static_flag r.BM.flags in
	  let (ps, _) = r.BM.descriptor in (* return is not used *)
	  let nr_params = List.length ps + if is_static then 0 else 1 in
          mk_method r.BM.name nr_params :: mns
      | _ -> mns in
    let method_names = List.fold_left fold [] c.BC.methods in
    let parents = match c.BC.extends with
      | None -> c.BC.implements
      | Some e -> e::c.BC.implements in
    Hashtbl.replace h name (method_names, parents)
  in
    ClassMapper.iter in_dir record_class;
  h

(* }}} *)
(* main *) (* {{{ *)

let read_properties fs =
  let e p = List.map (fun x -> x.PA.ast) p.SA.program_properties in
  fs >> List.map Helper.parse >>= e

let () =
  try
    let fs = ref [] in
    let in_dir = ref Filename.current_dir_name in
    let out_dir = ref (Filename.concat Filename.temp_dir_name "out") in
    Arg.parse ["-i", Arg.Set_string in_dir, "input directory";
               "-o", Arg.Set_string out_dir, "output directory"]
              (fun x -> fs := x :: !fs)
               "usage: ./instrumenter [-i <input directory>][-o <output directory>] <property_files>";
    let h = compute_inheritance !in_dir in
    let ps = read_properties !fs in
    let p = transform_properties ps in
(*     ClassMapper.map !in_dir !out_dir (instrument_class (get_tag p) h); *)
    generate_checkers !out_dir p
  with
    | Helper.Parsing_failed m -> eprintf "@[%s@." m

(* }}} *)
(* TODO:
  - Don't forget that methods in package "topl" should not be instrumented.
  - a way to select properties (by name) from the command line
  - a way to select where to put various outputs from the command line
  - generate an easy to parse file rather than Java, as the Java may be too
    big to fit in the 64KB bytecode limit per method
 *)
(*
vim:sts=2:sw=2:ts=8:et:
*)
