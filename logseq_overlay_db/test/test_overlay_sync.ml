module Database = Logseq_overlay_db.Database
module T = Test_support
module Types = Logseq_overlay_db.Types
open Types

let server_cursor value =
  Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" value)
  |> T.require_ok ~behavior:"construct server cursor"
;;

let checksum value =
  Checksum.of_string ("checksum:v1:" ^ value)
  |> T.require_ok ~behavior:"construct checksum"
;;

let encoded ?(maximum_bytes = 1_024) value =
  encoded_transaction_of_string ~maximum_bytes value
  |> T.require_ok ~behavior:"bounded encoded transaction"
;;

let commit_plain_authoritative database ~cursor wire behavior =
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:[ authoritative_transaction ~cursor ~transaction:(encoded wire) ]
      ~through:cursor
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, crypto =
    Database.begin_authoritative database ~expected:(sync_view_token sync) batch
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "plaintext authoritative batch requested crypto";
  match
    Database.apply_authoritative database prepared ~decrypted:None
    |> T.require_ok ~behavior
  with
  | Authoritative_applied commit -> commit
  | Authoritative_deferred _ -> Alcotest.fail "ordinary authoritative batch was deferred"
;;

let revision_codecs_reject_unknown_versions () =
  T.require
    (Result.is_error (Generation.of_string "generation:v0:1")
     && Result.is_error (Projection_revision.of_string "projection:v0:1")
     && Result.is_error (Block_state_revision.of_string "block-state:v0:1")
     && Result.is_error (Page_state_revision.of_string "page-state:v0:1")
     && Result.is_error (Scope_revision.of_string "scope:v0:1"))
    "a cross-process revision accepted an unknown codec version"
;;

let encoded_transaction_enforces_byte_bound () =
  match encoded_transaction_of_string ~maximum_bytes:3 "four" with
  | Error Authoritative_transaction_too_large -> ()
  | Error _ -> Alcotest.fail "oversized transaction returned the wrong input error"
  | Ok _ -> Alcotest.fail "oversized encoded transaction was accepted"
;;

let opaque_sync_values_have_validated_constructors () =
  (match sync_token_of_string "sync-token:v0:1" with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "sync token accepted an unknown version");
  let token =
    sync_token_of_string "sync-token:v1:1"
    |> T.require_ok ~behavior:"construct sync token"
  in
  T.require
    (String.equal (sync_token_to_string token) "sync-token:v1:1")
    "sync token changed during round trip";
  let fingerprint =
    Mutation_fingerprint.of_string
      "mutation-fingerprint:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    |> T.require_ok ~behavior:"construct mutation fingerprint"
  in
  (match
     submission_wire
       ~maximum_bytes:3
       ~mutation_id:T.block_uuid
       ~operation:Save_block_operation
       ~protected_transaction:"four"
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "oversized protected transaction was accepted");
  match
    remote_won_proof
      ~reason:Proven_unexecuted
      ~batch_id:None
      ~t_before:None
      ~rejection_through:None
      ~earliest_conflict_cursor:None
      ~operation:Delete_blocks_operation
      ~digest:fingerprint
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unexecuted proof omitted its server-order evidence"
;;

let authoritative_batch_requires_strict_cursor_order () =
  let transaction = encoded "tx" in
  let repeated = server_cursor 1 in
  let transactions =
    [ authoritative_transaction ~cursor:repeated ~transaction
    ; authoritative_transaction ~cursor:repeated ~transaction
    ]
  in
  match
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:1_024
      ~transactions
      ~through:repeated
      ~checksum:(Some (checksum "0000000000000000"))
  with
  | Error Authoritative_cursor_not_strictly_ordered -> ()
  | Error _ -> Alcotest.fail "unordered batch returned the wrong input error"
  | Ok _ -> Alcotest.fail "authoritative batch accepted repeated cursors"
;;

let authoritative_batch_requires_through_match () =
  let transaction = encoded "tx" in
  let transactions =
    [ authoritative_transaction ~cursor:(server_cursor 1) ~transaction ]
  in
  match
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:1_024
      ~transactions
      ~through:(server_cursor 2)
      ~checksum:None
  with
  | Error Authoritative_through_mismatch -> ()
  | Error _ -> Alcotest.fail "through mismatch returned the wrong input error"
  | Ok _ -> Alcotest.fail "authoritative batch accepted mismatched through cursor"
;;

let empty_sync_view_has_checkpoint_and_no_submissions database =
  let behavior = "empty sync view" in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  T.require
    (sync_view_submissions view = [])
    "empty durable outbox exposed submission descriptors";
  ignore (sync_view_checkpoint view);
  ignore (sync_view_token view)
;;

let empty_submission_group_fails_before_durability database =
  let behavior = "empty submission group fails before durability" in
  let before = Database.inspect_sync database |> T.require_ok ~behavior in
  match
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token before)
      (Submit_group [])
  with
  | Error (Outbox_transition_invalid _) ->
    let after = Database.inspect_sync database |> T.require_ok ~behavior in
    T.require
      (sync_token_equal (sync_view_token before) (sync_view_token after))
      "failed empty submission changed the sync token"
  | Error _ -> Alcotest.fail "empty submission returned the wrong typed error"
  | Ok _ -> Alcotest.fail "empty submission group was prepared"
;;

let outbox_crypto_results_are_validated_before_application database =
  let behavior = "outbox crypto results are validated before application" in
  let first_id = T.mutation_uuid 200 in
  let second_id = T.mutation_uuid 201 in
  let commit mutation =
    match
      T.commit_mutation
        database
        ~expected:(T.insert_precondition database ~parent:T.page_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed _ -> ()
    | Local_existing _ -> Alcotest.fail "fresh crypto fixture mutation already existed"
  in
  commit (T.insert_blocks ~ordinal:200 ());
  commit (T.insert_blocks ~ordinal:201 ~uuid:T.child_uuid ());
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  match
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Submit_group [ first_id; second_id ])
  with
  | Error _ -> Alcotest.fail "eligible two-member group was not prepared"
  | Ok (_prepared, None) ->
    Alcotest.fail "submission preparation omitted protection request"
  | Ok (prepared, Some request) ->
    let plaintexts = Database.protection_plaintexts request in
    List.iter
      (fun (name, expected_error, malformed) ->
         match
           Database.apply_outbox_transition
             database
             prepared
             ~encrypted:(Some (request, malformed))
         with
         | Error (Outbox_crypto_error actual_error)
           when T.crypto_result_error_equal expected_error actual_error -> ()
         | Error _ -> Alcotest.failf "%s crypto response returned the wrong error" name
         | Ok _ -> Alcotest.failf "%s crypto response was accepted" name)
      (T.malformed_crypto_results ~maximum_value_bytes:(4 * 1_024 * 1_024) plaintexts);
    let foreign_request =
      match
        Database.begin_outbox_transition
          database
          ~expected:(sync_view_token view)
          (Submit_group [ first_id; second_id ])
        |> T.require_ok ~behavior
      with
      | _, Some request -> request
      | _, None -> Alcotest.fail "foreign preparation omitted protection request"
    in
    (match
       Database.apply_outbox_transition
         database
         prepared
         ~encrypted:
           (Some (foreign_request, Database.protection_plaintexts foreign_request))
     with
     | Error Outbox_crypto_unexpected -> ()
     | Error _ -> Alcotest.fail "foreign crypto request returned the wrong error"
     | Ok _ -> Alcotest.fail "foreign crypto request was accepted");
    ignore
      (T.commit_mutation
         database
         ~expected:(T.insert_precondition database ~parent:T.page_uuid ~behavior)
         (T.insert_blocks ~ordinal:202 ~uuid:T.missing_block_uuid ())
         ~behavior);
    (match
       Database.apply_outbox_transition
         database
         prepared
         ~encrypted:(Some (request, plaintexts))
     with
     | Error (Outbox_crypto_error Crypto_result_stale) -> ()
     | Error _ -> Alcotest.fail "stale crypto response returned the wrong error"
     | Ok _ -> Alcotest.fail "stale crypto response was accepted")
;;

let commit_insert database ~ordinal ~uuid behavior =
  match
    T.commit_mutation
      database
      ~expected:(T.insert_precondition database ~parent:T.page_uuid ~behavior)
      (T.insert_blocks ~ordinal ~uuid ())
      ~behavior
  with
  | Local_committed commit -> commit
  | Local_existing _ -> Alcotest.fail "fresh outbox mutation already existed"
;;

let server_compatible_fractional_index key =
  let digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" in
  let integer_length = function
    | 'a' .. 'z' as head -> Char.code head - Char.code 'a' + 2
    | 'A' .. 'Z' as head -> Char.code 'Z' - Char.code head + 2
    | _ -> 0
  in
  let length = String.length key in
  if length = 0
  then false
  else (
    let integer_length = integer_length key.[0] in
    integer_length > 0
    && integer_length <= length
    && (not (String.equal key ("A" ^ String.make 26 digits.[0])))
    && (length = integer_length || not (Char.equal key.[length - 1] digits.[0]))
    && String.for_all
         (fun character -> Option.is_some (String.index_opt digits character))
         (String.sub key 1 (length - 1)))
;;

let block_precondition database block behavior =
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       let revision =
         match Database.get_blocks snapshot [ block ] |> T.require_ok ~behavior with
         | [ Present_block { revision; _ } ] | [ Missing_block { revision; _ } ] ->
           revision
         | _ -> Alcotest.fail "block precondition returned the wrong cardinality"
       in
       Database.write_precondition ~blocks:[ block, revision ] ~pages:[] ~scopes:[]
       |> T.require_ok ~behavior)
;;

let queued_local_commit_is_queryable database =
  let behavior = "queued local mutation is queryable" in
  let commit = commit_insert database ~ordinal:210 ~uuid:T.block_uuid behavior in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  match sync_view_submissions view with
  | [ descriptor ] ->
    T.require
      (Logseq_db_types.Graph_types.Uuid.equal descriptor.mutation_id commit.mutation_id)
      "sync view returned the wrong mutation";
    T.require (descriptor.state = Queued) "fresh local mutation is not Queued";
    T.require (descriptor.attempt_count = 0) "fresh mutation has a transport attempt";
    T.require (descriptor.plaintext_bytes > 0) "fresh mutation has no canonical plaintext"
  | _ -> Alcotest.fail "sync view did not expose exactly one queued mutation"
;;

let local_submission_uses_normalized_transaction database =
  let behavior = "local submission uses a normalized transaction" in
  let commit = commit_insert database ~ordinal:211 ~uuid:T.block_uuid behavior in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, request =
    match
      Database.begin_outbox_transition
        database
        ~expected:(sync_view_token view)
        (Submit_group [ commit.mutation_id ])
      |> T.require_ok ~behavior
    with
    | prepared, Some request -> prepared, request
    | _ -> Alcotest.fail "submission preparation omitted its protection request"
  in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let plaintexts = Database.protection_plaintexts request in
  match plaintexts with
  | [ (item, plaintext) ] ->
    T.require
      (Codec.of_string plaintext = Transit.String "Inserted")
      "submission encryption input was not the inserted block title";
    let envelope =
      Codec.to_string (Transit.Array [ Transit.Binary "iv"; Transit.Binary "ciphertext" ])
    in
    let committed =
      Database.apply_outbox_transition
        database
        prepared
        ~encrypted:(Some (request, [ item, envelope ]))
      |> T.require_ok ~behavior
    in
    let wire =
      committed.submission_batch
      |> Option.get
      |> submission_batch_wires
      |> List.hd
      |> submission_wire_protected_transaction
      |> Codec.of_string
    in
    (match wire with
     | Transit.Array operations ->
       T.require (List.length operations >= 5) "normalized insert wire omitted facts";
       T.require
         (List.exists
            (function
              | Transit.Array [ Keyword "db/add"; _; Keyword "block/uuid"; Uuid value ] ->
                String.equal value (Graph.Uuid.to_string T.block_uuid)
              | _ -> false)
            operations)
         "normalized insert wire omitted block/uuid";
       T.require
         (List.exists
            (function
              | Transit.Array [ Keyword "db/add"; _; Keyword "block/title"; String value ]
                -> String.equal value envelope
              | _ -> false)
            operations)
         "normalized insert wire did not embed the protected title envelope";
       T.require
         (not
            (List.exists
               (function
                 | Transit.Array
                     [ Keyword ("db/add" | "db/retract"); _; Keyword "block/tx-id"; _ ] ->
                   true
                 | _ -> false)
               operations))
         "normalized insert wire leaked the local block/tx-id";
       let has_current_tx_metadata =
         List.exists
           (function
             | Transit.Array [ Keyword "db/add"; Keyword "db/current-tx"; Keyword _; _ ]
               -> true
             | _ -> false)
           operations
       in
       T.require
         (not has_current_tx_metadata)
         "normalized insert wire embedded unsupported db/current-tx metadata"
     | _ -> Alcotest.fail "submission wire was not a normalized transaction array")
  | _ -> Alcotest.fail "insert submission did not expose exactly one protected title"
