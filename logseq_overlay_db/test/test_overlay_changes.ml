module Database = Logseq_overlay_db.Database
module Graph = Logseq_db_types.Graph_types
module T = Test_support
module Types = Logseq_overlay_db.Types
open Types

let insert_precondition database behavior =
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       let page_revision =
         match Database.get_pages snapshot [ T.page_uuid ] |> T.require_ok ~behavior with
         | [ Present_page { revision; _ } ] -> revision
         | _ -> Alcotest.fail "fixture page is missing"
       in
       let scope, scope_revision =
         match
           Database.get_structure
             snapshot
             (Children { parent = T.page_uuid; limit = 64; cursor = None })
           |> T.require_ok ~behavior
         with
         | Children_result { revision_scope; scope_revision; _ } ->
           revision_scope, scope_revision
         | Page_tree_result _ -> Alcotest.fail "children request returned a page tree"
       in
       Database.write_precondition
         ~blocks:[]
         ~pages:[ T.page_uuid, page_revision ]
         ~scopes:[ scope, scope_revision ]
       |> T.require_ok ~behavior)
;;

let commit_insert database behavior ordinal =
  let expected = insert_precondition database behavior in
  match
    Database.commit_local database ~expected (T.insert_blocks ~ordinal ())
    |> T.require_ok ~behavior
  with
  | Local_committed commit -> commit
  | Local_existing _ -> Alcotest.fail "fresh listener mutation already exists"
;;

let paused_subscription_returns_predecessor database =
  let behavior = "paused subscription returns immediate predecessor snapshot" in
  let subscription, snapshot = Database.listen database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () ->
      Database.release_snapshot snapshot;
      Database.unlisten subscription)
    (fun () -> T.expect_nonempty_projection ~behavior snapshot)
;;

let activated_subscription_delivers_adjacent_revision database =
  let behavior = "activated subscription delivers one adjacent exact event" in
  let subscription, predecessor = Database.listen database |> T.require_ok ~behavior in
  let predecessor_version = Database.snapshot_version predecessor in
  Database.release_snapshot predecessor;
  let promise, resolver = Eio.Promise.create () in
  Database.activate_subscription subscription ~notify:(fun change ->
    Eio.Promise.resolve resolver change)
  |> T.require_ok ~behavior;
  let commit = commit_insert database behavior 100 in
  let change = Eio.Promise.await promise in
  Database.unlisten subscription;
  match change with
  | Exact
      { generation
      ; before_revision
      ; after_revision
      ; block_uuids
      ; page_uuids
      ; structure_interests
      } ->
    T.require
      (Generation.equal generation commit.generation)
      "event generation differs from commit generation";
    T.require
      (Projection_revision.equal before_revision predecessor_version.projection_revision)
      "event is not adjacent to predecessor snapshot";
    T.require
      (Projection_revision.equal after_revision commit.after_projection_revision)
      "event after revision differs from commit";
    T.require
      (List.exists (Graph.Uuid.equal T.block_uuid) block_uuids)
      "exact event omitted inserted block UUID";
    T.require
      (List.exists (Graph.Uuid.equal T.page_uuid) page_uuids)
      "exact event omitted the affected page UUID";
    T.require
      (List.exists
         (function
           | Children_interest parent -> Graph.Uuid.equal parent T.page_uuid
           | Page_tree_interest _ | Journal_index_interest -> false)
         structure_interests)
      "exact event omitted the affected children scope";
    T.require
      (List.exists
         (function
           | Page_tree_interest page -> Graph.Uuid.equal page T.page_uuid
           | Children_interest _ | Journal_index_interest -> false)
         structure_interests)
      "exact event omitted the affected page-tree scope"
  | Projection_resync_required _ ->
    Alcotest.fail "single local insertion unexpectedly required resync"
;;

let callback_exception_is_isolated database =
  let behavior = "callback exceptions are isolated" in
  let failing, first_snapshot = Database.listen database |> T.require_ok ~behavior in
  let healthy, second_snapshot = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot first_snapshot;
  Database.release_snapshot second_snapshot;
  Database.activate_subscription failing ~notify:(fun _ ->
    failwith "injected callback failure")
  |> T.require_ok ~behavior;
  let promise, resolver = Eio.Promise.create () in
  Database.activate_subscription healthy ~notify:(fun change ->
    Eio.Promise.resolve resolver change)
  |> T.require_ok ~behavior;
  ignore (commit_insert database behavior 101);
  ignore (Eio.Promise.await promise);
  Database.unlisten failing;
  Database.unlisten healthy
;;

let self_unlisten_never_deadlocks database =
  let behavior = "callback self-unlisten never deadlocks" in
  let subscription, snapshot = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot snapshot;
  let promise, resolver = Eio.Promise.create () in
  Database.activate_subscription subscription ~notify:(fun _change ->
    Database.unlisten subscription;
    Eio.Promise.resolve resolver ())
  |> T.require_ok ~behavior;
  ignore (commit_insert database behavior 102);
  Eio.Promise.await promise;
  Database.unlisten subscription
;;

