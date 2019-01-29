
module Th_clause : sig
  type t = Lit.t IArray.t
  val pp : t CCFormat.printer
end = struct
  type t = Lit.t IArray.t

  let pp out c =
    if IArray.length c = 0 then CCFormat.string out "false"
    else if IArray.length c = 1 then Lit.pp out (IArray.get c 0)
    else (
      Format.fprintf out "[@[<hv>%a@]]"
        (Util.pp_iarray ~sep:" ∨ " Lit.pp) c
    )
end

(** Unsatisfiable conjunction.
    Its negation will become a conflict clause *)
type conflict = Lit.t list

(** Actions available to a theory during its lifetime *)
module type ACTIONS = sig
  val on_backtrack: (unit -> unit) -> unit
  (** Register an action to do when we backtrack *)

  val raise_conflict: conflict -> 'a
  (** Give a conflict clause to the solver *)

  val propagate_eq: Term.t -> Term.t -> Lit.t list -> unit
  (** Propagate an equality [t = u] because [e] *)

  val propagate_distinct: Term.t list -> neq:Term.t -> Lit.t -> unit
  (** Propagate a [distinct l] because [e] (where [e = neq] *)

  val propagate: Lit.t -> Lit.t list -> unit
  (** Propagate a boolean using a unit clause.
      [expl => lit] must be a theory lemma, that is, a T-tautology *)

  val add_local_axiom: Lit.t IArray.t -> unit
  (** Add local clause to the SAT solver. This clause will be
      removed when the solver backtracks. *)

  val add_persistent_axiom: Lit.t IArray.t -> unit
  (** Add toplevel clause to the SAT solver. This clause will
      not be backtracked. *)

  val find: Term.t -> Equiv_class.t
  (** Find representative of this term *)

  val all_classes: Equiv_class.t Sequence.t
  (** All current equivalence classes
      (caution: linear in the number of terms existing in the solver) *)
end

type actions = (module ACTIONS)

module type S = sig
  type t

  val name : string
  (** Name of the theory *)

  val create : Term.state -> t
  (** Instantiate the theory's state *)

  val on_merge: t -> actions -> Equiv_class.t -> Equiv_class.t -> Explanation.t -> unit
  (** Called when two classes are merged *)

  val partial_check : t -> actions -> Lit.t Sequence.t -> unit
  (** Called when a literal becomes true *)

  val final_check: t -> actions -> Lit.t Sequence.t -> unit
  (** Final check, must be complete (i.e. must raise a conflict
      if the set of literals is not satisfiable) *)

  val mk_model : t -> Lit.t Sequence.t -> Model.t
  (** Make a model for this theory's terms *)

  val push_level : t -> unit

  val pop_levels : t -> int -> unit

  (**/**)
  val check_invariants : t -> unit
  (**/**)
end

type t = (module S)

type 'a t1 = (module S with type t = 'a)

let make
  (type st)
    ?(check_invariants=fun _ -> ())
    ?(on_merge=fun _ _ _ _ _ -> ())
    ?(partial_check=fun _ _ _ -> ())
    ?(mk_model=fun _ _ -> Model.empty)
    ?(push_level=fun _ -> ())
    ?(pop_levels=fun _ _ -> ())
    ~name
    ~final_check
    ~create
    () : t =
  let module A = struct
    type nonrec t = st
    let name = name
    let create = create
    let on_merge = on_merge
    let partial_check = partial_check
    let final_check = final_check
    let mk_model = mk_model
    let check_invariants = check_invariants
    let push_level = push_level
    let pop_levels = pop_levels
  end in
  (module A : S)