;;

let prepare_submit database ids behavior =
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  match
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Submit_group ids)
    |> T.require_ok ~behavior
  with
  | prepared, Some request -> prepared, request, view
  | _ -> Alcotest.fail "submission preparation omitted its protection request"
;;

let protect request behavior =
  let encrypted =
    Database.protection_plaintexts request
    |> List.map (fun (item, plaintext) -> item, "encrypted:" ^ plaintext)
  in
  ignore behavior;
  request, encrypted
;;

let local_submission_uses_server_compatible_fractional_indices database =
  let behavior = "local submission uses server-compatible fractional indices" in
  let simple =
    List.init 9 (fun index ->
      commit_insert
        database
        ~ordinal:(500 + index)
        ~uuid:(T.uuid (Printf.sprintf "51000000-0000-4000-8000-%012d" index))
        behavior)
  in
  let tree : block_tree =
    { uuid = T.uuid "51000000-0000-4000-8000-000000000010"
    ; title = "Root with children"
    ; children =
        [ { uuid = T.uuid "51000000-0000-4000-8000-000000000011"
          ; title = "First child"
          ; children = []
          }
        ; { uuid = T.uuid "51000000-0000-4000-8000-000000000012"
          ; title = "Second child"
          ; children = []
          }
        ]
    }
  in
  let final =
    match
      T.commit_mutation
        database
        ~expected:(T.insert_precondition database ~parent:T.page_uuid ~behavior)
        (Insert_blocks { mutation_id = T.mutation_uuid 509; parent = T.page_uuid; tree })
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh tree insert already existed"
  in
  let commits = simple @ [ final ] in
  let prepared, request, _ =
    prepare_submit
      database
      (List.map (fun (commit : local_commit) -> commit.mutation_id) commits)
      behavior
  in
  let protected_values = protect request behavior in
  let batch =
    Database.apply_outbox_transition database prepared ~encrypted:(Some protected_values)
    |> T.require_ok ~behavior
    |> fun commit -> Option.get commit.submission_batch
  in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let orders =
    submission_batch_wires batch
    |> List.concat_map (fun wire ->
      match Codec.of_string (submission_wire_protected_transaction wire) with
      | Transit.Array operations ->
        List.filter_map
          (function
            | Transit.Array
                [ Transit.Keyword "db/add"
                ; _
                ; Transit.Keyword "block/order"
                ; Transit.String order
                ] -> Some order
            | _ -> None)
          operations
      | _ -> Alcotest.fail "submitted insertion was not a Transit array")
  in
  T.require (List.length orders = 12) "submitted tree omitted generated order values";
  T.require
    (List.for_all server_compatible_fractional_index orders)
    "submitted insertion emitted an invalid fractional index"
;;

let fake_decrypted_plaintext ~message ciphertext =
  let prefix = "encrypted:" in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  T.require (String.starts_with ~prefix ciphertext) message;
  let encoded =
    String.sub
      ciphertext
      (String.length prefix)
      (String.length ciphertext - String.length prefix)
  in
  match Codec.of_string encoded with
  | Transit.String plaintext -> plaintext
  | _ -> Alcotest.fail "fake decrypted value was not a Transit string"
;;

let atomic_submit_and_retry_are_byte_identical ?(advance = false) database =
  let behavior = "atomic submission and byte-identical retry" in
  let first = commit_insert database ~ordinal:220 ~uuid:T.block_uuid behavior in
  let second = commit_insert database ~ordinal:221 ~uuid:T.child_uuid behavior in
  let prepared, request, _view =
    prepare_submit database [ first.mutation_id; second.mutation_id ] behavior
  in
  let protected_values = protect request behavior in
  let committed =
    Database.apply_outbox_transition database prepared ~encrypted:(Some protected_values)
    |> T.require_ok ~behavior
  in
  T.require
    (Projection_revision.equal
       committed.before_projection_revision
       committed.after_projection_revision)
    "transport-only submit advanced the projection";
  let batch = Option.get committed.submission_batch in
  let original_wires = submission_batch_wires batch in
  if advance
  then
    ignore
      (commit_plain_authoritative
         database
         ~cursor:(server_cursor 1)
         (let module Json = Transit_core.Json in
          Json.Array
            [ Json.Array
                [ Json.Keyword "db/add"
                ; Json.Array
                    [ Json.Keyword "block/uuid"
                    ; Json.Uuid
                        (Logseq_db_types.Graph_types.Uuid.to_string
                           T.authoritative_block_uuid)
                    ]
                ; Json.Keyword "block/updated-at"
                ; Json.Int 1_704_067_200_456
                ]
            ]
          |> Transit_native.Transit.Json.to_string
               ~mode:Transit_native.Transit.Json.Verbose)
         behavior);
  let before_snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  let before_version = Database.snapshot_version before_snapshot in
  Database.release_snapshot before_snapshot;
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let retry, crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Retry_group (submission_batch_id batch))
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "retry unexpectedly requested protection";
  let retry_commit =
    Database.apply_outbox_transition database retry ~encrypted:None
    |> T.require_ok ~behavior
  in
  let retried_wires =
    retry_commit.submission_batch |> Option.get |> submission_batch_wires
  in
  let retried = Option.get retry_commit.submission_batch in
  T.require
    (Server_cursor.equal
       (submission_batch_t_before batch)
       (submission_batch_t_before retried))
    "retry changed the frozen conditional submission baseline";
  T.require
    (Submission_batch_id.equal (submission_batch_id batch) (submission_batch_id retried)
     && List.map submission_wire_mutation_id original_wires
        = List.map submission_wire_mutation_id retried_wires)
    "retry changed the batch identity or member order";
  T.require
    (List.map submission_wire_protected_transaction original_wires
     = List.map submission_wire_protected_transaction retried_wires)
    "retry changed protected bytes";
  let after_snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  let after_version = Database.snapshot_version after_snapshot in
  Database.release_snapshot after_snapshot;
  T.require
    (Projection_revision.equal
       before_version.projection_revision
       after_version.projection_revision)
    "transport-only submit/retry changed public snapshot revision"
;;

let submission_rejects_unfrozen_queued_dependency database =
  let behavior = "submission rejects an unfrozen queued dependency" in
  ignore (commit_insert database ~ordinal:222 ~uuid:T.block_uuid behavior);
  let dependent =
    match
      T.commit_mutation
        database
        ~expected:(block_precondition database T.block_uuid behavior)
        (Types.Save_block
           { mutation_id = T.mutation_uuid 223
           ; block = T.block_uuid
           ; title = "Depends on queued insert"
           })
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh dependent mutation already existed"
  in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  match
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Submit_group [ dependent.mutation_id ])
  with
  | Error (Outbox_dependency_ineligible mutation_id)
    when Graph.Uuid.equal mutation_id dependent.mutation_id -> ()
  | Error _ -> Alcotest.fail "unfrozen dependency returned the wrong error"
  | Ok _ -> Alcotest.fail "dependent mutation submitted ahead of its queued owner"
;;

let submission_rejects_reordered_members database =
  let behavior = "submission rejects reordered members" in
  let first = commit_insert database ~ordinal:224 ~uuid:T.block_uuid behavior in
  let second = commit_insert database ~ordinal:225 ~uuid:T.child_uuid behavior in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  match
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Submit_group [ second.mutation_id; first.mutation_id ])
  with
  | Error (Outbox_transition_invalid _) -> ()
  | Error _ -> Alcotest.fail "reordered submission returned the wrong error"
  | Ok _ -> Alcotest.fail "reordered submission members were accepted"
;;

let stale_sync_token_fails_without_state_change database =
  let behavior = "stale sync token fails atomically" in
  let initial = Database.inspect_sync database |> T.require_ok ~behavior in
  let commit = commit_insert database ~ordinal:230 ~uuid:T.block_uuid behavior in
  match
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token initial)
      (Submit_group [ commit.mutation_id ])
  with
  | Error Outbox_sync_token_conflict ->
    let current = Database.inspect_sync database |> T.require_ok ~behavior in
    (match sync_view_submissions current with
     | [ descriptor ] when descriptor.state = Queued -> ()
     | _ -> Alcotest.fail "token conflict changed queued state")
  | Error _ -> Alcotest.fail "stale token returned the wrong error"
  | Ok _ -> Alcotest.fail "stale token prepared a transition"
;;

let delete_submission_requires_singleton database =
  let behavior = "delete submission requires singleton" in
  ignore (commit_insert database ~ordinal:240 ~uuid:T.block_uuid behavior);
  let expected = T.delete_precondition database ~block:T.block_uuid ~behavior in
  let delete =
    match
      T.commit_mutation database ~expected (T.delete_blocks ~ordinal:241 ()) ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh delete already existed"
  in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let ids =
    sync_view_submissions view |> List.map (fun descriptor -> descriptor.mutation_id)
  in
  T.require
    (List.exists (Logseq_db_types.Graph_types.Uuid.equal delete.mutation_id) ids)
    "delete is absent from outbox";
  match
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Submit_group ids)
  with
  | Error Outbox_delete_requires_singleton -> ()
  | Error _ -> Alcotest.fail "multi-member delete returned the wrong error"
  | Ok _ -> Alcotest.fail "delete was accepted in a multi-member group"
;;

let delete_submission_freezes_complete_wire_footprint database =
  let behavior = "delete submission freezes its complete wire footprint" in
  let expected =
    T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior
  in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 242; root = T.authoritative_block_uuid }
  in
  let commit =
    match T.commit_mutation database ~expected mutation ~behavior with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh delete already existed"
  in
  let prepared, request, _ = prepare_submit database [ commit.mutation_id ] behavior in
  let protected_values = protect request behavior in
  let batch =
    Database.apply_outbox_transition database prepared ~encrypted:(Some protected_values)
    |> T.require_ok ~behavior
    |> fun committed -> Option.get committed.submission_batch
  in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let operations =
    batch
    |> submission_batch_wires
    |> List.hd
    |> submission_wire_protected_transaction
    |> Codec.of_string
    |> function
    | Transit.Array operations -> operations
    | _ -> Alcotest.fail "delete wire is not a transaction array"
  in
  let lookup uuid =
    Transit.Array
      [ Transit.Keyword "block/uuid"; Transit.Uuid (Graph.Uuid.to_string uuid) ]
  in
  T.require
    (List.exists
       (function
         | Transit.Array [ Keyword "db/retractEntity"; entity ] ->
           entity = lookup T.authoritative_block_uuid
         | _ -> false)
       operations)
    "delete wire omitted its frozen subtree frontier";
  T.require
    (List.exists
       (function
         | Transit.Array
             [ Keyword "db.fn/retractAttribute"; entity; Keyword "block/refs" ] ->
           entity = lookup T.reference_source_uuid
         | _ -> false)
       operations)
    "delete wire omitted its frozen incoming-reference rewrite"
;;

let admission_charges_plaintext_and_protected_bytes database =
  let behavior = "admission charges materialized outbox bytes" in
  let commit = commit_insert database ~ordinal:250 ~uuid:T.block_uuid behavior in
  let queued = Database.inspect_admission database |> T.require_ok ~behavior in
  T.require (queued.active_records = 1) "queued mutation was not charged as one record";
  T.require (queued.active_bytes > 0) "queued plaintext bytes were not charged";
  T.require (queued.protected_wire_bytes = 0) "queued mutation charged protected bytes";
  let prepared, request, _view =
    prepare_submit database [ commit.mutation_id ] behavior
  in
  let protected_values = protect request behavior in
  Database.apply_outbox_transition database prepared ~encrypted:(Some protected_values)
  |> T.require_ok ~behavior
  |> ignore;
  let submitted = Database.inspect_admission database |> T.require_ok ~behavior in
  T.require
    (submitted.protected_wire_bytes > 0)
    "submitted protected bytes were not charged"
