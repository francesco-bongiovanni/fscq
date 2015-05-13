Require Import Prog.
Require Import Log.
Require Import BFile.
Require Import Word.
Require Import BasicProg.
Require Import Bool.
Require Import Pred.
Require Import DirName.
Require Import Hoare.
Require Import GenSep.
Require Import GenSepN.
Require Import SepAuto.
Require Import Idempotent.
Require Import Inode.
Require Import List.
Require Import Balloc.
Require Import Arith.
Require Import Array.
Require Import FSLayout.
Require Import Cache.
Require Import Rec.
Require Import RecArray.
Require Import Omega.
Require Import Eqdep_dec.
Require Import Bytes.
Require Import ProofIrrelevance.

Set Implicit Arguments.
Import ListNotations.

Module SLOWBYTEFILE.

  Definition byte_type := Rec.WordF 8.
  Definition itemsz := Rec.len byte_type.
  Definition items_per_valu : addr := $ valubytes.
  Theorem itemsz_ok : valulen = wordToNat items_per_valu * itemsz.
  Proof.
    unfold items_per_valu.
    rewrite valulen_is, valubytes_is.
    reflexivity.
  Qed.

  Definition bytes_rep f (allbytes : list byte) :=
    BFileRec.array_item_file byte_type items_per_valu itemsz_ok f allbytes /\
    # (natToWord addrlen (length allbytes)) = length allbytes.

  Definition rep (bytes : list byte) (f : BFILE.bfile) :=
    exists allbytes,
    bytes_rep f allbytes /\
    firstn (# (f.(BFILE.BFAttr).(INODE.ISize))) allbytes = bytes.

  Fixpoint apply_bytes (allbytes : list byte) (off : nat) (newdata : list byte) :=
    match newdata with
    | nil => allbytes
    | b :: rest => updN (apply_bytes allbytes (off+1) rest) off b
    end.

  (*
  Lemma apply_bytes_upd:
    forall allbytes off b rest,
      (wordToNat off) < # (natToWord addrlen (length allbytes)) ->
      apply_bytes allbytes off (b::rest) = upd (apply_bytes allbytes (off^+$1) rest) off b.
  Proof.
    simpl. reflexivity.
  Qed.
*)

  Lemma apply_bytes_upd_comm:
    forall rest allbytes off off' b, 
      off < off' ->
      apply_bytes (updN allbytes off b) off' rest = updN (apply_bytes allbytes off' rest) off b.
  Proof.
    induction rest.
    simpl. reflexivity.
    simpl.
    intros.
    rewrite IHrest.
    rewrite updN_comm.
    reflexivity.
    omega.
    omega.
  Qed.

  Definition hidden (P : Prop) : Prop := P.
  Opaque hidden.

  Definition update_bytes T fsxp inum (off : nat) (newdata : list byte) mscs rx : prog T :=
    let^ (mscs, finaloff) <- ForEach b rest newdata
      Ghost [ mbase F Fm A allbytes ]
      Loopvar [ mscs boff ]
      Continuation lrx
      Invariant
        exists m' flist' f' allbytes',
          LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m') mscs  *
          [[ (Fm * BFILE.rep fsxp.(FSXPBlockAlloc) fsxp.(FSXPInode) flist')%pred (list2mem m') ]] *
          [[ (A * #inum |-> f')%pred (list2nmem flist') ]] *
          [[ bytes_rep f' allbytes' ]] *
          [[ apply_bytes allbytes' boff rest = apply_bytes allbytes off newdata ]] *
          [[ boff <= length allbytes' ]] *
          [[ off + length newdata = boff + length rest ]] *
          [[ hidden (length allbytes = length allbytes') ]]
      OnCrash
        exists m',
          LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m') mscs
      Begin
         mscs <- BFileRec.bf_put byte_type items_per_valu itemsz_ok
            fsxp.(FSXPLog) fsxp.(FSXPInode) inum ($ boff) b mscs;
          lrx ^(mscs, boff + 1)
      Rof ^(mscs, off);
      rx mscs.

  Lemma bound_helper : forall a b,
    # (natToWord addrlen b) = b -> a <= b -> a <= # (natToWord addrlen b).
  Proof.
    intuition.
  Qed.

  Lemma boff_le_length : forall T boff (l l' : list T) off x y z q,
    off + x = boff + S z ->
    off + y <= length (firstn q l') ->
    hidden (length l' = length l) ->
    x = y ->
    boff + 1 <= length l.
  Proof.
    intros.
    subst.
    rewrite firstn_length in *.
    eapply le_trans. eapply le_trans; [ | apply H0 ].
    omega.
    rewrite H1.
    apply Min.le_min_r.
  Qed.

  Lemma le_lt_S : forall a b,
    a + 1 <= b ->
    a < b.
  Proof.
    intros; omega.
  Qed.

  Hint Resolve bound_helper.
  Hint Resolve boff_le_length.
  Hint Resolve le_lt_S.

  Theorem update_bytes_ok: forall fsxp inum off len newdata mscs,
      {< m mbase F Fm A flist f bytes olddata Fx,
       PRE LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist)%pred (list2mem m) ]] *
           [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
           [[ rep bytes f ]] *
           [[ (Fx * arrayN off olddata)%pred (list2nmem bytes) ]] *
           [[ length olddata = len ]] *
           [[ length newdata = len ]] *
           [[ off + len <= length bytes ]] 
      POST RET:mscs
           exists m', LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m') mscs *
           exists flist' f' bytes',
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist')%pred (list2mem m') ]] *
           [[ (A * #inum |-> f')%pred (list2nmem flist') ]] *
           [[ rep bytes' f' ]] *
           [[ (Fx * arrayN off newdata)%pred (list2nmem bytes') ]] *
           [[ BFILE.BFAttr f = BFILE.BFAttr f' ]]
       CRASH LOG.would_recover_old (FSXPLog fsxp) F mbase 
      >} update_bytes fsxp inum off newdata mscs.
  Proof.
    unfold update_bytes, rep, bytes_rep.

    step.   (* step into loop *)

    rewrite firstn_length in *.
    eapply le_trans. eapply le_plus_l. eapply le_trans. apply H4.
    apply Min.le_min_r.

    step.   (* bf_put *)

    erewrite wordToNat_natToWord_bound by eauto.
    eauto.
    constructor.

    step.
    rewrite length_upd. auto.
    rewrite <- H18.
    rewrite <- apply_bytes_upd_comm by omega.
    unfold upd.

    erewrite wordToNat_natToWord_bound by eauto.
    auto.

    rewrite length_upd.
    eauto.

    rewrite H15. rewrite length_upd. constructor.

    step.

    admit.  (* some unification problem *)
    admit.  (* new allbytes *)
    apply LOG.activetxn_would_recover_old.
  Admitted.

  Definition grow_blocks T fsxp inum cursize newsize mscs rx : prog T :=
    let curblocks := (cursize ^/ ($ valulen)) ^+ $ 1 in
    let newblocks := (newsize ^/ ($ valulen)) ^+ $ 1 in
    let nblock := newblocks ^- curblocks in
    let^ (mscs) <- For i < nblock
      Ghost [ mbase F Fm A ]
      Loopvar [ mscs ]
      Continuation lrx
      Invariant
         exists m' flist f,
         LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m') mscs  *
          [[ (Fm * BFILE.rep fsxp.(FSXPBlockAlloc) fsxp.(FSXPInode) flist)%pred (list2mem m') ]] *
          [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
          [[ length (BFILE.BFData f) + # nblock - # i = # newblocks ]]
      OnCrash
        exists m',
          LOG.rep fsxp.(FSXPLog) F (ActiveTxn mbase m') mscs
      Begin
       let^ (mscs, ok) <- BFILE.bfgrow fsxp.(FSXPLog) fsxp.(FSXPBlockAlloc) fsxp.(FSXPInode) inum mscs;
       If (bool_dec ok true) {
          lrx ^(mscs)
       } else {
          rx ^(mscs, false)
       }
    Rof ^(mscs);
    rx ^(mscs, true).

  Theorem grow_blocks_ok: forall fsxp inum cursize newsize mscs,
      {< m mbase F Fm flist f A B bytes,
       PRE LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist)%pred (list2mem m) ]] *
           [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
           [[ B %pred (list2nmem (BFILE.BFData f)) ]] *
           [[ cursize < newsize ]] *
           [[ rep bytes f ]]
      POST RET:^(mscs, ok)
           exists m', LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m') mscs *
            ([[ ok = false ]] \/      
           [[ ok = true ]] * exists flist' f',
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist')%pred (list2mem m') ]] *
           [[ (length (BFILE.BFData f')) * valulen >= newsize ]] *
           [[ rep bytes f' ]])
       CRASH LOG.would_recover_old (FSXPLog fsxp) F mbase 
       >} grow_blocks fsxp inum ($ cursize) ($ newsize) mscs.
   Proof.
     admit.
   Admitted.

   Definition grow_file T fsxp inum off len mscs rx : prog T :=
    let newsize := off + len in
    let^ (mscs, oldattr) <- BFILE.bfgetattr fsxp.(FSXPLog) fsxp.(FSXPInode) inum mscs;
    If (wlt_dec oldattr.(INODE.ISize) ($ newsize)) {
      let^ (mscs, ok) <- grow_blocks fsxp inum oldattr.(INODE.ISize) ($ newsize) mscs;
      If (bool_dec ok true) {
           mscs <- BFILE.bfsetattr fsxp.(FSXPLog) fsxp.(FSXPInode) inum
                              (INODE.Build_iattr ($ newsize)
                                                 (INODE.IMTime oldattr)
                                                 (INODE.IType oldattr)) mscs;
          rx ^(mscs, true)
      } else {
          rx ^(mscs, false)
      }
    } else {
      rx ^(mscs, true)
    }.

  Definition write_bytes T fsxp inum (off : nat) (data : list byte) mscs rx : prog T :=
    let^ (mscs, ok) <- grow_file fsxp inum off (length data) mscs;
    If (bool_dec ok true) {
         mscs <- update_bytes fsxp inum off data mscs;
         rx ^(mscs, ok)
    } else {
         rx ^(mscs, false)
    }.
       
  Theorem write_bytes_ok: forall fsxp inum off len data mscs,
    {< m mbase F Fm A flist f bytes data0 Fx,
      PRE LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m) mscs *
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist)%pred (list2mem m) ]] *
           [[ (A * #inum |-> f)%pred (list2nmem flist) ]] *
           [[ rep bytes f ]] *
           [[ (Fx * arrayN off data0)%pred (list2nmem bytes) ]] *
           [[ length data0 = len ]] *
           [[ length data = len ]] *
           [[ off + len <= length bytes ]]
      POST RET:^(mscs, ok)
           exists m', LOG.rep (FSXPLog fsxp) F (ActiveTxn mbase m') mscs *
           ([[ ok = false ]] \/
           [[ ok = true ]] * exists flist' f' bytes',
           [[ (Fm * BFILE.rep (FSXPBlockAlloc fsxp) (FSXPInode fsxp) flist')%pred (list2mem m') ]] *
           [[ (A * #inum |-> f')%pred (list2nmem flist') ]] *
           [[ rep bytes' f' ]] *
           [[ (Fx * arrayN off data)%pred (list2nmem bytes') ]] *
           [[ BFILE.BFAttr f = BFILE.BFAttr f' ]])
       CRASH LOG.would_recover_old (FSXPLog fsxp) F mbase 
      >} write_bytes fsxp inum off data mscs.
  Proof.
    unfold write_bytes, rep, bytes_rep.

    apply LOG.activetxn_would_recover_old.
  Admitted.

End SLOWBYTEFILE.
