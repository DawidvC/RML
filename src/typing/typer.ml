(* The main typing algorithm.
   When a type if given if the term, we check if this type is well formed.
*)
let rec type_of_internal history context term = match term with
  (* ALL-I
     Γ, x : S ⊦ t : U ∧ x ∉ FV(S)
     =>
     Γ ⊦ λ(x : S) t ⊦ ∀(x : S) U
  *)
  | Grammar.TermAbstraction(s, (x, t)) ->
    CheckUtils.check_well_formedness context s;
    CheckUtils.check_avoidance_problem x s;
    let context' = ContextType.add x s context in
    let u_history, u = type_of_internal history context' t in
    let typ = Grammar.TypeDependentFunction(s, (x, u)) in
    DerivationTree.create_typing_node
      ~rule:"ALL-I"
      ~env:context
      ~term:(DerivationTree.Term term)
      ~typ
      ~history:[u_history]
  (* LET
     Γ ⊦ t : T ∧
     Γ, x : T ⊦ u : U ∧
     x ∉ FV(U)
     =>
     Γ ⊦ let x = t in u : U
  *)
  | Grammar.TermLet(t, (x, u)) ->
    let left_history, t_typ = type_of_internal history context t in
    (* It implies that x has the type of t, i.e. t_typ *)
    let x_typ = t_typ in
    let context' = ContextType.add x x_typ context in
    let right_history, u_typ = type_of_internal history context' u in
    CheckUtils.check_avoidance_problem x u_typ;
    DerivationTree.create_typing_node
      ~rule:"LET"
      ~env:context
      ~term:(DerivationTree.Term term)
      ~typ:u_typ
      ~history:[left_history ; right_history]
  (* USELESS NOW. Use {}-I instead.
     VAR
     Γ, x : T, Γ' ⊦ x : T
  | Grammar.TermVariable x ->
    let typ = ContextType.find x context in
    DerivationTree.create_typing_node
      ~rule:"VAR"
      ~env:context
      ~term:(DerivationTree.Term term)
      ~typ
      ~history:[]
  *)
  (* ALL-E.
     Γ ⊦ x : ∀(z : S) : T ∧
     Γ ⊦ y : S
     =>
     Γ ⊦ xy : [y := z]T
  *)
  | Grammar.TermVarApplication(x, y) ->
    (* We can simply use [ContextType.find x context], but it's to get the
       history.
    *)
    let history_x, type_of_x =
      type_of_internal history context (Grammar.TermVariable x)
    in
    let history_y, type_of_y =
      type_of_internal history context (Grammar.TermVariable y)
    in
    (* Check if [x] is a dependent function. *)
    let dep_function_opt =
      TypeUtils.least_upper_bound_of_dependent_function context type_of_x
    in
    (match dep_function_opt with
    | Some (s, (z, t)) ->
      CheckUtils.check_type_match context (Grammar.TermVariable y) type_of_y s;
      (* Here, we rename the variable [z] (which is the variable in the for all
         type, by the given variable [y]). We don't substitute the variable by
         the right types because it doesn't work with not well formed types (like
         x.A when x is of types Any).
      *)
      let typ = Grammar.rename_typ (AlphaLib.Atom.Map.singleton z y) t in
      DerivationTree.create_typing_node
        ~rule:"ALL-E"
        ~env:context
        ~term:(DerivationTree.Term term)
        ~typ
        ~history:[history_x ; history_y]
    | None -> raise (Error.NotADependentFunction(type_of_x))
    )
  (* ----- Unofficial typing rules ----- *)
  (* UN-ASC
     Γ ⊦ t : T
  *)
  | Grammar.TermAscription(t, typ_of_t) ->
    let actual_history, actual_typ_of_t =
      type_of_internal history context t
    in
    CheckUtils.check_well_formedness context typ_of_t;
    CheckUtils.check_subtype context actual_typ_of_t typ_of_t;
    DerivationTree.create_typing_node
      ~rule:"UN-ASC"
      ~env:context
      ~term:(DerivationTree.Term term)
      ~typ:typ_of_t
      ~history:[actual_history]
  (* UN-UNIMPLEMENTED
     Γ ⊦ Unimplemented : ⟂
  *)
  | Grammar.TermUnimplemented ->
    DerivationTree.create_typing_node
      ~rule:"UN-UNIMPLEMENTED"
      ~env:context
      ~term:(DerivationTree.Term term)
      ~typ:Grammar.TypeBottom
      ~history
  (* ----- Typing rules for DOT ----- *)
  (* {}-I
     Γ, x : T ⊦ d : T
     =>
     Γ ⊦ ν(x : T) d : μ(x : T)
  *)
  | Grammar.TermRecursiveRecord(typ, (z, d)) ->
    let context' = ContextType.add z typ context in
    let history_d, type_of_d =
      type_of_decl_internal history context' d
    in
    CheckUtils.check_subtype context type_of_d typ;
    DerivationTree.create_typing_node
      ~rule:"{}-I"
      ~env:context
      ~term:(DerivationTree.Term(term))
      ~typ:typ
      ~history:[history_d]
  (* UN-{}-I
     Γ, x : T ⊦ d : T
     =>
     Γ ⊦ ν(x) d : μ(x : T)
  *)
  | Grammar.TermRecursiveRecordUntyped(z, d) ->
    let history_d, type_of_d =
      type_of_decl_internal history context d
    in
    DerivationTree.create_typing_node
      ~rule:"{}-I"
      ~env:context
      ~term:(DerivationTree.Term(term))
      ~typ:type_of_d
      ~history:[history_d]

  (* FLD-E
     Γ ⊦ x : { a : T}
     =>
     Γ ⊦ x.a : T
  *)
  | Grammar.TermFieldSelection(x, a) ->
    (* TODO Check that x is a recursive record and contains the field a *)
    let type_of_x =
      ContextType.find x context
    in
    DerivationTree.create_typing_node
      ~rule:"FLD-E"
      ~env:context
      ~term:(DerivationTree.Term(term))
      ~typ:type_of_x
      ~history:[]
  (* REC-I with REC-E (both to avoid to recompute the type of x)

     REC-I
     Γ ⊦ x : T
     =>
     Γ ⊦ x : μ(x : T)

     REC-E
     Γ ⊦ x : μ(x : T)
     =>
     Γ ⊦ x : T
  *)
  | Grammar.TermVariable(x) ->
    let type_of_x =
      ContextType.find x context
    in
    let (typ, rule) = (match type_of_x with
     | Grammar.TypeRecursive(z, type_of_z) ->
       (* TODO: type_of_z must be the same than type_of_x *)
       type_of_x, "REC-E"
     | _ ->
       Grammar.TypeRecursive(x, type_of_x), "REC-I"
      )
    in
    DerivationTree.create_typing_node
      ~rule
      ~env:context
      ~term:(DerivationTree.Term(term))
      ~typ
      ~history