;;

let dependency_shadow_is_admitted_at_first_submission () =
  let behavior = "dependency shadow is admitted at first submission" in
  let limits =
    { Types.response_budget_bytes = 4 * 1_024 * 1_024
    ; outbox_max_records = 4_096
    ; outbox_max_bytes = 16 * 1_024
    ; change_max_items = 4_096
    ; change_max_bytes = 4 * 1_024 * 1_024
    ; dispatcher_capacity = 32
    ; wire_batch_max_bytes = 16 * 1_024
    }
  in
  T.with_database_using_limits ~behavior limits (fun database ->
    let module Transit = Transit_core.Json in
    let module Codec = Transit_native.Transit.Json in
    let remote_order = String.make 16_200 'r' in
    let wire =
      Codec.to_string
        ~mode:Codec.Verbose
        (Transit.Array
           [ Transit.Array
               [ Transit.Keyword "db/add"
               ; Transit.Array
                   [ Transit.Keyword "block/uuid"
                   ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
                   ]
               ; Transit.Keyword "block/order"
               ; Transit.String remote_order
               ]
           ])
    in
    let transaction = encoded ~maximum_bytes:(16 * 1_024) wire in
    let cursor = server_cursor 1 in
    let batch =
      authoritative_batch
        ~maximum_count:16
        ~maximum_bytes:(16 * 1_024)
        ~transactions:[ authoritative_transaction ~cursor ~transaction ]
        ~through:cursor
        ~checksum:None
      |> T.require_ok ~behavior
    in
    let sync = Database.inspect_sync database |> T.require_ok ~behavior in
    let prepared, crypto =
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    in
    T.require (Option.is_none crypto) "plaintext order update requested crypto";
    let application =
      match Database.apply_authoritative database prepared ~decrypted:None with
      | Ok application -> application
      | Error (Authoritative_decode_failed message) ->
        Alcotest.failf "large order decode failed: %s" message
      | Error (Authoritative_integrity_failure message) ->
        Alcotest.failf "large order integrity failed: %s" message
      | Error _ -> Alcotest.fail "large order update returned an unexpected error"
    in
    (match application with
     | Authoritative_applied _ -> ()
     | Authoritative_deferred _ -> Alcotest.fail "ordinary order update was deferred");
    let mutation =
      Types.Save_block
        { mutation_id = T.mutation_uuid 251
        ; block = T.authoritative_block_uuid
        ; title = "Small local title"
        }
    in
    let local =
      match
        T.commit_mutation
          database
          ~expected:
            (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
          mutation
          ~behavior
      with
      | Local_committed commit -> commit
      | Local_existing _ -> Alcotest.fail "fresh save already existed"
    in
    let view = Database.inspect_sync database |> T.require_ok ~behavior in
    let preparation, request =
      Database.begin_outbox_transition
        database
        ~expected:(sync_view_token view)
        (Submit_group [ local.mutation_id ])
      |> T.require_ok ~behavior
    in
    let request = Option.get request in
    let protected_values = protect request behavior in
    match
      Database.apply_outbox_transition
        database
        preparation
        ~encrypted:(Some protected_values)
    with
    | Error Outbox_limit_exceeded -> ()
    | Error _ -> Alcotest.fail "dependency-shadow admission returned the wrong error"
    | Ok _ -> Alcotest.fail "oversized dependency shadow was durably submitted")
;;

let submit_one database (commit : local_commit) behavior =
  let prepared, request, _view =
    prepare_submit database [ commit.mutation_id ] behavior
  in
  let protected_values = protect request behavior in
  let committed =
    Database.apply_outbox_transition database prepared ~encrypted:(Some protected_values)
    |> T.require_ok ~behavior
  in
  Option.get committed.submission_batch
;;

let submitted_transaction batch =
  batch |> submission_batch_wires |> List.hd |> submission_wire_protected_transaction
;;

let server_normalized_transaction ~mutation_id ~operation transaction =
  ignore mutation_id;
  ignore operation;
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let canonical_temp = function
    | Transit.String value
      when String.starts_with ~prefix:"overlay-insert:" value
           || String.starts_with ~prefix:"overlay-page:" value ->
      Transit.String
        (String.sub
           value
           (String.index value ':' + 1)
           (String.length value - String.index value ':' - 1))
    | value -> value
  in
  let normalize = function
    | Transit.Array
        [ (Transit.Keyword ("db/add" | "db/retract") as operation)
        ; entity
        ; (Transit.Keyword attribute as encoded_attribute)
        ; value
        ] ->
      let value =
        if String.equal attribute "block/parent" || String.equal attribute "block/page"
        then canonical_temp value
        else value
      in
      Transit.Array
        [ operation; canonical_temp entity; encoded_attribute; value; Transit.Int 1 ]
    | operation -> operation
  in
  match Codec.of_string transaction with
  | Transit.Array operations ->
    Codec.to_string ~mode:Codec.Verbose (Transit.Array (List.map normalize operations))
  | _ -> Alcotest.fail "submitted transaction was not a Transit array"
;;

let server_transaction ~mutation_id ~operation batch =
  server_normalized_transaction ~mutation_id ~operation (submitted_transaction batch)
;;

let decrypt_submitted_request request behavior =
  let plaintexts =
    Database.unprotection_ciphertexts request
    |> List.map (fun (id, ciphertext) ->
      ( id
      , fake_decrypted_plaintext
          ~message:"submitted protected envelope changed"
          ciphertext ))
  in
  ignore behavior;
  request, plaintexts
;;

let acceptance_is_transport_only database =
  let behavior = "acceptance is durable and transport-only" in
  let commit = commit_insert database ~ordinal:260 ~uuid:T.block_uuid behavior in
  let batch = submit_one database commit behavior in
  let before = Database.current_snapshot database |> T.require_ok ~behavior in
  let before_version = Database.snapshot_version before in
  Database.release_snapshot before;
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let barrier = { through = server_cursor 1; checksum = checksum "accepted" } in
  let prepared, crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Accept_group { batch_id = submission_batch_id batch; barrier })
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "acceptance requested crypto";
  let accepted =
    Database.apply_outbox_transition database prepared ~encrypted:None
    |> T.require_ok ~behavior
  in
  T.require
    (Projection_revision.equal
       accepted.before_projection_revision
       accepted.after_projection_revision)
    "acceptance advanced projection revision";
  let after = Database.current_snapshot database |> T.require_ok ~behavior in
  let after_version = Database.snapshot_version after in
  Database.release_snapshot after;
  T.require
    (Projection_revision.equal
       before_version.projection_revision
       after_version.projection_revision)
    "acceptance changed public snapshot";
  let final_view = Database.inspect_sync database |> T.require_ok ~behavior in
  match sync_view_submissions final_view with
  | [ descriptor ] ->
    (match descriptor.state with
     | Accepted_pending_authoritative id
       when Submission_batch_id.equal id (submission_batch_id batch) -> ()
     | _ -> Alcotest.fail "acceptance did not retain batch correlation")
  | _ -> Alcotest.fail "acceptance changed outbox cardinality"
;;

let acceptance_barrier_cannot_precede_submission_interval database =
  let behavior = "acceptance barrier cannot precede submission interval" in
  let commit = commit_insert database ~ordinal:265 ~uuid:T.block_uuid behavior in
  let batch = submit_one database commit behavior in
  let before = Database.inspect_sync database |> T.require_ok ~behavior in
  match
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token before)
      (Accept_group
         { batch_id = submission_batch_id batch
         ; barrier = { through = server_cursor 0; checksum = checksum "0000000000000000" }
         })
  with
  | Error (Outbox_transition_invalid _) -> ()
  | Error _ -> Alcotest.fail "early acceptance returned the wrong validation error"
  | Ok _ -> Alcotest.fail "acceptance barrier preceded the submitted cursor interval"
;;

let matching_state_does_not_replace_origin_evidence database =
  let behavior = "matching state does not replace origin evidence" in
  let mutation =
    Types.Save_block
      { mutation_id = T.mutation_uuid 266
      ; block = T.authoritative_block_uuid
      ; title = "Authoritative block"
      }
  in
  let commit =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh satisfied mutation already existed"
  in
  let batch = submit_one database commit behavior in
  let before = Database.inspect_sync database |> T.require_ok ~behavior in
  let barrier = { through = server_cursor 0; checksum = checksum "0000000000000000" } in
  match
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token before)
      (Accept_group { batch_id = submission_batch_id batch; barrier })
  with
  | Error (Outbox_transition_invalid _) -> ()
  | Error _ -> Alcotest.fail "evidence-free acceptance returned the wrong error"
  | Ok _ -> Alcotest.fail "matching fields replaced missing own-origin evidence"
;;

let definitive_rejection_rolls_back_once database =
  let behavior = "definitive rejection rolls back logical effect once" in
  let commit = commit_insert database ~ordinal:270 ~uuid:T.block_uuid behavior in
  let batch = submit_one database commit behavior in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let partition =
    { accepted_prefix = []
    ; failed_member = Some commit.mutation_id
    ; unexecuted_suffix = []
    ; acceptance_barrier = None
    ; missing_uuids = []
    ; diagnostics = [ "rejected by deterministic fixture" ]
    }
  in
  let prepared, crypto =
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
    Database.apply_outbox_transition database prepared ~encrypted:None
    |> T.require_ok ~behavior
  in
  T.require
    (not
       (Projection_revision.equal
          rejected.before_projection_revision
          rejected.after_projection_revision))
    "logical rollback did not advance projection revision";
  (match rejected.logical_change_summary with
   | Exact_logical_change { block_uuids; _ } ->
     T.require
       (List.exists (Logseq_db_types.Graph_types.Uuid.equal T.block_uuid) block_uuids)
       "rollback summary omitted rejected block"
   | No_logical_change | Logical_resync_required _ ->
     Alcotest.fail "single rejected insertion did not return an exact rollback");
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  (match Database.get_blocks snapshot [ T.block_uuid ] |> T.require_ok ~behavior with
   | [ Missing_block _ ] -> ()
   | _ -> Alcotest.fail "rejected insertion remained visible");
  Database.release_snapshot snapshot;
  let final_view = Database.inspect_sync database |> T.require_ok ~behavior in
  (match sync_view_submissions final_view with
   | [ descriptor ] when descriptor.state = Blocked -> ()
   | _ -> Alcotest.fail "rejected submission did not become Blocked");
  (match
     Database.commit_local
       database
       ~expected:(T.empty_precondition ~behavior)
       (T.insert_blocks ~ordinal:270 ())
     |> T.require_ok ~behavior
   with
   | Local_existing
       (Existing_blocked
          { mutation_id
          ; prior_transport_state = Submitted prior_batch
          ; reason = Rejected
          ; same_id_retry_eligible = false
          ; _
          }) ->
     T.require
       (Graph.Uuid.equal mutation_id commit.mutation_id)
       "blocked lookup returned another mutation";
     T.require
       (Submission_batch_id.equal prior_batch (submission_batch_id batch))
       "blocked lookup lost its submission batch"
   | _ -> Alcotest.fail "blocked same-ID lookup was not Existing_blocked");
  (match
     Database.retry_blocked
       database
       ~expected:(T.empty_precondition ~behavior)
       ~mutation_id:commit.mutation_id
   with
   | Error Blocked_retry_ineligible -> ()
   | Error _ -> Alcotest.fail "rejected mutation retry returned the wrong error"
   | Ok _ -> Alcotest.fail "definitively rejected mutation was retryable with the same ID");
  let discarded =
    Database.discard_blocked database ~mutation_id:commit.mutation_id
    |> T.require_ok ~behavior
  in
  T.require
    (Projection_revision.equal
       discarded.before_projection_revision
       discarded.after_projection_revision)
    "discarding an inactive blocked mutation advanced projection";
  let after_discard = Database.inspect_sync database |> T.require_ok ~behavior in
  T.require
    (sync_view_submissions after_discard = [])
    "discarded mutation remained in the active outbox";
  match
    Database.commit_local
      database
      ~expected:(T.empty_precondition ~behavior)
      (T.insert_blocks ~ordinal:270 ())
    |> T.require_ok ~behavior
  with
  | Local_existing (Existing_discarded existing)
    when Graph.Uuid.equal existing.mutation_id commit.mutation_id -> ()
  | _ -> Alcotest.fail "discarded same-ID lookup was not Existing_discarded"
