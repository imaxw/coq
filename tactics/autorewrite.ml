(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Equality
open Names
open Pp
open Constr
open Termops
open CErrors
open Util
open Mod_subst
open Locus

(* Rewriting rules *)
type rew_rule = { rew_lemma: constr;
                  rew_type: types;
                  rew_pat: constr;
                  rew_ctx: Univ.ContextSet.t;
                  rew_l2r: bool;
                  rew_tac: Genarg.glob_generic_argument option }

module RewRule =
struct
  type t = rew_rule
  let rew_lemma r = (r.rew_ctx, r.rew_lemma)
  let rew_l2r r = r.rew_l2r
  let rew_tac r = r.rew_tac
end

let subst_hint subst hint =
  let cst' = subst_mps subst hint.rew_lemma in
  let typ' = subst_mps subst hint.rew_type in
  let pat' = subst_mps subst hint.rew_pat in
  let t' = Option.Smart.map (Genintern.generic_substitute subst) hint.rew_tac in
    if hint.rew_lemma == cst' && hint.rew_type == typ' && hint.rew_tac == t' then hint else
      { hint with
        rew_lemma = cst'; rew_type = typ';
        rew_pat = pat';	rew_tac = t' }

module HintIdent =
struct
  type t = int * rew_rule

  let compare (i, t) (j, t') = i - j

  let constr_of (i,t) = t.rew_pat
end

(* Representation/approximation of terms to use in the dnet:
 *
 * - no meta or evar (use ['a pattern] for that)
 *
 * - [Rel]s and [Sort]s are not taken into account (that's why we need
 *   a second pass of linear filterin on the results - it's not a perfect
 *   term indexing structure)

 * - Foralls and LetIns are represented by a context DCtx (a list of
 *   generalization, similar to rel_context, and coded with DCons and
 *   DNil). This allows for matching under an unfinished context
 *)

module DTerm =
struct

  type 't t =
    | DRel
    | DSort
    | DRef    of GlobRef.t
    | DCtx    of 't * 't (* (binding list, subterm) = Prods and LetIns *)
    | DLambda of 't * 't
    | DApp    of 't * 't (* binary app *)
    | DCase   of case_info * 't * 't * 't array
    | DFix    of int array * int * 't array * 't array
    | DCoFix  of int * 't array * 't array
    | DInt    of Uint63.t
    | DFloat  of Float64.t
    | DArray  of 't array * 't * 't

    (* special constructors only inside the left-hand side of DCtx or
       DApp. Used to encode lists of foralls/letins/apps as contexts *)
    | DCons   of ('t * 't option) * 't
    | DNil

  (* debug *)
  let _pr_dconstr f : 'a t -> Pp.t = function
    | DRel -> str "*"
    | DSort -> str "Sort"
    | DRef _ -> str "Ref"
    | DCtx (ctx,t) -> f ctx ++ spc() ++ str "|-" ++ spc () ++ f t
    | DLambda (t1,t2) -> str "fun"++ spc() ++ f t1 ++ spc() ++ str"->" ++ spc() ++ f t2
    | DApp (t1,t2) -> f t1 ++ spc() ++ f t2
    | DCase (_,t1,t2,ta) -> str "case"
    | DFix _ -> str "fix"
    | DCoFix _ -> str "cofix"
    | DInt _ -> str "INT"
    | DFloat _ -> str "FLOAT"
    | DCons ((t,dopt),tl) -> f t ++ (match dopt with
          Some t' -> str ":=" ++ f t'
        | None -> str "") ++ spc() ++ str "::" ++ spc() ++ f tl
    | DNil -> str "[]"
    | DArray _ -> str "ARRAY"

  (*
   * Functional iterators for the t datatype
   * a.k.a boring and error-prone boilerplate code
   *)

  let map f = function
    | (DRel | DSort | DNil | DRef _ | DInt _ | DFloat _) as c -> c
    | DCtx (ctx,c) -> DCtx (f ctx, f c)
    | DLambda (t,c) -> DLambda (f t, f c)
    | DApp (t,u) -> DApp (f t,f u)
    | DCase (ci,p,c,bl) -> DCase (ci, f p, f c, Array.map f bl)
    | DFix (ia,i,ta,ca) ->
        DFix (ia,i,Array.map f ta,Array.map f ca)
    | DCoFix(i,ta,ca) ->
        DCoFix (i,Array.map f ta,Array.map f ca)
    | DCons ((t,topt),u) -> DCons ((f t,Option.map f topt), f u)
    | DArray (t,def,ty) -> DArray(Array.map f t, f def, f ty)

  let compare_ci ci1 ci2 =
    let c = Ind.CanOrd.compare ci1.ci_ind ci2.ci_ind in
    if c = 0 then
      let c = Int.compare ci1.ci_npar ci2.ci_npar in
      if c = 0 then
        let c = Array.compare Int.compare ci1.ci_cstr_ndecls ci2.ci_cstr_ndecls in
        if c = 0 then
          Array.compare Int.compare ci1.ci_cstr_nargs ci2.ci_cstr_nargs
        else c
      else c
    else c

  let compare cmp t1 t2 = match t1, t2 with
  | DRel, DRel -> 0
  | DRel, _ -> -1 | _, DRel -> 1
  | DSort, DSort -> 0
  | DSort, _ -> -1 | _, DSort -> 1
  | DRef gr1, DRef gr2 -> GlobRef.CanOrd.compare gr1 gr2
  | DRef _, _ -> -1 | _, DRef _ -> 1

  | DCtx (tl1, tr1), DCtx (tl2, tr2)
  | DLambda (tl1, tr1), DLambda (tl2, tr2)
  | DApp (tl1, tr1), DApp (tl2, tr2) ->
    let c = cmp tl1 tl2 in
    if c = 0 then cmp tr1 tr2 else c
  | DCtx _, _ -> -1 | _, DCtx _ -> 1
  | DLambda _, _ -> -1 | _, DLambda _ -> 1
  | DApp _, _ -> -1 | _, DApp _ -> 1

  | DCase (ci1, c1, t1, p1), DCase (ci2, c2, t2, p2) ->
    let c = cmp c1 c2 in
    if c = 0 then
      let c = cmp t1 t2 in
      if c = 0 then
        let c = Array.compare cmp p1 p2 in
        if c = 0 then compare_ci ci1 ci2
        else c
      else c
    else c
  | DCase _, _ -> -1 | _, DCase _ -> 1

  | DFix (i1, j1, tl1, pl1), DFix (i2, j2, tl2, pl2) ->
    let c = Int.compare j1 j2 in
    if c = 0 then
      let c = Array.compare Int.compare i1 i2 in
      if c = 0 then
        let c = Array.compare cmp tl1 tl2 in
        if c = 0 then Array.compare cmp pl1 pl2
        else c
      else c
    else c
  | DFix _, _ -> -1 | _, DFix _ -> 1

  | DCoFix (i1, tl1, pl1), DCoFix (i2, tl2, pl2) ->
    let c = Int.compare i1 i2 in
    if c = 0 then
      let c = Array.compare cmp tl1 tl2 in
      if c = 0 then Array.compare cmp pl1 pl2
      else c
    else c
  | DCoFix _, _ -> -1 | _, DCoFix _ -> 1

  | DInt i1, DInt i2 -> Uint63.compare i1 i2

  | DInt _, _ -> -1 | _, DInt _ -> 1

  | DFloat f1, DFloat f2 -> Float64.total_compare f1 f2

  | DFloat _, _ -> -1 | _, DFloat _ -> 1

  | DArray(t1,def1,ty1), DArray(t2,def2,ty2) ->
    let c =  Array.compare cmp t1 t2 in
    if c = 0 then
      let c = cmp def1 def2 in
      if c = 0 then
      cmp ty1 ty2
      else c
    else c

  | DArray _, _ -> -1 | _, DArray _ -> 1

  | DCons ((t1, ot1), u1), DCons ((t2, ot2), u2) ->
     let c = cmp t1 t2 in
     if Int.equal c 0 then
       let c = Option.compare cmp ot1 ot2 in
       if Int.equal c 0 then cmp u1 u2
       else c
     else c
  | DCons _, _ -> -1 | _, DCons _ -> 1

  | DNil, DNil -> 0

  let fold f acc = function
    | (DRel | DNil | DSort | DRef _ | DInt _ | DFloat _) -> acc
    | DCtx (ctx,c) -> f (f acc ctx) c
    | DLambda (t,c) -> f (f acc t) c
    | DApp (t,u) -> f (f acc t) u
    | DCase (ci,p,c,bl) -> Array.fold_left f (f (f acc p) c) bl
    | DFix (ia,i,ta,ca) ->
        Array.fold_left f (Array.fold_left f acc ta) ca
    | DCoFix(i,ta,ca) ->
        Array.fold_left f (Array.fold_left f acc ta) ca
    | DArray(t,def,ty) -> f (f (Array.fold_left f acc t) def) ty
    | DCons ((t,topt),u) -> f (Option.fold_left f (f acc t) topt) u

  let choose f = function
    | (DRel | DSort | DNil | DRef _ | DInt _ | DFloat _) -> invalid_arg "choose"
    | DCtx (ctx,c) -> f ctx
    | DLambda (t,c) -> f t
    | DApp (t,u) -> f u
    | DCase (ci,p,c,bl) -> f c
    | DFix (ia,i,ta,ca) -> f ta.(0)
    | DCoFix (i,ta,ca) -> f ta.(0)
    | DCons ((t,topt),u) -> f u
    | DArray(t,def,ty) -> f t.(0)

  let dummy_cmp () () = 0

  let fold2 (f:'a -> 'b -> 'c -> 'a) (acc:'a) (c1:'b t) (c2:'c t) : 'a =
    let head w = map (fun _ -> ()) w in
    if not (Int.equal (compare dummy_cmp (head c1) (head c2)) 0)
    then invalid_arg "fold2:compare" else
      match c1,c2 with
        | (DRel, DRel | DNil, DNil | DSort, DSort | DRef _, DRef _
           | DInt _, DInt _ | DFloat _, DFloat _) -> acc
        | (DCtx (c1,t1), DCtx (c2,t2)
          | DApp (c1,t1), DApp (c2,t2)
          | DLambda (c1,t1), DLambda (c2,t2)) -> f (f acc c1 c2) t1 t2
        | DCase (ci,p1,c1,bl1),DCase (_,p2,c2,bl2) ->
            Array.fold_left2 f (f (f acc p1 p2) c1 c2) bl1 bl2
        | DFix (ia,i,ta1,ca1), DFix (_,_,ta2,ca2) ->
            Array.fold_left2 f (Array.fold_left2 f acc ta1 ta2) ca1 ca2
        | DCoFix(i,ta1,ca1), DCoFix(_,ta2,ca2) ->
            Array.fold_left2 f (Array.fold_left2 f acc ta1 ta2) ca1 ca2
              | DArray(t1,def1,ty1), DArray(t2,def2,ty2) ->
            f (f (Array.fold_left2 f acc t1 t2) def1 def2) ty1 ty2
        | DCons ((t1,topt1),u1), DCons ((t2,topt2),u2) ->
            f (Option.fold_left2 f (f acc t1 t2) topt1 topt2) u1 u2
        | (DRel | DNil | DSort | DRef _ | DCtx _ | DApp _ | DLambda _ | DCase _
           | DFix _ | DCoFix _ | DCons _ | DInt _ | DFloat _| DArray _), _ -> assert false

  let map2 (f:'a -> 'b -> 'c) (c1:'a t) (c2:'b t) : 'c t =
    let head w = map (fun _ -> ()) w in
    if not (Int.equal (compare dummy_cmp (head c1) (head c2)) 0)
    then invalid_arg "map2_t:compare" else
      match c1,c2 with
        | (DRel, DRel | DSort, DSort | DNil, DNil | DRef _, DRef _
           | DInt _, DInt _ | DFloat _, DFloat _) as cc ->
            let (c,_) = cc in c
        | DCtx (c1,t1), DCtx (c2,t2) -> DCtx (f c1 c2, f t1 t2)
        | DLambda (t1,c1), DLambda (t2,c2) -> DLambda (f t1 t2, f c1 c2)
        | DApp (t1,u1), DApp (t2,u2) -> DApp (f t1 t2,f u1 u2)
        | DCase (ci,p1,c1,bl1), DCase (_,p2,c2,bl2) ->
            DCase (ci, f p1 p2, f c1 c2, Array.map2 f bl1 bl2)
        | DFix (ia,i,ta1,ca1), DFix (_,_,ta2,ca2) ->
            DFix (ia,i,Array.map2 f ta1 ta2,Array.map2 f ca1 ca2)
        | DCoFix (i,ta1,ca1), DCoFix (_,ta2,ca2) ->
            DCoFix (i,Array.map2 f ta1 ta2,Array.map2 f ca1 ca2)
              | DArray(t1,def1,ty1), DArray(t2,def2,ty2) ->
                DArray(Array.map2 f t1 t2, f def1 def2, f ty1 ty2)
        | DCons ((t1,topt1),u1), DCons ((t2,topt2),u2) ->
            DCons ((f t1 t2,Option.lift2 f topt1 topt2), f u1 u2)
        | (DRel | DNil | DSort | DRef _ | DCtx _ | DApp _ | DLambda _ | DCase _
           | DFix _ | DCoFix _ | DCons _ | DInt _ | DFloat _ | DArray _), _ -> assert false

  let terminal = function
    | (DRel | DSort | DNil | DRef _ | DInt _ | DFloat _) -> true
    | DLambda _ | DApp _ | DCase _ | DFix _ | DCoFix _ | DCtx _ | DCons _ | DArray _ ->
      false

  let compare t1 t2 = compare dummy_cmp t1 t2

end

(*
 * Terms discrimination nets
 * Uses the general dnet datatype on DTerm.t
 * (here you can restart reading)
 *)

module HintDN :
sig
  type t
  type ident = HintIdent.t

  val empty : t

  (** [add c i dn] adds the binding [(c,i)] to [dn]. [c] can be a
     closed term or a pattern (with untyped Evars). No Metas accepted *)
  val add : constr -> ident -> t -> t

  (*
   * High-level primitives describing specific search problems
   *)

  (** [search_pattern dn c] returns all terms/patterns in dn
     matching/matched by c *)
  val search_pattern : t -> constr -> ident list

  (** [find_all dn] returns all idents contained in dn *)
  val find_all : t -> ident list

end
=
struct
  module Ident = HintIdent
  module TDnet : Dnet.S with type ident=Ident.t
                        and  type 'a structure = 'a DTerm.t
                        and  type meta = int
    = Dnet.Make(DTerm)(Ident)(Int)

  type t = TDnet.t

  type ident = TDnet.ident

  (** We will freshen metas on the fly, to cope with the implementation defect
      of Term_dnet which requires metas to be all distinct. *)
  let fresh_meta =
    let index = ref 0 in
    fun () ->
      let ans = !index in
      let () = index := succ ans in
      ans

  open DTerm
  open TDnet

  let pat_of_constr c : term_pattern =
    let open GlobRef in
    (* To each evar we associate a unique identifier. *)
    let metas = ref Evar.Map.empty in
    let rec pat_of_constr c = match Constr.kind c with
    | Rel _          -> Term DRel
    | Sort _         -> Term DSort
    | Var i          -> Term (DRef (VarRef i))
    | Const (c,u)    -> Term (DRef (ConstRef c))
    | Ind (i,u)      -> Term (DRef (IndRef i))
    | Construct (c,u)-> Term (DRef (ConstructRef c))
    | Meta _         -> assert false
    | Evar (i,_)     ->
      let meta =
        try Evar.Map.find i !metas
        with Not_found ->
          let meta = fresh_meta () in
          let () = metas := Evar.Map.add i meta !metas in
          meta
      in
      Meta meta
    | Case (ci,u1,pms1,c1,_iv,c2,ca)     ->
      let f_ctx (_, p) = pat_of_constr p in
      Term(DCase(ci,f_ctx c1,pat_of_constr c2,Array.map f_ctx ca))
    | Fix ((ia,i),(_,ta,ca)) ->
      Term(DFix(ia,i,Array.map pat_of_constr ta, Array.map pat_of_constr ca))
    | CoFix (i,(_,ta,ca))    ->
      Term(DCoFix(i,Array.map pat_of_constr ta,Array.map pat_of_constr ca))
    | Cast (c,_,_)   -> pat_of_constr c
    | Lambda (_,t,c) -> Term(DLambda (pat_of_constr t, pat_of_constr c))
    | (Prod _ | LetIn _)   ->
      let (ctx,c) = ctx_of_constr (Term DNil) c in Term (DCtx (ctx,c))
    | App (f,ca)     ->
      Array.fold_left (fun c a -> Term (DApp (c,a)))
        (pat_of_constr f) (Array.map pat_of_constr ca)
    | Proj (p,c) ->
        Term (DApp (Term (DRef (ConstRef (Projection.constant p))), pat_of_constr c))
    | Int i -> Term (DInt i)
    | Float f -> Term (DFloat f)
    | Array (_u,t,def,ty) ->
      Term (DArray (Array.map pat_of_constr t, pat_of_constr def, pat_of_constr ty))

    and ctx_of_constr ctx c = match Constr.kind c with
    | Prod (_,t,c)   -> ctx_of_constr (Term(DCons((pat_of_constr t,None),ctx))) c
    | LetIn(_,d,t,c) -> ctx_of_constr (Term(DCons((pat_of_constr t, Some (pat_of_constr d)),ctx))) c
    | _ -> ctx,pat_of_constr c
    in
    pat_of_constr c

  let empty_ctx : term_pattern -> term_pattern = function
    | Meta _ as c -> c
    | Term (DCtx(_,_)) as c -> c
    | c -> Term (DCtx (Term DNil, c))

  (*
   * Basic primitives
   *)

  let empty = TDnet.empty

  let add (c:constr) (id:Ident.t) (dn:t) =
    let c = empty_ctx (pat_of_constr c) in
    TDnet.add dn c id

  let new_meta () = Meta (fresh_meta ())

  let rec remove_cap : term_pattern -> term_pattern = function
    | Term (DCons (t,u)) -> Term (DCons (t,remove_cap u))
    | Term DNil -> new_meta()
    | Meta _ as m -> m
    | _ -> assert false

  let under_prod : term_pattern -> term_pattern = function
    | Term (DCtx (t,u)) -> Term (DCtx (remove_cap t,u))
    | Meta m -> Term (DCtx(new_meta(), Meta m))
    | _ -> assert false

  (* debug *)
(*  let rec pr_term_pattern p =
    (fun pr_t -> function
       | Term t -> pr_t t
       | Meta m -> str"["++Pp.int (Obj.magic m)++str"]"
    ) (pr_dconstr pr_term_pattern) p*)

(* App(c,[t1,...tn]) -> ([c,t1,...,tn-1],tn)
   App(c,[||]) -> ([],c) *)
let split_app sigma c = match EConstr.kind sigma c with
    App(c,l) ->
      let len = Array.length l in
      if Int.equal len 0 then ([],c) else
        let last = Array.get l (len-1) in
        let prev = Array.sub l 0 (len-1) in
        c::(Array.to_list prev), last
  | _ -> assert false

exception CannotFilter

let filtering env sigma cv_pb c1 c2 =
  let open EConstr in
  let open Vars in
  let evm = ref Evar.Map.empty in
  let define cv_pb e1 ev c1 =
    try let (e2,c2) = Evar.Map.find ev !evm in
    let shift = e1 - e2 in
    if Termops.constr_cmp sigma cv_pb c1 (lift shift c2) then () else raise CannotFilter
    with Not_found ->
      evm := Evar.Map.add ev (e1,c1) !evm
  in
  let rec aux env cv_pb c1 c2 =
    match EConstr.kind sigma c1, EConstr.kind sigma c2 with
      | App _, App _ ->
        let ((p1,l1),(p2,l2)) = (split_app sigma c1),(split_app sigma c2) in
        let () = aux env cv_pb l1 l2 in
        begin match p1, p2 with
        | [], [] -> ()
        | (h1 :: p1), (h2 :: p2) ->
          aux env cv_pb (applist (h1, p1)) (applist (h2, p2))
        | _ -> assert false
        end
      | Prod (n,t1,c1), Prod (_,t2,c2) ->
          aux env cv_pb t1 t2;
          aux (env + 1) cv_pb c1 c2
      | _, Evar (ev,_) -> define cv_pb env ev c1
      | Evar (ev,_), _ -> define cv_pb env ev c2
      | _ ->
          if Termops.compare_constr_univ sigma
          (fun pb c1 c2 -> aux env pb c1 c2; true) cv_pb c1 c2 then ()
          else raise CannotFilter
          (* TODO: le reste des binders *)
  in
  try let () = aux env cv_pb c1 c2 in true with CannotFilter -> false

let align_prod_letin sigma c a =
  let open Termops in
  let (lc,_) = EConstr.decompose_prod_assum sigma c in
  let (l,a) = EConstr.decompose_prod_assum sigma a in
  let lc = List.length lc in
  let n = List.length l in
  if n < lc then invalid_arg "align_prod_letin";
  let l1 = CList.firstn lc l in
  n - lc, it_mkProd_or_LetIn a l1

  let search_pat cpat dpat dn =
    let whole_c = EConstr.of_constr cpat in
    (* if we are at the root, add an empty context *)
    let dpat = under_prod (empty_ctx dpat) in
    TDnet.Idset.fold
      (fun id acc ->
         let c_id = EConstr.of_constr @@ Ident.constr_of id in
         let (ctx,wc) =
           try align_prod_letin Evd.empty whole_c c_id (* FIXME *)
           with Invalid_argument _ -> 0, c_id in
        if filtering ctx Evd.empty Reduction.CUMUL whole_c wc then id :: acc
        else acc
      ) (TDnet.find_match dpat dn) []

  (*
   * High-level primitives describing specific search problems
   *)

  let search_pattern dn pat =
    search_pat pat (empty_ctx (pat_of_constr pat)) dn

  let find_all dn = Idset.elements (TDnet.find_all dn)

end

(* Summary and Object declaration *)
let rewtab =
  Summary.ref (String.Map.empty : HintDN.t String.Map.t) ~name:"autorewrite"

let raw_find_base bas = String.Map.find bas !rewtab

let find_base bas =
  try raw_find_base bas
  with Not_found ->
    user_err
      (str "Rewriting base " ++ str bas ++ str " does not exist.")

let find_rewrites bas =
  List.rev_map snd (HintDN.find_all (find_base bas))

let find_matches bas pat =
  let base = find_base bas in
  let res = HintDN.search_pattern base pat in
  List.map snd res

let print_rewrite_hintdb bas =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  (str "Database " ++ str bas ++ fnl () ++
           prlist_with_sep fnl
           (fun h ->
             str (if h.rew_l2r then "rewrite -> " else "rewrite <- ") ++
               Printer.pr_lconstr_env env sigma h.rew_lemma ++ str " of type " ++ Printer.pr_lconstr_env env sigma h.rew_type ++
               Option.cata (fun tac -> str " then use tactic " ++
               Pputils.pr_glb_generic env sigma tac) (mt ()) h.rew_tac)
           (find_rewrites bas))

type raw_rew_rule = (constr Univ.in_universe_context_set * bool * Genarg.raw_generic_argument option) CAst.t

(* Applies all the rules of one base *)
let one_base general_rewrite_maybe_in tac_main bas =
  let lrul = find_rewrites bas in
  let try_rewrite dir ctx c tc =
  Proofview.Goal.enter begin fun gl ->
    let sigma = Proofview.Goal.sigma gl in
    let subst, ctx' = UnivGen.fresh_universe_context_set_instance ctx in
    let c' = Vars.subst_univs_level_constr subst c in
    let sigma = Evd.merge_context_set Evd.univ_flexible sigma ctx' in
    Proofview.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
    (general_rewrite_maybe_in dir c' tc)
  end in
  let open Proofview.Notations in
  Proofview.tclProofInfo [@ocaml.warning "-3"] >>= fun (_name, poly) ->
  let lrul = List.map (fun h ->
  let tac = match h.rew_tac with
  | None -> Proofview.tclUNIT ()
  | Some (Genarg.GenArg (Genarg.Glbwit wit, tac)) ->
    let ist = { Geninterp.lfun = Id.Map.empty
              ; poly
              ; extra = Geninterp.TacStore.empty } in
    Ftactic.run (Geninterp.interp wit ist tac) (fun _ -> Proofview.tclUNIT ())
  in
    (h.rew_ctx,h.rew_lemma,h.rew_l2r,tac)) lrul in
    Tacticals.tclREPEAT_MAIN (Proofview.tclPROGRESS (List.fold_left (fun tac (ctx,csr,dir,tc) ->
      Tacticals.tclTHEN tac
        (Tacticals.tclREPEAT_MAIN
            (Tacticals.tclTHENFIRST (try_rewrite dir ctx csr tc) tac_main)))
      (Proofview.tclUNIT()) lrul))

(* The AutoRewrite tactic *)
let autorewrite ?(conds=Naive) tac_main lbas =
  Tacticals.tclREPEAT_MAIN (Proofview.tclPROGRESS
    (List.fold_left (fun tac bas ->
       Tacticals.tclTHEN tac
        (one_base (fun dir c tac ->
          let tac = (tac, conds) in
            general_rewrite ~where:None ~l2r:dir AllOccurrences ~freeze:true ~dep:false ~with_evars:false ~tac (EConstr.of_constr c, Tactypes.NoBindings))
          tac_main bas))
      (Proofview.tclUNIT()) lbas))

let autorewrite_multi_in ?(conds=Naive) idl tac_main lbas =
  Proofview.Goal.enter begin fun gl ->
 (* let's check at once if id exists (to raise the appropriate error) *)
  let _ = List.map (fun id -> Tacmach.pf_get_hyp id gl) idl in
  let general_rewrite_in id dir cstr tac =
    let cstr = EConstr.of_constr cstr in
    general_rewrite ~where:(Some id) ~l2r:dir AllOccurrences ~freeze:true ~dep:false ~with_evars:false ~tac:(tac, conds) (cstr, Tactypes.NoBindings)
  in
 Tacticals.tclMAP (fun id ->
  Tacticals.tclREPEAT_MAIN (Proofview.tclPROGRESS
    (List.fold_left (fun tac bas ->
       Tacticals.tclTHEN tac (one_base (general_rewrite_in id) tac_main bas)) (Proofview.tclUNIT()) lbas)))
   idl
 end

let autorewrite_in ?(conds=Naive) id = autorewrite_multi_in ~conds [id]

let gen_auto_multi_rewrite conds tac_main lbas cl =
  let try_do_hyps treat_id l =
    autorewrite_multi_in ~conds (List.map treat_id l) tac_main lbas
  in
  if not (Locusops.is_all_occurrences cl.concl_occs) &&
     cl.concl_occs != NoOccurrences
  then
    let info = Exninfo.reify () in
    Tacticals.tclZEROMSG ~info (str"The \"at\" syntax isn't available yet for the autorewrite tactic.")
  else
    let compose_tac t1 t2 =
      match cl.onhyps with
        | Some [] -> t1
        | _ ->      Tacticals.tclTHENFIRST t1 t2
    in
    compose_tac
        (if cl.concl_occs != NoOccurrences then autorewrite ~conds tac_main lbas else Proofview.tclUNIT ())
        (match cl.onhyps with
           | Some l -> try_do_hyps (fun ((_,id),_) -> id) l
           | None ->
                 (* try to rewrite in all hypothesis
                    (except maybe the rewritten one) *)
               Proofview.Goal.enter begin fun gl ->
                 let ids = Tacmach.pf_ids_of_hyps gl in
                 try_do_hyps (fun id -> id)  ids
               end)

let auto_multi_rewrite ?(conds=Naive) lems cl =
  Proofview.wrap_exceptions (fun () -> gen_auto_multi_rewrite conds (Proofview.tclUNIT()) lems cl)

let auto_multi_rewrite_with ?(conds=Naive) tac_main lbas cl =
  let onconcl = match cl.Locus.concl_occs with NoOccurrences -> false | _ -> true in
  match onconcl,cl.Locus.onhyps with
    | false,Some [_] | true,Some [] | false,Some [] ->
        (* autorewrite with .... in clause using tac n'est sur que
           si clause represente soit le but soit UNE hypothese
        *)
        Proofview.wrap_exceptions (fun () -> gen_auto_multi_rewrite conds tac_main lbas cl)
    | _ ->
      let info = Exninfo.reify () in
      Tacticals.tclZEROMSG ~info
        (strbrk "autorewrite .. in .. using can only be used either with a unique hypothesis or on the conclusion.")

(* Functions necessary to the library object declaration *)
let cache_hintrewrite (rbase,lrl) =
  let base = try raw_find_base rbase with Not_found -> HintDN.empty in
  let max = try fst (Util.List.last (HintDN.find_all base)) with Failure _ -> 0 in
  let fold i accu r = HintDN.add r.rew_pat (i + max + 1, r) accu in
  let base = List.fold_left_i fold 0 base lrl in
  rewtab := String.Map.add rbase base !rewtab

let subst_hintrewrite (subst,(rbase,list as node)) =
  let list' = List.Smart.map (fun h -> subst_hint subst h) list in
    if list' == list then node else
      (rbase,list')

(* Declaration of the Hint Rewrite library object *)
let inGlobalHintRewrite : string * rew_rule list -> Libobject.obj =
  let open Libobject in
  declare_object @@ superglobal_object_nodischarge "HINT_REWRITE_GLOBAL"
    ~cache:cache_hintrewrite
    ~subst:(Some subst_hintrewrite)

let inExportHintRewrite : string * rew_rule list -> Libobject.obj =
  let open Libobject in
  declare_object @@ global_object_nodischarge ~cat:Hints.hint_cat "HINT_REWRITE_EXPORT"
    ~cache:cache_hintrewrite
    ~subst:(Some subst_hintrewrite)

type hypinfo = {
  hyp_ty : EConstr.types;
  hyp_pat : EConstr.constr;
}

let decompose_applied_relation env sigma c ctype left2right =
  let find_rel ty =
    (* FIXME: this is nonsense, we generate evars and then we drop the
       corresponding evarmap. This sometimes works because [Term_dnet] performs
       evar surgery via [Termops.filtering]. *)
    let sigma, ty = Clenv.make_evar_clause env sigma ty in
    let (_, args) = Termops.decompose_app_vect sigma ty.Clenv.cl_concl in
    let len = Array.length args in
    if 2 <= len then
      let c1 = args.(len - 2) in
      let c2 = args.(len - 1) in
      Some (if left2right then c1 else c2)
    else None
  in
    match find_rel ctype with
    | Some c -> Some { hyp_pat = c; hyp_ty = ctype }
    | None ->
        let ctx,t' = Reductionops.splay_prod_assum env sigma ctype in (* Search for underlying eq *)
        let ctype = it_mkProd_or_LetIn t' ctx in
        match find_rel ctype with
        | Some c -> Some { hyp_pat = c; hyp_ty = ctype }
        | None -> None

let find_applied_relation ?loc env sigma c left2right =
  let ctype = Retyping.get_type_of env sigma (EConstr.of_constr c) in
    match decompose_applied_relation env sigma c ctype left2right with
    | Some c -> c
    | None ->
        user_err ?loc
                    (str"The type" ++ spc () ++ Printer.pr_econstr_env env sigma ctype ++
                       spc () ++ str"of this term does not end with an applied relation.")

let warn_deprecated_hint_rewrite_without_locality =
  CWarnings.create ~name:"deprecated-hint-rewrite-without-locality" ~category:"deprecated"
    (fun () -> strbrk "The default value for rewriting hint locality is currently \
    \"local\" in a section and \"global\" otherwise, but is scheduled to change \
    in a future release. For the time being, adding rewriting hints outside of sections \
    without specifying an explicit locality attribute is therefore deprecated. It is \
    recommended to use \"export\" whenever possible. Use the attributes \
    #[local], #[global] and #[export] depending on your choice. For example: \
    \"#[export] Hint Rewrite foo : bar.\" This is supported since Coq 8.14.")

let default_hint_rewrite_locality () =
  if Global.sections_are_opened () then Hints.Local
  else
    let () = warn_deprecated_hint_rewrite_without_locality () in
    Hints.SuperGlobal

(* To add rewriting rules to a base *)
let add_rew_rules ~locality base lrul =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let ist = Genintern.empty_glob_sign (Global.env ()) in
  let intern tac = snd (Genintern.generic_intern ist tac) in
  let map {CAst.loc;v=((c,ctx),b,t)} =
    let sigma = Evd.merge_context_set Evd.univ_rigid sigma ctx in
    let info = find_applied_relation ?loc env sigma c b in
    let pat = EConstr.Unsafe.to_constr info.hyp_pat in
    { rew_lemma = c; rew_type = EConstr.Unsafe.to_constr info.hyp_ty;
      rew_pat = pat; rew_ctx = ctx; rew_l2r = b;
      rew_tac = Option.map intern t }
  in
  let lrul = List.map map lrul in
  let open Hints in
  match locality with
  | Local -> cache_hintrewrite (base,lrul)
  | SuperGlobal ->
    let () =
      if Global.sections_are_opened () then
      CErrors.user_err Pp.(str
        "This command does not support the global attribute in sections.");
    in
    Lib.add_leaf (inGlobalHintRewrite (base,lrul))
  | Export ->
    let () =
      if Global.sections_are_opened () then
        CErrors.user_err Pp.(str
          "This command does not support the export attribute in sections.");
    in
    Lib.add_leaf (inExportHintRewrite (base,lrul))