let unlisten_is_idempotent database =
  let behavior = "unlisten is idempotent" in
  let subscription, snapshot = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot snapshot;
  Database.unlisten subscription;
  Database.unlisten subscription;
  match Database.activate_subscription subscription ~notify:ignore with
  | Error Subscription_inactive -> ()
  | Error _ ->
    Alcotest.fail "activation after unlisten returned the wrong lifecycle error"
  | Ok () -> Alcotest.fail "activation after unlisten succeeded"
;;

let paused_subscription_overflow_coalesces_to_resync database =
  let behavior = "paused subscription overflow coalesces to resync" in
  let subscription, predecessor = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot predecessor;
  for ordinal = 1 to 33 do
    let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
    let revision =
      Fun.protect
        ~finally:(fun () -> Database.release_snapshot snapshot)
        (fun () ->
           match
             Database.get_blocks snapshot [ T.authoritative_block_uuid ]
             |> T.require_ok ~behavior
           with
           | [ Present_block { revision; _ } ] -> revision
           | _ -> Alcotest.fail "overflow fixture block is missing")
    in
    let expected =
      Database.write_precondition
        ~blocks:[ T.authoritative_block_uuid, revision ]
        ~pages:[]
        ~scopes:[]
      |> T.require_ok ~behavior
    in
    let mutation =
      Save_block
        { mutation_id = T.mutation_uuid (500 + ordinal)
        ; block = T.authoritative_block_uuid
        ; title = Printf.sprintf "Overflow %d" ordinal
        }
    in
    match Database.commit_local database ~expected mutation |> T.require_ok ~behavior with
    | Local_existing _ -> Alcotest.fail "overflow mutation already exists"
    | Local_committed _ -> ()
  done;
  let delivered, resolve = Eio.Promise.create () in
  Database.activate_subscription subscription ~notify:(Eio.Promise.resolve resolve)
  |> T.require_ok ~behavior;
  let change = Eio.Promise.await delivered in
  Database.unlisten subscription;
  match change with
  | Projection_resync_required { reason = Dispatcher_retention_exceeded; _ } -> ()
  | Exact _ | Projection_resync_required _ ->
    Alcotest.fail "paused overflow did not coalesce to dispatcher resync"
;;

let rejection_publishes_one_rollback_and_transport_is_silent database =
  let behavior = "rejection publishes one rollback while transport stays silent" in
  let local = commit_insert database behavior 110 in
  let subscription, predecessor = Database.listen database |> T.require_ok ~behavior in
  let predecessor_version = Database.snapshot_version predecessor in
  Database.release_snapshot predecessor;
  let changes = ref [] in
  Database.activate_subscription subscription ~notify:(fun change ->
    changes := change :: !changes)
  |> T.require_ok ~behavior;
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let submit, request =
    match
      Database.begin_outbox_transition
        database
        ~expected:(sync_view_token view)
        (Submit_group [ local.mutation_id ])
      |> T.require_ok ~behavior
    with
    | prepared, Some request -> prepared, request
    | _ -> Alcotest.fail "submission omitted protection request"
  in
  let encrypted =
    Database.protection_plaintexts request
    |> List.map (fun (id, plaintext) -> id, "encrypted:" ^ plaintext)
  in
  let submitted =
    Database.apply_outbox_transition
      database
      submit
      ~encrypted:(Some (request, encrypted))
    |> T.require_ok ~behavior
  in
  T.require (!changes = []) "transport-only submit published a projection change";
  let batch = Option.get submitted.submission_batch in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let partition =
    { accepted_prefix = []
    ; failed_member = Some local.mutation_id
    ; unexecuted_suffix = []
    ; acceptance_barrier = None
    ; missing_uuids = []
    ; diagnostics = [ "listener rollback fixture" ]
    }
  in
  let reject, crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Reject_group
         { batch_id = submission_batch_id batch
         ; resolution = Definitive { reason = Invalid_request; partition }
         })
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "rejection requested crypto";
  let rejected =
    Database.apply_outbox_transition database reject ~encrypted:None
    |> T.require_ok ~behavior
  in
  Eio.Fiber.yield ();
  Database.unlisten subscription;
  match !changes with
  | [ Exact { before_revision; after_revision; block_uuids; _ } ] ->
    T.require
      (Projection_revision.equal before_revision predecessor_version.projection_revision)
      "rollback event is not adjacent to predecessor";
    T.require
      (Projection_revision.equal after_revision rejected.after_projection_revision)
      "rollback event revision differs from commit";
    T.require
      (List.exists (Graph.Uuid.equal T.block_uuid) block_uuids)
      "rollback event omitted rejected UUID"
  | [] -> Alcotest.fail "logical rejection published no rollback event"
  | _ -> Alcotest.fail "logical rejection published more than one event or resync"
;;