;;

let authoritative_batch_updates_the_logical_snapshot database =
  let behavior = "authoritative batch updates one logical snapshot" in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
              ]
          ; Transit.Keyword "block/updated-at"
          ; Transit.Int 1_704_067_200_123
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded
  in
  let cursor = server_cursor 1 in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
      ~through:cursor
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let before = Database.current_snapshot database |> T.require_ok ~behavior in
  let before_version = Database.snapshot_version before in
  Database.release_snapshot before;
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, crypto =
    Database.begin_authoritative database ~expected:(sync_view_token sync) batch
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "plaintext authoritative batch requested crypto";
  let committed =
    match
      Database.apply_authoritative database prepared ~decrypted:None
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "ordinary remote batch was deferred"
  in
  T.require
    (Server_cursor.equal committed.checkpoint cursor)
    "authoritative commit did not advance checkpoint";
  T.require
    (not
       (Projection_revision.equal
          before_version.projection_revision
          committed.after_projection_revision))
    "visible authoritative update did not advance projection";
  let after = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_blocks after [ T.authoritative_block_uuid ] |> T.require_ok ~behavior
   with
   | [ Present_block { value; _ } ] ->
     T.require
       (value.block.updated_at_ms = 1_704_067_200_123L)
       "authoritative updated-at was not projected"
   | _ -> Alcotest.fail "authoritative block disappeared after remote update");
  Database.release_snapshot after
;;

let authoritative_rebase_replans_queued_ordinary_mutation database =
  let behavior = "authoritative rebase replans queued ordinary mutation" in
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  let revision =
    match
      Database.get_blocks snapshot [ T.authoritative_block_uuid ]
      |> T.require_ok ~behavior
    with
    | [ Present_block { revision; _ } ] -> revision
    | _ -> Alcotest.fail "authoritative block is missing"
  in
  Database.release_snapshot snapshot;
  let mutation_id = T.mutation_uuid 278 in
  let mutation =
    Types.Save_block
      { mutation_id; block = T.authoritative_block_uuid; title = "Queued local title" }
  in
  let expected =
    Database.write_precondition
      ~blocks:[ T.authoritative_block_uuid, revision ]
      ~pages:[]
      ~scopes:[]
    |> T.require_ok ~behavior
  in
  ignore (T.commit_mutation database ~expected mutation ~behavior);
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
              ]
          ; Transit.Keyword "block/updated-at"
          ; Transit.Int 1_704_067_200_456
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
  in
  let committed =
    commit_plain_authoritative database ~cursor:(server_cursor 1) wire behavior
  in
  T.require
    (List.exists (Graph.Uuid.equal mutation_id) committed.replanned_queued_ids)
    "queued ordinary mutation was not reported as replanned";
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_blocks snapshot [ T.authoritative_block_uuid ] |> T.require_ok ~behavior
   with
   | [ Present_block { value; _ } ] ->
     T.require
       (String.equal value.block.title "Queued local title"
        && value.block.updated_at_ms <> 1_704_067_200_456L)
       "replanned queued overlay lost its local field mask"
   | _ -> Alcotest.fail "replanned block disappeared");
  Database.release_snapshot snapshot
;;

let authoritative_rebase_terminalizes_queued_no_change database =
  let behavior = "authoritative rebase terminalizes queued no-change" in
  let expected = block_precondition database T.authoritative_block_uuid behavior in
  let mutation_id = T.mutation_uuid 279 in
  let mutation =
    Types.Set_task_status
      { mutation_id; block = T.authoritative_block_uuid; status = Todo }
  in
  ignore (T.commit_mutation database ~expected mutation ~behavior);
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
              ]
          ; Transit.Keyword "logseq.property/status"
          ; Transit.Keyword "logseq.property/status.todo"
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
  in
  let committed =
    commit_plain_authoritative database ~cursor:(server_cursor 1) wire behavior
  in
  T.require
    (List.exists
       (fun (receipt : terminal_receipt) ->
          match receipt.receipt with
          | No_change_receipt value -> Graph.Uuid.equal value.mutation_id mutation_id
          | Applied_receipt _ | Remote_won_receipt _ | Discarded_receipt _ -> false)
       committed.terminal_receipts)
    "queued no-change did not produce a terminal receipt";
  T.require
    (not (List.exists (Graph.Uuid.equal mutation_id) committed.replanned_queued_ids))
    "queued no-change was reported as an active replan";
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  T.require
    (not
       (List.exists
          (fun (descriptor : submission_descriptor) ->
             Graph.Uuid.equal descriptor.mutation_id mutation_id)
          (sync_view_submissions sync)))
    "queued no-change remained in the active outbox"
;;

let authoritative_rebase_blocks_transitive_queued_dependency database =
  let behavior = "authoritative rebase blocks transitive queued dependency" in
  let inserted_id = T.mutation_uuid 280 in
  let inserted = T.missing_block_uuid in
  let insert =
    Types.Insert_blocks
      { mutation_id = inserted_id
      ; parent = T.page_uuid
      ; tree = { uuid = inserted; title = "Pending parent child"; children = [] }
      }
  in
  ignore
    (T.commit_mutation
       database
       ~expected:(T.insert_precondition database ~parent:T.page_uuid ~behavior)
       insert
       ~behavior);
  let dependent_id = T.mutation_uuid 281 in
  let dependent =
    Types.Save_block
      { mutation_id = dependent_id; block = inserted; title = "Dependent edit" }
  in
  ignore
    (T.commit_mutation
       database
       ~expected:(block_precondition database inserted behavior)
       dependent
       ~behavior);
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/retractEntity"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.page_uuid)
              ]
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
  in
  let committed =
    commit_plain_authoritative database ~cursor:(server_cursor 1) wire behavior
  in
  T.require
    (List.exists (Graph.Uuid.equal inserted_id) committed.blocked_ids
     && List.exists (Graph.Uuid.equal dependent_id) committed.blocked_ids)
    "rebase did not report both blocked queued mutations";
  let empty = T.empty_precondition ~behavior in
  let blocked_reason mutation =
    match
      Database.commit_local database ~expected:empty mutation |> T.require_ok ~behavior
    with
    | Local_existing (Existing_blocked value) -> value.reason
    | Local_existing _ | Local_committed _ ->
      Alcotest.fail "blocked queued mutation did not retain its durable outcome"
  in
  T.require
    (blocked_reason insert = Planner_dependency_changed)
    "missing authoritative parent used the wrong block reason";
  T.require
    (blocked_reason dependent = Dependency_blocked inserted_id)
    "dependent queued mutation did not identify its blocked predecessor"
;;

let authoritative_crypto_is_correlated_and_applied database =
  let behavior = "authoritative crypto is correlated and applied" in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let envelope =
    Codec.to_string (Transit.Array [ Transit.Binary "iv"; Transit.Binary "ciphertext" ])
  in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
              ]
          ; Transit.Keyword "block/title"
          ; Transit.String envelope
          ]
      ; Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.reference_source_uuid)
              ]
          ; Transit.Keyword "block/title"
          ; Transit.String envelope
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded
  in
  let cursor = server_cursor 1 in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
      ~through:cursor
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | prepared, Some request -> prepared, request
    | _ -> Alcotest.fail "protected authoritative title omitted crypto request"
  in
  let decrypted_values request =
    match Database.unprotection_ciphertexts request with
    | [ (first_id, first); (second_id, second) ] ->
      T.require
        (String.equal first envelope && String.equal second envelope)
        "crypto request changed an envelope";
      [ first_id, "Remote decrypted title"; second_id, "Remote reference title" ]
    | _ -> Alcotest.fail "protected authoritative titles returned the wrong item count"
  in
  let plaintexts = decrypted_values request in
  List.iter
    (fun (name, expected_error, malformed) ->
       match
         Database.apply_authoritative
           database
           prepared
           ~decrypted:(Some (request, malformed))
       with
       | Error (Authoritative_crypto_error actual_error)
         when T.crypto_result_error_equal expected_error actual_error -> ()
       | Error _ -> Alcotest.failf "%s authoritative crypto returned the wrong error" name
       | Ok _ -> Alcotest.failf "%s authoritative crypto was accepted" name)
    (T.malformed_crypto_results ~maximum_value_bytes:(4 * 1_024 * 1_024) plaintexts);
  let second_prepared, second_request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | prepared, Some request -> prepared, request
    | _ -> Alcotest.fail "second authoritative preparation omitted crypto request"
  in
  (match
     Database.apply_authoritative
       database
       prepared
       ~decrypted:(Some (second_request, decrypted_values second_request))
   with
   | Error Authoritative_crypto_unexpected -> ()
   | Error _ -> Alcotest.fail "foreign authoritative request returned the wrong error"
   | Ok _ -> Alcotest.fail "foreign authoritative request was accepted");
  let application =
    match
      Database.apply_authoritative
        database
        second_prepared
        ~decrypted:(Some (second_request, decrypted_values second_request))
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "protected remote update was deferred"
  in
  ignore application;
  (match
     Database.apply_authoritative
       database
       prepared
       ~decrypted:(Some (request, plaintexts))
   with
   | Error (Authoritative_crypto_error Crypto_result_stale) -> ()
   | Error _ -> Alcotest.fail "stale authoritative crypto returned the wrong error"
   | Ok _ -> Alcotest.fail "stale authoritative crypto was accepted");
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_blocks snapshot [ T.authoritative_block_uuid ] |> T.require_ok ~behavior
   with
   | [ Present_block { value; _ } ] ->
     T.require
       (String.equal value.block.title "Remote decrypted title")
       "decrypted authoritative title was not projected"
   | _ -> Alcotest.fail "authoritative block disappeared after decrypted update");
  Database.release_snapshot snapshot
;;

let submitted_delete_defers_authoritative_batch_until_transport_outcome database =
  let behavior = "submitted delete defers authoritative batch until transport outcome" in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 305; root = T.authoritative_block_uuid }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh deferred delete already existed"
  in
  let submitted = submit_one database local behavior in
  let wire =
    server_transaction ~mutation_id:local.mutation_id ~operation:"delete-blocks" submitted
    |> encoded
  in
  let cursor = server_cursor 1 in
  let checksum = checksum "dededededededede" in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
      ~through:cursor
      ~checksum:(Some checksum)
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | prepared, Some request -> prepared, request
    | _ -> Alcotest.fail "deferred own delete omitted crypto request"
  in
  let decrypted = decrypt_submitted_request request behavior in
  (match
     Database.apply_authoritative database prepared ~decrypted:(Some decrypted)
     |> T.require_ok ~behavior
   with
   | Authoritative_deferred (Await_submission_outcome batch_id) ->
     T.require
       (Submission_batch_id.equal batch_id (submission_batch_id submitted))
       "defer named the wrong submission batch"
   | Authoritative_applied _ ->
     Alcotest.fail "submitted delete allowed authoritative commit before its outcome");
  (match Database.apply_authoritative database prepared ~decrypted:(Some decrypted) with
   | Error Authoritative_preparation_consumed -> ()
   | Error _ -> Alcotest.fail "deferred preparation returned the wrong reuse error"
   | Ok _ -> Alcotest.fail "deferred preparation was reusable");
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let accepted, crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Accept_group
         { batch_id = submission_batch_id submitted
         ; barrier = { through = cursor; checksum }
         })
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "acceptance unexpectedly requested crypto";
  Database.apply_outbox_transition database accepted ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let reprepared, request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | prepared, Some request -> prepared, request
    | _ -> Alcotest.fail "reprepared own delete omitted crypto request"
  in
  let decrypted = decrypt_submitted_request request behavior in
  match Database.apply_authoritative database reprepared ~decrypted:(Some decrypted) with
  | Ok (Authoritative_applied _) -> ()
  | Ok (Authoritative_deferred _) ->
    Alcotest.fail "transport outcome did not release the deferred authoritative batch"
  | Error Authoritative_commit_token_conflict ->
    Alcotest.fail "released authoritative batch observed a commit token conflict"
  | Error (Authoritative_commit_persistence_failed message) ->
    Alcotest.failf "released authoritative batch failed persistence: %s" message
  | Error (Authoritative_commit_fatal_state message) ->
    Alcotest.failf "released authoritative batch failed publication: %s" message
  | Error _ -> Alcotest.fail "released authoritative batch returned a state error"
