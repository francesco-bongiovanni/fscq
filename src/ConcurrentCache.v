Require Import EventCSL.
Require Import EventCSLauto.
Require Import Hlist.
Require Import Star.
Require Import Coq.Program.Equality.
Require Import FunctionalExtensionality.
Require Import FMapAVL.
Require Import FMapFacts.
Require Word.

Require Import List.
Import List.ListNotations.
Open Scope list.

Module AddrM <: Word.WordSize.
                 Definition sz := addrlen.
                 Definition word := word sz.
End AddrM.

Module Addr_as_OT := Word_as_OT AddrM.

Module Map := FMapAVL.Make(Addr_as_OT).
Module MapFacts := WFacts_fun Addr_as_OT Map.
Module MapProperties := WProperties_fun Addr_as_OT Map.

Section MemCache.

  Inductive cache_entry : Set :=
  | Clean :  valu -> cache_entry
  | Dirty :  valu -> cache_entry.

  Definition AssocCache := Map.t cache_entry.
  Definition cache_add (c:AssocCache) a v := Map.add a (Clean v) c.

  (* returns (dirty, v) *)
  Definition cache_get (c:AssocCache) (a0:addr) : option (bool * valu) :=
    match (Map.find a0 c) with
    | Some (Clean v) => Some (false, v)
    | Some (Dirty v) => Some (true, v)
    | None => None
    end.

  Definition cache_dirty (c:AssocCache) (a:addr) v' :=
    match (Map.find a c) with
    | Some (Clean _) => Map.add a v' c
    | Some (Dirty _) => Map.add a v' c
    | None => c
    end.

  Definition cache_add_dirty (c:AssocCache) (a:addr) v' :=
    Map.add a (Dirty v') c.

  Definition cache_mem c : DISK :=
    fun (a:addr) =>
      match (cache_get c a) with
      | None => None
      | Some (_, v) => Some v
      end.

  (** Evict a clean address *)
  Definition cache_evict (c:AssocCache) (a:addr) :=
    match (Map.find a c) with
    | Some (Clean _) => Map.remove a c
    (* dirty/miss *)
    | _ => c
    end.

  (** Change a dirty mapping to a clean one, keeping the same
  value. Intended for use after writeback. *)
  Definition cache_clean (c:AssocCache) (a:addr) :=
    match (Map.find a c) with
    | Some (Dirty v) => Map.add a (Clean v) c
    | _ => c
    end.

End MemCache.

Inductive MutexOwner : Set :=
| NoOwner
| Owned (id:ID).

Definition Scontents := [DISK; AssocCache; MutexOwner].

Definition GDisk : var Scontents _ := HFirst.
Definition GCache : var Scontents _ := HNext HFirst.
Definition GCacheL : var Scontents _ := HNext (HNext HFirst).

Definition S := hlist (fun T:Set => T) Scontents.

Definition Mcontents := [AssocCache; Mutex].

Definition virt_disk (s:S) : DISK := get GDisk s.

Hint Unfold virt_disk : prog.

Definition Cache : var Mcontents _ := HFirst.

Definition CacheL : var Mcontents _ := HNext HFirst.

Hint Unfold cache_mem : prog.

Definition cache_pred c vd : @pred addr (@weq addrlen) valu :=
  fun d => vd = mem_union (cache_mem c) d /\
         (* this is only true for the clean addresses *)
         (forall a v, cache_get c a = Some (false, v) -> d a = Some v) /\
         (* there's something on disk for even dirty addresses *)
         (forall a v, cache_get c a = Some (true, v) -> exists v', d a = Some v').

(** given a lock variable and some other variable v, generate a
relation for tid that makes the variable read-only for non-owners. *)
Definition lock_protects (lvar : var Scontents MutexOwner)
           {tv} (v : var Scontents tv) tid (s s' : S) :=
  forall owner_tid,
    get lvar s = Owned owner_tid ->
    tid <> owner_tid ->
    get v s' = get v s.

Inductive lock_protocol (lvar : var Scontents MutexOwner) (tid : ID) :  S -> S -> Prop :=
| NoChange : forall s s', get lvar s  = get lvar s' ->
                     lock_protocol lvar tid s s'
| OwnerRelease : forall s s', get lvar s = Owned tid ->
                         get lvar s' = NoOwner ->
                         lock_protocol lvar tid s s'
| OwnerAcquire : forall s s', get lvar s = NoOwner ->
                         get lvar s' = Owned tid ->
                         lock_protocol lvar tid s s'.

Hint Constructors lock_protocol.

Variable diskR : DISK -> DISK -> Prop.

Hypothesis diskR_stutter : forall vd, diskR vd vd.

Hint Resolve diskR_stutter.

Definition cacheR tid : Relation S :=
  fun s s' =>
    lock_protocol GCacheL tid s s' /\
    lock_protects GCacheL GCache tid s s' /\
    lock_protects GCacheL GDisk tid s s' /\
    let vd := virt_disk s in
    let vd' := virt_disk s' in
    (forall a v, vd a = Some v -> exists v', vd' a = Some v') /\
    diskR vd vd'.

Inductive ghost_lock_invariant
          (lvar : var Mcontents Mutex)
          (glvar : var Scontents MutexOwner)
          (m : M Mcontents) (s : S) : Prop :=
| LockOpen : get lvar m = Open -> get glvar s = NoOwner ->
             ghost_lock_invariant lvar glvar m s
| LockOwned : forall tid, get lvar m = Locked -> get glvar s = Owned tid ->
                     ghost_lock_invariant lvar glvar m s.

Hint Constructors ghost_lock_invariant.

Definition cacheI : Invariant Mcontents S :=
  fun m s d =>
    let c := get Cache m in
    (d |= cache_pred c (virt_disk s))%judgement /\
    ghost_lock_invariant CacheL GCacheL m s /\
    (* mirror cache for sake of lock_protects *)
    get Cache m = get GCache s.

(* for now, we don't have any lemmas about the lock semantics so just operate
on the definitions directly *)
Hint Unfold lock_protects : prog.
Hint Unfold cacheR cacheI : prog.

Ltac solve_get_set :=
  simpl_get_set;
  try match goal with
      | [ |- _ =p=> _ ] => cancel
      | [ |- ?p _ ] => match type of p with
                      | pred => solve [ pred_apply; cancel; eauto ]
                      end
      end.

Hint Extern 4 (get _ (set _ _ _) = _) => solve_get_set.
Hint Extern 4 (_ = get _ (set _ _ _)) => solve_get_set.

Ltac dispatch :=
  intros; subst;
  cbn in *;
  (repeat match goal with
          | [ |- _ /\ _ ] => intuition
          | [ |- exists _, _ ] => eexists
          | [ H: context[get _ (set _ _ _)] |- _ ] => simpl_get_set_hyp H
          | _ => solve_get_set
          end); eauto;
  try match goal with
      | [ |- star (StateR' _ _) _ _ ] =>
        unfold StateR', othersR;
          eapply star_step; [| apply star_refl];
          eauto 10
      end.

Definition cacheS : transitions Mcontents S :=
  Build_transitions cacheR cacheI.

Hint Rewrite get_set.

Ltac valid_match_opt :=
  match goal with
  | [ |- valid _ _ _ _ (match ?discriminee with
                       | _ => _
                       end) ] =>
    case_eq discriminee; intros;
    try match goal with
    | [ cache_entry : bool * valu |- _ ] =>
      destruct cache_entry as [ [] ]
    end
  end.

Ltac cache_contents_eq :=
  match goal with
  | [ H: cache_get ?c ?a = ?v1, H2 : cache_get ?c ?a = ?v2 |- _ ] =>
    assert (v1 = v2) by (
                         rewrite <- H;
                         rewrite <- H2;
                         auto)
  end; inv_opt.


Ltac inv_protocol :=
  match goal with
  | [ H: lock_protocol _ _ _ _ |- _ ] =>
    inversion H; subst; try congruence
  end.

Lemma cache_readonly' : forall tid s s',
    get GCacheL s = Owned tid ->
    othersR cacheR tid s s' ->
    get GCache s' = get GCache s /\
    get GCacheL s' = Owned tid.
Proof.
  repeat (autounfold with prog).
  unfold othersR.
  intros.
  deex; eauto; inv_protocol.
Qed.

Lemma cache_readonly : forall tid s s',
    get GCacheL s = Owned tid ->
    star (othersR cacheR tid) s s' ->
    get GCache s' = get GCache s /\
    get GCacheL s' = Owned tid.
Proof.
  intros.
  eapply (star_invariant _ _ (cache_readonly' tid));
    intuition eauto; try congruence.
Qed.

Lemma virt_disk_readonly' : forall tid s s',
    get GCacheL s = Owned tid ->
    othersR cacheR tid s s' ->
    get GDisk s' = get GDisk s /\
    get GCacheL s' = Owned tid.
Proof.
  repeat (autounfold with prog).
  unfold othersR.
  intros.
  deex; eauto; inv_protocol.
Qed.

Lemma virt_disk_readonly : forall tid s s',
    get GCacheL s = Owned tid ->
    star (othersR cacheR tid) s s' ->
    get GDisk s' = get GDisk s /\
    get GCacheL s' = Owned tid.
Proof.
  intros.
  eapply (star_invariant _ _ (virt_disk_readonly' tid));
    intuition eauto; try congruence.
Qed.

Lemma sectors_unchanged' : forall tid s s',
    othersR cacheR tid s s' ->
    let vd := virt_disk s in
    let vd' := virt_disk s' in
    (forall a v, vd a = Some v ->
            exists v', vd' a = Some v').
Proof.
  unfold othersR, cacheR.
  intros.
  deex; eauto.
Qed.

Lemma sectors_unchanged'' : forall tid s s',
    star (othersR cacheR tid) s s' ->
    let vd := virt_disk s in
    let vd' := virt_disk s' in
    (forall a, (exists v, vd a = Some v) ->
            exists v', vd' a = Some v').
Proof.
  induction 1; intros; eauto.
  deex.
  eapply sectors_unchanged' in H; eauto.
Qed.

Lemma sectors_unchanged : forall tid s s',
    star (othersR cacheR tid) s s' ->
    let vd := virt_disk s in
    let vd' := virt_disk s' in
    (forall a v, vd a = Some v ->
            exists v', vd' a = Some v').
Proof.
  intros.
  subst vd vd'.
  eauto using sectors_unchanged''.
Qed.

Lemma star_diskR : forall tid s s',
    star (othersR cacheR tid) s s' ->
    star diskR (virt_disk s) (virt_disk s').
Proof.
  induction 1; eauto.
  eapply star_trans; try eassumption.
  eapply star_step; [| eauto].
  unfold othersR, cacheR in *; deex.
Qed.

Ltac remove_duplicate :=
  match goal with
  | [ H: ?p, H': ?p |- _ ] =>
    match type of p with
    | Prop => clear H'
    end
  end.

Ltac remove_refl :=
  match goal with
  | [ H: ?a = ?a |- _ ] => clear dependent H
  end.

Ltac remove_sym_neq :=
  match goal with
  | [ H: ?a <> ?a', H': ?a' <> ?a |- _ ] => clear dependent H'
  end.

Ltac cleanup :=
  repeat (remove_duplicate
            || remove_refl
            || remove_sym_neq);
  try congruence.

Hint Extern 4 (get _ (set _ _ _) = _) => simpl_get_set : prog.
Hint Extern 4 (_ = get _ (set _ _ _)) => simpl_get_set : prog.

Ltac mem_contents_eq :=
  match goal with
  | [ H: get ?m ?var = _, H': get ?m ?var = _ |- _ ] =>
    rewrite H in H';
      try inversion H';
      subst
  end.

Ltac learn_tac H t :=
  let H' := fresh in
  pose proof H as H';
    t;
    lazymatch type of H with
    | ?t =>
      try lazymatch goal with
        | [ Hcopy: t, H: t |- _ ] =>
          fail 1 "already know that"
        end
    end.

Tactic Notation "learn" hyp(H) tactic(t) := learn_tac H t.

Ltac star_readonly thm :=
  match goal with
  | [ H: star _ _ _ |- _ ] =>
    learn H (apply thm in H; [| cbn; now auto ];
      cbn in H;
      destruct H)
  end.

Ltac cache_locked := star_readonly cache_readonly.
Ltac disk_locked := star_readonly virt_disk_readonly.
Ltac sectors_unchanged := match goal with
                          | [ H: star _ _ _ |- _ ] =>
                            let H' := fresh in
                            pose proof (sectors_unchanged _ _ _ H) as H';
                              cbn in H'
                          end.
Ltac star_diskR := match goal with
                   | [ H: star _ _ _ |- _ ] =>
                     learn H (apply star_diskR in H;
                              cbn in H)
                   end.

Ltac learn_invariants :=
  try cache_locked;
  try disk_locked;
  try sectors_unchanged;
  try star_diskR.

(** These proofs are still very messy. There's a lot of low-level
manipulations of memories to prove/use the cache_pred in service of
re-representing the disk as disk + cache. *)

Lemma ptsto_valid_iff : forall AT AEQ V a v (m : @mem AT AEQ V),
    m a = Some v ->
    (any * a |-> v)%pred m.
Proof.
  intros.
  unfold_sep_star.
  exists (mem_except m a).
  exists (fun a0 => if (AEQ a0 a) then Some v else None).
  intuition.
  apply functional_extensionality; intro a0.
  unfold mem_union.
  unfold mem_except.
  case_eq (AEQ a0 a); intros; subst; eauto.
  case_eq (m a0); eauto.
  unfold mem_disjoint, mem_except.
  intro.
  repeat deex.
  case_eq (AEQ a0 a); intros.
  rewrite H0 in *.
  congruence.
  rewrite H0 in *.
  congruence.
  unfold any; auto.
  unfold ptsto; intuition.
  case_eq (AEQ a a); intros; auto; congruence.
  case_eq (AEQ a' a); intros; auto; congruence.
Qed.

Hint Unfold cache_pred cache_mem mem_union : cache.

Ltac replace_cache_vals :=
  repeat
    match goal with
    | [ H: context[cache_get ?c ?a], Heq: cache_get ?c ?a = _ |- _ ] =>
      replace (cache_get c a) in H
    | [ Heq: cache_get ?c ?a = _ |- context[cache_get ?c ?a] ] =>
      replace (cache_get c a)
    end.

Ltac disk_equalities :=
  repeat
    lazymatch goal with
    | [ a: addr, H: @eq DISK _ _ |- _ ] =>
      learn H (apply equal_f with a in H);
        replace_cache_vals
    | [ |- @eq DISK _ _ ] =>
      apply functional_extensionality; intro a'
    end.

Hint Extern 3 (eq _ _) => congruence : mem_equalities.

Hint Unfold Map.key AddrM.word AddrM.sz : cache_m.

Ltac prove_cache_pred :=
  intros;
  autounfold with cache_m in *;
  repeat match goal with
  | [ |- context[cache_pred] ] =>
    autounfold with cache; intuition;
    disk_equalities
  | [ H_cache_pred: context[cache_pred] |- _ ] =>
    autounfold with cache in H_cache_pred; intuition;
    disk_equalities
  end; try congruence; eauto with core mem_equalities.

Hint Resolve ptsto_valid_iff.
Lemma cache_pred_miss : forall c a v vd,
    cache_get c a = None ->
    vd a = Some v ->
    cache_pred c vd =p=> any * a |-> v.
Proof.
  unfold pimpl.
  prove_cache_pred.
Qed.

Lemma cache_miss_mem_eq : forall c vd a d,
    cache_pred c vd d ->
    cache_get c a = None ->
    vd a = d a.
Proof.
  prove_cache_pred.
Qed.

Ltac distinguish_two_addresses a1 a2 :=
    case_eq (weq a1 a2);
      case_eq (weq a2 a1);
      case_eq (weq a1 a1);
      intros;
      subst;
      cbn;
      try replace (weq a1 a2) in *;
      try replace (weq a2 a1) in *;
      try replace (weq a1 a1) in *;
      try congruence.

Lemma weq_same : forall sz a,
    @weq sz a a = left (eq_refl a).
Proof.
  intros.
  case_eq (weq a a); intros; try congruence.
  f_equal.
  apply proof_irrelevance.
Qed.

Ltac distinguish_addresses :=
  try match goal with
  | [ a1 : addr, a2 : addr |- _ ] =>
    match goal with
      | [ H: context[if (weq a1 a2) then _ else _] |- _] =>
        distinguish_two_addresses a1 a2
      | [ |- context[if (weq a1 a2) then _ else _] ] =>
        distinguish_two_addresses a1 a2
    end
  | [ a1 : addr, a2 : addr |- _ ] =>
    distinguish_two_addresses a1 a2
  | [ H : context[weq ?a ?a] |- _ ] =>
    progress (rewrite weq_same in H)
  | [ |- context[weq ?a ?a] ] =>
    progress (rewrite weq_same)
  end;
  cleanup.

Lemma cache_pred_except : forall c vd m a,
    cache_get c a = None ->
    cache_pred c vd m ->
    cache_pred c (mem_except vd a) (mem_except m a).
Proof.
  unfold mem_except.
  prove_cache_pred;
    distinguish_addresses;
    replace_cache_vals;
    eauto.
Qed.

Lemma cache_pred_address : forall c vd a v,
    cache_get c a = None ->
    vd a = Some v ->
    cache_pred c vd =p=>
cache_pred c (mem_except vd a) * a |-> v.
Proof.
  unfold pimpl.
  intros.
  unfold_sep_star.
  exists (mem_except m a).
  exists (fun a' => if weq a' a then Some v else None).
  unfold mem_except.
  prove_cache_pred; distinguish_addresses; replace_cache_vals; eauto.
  destruct (m a'); auto.
  unfold mem_disjoint; intro; repeat deex.
  distinguish_addresses.
  disk_equalities; distinguish_addresses; replace_cache_vals; auto.
  unfold ptsto; intuition; distinguish_addresses.
Qed.

Hint Resolve cache_pred_address.

Ltac destruct_matches_in e :=
  lazymatch e with
  | context[match ?d with | _ => _ end] =>
    destruct_matches_in d
  | _ => case_eq e; intros
  end.

Ltac simpl_matches :=
  repeat match goal with
          | [H: context[match ?d with | _ => _ end], Heq: ?d = _ |- _ ] =>
            rewrite Heq in H
         | [ |- context[match ?d with | _ => _ end] ] =>
           replace d
         | [ H: context[match ?d with | _ => _ end] |- _ ] =>
           replace d in H
          end.

Ltac destruct_matches :=
  repeat (simpl_matches;
           try match goal with
           | [ |- context[match ?d with | _ => _ end] ] =>
              destruct_matches_in d
           | [ H: context[match ?d with | _ => _ end] |- _ ] =>
             destruct_matches_in d
           end);
  subst;
  try congruence.

Ltac destruct_goal_matches :=
  repeat (simpl_matches;
           match goal with
           | [ |- context[match ?d with | _ => _ end] ] =>
              destruct_matches_in d
           end);
  try congruence.

Ltac remove_rewrite :=
  try rewrite MapFacts.remove_eq_o in * by auto;
  try rewrite MapFacts.remove_neq_o in * by auto.

Lemma cache_get_find_clean : forall c a v,
    cache_get c a = Some (false, v) <->
    Map.find a c = Some (Clean v).
Proof.
  unfold cache_get; intros.
  split; destruct_matches.
Qed.

Lemma cache_get_find_dirty : forall c a v,
    cache_get c a = Some (true, v) <->
    Map.find a c = Some (Dirty v).
Proof.
  unfold cache_get; intros.
  split; destruct_matches.
Qed.

Lemma cache_get_find_empty : forall c a,
    cache_get c a = None <->
    Map.find a c = None.
Proof.
  unfold cache_get; intros.
  split; destruct_matches.
Qed.

Ltac cache_get_add :=
  unfold cache_get, cache_add, cache_add_dirty, cache_evict;
  intros;
  try rewrite MapFacts.add_eq_o by auto;
  try rewrite MapFacts.add_neq_o by auto;
  auto.

Lemma cache_get_eq : forall c a v,
    cache_get (cache_add c a v) a = Some (false, v).
Proof.
  cache_get_add.
Qed.

Lemma cache_get_dirty_eq : forall c a v,
    cache_get (cache_add_dirty c a v) a = Some (true, v).
Proof.
  cache_get_add.
Qed.

Lemma cache_get_dirty_neq : forall c a a' v,
    a <> a' ->
    cache_get (cache_add_dirty c a v) a' = cache_get c a'.
Proof.
  cache_get_add.
Qed.

Lemma cache_get_neq : forall c a a' v,
    a <> a' ->
    cache_get (cache_add c a v) a' = cache_get c a'.
Proof.
  cache_get_add.
Qed.

Hint Rewrite cache_get_eq cache_get_dirty_eq : cache.
Hint Rewrite cache_get_dirty_neq cache_get_neq using (now eauto) : cache.

Ltac cache_remove_manip :=
  cache_get_add;
  destruct_matches;
  remove_rewrite;
  try congruence.

Lemma cache_evict_get : forall c v a,
  cache_get c a = Some (false, v) ->
  cache_get (cache_evict c a) a = None.
Proof.
  cache_remove_manip.
Qed.

Lemma cache_evict_get_other : forall c a a',
  a <> a' ->
  cache_get (cache_evict c a) a' = cache_get c a'.
Proof.
  cache_remove_manip.
Qed.

Hint Rewrite cache_evict_get_other using (now eauto) : cache.

Lemma cache_remove_get : forall c a,
  cache_get (Map.remove a c) a = None.
Proof.
  cache_remove_manip.
Qed.

Lemma cache_remove_get_other : forall c a a',
  a <> a' ->
  cache_get (Map.remove a c) a' = cache_get c a'.
Proof.
  cache_remove_manip.
Qed.

Hint Rewrite cache_remove_get : cache.
Hint Rewrite cache_remove_get_other using (now eauto) : cache.

(* Simple consequences of cache_pred. *)
Lemma cache_pred_hit_vd : forall c vd b d a v,
    cache_pred c vd d ->
    cache_get c a = Some (b, v) ->
    vd a = Some v.
Proof.
  prove_cache_pred.
Qed.

Hint Resolve cache_pred_hit_vd.

Ltac rewrite_cache_get :=
  repeat match goal with
         | [ H: context[cache_get (cache_evict ?c ?a) ?a],
             H': cache_get ?c ?a = Some (false, ?v) |- _ ] =>
           rewrite (cache_evict_get c v a H') in H
         | [ H: context[cache_get] |- _ ] => progress (autorewrite with cache in H)
         end;
  autorewrite with cache.

Lemma cache_pred_clean : forall c vd a v,
    cache_get c a = Some (false, v) ->
    vd a = Some v ->
    cache_pred c vd =p=>
cache_pred (Map.remove a c) (mem_except vd a) * a |-> v.
Proof.
  unfold pimpl.
  intros.
  unfold_sep_star.
  exists (mem_except m a).
  exists (fun a' => if weq a' a then Some v else None).
  unfold mem_except.
  intuition.
  - unfold mem_union; apply functional_extensionality; intro a'.
    prove_cache_pred; distinguish_addresses; replace_cache_vals; eauto.
    destruct_matches.
  - unfold mem_disjoint; intro; repeat deex.
    prove_cache_pred; distinguish_addresses; replace_cache_vals; eauto.
  - prove_cache_pred; distinguish_addresses; destruct_matches;
    rewrite_cache_get; try congruence; eauto.
  - unfold ptsto; intuition; distinguish_addresses.
Qed.

Ltac replace_match :=
  try match goal with
  | [ |- context[match ?d with _ => _ end] ] =>
    replace d
  | [ H: context[match ?d with _ => _ end] |- _ ] =>
    replace d in H
  end.

Lemma cache_pred_clean' : forall c vd a v,
    cache_get c a = Some (false, v) ->
    vd a = Some v ->
    cache_pred (Map.remove a c) (mem_except vd a) * a |-> v =p=>
cache_pred c vd.
Proof.
  unfold pimpl, mem_except.
  intros.
  unfold_sep_star in H1.
  repeat deex.
  unfold ptsto in *; intuition.
  prove_cache_pred; distinguish_addresses; replace_cache_vals; rewrite_cache_get;
  disk_equalities; distinguish_addresses; replace_match.
  case_eq (cache_get c a'); intros.
  destruct p as [ [] ]; replace_cache_vals; auto.
  (* why doesn't disk_equalities do this? *)
  lazymatch goal with
  | [ H: @eq (@mem addr _ _) _ _ |- context[match (?m ?a) with _ => _ end] ] =>
    apply equal_f with a' in H
  end.
  distinguish_addresses.
  rewrite_cache_get; replace_cache_vals.
  case_eq (m1 a'); intros; try congruence.
  match goal with
  | [ H: context[m2 _ = None] |- _ ] =>
    rewrite H; auto
  end; congruence.
  distinguish_addresses.

  (* these are some annoying manipulations that would be hard to automate *)

  distinguish_addresses.
  replace (m1 a0) with (Some v0); auto.
  erewrite H3; autorewrite with cache; auto.
  edestruct H8; eauto.
  autorewrite with cache; eauto.
  eexists.
  replace_match; eauto.
Qed.

Hint Resolve cache_pred_clean.
Hint Resolve cache_pred_clean'.

Lemma cache_pred_dirty : forall c vd a v,
    cache_get c a = Some (true, v) ->
    vd a = Some v ->
    cache_pred c vd =p=>
exists v', cache_pred (Map.remove a c) (mem_except vd a) * a |-> v'.
Proof.
  unfold pimpl.
  intros.
  unfold_sep_star.
  assert (exists v', m a = Some v').
  unfold cache_pred in *; intuition eauto.
  destruct H2 as [v' ?].
  exists v'.
  exists (mem_except m a).
  exists (fun a' => if weq a' a then Some v' else None).
  unfold mem_except.
  intuition.
  - unfold mem_union; apply functional_extensionality; intro a'.
    prove_cache_pred; distinguish_addresses; replace_cache_vals; eauto.
    destruct_matches.
  - unfold mem_disjoint; intro; repeat deex.
    prove_cache_pred; distinguish_addresses; replace_cache_vals; eauto.
  - prove_cache_pred; distinguish_addresses; destruct_matches;
    rewrite_cache_get; try congruence; eauto.
  - unfold ptsto; intuition; distinguish_addresses.
Qed.

Lemma cache_pred_dirty' : forall c vd a v v',
    cache_get c a = Some (true, v') ->
    vd a = Some v' ->
    cache_pred (Map.remove a c) (mem_except vd a) * a |-> v =p=>
cache_pred c vd.
Proof.
  unfold pimpl, mem_except.
  intros.
  unfold_sep_star in H1.
  repeat deex.
  unfold ptsto in *; intuition.
  prove_cache_pred; distinguish_addresses; replace_cache_vals; rewrite_cache_get;
  disk_equalities; distinguish_addresses; replace_match; eauto.
  case_eq (cache_get c a'); intros.
  destruct p as [ [] ]; replace_cache_vals; auto.

  (* why doesn't disk_equalities do this? *)
  lazymatch goal with
  | [ H: @eq (@mem addr _ _) _ _ |- context[match (?m ?a) with _ => _ end] ] =>
    apply equal_f with a' in H
  end.
  distinguish_addresses.
  rewrite_cache_get; replace_cache_vals.
  case_eq (m1 a'); intros; try congruence.
  match goal with
  | [ H: context[m2 _ = None] |- _ ] =>
    rewrite H; auto
  end; congruence.

  match goal with
  | [ H: context[cache_get _ _ = Some (false, _) ] |- _ ] =>
    erewrite H; rewrite_cache_get; eauto
  end.

  match goal with
  | [ H: context[cache_get _ _ = Some (true, _) ] |- _ ] =>
    edestruct H; rewrite_cache_get; eauto
  end.
  eexists; replace_match; eauto.
Qed.

Lemma cache_pred_hit :  forall c vd d a b v,
    cache_pred c vd d ->
    cache_get c a = Some (b, v) ->
    vd a = Some v.
Proof.
  prove_cache_pred.
Qed.

Ltac cache_vd_val :=
  lazymatch goal with
  | [ H: cache_get _ ?a = Some (_, ?v) |- _ ] =>
    learn H (eapply cache_pred_hit in H;
              eauto)
  end.

Ltac unify_mem_contents :=
  match goal with
  | [ H : get ?v ?l = get ?v' ?l' |- _ ] =>
    progress replace (get v l) in *
  end.

Ltac simplify :=
  step_simplifier;
  learn_invariants;
  subst;
  try cache_vd_val;
  cleanup.

Ltac finish :=
  solve_get_set;
  try solve [ pred_apply; cancel ];
  try cache_contents_eq;
  try congruence;
  eauto.

Lemma cache_pred_stable_add : forall c vd a v d,
    vd a = Some v ->
    cache_get c a = None ->
    cache_pred c vd d ->
    cache_pred (cache_add c a v) vd d.
Proof.
  intros.

  assert (d a = Some v).
  prove_cache_pred.

  prove_cache_pred;
    distinguish_addresses;
    replace_cache_vals;
    try rewrite cache_get_eq in *;
    try rewrite cache_get_neq in * by auto;
    try inv_opt;
    eauto.
Qed.

Hint Resolve cache_pred_stable_add.

Hint Rewrite cache_get_dirty_eq upd_eq : cache.
Hint Rewrite cache_get_dirty_neq upd_ne using (now auto) : cache.

Lemma cache_pred_stable_dirty : forall c vd a v v' d,
    vd a = Some v ->
    cache_pred c vd d ->
    cache_pred (cache_add_dirty c a v') (upd vd a v') d.
Proof.
  intros.
  prove_cache_pred;
    distinguish_addresses;
    autorewrite with cache in *;
    try congruence;
    eauto.
  case_eq (cache_get c a); intros;
  try match goal with
      | [ p: bool * valu |- _ ] =>
        destruct p as [ [] ]
      end;
  replace_cache_vals;
  eauto.
Qed.

Hint Resolve cache_pred_stable_dirty.

Ltac learn_mem_val H m a :=
  let v := fresh "v" in
    evar (v : valu);
    assert (m a = Some v);
    [ eapply ptsto_valid;
      pred_apply' H; cancel |
    ]; subst v.

Ltac learn_some_addr :=
  match goal with
  | [ a: addr, H: ?P ?m |- _ ] =>
    match P with
    | context[(a |-> _)%pred] => learn_mem_val H m a
    end
  end.

Definition locked_disk_read {T} a rx : prog Mcontents S T :=
  c <- Get Cache;
  match cache_get c a with
  | None => v <- Read a;
      let c' := cache_add c a v in
      Assgn Cache c';;
            rx v
  | Some (_, v) =>
    rx v
  end.

Theorem locked_disk_read_ok : forall a,
    cacheS TID: tid |-
    {{ F v,
     | PRE d m s0 s: let vd := virt_disk s in
                     d |= cache_pred (get Cache m) vd /\
                     vd |= F * a |-> v /\
                     get GCacheL s = Owned tid
     | POST d' m' s0' s' r: let vd' := virt_disk s' in
                            d' |= cache_pred (get Cache m') vd' /\
                            vd' = virt_disk s /\
                            r = v /\
                            get GCacheL s' = Owned tid /\
                            s0' = s0
    }} locked_disk_read a.
Proof.
  hoare.
  learn_some_addr.
  valid_match_opt; hoare pre simplify with finish.
Qed.

Hint Extern 1 {{locked_disk_read _; _}} => apply locked_disk_read_ok : prog.

Theorem cache_pred_same_disk : forall c vd vd' d,
    cache_pred c vd d ->
    cache_pred c vd' d ->
    vd = vd'.
Proof.
  prove_cache_pred.
Qed.

Ltac replace_cache :=
  match goal with
  | [ H: get Cache ?m = get Cache ?m' |- _ ] =>
    try replace (get Cache m) in *
  end.

Ltac vd_locked :=
  match goal with
  | [ H: cache_pred ?c ?vd ?d, H': cache_pred ?c ?vd' ?d |- _ ] =>
    assert (vd = vd') by
        (apply (cache_pred_same_disk c vd vd' d); auto);
      subst vd'
  end.

Definition locked_async_disk_read {T} a rx : prog Mcontents S T :=
  c <- Get Cache;
  match cache_get c a with
  | None => v <- Read a;
      Commit (set GCache c);;
             Yield;;
             let c' := cache_add c a v in
             Assgn Cache c';;
                   Commit (fun (s:S) => set GCache c' s);;
                   rx v
  | Some (_, v) =>
    rx v
  end.

Lemma ghost_lock_stable_set_cache : forall m s m' s',
    ghost_lock_invariant CacheL GCacheL m s ->
    get CacheL m' = get CacheL m ->
    get GCacheL s' = get GCacheL s ->
    ghost_lock_invariant CacheL GCacheL m' s'.
Proof.
  inversion 1; intros.
  apply LockOpen; congruence.
  apply LockOwned with (tid := tid); congruence.
Qed.

Hint Resolve ghost_lock_stable_set_cache.

Theorem locked_async_disk_read_ok : forall a,
    cacheS TID: tid |-
    {{ F v,
     | PRE d m s0 s: let vd := virt_disk s in
                     cacheI m s d /\
                     vd |= F * a |-> v /\
                     get GCacheL s = Owned tid /\
                     s0 = s
     | POST d' m' s0' s' r: let vd' := virt_disk s' in
                            cacheI m' s' d' /\
                            vd' = virt_disk s /\
                            r = v /\
                            get GCacheL s' = Owned tid /\
                            s' = set GCache (get Cache m') s0'
    }} locked_async_disk_read a.
Proof.
  hoare.
  learn_some_addr.
  valid_match_opt; hoare pre simplify with (finish;
                                             try (replace_cache; vd_locked);
                                             repeat unify_mem_contents;
                                             eauto).
Qed.

Hint Extern 4 {{locked_async_disk_read _; _}} => apply locked_async_disk_read_ok.

Definition disk_read {T} a rx : prog _ _ T :=
  AcquireLock CacheL (fun tid => set GCacheL (Owned tid));;
              v <- locked_async_disk_read a;
  Assgn CacheL Open;;
        Commit (set GCacheL NoOwner);;
        rx v.

Lemma cache_pred_same_sectors : forall c vd d,
    cache_pred c vd d ->
    (forall a v, d a = Some v ->
            exists v', vd a = Some v').
Proof.
  intros.
  case_eq (cache_get c a); intros.
  destruct p as [ [] ];
  match goal with
  | [ H: cache_get _ _ = _ |- _ ] =>
    eapply cache_pred_hit in H; eauto
  end.
  match goal with
  | [ H: context[cache_pred] |- _ ] =>
    eapply cache_miss_mem_eq in H; eauto
  end.
  replace (vd a); eauto.
Qed.

Lemma cache_pred_same_sectors' : forall c vd d,
    cache_pred c vd d ->
    (forall a v, vd a = Some v ->
            exists v', d a = Some v').
Proof.
  intros.
  case_eq (cache_get c a); intros.
  prove_cache_pred.
  destruct p as [ [] ]; eauto.
  match goal with
  | [ H: context[cache_pred] |- _ ] =>
    eapply cache_miss_mem_eq in H; eauto
  end.
  replace (d a); eauto.
Qed.

Ltac learn_fact H :=
  match type of H with
    | ?t =>
      match goal with
      | [ H': t |- _ ] =>
        fail 2 "already knew that" H'
      | _ => pose proof H
      end
  end.

Remark cacheR_stutter : forall tid s,
  cacheR tid s s.
Proof.
  unfold cacheR, lock_protects;
  intuition eauto.
Qed.

Theorem disk_read_ok : forall a,
    cacheS TID: tid |-
    {{ F v,
     | PRE d m s0 s: let vd := virt_disk s in
                     cacheI m s d /\
                     vd |= F * a |-> v /\
                     cacheR tid s0 s
     | POST d' m' s0' s' r: let vd' := virt_disk s' in
                            cacheI m' s' d' /\
                            get CacheL m' = Open /\
                            star diskR (virt_disk s) (virt_disk s') /\
                            (* this is ugly, but very precise *)
                            s' = set GCacheL NoOwner
                                     (set GCache (get Cache m') s0') /\
                            exists F' v',
                              vd' |= F' * a |-> v' /\
                              r = v'
    }} disk_read a.
Proof.
  intros.
  step pre simplify with finish.
  unfold cacheR; eauto.
  learn_some_addr.
  step pre (cbn; intuition; repeat deex;
            learn_invariants) with idtac.
  match goal with
  | [ H: context[virt_disk s' _ = _] |- _ ] =>
    unfold virt_disk in H; edestruct (H a); eauto
  end.
  simplify; finish.
  unfold pred_in in *.
  repeat match goal with
         | [ H: cache_pred _ _ _ |- _ ] =>
           learn_fact (cache_pred_same_sectors _ _ _ H) ||
                      learn_fact (cache_pred_same_sectors' _ _ _ H)
         end.
  (* follow the chain of sector equalities until you can't produce a
  term about a new disk *)
  repeat match goal with
         | [ Hmem: context[_ -> exists _, ?d _ = _] |- _ ] =>
           edestruct Hmem; [ now eauto | ];
           match goal with
           | [ H: d _ = _, H': d _ = _ |- _ ] => fail 1
           | _ => idtac
           end
         end.

  hoare pre (simplify;
              repeat match goal with
                     | [ H: context[get _ (set _ _ _)] |- _ ] =>
                       simpl_get_set in H
                     end) with finish;
    (* this is ugly, but [finish] does something that enables this *)
    repeat unify_mem_contents; eauto.
Qed.

Definition locked_disk_write {T} a v rx : prog Mcontents S T :=
  c <- Get Cache;
  let c' := cache_add_dirty c a v in
  Assgn Cache c';;
        Commit (set GCache c');;
        Commit (fun (s:S) => set GDisk (upd (get GDisk s) a v) s);;
        rx tt.

Theorem locked_disk_write_ok : forall a v,
    cacheS TID: tid |-
    {{ F v0,
     | PRE d m s0 s: let vd := virt_disk s in
                     cacheI m s d /\
                     get GCacheL s = Owned tid /\
                     vd |= F * a |-> v0
     | POST d' m' s0' s' _: let vd' := virt_disk s' in
                            cacheI m' s' d' /\
                            get GCacheL s = Owned tid /\
                            vd' |= F * a |-> v /\
                            s0' = s0
    }} locked_disk_write a v.
Proof.
  hoare pre (simplify; learn_some_addr) with finish.
  eapply pimpl_apply;
    [ | eapply ptsto_upd ];
    dispatch.
Qed.

(** Eviction, so far without writeback *)
Definition evict {T} a rx : prog Mcontents S T :=
  c <- Get Cache;
  match cache_get c a with
  | None => rx tt
  | Some (dirty, v) =>
    If (Bool.bool_dec dirty true) {
         rx tt
       } else {
    let c' := cache_evict c a in
    Assgn Cache c';;
          rx tt
  }
end.

Ltac if_ok :=
  match goal with
  | [ |- valid _ _ _ _ (If_ ?b _ _) ] =>
    unfold If_; case_eq b; intros
  end.

Lemma cache_pred_stable_evict : forall c a vd d v,
    cache_pred c vd d ->
    cache_get c a = Some (false, v) ->
    cache_pred (cache_evict c a) vd d.
Proof.
  prove_cache_pred; distinguish_addresses; eauto;
  try solve [ autorewrite with cache in *; eauto ].

  rewrite H0.
  erewrite cache_evict_get; eauto.
  erewrite H; eauto.
  erewrite cache_evict_get in H1 by eauto; congruence.
Qed.

Hint Resolve cache_pred_stable_evict.

Theorem locked_evict_ok : forall a,
    cacheS TID: tid |-
    {{ F v0,
     | PRE d m s0 s: let vd := virt_disk s in
                     cacheI m s d /\
                     get GCacheL s = Owned tid /\
                     vd |= F * a |-> v0
     | POST d' m' s0' s' _: let vd' := virt_disk s' in
                            cacheI m s d /\
                            get GCacheL s = Owned tid /\
                            vd' = virt_disk s /\
                            s0' = s0
    }} evict a.
Proof.
  hoare pre simplify with finish.
  learn_some_addr.
  valid_match_opt; try if_ok; try congruence;
    hoare pre simplify with finish.
Qed.

Definition writeback {T} a rx : prog Mcontents S T :=
  c <- Get Cache;
  let ov := cache_get c a in
  match (cache_get c a) with
  | Some (dirty, v) =>
    Write a v;;
          Assgn Cache (cache_clean c a);;
      rx tt
  | None => rx tt
  end.

Lemma cache_clean_clean_noop : forall c a v,
    cache_get c a = Some (false, v) ->
    cache_clean c a = c.
Proof.
  unfold cache_clean, cache_get.
  intros; destruct_matches.
Qed.

Lemma cache_pred_stable_clean_noop : forall c vd d a v,
    cache_pred c vd d ->
    cache_get c a = Some (false, v) ->
    cache_pred (cache_clean c a) vd d.
Proof.
  intros.
  erewrite cache_clean_clean_noop; eauto.
Qed.

Hint Resolve cache_pred_stable_clean_noop.

Lemma cache_get_add_clean : forall a c v,
    cache_get (Map.add a (Clean v) c) a = Some (false, v).
Proof.
  unfold cache_get; intros.
  rewrite MapFacts.add_eq_o; auto.
Qed.

Lemma cache_get_add_clean_other : forall a a' c v,
    a <> a' ->
    cache_get (Map.add a (Clean v) c) a' = cache_get c a'.
Proof.
  unfold cache_get; intros.
  rewrite MapFacts.add_neq_o; auto.
Qed.

Hint Rewrite cache_get_add_clean : cache.
Hint Rewrite cache_get_add_clean_other using (now eauto) : cache.

Lemma cache_pred_stable_clean : forall c vd d a v,
    cache_pred c vd d ->
    cache_get c a = Some (true, v) ->
    d a = Some v ->
    cache_pred (cache_clean c a) vd d.
Proof.
  intros.
  unfold cache_clean.
  match goal with
    | [ H: cache_get _ _ = Some (true, _) |- _ ] =>
      learn H (apply cache_get_find_dirty in H)
  end; replace_match.
  prove_cache_pred; destruct_matches; distinguish_addresses; replace_cache_vals;
  rewrite_cache_get; try congruence; eauto.
Qed.

Hint Resolve cache_pred_stable_clean.

Theorem writeback_ok : forall a,
    cacheS TID: tid |-
    {{ F v0,
     | PRE d m s0 s: let vd := virt_disk s in
                     cacheI m s d /\
                     get GCacheL s = Owned tid /\
                     vd |= F * a |-> v0
     | POST d' m' s0' s' _: let vd' := virt_disk s' in
                            d' |= cache_pred (get Cache m') vd' /\
                            get GCacheL s = Owned tid /\
                            vd' = virt_disk s /\
                            s0' = s0
    }} writeback a.
Proof.
  (* this proof is a bit messy, but could be better automated with some
specific simplifiers *)
  hoare pre simplify with finish.
  learn_some_addr.

  Remove Hints ptsto_valid_iff : core.

  assert (exists dv0, d a = Some dv0).
  prove_cache_pred.
  case_eq (cache_get (get Cache m) a); intros.
  destruct p as [ [] ]; eauto.
  replace_cache_vals.
  eexists.
  replace (d a); eauto.

  (* we have to split the proof at this level so we can get the
  cache_pred we need for the Write *)
  case_eq (cache_get (get Cache m) a); intros;
  try destruct p as [ [] ].
  match goal with
  | [ H: cache_pred _ _ _ |- _ ] =>
    let H' := fresh in
    pose proof H as H';
      eapply cache_pred_dirty in H; eauto
  end.
  repeat deex.

  all: valid_match_opt; hoare pre simplify with finish.

  assert (d0 a = Some w0).
  eapply ptsto_valid; pred_apply; cancel.
  match goal with
  | [ H: ?m _ = _ |- cache_pred _ ?m _ ] =>
    eapply cache_pred_dirty' in H; eauto
  end.

  match goal with
  | [ H: ?m _ = _ |- cache_pred _ ?m _ ] =>
    eapply cache_pred_clean' in H; eauto
  end.

  Grab Existential Variables.
  all: auto.
Qed.