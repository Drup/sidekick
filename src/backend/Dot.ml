(*
MSAT is free software, using the Apache license, see file LICENSE
Copyright 2014 Guillaume Bury
Copyright 2014 Simon Cruanes
*)

(** Output interface for the backend *)
module type S = Backend_intf.S

(** Input module for the backend *)
module type Arg = sig

  type atom

  type hyp
  type lemma
  type assumption
  (** Types for hypotheses, lemmas, and assumptions. *)

  val print_atom : Format.formatter -> atom -> unit
  (** Printing function for atoms *)

  val hyp_info : hyp -> string * string option * (Format.formatter -> unit -> unit) list
  val lemma_info : lemma -> string * string option * (Format.formatter -> unit -> unit) list
  val assumption_info : assumption -> string * string option * (Format.formatter -> unit -> unit) list
  (** Functions to return information about hypotheses and lemmas *)

end

module Default(S : Sidekick_sat.S) = struct
  module Atom = S.Atom
  module Clause = S.Clause
  module P = S.Proof

  let print_atom = Atom.pp

  let hyp_info c =
    "hypothesis", Some "LIGHTBLUE",
    [ fun fmt () -> Format.fprintf fmt "%s" @@ Clause.name c]

  let lemma_info c =
    "lemma", Some "BLUE",
    [ fun fmt () -> Format.fprintf fmt "%s" @@ Clause.name c]

  let assumption_info c =
    "assumption", Some "PURPLE",
    [ fun fmt () -> Format.fprintf fmt "%s" @@ Clause.name c]

end

(** Functor to provide dot printing *)
module Make(S : Sidekick_sat.S)(A : Arg with type atom := S.atom
                                and type hyp := S.clause
                                and type lemma := S.clause
                                and type assumption := S.clause) = struct
  module Atom = S.Atom
  module Clause = S.Clause
  module P = S.Proof

  let node_id n = Clause.name n.P.conclusion

  let res_node_id n = (node_id n) ^ "_res"

  let proof_id p = node_id (P.expand p)

  let print_clause fmt c =
    let v = Clause.atoms c in
    if Array.length v = 0 then
      Format.fprintf fmt "⊥"
    else (
      let n = Array.length v in
      for i = 0 to n - 1 do
        Format.fprintf fmt "%a" A.print_atom (Array.get v i);
        if i < n - 1 then
          Format.fprintf fmt ", "
      done
    )

  let print_edge fmt i j =
    Format.fprintf fmt "%s -> %s;@\n" j i

  let print_edges fmt n =
    match n.P.step with
    | P.Resolution (p1, p2, _) ->
      print_edge fmt (res_node_id n) (proof_id p1);
      print_edge fmt (res_node_id n) (proof_id p2)
    | _ -> ()

  let table_options fmt color =
    Format.fprintf fmt "BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\" BGCOLOR=\"%s\"" color

  let table fmt (c, rule, color, l) =
    Format.fprintf fmt "<TR><TD colspan=\"2\">%a</TD></TR>" print_clause c;
    match l with
    | [] ->
      Format.fprintf fmt "<TR><TD BGCOLOR=\"%s\" colspan=\"2\">%s</TD></TR>" color rule
    | f :: r ->
      Format.fprintf fmt "<TR><TD BGCOLOR=\"%s\" rowspan=\"%d\">%s</TD><TD>%a</TD></TR>"
        color (List.length l) rule f ();
      List.iter (fun f -> Format.fprintf fmt "<TR><TD>%a</TD></TR>" f ()) r

  let print_dot_node fmt id color c rule rule_color l =
    Format.fprintf fmt "%s [shape=plaintext, label=<<TABLE %a>%a</TABLE>>];@\n"
      id table_options color table (c, rule, rule_color, l)

  let print_dot_res_node fmt id a =
    Format.fprintf fmt "%s [label=<%a>];@\n" id A.print_atom a

  let ttify f c = fun fmt () -> f fmt c

  let print_contents fmt n =
    match n.P.step with
    (* Leafs of the proof tree *)
    | P.Hypothesis ->
      let rule, color, l = A.hyp_info P.(n.conclusion) in
      let color = match color with None -> "LIGHTBLUE" | Some c -> c in
      print_dot_node fmt (node_id n) "LIGHTBLUE" P.(n.conclusion) rule color l
    | P.Assumption ->
      let rule, color, l = A.assumption_info P.(n.conclusion) in
      let color = match color with None -> "LIGHTBLUE" | Some c -> c in
      print_dot_node fmt (node_id n) "LIGHTBLUE" P.(n.conclusion) rule color l
    | P.Lemma _ ->
      let rule, color, l = A.lemma_info P.(n.conclusion) in
      let color = match color with None -> "YELLOW" | Some c -> c in
      print_dot_node fmt (node_id n) "LIGHTBLUE" P.(n.conclusion) rule color l

    (* Tree nodes *)
    | P.Duplicate (p, l) ->
      print_dot_node fmt (node_id n) "GREY" P.(n.conclusion) "Duplicate" "GREY"
        ((fun fmt () -> (Format.fprintf fmt "%s" (node_id n))) ::
         List.map (ttify A.print_atom) l);
      print_edge fmt (node_id n) (node_id (P.expand p))
    | P.Resolution (_, _, a) ->
      print_dot_node fmt (node_id n) "GREY" P.(n.conclusion) "Resolution" "GREY"
        [(fun fmt () -> (Format.fprintf fmt "%s" (node_id n)))];
      print_dot_res_node fmt (res_node_id n) a;
      print_edge fmt (node_id n) (res_node_id n)

  let print_node fmt n =
    print_contents fmt n;
    print_edges fmt n

  let print fmt p =
    Format.fprintf fmt "digraph proof {@\n";
    P.fold (fun () -> print_node fmt) () p;
    Format.fprintf fmt "}@."

end

module Simple(S : Sidekick_sat.S) = Make(S)(Default(S))