;;

let pull_first_delete_conflict_proves_non_execution database =
  let behavior = "Pull-first delete conflict proves non-execution" in
  let mutation_id = T.mutation_uuid 306 in
  let mutation = Types.Delete_blocks { mutation_id; root = T.authoritative_block_uuid } in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh Pull-first delete already existed"
  in
  let submitted = submit_one database local behavior in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Codec.to_string
      ~mode:Codec.Verbose
      (Transit.Array
         [ Transit.Array
             [ Keyword "db/add"
             ; Array
                 [ Keyword "block/uuid"
                 ; Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
                 ]
             ; Keyword "block/updated-at"
             ; Int 1_704_067_200_457
             ]
         ])
    |> encoded
  in
  let cursor = server_cursor 1 in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
      ~through:cursor
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let preparation, crypto =
    Database.begin_authoritative database ~expected:(sync_view_token sync) batch
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "Pull-first conflict unexpectedly requested crypto";
  let committed =
    match Database.apply_authoritative database preparation ~decrypted:None with
    | Ok (Authoritative_applied commit) -> commit
    | Ok (Authoritative_deferred _) ->
      Alcotest.fail "first-cursor delete conflict was deferred"
    | Error (Authoritative_commit_persistence_failed message) ->
      Alcotest.failf "Pull-first persistence failed: %s" message
    | Error (Authoritative_commit_fatal_state message) ->
      Alcotest.failf "Pull-first publication failed: %s" message
    | Error _ -> Alcotest.fail "Pull-first authoritative commit returned a state error"
  in
  (match committed.terminal_receipts with
   | [ { receipt = Remote_won_receipt receipt
       ; transport_disposition = Retain_terminal_owner_until_response batch_id
       }
     ] ->
     T.require
       (Graph.Uuid.equal receipt.mutation_id mutation_id)
       "Remote_won receipt named the wrong mutation";
     T.require
       (receipt.reason = Proven_unexecuted)
       "Pull-first conflict used the wrong proof reason";
     T.require
       (Submission_batch_id.equal batch_id (submission_batch_id submitted))
       "terminal transport disposition named the wrong batch"
   | _ -> Alcotest.fail "Pull-first conflict omitted its retained terminal receipt");
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_blocks snapshot [ T.authoritative_block_uuid ] |> T.require_ok ~behavior
   with
   | [ Present_block { value; _ } ] ->
     T.require
       (Int64.equal value.block.updated_at_ms 1_704_067_200_457L)
       "remote winner was not visible after optimistic delete rollback"
   | _ -> Alcotest.fail "remote winner remained hidden after delete conflict");
  Database.release_snapshot snapshot;
  T.require
    (sync_view_submissions (Database.inspect_sync database |> T.require_ok ~behavior) = [])
    "proven-unexecuted delete remained retryable";
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let rejected, crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Reject_group
         { batch_id = submission_batch_id submitted
         ; resolution = Stale { through = cursor }
         })
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "late rejection unexpectedly requested crypto";
  let duplicate =
    Database.apply_outbox_transition database rejected ~encrypted:None
    |> T.require_ok ~behavior
  in
  T.require
    (duplicate.activity = Logically_inactive
     && duplicate.logical_change_summary = No_logical_change)
    "late rejection was not an idempotent terminal confirmation";
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let impossible_acceptance =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Accept_group
         { batch_id = submission_batch_id submitted
         ; barrier = { through = cursor; checksum = checksum "1111111111111111" }
         })
  in
  match impossible_acceptance with
  | Error (Outbox_transition_invalid _) -> ()
  | Error _ -> Alcotest.fail "late acceptance returned the wrong integrity error"
  | Ok _ -> Alcotest.fail "late acceptance contradicted proven non-execution"
;;

let stale_delete_resolves_to_no_change_after_equivalent_authoritative_delete database =
  let behavior = "Stale delete resolves after equivalent authoritative delete" in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 310; root = T.authoritative_block_uuid }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh delete fixture already existed"
  in
  let submitted = submit_one database local behavior in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let rejected, _crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Reject_group
         { batch_id = submission_batch_id submitted
         ; resolution = Stale { through = server_cursor 1 }
         })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database rejected ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    submitted
    |> submission_batch_wires
    |> List.hd
    |> submission_wire_protected_transaction
    |> Codec.of_string
    |> (function
     | Transit.Array operations ->
       Transit.Array
         (List.filter
            (function
              | Transit.Array (_ :: Transit.Keyword "db/current-tx" :: _) -> false
              | _ -> true)
            operations)
     | _ -> Alcotest.fail "frozen delete wire is not a transaction array")
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded
  in
  let cursor = server_cursor 1 in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
      ~through:cursor
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let authoritative, request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | authoritative, Some request -> authoritative, request
    | _ -> Alcotest.fail "equivalent protected delete omitted crypto request"
  in
  let plaintexts =
    Database.unprotection_ciphertexts request
    |> List.map (fun (id, ciphertext) ->
      ( id
      , fake_decrypted_plaintext
          ~message:"equivalent delete changed the protected envelope"
          ciphertext ))
  in
  let committed =
    match
      Database.apply_authoritative
        database
        authoritative
        ~decrypted:(Some (request, plaintexts))
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "equivalent delete was deferred"
  in
  (match committed.terminal_receipts with
   | [ { receipt = No_change_receipt { mutation_id; _ }; _ } ]
     when Graph.Uuid.equal mutation_id local.mutation_id -> ()
   | _ -> Alcotest.fail "equivalent authoritative delete omitted No_change receipt");
  let final_sync = Database.inspect_sync database |> T.require_ok ~behavior in
  T.require
    (sync_view_submissions final_sync = [])
    "resolved Stale delete remained in the active outbox";
  T.require
    (committed.logical_change_summary = No_logical_change)
    "equivalent delete published a logical change"
;;

let stale_delete_without_conflict_becomes_blocked_at_barrier database =
  let behavior = "Stale delete without conflict becomes blocked at barrier" in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 315; root = T.authoritative_block_uuid }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh Stale fixture already existed"
  in
  let submitted = submit_one database local behavior in
  let batch_id = submission_batch_id submitted in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let rejected, _ =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Reject_group { batch_id; resolution = Stale { through = server_cursor 1 } })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database rejected ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Codec.to_string
      ~mode:Codec.Verbose
      (Transit.Array
         [ Transit.Array
             [ Keyword "db/add"
             ; Keyword "db/current-tx"
             ; Keyword "logseq-overlay/unrelated"
             ; String "remote"
             ]
         ])
    |> encoded
  in
  let cursor = server_cursor 1 in
  let authoritative_batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:[ authoritative_transaction ~cursor ~transaction:wire ]
      ~through:cursor
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let preparation, _ =
    Database.begin_authoritative
      database
      ~expected:(sync_view_token sync)
      authoritative_batch
    |> T.require_ok ~behavior
  in
  let committed =
    match
      Database.apply_authoritative database preparation ~decrypted:None
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "Stale catch-up was unexpectedly deferred"
  in
  T.require
    (List.exists (Graph.Uuid.equal local.mutation_id) committed.blocked_ids)
    "Stale barrier did not report the blocked mutation";
  let expected =
    Database.write_precondition ~blocks:[] ~pages:[] ~scopes:[] |> T.require_ok ~behavior
  in
  (match Database.commit_local database ~expected mutation |> T.require_ok ~behavior with
   | Local_existing (Existing_blocked { reason = Stale_barrier; _ }) -> ()
   | Local_existing _ -> Alcotest.fail "Stale barrier restored the wrong outcome"
   | Local_committed _ -> Alcotest.fail "Stale barrier allowed the same mutation ID again");
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let duplicate, _ =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Reject_group { batch_id; resolution = Stale { through = cursor } })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database duplicate ~encrypted:None
  |> T.require_ok ~behavior
  |> fun commit ->
  T.require
    (commit.activity = Logically_inactive
     && commit.logical_change_summary = No_logical_change)
    "late Stale rejection was not idempotent"
;;

let accepted_member_terminalizes_at_its_authoritative_barrier_with
      ~behavior
      ~reorder_wire
      database
  =
  let mutation =
    Types.Save_block
      { mutation_id = T.mutation_uuid 320
      ; block = T.authoritative_block_uuid
      ; title = "Own accepted title"
      }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh accepted fixture already existed"
  in
  let submitted = submit_one database local behavior in
  let barrier = { through = server_cursor 1; checksum = checksum "1111111111111111" } in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let accepted, _crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Accept_group { batch_id = submission_batch_id submitted; barrier })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database accepted ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let wire =
    server_transaction ~mutation_id:local.mutation_id ~operation:"save-block" submitted
    |> reorder_wire
    |> encoded
  in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:
        [ authoritative_transaction ~cursor:(server_cursor 1) ~transaction:wire ]
      ~through:(server_cursor 1)
      ~checksum:(Some (checksum "1111111111111111"))
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let authoritative, request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | prepared, Some request -> prepared, request
    | _ -> Alcotest.fail "accepted protected title omitted crypto request"
  in
  let decrypted = decrypt_submitted_request request behavior in
  let committed =
    match
      Database.apply_authoritative database authoritative ~decrypted:(Some decrypted)
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "accepted authoritative batch deferred"
  in
  (match committed.terminal_receipts with
   | [ { receipt = Applied_receipt { mutation_id; _ }; _ } ]
     when Graph.Uuid.equal mutation_id local.mutation_id -> ()
   | _ -> Alcotest.fail "accepted member omitted its Applied receipt");
  T.require
    (committed.logical_change_summary = No_logical_change)
    "own authoritative incorporation changed the logical projection";
  let final_sync = Database.inspect_sync database |> T.require_ok ~behavior in
  T.require
    (sync_view_submissions final_sync = [])
    "incorporated accepted member remained in the active outbox"
;;

let accepted_member_terminalizes_at_its_authoritative_barrier database =
  accepted_member_terminalizes_at_its_authoritative_barrier_with
    ~behavior:"accepted member terminalizes at authoritative barrier"
    ~reorder_wire:Fun.id
    database
;;

let accepted_member_allows_reordered_normalized_datoms database =
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let reorder_wire transaction =
    match Codec.of_string transaction with
    | Transit.Array operations ->
      Codec.to_string ~mode:Codec.Verbose (Transit.Array (List.rev operations))
    | _ -> Alcotest.fail "server transaction was not a Transit array"
  in
  accepted_member_terminalizes_at_its_authoritative_barrier_with
    ~behavior:"accepted member allows reordered normalized datoms"
    ~reorder_wire
    database
;;

let accepted_member_rejects_wrong_payload database =
  let behavior = "accepted member rejects wrong payload" in
  let mutation =
    Types.Save_block
      { mutation_id = T.mutation_uuid 323
      ; block = T.authoritative_block_uuid
      ; title = "Wrong digest title"
      }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh wrong-digest fixture already existed"
  in
  let submitted = submit_one database local behavior in
  let barrier = { through = server_cursor 1; checksum = checksum "1111111111111111" } in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let accepted, _ =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Accept_group { batch_id = submission_batch_id submitted; barrier })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database accepted ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let envelope =
    Codec.to_string (Transit.Array [ Transit.Binary "iv"; Transit.Binary "wrong-digest" ])
  in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
              ]
          ; Transit.Keyword "block/title"
          ; Transit.String envelope
          ]
      ; Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
              ]
          ; Transit.Keyword "block/updated-at"
          ; Transit.Int 1_704_067_200_000
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded
  in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:
        [ authoritative_transaction ~cursor:(server_cursor 1) ~transaction:wire ]
      ~through:(server_cursor 1)
      ~checksum:(Some (checksum "1111111111111111"))
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let authoritative, request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | authoritative, Some request -> authoritative, request
    | _ -> Alcotest.fail "wrong-digest transaction omitted crypto request"
  in
  let plaintexts =
    match Database.unprotection_ciphertexts request with
    | [ (id, protected) ] ->
      T.require (String.equal protected envelope) "wrong-digest envelope changed";
      [ id, "Contradictory title" ]
    | _ -> Alcotest.fail "wrong-digest transaction returned the wrong crypto count"
  in
  match
    Database.apply_authoritative
      database
      authoritative
      ~decrypted:(Some (request, plaintexts))
  with
  | Error (Authoritative_integrity_failure _) -> ()
  | Error _ -> Alcotest.fail "wrong payload returned the wrong integrity error"
  | Ok _ -> Alcotest.fail "accepted transaction trusted a mismatched payload"