and type_of_decl_internal history context decl = match decl with
  (* TYP-I
     Γ ⊦ { A = T } : { A : T .. T }
  *)
  | Grammar.TermTypeDeclaration(a, typ) ->
    let typ = Grammar.TypeDeclaration(a, typ, typ) in
    DerivationTree.create_typing_node
      ~rule:"TYP-I"
      ~env:context
      ~term:(DerivationTree.Declaration(decl))
      ~typ
      ~history
  (* FLD-I
     Γ ⊦ t : T
     =>
     Γ ⊦ { a = t } : { a : T }
  *)
  | Grammar.TermFieldDeclaration(a, term) ->
    let history_type_of_term, type_of_term =
      type_of_internal history context term
    in
    let typ =
      Grammar.TypeFieldDeclaration(a, type_of_term)
    in
    DerivationTree.create_typing_node
      ~rule:"FLD-I"
      ~env:context
      ~term:(DerivationTree.Declaration(decl))
      ~typ
      ~history:[history_type_of_term]
  (* ANDDEF-I
     Γ ⊦ d1 : T1 ∧ Γ ⊦ d2 : T2 ∧ dom(d1) ∩ dom(d2) = ∅
     Γ ⊦ d1 ∧ d2 : T1 ∧ T2
  *)
  | Grammar.TermAggregateDeclaration(d1, d2) ->
    CheckUtils.check_disjoint_domains d1 d2;
    let history_d1, type_of_d1 =
      type_of_decl_internal history context d1
    in
    let history_d2, type_of_d2 =
      type_of_decl_internal history context d2
    in
    let typ =
      Grammar.TypeIntersection(type_of_d1, type_of_d2)
    in
    DerivationTree.create_typing_node
      ~rule:"ANDDEF-I"
      ~env:context
      ~term:(DerivationTree.Declaration(decl))
      ~typ
      ~history:[history_d1 ; history_d2]


let type_of ?(context = ContextType.empty ()) term =
  type_of_internal [] context term
