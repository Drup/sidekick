
open CDCL
open Solver_types

type node = Equiv_class.t
type repr = Equiv_class.repr

(** A signature is a shallow term shape where immediate subterms
    are representative *)
module Signature = struct
  type t = node term_cell
  include Term_cell.Make_eq(Equiv_class)
end

module Sig_tbl = CCHashtbl.Make(Signature)

type merge_op = node * node * cc_explanation
(* a merge operation to perform *)

type actions =
  | Propagate of Lit.t * cc_explanation list
  | Split of Lit.t list * cc_explanation list
  | Merge of node * node (* merge these two classes *)

type t = {
  tst: Term.state;
  tbl: node Term.Tbl.t;
  (* internalization [term -> node] *)
  signatures_tbl : repr Sig_tbl.t;
  (* map a signature to the corresponding term in some equivalence class.
     A signature is a [term_cell] in which every immediate subterm
     that participates in the congruence/evaluation relation
     is normalized (i.e. is its own representative).
     The critical property is that all members of an equivalence class
     that have the same "shape" (including head symbol)
     have the same signature *)
  on_backtrack: (unit -> unit) -> unit;
  (* register a function to be called when we backtrack *)
  at_lvl_0: unit -> bool;
  (* currently at level 0? *)
  on_merge: (repr -> repr -> cc_explanation -> unit) list;
  (* callbacks to call when we merge classes *)
  pending: node Vec.t;
  (* nodes to check, maybe their new signature is in {!signatures_tbl} *)
  combine: merge_op Vec.t;
  (* pairs of terms to merge *)
  mutable actions : actions list;
  (* some boolean propagations/splits to make. *)
  mutable ps_lits: Lit.Set.t;
  (* proof state *)
  ps_queue: (node*node) Vec.t;
  (* pairs to explain *)
  true_ : node lazy_t;
  false_ : node lazy_t;
}
(* TODO: an additional union-find to keep track, for each term,
   of the terms they are known to be equal to, according
   to the current explanation. That allows not to prove some equality
   several times.
   See "fast congruence closure and extensions", Nieuwenhis&al, page 14 *)

module CC_expl_set = CCSet.Make(struct
    type t = cc_explanation
    let compare = Solver_types.cmp_cc_expl
  end)

let[@inline] is_root_ (n:node) : bool = n.n_root == n

let[@inline] size_ (r:repr) =
  assert (is_root_ (r:>node));
  Bag.size (r :> node).n_parents

(* check if [t] is in the congruence closure.
   Invariant: [in_cc t => in_cc u, forall u subterm t] *)
let[@inline] mem (cc:t) (t:term): bool =
  Term.Tbl.mem cc.tbl t

(* find representative, recursively, and perform path compression *)
let rec find_rec cc (n:node) : repr =
  if n==n.n_root then (
    Equiv_class.unsafe_repr_of_node n
  ) else (
    let old_root = n.n_root in
    let root = find_rec cc old_root in
    (* path compression *)
    if (root :> node) != old_root then (
      if not (cc.at_lvl_0 ()) then (
        cc.on_backtrack (fun () -> n.n_root <- old_root);
      );
      n.n_root <- (root :> node);
    );
    root
  )

let[@inline] true_ cc = Lazy.force cc.true_
let[@inline] false_ cc = Lazy.force cc.false_

(* get term that should be there *)
let[@inline] get_ cc (t:term) : node =
  try Term.Tbl.find cc.tbl t
  with Not_found ->
    Log.debugf 5 (fun k->k "(@[<hv1>missing@ %a@])" Term.pp t);
    assert false

(* non-recursive, inlinable function for [find] *)
let[@inline] find st (n:node) : repr =
  if n == n.n_root
  then (Equiv_class.unsafe_repr_of_node n)
  else find_rec st n

let[@inline] find_tn cc (t:term) : repr = get_ cc t |> find cc
let[@inline] find_tt cc (t:term) : term = find_tn cc t |> Equiv_class.Repr.term

let[@inline] same_class cc (n1:node)(n2:node): bool =
  Equiv_class.Repr.equal (find cc n1) (find cc n2)