;;

let accepted_member_rejects_extra_touched_fact database =
  let behavior = "accepted member rejects extra touched fact" in
  let mutation =
    Types.Save_block
      { mutation_id = T.mutation_uuid 324
      ; block = T.authoritative_block_uuid
      ; title = "Exact footprint title"
      }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh touched-footprint fixture already existed"
  in
  let submitted = submit_one database local behavior in
  let barrier = { through = server_cursor 1; checksum = checksum "1111111111111111" } in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let accepted, _ =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Accept_group { batch_id = submission_batch_id submitted; barrier })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database accepted ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    submitted
    |> submission_batch_wires
    |> List.hd
    |> submission_wire_protected_transaction
    |> Codec.of_string
    |> (function
     | Transit.Array operations ->
       Transit.Array
         (operations
          @ [ Transit.Array
                [ Transit.Keyword "db/add"
                ; Transit.Array
                    [ Transit.Keyword "block/uuid"
                    ; Transit.Uuid (Graph.Uuid.to_string T.reference_source_uuid)
                    ]
                ; Transit.Keyword "block/order"
                ; Transit.String "tampered-order"
                ]
            ])
     | _ -> Alcotest.fail "submitted save wire is not a transaction array")
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded
  in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:
        [ authoritative_transaction ~cursor:(server_cursor 1) ~transaction:wire ]
      ~through:(server_cursor 1)
      ~checksum:(Some (checksum "1111111111111111"))
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let authoritative, request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | authoritative, Some request -> authoritative, request
    | _ -> Alcotest.fail "touched-footprint transaction omitted crypto request"
  in
  let plaintexts =
    Database.unprotection_ciphertexts request
    |> List.map (fun (id, ciphertext) ->
      ( id
      , fake_decrypted_plaintext ~message:"touched-footprint envelope changed" ciphertext
      ))
  in
  match
    Database.apply_authoritative
      database
      authoritative
      ~decrypted:(Some (request, plaintexts))
  with
  | Error (Authoritative_integrity_failure _) -> ()
  | Error _ -> Alcotest.fail "extra touched fact returned the wrong integrity error"
  | Ok _ -> Alcotest.fail "accepted transaction exceeded its frozen touched footprint"
;;

let accepted_member_uses_intermediate_barrier_root database =
  let behavior = "accepted member uses its intermediate barrier root" in
  let mutation =
    Types.Save_block
      { mutation_id = T.mutation_uuid 321
      ; block = T.authoritative_block_uuid
      ; title = "Own intermediate title"
      }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh accepted fixture already existed"
  in
  let submitted = submit_one database local behavior in
  let barrier = { through = server_cursor 1; checksum = checksum "3131313131313131" } in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let accepted, _ =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Accept_group { batch_id = submission_batch_id submitted; barrier })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database accepted ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let remote_title_wire title =
    Codec.to_string
      ~mode:Codec.Verbose
      (Transit.Array
         [ Transit.Array
             [ Transit.Keyword "db/add"
             ; Transit.Array
                 [ Transit.Keyword "block/uuid"
                 ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
                 ]
             ; Transit.Keyword "block/title"
             ; Transit.String title
             ]
         ])
    |> encoded
  in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:
        [ authoritative_transaction
            ~cursor:(server_cursor 1)
            ~transaction:
              (encoded
                 (server_transaction
                    ~mutation_id:local.mutation_id
                    ~operation:"save-block"
                    submitted))
        ; authoritative_transaction
            ~cursor:(server_cursor 2)
            ~transaction:(remote_title_wire "remote-envelope")
        ]
      ~through:(server_cursor 2)
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let preparation, request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | preparation, Some request -> preparation, request
    | _ -> Alcotest.fail "protected barrier fixture omitted crypto request"
  in
  let plaintexts =
    match Database.unprotection_ciphertexts request with
    | [ (first, own_ciphertext); (second, _) ] ->
      [ ( first
        , fake_decrypted_plaintext
            ~message:"intermediate own envelope changed"
            own_ciphertext )
      ; second, "Later remote title"
      ]
    | _ -> Alcotest.fail "barrier fixture returned the wrong crypto item count"
  in
  let committed =
    match
      Database.apply_authoritative
        database
        preparation
        ~decrypted:(Some (request, plaintexts))
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "accepted barrier fixture deferred"
  in
  (match committed.terminal_receipts with
   | [ { receipt = Applied_receipt { mutation_id; _ }; _ } ]
     when Graph.Uuid.equal mutation_id local.mutation_id -> ()
   | _ -> Alcotest.fail "intermediate barrier did not earn Applied receipt");
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_blocks snapshot [ T.authoritative_block_uuid ] |> T.require_ok ~behavior
   with
   | [ Present_block { value; _ } ] ->
     T.require
       (String.equal value.block.title "Later remote title")
       "later authoritative transaction was not preserved"
   | _ -> Alcotest.fail "accepted barrier target disappeared");
  Database.release_snapshot snapshot
;;

let covered_acceptance_uses_combined_group_requirements database =
  let behavior = "covered acceptance uses combined ordered group requirements" in
  let save ordinal title =
    let mutation =
      Types.Save_block
        { mutation_id = T.mutation_uuid ordinal
        ; block = T.authoritative_block_uuid
        ; title
        }
    in
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> mutation, commit
    | Local_existing _ -> Alcotest.fail "fresh grouped save already existed"
  in
  let first_mutation, first = save 322 "First grouped title" in
  let second_mutation, second = save 323 "Final grouped title" in
  let submit_preparation, request, _ =
    prepare_submit database [ first.mutation_id; second.mutation_id ] behavior
  in
  let submitted =
    Database.apply_outbox_transition
      database
      submit_preparation
      ~encrypted:(Some (protect request behavior))
    |> T.require_ok ~behavior
    |> fun commit -> Option.get commit.submission_batch
  in
  let wires = submission_batch_wires submitted in
  let group_checksum = checksum "4141414141414141" in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:
        (List.combine [ first.mutation_id; second.mutation_id ] wires
         |> List.mapi (fun index (mutation_id, wire) ->
           authoritative_transaction
             ~cursor:(server_cursor (index + 1))
             ~transaction:
               (encoded
                  (server_normalized_transaction
                     ~mutation_id
                     ~operation:"save-block"
                     (submission_wire_protected_transaction wire)))))
      ~through:(server_cursor 2)
      ~checksum:(Some group_checksum)
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let preparation, request =
    match
      Database.begin_authoritative database ~expected:(sync_view_token sync) batch
      |> T.require_ok ~behavior
    with
    | preparation, Some request -> preparation, request
    | _ -> Alcotest.fail "grouped authoritative title omitted crypto request"
  in
  let decrypted = decrypt_submitted_request request behavior in
  let authoritative_commit =
    match
      Database.apply_authoritative database preparation ~decrypted:(Some decrypted)
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "ordinary grouped Pull was deferred"
  in
  ignore authoritative_commit;
  let admission = Database.inspect_admission database |> T.require_ok ~behavior in
  T.require
    (admission.retained_origin_evidence_bytes > 0)
    "covered submission did not retain bounded origin evidence";
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let acceptance, _ =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Accept_group
         { batch_id = submission_batch_id submitted
         ; barrier = { through = server_cursor 2; checksum = group_checksum }
         })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database acceptance ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let assert_applied mutation =
    match
      Database.commit_local database ~expected:(T.empty_precondition ~behavior) mutation
      |> T.require_ok ~behavior
    with
    | Local_existing (Existing_applied _) -> ()
    | Local_existing _ -> Alcotest.fail "group member terminalized incorrectly"
    | Local_committed _ -> Alcotest.fail "group member lost its terminal receipt"
  in
  assert_applied first_mutation;
  assert_applied second_mutation
;;

let accepted_delete_rejects_missing_own_incorporation database =
  let behavior = "accepted delete rejects missing own incorporation" in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 330; root = T.authoritative_block_uuid }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh mismatch fixture already existed"
  in
  let submitted = submit_one database local behavior in
  let barrier = { through = server_cursor 1; checksum = checksum "2222222222222222" } in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let accepted, _crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Accept_group { batch_id = submission_batch_id submitted; barrier })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database accepted ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
              ]
          ; Transit.Keyword "block/updated-at"
          ; Transit.Int 1_704_067_200_789
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded
  in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:
        [ authoritative_transaction ~cursor:(server_cursor 1) ~transaction:wire ]
      ~through:(server_cursor 1)
      ~checksum:(Some (checksum "2222222222222222"))
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let authoritative, _crypto =
    Database.begin_authoritative database ~expected:(sync_view_token sync) batch
    |> T.require_ok ~behavior
  in
  (match Database.apply_authoritative database authoritative ~decrypted:None with
   | Error (Authoritative_integrity_failure _) -> ()
   | Error _ -> Alcotest.fail "missing own delete returned the wrong integrity error"
   | Ok _ -> Alcotest.fail "accepted delete tolerated missing own incorporation");
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_blocks snapshot [ T.authoritative_block_uuid ] |> T.require_ok ~behavior
   with
   | [ Missing_block _ ] -> ()
   | _ -> Alcotest.fail "failed integrity preparation changed the logical delete");
  Database.release_snapshot snapshot;
  let final_sync = Database.inspect_sync database |> T.require_ok ~behavior in
  match sync_view_submissions final_sync with
  | [ descriptor ] ->
    (match descriptor.state with
     | Accepted_pending_authoritative _ -> ()
     | _ -> Alcotest.fail "integrity failure changed accepted delete state")
  | _ -> Alcotest.fail "integrity failure changed accepted delete cardinality"
;;

let accepted_delete_allows_server_normalized_order database =
  let behavior = "accepted delete allows server normalized order" in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 331; root = T.authoritative_block_uuid }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh normalized delete fixture already existed"
  in
  let submitted = submit_one database local behavior in
  let barrier = { through = server_cursor 1; checksum = checksum "2323232323232323" } in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let accepted, _crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Accept_group { batch_id = submission_batch_id submitted; barrier })
    |> T.require_ok ~behavior
  in
  Database.apply_outbox_transition database accepted ~encrypted:None
  |> T.require_ok ~behavior
  |> ignore;
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    let transaction =
      server_transaction
        ~mutation_id:local.mutation_id
        ~operation:"delete-blocks"
        submitted
    in
    match Codec.of_string transaction with
    | Transit.Array operations ->
      let is_updated_at = function
        | Transit.Array
            [ Transit.Keyword ("db/add" | "db/retract")
            ; _
            ; Transit.Keyword "block/updated-at"
            ; _
            ; _
            ] -> true
        | _ -> false
      in
      let updated_at, rest = List.partition is_updated_at operations in
      Codec.to_string ~mode:Codec.Verbose (Transit.Array (updated_at @ rest)) |> encoded
    | _ -> Alcotest.fail "submitted delete was not a Transit array"
  in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:
        [ authoritative_transaction ~cursor:(server_cursor 1) ~transaction:wire ]
      ~through:(server_cursor 1)
      ~checksum:(Some barrier.checksum)
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let authoritative, crypto =
    Database.begin_authoritative database ~expected:(sync_view_token sync) batch
    |> T.require_ok ~behavior
  in
  let decrypted =
    Option.map (fun request -> decrypt_submitted_request request behavior) crypto
  in
  let committed =
    match Database.apply_authoritative database authoritative ~decrypted with
    | Ok (Authoritative_applied commit) -> commit
    | Ok (Authoritative_deferred _) ->
      Alcotest.fail "accepted normalized delete was deferred"
    | Error _ -> Alcotest.fail "accepted normalized delete failed integrity validation"
  in
  (match committed.terminal_receipts with
   | [ { receipt = Applied_receipt { mutation_id; _ }; _ } ]
     when Graph.Uuid.equal mutation_id local.mutation_id -> ()
   | _ -> Alcotest.fail "normalized delete omitted its applied receipt");
  let final_sync = Database.inspect_sync database |> T.require_ok ~behavior in
  T.require
    (sync_view_submissions final_sync = [])
    "normalized delete remained in the active outbox"
