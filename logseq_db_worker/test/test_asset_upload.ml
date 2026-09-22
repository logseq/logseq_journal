module U = Logseq_db_worker_pure_reducer.Asset_upload
module I = Logseq_db_types.Asset_upload_intent
module A = Logseq_db_types.Asset_descriptor
module C = Logseq_sync_pure_reducer.Core

let get = function
  | Ok value -> value
  | Error _ -> failwith "unexpected error"
;;

let uuid n =
  get
    (Logseq_db_types.Graph_types.Uuid.of_string
       (Printf.sprintf "00000000-0000-4000-8000-%012d" n))
;;

let scope : C.graph_scope =
  { account =
      { managed_sync_origin = Uri.of_string "https://sync.example"
      ; user_id = "user"
      ; account_generation = 1
      ; presentation_generation = 1
      ; lifecycle_generation = 1L
      }
  ; graph_id = uuid 1
  ; graph_generation = 1
  }
;;

let intent =
  get
    (I.prepare
       ~replace_reference:None
       ~operation_id:(uuid 2)
       ~origin:"https://sync.example"
       ~account:"user"
       ~graph:(uuid 1)
       ~asset:(uuid 3)
       ~version:(get (A.version ~checksum:(String.make 64 'a') ~file_type:"png"))
       ~title:"Fixture image"
       ~size:4L
       ~staged_file:"staged-file"
       ~target:(uuid 4)
       ~local_mutation:(uuid 5)
       ~metadata_mutation:(uuid 6))
;;

let one = function
  | [ x ] -> x
  | _ -> Alcotest.fail "expected exactly one owned instruction"
;;

let ticket = function
  | U.Persist (t, _, _)
  | Inspect (t, _)
  | Apply_local (t, _)
  | Put (t, _)
  | Apply_metadata (t, _)
  | Await_publication (t, _)
  | Cancel_operation t -> t
  | Release_staging _ -> Alcotest.fail "no ticket"
;;

let complete state instruction completion =
  U.step state (Completed (ticket instruction, completion))
;;

let persisted state instruction = complete state instruction U.Persisted

let phase state expected =
  Alcotest.(check bool)
    "durable phase"
    true
    (Option.map (fun x -> x.I.phase) (U.checkpoint state) = Some expected)
;;

let started () =
  let t, e = U.step (U.create ~scope ~available:true) (Start intent) in
  t, one e
;;

let to_put () =
  let t, e = started () in
  let t, e = persisted t e in
  let t, e = complete t (one e) Local_applied in
  let t, e = persisted t (one e) in
  let t, e = persisted t (one e) in
  t, one e
;;

let status t expected =
  Alcotest.(check bool) "observable upload status" true (U.status t = Some expected)
;;

let presentation_status () =
  Alcotest.(check bool)
    "empty owner has no upload"
    true
    (U.status (U.create ~scope ~available:true) = None);
  let initial, _ = started () in
  status initial Preparing;
  let sending, put = to_put () in
  status sending Sending;
  let paused, _ = U.step sending (Availability_changed false) in
  status paused Waiting;
  let resumed, effects = U.step paused (Availability_changed true) in
  status resumed Sending;
  let failed, _ = complete resumed (one effects) (Failed Network) in
  status failed (Failed_upload Network);
  let stale, _ = complete failed put Put_succeeded in
  status stale (Failed_upload Network);
  let retried, _ = U.step failed Retry in
  status retried Sending;
  let cancelling, effects = U.step retried Cancel in
  status cancelling Cancelling;
  let save =
    List.find
      (function
        | U.Persist _ -> true
        | _ -> false)
      effects
  in
  let cancelled, _ = persisted cancelling save in
  status cancelled Cancelled;
  let stopped, _ = U.step retried Shutdown in
  Alcotest.(check bool) "retired owner has no live status" true (U.status stopped = None)
;;

let ordered_publication () =
  let t, put = to_put () in
  Alcotest.(check bool)
    "upload has durable checkpoint"
    true
    (match put with
     | U.Put (_, i) -> i.phase = Uploading
     | _ -> false);
  let t, e = complete t put Put_succeeded in
  status t Publishing;
  phase t Uploading;
  let saved = one e in
  Alcotest.(check bool)
    "PUT ack first persists remote stored"
    true
    (match saved with
     | U.Persist (_, i, _) -> i.phase = Remote_stored
     | _ -> false);
  let t, e = persisted t saved in
  phase t Remote_stored;
  let t, e = persisted t (one e) in
  phase t Metadata_pending;
  let publish = one e in
  Alcotest.(check bool)
    "stable metadata mutation"
    true
    (match publish with
     | U.Apply_metadata (_, i) -> i.metadata_mutation = intent.metadata_mutation
     | _ -> false);
  let t, e = complete t publish Metadata_applied in
  let t, e = complete t (one e) Publication_acked in
  phase t Metadata_pending;
  let t, e = persisted t (one e) in
  phase t Complete;
  status t Uploaded;
  Alcotest.(check bool)
    "release only after complete durable"
    true
    (match one e with
     | U.Release_staging _ -> true
     | _ -> false)
;;

let recover_remote () =
  let restored = get (I.restore intent ~phase:Remote_stored ~revision:3) in
  let t, e = U.step (U.create ~scope ~available:true) (Restore restored) in
  let t, e = complete t (one e) (Inspected Local_present) in
  let _, e = persisted t (one e) in
  Alcotest.(check bool)
    "no second PUT after durable acknowledgement"
    true
    (match one e with
     | U.Apply_metadata _ -> true
     | _ -> false)
;;

