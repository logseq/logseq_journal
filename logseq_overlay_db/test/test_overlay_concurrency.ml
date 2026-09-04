module Database = Logseq_overlay_db.Database
module T = Test_support
module Types = Logseq_overlay_db.Types
open Types

let same_fingerprint_commits_once database =
  let behavior = "two concurrent same-ID same-fingerprint writes commit once" in
  let expected = T.insert_precondition database ~parent:T.page_uuid ~behavior in
  let mutation = T.insert_blocks ~ordinal:300 () in
  let left_result = ref None in
  let right_result = ref None in
  Eio.Fiber.both
    (fun () ->
       left_result
       := Some
            (Database.commit_local database ~expected mutation |> T.require_ok ~behavior))
    (fun () ->
       right_result
       := Some
            (Database.commit_local database ~expected mutation |> T.require_ok ~behavior));
  let left_result = Option.get !left_result in
  let right_result = Option.get !right_result in
  match left_result, right_result with
  | Local_committed _, Local_existing (Existing_applied _)
  | Local_existing (Existing_applied _), Local_committed _ -> ()
  | _ -> Alcotest.fail "same-ID race did not produce one commit and one Existing_applied"
;;

let different_fingerprint_conflicts database =
  let behavior = "same-ID different-fingerprint write conflicts at commit" in
  let expected = T.insert_precondition database ~parent:T.page_uuid ~behavior in
  let first = T.insert_blocks ~ordinal:301 () in
  let different =
    Types.Insert_blocks
      { mutation_id = T.mutation_uuid 301
      ; parent = T.page_uuid
      ; tree = { uuid = T.child_uuid; title = "Different"; children = [] }
      }
  in
  ignore (Database.commit_local database ~expected first |> T.require_ok ~behavior);
  match Database.commit_local database ~expected different with
  | Error Mutation_identity_conflict -> ()
  | Error _ -> Alcotest.fail "commit-time identity race returned the wrong error"
  | Ok _ -> Alcotest.fail "different fingerprint committed under an existing ID"
;;

let close_invalidates_retained_snapshot database =
  let behavior = "close invalidates retained snapshot leases" in
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  Database.close database |> T.require_ok ~behavior;
  match Database.graph_info snapshot with
  | Error Database_closed | Error Snapshot_generation_invalidated ->
    Database.release_snapshot snapshot
  | Error _ -> Alcotest.fail "closed snapshot returned the wrong lifecycle error"
  | Ok _ -> Alcotest.fail "retained snapshot remained readable after close"
;;

let concurrent_snapshots_never_tear database =
  let behavior = "concurrent snapshots never tear authoritative and outbox roots" in
  let read () =
    let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
    Fun.protect
      ~finally:(fun () -> Database.release_snapshot snapshot)
      (fun () ->
         let version = Database.snapshot_version snapshot in
         let info = Database.graph_info snapshot |> T.require_ok ~behavior in
         T.require
           (Generation.equal version.generation info.version.generation
            && Projection_revision.equal
                 version.projection_revision
                 info.version.projection_revision)
           "snapshot version and graph-info version tore")
  in
  Eio.Fiber.both read read |> ignore
;;

let callback_never_starts_after_unlisten database =
  let behavior = "no callback starts after unlisten" in
  let subscription, snapshot = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot snapshot;
  let callbacks = Atomic.make 0 in
  Database.activate_subscription subscription ~notify:(fun _ -> Atomic.incr callbacks)
  |> T.require_ok ~behavior;
  Database.unlisten subscription;
  let expected = T.insert_precondition database ~parent:T.page_uuid ~behavior in
  ignore
    (T.commit_mutation database ~expected (T.insert_blocks ~ordinal:302 ()) ~behavior);
  T.require (Atomic.get callbacks = 0) "callback started after unlisten returned"
;;

let external_unlisten_waits_for_running_callback database =
  let behavior = "external unlisten waits for an in-flight callback" in
  let subscription, snapshot = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot snapshot;
  let callback_started, resolve_callback_started = Eio.Promise.create () in
  let release_callback, resolve_release_callback = Eio.Promise.create () in
  let unlisten_returned = Atomic.make false in
  Database.activate_subscription subscription ~notify:(fun _ ->
    Eio.Promise.resolve resolve_callback_started ();
    Eio.Promise.await release_callback)
  |> T.require_ok ~behavior;
  Eio.Fiber.both
    (fun () ->
       let expected = T.insert_precondition database ~parent:T.page_uuid ~behavior in
       ignore
         (T.commit_mutation
            database
            ~expected
            (T.insert_blocks ~ordinal:303 ())
            ~behavior);
       Eio.Promise.await callback_started;
       Database.unlisten subscription;
       Atomic.set unlisten_returned true)
    (fun () ->
       Eio.Promise.await callback_started;
       Eio.Fiber.yield ();
       T.require
         (not (Atomic.get unlisten_returned))
         "external unlisten returned while its callback was still running";
       Eio.Promise.resolve resolve_release_callback ())
