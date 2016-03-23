Require Import Arith.
Require Import Pred.
Require Import Word.
Require Import Prog.
Require Import Hoare.
Require Import SepAuto.
Require Import BasicProg.
Require Import Omega.
Require Import Log.
Require Import Array.
Require Import List ListUtils.
Require Import Bool.
Require Import Eqdep_dec.
Require Import Setoid.
Require Import Rec.
Require Import FunctionalExtensionality.
Require Import NArith.
Require Import WordAuto.
Require Import RecArrayUtils LogRecArray.
Require Import GenSepN.
Require Import Balloc.
Require Import ListPred.
Require Import FSLayout.
Require Import AsyncDisk.
Require Import BlockPtr.
Require Import GenSepAuto.

Import ListNotations.

Set Implicit Arguments.



Module INODE.

  (************* on-disk representation of inode *)

  Definition iattrtype : Rec.type := Rec.RecF ([
    ("bytes",  Rec.WordF 64) ;       (* file size in bytes *)
    ("uid",    Rec.WordF 32) ;        (* user id *)
    ("gid",    Rec.WordF 32) ;        (* group id *)
    ("dev",    Rec.WordF 64) ;        (* device major/minor *)
    ("mtime",  Rec.WordF 32) ;        (* last modify time *)
    ("atime",  Rec.WordF 32) ;        (* last access time *)
    ("ctime",  Rec.WordF 32) ;        (* create time *)
    ("itype",  Rec.WordF  8) ;        (* type code, 0 = regular file, 1 = directory, ... *)
    ("unused", Rec.WordF 24)          (* reserved (permission bits) *)
  ]).

  Definition NDirect := 9.

  Definition irectype : Rec.type := Rec.RecF ([
    ("len", Rec.WordF addrlen);     (* number of blocks *)
    ("attrs", iattrtype);           (* file attributes *)
    ("indptr", Rec.WordF addrlen);  (* indirect block pointer *)
    ("blocks", Rec.ArrayF (Rec.WordF addrlen) NDirect)]).


  (* RecArray for inodes records *)
  Module IRecSig <: RASig.

    Definition xparams := inode_xparams.
    Definition RAStart := IXStart.
    Definition RALen := IXLen.
    Definition xparams_ok (_ : xparams) := True.

    Definition itemtype := irectype.
    Definition items_per_val := valulen / (Rec.len itemtype).


    Theorem blocksz_ok : valulen = Rec.len (Rec.ArrayF itemtype items_per_val).
    Proof.
      unfold items_per_val; rewrite valulen_is; compute; auto.
    Qed.

  End IRecSig.

  Module IRec := LogRecArray IRecSig.
  Hint Extern 0 (okToUnify (IRec.rep _ _) (IRec.rep _ _)) => constructor : okToUnify.


  Definition iattr := Rec.data iattrtype.
  Definition irec := IRec.Defs.item.
  Definition bnlist := list waddr.

  Module BPtrSig <: BlockPtrSig.

    Definition irec     := irec.
    Definition iattr    := iattr.
    Definition NDirect  := NDirect.

    Fact NDirect_bound : NDirect <= addrlen.
      compute; omega.
    Qed.

    Definition IRLen    (x : irec) := Eval compute_rec in # ( x :-> "len").
    Definition IRIndPtr (x : irec) := Eval compute_rec in # ( x :-> "indptr").
    Definition IRBlocks (x : irec) := Eval compute_rec in ( x :-> "blocks").
    Definition IRAttrs  (x : irec) := Eval compute_rec in ( x :-> "attrs").

    Definition upd_len (x : irec) v  := Eval compute_rec in (x :=> "len" := $ v).

    Definition upd_irec (x : irec) len ibptr dbns := Eval compute_rec in
      (x :=> "len" := $ len :=> "indptr" := $ ibptr :=> "blocks" := dbns).

    (* getter/setter lemmas *)
    Fact upd_len_get_len : forall ir n,
      goodSize addrlen n -> IRLen (upd_len ir n) = n.
    Proof.
      unfold IRLen, upd_len; intros; simpl.
      rewrite wordToNat_natToWord_idempotent'; auto.
    Qed.

    Fact upd_len_get_ind : forall ir n, IRIndPtr (upd_len ir n) = IRIndPtr ir.
    Proof. intros; simpl; auto. Qed.

    Fact upd_len_get_blk : forall ir n, IRBlocks (upd_len ir n) = IRBlocks ir.
    Proof. intros; simpl; auto. Qed.

    Fact upd_len_get_iattr : forall ir n, IRAttrs (upd_len ir n) = IRAttrs ir.
    Proof. intros; simpl; auto. Qed.

    Fact upd_irec_get_len : forall ir len ibptr dbns,
      goodSize addrlen len -> IRLen (upd_irec ir len ibptr dbns) = len.
    Proof.
      intros; cbn.
      rewrite wordToNat_natToWord_idempotent'; auto.
    Qed.

    Fact upd_irec_get_ind : forall ir len ibptr dbns,
      goodSize addrlen ibptr -> IRIndPtr (upd_irec ir len ibptr dbns) = ibptr.
    Proof.
      intros; cbn.
      rewrite wordToNat_natToWord_idempotent'; auto.
    Qed.

    Fact upd_irec_get_blk : forall ir len ibptr dbns, 
      IRBlocks (upd_irec ir len ibptr dbns) = dbns.
    Proof. intros; simpl; auto. Qed.

    Fact upd_irec_get_iattr : forall ir len ibptr dbns, 
      IRAttrs (upd_irec ir len ibptr dbns) = IRAttrs ir.
    Proof. intros; simpl; auto. Qed.

  End BPtrSig.

  Module Ind := BlockPtr BPtrSig.

  Definition NBlocks := NDirect + Ind.IndSig.items_per_val.


  (************* program *)


  Definition getlen T lxp xp inum ms rx : prog T := Eval compute_rec in
    let^ (ms, (ir : irec)) <- IRec.get_array lxp xp inum ms;
    rx ^(ms, # (ir :-> "len" )).

  Definition getattrs T lxp xp inum ms rx : prog T := Eval compute_rec in
    let^ (ms, (i : irec)) <- IRec.get_array lxp xp inum ms;
    rx ^(ms, (i :-> "attrs")).

  Definition setattrs T lxp xp inum attr ms rx : prog T := Eval compute_rec in
    let^ (ms, (i : irec)) <- IRec.get_array lxp xp inum ms;
    ms <- IRec.put_array lxp xp inum (i :=> "attrs" := attr) ms;
    rx ms.

  (* For updattr : a convenient way for setting individule attribute *)

  Inductive iattrupd_arg :=
  | IABytes (v : word 64)
  | IAMTime (v : word 32)
  | IAType  (v : word  8)
  .

  Definition iattr_upd (e : iattr) (a : iattrupd_arg) := Eval compute_rec in
  match a with
  | IABytes v => (e :=> "bytes" := v)
  | IAMTime v => (e :=> "mtime" := v)
  | IAType  v => (e :=> "itype" := v)
  end.

  Definition updattr T lxp xp inum a ms rx : prog T := Eval compute_rec in
    let^ (ms, (i : irec)) <- IRec.get_array lxp xp inum ms;
    ms <- IRec.put_array lxp xp inum (i :=> "attrs" := (iattr_upd (i :-> "attrs") a)) ms;
    rx ms.


  Definition getbnum T lxp xp inum off ms rx : prog T :=
    let^ (ms, (ir : irec)) <- IRec.get_array lxp xp inum ms;
    ms <- Ind.get lxp ir off ms;
    rx ms.

  Definition getallbnum T lxp xp inum ms rx : prog T :=
    let^ (ms, (ir : irec)) <- IRec.get_array lxp xp inum ms;
    ms <- Ind.read lxp ir ms;
    rx ms.

  Definition shrink T lxp bxp xp inum nr ms rx : prog T :=
    let^ (ms, (ir : irec)) <- IRec.get_array lxp xp inum ms;
    let^ (ms, ir') <- Ind.shrink lxp bxp ir nr ms;
    ms <- IRec.put_array lxp xp inum ir' ms;
    rx ms.

  Definition grow T lxp bxp xp inum bn ms rx : prog T :=
    let^ (ms, (ir : irec)) <- IRec.get_array lxp xp inum ms;
    let^ (ms, r) <- Ind.grow lxp bxp ir ($ bn) ms;
    match r with
    | None => rx ^(ms, false)
    | Some ir' =>
        ms <- IRec.put_array lxp xp inum ir' ms;
        rx ^(ms, true)
    end.


  (************** rep invariant *)

  Record inode := mk_inode {
    IBlocks : bnlist;
    IAttr   : iattr
  }.

  Definition iattr0 := @Rec.of_word iattrtype $0.
  Definition inode0 := mk_inode nil iattr0.
  Definition irec0 := IRec.Defs.item0.


  Definition inode_match bxp ino (ir : irec) := Eval compute_rec in
    ( [[ IAttr ino = (ir :-> "attrs") ]] *
      Ind.rep bxp ir (IBlocks ino) )%pred.

  Definition rep bxp xp (ilist : list inode) := (
     exists reclist, IRec.rep xp reclist *
     listmatch (inode_match bxp) ilist reclist)%pred.


  (************** Basic lemmas *)

  Lemma irec_well_formed : forall Fm xp l i inum m,
    (Fm * IRec.rep xp l)%pred m
    -> i = selN l inum irec0
    -> Rec.well_formed i.
  Proof.
    intros; subst.
    eapply IRec.item_wellforemd; eauto.
  Qed.

  Lemma direct_blocks_length: forall (i : irec),
    Rec.well_formed i
    -> length (i :-> "blocks") = NDirect.
  Proof.
    intros; simpl in H.
    destruct i; repeat destruct p.
    repeat destruct d0; repeat destruct p; intuition.
  Qed.

  Lemma irec_blocks_length: forall m xp l inum Fm,
    (Fm * IRec.rep xp l)%pred m ->
    length (selN l inum irec0 :-> "blocks") = NDirect.
  Proof.
    intros.
    apply direct_blocks_length.
    eapply irec_well_formed; eauto.
  Qed.

  Lemma irec_blocks_length': forall m xp l inum Fm d d0 d1 d2 u,
    (Fm * IRec.rep xp l)%pred m ->
    (d, (d0, (d1, (d2, u)))) = selN l inum irec0 ->
    length d2 = NDirect.
  Proof.
    intros.
    eapply IRec.item_wellforemd with (i := inum) in H.
    setoid_rewrite <- H0 in H.
    unfold Rec.well_formed in H; simpl in H; intuition.
  Qed.


  (**************  Automation *)

  Fact resolve_selN_irec0 : forall l i d,
    d = irec0 -> selN l i d = selN l i irec0.
  Proof.
    intros; subst; auto.
  Qed.

  Fact resolve_selN_inode0 : forall l i d,
    d = inode0 -> selN l i d = selN l i inode0.
  Proof.
    intros; subst; auto.
  Qed.

  Hint Rewrite resolve_selN_irec0   using reflexivity : defaults.
  Hint Rewrite resolve_selN_inode0  using reflexivity : defaults.


  Ltac destruct_irec' x :=
    match type of x with
    | irec => let b := fresh in destruct x as [? b] eqn:? ; destruct_irec' b
    | iattr => let b := fresh in destruct x as [? b] eqn:? ; destruct_irec' b
    | prod _ _ => let b := fresh in destruct x as [? b] eqn:? ; destruct_irec' b
    | _ => idtac
    end.

  Ltac destruct_irec x :=
    match x with
    | (?a, ?b) => (destruct_irec a || destruct_irec b)
    | fst ?a => destruct_irec a
    | snd ?a => destruct_irec a
    | _ => destruct_irec' x; simpl
    end.

  Ltac smash_rec_well_formed' :=
    match goal with
    | [ |- Rec.well_formed ?x ] => destruct_irec x
    end.

  Ltac smash_rec_well_formed :=
    subst; autorewrite with defaults;
    repeat smash_rec_well_formed';
    unfold Rec.well_formed; simpl;
    try rewrite Forall_forall; intuition.


  Ltac irec_wf :=
    smash_rec_well_formed;
    match goal with
      | [ H : ?p %pred ?mm |- length ?d = NDirect ] =>
      match p with
        | context [ IRec.rep ?xp ?ll ] => 
          eapply irec_blocks_length' with (m := mm) (l := ll) (xp := xp); eauto;
          pred_apply; cancel
      end
    end.

  Arguments Rec.well_formed : simpl never.



  (********************** SPECs *)

  Theorem getlen_ok : forall lxp bxp xp inum ms,
    {< F Fm Fi m0 m ilist ino,
    PRE    LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[[ m ::: (Fm * rep bxp xp ilist) ]]] *
           [[[ ilist ::: Fi * inum |-> ino ]]]
    POST RET:^(ms,r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[ r = length (IBlocks ino) ]]
    CRASH  LOG.intact lxp F m0
    >} getlen lxp xp inum ms.
  Proof.
    unfold getlen, rep; pose proof irec0.
    hoare.

    sepauto.
    extract. 
    denote Ind.rep as Hx; unfold Ind.rep in Hx; destruct_lift Hx.
    seprewrite; subst; eauto.
  Qed.


  Theorem getattrs_ok : forall lxp bxp xp inum ms,
    {< F Fm Fi m0 m ilist ino,
    PRE    LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[[ m ::: (Fm * rep bxp xp ilist) ]]] *
           [[[ ilist ::: (Fi * inum |-> ino) ]]]
    POST RET:^(ms,r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[ r = IAttr ino ]]
    CRASH  LOG.intact lxp F m0
    >} getattrs lxp xp inum ms.
  Proof.
    unfold getattrs, rep.
    hoare.

    sepauto.
    extract.
    seprewrite; subst; eauto.
  Qed.


  Theorem setattrs_ok : forall lxp bxp xp inum attr ms,
    {< F Fm Fi m0 m ilist ino,
    PRE    LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[[ m ::: (Fm * rep bxp xp ilist) ]]] *
           [[[ ilist ::: (Fi * inum |-> ino) ]]]
    POST RET:ms exists m' ilist' ino',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') ms *
           [[[ m' ::: (Fm * rep bxp xp ilist') ]]] *
           [[[ ilist' ::: (Fi * inum |-> ino') ]]] *
           [[ ino' = mk_inode (IBlocks ino) attr ]]
    CRASH  LOG.intact lxp F m0
    >} setattrs lxp xp inum attr ms.
  Proof.
    unfold setattrs, rep.
    hoare.

    sepauto.
    irec_wf.

    sepauto.
    eapply listmatch_updN_selN; simplen.
    instantiate (1 := mk_inode (IBlocks ino) attr).
    unfold inode_match; cancel; sepauto.
    sepauto.
    Unshelve. exact irec0.
  Qed.


  Theorem updattr_ok : forall lxp bxp xp inum kv ms,
    {< F Fm Fi m0 m ilist ino,
    PRE    LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[[ m ::: (Fm * rep bxp xp ilist) ]]] *
           [[[ ilist ::: (Fi * inum |-> ino) ]]]
    POST RET:ms exists m' ilist' ino',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') ms *
           [[[ m' ::: (Fm * rep bxp xp ilist') ]]] *
           [[[ ilist' ::: (Fi * inum |-> ino') ]]] *
           [[ ino' = mk_inode (IBlocks ino) (iattr_upd (IAttr ino) kv) ]]
    CRASH  LOG.intact lxp F m0
    >} updattr lxp xp inum kv ms.
  Proof.
    unfold updattr, rep.
    hoare.

    sepauto.
    filldef; abstract (destruct kv; simpl; subst; irec_wf).
    sepauto.
    eapply listmatch_updN_selN; simplen.
    instantiate (1 := mk_inode (IBlocks ino) (iattr_upd (IAttr ino) kv)).
    unfold inode_match; cancel; sepauto.
    sepauto.
    Unshelve. exact irec0.
  Qed.


  Theorem getbnum_ok : forall lxp bxp xp inum off ms,
    {< F Fm Fi m0 m ilist ino,
    PRE    LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[ off < length (IBlocks ino) ]] *
           [[[ m ::: (Fm * rep bxp xp ilist) ]]] *
           [[[ ilist ::: (Fi * inum |-> ino) ]]]
    POST RET:^(ms, r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[ r = selN (IBlocks ino) off $0 ]]
    CRASH  LOG.intact lxp F m0
    >} getbnum lxp xp inum off ms.
  Proof.
    unfold getbnum, rep.
    step.
    sepauto.

    prestep; norml.
    extract; seprewrite.
    cancel.
  Qed.


  Theorem getallbnum_ok : forall lxp bxp xp inum ms,
    {< F Fm Fi m0 m ilist ino,
    PRE    LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[[ m ::: (Fm * rep bxp xp ilist) ]]] *
           [[[ ilist ::: (Fi * inum |-> ino) ]]]
    POST RET:^(ms, r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[ r = (IBlocks ino) ]]
    CRASH  LOG.intact lxp F m0
    >} getallbnum lxp xp inum ms.
  Proof.
    unfold getallbnum, rep.
    step.
    sepauto.

    prestep; norml.
    extract; seprewrite.
    cancel.
  Qed.


  Theorem shrink_ok : forall lxp bxp xp inum nr ms,
    {< F Fm Fi m0 m ilist ino freelist,
    PRE    LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[[ m ::: (Fm * rep bxp xp ilist * BALLOC.rep bxp freelist) ]]] *
           [[[ ilist ::: (Fi * inum |-> ino) ]]]
    POST RET:ms exists m' ilist' ino' freelist',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') ms *
           [[[ m' ::: (Fm * rep bxp xp ilist' * BALLOC.rep bxp freelist') ]]] *
           [[[ ilist' ::: (Fi * inum |-> ino') ]]] *
           [[ ino' = mk_inode (cuttail nr (IBlocks ino)) (IAttr ino) ]]
    CRASH  LOG.intact lxp F m0
    >} shrink lxp bxp xp inum nr ms.
  Proof.
    unfold shrink, rep.
    step.
    sepauto.

    extract; seprewrite.
    step.
    step.
    subst; unfold BPtrSig.upd_len, BPtrSig.IRLen.
    irec_wf.
    sepauto.

    step.
    2: sepauto.
    rewrite listmatch_updN_removeN by omega.
    cancel.
    unfold inode_match, BPtrSig.upd_len, BPtrSig.IRLen; simpl.
    cancel.
    Unshelve. eauto.
  Qed.


  Lemma grow_wellformed : forall (a : BPtrSig.irec) inum reclist F1 F2 F3 F4 m xp,
    ((((F1 * IRec.rep xp reclist) * F2) * F3) * F4)%pred m ->
    length (BPtrSig.IRBlocks a) = length (BPtrSig.IRBlocks (selN reclist inum irec0)) ->
    inum < length reclist ->
    Rec.well_formed a.
  Proof.
    unfold IRec.rep, IRec.items_valid; intros.
    destruct_lift H.
    denote Forall as Hx.
    apply Forall_selN with (i := inum) (def := irec0) in Hx; auto.
    apply direct_blocks_length in Hx.
    setoid_rewrite <- H0 in Hx.
    cbv in Hx; cbv in a.
    cbv.
    destruct a; repeat destruct p. destruct p0; destruct p.
    intuition.
  Qed.

  Theorem grow_ok : forall lxp bxp xp inum bn ms,
    {< F Fm Fi m0 m ilist ino freelist,
    PRE    LOG.rep lxp F (LOG.ActiveTxn m0 m) ms *
           [[ length (IBlocks ino) < NBlocks ]] *
           [[[ m ::: (Fm * rep bxp xp ilist * BALLOC.rep bxp freelist) ]]] *
           [[[ ilist ::: (Fi * inum |-> ino) ]]]
    POST RET:^(ms, r)
           [[ r = false ]] * LOG.rep lxp F (LOG.ActiveTxn m0 m) ms \/
           [[ r = true ]] * exists m' ilist' ino' freelist',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') ms *
           [[[ m' ::: (Fm * rep bxp xp ilist' * BALLOC.rep bxp freelist') ]]] *
           [[[ ilist' ::: (Fi * inum |-> ino') ]]] *
           [[ ino' = mk_inode ((IBlocks ino) ++ [$ bn]) (IAttr ino) ]]
    CRASH  LOG.intact lxp F m0
    >} grow lxp bxp xp inum bn ms.
  Proof.
    unfold grow, rep.
    step.
    sepauto.

    extract; seprewrite.
    step.
    step.
    eapply grow_wellformed; eauto.
    sepauto.

    step.
    or_r; cancel.
    2: sepauto.
    rewrite listmatch_updN_removeN by omega.
    cancel.
    unfold inode_match, BPtrSig.IRAttrs in *; simpl.
    cancel.
    substl (IAttr (selN ilist inum inode0)); eauto.
    Unshelve. all: eauto; exact emp.
  Qed.

  Hint Extern 1 ({{_}} progseq (getlen _ _ _ _) _) => apply getlen_ok : prog.
  Hint Extern 1 ({{_}} progseq (getattrs _ _ _ _) _) => apply getattrs_ok : prog.
  Hint Extern 1 ({{_}} progseq (setattrs _ _ _ _ _) _) => apply setattrs_ok : prog.
  Hint Extern 1 ({{_}} progseq (updattr _ _ _ _ _) _) => apply updattr_ok : prog.
  Hint Extern 1 ({{_}} progseq (grow _ _ _ _ _ _) _) => apply grow_ok : prog.
  Hint Extern 1 ({{_}} progseq (shrink _ _ _ _ _ _) _) => apply shrink_ok : prog.

  Hint Extern 0 (okToUnify (rep _ _ _) (rep _ _ _)) => constructor : okToUnify.


End INODE.