let recover_prepared () =
  let t, e = U.step (U.create ~scope ~available:true) (Restore intent) in
  let t, e = complete t (one e) (Inspected Local_present) in
  let t, e = persisted t (one e) in
  let _, e = persisted t (one e) in
  Alcotest.(check bool)
    "no duplicate insertion after lost local ack"
    true
    (match one e with
     | U.Put (_, i) -> i.asset = intent.asset
     | _ -> false)
;;

let cancel_fences () =
  let t, put = to_put () in
  let t, e = U.step t Cancel in
  let save =
    List.find
      (function
        | U.Persist _ -> true
        | _ -> false)
      e
  in
  let t, _ = persisted t save in
  phase t Cancelled;
  let t, e = complete t put Put_succeeded in
  phase t Cancelled;
  Alcotest.(check int) "late PUT inert" 0 (List.length e)
;;

let failures () =
  let t, e = started () in
  let t, e = complete t e (Failed (Persistence_failed "disk full")) in
  Alcotest.(check int) "no mutation before durable prepare" 0 (List.length e);
  Alcotest.(check bool) "failure surfaced" true (Option.is_some (U.failure t));
  let _, e = U.step t Retry in
  Alcotest.(check bool)
    "retry preparation"
    true
    (match one e with
     | U.Persist (_, i, None) -> i.phase = Prepared
     | _ -> false)
;;

let duplicate () =
  let t, put = to_put () in
  let t, e = complete t put Put_succeeded in
  let expected = one e in
  let t, e = complete t put Put_succeeded in
  Alcotest.(check int) "duplicate completion does not persist twice" 0 (List.length e);
  let _, e = persisted t expected in
  Alcotest.(check int) "original persistence still completes" 1 (List.length e)
;;

let cancellation_recovery () =
  let saved = get (I.restore intent ~phase:Uploading ~revision:2) in
  let t, e = U.step (U.create ~scope ~available:true) (Restore saved) in
  let t, e = complete t (one e) (Inspected Entity_cancelled) in
  let t, _ = persisted t (one e) in
  phase t Cancelled
;;

let paused_recovery () =
  let saved = get (I.restore intent ~phase:Uploading ~revision:2) in
  let t, effects = U.step (U.create ~scope ~available:false) (Restore saved) in
  let t, effects = complete t (one effects) (Inspected Local_present) in
  Alcotest.(check int) "offline restore does not PUT" 0 (List.length effects);
  phase t Uploading;
  let t, effects = U.step t Retry in
  Alcotest.(check int) "retry cannot bypass pause" 0 (List.length effects);
  let t, effects = U.step t (Availability_changed true) in
  let put = one effects in
  Alcotest.(check bool)
    "resume uploads same durable intent"
    true
    (match put with
     | U.Put (_, i) -> i = saved
     | _ -> false);
  let _, effects = U.step t (Availability_changed true) in
  Alcotest.(check int)
    "repeated availability does not duplicate PUT"
    0
    (List.length effects)
;;

let pause_inflight () =
  let t, old_put = to_put () in
  let t, effects = U.step t (Availability_changed false) in
  Alcotest.(check bool)
    "pause cancels exact PUT"
    true
    (one effects = U.Cancel_operation (ticket old_put));
  Alcotest.(check bool)
    "old ticket is retired"
    false
    (U.ticket_current t (ticket old_put));
  let t, effects = complete t old_put Put_succeeded in
  Alcotest.(check int) "late success cannot publish" 0 (List.length effects);
  phase t Uploading;
  let t, effects = U.step t (Availability_changed true) in
  let new_put = one effects in
  Alcotest.(check bool)
    "resume issues a fresh ticket"
    true
    (ticket new_put <> ticket old_put);
  let t, effects = U.step t (Availability_changed false) in
  Alcotest.(check bool)
    "second pause cancels fresh ticket"
    true
    (one effects = U.Cancel_operation (ticket new_put));
  let t, effects = U.step t Cancel in
  let t, effects = persisted t (one effects) in
  phase t Cancelled;
  Alcotest.(check bool)
    "cancel releases staging while paused"
    true
    (match one effects with
     | U.Release_staging _ -> true
     | _ -> false);
  let _, effects = U.step t (Availability_changed true) in
  Alcotest.(check int)
    "availability cannot revive cancelled upload"
    0
    (List.length effects)
;;

let pause_during_checkpoint () =
  let t, effects = started () in
  let t, effects = persisted t effects in
  let t, effects = complete t (one effects) Local_applied in
  let t, effects = persisted t (one effects) in
  let saving = one effects in
  let t, effects = U.step t (Availability_changed false) in
  Alcotest.(check int) "local persistence is not cancelled" 0 (List.length effects);
  let t, effects = persisted t saving in
  phase t Uploading;
  Alcotest.(check int) "checkpoint completion respects pause" 0 (List.length effects);
  let _, effects = U.step t (Availability_changed true) in
  Alcotest.(check bool)
    "checkpoint resumes PUT"
    true
    (match one effects with
     | U.Put _ -> true
     | _ -> false)
;;

let () =
  Alcotest.run
    "asset upload"
    [ ( "public worker reducer"
      , List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          [ "presentation status", presentation_status
          ; "publication ordering", ordered_publication
          ; "remote recovery", recover_remote
          ; "prepared recovery", recover_prepared
          ; "cancel fences", cancel_fences
          ; "persistence failure", failures
          ; "duplicate completion", duplicate
          ; "deleted entity recovery", cancellation_recovery
          ; "paused recovery", paused_recovery
          ; "pause active PUT", pause_inflight
          ; "pause during checkpoint", pause_during_checkpoint
          ] )
    ]
;;