;;

let close_waits_for_running_callback database =
  let behavior = "close waits for an in-flight callback" in
  let subscription, snapshot = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot snapshot;
  let callback_started, resolve_callback_started = Eio.Promise.create () in
  let release_callback, resolve_release_callback = Eio.Promise.create () in
  let close_returned = Atomic.make false in
  Database.activate_subscription subscription ~notify:(fun _ ->
    Eio.Promise.resolve resolve_callback_started ();
    Eio.Promise.await release_callback)
  |> T.require_ok ~behavior;
  Eio.Fiber.both
    (fun () ->
       let expected = T.insert_precondition database ~parent:T.page_uuid ~behavior in
       ignore
         (T.commit_mutation
            database
            ~expected
            (T.insert_blocks ~ordinal:304 ())
            ~behavior);
       Eio.Promise.await callback_started;
       Database.close database |> T.require_ok ~behavior;
       Atomic.set close_returned true)
    (fun () ->
       Eio.Promise.await callback_started;
       Eio.Fiber.yield ();
       T.require
         (not (Atomic.get close_returned))
         "close returned while a callback was still running";
       Eio.Promise.resolve resolve_release_callback ())
;;

let concurrent_commits_publish_in_revision_order database =
  let behavior = "concurrent commits publish in revision order" in
  ignore
    (T.commit_mutation
       database
       ~expected:(T.insert_precondition database ~parent:T.page_uuid ~behavior)
       (T.insert_blocks ~ordinal:307 ())
       ~behavior);
  let block_revision block =
    let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
    Fun.protect
      ~finally:(fun () -> Database.release_snapshot snapshot)
      (fun () ->
         match Database.get_blocks snapshot [ block ] |> T.require_ok ~behavior with
         | [ Present_block { revision; _ } ] -> revision
         | _ -> Alcotest.fail "concurrent commit fixture block is missing")
  in
  let save_with_precondition ordinal block title =
    let expected =
      Database.write_precondition
        ~blocks:[ block, block_revision block ]
        ~pages:[]
        ~scopes:[]
      |> T.require_ok ~behavior
    in
    expected, Save_block { mutation_id = T.mutation_uuid ordinal; block; title }
  in
  let first = save_with_precondition 305 T.block_uuid "Concurrent first" in
  let second =
    save_with_precondition 306 T.authoritative_block_uuid "Concurrent second"
  in
  let subscription, snapshot = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot snapshot;
  let events = Eio.Stream.create 2 in
  Database.activate_subscription subscription ~notify:(Eio.Stream.add events)
  |> T.require_ok ~behavior;
  let first_commit = ref None in
  let second_commit = ref None in
  Eio.Fiber.both
    (fun () ->
       first_commit
       := Some
            (Database.commit_local database ~expected:(fst first) (snd first)
             |> T.require_ok ~behavior))
    (fun () ->
       second_commit
       := Some
            (Database.commit_local database ~expected:(fst second) (snd second)
             |> T.require_ok ~behavior));
  let first_event = Eio.Stream.take events in
  let second_event = Eio.Stream.take events in
  Database.unlisten subscription;
  let revisions = function
    | Exact { before_revision; after_revision; _ } -> before_revision, after_revision
    | Projection_resync_required _ ->
      Alcotest.fail "two point commits unexpectedly exhausted the change bound"
  in
  let _, first_after = revisions first_event in
  let second_before, _ = revisions second_event in
  T.require
    (Projection_revision.equal first_after second_before)
    "concurrent commits published non-adjacent or overtaken revisions";
  let committed_after =
    [ Option.get !first_commit; Option.get !second_commit ]
    |> List.map (function
      | Local_committed commit -> commit.after_projection_revision
      | Local_existing _ -> Alcotest.fail "fresh concurrent commit became existing")
  in
  T.require
    (List.exists (Projection_revision.equal first_after) committed_after)
    "first published revision does not belong to either concurrent commit"
;;

let cases =
  [ T.database_case "same-ID same-fingerprint commits once" same_fingerprint_commits_once
  ; T.database_case
      "different fingerprint loses the ID race"
      different_fingerprint_conflicts
  ; T.database_case
      "close invalidates retained snapshot"
      close_invalidates_retained_snapshot
  ; T.database_case
      "concurrent snapshots never tear roots"
      concurrent_snapshots_never_tear
  ; T.database_case
      "no callback starts after unlisten"
      callback_never_starts_after_unlisten
  ; T.database_case
      "external unlisten waits for running callback"
      external_unlisten_waits_for_running_callback
  ; T.database_case "close waits for running callback" close_waits_for_running_callback
  ; T.database_case
      "concurrent commits publish in revision order"
      concurrent_commits_publish_in_revision_order
  ]
;;

let () = Alcotest.run "logseq_overlay_db concurrency" [ "serialized lane", cases ]
