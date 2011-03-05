{
  open Parser

  type ('a, 'b) either = Left of 'a | Right of 'b

  let l x = Left x
  let r x = Right x

  let new_line x y lexbuf =
    let m = ref 0 in
    String.iter (fun c -> if c = '\n' then incr m) x;
    let n = String.length y in
    let lcp = lexbuf.Lexing.lex_curr_p in
    lexbuf.Lexing.lex_curr_p <- { lcp with
      Lexing.pos_lnum = lcp.Lexing.pos_lnum + !m;
      Lexing.pos_bol = lcp.Lexing.pos_cnum - n
    };
    r n
  
}

rule tok1 = parse
    '\t'    { raise Error }
  | ((' '* '\n')+ as x) (' '* as y)
            { new_line x y lexbuf }
  | ' '+    { tok1 lexbuf }
  | "/\\" | "&&" | "and"
            { l AND }
  | ":="    { l ASGN }
  | "class" { l CLASS }
  | ','     { l COMMA }
  | '.'     { l DOT }
  | "else"  { l ELSE }
  | "=="    { l EQ }
  | "if"    { l IF }
  | '{'     { l LB }
  | '('     { l LP }
  | "!="    { l NE }
  | "new"   { l NEW }
  | "¬" | "!"
            { l NOT }
  | "\\/" | "||" | "or"
            { l OR }
  | '}'     { l RB }
  | "return"{ l RETURN }
  | ')'     { l RP }
  | "this"  { l THIS }
  | "while" { l WHILE }
  | ['a'-'z' 'A'-'Z']+ as id
            { l (ID id) }
  | eof     { l EOF }
  | _       { raise Error }

{
  (* EXERCISE: Write it with continuations. *)
  let token lexbuf =
    let indents = ref [0] in
    let scheduled_rb = ref 0 in
    let return t = (t, lexbuf.Lexing.lex_start_p, lexbuf.Lexing.lex_curr_p) in
    let rec return_rb n = match !indents with
      | h :: t when h > n -> incr scheduled_rb; indents := t; return_rb n
      | h :: t when h < n -> raise Error
      | [] -> failwith "broken invariant: List.length !indents > 0"
      | _ -> tok2 ()
    and tok2 () =
      if !scheduled_rb > 0 then begin
        decr scheduled_rb;
        return RB
      end else match tok1 lexbuf with (* TODO *)
        | Right n ->
            if n > List.hd !indents then begin
              indents := n :: !indents;
              return LB
            end else return_rb n
        | Left t -> return t in
    tok2
}