let semantic_no_op_publishes_no_event database =
  let behavior = "semantic no-op publishes no event" in
  let subscription, predecessor = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot predecessor;
  let changes = ref [] in
  Database.activate_subscription subscription ~notify:(fun change ->
    changes := change :: !changes)
  |> T.require_ok ~behavior;
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  let revision =
    match
      Database.get_blocks snapshot [ T.missing_block_uuid ] |> T.require_ok ~behavior
    with
    | [ Missing_block { revision; _ } ] -> revision
    | _ -> Alcotest.fail "missing no-op target unexpectedly exists"
  in
  Database.release_snapshot snapshot;
  let expected =
    Database.write_precondition
      ~blocks:[ T.missing_block_uuid, revision ]
      ~pages:[]
      ~scopes:[]
    |> T.require_ok ~behavior
  in
  let mutation =
    Save_block
      { mutation_id = T.mutation_uuid 120
      ; block = T.missing_block_uuid
      ; title = "Still missing"
      }
  in
  (match Database.commit_local database ~expected mutation |> T.require_ok ~behavior with
   | Local_committed { status = No_change; _ } -> ()
   | _ -> Alcotest.fail "missing target did not commit as No_change");
  Database.unlisten subscription;
  T.require (!changes = []) "semantic No_change published a listener event"
;;

let authoritative_membership_change_reports_structure_interests database =
  let behavior = "authoritative membership change reports structure interests" in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let entity = Transit.String "remote-child" in
  let page =
    Transit.Array
      [ Transit.Keyword "block/uuid"; Transit.Uuid (Graph.Uuid.to_string T.page_uuid) ]
  in
  let add attribute value =
    Transit.Array [ Transit.Keyword "db/add"; entity; Transit.Keyword attribute; value ]
  in
  let wire =
    Transit.Array
      [ add "block/uuid" (Transit.Uuid (Graph.Uuid.to_string T.missing_block_uuid))
      ; add "block/title" (Transit.String "Remote child")
      ; add "block/parent" page
      ; add "block/page" page
      ; add "block/order" (Transit.String "a00000009")
      ; add "block/created-at" (Transit.Int 1_704_067_200_000)
      ; add "block/updated-at" (Transit.Int 1_704_067_200_000)
      ]
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded_transaction_of_string ~maximum_bytes:4096
    |> T.require_ok ~behavior
  in
  let cursor = Server_cursor.of_string "server-cursor:v1:1" |> T.require_ok ~behavior in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4096
      ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
      ~through:cursor
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let subscription, predecessor = Database.listen database |> T.require_ok ~behavior in
  Database.release_snapshot predecessor;
  let promise, resolver = Eio.Promise.create () in
  Database.activate_subscription subscription ~notify:(fun change ->
    Eio.Promise.resolve resolver change)
  |> T.require_ok ~behavior;
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, crypto =
    Database.begin_authoritative database ~expected:(sync_view_token sync) batch
    |> T.require_ok ~behavior
  in
  let decrypted_values =
    match crypto with
    | None -> None
    | Some request ->
      let plaintexts =
        Database.unprotection_ciphertexts request
        |> List.map (fun (id, _) -> id, "Remote child")
      in
      Some (request, plaintexts)
  in
  let application =
    match
      Database.apply_authoritative database prepared ~decrypted:decrypted_values
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "remote insertion was deferred"
  in
  ignore application;
  let change = Eio.Promise.await promise in
  Database.unlisten subscription;
  match change with
  | Exact { block_uuids; page_uuids; structure_interests; _ } ->
    T.require
      (List.exists (Graph.Uuid.equal T.missing_block_uuid) block_uuids)
      "remote insertion omitted its block UUID";
    T.require
      (List.exists (Graph.Uuid.equal T.page_uuid) page_uuids)
      "remote insertion omitted its page UUID";
    T.require
      (List.exists
         (function
           | Children_interest parent -> Graph.Uuid.equal parent T.page_uuid
           | Page_tree_interest _ | Journal_index_interest -> false)
         structure_interests)
      "remote insertion omitted its children interest";
    T.require
      (List.exists
         (function
           | Page_tree_interest page -> Graph.Uuid.equal page T.page_uuid
           | Children_interest _ | Journal_index_interest -> false)
         structure_interests)
      "remote insertion omitted its page-tree interest"
  | Projection_resync_required _ ->
    Alcotest.fail "bounded remote insertion unexpectedly required resync"
;;

let cases =
  [ T.database_case
      "listen returns paused subscriber and predecessor lease"
      paused_subscription_returns_predecessor
  ; T.database_case
      "local commit produces one adjacent exact event"
      activated_subscription_delivers_adjacent_revision
  ; T.database_case
      "callback exception does not affect another subscriber"
      callback_exception_is_isolated
  ; T.database_case
      "callback can unlisten itself without deadlock"
      self_unlisten_never_deadlocks
  ; T.database_case
      "paused subscriber overflow coalesces to resync"
      paused_subscription_overflow_coalesces_to_resync
  ; T.database_case
      "unlisten is idempotent and prevents activation"
      unlisten_is_idempotent
  ; T.database_case
      "rejection publishes one rollback and transport is silent"
      rejection_publishes_one_rollback_and_transport_is_silent
  ; T.database_case "semantic no-op publishes no event" semantic_no_op_publishes_no_event
  ; T.database_case
      "authoritative membership change reports structure interests"
      authoritative_membership_change_reports_structure_interests
  ]
;;

let () = Alcotest.run "logseq_overlay_db changes" [ "merged logical listener", cases ]