(* compute signature *)
let signature cc (t:term): node term_cell option =
  let find = (find_tn cc :> term -> node) in
  begin match Term.cell t with
    | True | Builtin _
      -> None
    | App_cst (_, a) when IArray.is_empty a -> None
    | App_cst (f, a) -> App_cst (f, IArray.map find a) |> CCOpt.return
    | If (a,b,c) -> If (find a, get_  cc b, get_ cc c) |> CCOpt.return
    | Case (t, m) -> Case (find t, ID.Map.map (get_ cc) m) |> CCOpt.return
   end

(* find whether the given (parent) term corresponds to some signature
   in [signatures_] *)
let find_by_signature cc (t:term) : repr option = match signature cc t with
  | None -> None
  | Some s -> Sig_tbl.get cc.signatures_tbl s

let remove_signature cc (t:term): unit = match signature cc t with
  | None -> ()
  | Some s ->
    Sig_tbl.remove cc.signatures_tbl s

let add_signature cc (t:term) (r:repr): unit = match signature cc t with
  | None -> ()
  | Some s ->
    assert (CCOpt.map_or ~default:false (Signature.equal s)
        (signature cc (r:>node).n_term));
    (* add, but only if not present already *)
    begin match Sig_tbl.get cc.signatures_tbl s with
      | None ->
        if not (cc.at_lvl_0 ()) then (
          cc.on_backtrack
            (fun () -> Sig_tbl.remove cc.signatures_tbl s);
        );
        Sig_tbl.add cc.signatures_tbl s r;
      | Some r' ->
        assert (Equiv_class.Repr.equal r r');
    end

let is_done (cc:t): bool =
  Vec.is_empty cc.pending &&
  Vec.is_empty cc.combine

let push_pending cc t : unit =
  Log.debugf 5 (fun k->k "(@[<hv1>push_pending@ %a@])" Equiv_class.pp t);
  Vec.push cc.pending t

let push_combine cc t u e : unit =
  Log.debugf 5
    (fun k->k "(@[<hv1>push_combine@ %a@ %a@ expl: %a@])"
      Equiv_class.pp t Equiv_class.pp u pp_cc_explanation e);
  Vec.push cc.combine (t,u,e)

let push_split cc (lits:lit list) (expl:cc_explanation list): unit =
  Log.debugf 5
    (fun k->k "(@[<hv1>push_split@ (@[%a@])@ expl: (@[<hv>%a@])@])"
      (Util.pp_list Lit.pp) lits (Util.pp_list pp_cc_explanation) expl);
  let l = Split (lits, expl) in
  cc.actions <- l :: cc.actions

let push_propagation cc (lit:lit) (expl:cc_explanation list): unit =
  Log.debugf 5
    (fun k->k "(@[<hv1>push_propagate@ %a@ expl: (@[<hv>%a@])@])"
      Lit.pp lit (Util.pp_list pp_cc_explanation) expl);
  let l = Propagate (lit,expl) in
  cc.actions <- l :: cc.actions

let[@inline] union cc (a:node) (b:node) (e:cc_explanation): unit =
  if not (same_class cc a b) then (
    push_combine cc a b e; (* start by merging [a=b] *)
  )

(* re-root the explanation tree of the equivalence class of [n]
   so that it points to [n].
   postcondition: [n.n_expl = None] *)
let rec reroot_expl cc (n:node): unit =
  let old_expl = n.n_expl in
  if not (cc.at_lvl_0 ()) then (
    cc.on_backtrack (fun () -> n.n_expl <- old_expl);
  );
  begin match old_expl with
    | None -> () (* already root *)
    | Some (u, e_n_u) ->
      reroot_expl cc u;
      u.n_expl <- Some (n, e_n_u);
      n.n_expl <- None;
  end

(* TODO:
   - move what follows into {!Theory}.
   - also, obtain merges of CC via callbacks / [pop_merges] afterwards?
   *)

exception Exn_unsat of cc_explanation list

let unsat (e:cc_explanation list): _ = raise (Exn_unsat e)

type result =
  | Sat of actions list
  | Unsat of cc_explanation list
  (* list of direct explanations to the conflict. *)

let[@inline] all_classes cc : repr Sequence.t =
  Term.Tbl.values cc.tbl
  |> Sequence.filter is_root_
  |> Equiv_class.unsafe_repr_seq_of_seq

(* main CC algo: add terms from [pending] to the signature table,
   check for collisions *)
let rec update_pending (cc:t): result =
  (* step 2 deal with pending (parent) terms whose equiv class
     might have changed *)
  while not (Vec.is_empty cc.pending) do
    let n = Vec.pop_last cc.pending in
    (* check if some parent collided *)
    begin match find_by_signature cc n.n_term with
      | None ->
        (* add to the signature table [n --> n.root] *)
        add_signature cc n.n_term (find cc n)
      | Some u ->
        (* must combine [t] with [r] *)
        push_combine cc n (u:>node) (CC_congruence (n,(u:>node)))
    end;
    (* FIXME: when to actually evaluate?
    eval_pending cc;
    *)
  done;
  if is_done cc then (
    let actions = cc.actions in
    cc.actions <- [];
    Sat actions
  ) else (
    update_combine cc (* repeat *)
  )

(* main CC algo: merge equivalence classes in [st.combine].
   @raise Exn_unsat if merge fails *)
and update_combine cc =
  while not (Vec.is_empty cc.combine) do
    let a, b, e_ab = Vec.pop_last cc.combine in
    let ra = find cc a in
    let rb = find cc b in
    if not (Equiv_class.Repr.equal ra rb) then (
      assert (is_root_ (ra:>node));
      assert (is_root_ (rb:>node));
      (* We will merge [r_from] into [r_into].
         we try to ensure that [size ra <= size rb] in general, unless
         it clashes with the invariant that the representative must
         be a normal form if the class contains a normal form *)
      let r_from, r_into =
        if size_ ra > size_ rb then rb, ra else ra, rb
      in
      (* remove [ra.parents] from signature, put them into [st.pending] *)
      begin
        Bag.to_seq (r_from:>node).n_parents
        |> Sequence.iter
          (fun parent ->
             (* FIXME: with OCaml's hashtable, we should be able
                to keep this entry (and have it become relevant later
                once the signature of [parent] is backtracked) *)
             remove_signature cc parent.n_term;
             push_pending cc parent)
      end;
      (* perform [union ra rb] *)
      begin
        let r_from = (r_from :> node) in
        let r_into = (r_into :> node) in
        let rb_old_class = r_into.n_class in
        let rb_old_parents = r_into.n_parents in
        cc.on_backtrack
          (fun () ->
             r_from.n_root <- r_from;
             r_into.n_class <- rb_old_class;
             r_into.n_parents <- rb_old_parents);
        r_from.n_root <- r_into;
        r_from.n_class <- Bag.append rb_old_class r_from.n_class;
        r_from.n_parents <- Bag.append rb_old_parents r_from.n_parents;
      end;
      (* update explanations (a -> b), arbitrarily *)
      begin
        reroot_expl cc a;
        assert (a.n_expl = None);
        if not (cc.at_lvl_0 ()) then (
          cc.on_backtrack (fun () -> a.n_expl <- None);
        );
        a.n_expl <- Some (b, e_ab);
      end;
      (* notify listeners of the merge *)
      notify_merge cc r_from ~into:r_into e_ab;
    )
  done;
  (* now update pending terms again *)
  update_pending cc

(* Checks if [ra] and [~into] have compatible normal forms and can
   be merged w.r.t. the theories.
   Side effect: also pushes sub-tasks *)
and notify_merge cc (ra:repr) ~into:(rb:repr) (e:cc_explanation): unit =
  assert (is_root_ (ra:>node));
  assert (is_root_ (rb:>node));
  List.iter
    (fun f -> f ra rb e)
    cc.on_merge;
  ()


(* FIXME: callback?
(* evaluation rules: if, case... *)
and eval_pending (t:term): unit =
  List.iter
    (fun ((module Theory):repr theory) -> Theory.eval t)
    theories
   *)

(* FIXME: remove?
(* main CC algo: add missing terms to the congruence class *)
and update_add (cc:t) terms () =
  while not (Queue.is_empty cc.terms_to_add) do
    let t = Queue.pop cc.terms_to_add in
    add cc t
  done
*)

(* add [t] to [cc] when not present already *)
and add_new_term cc (t:term) : node =
  assert (not @@ mem cc t);
  let n = Equiv_class.make t in
  (* how to add a subterm *)
  let add_to_parents_of_sub_node (sub:node) : unit =
    let old_parents = sub.n_parents in
    if not @@ cc.at_lvl_0 () then (
      cc.on_backtrack (fun () -> sub.n_parents <- old_parents);
    );
    sub.n_parents <- Bag.cons n sub.n_parents;
    push_pending cc sub
  in
  (* add sub-term to [cc], and register [n] to its parents *)
  let add_sub_t (u:term) : unit =
    let n_u = add cc u in
    add_to_parents_of_sub_node n_u
  in
  (* register sub-terms, add [t] to their parent list *)
  begin match t.term_cell with
    | True -> ()
    | App_cst (_, a) -> IArray.iter add_sub_t a
    | If (a,b,c) ->
      add_sub_t a;
      add_sub_t b;
      add_sub_t c
    | Case (u, _) -> add_sub_t u
    | Builtin b -> Term.builtin_to_seq b add_sub_t
  end;
  (* remove term when we backtrack *)
  if not (cc.at_lvl_0 ()) then (
    cc.on_backtrack (fun () -> Term.Tbl.remove cc.tbl t);
  );
  (* add term to the table *)
  Term.Tbl.add cc.tbl t n;
  (* [n] might be merged with other equiv classes *)
  push_pending cc n;
  n

(* add [t=u] to the congruence closure, unconditionally (reduction relation)  *)
and[@inline] add_eqn (cc:t) (eqn:merge_op): unit =
  let t, u, expl = eqn in
  push_combine cc t u expl

(* add a term *)
and[@inline] add cc t =
  try Term.Tbl.find cc.tbl t
  with Not_found -> add_new_term cc t

let[@inline] add_seq cc seq = seq (fun t -> ignore @@ add cc t)

(* assert that this boolean literal holds *)
let assert_lit cc lit : unit = match Lit.view lit with
  | Lit_fresh _
  | Lit_expanded _ -> ()
  | Lit_atom t ->
    assert (Ty.is_prop t.term_ty);
    let sign = Lit.sign lit in
    (* equate t and true/false *)
    let rhs = if sign then true_ cc else false_ cc in
    let n = add cc t in
    push_combine cc n rhs (CC_lit lit);
    ()

let create ?(size=2048) ~on_backtrack ~at_lvl_0 ~on_merge (tst:Term.state) : t =
  assert (at_lvl_0 ());
  let nd = Equiv_class.dummy in
  let rec cc = {
    tst;
    tbl = Term.Tbl.create size;
    on_merge;
    signatures_tbl = Sig_tbl.create size;
    on_backtrack;
    at_lvl_0;
    pending=Vec.make_empty Equiv_class.dummy;
    combine= Vec.make_empty (nd,nd,CC_reduce_eq(nd,nd));
    actions=[];
    ps_lits=Lit.Set.empty;
    ps_queue=Vec.make_empty (nd,nd);
    true_ = lazy (add cc (Term.true_ tst));
    false_ = lazy (add cc (Term.false_ tst));
  } in
  ignore (Lazy.force cc.true_);
  ignore (Lazy.force cc.false_);
  cc

(* distance from [t] to its root in the proof forest *)
let[@inline][@unroll 2] rec distance_to_root (n:node): int = match n.n_expl with
  | None -> 0
  | Some (t', _) -> 1 + distance_to_root t'

(* find the closest common ancestor of [a] and [b] in the proof forest *)
let find_common_ancestor (a:node) (b:node) : node =
  let d_a = distance_to_root a in
  let d_b = distance_to_root b in
  (* drop [n] nodes in the path from [t] to its root *)
  let rec drop_ n t =
    if n=0 then t
    else match t.n_expl with
      | None -> assert false
      | Some (t', _) -> drop_ (n-1) t'
  in
  (* reduce to the problem where [a] and [b] have the same distance to root *)
  let a, b =
    if d_a > d_b then drop_ (d_a-d_b) a, b
    else if d_a < d_b then a, drop_ (d_b-d_a) b
    else a, b
  in
  (* traverse stepwise until a==b *)
  let rec aux_same_dist a b =
    if a==b then a
    else match a.n_expl, b.n_expl with
      | None, _ | _, None -> assert false
      | Some (a', _), Some (b', _) -> aux_same_dist a' b'
  in
  aux_same_dist a b

let[@inline] ps_add_obligation (cc:t) a b = Vec.push cc.ps_queue (a,b)
let[@inline] ps_add_lit ps l = ps.ps_lits <- Lit.Set.add l ps.ps_lits
let[@inline] ps_add_expl ps e = match e with
  | CC_lit lit -> ps_add_lit ps lit
  | CC_reduce_eq _ | CC_congruence _
  | CC_injectivity _ | CC_reduction
    -> ()

and ps_add_obligation_t cc (t1:term) (t2:term) =
  let n1 = get_ cc t1 in
  let n2 = get_ cc t2 in
  ps_add_obligation cc n1 n2

let ps_clear (cc:t) =
  cc.ps_lits <- Lit.Set.empty;
  Vec.clear cc.ps_queue;
  ()

let decompose_explain cc (e:cc_explanation): unit =
  Log.debugf 5 (fun k->k "(@[decompose_expl@ %a@])" pp_cc_explanation e);
  ps_add_expl cc e;
  begin match e with
    | CC_reduction
    | CC_lit _ -> ()
    | CC_reduce_eq (a, b) ->
      ps_add_obligation cc a b;
    | CC_injectivity (t1,t2)
    (* FIXME: should this be different from CC_congruence? just explain why t1==t2? *)
    | CC_congruence (t1,t2) ->
      begin match t1.n_term.term_cell, t2.n_term.term_cell with
        | True, _ -> assert false (* no congruence here *)
        | App_cst (f1, a1), App_cst (f2, a2) ->
          assert (Cst.equal f1 f2);
          assert (IArray.length a1 = IArray.length a2);
          IArray.iter2 (ps_add_obligation_t cc) a1 a2
        | Case (_t1, _m1), Case (_t2, _m2) ->
          assert false
          (* TODO: this should never happen
          ps_add_obligation ps t1 t2;
          ID.Map.iter
            (fun id rhs1 ->
               let rhs2 = ID.Map.find id m2 in
               ps_add_obligation ps rhs1 rhs2)
            m1;
             *)
        | If (a1,b1,c1), If (a2,b2,c2) ->
          ps_add_obligation_t cc a1 a2;
          ps_add_obligation_t cc b1 b2;
          ps_add_obligation_t cc c1 c2;
        | Builtin _, _ -> assert false
        | App_cst _, _
        | Case _, _
        | If _, _
          -> assert false
      end
  end

(* explain why [a = parent_a], where [a -> ... -> parent_a] in the
   proof forest *)
let rec explain_along_path ps (a:node) (parent_a:node) : unit =
  if a!=parent_a then (
    match a.n_expl with
      | None -> assert false
      | Some (next_a, e_a_b) ->
        decompose_explain ps e_a_b;
        (* now prove [next_a = parent_a] *)
        explain_along_path ps next_a parent_a
  )

(* find explanation *)
let explain_loop (cc : t) : Lit.Set.t =
  while not (Vec.is_empty cc.ps_queue) do
    let a, b = Vec.pop_last cc.ps_queue in
    Log.debugf 5
      (fun k->k "(@[explain_loop at@ %a@ %a@])" Equiv_class.pp a Equiv_class.pp b);
    assert (Equiv_class.Repr.equal (find cc a) (find cc b));
    let c = find_common_ancestor a b in
    explain_along_path cc a c;
    explain_along_path cc b c;
  done;
  cc.ps_lits

let explain_unfold cc (l:cc_explanation list): Lit.Set.t =
  Log.debugf 5
    (fun k->k "(@[explain_confict@ (@[<hv>%a@])@])"
        (Util.pp_list pp_cc_explanation) l);
  ps_clear cc;
  List.iter (decompose_explain cc) l;
  explain_loop cc

let check_ cc =
  try update_pending cc
  with Exn_unsat e ->
    Unsat e

(* check satisfiability, update congruence closure *)
let check (cc:t) : result =
  Log.debug 5 "(cc.check)";
  check_ cc

let final_check cc : result =
  Log.debug 5 "(CC.final_check)";
  check_ cc