;;

let queued_delete_yields_to_remote_change_before_submission database =
  let behavior = "queued delete yields to remote change before submission" in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 340; root = T.authoritative_block_uuid }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:
          (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh remote-won fixture already existed"
  in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
              ]
          ; Transit.Keyword "block/updated-at"
          ; Transit.Int 1_704_067_200_999
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded
  in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:
        [ authoritative_transaction ~cursor:(server_cursor 1) ~transaction:wire ]
      ~through:(server_cursor 1)
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let authoritative, _crypto =
    Database.begin_authoritative database ~expected:(sync_view_token sync) batch
    |> T.require_ok ~behavior
  in
  let committed =
    match
      Database.apply_authoritative database authoritative ~decrypted:None
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "queued delete conflict was deferred"
  in
  (match committed.terminal_receipts with
   | [ { receipt = Remote_won_receipt receipt
       ; transport_disposition = No_transport_owner
       }
     ]
     when Graph.Uuid.equal receipt.mutation_id local.mutation_id
          && receipt.reason = Before_submission -> ()
   | _ -> Alcotest.fail "queued delete conflict omitted Remote_won receipt");
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_blocks snapshot [ T.authoritative_block_uuid ] |> T.require_ok ~behavior
   with
   | [ Present_block { value; _ } ] ->
     T.require
       (value.block.updated_at_ms = 1_704_067_200_999L)
       "Remote_won did not reveal the remote block"
   | _ -> Alcotest.fail "queued delete continued to hide remote state");
  Database.release_snapshot snapshot;
  let final_sync = Database.inspect_sync database |> T.require_ok ~behavior in
  T.require
    (sync_view_submissions final_sync = [])
    "Remote_won delete remained in the active outbox";
  match
    Database.commit_local database ~expected:(T.empty_precondition ~behavior) mutation
    |> T.require_ok ~behavior
  with
  | Local_existing (Existing_remote_won receipt) when receipt.reason = Before_submission
    -> ()
  | _ -> Alcotest.fail "same-ID lookup lost Remote_won history"
;;

let queued_default_property_delete_detects_new_holder database =
  let behavior = "queued default-property delete detects a new holder" in
  let mutation =
    Types.Delete_blocks { mutation_id = T.mutation_uuid 341; root = T.default_value_uuid }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:(T.delete_precondition database ~block:T.default_value_uuid ~behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh default-property delete already existed"
  in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let holder = Transit.String "remote-default-property-holder" in
  let lookup uuid =
    Transit.Array
      [ Transit.Keyword "block/uuid"; Transit.Uuid (Graph.Uuid.to_string uuid) ]
  in
  let add attribute value =
    Transit.Array [ Transit.Keyword "db/add"; holder; Transit.Keyword attribute; value ]
  in
  let wire =
    Transit.Array
      [ add "block/uuid" (Transit.Uuid "44444444-4444-4444-8444-444444444441")
      ; add "block/parent" (lookup T.page_uuid)
      ; add "block/page" (lookup T.page_uuid)
      ; add "block/order" (Transit.String "a00000006")
      ; add "test.property/default" (lookup T.default_value_uuid)
      ]
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded
  in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4_096
      ~transactions:
        [ authoritative_transaction ~cursor:(server_cursor 1) ~transaction:wire ]
      ~through:(server_cursor 1)
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let preparation, crypto =
    Database.begin_authoritative database ~expected:(sync_view_token sync) batch
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "default-property holder change requested crypto";
  let committed =
    match
      Database.apply_authoritative database preparation ~decrypted:None
      |> T.require_ok ~behavior
    with
    | Authoritative_applied commit -> commit
    | Authoritative_deferred _ ->
      Alcotest.fail "queued default-property delete was deferred"
  in
  match committed.terminal_receipts with
  | [ { receipt = Remote_won_receipt receipt; transport_disposition = No_transport_owner }
    ]
    when Graph.Uuid.equal receipt.mutation_id local.mutation_id
         && List.mem
              (Auxiliary_write_footprint_changed Default_property_holder)
              (delete_conflict_kinds receipt.conflicts) -> ()
  | _ -> Alcotest.fail "new default-property holder did not terminalize queued delete"
;;

let submitted_save_retains_required_block_shadow database =
  let behavior = "submitted save retains its required block shadow" in
  let mutation =
    Types.Save_block
      { mutation_id = T.mutation_uuid 342
      ; block = T.authoritative_block_uuid
      ; title = "Frozen submitted title"
      }
  in
  let local =
    match
      T.commit_mutation
        database
        ~expected:(block_precondition database T.authoritative_block_uuid behavior)
        mutation
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh shadow fixture mutation already existed"
  in
  ignore (submit_one database local behavior);
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/retractEntity"
          ; Transit.Array
              [ Transit.Keyword "block/uuid"
              ; Transit.Uuid (Graph.Uuid.to_string T.authoritative_block_uuid)
              ]
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
  in
  ignore (commit_plain_authoritative database ~cursor:(server_cursor 1) wire behavior);
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       (match
          Database.get_blocks snapshot [ T.authoritative_block_uuid ]
          |> T.require_ok ~behavior
        with
        | [ Present_block { value; _ } ] ->
          T.require
            (String.equal value.block.title "Frozen submitted title")
            "submitted title disappeared with its authoritative entity"
        | _ -> Alcotest.fail "submitted block shadow was not visible");
       match
         Database.get_structure
           snapshot
           (Children { parent = T.page_uuid; limit = 200; cursor = None })
         |> T.require_ok ~behavior
       with
       | Children_result { items; _ } ->
         T.require
           (List.exists
              (fun (item : child_member) ->
                 Graph.Uuid.equal item.block.block.uuid T.authoritative_block_uuid)
              items)
           "submitted block shadow lost its required parent membership"
       | Page_tree_result _ -> Alcotest.fail "children query returned a page tree")
;;

let queued_delete_detects_new_remote_descendant database =
  let behavior = "queued delete detects a new remote descendant" in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 341; root = T.authoritative_block_uuid }
  in
  ignore
    (T.commit_mutation
       database
       ~expected:
         (T.delete_precondition database ~block:T.authoritative_block_uuid ~behavior)
       mutation
       ~behavior);
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let entity = Transit.String "remote-descendant" in
  let lookup uuid =
    Transit.Array
      [ Transit.Keyword "block/uuid"; Transit.Uuid (Graph.Uuid.to_string uuid) ]
  in
  let wire =
    Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; entity
          ; Transit.Keyword "block/uuid"
          ; Transit.Uuid (Graph.Uuid.to_string T.missing_block_uuid)
          ]
      ; Transit.Array
          [ Transit.Keyword "db/add"
          ; entity
          ; Transit.Keyword "block/parent"
          ; lookup T.authoritative_block_uuid
          ]
      ; Transit.Array
          [ Transit.Keyword "db/add"
          ; entity
          ; Transit.Keyword "block/page"
          ; lookup T.page_uuid
          ]
      ; Transit.Array
          [ Transit.Keyword "db/add"
          ; entity
          ; Transit.Keyword "block/order"
          ; Transit.String "a00000001.00000000"
          ]
      ]
    |> Codec.to_string ~mode:Codec.Verbose
  in
  let committed =
    commit_plain_authoritative database ~cursor:(server_cursor 1) wire behavior
  in
  match committed.terminal_receipts with
  | [ { receipt = Remote_won_receipt receipt; _ } ] ->
    T.require
      (List.mem Descendant_closure_changed (delete_conflict_kinds receipt.conflicts))
      "new descendant conflict omitted Descendant_closure_changed"
  | _ -> Alcotest.fail "new descendant did not resolve queued delete as Remote_won"
;;

let submit_group database commits behavior =
  let ids = List.map (fun (commit : local_commit) -> commit.mutation_id) commits in
  let prepared, request, _ = prepare_submit database ids behavior in
  let protected_values = protect request behavior in
  Database.apply_outbox_transition database prepared ~encrypted:(Some protected_values)
  |> T.require_ok ~behavior
  |> fun commit -> Option.get commit.submission_batch
;;

let partial_rejection_preserves_prefix_and_retries_independent_suffix database =
  let behavior = "partial rejection preserves prefix and retries independent suffix" in
  let first_uuid = T.uuid "55555555-5555-4555-8555-555555555551" in
  let second_uuid = T.uuid "55555555-5555-4555-8555-555555555552" in
  let third_uuid = T.uuid "55555555-5555-4555-8555-555555555553" in
  let first = commit_insert database ~ordinal:280 ~uuid:first_uuid behavior in
  let second = commit_insert database ~ordinal:281 ~uuid:second_uuid behavior in
  let third = commit_insert database ~ordinal:282 ~uuid:third_uuid behavior in
  let original = submit_group database [ first; second; third ] behavior in
  let original_wires = submission_batch_wires original in
  let third_bytes =
    original_wires
    |> List.find (fun wire ->
      Graph.Uuid.equal (submission_wire_mutation_id wire) third.mutation_id)
    |> submission_wire_protected_transaction
  in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let partition =
    { accepted_prefix = [ first.mutation_id ]
    ; failed_member = Some second.mutation_id
    ; unexecuted_suffix = [ third.mutation_id ]
    ; acceptance_barrier =
        Some { through = server_cursor 1; checksum = checksum "prefix" }
    ; missing_uuids = []
    ; diagnostics = [ "deterministic partial rejection" ]
    }
  in
  let prepared, crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Reject_group
         { batch_id = submission_batch_id original
         ; resolution = Definitive { reason = Invalid_request; partition }
         })
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "partial rejection requested crypto";
  let rejected =
    Database.apply_outbox_transition database prepared ~encrypted:None
    |> T.require_ok ~behavior
  in
  let retry =
    match rejected.submission_batch with
    | Some retry -> retry
    | None -> Alcotest.fail "partial rejection omitted independent suffix retry batch"
  in
  T.require
    (not
       (Submission_batch_id.equal
          (submission_batch_id original)
          (submission_batch_id retry)))
    "partial rejection reused the original batch ID";
  (match submission_batch_wires retry with
   | [ wire ] ->
     T.require
       (Graph.Uuid.equal (submission_wire_mutation_id wire) third.mutation_id)
       "retry batch contains the wrong suffix member";
     T.require
       (String.equal (submission_wire_protected_transaction wire) third_bytes)
       "partial rejection changed frozen suffix bytes"
   | _ -> Alcotest.fail "retry batch cardinality does not match independent suffix");
  let state_of id =
    Database.inspect_sync database
    |> T.require_ok ~behavior
    |> sync_view_submissions
    |> List.find (fun descriptor -> Graph.Uuid.equal descriptor.mutation_id id)
    |> fun descriptor -> descriptor.state
  in
  (match state_of first.mutation_id with
   | Accepted_pending_authoritative batch
     when Submission_batch_id.equal batch (submission_batch_id original) -> ()
   | _ -> Alcotest.fail "accepted prefix did not retain the original batch");
  T.require (state_of second.mutation_id = Blocked) "failed member did not become Blocked";
  (match state_of third.mutation_id with
   | Submitted batch when Submission_batch_id.equal batch (submission_batch_id retry) ->
     ()
   | _ -> Alcotest.fail "independent suffix did not enter its retry group");
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_blocks snapshot [ first_uuid; second_uuid; third_uuid ]
     |> T.require_ok ~behavior
   with
   | [ Present_block _; Missing_block _; Present_block _ ] -> ()
   | _ ->
     Alcotest.fail "partial rejection exposed an intermediate or incorrect projection");
  Database.release_snapshot snapshot
;;

let invalid_partial_rejection_partition_fails_before_durability database =
  let behavior = "invalid partial rejection partition fails before durability" in
  let first =
    commit_insert
      database
      ~ordinal:290
      ~uuid:(T.uuid "55555555-5555-4555-8555-555555555561")
      behavior
  in
  let second =
    commit_insert
      database
      ~ordinal:291
      ~uuid:(T.uuid "55555555-5555-4555-8555-555555555562")
      behavior
  in
  let original = submit_group database [ first; second ] behavior in
  let before = Database.inspect_sync database |> T.require_ok ~behavior in
  let invalid =
    { accepted_prefix = [ second.mutation_id ]
    ; failed_member = Some first.mutation_id
    ; unexecuted_suffix = []
    ; acceptance_barrier =
        Some { through = server_cursor 1; checksum = checksum "invalid" }
    ; missing_uuids = []
    ; diagnostics = []
    }
  in
  (match
     Database.begin_outbox_transition
       database
       ~expected:(sync_view_token before)
       (Reject_group
          { batch_id = submission_batch_id original
          ; resolution = Definitive { reason = Invalid_request; partition = invalid }
          })
   with
   | Error (Outbox_transition_invalid _) -> ()
   | Error _ -> Alcotest.fail "invalid partition returned the wrong error"
   | Ok _ -> Alcotest.fail "non-prefix rejection partition was prepared");
  let after = Database.inspect_sync database |> T.require_ok ~behavior in
  T.require
    (sync_token_equal (sync_view_token before) (sync_view_token after))
    "invalid partition changed durable sync state"
;;

let partial_rejection_blocks_suffix_dependent_on_failed_insert database =
  let behavior = "partial rejection blocks suffix dependent on failed insert" in
  let inserted = commit_insert database ~ordinal:300 ~uuid:T.block_uuid behavior in
  let edited =
    match
      T.commit_mutation
        database
        ~expected:(block_precondition database T.block_uuid behavior)
        (T.save_block ~ordinal:301 ~title:"Depends on insert" ())
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh dependent mutation already existed"
  in
  let original = submit_group database [ inserted; edited ] behavior in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let partition =
    { accepted_prefix = []
    ; failed_member = Some inserted.mutation_id
    ; unexecuted_suffix = [ edited.mutation_id ]
    ; acceptance_barrier = None
    ; missing_uuids = [ T.block_uuid ]
    ; diagnostics = [ "suffix target was introduced by failed member" ]
    }
  in
  let prepared, crypto =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Reject_group
         { batch_id = submission_batch_id original
         ; resolution = Definitive { reason = Missing_dependencies; partition }
         })
    |> T.require_ok ~behavior
  in
  T.require (Option.is_none crypto) "dependent rejection requested crypto";
  let committed =
    Database.apply_outbox_transition database prepared ~encrypted:None
    |> T.require_ok ~behavior
  in
  T.require
    (Option.is_none committed.submission_batch)
    "dependent suffix was incorrectly returned as a retry batch";
  let states =
    Database.inspect_sync database
    |> T.require_ok ~behavior
    |> sync_view_submissions
    |> List.map (fun descriptor -> descriptor.state)
  in
  T.require
    (states = [ Blocked; Blocked ])
    "failed member and dependent suffix did not become atomically Blocked";
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  (match Database.get_blocks snapshot [ T.block_uuid ] |> T.require_ok ~behavior with
   | [ Missing_block _ ] -> ()
   | _ -> Alcotest.fail "dependent suffix remained in the logical projection");
  Database.release_snapshot snapshot
;;

let reopened_submission_does_not_reuse_terminal_batch () =
  let behavior = "reopened submission does not reuse a terminal batch" in
  T.with_temp_directory "overlay-batch-reopen-" (fun support ->
    ignore (T.seed_mirror support);
    let dependencies = T.dependencies ~behavior in
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let open_database () =
          let inspection =
            Database.inspect_mirror
              ~application_support_directory:support
              ~graph_id:T.graph_uuid
            |> T.require_ok ~behavior
          in
          Database.open_ ~sw dependencies inspection ~graph_name:"oracle-graph"
          |> T.require_ok ~behavior
        in
        let first = open_database () in
        let old_id = ref None in
        accepted_member_terminalizes_at_its_authoritative_barrier_with
          ~behavior
          ~reorder_wire:(fun wire ->
            let view = Database.inspect_sync first |> T.require_ok ~behavior in
            (match sync_view_submissions view with
             | [ { state = Accepted_pending_authoritative id; _ } ] -> old_id := Some id
             | _ -> Alcotest.fail "first batch lost its acceptance owner");
            wire)
          first;
        Database.close first |> T.require_ok ~behavior;
        let second = open_database () in
        Fun.protect
          ~finally:(fun () -> ignore (Database.close second))
          (fun () ->
             let local =
               T.commit_mutation
                 second
                 ~expected:
                   (T.delete_precondition
                      second
                      ~block:T.authoritative_block_uuid
                      ~behavior)
                 (Save_block
                    { mutation_id = T.mutation_uuid 321
                    ; block = T.authoritative_block_uuid
                    ; title = "After reopen"
                    })
                 ~behavior
             in
             let local =
               match local with
               | Local_committed commit -> commit
               | Local_existing _ -> Alcotest.fail "new edit already existed"
             in
             let batch = submit_one second local behavior in
             let old_id = Option.get !old_id in
             T.require
               (not (Submission_batch_id.equal old_id (submission_batch_id batch)))
               "reopen reused a batch ID retained by a terminal receipt";
             let view = Database.inspect_sync second |> T.require_ok ~behavior in
             let late, _ =
               Database.begin_outbox_transition
                 second
                 ~expected:(sync_view_token view)
                 (Accept_group
                    { batch_id = old_id
                    ; barrier =
                        { through = server_cursor 1
                        ; checksum = checksum "1111111111111111"
                        }
                    })
               |> T.require_ok ~behavior
             in
             ignore
               (Database.apply_outbox_transition second late ~encrypted:None
                |> T.require_ok ~behavior);
             let after = Database.inspect_sync second |> T.require_ok ~behavior in
             T.require
               (sync_view_submissions view = sync_view_submissions after)
               "old terminal acknowledgement changed the reopened submission"))))
;;

let pure_cases =
  [ Alcotest.test_case
      "revision codecs reject unknown versions"
      `Quick
      revision_codecs_reject_unknown_versions
  ; Alcotest.test_case
      "encoded transaction enforces byte bound"
      `Quick
      encoded_transaction_enforces_byte_bound
  ; Alcotest.test_case
      "opaque sync values use validated constructors"
      `Quick
      opaque_sync_values_have_validated_constructors
  ; Alcotest.test_case
      "authoritative cursors are strictly ordered"
      `Quick
      authoritative_batch_requires_strict_cursor_order
  ; Alcotest.test_case
      "authoritative through cursor matches final member"
      `Quick
      authoritative_batch_requires_through_match
  ]
;;

let database_cases =
  [ Alcotest.test_case
      "reopen never reuses a terminal batch identity"
      `Quick
      reopened_submission_does_not_reuse_terminal_batch
  ; T.database_case
      "empty sync view has checkpoint and no submissions"
      empty_sync_view_has_checkpoint_and_no_submissions
  ; T.database_case
      "empty submission group fails atomically"
      empty_submission_group_fails_before_durability
  ; T.database_case
      "outbox crypto results are validated before application"
      outbox_crypto_results_are_validated_before_application
  ; T.database_case "queued local commit is queryable" queued_local_commit_is_queryable
  ; T.database_case
      "local submission uses normalized transaction"
      local_submission_uses_normalized_transaction
  ; T.database_case
      "local submission uses server-compatible fractional indices"
      local_submission_uses_server_compatible_fractional_indices
  ; T.database_case
      "submit is atomic and retry is byte-identical"
      (atomic_submit_and_retry_are_byte_identical ~advance:false)
  ; T.database_case
      "retry preserves its frozen baseline after an authoritative change"
      (atomic_submit_and_retry_are_byte_identical ~advance:true)
  ; T.database_case
      "submission rejects an unfrozen queued dependency"
      submission_rejects_unfrozen_queued_dependency
  ; T.database_case
      "submission rejects reordered members"
      submission_rejects_reordered_members
  ; T.database_case
      "stale sync token changes nothing"
      stale_sync_token_fails_without_state_change
  ; T.database_case
      "delete submission is singleton-only"
      delete_submission_requires_singleton
  ; T.database_case
      "delete submission freezes complete wire footprint"
      delete_submission_freezes_complete_wire_footprint
  ; T.database_case
      "admission charges plaintext and protected bytes"
      admission_charges_plaintext_and_protected_bytes
  ; Alcotest.test_case
      "dependency shadow is admitted at first submission"
      `Quick
      dependency_shadow_is_admitted_at_first_submission
  ; T.database_case "acceptance is transport-only" acceptance_is_transport_only
  ; T.database_case
      "acceptance barrier cannot precede submission interval"
      acceptance_barrier_cannot_precede_submission_interval
  ; T.database_case
      "matching state does not replace origin evidence"
      matching_state_does_not_replace_origin_evidence
  ; T.database_case
      "definitive rejection rolls back once"
      definitive_rejection_rolls_back_once
  ; T.database_case
      "authoritative batch updates logical snapshot"
      authoritative_batch_updates_the_logical_snapshot
  ; T.database_case
      "authoritative rebase replans queued ordinary mutation"
      authoritative_rebase_replans_queued_ordinary_mutation
  ; T.database_case
      "authoritative rebase terminalizes queued no-change"
      authoritative_rebase_terminalizes_queued_no_change
  ; T.database_case
      "authoritative rebase blocks transitive queued dependency"
      authoritative_rebase_blocks_transitive_queued_dependency
  ; T.database_case
      "authoritative crypto is correlated and applied"
      authoritative_crypto_is_correlated_and_applied
  ; T.database_case
      "submitted delete defers authoritative batch until transport outcome"
      submitted_delete_defers_authoritative_batch_until_transport_outcome
  ; T.database_case
      "Pull-first delete conflict proves non-execution"
      pull_first_delete_conflict_proves_non_execution
  ; T.database_case
      "Stale delete resolves after equivalent authoritative delete"
      stale_delete_resolves_to_no_change_after_equivalent_authoritative_delete
  ; T.database_case
      "Stale delete without conflict becomes blocked at barrier"
      stale_delete_without_conflict_becomes_blocked_at_barrier
  ; T.database_case
      "accepted member terminalizes at authoritative barrier"
      accepted_member_terminalizes_at_its_authoritative_barrier
  ; T.database_case
      "accepted member allows reordered normalized datoms"
      accepted_member_allows_reordered_normalized_datoms
  ; T.database_case
      "accepted member rejects wrong payload digest"
      accepted_member_rejects_wrong_payload
  ; T.database_case
      "accepted member rejects extra touched fact"
      accepted_member_rejects_extra_touched_fact
  ; T.database_case
      "accepted member uses intermediate barrier root"
      accepted_member_uses_intermediate_barrier_root
  ; T.database_case
      "covered acceptance uses combined group requirements"
      covered_acceptance_uses_combined_group_requirements
  ; T.database_case
      "accepted delete rejects missing own incorporation"
      accepted_delete_rejects_missing_own_incorporation
  ; T.database_case
      "accepted delete allows server normalized order"
      accepted_delete_allows_server_normalized_order
  ; T.database_case
      "queued delete yields to remote change before submission"
      queued_delete_yields_to_remote_change_before_submission
  ; T.database_case
      "queued delete detects a new remote descendant"
      queued_delete_detects_new_remote_descendant
  ; T.database_case
      "queued default-property delete detects a new holder"
      queued_default_property_delete_detects_new_holder
  ; T.database_case
      "submitted save retains its dependency shadow"
      submitted_save_retains_required_block_shadow
  ; T.database_case
      "partial rejection preserves prefix and retries independent suffix"
      partial_rejection_preserves_prefix_and_retries_independent_suffix
  ; T.database_case
      "invalid partial rejection partition fails before durability"
      invalid_partial_rejection_partition_fails_before_durability
  ; T.database_case
      "partial rejection blocks suffix dependent on failed insert"
      partial_rejection_blocks_suffix_dependent_on_failed_insert
  ]
;;

let () =
  Alcotest.run
    "logseq_overlay_db sync"
    [ "validated wire inputs", pure_cases; "durable sync view", database_cases ]
;;
