module Graph = Logseq_db_types.Graph_types
module Storage = Logseq_db_storage.Logseq_sqlite_storage
open Types
open Authoritative_store
open Overlay_effect
module Uuid_map = Map.Make (String)

type effect_footprint = footprint

type dependencies =
  { epoch_ms : unit -> int64
  ; monotonic_ns : unit -> int64
  ; limits : Types.capability_limits
  }

type durable_mirror_location =
  { database_path : string
  ; graph_id : Graph.Uuid.t
  }

type mirror_inspection =
  { location : durable_mirror_location
  ; presence : Types.mirror_presence
  }

type prepared_snapshot_activation =
  { snapshot_dependencies : dependencies
  ; snapshot_inspection : mirror_inspection
  ; snapshot_cursor : Types.server_cursor
  ; snapshot_staging : Mirror.staged
  ; mutable snapshot_remaining_protected_datoms : Datascript.datom Seq.t
  ; mutable snapshot_current_protected_datoms : Datascript.datom list
  ; mutable snapshot_next_crypto_index : int
  ; mutable snapshot_crypto_revision : int
  ; mutable snapshot_awaiting_crypto : bool
  ; mutable snapshot_crypto_complete : bool
  ; mutable snapshot_persisted :
      (Logseq_db_types.Sync_checkpoint.t * Types.checksum option) option
  ; mutable snapshot_committed : bool
  ; mutable snapshot_canceled : bool
  }

type write_precondition =
  { blocks : (Graph.block_uuid * Types.block_state_revision) list
  ; pages : (Graph.page_uuid * Types.page_state_revision) list
  ; scopes : (Types.structure_revision_scope * Types.scope_revision) list
  }

type outbox_record = Persistence_outbox_v14.t =
  { mutation_id : Graph.Uuid.t
  ; fingerprint : string
  ; mutation : Types.local_mutation
  ; normalized_transaction : string
  ; mutable dependency_shadows : dependency_shadows
  ; effect_footprint : footprint
  ; delete_artifacts : delete_artifacts option
  ; intent_time_ms : int64
  ; planned_tx : int
  ; sequence : int
  ; mutable transport_state : Types.transport_state
  ; mutable protected_transaction : string option
  ; mutable attempt_count : int
  ; mutable blocked_prior_state : Types.transport_state option
  ; mutable blocked_reason : Types.block_reason option
  ; mutable same_id_retry_eligible : bool
  ; mutable acceptance_barrier : Types.acceptance_barrier option
  ; mutable submission_t_before : Types.server_cursor option
  ; mutable submission_ordinal : int option
  ; mutable submission_count : int option
  ; mutable observed_origin_cursor : Types.server_cursor option
  ; mutable stale_earliest_conflict_cursor : Types.server_cursor option
  ; mutable stale_conflicts : Types.delete_conflict_kind list
  }

type lifecycle =
  | Active
  | Unlistened

type logical_view = Logical_snapshot.t

type receipt_entry = Persistence_receipt_v1.entry =
  | Commit_receipt of Types.local_commit
  | Discarded_receipt of Types.blocked_discard_commit * Types.block_reason
  | Remote_won_entry of Types.remote_won_receipt

type terminal_batch_receipt = Persistence_receipt_v1.terminal_batch_receipt =
  { terminal_batch_id : Types.submission_batch_id
  ; terminal_outcome : terminal_batch_outcome
  }

and terminal_batch_outcome = Persistence_receipt_v1.terminal_batch_outcome =
  | Terminal_accepted of Types.acceptance_barrier
  | Terminal_proven_unexecuted of
      { mutation_id : Graph.Uuid.t
      ; fingerprint : string
      }

type dispatch_item =
  | Dispatch_change of Types.projection_change * unit Eio.Promise.u
  | Stop_dispatch

type t =
  { lock : Eio.Mutex.t
  ; notification_lock : Eio.Mutex.t
  ; sw : Eio.Switch.t
  ; dispatch_stream : dispatch_item Eio.Stream.t
  ; dispatch_slots : Eio.Semaphore.t
  ; dependencies : dependencies
  ; database_path : string
  ; graph_uuid : Graph.Uuid.t
  ; graph_name : string
  ; schema : Graph.schema_version
  ; admission_facts : Graph.admission_fact list
  ; storage_session : Logseq_db_storage.Storage_session.t
  ; ownership : Ownership.t
  ; release_slot : t option ref
  ; mutable closed : bool
  ; generation : Types.generation
  ; mutable projection : int
  ; authoritative_connection : Datascript.conn
  ; authoritative_listener : string
  ; authoritative_reports : Datascript.tx_report list ref
  ; mutable receipts : (Graph.Uuid.t * string * receipt_entry) list
  ; mutable outbox : outbox_record list
  ; mutable queryable_outbox : outbox_record list
  ; mutable queryable_block_effects : outbox_record list Uuid_map.t
  ; mutable queryable_page_effects : outbox_record list Uuid_map.t
  ; mutable queryable_children_effects : outbox_record list Uuid_map.t
  ; mutable sync_revision : int
  ; mutable checkpoint : int
  ; mutable checkpoint_metadata : Logseq_db_types.Sync_checkpoint.t
  ; mutable subscriptions : subscription list
  ; mutable snapshots : snapshot list
  }

and snapshot =
  { owner : t
  ; version : Types.snapshot_version
  ; mutable authoritative_database : Datascript.db option
  ; mutable outbox : outbox_record list option
  ; mutable block_effects : outbox_record list Uuid_map.t option
  ; mutable page_effects : outbox_record list Uuid_map.t option
  ; mutable children_effects : outbox_record list Uuid_map.t option
  ; mutable released : bool
  ; mutable active_reads : int
  ; mutable drain_waiters : unit Eio.Promise.u list
  }

and subscription =
  { owner : t
  ; events : Types.projection_change option Eio.Stream.t
  ; mutable lifecycle : lifecycle
  ; mutable notify : (Types.projection_change -> unit) option
  ; mutable callback_running : bool
  ; mutable callback_waiters : unit Eio.Promise.u list
  }

type protection_request =
  { protection_owner : t
  ; protection_revision : int
  ; protection_items : (Types.crypto_item_id * string) list
  ; mutable protection_consumed : bool
  }

type unprotection_owner =
  | Authoritative_unprotection of t * int
  | Snapshot_unprotection of prepared_snapshot_activation * int

type unprotection_request =
  { unprotection_owner : unprotection_owner
  ; unprotection_limit_bytes : int
  ; unprotection_items : (Types.crypto_item_id * string) list
  ; mutable unprotection_consumed : bool
  }

type outbox_plan =
  | Submit_plan of outbox_record list
  | Retry_plan of Types.submission_batch_id * outbox_record list
  | Accept_plan of Types.submission_batch_id * Types.acceptance_barrier
  | Reject_plan of Types.submission_batch_id * Types.rejection_resolution
  | Duplicate_plan

type prepared_outbox_transition =
  { transition_owner : t
  ; transition_revision : int
  ; transition : Types.outbox_transition
  ; plan : outbox_plan
  ; protection_request : protection_request option
  ; mutable transition_consumed : bool
  }

type authoritative_preparation =
  { authoritative_owner : t
  ; authoritative_revision : int
  ; authoritative_batch : Types.authoritative_batch
  ; authoritative_wires : string list
  ; authoritative_unprotection : unprotection_request option
  ; mutable authoritative_state : authoritative_state
  }

and authoritative_state =
  | Authoritative_awaiting
  | Authoritative_ready of authoritative_candidate
  | Authoritative_deferred_state
  | Authoritative_consumed

and authoritative_candidate =
  { authoritative_preparation : authoritative_preparation
  ; authoritative_decrypted_input :
      (unprotection_request * (Types.crypto_item_id * string) list) option
  ; authoritative_transactions : Datascript.tx_op list list
  ; authoritative_expected_tx_data : Datascript.datom list list
  ; authoritative_roots_after : Datascript.db list
  ; validated_origins : (Graph.Uuid.t * Types.server_cursor) list
  ; submitted_remote_won :
      (Graph.Uuid.t
      * Types.submission_batch_id
      * Types.server_cursor
      * Types.delete_conflict_kind list)
        list
  ; stale_updates :
      (Graph.Uuid.t * Types.server_cursor option * Types.delete_conflict_kind list) list
  ; stale_remote_won :
      (Graph.Uuid.t
      * Types.submission_batch_id
      * Types.server_cursor
      * Types.server_cursor
      * Types.delete_conflict_kind list)
        list
  ; stale_no_change : (Graph.Uuid.t * Types.submission_batch_id) list
  ; stale_blocked : (Graph.Uuid.t * Types.submission_batch_id) list
  ; authoritative_db_after : Datascript.db
  }

type authoritative_application =
  | Authoritative_applied of Types.authoritative_commit
  | Authoritative_deferred of Types.authoritative_defer

let current_callback_subscription : subscription Eio.Fiber.key = Eio.Fiber.create_key ()
let authoritative_database database = Datascript.db database.authoritative_connection

let token of_string value =
  match of_string value with
  | Ok value -> value
  | Error message -> invalid_arg message
;;

let startup_generation = token Types.Generation.of_string "generation:v1:startup"
let generation_sequence = Atomic.make 0

let fresh_generation monotonic_ns =
  let sequence = Atomic.fetch_and_add generation_sequence 1 + 1 in
  token
    Types.Generation.of_string
    (Printf.sprintf "generation:v1:%Ld:%d" (monotonic_ns ()) sequence)
;;

let projection_revision value =
  token Types.Projection_revision.of_string (Printf.sprintf "projection:v1:%d" value)
;;

let mirror_generation value =
  token Types.Mirror_generation.of_string ("mirror-generation:v1:" ^ value)
;;

let mirror_generation_for_path path =
  let stat = Unix.stat path in
  mirror_generation
    (Digestif.SHA256.digest_string
       (Printf.sprintf "%s:%d:%d" path stat.st_dev stat.st_ino)
     |> Digestif.SHA256.to_hex)
;;

let absent_mirror_generation path =
  mirror_generation
    (Digestif.SHA256.digest_string ("absent:" ^ path) |> Digestif.SHA256.to_hex)
;;

let server_cursor value =
  token Types.Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" value)
;;

let dependencies ~epoch_ms ~monotonic_ns ~limits =
  let values =
    [ "response_budget_bytes", limits.response_budget_bytes
    ; "outbox_max_records", limits.outbox_max_records
    ; "outbox_max_bytes", limits.outbox_max_bytes
    ; "change_max_items", limits.change_max_items
    ; "change_max_bytes", limits.change_max_bytes
    ; "dispatcher_capacity", limits.dispatcher_capacity
    ; "wire_batch_max_bytes", limits.wire_batch_max_bytes
    ]
  in
  match List.find_opt (fun (_, value) -> value <= 0) values with
  | Some (name, _) -> Error (Types.Non_positive_limit name)
  | None when limits.wire_batch_max_bytes > limits.outbox_max_bytes ->
    Error (Types.Inconsistent_limits "wire batch exceeds outbox byte limit")
  | None -> Ok { epoch_ms; monotonic_ns; limits }
;;

let durable_mirror_location ~application_support_directory ~graph_id =
  if String.trim application_support_directory = ""
  then Error Types.Invalid_application_support_directory
  else
    Ok
      { database_path =
          Filename.concat
            application_support_directory
            (Filename.concat
               "logseq-db-worker/synced-graphs"
               (Filename.concat (Graph.Uuid.to_string graph_id) "db.sqlite"))
      ; graph_id
      }
;;

let is_regular_single_link path =
  try
    let stat = Unix.lstat path in
    stat.st_kind = Unix.S_REG && stat.st_nlink = 1
  with
  | Unix.Unix_error _ -> false
;;

let inspect_durable_mirror (location : durable_mirror_location) =
  if not (Sys.file_exists location.database_path)
  then
    Ok
      { location
      ; presence =
          Types.Absent { generation = absent_mirror_generation location.database_path }
      }
  else (
    match Logseq_db_storage.Sync_checkpoint_store.read_path location.database_path with
    | Error message -> Error (Types.Mirror_inspection_failed message)
    | Ok checkpoint ->
      if not (Graph.Uuid.equal checkpoint.graph_id location.graph_id)
      then Error (Types.Mirror_inspection_failed "checkpoint graph UUID mismatch")
      else
        Ok
          { location
          ; presence =
              Types.Available
                { generation = mirror_generation_for_path location.database_path
                ; graph_uuid = checkpoint.graph_id
                ; checkpoint = server_cursor checkpoint.applied_server_t
                ; checksum =
                    Types.Checksum.of_string ("checksum:v1:" ^ checkpoint.checksum)
                    |> Result.to_option
                }
          })
;;

let inspect_mirror ~application_support_directory ~graph_id =
  Result.bind
    (durable_mirror_location ~application_support_directory ~graph_id)
    inspect_durable_mirror
;;

let mirror_presence inspection = inspection.presence

let rec ensure_directory path =
  if Sys.file_exists path
  then (
    try (Unix.lstat path).st_kind = Unix.S_DIR with
    | Unix.Unix_error _ -> false)
  else (
    let parent = Filename.dirname path in
    (not (String.equal parent path))
    && ensure_directory parent
    &&
    try
      Unix.mkdir path 0o700;
      true
    with
    | Unix.Unix_error _ -> false)
;;

let checksum_value checksum =
  let value = Types.Checksum.to_string checksum in
  match String.split_on_char ':' value with
  | [ "checksum"; "v1"; digest ] -> digest
  | _ -> value
;;

let cursor_value cursor =
  let value = Types.Server_cursor.to_string cursor in
  match String.split_on_char ':' value with
  | [ "server-cursor"; "v1"; ordinal ] -> int_of_string ordinal
  | _ -> invalid_arg "invalid server cursor"
;;

let protected_snapshot_datoms database =
  if not (Authoritative_checksum.graph_e2ee database)
  then Seq.empty
  else
    Datascript.datoms database Datascript.Eavt ()
    |> Seq.filter (fun datom ->
      (String.equal datom.Datascript.a "block/title" || String.equal datom.a "block/name")
      &&
      match datom.v with
      | Datascript.String _ -> true
      | _ -> false)
;;

let prepare_snapshot_activation
      dependencies
      inspection
      ~path
      ~applied_server_cursor
      ~expected_checksum
      ~expected_rows
  =
  if Filename.is_relative path || not (is_regular_single_link path)
  then Error Types.Invalid_snapshot_path
  else if expected_rows < 0
  then Error Types.Invalid_expected_rows
  else (
    match inspection.presence with
    | Types.Available _ -> Error Types.Mirror_exists
    | Types.Absent _ ->
      let active_directory = Filename.dirname inspection.location.database_path in
      if Sys.file_exists active_directory
      then Error Types.Stale_snapshot_inspection
      else (
        let root = Filename.dirname active_directory in
        if not (ensure_directory root)
        then Error Types.Snapshot_state_error
        else (
          match
            Mirror.stage
              ~root
              ~graph_id:inspection.location.graph_id
              ~snapshot_path:path
              ~expected_rows
          with
          | Error message -> Error (Types.Snapshot_parse_error message)
          | Ok staging ->
            let database = Mirror.database staging in
            let digest =
              Authoritative_checksum.recompute
                ~e2ee:(Authoritative_checksum.graph_e2ee database)
                database
            in
            (match expected_checksum with
             | Some expected when not (String.equal (checksum_value expected) digest) ->
               Mirror.cancel staging;
               Error (Types.Snapshot_parse_error "snapshot checksum mismatch")
             | None | Some _ ->
               Ok
                 { snapshot_dependencies = dependencies
                 ; snapshot_inspection = inspection
                 ; snapshot_cursor = applied_server_cursor
                 ; snapshot_staging = staging
                 ; snapshot_remaining_protected_datoms =
                     protected_snapshot_datoms database
                 ; snapshot_current_protected_datoms = []
                 ; snapshot_next_crypto_index = 0
                 ; snapshot_crypto_revision = 0
                 ; snapshot_awaiting_crypto = false
                 ; snapshot_crypto_complete = false
                 ; snapshot_persisted = None
                 ; snapshot_committed = false
                 ; snapshot_canceled = false
                 }))))
;;

let snapshot_crypto_id preparation index =
  token
    Types.Crypto_item_id.of_string
    (Printf.sprintf
       "crypto-item:v1:snapshot:%d:%d"
       preparation.snapshot_crypto_revision
       index)
;;

let next_snapshot_unprotection_batch preparation =
  if preparation.snapshot_canceled
  then Error Types.Snapshot_preparation_canceled
  else if preparation.snapshot_committed || Option.is_some preparation.snapshot_persisted
  then Error Types.Snapshot_state_error
  else if preparation.snapshot_awaiting_crypto
  then Error Types.Snapshot_state_error
  else (
    let maximum = preparation.snapshot_dependencies.limits.wire_batch_max_bytes in
    let rec take bytes reversed sequence =
      match sequence () with
      | Seq.Nil -> Ok (List.rev reversed, Seq.empty)
      | Seq.Cons (datom, rest) ->
        let value =
          match datom.Datascript.v with
          | Datascript.String value -> value
          | _ -> assert false
        in
        let next = bytes + String.length value in
        if next > maximum
        then
          if reversed = []
          then Error Types.Snapshot_limit_exceeded
          else Ok (List.rev reversed, fun () -> Seq.Cons (datom, rest))
        else take next (datom :: reversed) rest
    in
    Result.bind
      (take 0 [] preparation.snapshot_remaining_protected_datoms)
      (fun (datoms, remaining) ->
         preparation.snapshot_remaining_protected_datoms <- remaining;
         match datoms with
         | [] ->
           preparation.snapshot_crypto_complete <- true;
           Ok None
         | _ ->
           let items =
             List.mapi
               (fun offset datom ->
                  let value =
                    match datom.Datascript.v with
                    | Datascript.String value -> value
                    | _ -> assert false
                  in
                  let index = preparation.snapshot_next_crypto_index + offset in
                  snapshot_crypto_id preparation index, value)
               datoms
           in
           preparation.snapshot_current_protected_datoms <- datoms;
           preparation.snapshot_awaiting_crypto <- true;
           Ok
             (Some
                { unprotection_owner =
                    Snapshot_unprotection
                      (preparation, preparation.snapshot_crypto_revision)
                ; unprotection_limit_bytes = maximum
                ; unprotection_items = items
                ; unprotection_consumed = false
                })))
;;

let supply_snapshot_unprotection_batch preparation ~request ~plaintexts =
  if preparation.snapshot_canceled
  then Error Types.Snapshot_preparation_canceled
  else if preparation.snapshot_committed || Option.is_some preparation.snapshot_persisted
  then Error Types.Snapshot_state_error
  else (
    match request.unprotection_owner with
    | Snapshot_unprotection (owner, revision)
      when owner == preparation
           && revision = preparation.snapshot_crypto_revision
           && preparation.snapshot_awaiting_crypto
           && not request.unprotection_consumed ->
      (match
         Crypto_bridge.validate_results
           ~maximum_value_bytes:request.unprotection_limit_bytes
           ~expected:request.unprotection_items
           ~actual:plaintexts
       with
       | Error error -> Error (Types.Snapshot_crypto_result_error error)
       | Ok () ->
         let replacements =
           List.combine
             preparation.snapshot_current_protected_datoms
             (List.map snd plaintexts)
         in
         (match Mirror.stage_plaintexts preparation.snapshot_staging replacements with
          | Error message ->
            request.unprotection_consumed <- true;
            preparation.snapshot_current_protected_datoms <- [];
            preparation.snapshot_remaining_protected_datoms <- Seq.empty;
            preparation.snapshot_awaiting_crypto <- false;
            preparation.snapshot_canceled <- true;
            Mirror.cancel preparation.snapshot_staging;
            Error (Types.Snapshot_crypto_error message)
          | Ok () ->
            request.unprotection_consumed <- true;
            preparation.snapshot_next_crypto_index
            <- preparation.snapshot_next_crypto_index + List.length plaintexts;
            preparation.snapshot_crypto_revision
            <- preparation.snapshot_crypto_revision + 1;
            preparation.snapshot_current_protected_datoms <- [];
            preparation.snapshot_awaiting_crypto <- false;
            Ok ()))
    | Authoritative_unprotection _ | Snapshot_unprotection _ ->
      Error (Types.Snapshot_crypto_result_error Types.Crypto_result_stale))
;;

let persist_snapshot_activation preparation =
  if preparation.snapshot_canceled
  then Error Types.Snapshot_preparation_canceled
  else if preparation.snapshot_committed
  then Error Types.Snapshot_commit_consumed
  else (
    match preparation.snapshot_persisted with
    | Some persisted -> Ok persisted
    | None ->
      if preparation.snapshot_awaiting_crypto
      then Error Types.Snapshot_state_error
      else if not preparation.snapshot_crypto_complete
      then Error (Types.Snapshot_crypto_error "snapshot crypto input is incomplete")
      else (
        try
          let staged_database = Mirror.database preparation.snapshot_staging in
          let database =
            (if Authoritative_checksum.graph_e2ee staged_database
             then Mirror.apply_staged_plaintexts preparation.snapshot_staging
             else Ok staged_database)
            |> Result.map_error (fun message -> Types.Snapshot_parse_error message)
          in
          Result.bind database (fun database ->
            let digest =
              Authoritative_checksum.recompute
                ~e2ee:(Authoritative_checksum.graph_e2ee database)
                database
            in
            let metadata =
              Logseq_db_types.Sync_checkpoint.create
                ~graph_id:preparation.snapshot_inspection.location.graph_id
                ~schema:(Mirror.schema preparation.snapshot_staging)
                ~applied_server_t:(cursor_value preparation.snapshot_cursor)
                ~checksum:digest
              |> Result.map_error (fun _message -> Types.Snapshot_state_error)
            in
            Result.bind metadata (fun metadata ->
              match Mirror.persist preparation.snapshot_staging database metadata with
              | Error message -> Error (Types.Snapshot_commit_persistence_failed message)
              | Ok () ->
                let persisted =
                  ( metadata
                  , Types.Checksum.of_string ("checksum:v1:" ^ digest) |> Result.to_option
                  )
                in
                preparation.snapshot_persisted <- Some persisted;
                Ok persisted))
        with
        | exn -> Error (Types.Snapshot_parse_error (Printexc.to_string exn))))
;;

let commit_snapshot_activation preparation =
  if preparation.snapshot_canceled
  then Error Types.Snapshot_preparation_canceled
  else if preparation.snapshot_committed
  then Error Types.Snapshot_commit_consumed
  else
    Result.bind (persist_snapshot_activation preparation) (fun (metadata, checksum) ->
      let active =
        Filename.dirname preparation.snapshot_inspection.location.database_path
      in
      if Sys.file_exists active
      then Error Types.Snapshot_commit_stale
      else (
        try
          match Mirror.activate preparation.snapshot_staging ~active_directory:active with
          | Error message -> Error (Types.Snapshot_commit_persistence_failed message)
          | Ok () ->
            preparation.snapshot_committed <- true;
            let generation =
              mirror_generation_for_path
                preparation.snapshot_inspection.location.database_path
            in
            let inspection =
              { location = preparation.snapshot_inspection.location
              ; presence =
                  Types.Available
                    { generation
                    ; graph_uuid = metadata.graph_id
                    ; checkpoint = preparation.snapshot_cursor
                    ; checksum
                    }
              }
            in
            Ok inspection
        with
        | exn -> Error (Types.Snapshot_commit_persistence_failed (Printexc.to_string exn))))
;;

let cancel_snapshot_activation preparation =
  if (not preparation.snapshot_committed) && not preparation.snapshot_canceled
  then (
    preparation.snapshot_canceled <- true;
    preparation.snapshot_current_protected_datoms <- [];
    preparation.snapshot_remaining_protected_datoms <- Seq.empty;
    preparation.snapshot_awaiting_crypto <- false;
    Mirror.cancel preparation.snapshot_staging)
;;

let rec remove_mirror_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_mirror_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let delete_mirror inspection =
  let path = inspection.location.database_path in
  match inspection.presence with
  | Types.Absent _ -> Error Types.Mirror_delete_stale
  | Available { generation = expected; _ } ->
    (match inspect_durable_mirror inspection.location with
     | Error _ | Ok { presence = Absent _; _ } -> Error Types.Mirror_delete_stale
     | Ok { presence = Available { generation = current; _ }; _ }
       when not (Types.Mirror_generation.equal expected current) ->
       Error Types.Mirror_delete_stale
     | Ok { presence = Available _; _ } ->
       let graph_directory = Filename.dirname path in
       (match Ownership.acquire ~graph_directory with
        | Error Ownership.Already_owned -> Error Types.Mirror_delete_busy
        | Error (Unavailable message) -> Error (Types.Mirror_delete_failed message)
        | Ok ownership ->
          (try
             remove_mirror_tree graph_directory;
             ignore (Ownership.release ownership);
             Ok
               { Types.graph_uuid = Some inspection.location.graph_id
               ; previous_generation = expected
               ; absent_generation = absent_mirror_generation path
               }
           with
           | exn ->
             ignore (Ownership.release ownership);
             Error (Types.Mirror_delete_failed (Printexc.to_string exn)))))
;;

let collect_garbage inspection =
  match inspection.presence with
  | Types.Absent _ -> Error Types.Garbage_collection_stale
  | Available { generation = expected; _ } ->
    (match inspect_durable_mirror inspection.location with
     | Error _ | Ok { presence = Absent _; _ } -> Error Types.Garbage_collection_stale
     | Ok { presence = Available { generation = current; _ }; _ }
       when not (Types.Mirror_generation.equal expected current) ->
       Error Types.Garbage_collection_stale
     | Ok { presence = Available _; _ } ->
       let graph_directory = Filename.dirname inspection.location.database_path in
       (match Ownership.acquire ~graph_directory with
        | Error Ownership.Already_owned -> Error Types.Garbage_collection_busy
        | Error (Unavailable message) -> Error (Types.Garbage_collection_failed message)
        | Ok ownership ->
          let sqlite =
            Sqlite3.db_open ~mode:`NO_CREATE inspection.location.database_path
          in
          Fun.protect
            ~finally:(fun () ->
              ignore (Sqlite3.db_close sqlite);
              ignore (Ownership.release ownership))
            (fun () ->
               match
                 Result.bind
                   (Logseq_db_storage.Mutation_receipt_store.initialize_database sqlite)
                   (fun () ->
                      Logseq_db_storage.Mutation_receipt_store.read_database sqlite)
               with
               | Error message -> Error (Types.Garbage_collection_failed message)
               | Ok receipts ->
                 let retained_terminal_batch_receipts =
                   List.fold_left
                     (fun count (_, source) ->
                        try
                          match Yojson.Safe.from_string source with
                          | `Assoc fields
                            when List.assoc_opt "receiptType" fields
                                 = Some (`String "acceptedBatch") -> count + 1
                          | _ -> count
                        with
                        | Yojson.Json_error _ -> count)
                     0
                     receipts
                 in
                 Ok
                   { Types.mirror_generation = expected
                   ; reclaimed_bytes = 0L
                   ; retained_mutation_receipts =
                       List.length receipts - retained_terminal_batch_receipts
                   ; retained_terminal_batch_receipts
                   })))
;;

let page_kind_of_datoms database datoms =
  let built_in =
    Option.bind (one_in_datoms datoms "logseq.property/built-in?") bool_of_value
    |> Option.value ~default:false
  in
  if built_in
  then Graph.Built_in_page
  else (
    match Option.bind (one_in_datoms datoms "block/journal-day") int_of_value with
    | Some journal_day -> Graph.Journal_page { journal_day }
    | None ->
      let tag_idents =
        referenced_entities_in_datoms datoms "block/tags"
        |> List.filter_map (fun entity ->
          Option.bind (one database entity "db/ident") ident_of_value)
      in
      if List.mem "logseq.class/Property" tag_idents
      then Graph.Property_page
      else if List.mem "logseq.class/Tag" tag_idents
      then Graph.Class_page
      else (
        let hidden =
          Option.bind (one_in_datoms datoms "logseq.property/hide?") bool_of_value
          |> Option.value ~default:false
        in
        if hidden then Graph.Hidden_page else Graph.Ordinary_page))
;;

let tagged_uuids_of_datoms database datoms =
  referenced_entities_in_datoms datoms "block/tags"
  |> List.filter_map (fun entity ->
    Option.bind (one database entity "block/uuid") uuid_of_value)
  |> List.sort_uniq Graph.Uuid.compare
;;

let property_type_of_name = function
  | "default" -> Graph.Default
  | "number" -> Number
  | "date" -> Date
  | "datetime" -> Datetime
  | "checkbox" -> Checkbox
  | "url" -> Url
  | "node" -> Node
  | "asset" -> Asset
  | "keyword" -> Keyword
  | "map" -> Map
  | "collection" -> Collection
  | "any" -> Any
  | "entity" -> Entity
  | "class" -> Class
  | "page" -> Page
  | "property" -> Property
  | "string" -> String
  | "json" -> Json
  | "raw-number" -> Raw_number
  | _ -> Default
;;

let property_type database entity =
  match Option.bind (one database entity "logseq.property/type") ident_of_value with
  | Some name -> property_type_of_name name
  | None -> Graph.Default
;;

let property_cardinality database entity ident =
  match Option.bind (one database entity "db/cardinality") ident_of_value with
  | Some "db.cardinality/many" -> Graph.Many
  | Some "db.cardinality/one" -> One
  | Some _ | None ->
    (match List.assoc_opt ident (Datascript.schema database) with
     | Some attribute when attribute.Datascript.cardinality = Datascript.Many ->
       Graph.Many
     | Some _ | None -> One)
;;

let bool_attribute database entity attribute =
  Option.bind (one database entity attribute) bool_of_value |> Option.value ~default:false
;;

let rec all_options = function
  | [] -> Some []
  | None :: _ -> None
  | Some value :: rest -> Option.map (fun rest -> value :: rest) (all_options rest)
;;

let rec internal_property_value database = function
  | Datascript.Nil -> Some Graph.Internal_null
  | Bool value -> Some (Internal_bool value)
  | Int value -> Some (Internal_number (string_of_int value))
  | Float value -> Some (Internal_number (string_of_float value))
  | String value | Symbol value -> Some (Internal_string value)
  | Keyword value -> Some (Internal_keyword value)
  | Uuid value ->
    Graph.Uuid.of_string value
    |> Result.to_option
    |> Option.map (fun uuid -> Graph.Internal_uuid uuid)
  | Ref entity ->
    Option.bind (one database entity "block/uuid") uuid_of_value
    |> Option.map (fun uuid -> Graph.Internal_uuid uuid)
  | List values | Vector values | Set values ->
    values
    |> List.map (internal_property_value database)
    |> all_options
    |> Option.map (fun values -> Graph.Internal_list values)
  | Map entries ->
    entries
    |> List.map (fun (key, value) ->
      Option.bind (internal_property_value database key) (fun key ->
        Option.map (fun value -> key, value) (internal_property_value database value)))
    |> all_options
    |> Option.map (fun entries -> Graph.Internal_map entries)
  | Instant value -> Some (Graph.Internal_number (string_of_int value))
  | Regex value -> Some (Graph.Internal_string value)
  | Tuple values ->
    values
    |> List.map (Option.value ~default:Datascript.Nil)
    |> fun values -> internal_property_value database (Datascript.Vector values)
  | TxRef | Ref_to _ -> None
;;

let ident_or_uuid database entity =
  match Option.bind (one database entity "db/ident") ident_of_value with
  | Some ident -> Some ident
  | None ->
    Option.bind (one database entity "block/uuid") uuid_of_value
    |> Option.map Graph.Uuid.to_string
;;

let property_value database property_type value =
  let uuid_of_ref entity = Option.bind (one database entity "block/uuid") uuid_of_value in
  match property_type, value with
  | Graph.Default, Datascript.String value -> Some (Graph.Default_value value)
  | Url, String value -> Some (Url_value value)
  | String, String value -> Some (String_value value)
  | Json, String value -> Some (Json_value value)
  | Number, String value -> Some (Number_value value)
  | Raw_number, String value -> Some (Raw_number_value value)
  | Number, Int value -> Some (Number_value (string_of_int value))
  | Number, Float value -> Some (Number_value (string_of_float value))
  | Raw_number, Int value -> Some (Raw_number_value (string_of_int value))
  | Raw_number, Float value -> Some (Raw_number_value (string_of_float value))
  | Date, Int journal_day -> Some (Date_value { journal_day })
  | Datetime, Int unix_ms -> Some (Datetime_value { unix_ms = Int64.of_int unix_ms })
  | Checkbox, Bool value -> Some (Checkbox_value value)
  | Keyword, Keyword value -> Some (Keyword_value value)
  | Node, Ref entity ->
    Option.map (fun uuid -> Graph.Node_value uuid) (uuid_of_ref entity)
  | Asset, Ref entity ->
    Option.map (fun uuid -> Graph.Asset_value uuid) (uuid_of_ref entity)
  | Entity, Ref entity ->
    Option.map (fun uuid -> Graph.Entity_value uuid) (uuid_of_ref entity)
  | Class, Ref entity ->
    Option.map (fun uuid -> Graph.Class_value uuid) (uuid_of_ref entity)
  | Page, Ref entity ->
    Option.map (fun uuid -> Graph.Page_value uuid) (uuid_of_ref entity)
  | Property, Ref entity ->
    Option.map (fun ident -> Graph.Property_value ident) (ident_or_uuid database entity)
  | Map, value ->
    (match internal_property_value database value with
     | Some (Graph.Internal_map entries) -> Some (Graph.Map_value entries)
     | Some _ | None -> None)
  | Collection, value ->
    (match internal_property_value database value with
     | Some (Graph.Internal_list values) -> Some (Graph.Collection_value values)
     | Some value -> Some (Graph.Collection_value [ value ])
     | None -> None)
  | Any, value ->
    Option.map
      (fun value -> Graph.Any_value value)
      (internal_property_value database value)
  | Default, Ref entity ->
    Option.map (fun value -> Graph.Default_value value) (ident_or_uuid database entity)
  | _, value ->
    Option.map
      (fun value -> Graph.Any_value value)
      (internal_property_value database value)
;;

let property_definition_for_entity database property_class ident property_entity =
  if entity_has_ref database property_entity "block/tags" property_class
  then (
    match
      ( Option.bind (one database property_entity "block/uuid") uuid_of_value
      , Option.bind (one database property_entity "block/title") string_of_value )
    with
    | Some uuid, Some title ->
      let property_type = property_type database property_entity in
      Some
        Graph.
          { ident
          ; uuid
          ; title
          ; schema =
              { property_type
              ; cardinality = property_cardinality database property_entity ident
              ; hidden = bool_attribute database property_entity "logseq.property/hide?"
              ; public = bool_attribute database property_entity "logseq.property/public?"
              }
          ; values = []
          ; values_truncated = false
          }
    | _ -> None)
  else None
;;

let property_definition_with_class database property_class ident =
  Option.bind
    (entity_of_ident database ident)
    (property_definition_for_entity database property_class ident)
;;

let property_summary_from_definition database (definition : Graph.property_summary) values
  =
  let values =
    List.filter_map (property_value database definition.Graph.schema.property_type) values
  in
  let maximum_values = 256 in
  { definition with
    Graph.values = List.filteri (fun index _ -> index < maximum_values) values
  ; values_truncated = List.length values > maximum_values
  }
;;

let property_summary_with_class database property_class ident values =
  Option.map
    (fun definition -> property_summary_from_definition database definition values)
    (property_definition_with_class database property_class ident)
;;

let property_summary database ident values =
  Option.bind (entity_of_ident database "logseq.class/Property") (fun property_class ->
    property_summary_with_class database property_class ident values)
;;

let property_summaries_of_datoms_with_class database property_class datoms =
  match property_class with
  | None -> []
  | Some property_class ->
    datoms
    |> List.map (fun (datom : Datascript.datom) -> datom.a)
    |> List.sort_uniq String.compare
    |> List.filter_map (fun ident ->
      property_summary_with_class
        database
        property_class
        ident
        (values_in_datoms datoms ident))
    |> List.sort (fun (left : Graph.property_summary) right ->
      String.compare left.ident right.ident)
;;

type hydration_cache =
  { uuids : (int, Graph.Uuid.t option) Hashtbl.t
  ; page_titles : (int, string) Hashtbl.t
  ; property_class : int option
  ; property_definitions : (string, Graph.property_summary option) Hashtbl.t
  ; ident_entities : (string, int) Hashtbl.t
  }

let hydration_cache database =
  let ident_entities = Hashtbl.create 64 in
  Datascript.datoms database Datascript.Aevt ~a:"db/ident" ()
  |> Seq.iter (fun (datom : Datascript.datom) ->
    match ident_of_value datom.v with
    | Some ident -> Hashtbl.replace ident_entities ident datom.e
    | None -> ());
  { uuids = Hashtbl.create 64
  ; page_titles = Hashtbl.create 8
  ; property_class = Hashtbl.find_opt ident_entities "logseq.class/Property"
  ; property_definitions = Hashtbl.create 16
  ; ident_entities
  }
;;

let property_summary_with_cache database cache ident values =
  match cache.property_class with
  | None -> None
  | Some property_class ->
    let definition =
      match Hashtbl.find_opt cache.property_definitions ident with
      | Some definition -> definition
      | None ->
        let definition =
          Option.bind
            (Hashtbl.find_opt cache.ident_entities ident)
            (property_definition_for_entity database property_class ident)
        in
        Hashtbl.add cache.property_definitions ident definition;
        definition
    in
    Option.map
      (fun definition -> property_summary_from_definition database definition values)
      definition
;;

let property_summaries_of_datoms_with_cache database cache datoms =
  datoms
  |> List.map (fun (datom : Datascript.datom) -> datom.a)
  |> List.sort_uniq String.compare
  |> List.filter_map (fun ident ->
    property_summary_with_cache database cache ident (values_in_datoms datoms ident))
  |> List.sort (fun (left : Graph.property_summary) right ->
    String.compare left.ident right.ident)
;;

let rec insert_property_summary (property : Graph.property_summary) = function
  | [] -> [ property ]
  | (head : Graph.property_summary) :: _ as properties
    when String.compare property.ident head.ident <= 0 -> property :: properties
  | head :: rest -> head :: insert_property_summary property rest
;;

let set_property_values ?cache database ident values properties =
  let existing =
    List.find_opt
      (fun (property : Graph.property_summary) -> String.equal property.ident ident)
      properties
  in
  match values with
  | [] ->
    List.filter
      (fun (property : Graph.property_summary) -> not (String.equal property.ident ident))
      properties
  | _ ->
    (match existing with
     | Some definition ->
       let replacement = property_summary_from_definition database definition values in
       List.map
         (fun (property : Graph.property_summary) ->
            if String.equal property.ident ident then replacement else property)
         properties
     | None ->
       (match cache with
        | Some cache -> property_summary_with_cache database cache ident values
        | None -> property_summary database ident values)
       |> Option.fold ~none:properties ~some:(fun property ->
         insert_property_summary property properties))
;;

let property_value_of_uuid property_type uuid =
  match property_type with
  | Graph.Node -> Graph.Node_value uuid
  | Asset -> Asset_value uuid
  | Entity -> Entity_value uuid
  | Class -> Class_value uuid
  | Page -> Page_value uuid
  | Default -> Default_value (Graph.Uuid.to_string uuid)
  | Any -> Any_value (Internal_uuid uuid)
  | Property -> Property_value (Graph.Uuid.to_string uuid)
  | Collection -> Collection_value [ Internal_uuid uuid ]
  | Number | Date | Datetime | Checkbox | Url | Keyword | Map | String | Json | Raw_number
    -> Any_value (Internal_uuid uuid)
;;

let set_uuid_property_values ?cache database ident uuids properties =
  let existing =
    List.find_opt
      (fun (property : Graph.property_summary) -> String.equal property.ident ident)
      properties
  in
  match uuids with
  | [] ->
    List.filter
      (fun (property : Graph.property_summary) -> not (String.equal property.ident ident))
      properties
  | _ ->
    let definition =
      match existing with
      | Some definition -> Some definition
      | None ->
        (match cache with
         | Some cache -> property_summary_with_cache database cache ident []
         | None -> property_summary database ident [])
    in
    (match definition with
     | None -> properties
     | Some definition ->
       let property =
         Graph.
           { definition with
             values =
               List.map (property_value_of_uuid definition.schema.property_type) uuids
           }
       in
       (match existing with
        | Some _ ->
          List.map
            (fun (current : Graph.property_summary) ->
               if String.equal current.ident ident then property else current)
            properties
        | None -> insert_property_summary property properties))
;;

let set_block_field_properties
      ?cache
      database
      (block : Graph.block)
      ~title
      ~updated_at_ms
      ~refs
  =
  block.Graph.properties
  |> set_property_values ?cache database "block/title" [ Datascript.String title ]
  |> set_property_values
       ?cache
       database
       "block/updated-at"
       [ Datascript.Int (Int64.to_int updated_at_ms) ]
  |> set_uuid_property_values ?cache database "block/refs" refs
;;

let page_record_of_entity_with_class database property_class entity =
  let datoms = entity_datoms database entity in
  match
    ( Option.bind (one_in_datoms datoms "block/uuid") uuid_of_value
    , Option.bind (one_in_datoms datoms "block/name") string_of_value
    , Option.bind (one_in_datoms datoms "block/title") string_of_value )
  with
  | Some uuid, Some name, Some title ->
    let created_at_ms =
      Option.bind (one_in_datoms datoms "block/created-at") int_of_value
      |> Option.value ~default:0
      |> Int64.of_int
    in
    let updated_at_ms =
      Option.bind (one_in_datoms datoms "block/updated-at") int_of_value
      |> Option.value ~default:0
      |> Int64.of_int
    in
    Some
      Types.
        { page =
            Graph.
              { uuid
              ; name
              ; title
              ; kind = page_kind_of_datoms database datoms
              ; created_at_ms
              ; updated_at_ms
              ; tags = tagged_uuids_of_datoms database datoms
              ; properties =
                  property_summaries_of_datoms_with_class database property_class datoms
              ; recycled =
                  Option.is_some (one_in_datoms datoms "logseq.property/deleted-at")
              }
        }
  | _ -> None
;;

let page_record_of_entity database entity =
  page_record_of_entity_with_class
    database
    (entity_of_ident database "logseq.class/Property")
    entity
;;

let page_of_database database uuid =
  Option.bind (entity_of_uuid database uuid) (page_record_of_entity database)
;;

let entity_datoms_for_ids database entities =
  let entities = List.sort_uniq Int.compare entities in
  let result = Hashtbl.create (List.length entities) in
  let add datom =
    let preceding =
      Hashtbl.find_opt result datom.Datascript.e |> Option.value ~default:[]
    in
    Hashtbl.replace result datom.e (datom :: preceding)
  in
  (match entities with
   | [] -> ()
   | first :: _ ->
     let last = List.hd (List.rev entities) in
     if last - first <= List.length entities * 32
     then (
       let wanted = Hashtbl.create (List.length entities) in
       List.iter (fun entity -> Hashtbl.add wanted entity ()) entities;
       let rec consume sequence =
         match sequence () with
         | Seq.Nil -> ()
         | Seq.Cons (datom, rest) ->
           if datom.Datascript.e > last
           then ()
           else (
             if Hashtbl.mem wanted datom.e then add datom;
             consume rest)
       in
       consume (Datascript.seek_datoms database Datascript.Eavt ~e:first ()))
     else List.iter (fun entity -> List.iter add (entity_datoms database entity)) entities);
  Hashtbl.iter
    (fun entity datoms -> Hashtbl.replace result entity (List.rev datoms))
    result;
  result
;;

let pages_of_database database =
  let cache = hydration_cache database in
  let entities =
    Datascript.datoms database Datascript.Aevt ~a:"block/name" ()
    |> Seq.map (fun (datom : Datascript.datom) -> datom.e)
    |> List.of_seq
  in
  let datoms_by_entity = entity_datoms_for_ids database entities in
  entities
  |> List.filter_map (fun entity ->
    Option.bind (Hashtbl.find_opt datoms_by_entity entity) (fun datoms ->
      Option.map
        (fun (record : Types.page_record) -> record.page.uuid, record)
        (match
           ( Option.bind (one_in_datoms datoms "block/uuid") uuid_of_value
           , Option.bind (one_in_datoms datoms "block/name") string_of_value
           , Option.bind (one_in_datoms datoms "block/title") string_of_value )
         with
         | Some uuid, Some name, Some title ->
           let created_at_ms =
             Option.bind (one_in_datoms datoms "block/created-at") int_of_value
             |> Option.value ~default:0
             |> Int64.of_int
           in
           let updated_at_ms =
             Option.bind (one_in_datoms datoms "block/updated-at") int_of_value
             |> Option.value ~default:0
             |> Int64.of_int
           in
           Some
             Types.
               { page =
                   Graph.
                     { uuid
                     ; name
                     ; title
                     ; kind = page_kind_of_datoms database datoms
                     ; created_at_ms
                     ; updated_at_ms
                     ; tags = tagged_uuids_of_datoms database datoms
                     ; properties =
                         property_summaries_of_datoms_with_cache database cache datoms
                     ; recycled =
                         Option.is_some
                           (one_in_datoms datoms "logseq.property/deleted-at")
                     }
               }
         | _ -> None)))
  |> List.sort_uniq (fun (left, _) (right, _) -> Graph.Uuid.compare left right)
;;

let task_status_of_ident = function
  | "logseq.property/status.todo" -> Some Types.Todo
  | "logseq.property/status.doing" -> Some Doing
  | "logseq.property/status.in-review" -> Some In_review
  | "logseq.property/status.now" -> Some Now
  | "logseq.property/status.done" -> Some Done
  | "logseq.property/status.canceled" -> Some Canceled
  | "logseq.property/status.backlog" -> Some Backlog
  | "logseq.property/status.waiting" -> Some Waiting
  | "logseq.property/status.later" -> Some Later
  | _ -> None
;;

let task_status_of_datoms database datoms =
  match one_in_datoms datoms "logseq.property/status" with
  | Some (Datascript.Ref status) ->
    (match one database status "db/ident" with
     | Some (Datascript.Keyword ident | String ident) -> task_status_of_ident ident
     | Some _ | None -> None)
  | Some _ | None -> None
;;

let cached_uuid_of_entity database cache entity =
  match Hashtbl.find_opt cache.uuids entity with
  | Some uuid -> uuid
  | None ->
    let uuid = uuid_of_entity database entity in
    Hashtbl.add cache.uuids entity uuid;
    uuid
;;

let cached_page_title database cache entity =
  match Hashtbl.find_opt cache.page_titles entity with
  | Some title -> title
  | None ->
    let title =
      Option.bind (one database entity "block/title") string_of_value
      |> Option.value ~default:""
    in
    Hashtbl.add cache.page_titles entity title;
    title
;;

let block_record_of_datoms_with_cache database cache datoms =
  match
    ( Option.bind (one_in_datoms datoms "block/uuid") uuid_of_value
    , Option.bind (one_in_datoms datoms "block/title") string_of_value
    , Option.bind (one_in_datoms datoms "block/parent") reference_of_value
    , Option.bind (one_in_datoms datoms "block/page") reference_of_value
    , Option.bind (one_in_datoms datoms "block/order") string_of_value )
  with
  | Some uuid, Some title, Some parent_entity, Some page_entity, Some order ->
    (match
       ( cached_uuid_of_entity database cache parent_entity
       , cached_uuid_of_entity database cache page_entity )
     with
     | Some parent, Some page ->
       let created_at_ms =
         Option.bind (one_in_datoms datoms "block/created-at") int_of_value
         |> Option.value ~default:0
         |> Int64.of_int
       in
       let updated_at_ms =
         Option.bind (one_in_datoms datoms "block/updated-at") int_of_value
         |> Option.value ~default:0
         |> Int64.of_int
       in
       let rendered_page_title = cached_page_title database cache page_entity in
       Some
         Types.
           { block =
               Graph.
                 { uuid
                 ; title
                 ; parent
                 ; page
                 ; order
                 ; created_at_ms
                 ; updated_at_ms
                 ; refs =
                     values_in_datoms datoms "block/refs"
                     |> List.filter_map (fun value ->
                       Option.bind
                         (reference_of_value value)
                         (cached_uuid_of_entity database cache))
                     |> List.sort_uniq Graph.Uuid.compare
                 ; tags =
                     values_in_datoms datoms "block/tags"
                     |> List.filter_map (fun value ->
                       Option.bind
                         (reference_of_value value)
                         (cached_uuid_of_entity database cache))
                     |> List.sort_uniq Graph.Uuid.compare
                 ; properties =
                     property_summaries_of_datoms_with_cache database cache datoms
                 }
           ; task_status = task_status_of_datoms database datoms
           ; rendered_page_title
           }
     | _ -> None)
  | _ -> None
;;

let block_record_of_entity_with_cache database cache entity =
  block_record_of_datoms_with_cache database cache (entity_datoms database entity)
;;

let block_of_database_with_cache database cache uuid =
  Option.bind
    (entity_of_uuid database uuid)
    (block_record_of_entity_with_cache database cache)
;;

let block_of_database database uuid =
  block_of_database_with_cache database (hydration_cache database) uuid
;;

let decode_outbox records =
  let rec loop decoded seen maximum_revision = function
    | [] -> Ok (List.rev decoded, maximum_revision)
    | record :: rest ->
      Result.bind (Persistence_outbox_v14.decode record) (fun (record, revision) ->
        if List.exists (Graph.Uuid.equal record.mutation_id) seen
        then Error "duplicate mutation UUID in overlay outbox"
        else
          loop
            (record :: decoded)
            (record.mutation_id :: seen)
            (Int.max maximum_revision revision)
            rest)
  in
  loop [] [] 0 records
;;

let read_outbox path =
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () -> Logseq_db_storage.Sync_outbox_store.read_database sqlite)
;;

let validate_durable_receipts path =
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       Result.bind
         (Logseq_db_storage.Mutation_receipt_store.initialize_database sqlite)
         (fun () ->
            Logseq_db_storage.Mutation_receipt_store.validate_database
              sqlite
              ~is_valid:(fun key source ->
                Result.is_ok
                  (Persistence_receipt_v1.decode_mutation
                     ~startup_generation
                     ~projection_revision:(projection_revision 0)
                     (key, source)))))
;;

let read_durable_receipt path mutation_id =
  let key = Persistence_receipt_v1.receipt_key mutation_id in
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       Result.bind
         (Logseq_db_storage.Mutation_receipt_store.read_mutation sqlite key)
         (function
         | None -> Ok None
         | Some source ->
           Result.map
             Option.some
             (Persistence_receipt_v1.decode_mutation
                ~startup_generation
                ~projection_revision:(projection_revision 0)
                (key, source))))
;;

let read_terminal_batch database batch_id =
  let key = Persistence_receipt_v1.terminal_batch_key batch_id in
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database.database_path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       Result.bind
         (Logseq_db_storage.Mutation_receipt_store.read_terminal_batch sqlite key)
         (function
         | None -> Ok None
         | Some source ->
           Result.map
             Option.some
             (Persistence_receipt_v1.decode_terminal_batch (key, source))))
;;

let record_is_logically_active (record : outbox_record) =
  Queryable_outbox.logically_active record.transport_state
;;

let record_has_active_dependency_shadows (record : outbox_record) =
  Queryable_outbox.has_active_dependency_shadows record.transport_state
;;

let logical_pages_of_snapshot (snapshot : snapshot) =
  let view : logical_view =
    { block_rows = []
    ; page_rows = pages_of_database (Option.get snapshot.authoritative_database)
    }
  in
  List.iter
    (fun (record : outbox_record) ->
       match record.mutation with
       | Types.Create_journal_page _ when record_is_logically_active record ->
         ignore
           (Logical_snapshot.apply
              view
              ~ordinal:record.sequence
              ~now:record.intent_time_ms
              record.mutation
            : bool)
       | Save_block _
       | Insert_blocks _
       | Delete_blocks _
       | Set_task_status _
       | Clear_task_status _
       | Create_journal_page _ -> ())
    (Option.get snapshot.outbox);
  view.page_rows
;;

let clear_snapshot_roots (snapshot : snapshot) =
  snapshot.authoritative_database <- None;
  snapshot.outbox <- None;
  snapshot.block_effects <- None;
  snapshot.page_effects <- None;
  snapshot.children_effects <- None
;;

let close database =
  let current_callback = Eio.Fiber.get current_callback_subscription in
  let stopped, stopped_subscriptions, snapshot_waiters, callback_waiters =
    Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
      if database.closed
      then false, [], [], []
      else (
        database.closed <- true;
        database.release_slot := None;
        let callback_waiters =
          List.filter_map
            (fun (subscription : subscription) ->
               subscription.lifecycle <- Unlistened;
               subscription.notify <- None;
               if
                 subscription.callback_running
                 && not
                      (match current_callback with
                       | Some current -> current == subscription
                       | None -> false)
               then (
                 let waiter, resolver = Eio.Promise.create () in
                 subscription.callback_waiters
                 <- resolver :: subscription.callback_waiters;
                 Some waiter)
               else None)
            database.subscriptions
        in
        let snapshot_waiters =
          List.filter_map
            (fun (snapshot : snapshot) ->
               snapshot.released <- true;
               if snapshot.active_reads = 0
               then (
                 clear_snapshot_roots snapshot;
                 None)
               else (
                 let waiter, resolver = Eio.Promise.create () in
                 snapshot.drain_waiters <- resolver :: snapshot.drain_waiters;
                 Some waiter))
            database.snapshots
        in
        database.snapshots <- [];
        Datascript.unlisten
          database.authoritative_connection
          database.authoritative_listener;
        true, database.subscriptions, snapshot_waiters, callback_waiters))
  in
  List.iter
    (fun (subscription : subscription) ->
       while Option.is_some (Eio.Stream.take_nonblocking subscription.events) do
         ()
       done;
       Eio.Stream.add subscription.events None)
    stopped_subscriptions;
  if stopped
  then (
    while
      Eio.Stream.length database.dispatch_stream
      >= database.dependencies.limits.dispatcher_capacity
    do
      match Eio.Stream.take_nonblocking database.dispatch_stream with
      | Some (Dispatch_change (_, queued)) ->
        Eio.Semaphore.release database.dispatch_slots;
        Eio.Promise.resolve queued ()
      | Some Stop_dispatch | None -> ()
    done;
    Eio.Stream.add database.dispatch_stream Stop_dispatch);
  List.iter Eio.Promise.await snapshot_waiters;
  List.iter Eio.Promise.await callback_waiters;
  if stopped
  then (
    let storage_result =
      Logseq_db_storage.Storage_session.close database.storage_session
    in
    let ownership_result = Ownership.release database.ownership in
    match storage_result, ownership_result with
    | Ok (), Ok () -> Ok ()
    | Error _, _ -> Error (Types.Close_failed "lower storage close failed")
    | Ok (), Error message -> Error (Types.Close_failed message))
  else Ok ()
;;

let index_effects select records =
  List.fold_right
    (fun (record : outbox_record) index ->
       List.fold_left
         (fun index uuid ->
            let key = Graph.Uuid.to_string uuid in
            let current = Uuid_map.find_opt key index |> Option.value ~default:[] in
            Uuid_map.add key (record :: current) index)
         index
         (select record))
    records
    Uuid_map.empty
;;

let index_children_effects records =
  index_effects
    (fun record ->
       List.filter_map
         (function
           | Types.Children_interest parent -> Some parent
           | Page_tree_interest _ | Journal_index_interest -> None)
         record.effect_footprint.structure_interests
       @
       if record_has_active_dependency_shadows record
       then
         List.map
           (fun shadow -> shadow.shadow_parent)
           record.dependency_shadows.shadow_blocks
       else [])
    records
;;

let frozen_outbox (records : outbox_record list) =
  List.map
    (fun (record : outbox_record) -> { record with mutation_id = record.mutation_id })
    records
;;

let queryable_outbox_root (records : outbox_record list) =
  let outbox = frozen_outbox records in
  ( outbox
  , index_effects
      (fun record ->
         record.effect_footprint.block_uuids
         @
         if record_has_active_dependency_shadows record
         then
           List.map
             (fun shadow -> shadow.shadow_block_uuid)
             record.dependency_shadows.shadow_blocks
         else [])
      outbox
  , index_effects
      (fun record ->
         record.effect_footprint.page_uuids
         @
         if record_has_active_dependency_shadows record
         then
           List.map
             (fun shadow -> shadow.shadow_page_uuid)
             record.dependency_shadows.shadow_pages
         else [])
      outbox
  , index_children_effects outbox )
;;

let refresh_queryable_outbox database =
  let outbox, block_effects, page_effects, children_effects =
    queryable_outbox_root database.outbox
  in
  database.queryable_outbox <- outbox;
  database.queryable_block_effects <- block_effects;
  database.queryable_page_effects <- page_effects;
  database.queryable_children_effects <- children_effects
;;

let snapshot_of_database database =
  { owner = database
  ; version =
      { Types.generation = database.generation
      ; projection_revision = projection_revision database.projection
      }
  ; authoritative_database = Some (authoritative_database database)
  ; outbox = Some database.queryable_outbox
  ; block_effects = Some database.queryable_block_effects
  ; page_effects = Some database.queryable_page_effects
  ; children_effects = Some database.queryable_children_effects
  ; released = false
  ; active_reads = 0
  ; drain_waiters = []
  }
;;

let snapshot_for_sources database authoritative_database outbox =
  let outbox, block_effects, page_effects, children_effects =
    queryable_outbox_root outbox
  in
  { owner = database
  ; version =
      { Types.generation = database.generation
      ; projection_revision = projection_revision database.projection
      }
  ; authoritative_database = Some authoritative_database
  ; outbox = Some outbox
  ; block_effects = Some block_effects
  ; page_effects = Some page_effects
  ; children_effects = Some children_effects
  ; released = false
  ; active_reads = 0
  ; drain_waiters = []
  }
;;

let current_snapshot database =
  Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
    if database.closed
    then Error Types.Database_closed
    else (
      let snapshot = snapshot_of_database database in
      database.snapshots <- snapshot :: database.snapshots;
      Ok snapshot))
;;

let snapshot_version snapshot = snapshot.version

let release_snapshot snapshot =
  let waiter =
    Eio.Mutex.use_rw ~protect:true snapshot.owner.lock (fun () ->
      if not snapshot.released
      then (
        snapshot.released <- true;
        snapshot.owner.snapshots
        <- List.filter (fun candidate -> candidate != snapshot) snapshot.owner.snapshots;
        if snapshot.active_reads = 0
        then (
          clear_snapshot_roots snapshot;
          None)
        else (
          let waiter, resolver = Eio.Promise.create () in
          snapshot.drain_waiters <- resolver :: snapshot.drain_waiters;
          Some waiter))
      else None)
  in
  Option.iter Eio.Promise.await waiter
;;

let with_snapshot_read snapshot read =
  let captured =
    Eio.Mutex.use_rw ~protect:true snapshot.owner.lock (fun () ->
      if snapshot.owner.closed
      then Error Types.Database_closed
      else if snapshot.released
      then Error Types.Snapshot_released
      else (
        snapshot.active_reads <- snapshot.active_reads + 1;
        Ok
          { snapshot with
            authoritative_database = snapshot.authoritative_database
          ; outbox = snapshot.outbox
          ; block_effects = snapshot.block_effects
          ; page_effects = snapshot.page_effects
          ; children_effects = snapshot.children_effects
          ; active_reads = 0
          ; drain_waiters = []
          }))
  in
  match captured with
  | Error _ as error -> error
  | Ok captured ->
    Fun.protect
      ~finally:(fun () ->
        Eio.Mutex.use_rw ~protect:true snapshot.owner.lock (fun () ->
          snapshot.active_reads <- snapshot.active_reads - 1;
          if snapshot.active_reads = 0 && snapshot.drain_waiters <> []
          then (
            if snapshot.released || snapshot.owner.closed
            then clear_snapshot_roots snapshot;
            let waiters = snapshot.drain_waiters in
            snapshot.drain_waiters <- [];
            List.iter (fun resolver -> Eio.Promise.resolve resolver ()) waiters)))
      (fun () -> read captured)
;;

let graph_info snapshot =
  with_snapshot_read snapshot (fun snapshot ->
    Ok
      { Types.graph_uuid = snapshot.owner.graph_uuid
      ; graph_name = snapshot.owner.graph_name
      ; schema = snapshot.owner.schema
      ; admission_facts = snapshot.owner.admission_facts
      ; limits = snapshot.owner.dependencies.limits
      ; version = snapshot.version
      })
;;

let inspect_admission database =
  Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
    if database.closed
    then Error Types.Admission_database_closed
    else (
      let active_bytes =
        database.outbox
        |> List.map (Persistence_outbox_v14.encode ~sync_revision:database.sync_revision)
        |> List.fold_left (fun total record -> total + String.length record) 0
      in
      let protected_wire_bytes =
        List.fold_left
          (fun total (record : outbox_record) ->
             total + Option.fold ~none:0 ~some:String.length record.protected_transaction)
          0
          database.outbox
      in
      let retained_origin_evidence_bytes =
        List.fold_left
          (fun total (record : outbox_record) ->
             total
             + Option.fold
                 ~none:0
                 ~some:(fun cursor ->
                   String.length (Types.Server_cursor.to_string cursor))
                 record.observed_origin_cursor)
          0
          database.outbox
      in
      Ok
        { Types.active_records = List.length database.outbox
        ; active_bytes
        ; protected_wire_bytes
        ; retained_origin_evidence_bytes
        ; maximum_records = database.dependencies.limits.outbox_max_records
        ; maximum_bytes = database.dependencies.limits.outbox_max_bytes
        }))
;;

let state_digest value =
  Marshal.to_string value [ Marshal.No_sharing ] |> Digest.string |> Digest.to_hex
;;

let logical_block_revision uuid value =
  token
    Types.Block_state_revision.of_string
    ("block-state:v1:" ^ Graph.Uuid.to_string uuid ^ ":" ^ state_digest value)
;;

let logical_page_revision uuid value =
  token
    Types.Page_state_revision.of_string
    ("page-state:v1:" ^ Graph.Uuid.to_string uuid ^ ":" ^ state_digest value)
;;

let status_ident = Outliner.Task_status.ident

let rec inserted_block
          database
          ~target
          ~parent
          ~page
          ~order
          ~now
          (tree : Types.block_tree)
  =
  if Graph.Uuid.equal target tree.uuid
  then (
    let properties =
      []
      |> set_property_values database "block/title" [ Datascript.String tree.title ]
      |> set_uuid_property_values database "block/parent" [ parent ]
      |> set_uuid_property_values database "block/page" [ page ]
      |> set_property_values database "block/order" [ Datascript.String order ]
      |> set_property_values
           database
           "block/created-at"
           [ Datascript.Int (Int64.to_int now) ]
      |> set_property_values
           database
           "block/updated-at"
           [ Datascript.Int (Int64.to_int now) ]
    in
    Some
      Types.
        { block =
            Graph.
              { uuid = tree.uuid
              ; title = tree.title
              ; parent
              ; page
              ; order
              ; created_at_ms = now
              ; updated_at_ms = now
              ; refs = []
              ; tags = []
              ; properties
              }
        ; task_status = None
        ; rendered_page_title = ""
        })
  else
    List.mapi (fun index child -> index, child) tree.children
    |> List.find_map (fun (index, child) ->
      inserted_block
        database
        ~target
        ~parent:tree.uuid
        ~page
        ~order:(Outliner_order.child ~index)
        ~now
        child)
;;

let page_record_of_shadow shadow =
  Types.
    { page =
        Graph.
          { uuid = shadow.shadow_page_uuid
          ; name = shadow.shadow_name
          ; title = shadow.shadow_page_title
          ; kind = shadow.shadow_page_kind
          ; created_at_ms = shadow.shadow_page_created_at_ms
          ; updated_at_ms = shadow.shadow_page_updated_at_ms
          ; tags = []
          ; properties = []
          ; recycled = shadow.shadow_recycled
          }
    }
;;

let block_record_of_shadow shadow =
  Types.
    { block =
        Graph.
          { uuid = shadow.shadow_block_uuid
          ; title = shadow.shadow_title
          ; parent = shadow.shadow_parent
          ; page = shadow.shadow_page
          ; order = shadow.shadow_order
          ; created_at_ms = shadow.shadow_created_at_ms
          ; updated_at_ms = shadow.shadow_updated_at_ms
          ; refs = []
          ; tags = []
          ; properties = []
          }
    ; task_status = shadow.shadow_task_status
    ; rendered_page_title = ""
    }
;;

let logical_page_at (snapshot : snapshot) uuid =
  let authoritative = Option.get snapshot.authoritative_database in
  let effects =
    Uuid_map.find_opt (Graph.Uuid.to_string uuid) (Option.get snapshot.page_effects)
    |> Option.value ~default:[]
  in
  let initial =
    match page_of_database authoritative uuid with
    | Some _ as page -> page
    | None ->
      List.find_map
        (fun (record : outbox_record) ->
           if record_has_active_dependency_shadows record
           then
             List.find_opt
               (fun shadow -> Graph.Uuid.equal shadow.shadow_page_uuid uuid)
               record.dependency_shadows.shadow_pages
             |> Option.map page_record_of_shadow
           else None)
        effects
  in
  List.fold_left
    (fun current (record : outbox_record) ->
       if not (record_is_logically_active record)
       then current
       else (
         match record.mutation with
         | Types.Create_journal_page { page; title; journal_day; _ }
           when Graph.Uuid.equal page uuid ->
           let properties =
             []
             |> set_property_values
                  authoritative
                  "block/title"
                  [ Datascript.String title ]
             |> set_property_values
                  authoritative
                  "block/created-at"
                  [ Datascript.Int (Int64.to_int record.intent_time_ms) ]
             |> set_property_values
                  authoritative
                  "block/updated-at"
                  [ Datascript.Int (Int64.to_int record.intent_time_ms) ]
             |> set_property_values
                  authoritative
                  "block/journal-day"
                  [ Datascript.Int journal_day ]
           in
           Some
             Types.
               { page =
                   Graph.
                     { uuid = page
                     ; name = String.lowercase_ascii title
                     ; title
                     ; kind = Journal_page { journal_day }
                     ; created_at_ms = record.intent_time_ms
                     ; updated_at_ms = record.intent_time_ms
                     ; tags = []
                     ; properties
                     ; recycled = false
                     }
               }
         | Delete_blocks _ ->
           (match record.delete_artifacts with
            | None -> current
            | Some artifacts ->
              let property_patch =
                List.find_opt
                  (fun patch -> Graph.Uuid.equal patch.holder_uuid uuid)
                  artifacts.property_patches
              in
              let page_patch =
                List.find_opt
                  (fun patch -> Graph.Uuid.equal patch.page_uuid uuid)
                  artifacts.page_patches
              in
              Option.map
                (fun (value : Types.page_record) ->
                   let properties =
                     match property_patch with
                     | None -> value.page.properties
                     | Some patch ->
                       set_uuid_property_values
                         authoritative
                         patch.property_ident
                         [ patch.replacement_uuid ]
                         value.page.properties
                   in
                   match page_patch with
                   | None -> Types.{ page = Graph.{ value.page with properties } }
                   | Some patch ->
                     let properties =
                       set_property_values
                         authoritative
                         "block/updated-at"
                         [ Datascript.Int (Int64.to_int patch.updated_at_ms) ]
                         properties
                     in
                     Types.
                       { page =
                           Graph.
                             { value.page with
                               updated_at_ms = patch.updated_at_ms
                             ; properties
                             }
                       })
                current)
         | _ -> current))
    initial
    effects
;;

let logical_block_at ?cache ?initial (snapshot : snapshot) uuid =
  let authoritative = Option.get snapshot.authoritative_database in
  let effects =
    Uuid_map.find_opt (Graph.Uuid.to_string uuid) (Option.get snapshot.block_effects)
    |> Option.value ~default:[]
  in
  let authoritative_initial =
    match initial, cache with
    | Some initial, _ -> initial
    | None, None -> block_of_database authoritative uuid
    | None, Some cache -> block_of_database_with_cache authoritative cache uuid
  in
  let initial =
    match authoritative_initial with
    | Some _ as block -> block
    | None ->
      List.find_map
        (fun (record : outbox_record) ->
           if record_has_active_dependency_shadows record
           then
             List.find_opt
               (fun shadow -> Graph.Uuid.equal shadow.shadow_block_uuid uuid)
               record.dependency_shadows.shadow_blocks
             |> Option.map block_record_of_shadow
           else None)
        effects
  in
  let value =
    List.fold_left
      (fun current (record : outbox_record) ->
         if not (record_is_logically_active record)
         then current
         else (
           match record.mutation with
           | Types.Save_block { block; title; _ } when Graph.Uuid.equal block uuid ->
             Option.map
               (fun (value : Types.block_record) ->
                  let properties =
                    set_block_field_properties
                      ?cache
                      authoritative
                      value.block
                      ~title
                      ~updated_at_ms:record.intent_time_ms
                      ~refs:value.block.refs
                  in
                  Types.
                    { value with
                      block =
                        Graph.
                          { value.block with
                            title
                          ; updated_at_ms = record.intent_time_ms
                          ; properties
                          }
                    })
               current
           | Insert_blocks { parent; tree; _ } ->
             let page =
               match record.effect_footprint.page_uuids with
               | page :: _ -> page
               | [] -> parent
             in
             (match
                inserted_block
                  authoritative
                  ~target:uuid
                  ~parent
                  ~page
                  ~order:(Outliner_order.root ~sequence:record.sequence)
                  ~now:record.intent_time_ms
                  tree
              with
              | Some inserted -> Some inserted
              | None -> current)
           | Delete_blocks _ ->
             (match record.delete_artifacts with
              | None -> None
              | Some artifacts when List.exists (Graph.Uuid.equal uuid) artifacts.frontier
                -> None
              | Some artifacts ->
                (match
                   List.find_opt
                     (fun patch -> Graph.Uuid.equal patch.holder_uuid uuid)
                     artifacts.property_patches
                 with
                 | Some patch ->
                   Option.map
                     (fun (value : Types.block_record) ->
                        let properties =
                          set_uuid_property_values
                            ?cache
                            authoritative
                            patch.property_ident
                            [ patch.replacement_uuid ]
                            value.block.properties
                          |> set_property_values
                               ?cache
                               authoritative
                               "block/updated-at"
                               [ Datascript.Int (Int64.to_int patch.updated_at_ms) ]
                        in
                        Types.
                          { value with
                            block =
                              Graph.
                                { value.block with
                                  updated_at_ms = patch.updated_at_ms
                                ; properties
                                }
                          })
                     current
                 | None ->
                   (match
                      List.find_opt
                        (fun patch -> Graph.Uuid.equal patch.block_uuid uuid)
                        artifacts.block_patches
                    with
                    | None -> current
                    | Some patch ->
                      Option.map
                        (fun (value : Types.block_record) ->
                           let properties =
                             set_block_field_properties
                               ?cache
                               authoritative
                               value.block
                               ~title:patch.title
                               ~updated_at_ms:patch.updated_at_ms
                               ~refs:patch.refs
                           in
                           Types.
                             { value with
                               block =
                                 Graph.
                                   { value.block with
                                     title = patch.title
                                   ; refs = patch.refs
                                   ; updated_at_ms = patch.updated_at_ms
                                   ; properties
                                   }
                             })
                        current)))
           | Set_task_status { block; status; _ } when Graph.Uuid.equal block uuid ->
             Option.map
               (fun (value : Types.block_record) ->
                  let properties =
                    let properties =
                      set_property_values
                        authoritative
                        "block/updated-at"
                        [ Datascript.Int (Int64.to_int record.intent_time_ms) ]
                        value.block.properties
                    in
                    match entity_of_ident authoritative (status_ident status) with
                    | None -> properties
                    | Some status_entity ->
                      set_property_values
                        authoritative
                        "logseq.property/status"
                        [ Datascript.Ref status_entity ]
                        properties
                  in
                  Types.
                    { value with
                      block =
                        Graph.
                          { value.block with
                            updated_at_ms = record.intent_time_ms
                          ; properties
                          }
                    ; task_status = Some status
                    })
               current
           | Clear_task_status { block; _ } when Graph.Uuid.equal block uuid ->
             Option.map
               (fun (value : Types.block_record) ->
                  let properties =
                    value.block.properties
                    |> set_property_values authoritative "logseq.property/status" []
                    |> set_property_values
                         authoritative
                         "block/updated-at"
                         [ Datascript.Int (Int64.to_int record.intent_time_ms) ]
                  in
                  Types.
                    { value with
                      block =
                        Graph.
                          { value.block with
                            updated_at_ms = record.intent_time_ms
                          ; properties
                          }
                    ; task_status = None
                    })
               current
           | Save_block _
           | Create_journal_page _
           | Set_task_status _
           | Clear_task_status _ -> current))
      initial
      effects
  in
  Option.map
    (fun (value : Types.block_record) ->
       let rendered_page_title =
         logical_page_at snapshot value.block.page
         |> Option.map (fun (page : Types.page_record) -> page.page.title)
         |> Option.value ~default:""
       in
       Types.{ value with rendered_page_title })
    value
;;

let get_blocks snapshot uuids =
  with_snapshot_read snapshot (fun snapshot ->
    let cache = hydration_cache (Option.get snapshot.authoritative_database) in
    Ok
      (List.map
         (fun uuid ->
            let value = logical_block_at ~cache snapshot uuid in
            let revision = logical_block_revision uuid value in
            match value with
            | Some value -> Types.Present_block { value; revision }
            | None -> Missing_block { uuid; revision })
         uuids))
;;

let get_pages snapshot uuids =
  with_snapshot_read snapshot (fun snapshot ->
    Ok
      (List.map
         (fun uuid ->
            let value = logical_page_at snapshot uuid in
            let revision = logical_page_revision uuid value in
            match value with
            | Some value -> Types.Present_page { value; revision }
            | None -> Missing_page { uuid; revision })
         uuids))
;;

let scope_key = function
  | Types.Children_revision parent -> "children:" ^ Graph.Uuid.to_string parent
  | Page_tree_revision { page; maximum_depth } ->
    Printf.sprintf "page-tree:%s:%d" (Graph.Uuid.to_string page) maximum_depth
  | Journal_index_revision -> "journal-index"
;;

let block_is_tombstoned (snapshot : snapshot) uuid =
  Uuid_map.find_opt (Graph.Uuid.to_string uuid) (Option.get snapshot.block_effects)
  |> Option.value ~default:[]
  |> List.exists (fun (record : outbox_record) ->
    record_is_logically_active record
    &&
    match record.mutation, record.delete_artifacts with
    | Types.Delete_blocks _, Some artifacts ->
      List.exists (Graph.Uuid.equal uuid) artifacts.frontier
    | ( ( Save_block _
        | Insert_blocks _
        | Delete_blocks _
        | Create_journal_page _
        | Set_task_status _
        | Clear_task_status _ )
      , _ ) -> false)
;;

let authoritative_child_entity_facts ?datoms_by_uuid (snapshot : snapshot) parent =
  let database = Option.get snapshot.authoritative_database in
  match entity_of_uuid database parent with
  | None -> Seq.empty
  | Some parent_entity ->
    let entities =
      Datascript.datoms
        database
        Datascript.Avet
        ~a:"block/parent"
        ~v:(Datascript.Ref parent_entity)
        ()
      |> Seq.map (fun (datom : Datascript.datom) -> datom.e)
      |> List.of_seq
    in
    let datoms_by_entity = entity_datoms_for_ids database entities in
    entities
    |> List.filter_map (fun entity ->
      Option.bind (Hashtbl.find_opt datoms_by_entity entity) (fun datoms ->
        match
          ( Option.bind (one_in_datoms datoms "block/uuid") uuid_of_value
          , Option.bind (one_in_datoms datoms "block/order") string_of_value )
        with
        | Some uuid, Some order when not (block_is_tombstoned snapshot uuid) ->
          Option.iter
            (fun table -> Hashtbl.replace table (Graph.Uuid.to_string uuid) datoms)
            datoms_by_uuid;
          Some (order, uuid, entity)
        | _ -> None))
    |> List.to_seq
;;

let authoritative_child_facts snapshot parent =
  authoritative_child_entity_facts snapshot parent
  |> Seq.map (fun (order, uuid, _) -> order, uuid)
;;

let local_child_facts (snapshot : snapshot) parent =
  Uuid_map.find_opt (Graph.Uuid.to_string parent) (Option.get snapshot.children_effects)
  |> Option.value ~default:[]
  |> List.concat_map (fun (record : outbox_record) ->
    if not (record_is_logically_active record)
    then []
    else (
      let inserted =
        match record.mutation with
        | Types.Insert_blocks { parent = candidate; tree; _ }
          when Graph.Uuid.equal parent candidate ->
          [ Outliner_order.root ~sequence:record.sequence, tree.uuid ]
        | Save_block _
        | Insert_blocks _
        | Delete_blocks _
        | Create_journal_page _
        | Set_task_status _
        | Clear_task_status _ -> []
      in
      let shadows =
        if record_has_active_dependency_shadows record
        then
          record.dependency_shadows.shadow_blocks
          |> List.filter (fun shadow -> Graph.Uuid.equal shadow.shadow_parent parent)
          |> List.filter (fun shadow ->
            Option.is_none
              (block_of_database
                 (Option.get snapshot.authoritative_database)
                 shadow.shadow_block_uuid))
          |> List.map (fun shadow -> shadow.shadow_order, shadow.shadow_block_uuid)
        else []
      in
      inserted @ shadows))
  |> List.sort_uniq compare
;;

let xor_digest accumulator value =
  let digest = Digestif.SHA256.digest_string value |> Digestif.SHA256.to_raw_string in
  for index = 0 to Bytes.length accumulator - 1 do
    Bytes.set
      accumulator
      index
      (Char.chr (Char.code (Bytes.get accumulator index) lxor Char.code digest.[index]))
  done
;;

let children_membership_digest snapshot parent =
  let accumulator = Bytes.make 32 '\000' in
  let add (order, uuid) =
    xor_digest accumulator (Graph.Uuid.to_string uuid ^ "\000" ^ order)
  in
  Seq.iter add (authoritative_child_facts snapshot parent);
  List.iter add (local_child_facts snapshot parent);
  Bytes.to_string accumulator |> Digestif.SHA256.of_raw_string |> Digestif.SHA256.to_hex
;;

let scope_revision_from_members scope members =
  let key = scope_key scope in
  let digest = String.concat "\000" members |> Digest.string |> Digest.to_hex in
  token Types.Scope_revision.of_string (Printf.sprintf "scope:v1:%s:%s" digest key)
;;

let revision_for_scope (snapshot : snapshot) scope =
  let direct_children parent =
    let authoritative =
      match entity_of_uuid (Option.get snapshot.authoritative_database) parent with
      | None -> []
      | Some parent_entity ->
        Datascript.datoms
          (Option.get snapshot.authoritative_database)
          Datascript.Avet
          ~a:"block/parent"
          ~v:(Datascript.Ref parent_entity)
          ()
        |> List.of_seq
        |> List.filter_map (fun (datom : Datascript.datom) ->
          uuid_of_entity (Option.get snapshot.authoritative_database) datom.e)
    in
    let inserted =
      Uuid_map.find_opt
        (Graph.Uuid.to_string parent)
        (Option.get snapshot.children_effects)
      |> Option.value ~default:[]
      |> List.filter_map (fun (record : outbox_record) ->
        if not (record_is_logically_active record)
        then None
        else (
          match record.mutation with
          | Types.Insert_blocks { parent = candidate; tree; _ }
            when Graph.Uuid.equal candidate parent -> Some tree.uuid
          | _ -> None))
    in
    List.sort_uniq Graph.Uuid.compare (authoritative @ inserted)
    |> List.filter_map (fun uuid ->
      match logical_block_at snapshot uuid with
      | Some record when Graph.Uuid.equal record.block.parent parent -> Some record
      | Some _ | None -> None)
    |> List.sort (fun (left : Types.block_record) (right : Types.block_record) ->
      String.compare left.block.order right.block.order)
  in
  let block_member (record : Types.block_record) =
    String.concat
      ":"
      [ Graph.Uuid.to_string record.block.uuid
      ; Graph.Uuid.to_string record.block.parent
      ; record.block.order
      ]
  in
  let members =
    match scope with
    | Types.Children_revision parent -> [ children_membership_digest snapshot parent ]
    | Page_tree_revision { page; maximum_depth } ->
      let rec walk depth parent =
        if depth > maximum_depth
        then []
        else
          direct_children parent
          |> List.concat_map (fun record ->
            (string_of_int depth ^ ":" ^ block_member record)
            :: walk (depth + 1) record.block.uuid)
      in
      walk 0 page
    | Journal_index_revision ->
      logical_pages_of_snapshot snapshot
      |> List.filter_map (fun (_, (record : Types.page_record)) ->
        match record.page.kind with
        | Graph.Journal_page { journal_day } ->
          Some
            (Printf.sprintf "%08d:%s" journal_day (Graph.Uuid.to_string record.page.uuid))
        | Ordinary_page | Class_page | Property_page | Hidden_page | Built_in_page -> None)
      |> List.sort String.compare
  in
  scope_revision_from_members scope members
;;

let projection_number revision =
  Types.Projection_revision.to_string revision
  |> String.split_on_char ':'
  |> List.rev
  |> List.hd
  |> int_of_string
;;

let maximum_cursor_offset = Query_cursor.maximum_offset
let maximum_read_page_size = 200
let valid_page_limit limit = limit >= 1 && limit <= maximum_read_page_size

let checked_add_nonnegative left right =
  if left < 0 || right < 0 || right > Int.max_int - left then None else Some (left + right)
;;

let journal_cursor snapshot offset =
  let projection = projection_number snapshot.version.projection_revision in
  Query_cursor.create ~projection ~offset
;;

let journal_cursor_offset snapshot cursor =
  Query_cursor.offset
    ~projection:(projection_number snapshot.version.projection_revision)
    cursor
  |> Result.map_error (function
    | Query_cursor.Invalid -> Types.Invalid_read_request "invalid journal cursor"
    | Invalid_or_stale -> Types.Invalid_read_request "invalid or stale journal cursor")
;;

let get_journals snapshot ~limit ~cursor =
  with_snapshot_read snapshot (fun snapshot ->
    if not (valid_page_limit limit)
    then Error (Types.Invalid_read_request "limit must be between 1 and 200")
    else (
      let offset_result =
        match cursor with
        | None -> Ok 0
        | Some cursor -> journal_cursor_offset snapshot cursor
      in
      Result.bind offset_result (fun offset ->
        let page_rows = logical_pages_of_snapshot snapshot in
        let journals =
          page_rows
          |> List.filter_map (fun (_, (record : Types.page_record)) ->
            match record.page.kind with
            | Graph.Journal_page { journal_day } ->
              let revision = logical_page_revision record.page.uuid (Some record) in
              Some Types.{ page = record; journal_day; revision }
            | _ -> None)
          |> List.sort (fun (left : Types.journal_item) (right : Types.journal_item) ->
            let day = Int.compare right.journal_day left.journal_day in
            if day <> 0
            then day
            else Graph.Uuid.compare left.page.page.uuid right.page.page.uuid)
        in
        let rec take count acc = function
          | [] -> List.rev acc
          | _ when count = 0 -> List.rev acc
          | item :: rest -> take (count - 1) (item :: acc) rest
        in
        let rec drop count values =
          match count, values with
          | 0, _ | _, [] -> values
          | count, _ :: rest -> drop (count - 1) rest
        in
        let revision_scope = Types.Journal_index_revision in
        let items = take limit [] (drop offset journals) in
        match checked_add_nonnegative offset (List.length items) with
        | None -> Error (Types.Invalid_read_request "journal cursor offset overflow")
        | Some consumed
          when consumed < List.length journals && consumed > maximum_cursor_offset ->
          Error Types.Read_limit_exceeded
        | Some consumed ->
          let scope_members =
            List.map
              (fun (item : Types.journal_item) ->
                 Printf.sprintf
                   "%08d:%s"
                   item.journal_day
                   (Graph.Uuid.to_string item.page.page.uuid))
              journals
            |> List.sort String.compare
          in
          Ok
            { Types.items
            ; next_cursor =
                (if consumed < List.length journals
                 then Some (journal_cursor snapshot consumed)
                 else None)
            ; revision_scope
            ; scope_revision = scope_revision_from_members revision_scope scope_members
            })))
;;

let child_items ?cache (snapshot : snapshot) parent =
  let authoritative =
    match entity_of_uuid (Option.get snapshot.authoritative_database) parent with
    | None -> []
    | Some parent_entity ->
      Datascript.datoms
        (Option.get snapshot.authoritative_database)
        Datascript.Avet
        ~a:"block/parent"
        ~v:(Datascript.Ref parent_entity)
        ()
      |> List.of_seq
      |> List.filter_map (fun (datom : Datascript.datom) ->
        uuid_of_entity (Option.get snapshot.authoritative_database) datom.e)
  in
  let inserted =
    Uuid_map.find_opt (Graph.Uuid.to_string parent) (Option.get snapshot.children_effects)
    |> Option.value ~default:[]
    |> List.filter_map (fun (record : outbox_record) ->
      if not (record_is_logically_active record)
      then None
      else (
        match record.mutation with
        | Types.Insert_blocks { parent = candidate; tree; _ }
          when Graph.Uuid.equal candidate parent -> Some tree.uuid
        | _ -> None))
  in
  List.sort_uniq Graph.Uuid.compare (authoritative @ inserted)
  |> List.filter_map (fun uuid ->
    match logical_block_at ?cache snapshot uuid with
    | Some record when Graph.Uuid.equal record.block.parent parent ->
      Some
        Types.
          { block = record
          ; revision = logical_block_revision record.block.uuid (Some record)
          }
    | Some _ | None -> None)
  |> List.sort (fun (left : Types.child_member) (right : Types.child_member) ->
    String.compare left.block.block.order right.block.block.order)
;;

let structure_cursor snapshot offset =
  let projection = projection_number snapshot.version.projection_revision in
  Query_cursor.create ~projection ~offset
;;

let structure_cursor_offset snapshot cursor =
  Query_cursor.offset
    ~projection:(projection_number snapshot.version.projection_revision)
    cursor
  |> Result.map_error (function
    | Query_cursor.Invalid -> Types.Invalid_read_request "invalid structure cursor"
    | Invalid_or_stale -> Types.Invalid_read_request "invalid or stale structure cursor")
;;

let paginate_structure snapshot ~limit ~offset items =
  let rec take count acc = function
    | [] -> List.rev acc
    | _ when count = 0 -> List.rev acc
    | item :: rest -> take (count - 1) (item :: acc) rest
  in
  let rec drop count values =
    match count, values with
    | 0, _ | _, [] -> values
    | count, _ :: rest -> drop (count - 1) rest
  in
  let page = take limit [] (drop offset items) in
  match checked_add_nonnegative offset (List.length page) with
  | None -> Error (Types.Invalid_read_request "structure cursor offset overflow")
  | Some consumed when consumed < List.length items && consumed > maximum_cursor_offset ->
    Error Types.Read_limit_exceeded
  | Some consumed ->
    let next_cursor =
      if consumed < List.length items
      then Some (structure_cursor snapshot consumed)
      else None
    in
    Ok (page, next_cursor)
;;

let paginate_children snapshot ~parent ~limit ~offset =
  let local = local_child_facts snapshot parent in
  let requested =
    Option.bind (checked_add_nonnegative offset limit) (fun requested ->
      checked_add_nonnegative requested (List.length local))
  in
  match requested with
  | None -> Error (Types.Invalid_read_request "children pagination bound overflow")
  | Some requested ->
    let membership_accumulator = Bytes.make 32 '\000' in
    let add_to_membership_digest ((order, uuid) as fact) =
      xor_digest membership_accumulator (Graph.Uuid.to_string uuid ^ "\000" ^ order);
      fact
    in
    let authoritative_datoms = Hashtbl.create requested in
    let authoritative_facts =
      authoritative_child_entity_facts
        ~datoms_by_uuid:authoritative_datoms
        snapshot
        parent
      |> Seq.map (fun (order, uuid, _) -> order, uuid)
    in
    let facts, total =
      Overlay_read.bounded_members
        ~maximum:requested
        (Seq.append authoritative_facts (List.to_seq local)
         |> Seq.map add_to_membership_digest)
    in
    let rec drop count values =
      match count, values with
      | 0, _ | _, [] -> values
      | count, _ :: rest -> drop (count - 1) rest
    in
    let cache = hydration_cache (Option.get snapshot.authoritative_database) in
    let rec take count reversed = function
      | [] -> List.rev reversed
      | _ when count = 0 -> List.rev reversed
      | (_, uuid) :: rest ->
        let reversed =
          let initial =
            Option.bind
              (Hashtbl.find_opt authoritative_datoms (Graph.Uuid.to_string uuid))
              (block_record_of_datoms_with_cache
                 (Option.get snapshot.authoritative_database)
                 cache)
          in
          match logical_block_at ~cache ~initial snapshot uuid with
          | Some block ->
            Types.{ block; revision = logical_block_revision uuid (Some block) }
            :: reversed
          | None -> reversed
        in
        take (count - 1) reversed rest
    in
    let items = take limit [] (drop offset facts) in
    (match checked_add_nonnegative offset (List.length items) with
     | None -> Error (Types.Invalid_read_request "children cursor offset overflow")
     | Some consumed when consumed < total && consumed > maximum_cursor_offset ->
       Error Types.Read_limit_exceeded
     | Some consumed ->
       let next_cursor =
         if consumed < total then Some (structure_cursor snapshot consumed) else None
       in
       let membership_digest =
         Bytes.to_string membership_accumulator
         |> Digestif.SHA256.of_raw_string
         |> Digestif.SHA256.to_hex
       in
       Ok (items, next_cursor, membership_digest))
;;

let get_structure snapshot request =
  with_snapshot_read snapshot (fun snapshot ->
    match request with
    | Types.Children { parent; limit; cursor } ->
      (match () with
       | () when not (valid_page_limit limit) ->
         Error (Types.Invalid_read_request "limit must be between 1 and 200")
       | () ->
         let revision_scope = Types.Children_revision parent in
         let offset_result =
           match cursor with
           | None -> Ok 0
           | Some cursor -> structure_cursor_offset snapshot cursor
         in
         Result.bind offset_result (fun offset ->
           Result.map
             (fun (items, next_cursor, membership_digest) ->
                Types.Children_result
                  { parent
                  ; revision_scope
                  ; scope_revision =
                      scope_revision_from_members revision_scope [ membership_digest ]
                  ; items
                  ; next_cursor
                  })
             (paginate_children snapshot ~parent ~limit ~offset)))
    | Types.Page_tree { page; maximum_depth; limit; cursor } ->
      (match () with
       | () when (not (valid_page_limit limit)) || maximum_depth < 0 ->
         Error (Types.Invalid_read_request "invalid page-tree bounds")
       | () ->
         let offset_result =
           match cursor with
           | None -> Ok 0
           | Some cursor -> structure_cursor_offset snapshot cursor
         in
         Result.bind offset_result (fun offset ->
           let cache = hydration_cache (Option.get snapshot.authoritative_database) in
           let rec walk depth parent =
             if depth > maximum_depth
             then []
             else
               child_items ~cache snapshot parent
               |> List.concat_map (fun (child : Types.child_member) ->
                 Types.{ block = child.block; revision = child.revision; depth; parent }
                 :: walk (depth + 1) child.block.block.uuid)
           in
           let revision_scope = Types.Page_tree_revision { page; maximum_depth } in
           Result.map
             (fun (items, next_cursor) ->
                Types.Page_tree_result
                  { page
                  ; maximum_depth
                  ; revision_scope
                  ; scope_revision = revision_for_scope snapshot revision_scope
                  ; items
                  ; next_cursor
                  })
             (paginate_structure snapshot ~limit ~offset (walk 0 page)))))
;;

let listen database =
  Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
    if database.closed
    then Error Types.Listen_database_closed
    else (
      let subscription =
        { owner = database
        ; events = Eio.Stream.create database.dependencies.limits.dispatcher_capacity
        ; lifecycle = Active
        ; notify = None
        ; callback_running = false
        ; callback_waiters = []
        }
      in
      database.subscriptions <- subscription :: database.subscriptions;
      let snapshot = snapshot_of_database database in
      database.snapshots <- snapshot :: database.snapshots;
      Ok (subscription, snapshot)))
;;

let activate_subscription (subscription : subscription) ~notify =
  Eio.Mutex.use_rw ~protect:true subscription.owner.lock (fun () ->
    if subscription.owner.closed
    then Error Types.Listen_database_closed
    else (
      match subscription.lifecycle, subscription.notify with
      | Unlistened, _ -> Error Types.Subscription_inactive
      | Active, Some _ -> Error Types.Subscription_already_active
      | Active, None ->
        subscription.notify <- Some notify;
        Eio.Fiber.fork_daemon ~sw:subscription.owner.sw (fun () ->
          let rec deliver () =
            match Eio.Stream.take subscription.events with
            | None -> ()
            | Some change ->
              let callback =
                Eio.Mutex.use_rw ~protect:true subscription.owner.lock (fun () ->
                  match subscription.lifecycle, subscription.notify with
                  | Active, Some callback ->
                    subscription.callback_running <- true;
                    Some callback
                  | Active, None | Unlistened, _ -> None)
              in
              Option.iter
                (fun callback ->
                   let finish_callback () =
                     let waiters =
                       Eio.Mutex.use_rw ~protect:true subscription.owner.lock (fun () ->
                         subscription.callback_running <- false;
                         let waiters = subscription.callback_waiters in
                         subscription.callback_waiters <- [];
                         waiters)
                     in
                     List.iter (fun resolve -> Eio.Promise.resolve resolve ()) waiters
                   in
                   Fun.protect ~finally:finish_callback (fun () ->
                     Eio.Fiber.with_binding
                       current_callback_subscription
                       subscription
                       (fun () ->
                          try callback change with
                          | _ -> ())))
                callback;
              if subscription.lifecycle = Active then deliver ()
          in
          deliver ();
          `Stop_daemon);
        Ok ()))
;;

let unlisten (subscription : subscription) =
  let self_unlisten =
    match Eio.Fiber.get current_callback_subscription with
    | Some current -> current == subscription
    | None -> false
  in
  let stopped, waiter =
    Eio.Mutex.use_rw ~protect:true subscription.owner.lock (fun () ->
      let stopped = subscription.lifecycle = Active in
      subscription.lifecycle <- Unlistened;
      subscription.notify <- None;
      let waiter =
        if subscription.callback_running && not self_unlisten
        then (
          let waiter, resolver = Eio.Promise.create () in
          subscription.callback_waiters <- resolver :: subscription.callback_waiters;
          Some waiter)
        else None
      in
      stopped, waiter)
  in
  if stopped
  then (
    while Option.is_some (Eio.Stream.take_nonblocking subscription.events) do
      ()
    done;
    Eio.Stream.add subscription.events None);
  Option.iter Eio.Promise.await waiter
;;

let duplicate_by equal values =
  let rec loop seen = function
    | [] -> None
    | value :: rest ->
      if List.exists (equal value) seen then Some value else loop (value :: seen) rest
  in
  loop [] values
;;

let equal_scope left right =
  match left, right with
  | Types.Children_revision left, Children_revision right -> Graph.Uuid.equal left right
  | Page_tree_revision left, Page_tree_revision right ->
    Graph.Uuid.equal left.page right.page && left.maximum_depth = right.maximum_depth
  | Journal_index_revision, Journal_index_revision -> true
  | _ -> false
;;

let write_precondition ~blocks ~pages ~scopes =
  match duplicate_by (fun (left, _) (right, _) -> Graph.Uuid.equal left right) blocks with
  | Some (uuid, _) -> Error (Types.Duplicate_block_precondition uuid)
  | None ->
    (match
       duplicate_by (fun (left, _) (right, _) -> Graph.Uuid.equal left right) pages
     with
     | Some (uuid, _) -> Error (Types.Duplicate_page_precondition uuid)
     | None ->
       (match
          duplicate_by (fun (left, _) (right, _) -> equal_scope left right) scopes
        with
        | Some (scope, _) -> Error (Types.Duplicate_scope_precondition scope)
        | None -> Ok { blocks; pages; scopes }))
;;

let mutation_id = Overlay_planner.mutation_id
let operation_of_mutation = Overlay_planner.operation

let uuid_lookup uuid =
  Datascript.Lookup_ref ("block/uuid", Datascript.Uuid (Graph.Uuid.to_string uuid))
;;

let uuid_temp prefix uuid = Datascript.Temp_id (prefix ^ ":" ^ Graph.Uuid.to_string uuid)

let local_operations
      ~fingerprint:_
      ~intent_time_ms
      ~next_tx
      ~sequence
      ~(effect_footprint : effect_footprint)
      ~delete_artifacts
      mutation
  =
  let now = Int64.to_int intent_time_ms in
  let operations =
    match mutation with
    | Types.Save_block { block; title; _ } ->
      let entity = uuid_lookup block in
      [ Datascript.Add (entity, "block/title", String title)
      ; Add (entity, "block/updated-at", Int now)
      ; Add (entity, "block/tx-id", Int next_tx)
      ]
    | Insert_blocks { tree; parent; _ } ->
      let page =
        match effect_footprint.page_uuids with
        | page :: _ -> page
        | [] -> parent
      in
      let page_ref = uuid_lookup page in
      let rec add_tree ~parent_ref ~order (tree : Types.block_tree) =
        let entity = uuid_temp "overlay-insert" tree.uuid in
        [ Datascript.Add (entity, "block/uuid", Uuid (Graph.Uuid.to_string tree.uuid))
        ; Add (entity, "block/title", String tree.title)
        ; Add (entity, "block/parent", Ref_to parent_ref)
        ; Add (entity, "block/page", Ref_to page_ref)
        ; Add (entity, "block/order", String order)
        ; Add (entity, "block/created-at", Int now)
        ; Add (entity, "block/updated-at", Int now)
        ; Add (entity, "block/tx-id", Int next_tx)
        ]
        @ (tree.children
           |> List.mapi (fun index child ->
             add_tree ~parent_ref:entity ~order:(Outliner_order.child ~index) child)
           |> List.concat)
      in
      add_tree
        ~parent_ref:(uuid_lookup parent)
        ~order:(Outliner_order.root ~sequence)
        tree
    | Delete_blocks _ ->
      let artifacts = Option.get delete_artifacts in
      let block_patch_operations patch =
        let entity = uuid_lookup patch.block_uuid in
        [ Datascript.RetractAttr (entity, "block/refs")
        ; Add (entity, "block/title", String patch.title)
        ; Add (entity, "block/updated-at", Int (Int64.to_int patch.updated_at_ms))
        ; Add (entity, "block/tx-id", Int next_tx)
        ]
        @ List.map
            (fun target ->
               Datascript.Add (entity, "block/refs", Ref_to (uuid_lookup target)))
            patch.refs
      in
      List.concat_map block_patch_operations artifacts.block_patches
      @ List.concat_map
          (fun patch ->
             let holder = uuid_lookup patch.holder_uuid in
             [ Datascript.RetractAttr (holder, patch.property_ident)
             ; Add
                 ( holder
                 , patch.property_ident
                 , Ref_to (uuid_lookup patch.replacement_uuid) )
             ; Add (holder, "block/updated-at", Int (Int64.to_int patch.updated_at_ms))
             ; Add (holder, "block/tx-id", Int next_tx)
             ])
          artifacts.property_patches
      @ List.map
          (fun uuid -> Datascript.RetractEntity (uuid_lookup uuid))
          artifacts.frontier
      @ List.map
          (fun patch ->
             Datascript.Add
               ( uuid_lookup patch.page_uuid
               , "block/updated-at"
               , Int (Int64.to_int patch.updated_at_ms) ))
          artifacts.page_patches
      @ List.map
          (fun patch ->
             Datascript.Add (uuid_lookup patch.page_uuid, "block/tx-id", Int next_tx))
          artifacts.page_patches
    | Create_journal_page { page; title; journal_day; _ } ->
      let entity = uuid_temp "overlay-page" page in
      [ Datascript.Add (entity, "block/uuid", Uuid (Graph.Uuid.to_string page))
      ; Add (entity, "block/title", String title)
      ; Add (entity, "block/name", String (String.lowercase_ascii title))
      ; Add (entity, "block/created-at", Int now)
      ; Add (entity, "block/updated-at", Int now)
      ; Add (entity, "block/journal-day", Int journal_day)
      ; Add (entity, "block/tx-id", Int next_tx)
      ]
    | Set_task_status { block; status; _ } ->
      [ Datascript.Add
          ( uuid_lookup block
          , "logseq.property/status"
          , Ref_to (Ident (status_ident status)) )
      ; Add (uuid_lookup block, "block/updated-at", Int now)
      ; Add (uuid_lookup block, "block/tx-id", Int next_tx)
      ]
    | Clear_task_status { block; _ } ->
      [ Datascript.RetractAttr (uuid_lookup block, "logseq.property/status")
      ; Add (uuid_lookup block, "block/updated-at", Int now)
      ; Add (uuid_lookup block, "block/tx-id", Int next_tx)
      ]
  in
  operations
;;

let normalized_transaction_in
      authoritative_database
      ~fingerprint
      ~intent_time_ms
      ~planned_tx
      ~sequence
      ~effect_footprint
      ~delete_artifacts
      mutation
  =
  local_operations
    ~fingerprint
    ~intent_time_ms
    ~next_tx:planned_tx
    ~sequence
    ~effect_footprint
    ~delete_artifacts
    mutation
  |> Sync_tx_codec.encode ~db:authoritative_database
  |> Result.get_ok
;;

let normalized_transaction database ~planned_tx =
  let authoritative_database = authoritative_database database in
  normalized_transaction_in authoritative_database ~planned_tx
;;

let fingerprint = Overlay_planner.fingerprint

let dependency_shadows_are_canonical mutation shadows =
  let find_block uuid =
    List.find_opt
      (fun shadow -> Graph.Uuid.equal shadow.shadow_block_uuid uuid)
      shadows.shadow_blocks
  in
  let find_page uuid =
    List.find_opt
      (fun shadow -> Graph.Uuid.equal shadow.shadow_page_uuid uuid)
      shadows.shadow_pages
  in
  let add_page pages uuid =
    if List.exists (Graph.Uuid.equal uuid) pages then pages else uuid :: pages
  in
  let rec add_block blocks pages uuid =
    if List.exists (Graph.Uuid.equal uuid) blocks
    then Some (blocks, pages)
    else (
      match find_block uuid with
      | None -> None
      | Some shadow ->
        let blocks = uuid :: blocks in
        let pages = add_page pages shadow.shadow_page in
        if
          Graph.Uuid.equal shadow.shadow_parent shadow.shadow_page
          || Graph.Uuid.equal shadow.shadow_parent shadow.shadow_block_uuid
        then Some (blocks, pages)
        else add_parent blocks pages shadow.shadow_parent)
  and add_parent blocks pages uuid =
    if
      List.exists (Graph.Uuid.equal uuid) blocks
      || List.exists (Graph.Uuid.equal uuid) pages
    then Some (blocks, pages)
    else (
      match find_block uuid, find_page uuid with
      | Some _, _ -> add_block blocks pages uuid
      | None, Some _ -> Some (blocks, uuid :: pages)
      | None, None -> None)
  in
  let expected =
    match mutation with
    | Types.Save_block { block; _ }
    | Set_task_status { block; _ }
    | Clear_task_status { block; _ } -> add_block [] [] block
    | Insert_blocks { parent; _ } -> add_parent [] [] parent
    | Delete_blocks _ | Create_journal_page _ -> Some ([], [])
  in
  let actual_blocks =
    List.map (fun shadow -> shadow.shadow_block_uuid) shadows.shadow_blocks
  in
  let actual_pages =
    List.map (fun shadow -> shadow.shadow_page_uuid) shadows.shadow_pages
  in
  match expected with
  | None -> false
  | Some (expected_blocks, expected_pages) ->
    List.sort_uniq Graph.Uuid.compare expected_blocks = actual_blocks
    && List.sort_uniq Graph.Uuid.compare expected_pages = actual_pages
;;

let outbox_record_is_canonical (record : outbox_record) =
  let submission_shape =
    match
      record.submission_t_before, record.submission_ordinal, record.submission_count
    with
    | None, None, None -> Some None
    | Some t_before, Some ordinal, Some count when count > 0 && ordinal < count ->
      Some (Some (cursor_value t_before + ordinal + 1))
    | _ -> None
  in
  let origin_is_canonical =
    match submission_shape, record.observed_origin_cursor with
    | Some None, None -> true
    | Some (Some expected), Some observed -> cursor_value observed = expected
    | Some (Some _), None -> true
    | None, _ | Some None, Some _ -> false
  in
  let transport_is_canonical =
    match record.transport_state, submission_shape with
    | Types.Queued, Some None ->
      Option.is_none record.protected_transaction
      && Option.is_none record.acceptance_barrier
      && Option.is_none record.blocked_prior_state
      && Option.is_none record.blocked_reason
    | Submitted _, Some (Some _) ->
      Option.is_some record.protected_transaction
      && Option.is_none record.acceptance_barrier
      && Option.is_none record.blocked_prior_state
      && Option.is_none record.blocked_reason
    | Accepted_pending_authoritative _, Some (Some _) ->
      Option.is_some record.protected_transaction
      && Option.is_some record.acceptance_barrier
      && Option.is_none record.blocked_prior_state
      && Option.is_none record.blocked_reason
    | Delete_barrier_rejected_pending_authoritative _, Some (Some _) ->
      Option.is_some record.protected_transaction
      && Option.is_none record.acceptance_barrier
      && Option.is_none record.blocked_prior_state
      && Option.is_none record.blocked_reason
    | Blocked, Some _ ->
      Option.is_some record.blocked_prior_state && Option.is_some record.blocked_reason
    | ( ( Queued
        | Submitted _
        | Accepted_pending_authoritative _
        | Delete_barrier_rejected_pending_authoritative _
        | Blocked )
      , _ ) -> false
  in
  let dependency_shadows_are_state_canonical =
    match record.transport_state with
    | Types.Queued | Blocked -> record.dependency_shadows = empty_dependency_shadows
    | Submitted _
    | Accepted_pending_authoritative _
    | Delete_barrier_rejected_pending_authoritative _ ->
      dependency_shadows_are_canonical record.mutation record.dependency_shadows
  in
  Result.is_ok (Sync_tx_codec.protected_values record.normalized_transaction)
  && String.equal record.fingerprint (fingerprint record.mutation)
  && Graph.Uuid.equal record.mutation_id (mutation_id record.mutation)
  && origin_is_canonical
  && transport_is_canonical
  && dependency_shadows_are_state_canonical
  && record.dependency_shadows.shadow_blocks
     = List.sort_uniq
         (fun left right ->
            Graph.Uuid.compare left.shadow_block_uuid right.shadow_block_uuid)
         record.dependency_shadows.shadow_blocks
  && record.dependency_shadows.shadow_pages
     = List.sort_uniq
         (fun left right ->
            Graph.Uuid.compare left.shadow_page_uuid right.shadow_page_uuid)
         record.dependency_shadows.shadow_pages
  &&
  match record.mutation, record.delete_artifacts with
  | Types.Delete_blocks { root; _ }, Some artifacts ->
    ((List.exists (Graph.Uuid.equal root) artifacts.frontier
      && Option.is_none artifacts.property_guard)
     || (artifacts.frontier = [] && Option.is_some artifacts.property_guard))
    && artifacts.frontier = List.sort_uniq Graph.Uuid.compare artifacts.frontier
    && artifacts.property_patches
       = List.sort_uniq
           (fun (left : delete_property_patch) right ->
              Graph.Uuid.compare left.holder_uuid right.holder_uuid)
           artifacts.property_patches
    &&
      (match artifacts.property_guard with
      | None -> artifacts.property_patches = []
      | Some guard ->
        List.for_all
          (fun (patch : delete_property_patch) ->
             String.equal patch.property_ident guard.property_ident
             && Graph.Uuid.equal patch.replacement_uuid guard.replacement_uuid)
          artifacts.property_patches)
  | Delete_blocks _, None -> false
  | ( ( Save_block _
      | Insert_blocks _
      | Create_journal_page _
      | Set_task_status _
      | Clear_task_status _ )
    , None ) -> true
  | ( ( Save_block _
      | Insert_blocks _
      | Create_journal_page _
      | Set_task_status _
      | Clear_task_status _ )
    , Some _ ) -> false
;;

let find_receipt database id =
  match
    List.find_opt
      (fun (candidate, _, _) -> Graph.Uuid.equal id candidate)
      database.receipts
  with
  | Some _ as receipt -> receipt
  | None ->
    Result.to_option (read_durable_receipt database.database_path id) |> Option.join
;;

let duplicate_commit database commit =
  let revision = projection_revision database.projection in
  { commit with
    Types.status = Already_applied
  ; before_projection_revision = revision
  ; after_projection_revision = revision
  ; logical_change_summary = Types.No_logical_change
  }
;;

let active_duplicate_commit database (record : outbox_record) =
  let revision = projection_revision database.projection in
  { Types.mutation_id = record.mutation_id
  ; status = Already_applied
  ; generation = database.generation
  ; before_projection_revision = revision
  ; after_projection_revision = revision
  ; logical_change_summary = No_logical_change
  }
;;

let typed_mutation_fingerprint value =
  token Types.Mutation_fingerprint.of_string ("mutation-fingerprint:v1:" ^ value)
;;

let remote_won_before_submission
      ?(conflict_kinds = [ Types.Frontier_fact_changed ])
      (record : outbox_record)
  =
  let fingerprint = typed_mutation_fingerprint record.fingerprint in
  let conflicts = Types.delete_conflict_kind_set conflict_kinds |> Result.get_ok in
  let proof =
    Types.remote_won_proof
      ~reason:Before_submission
      ~batch_id:None
      ~t_before:None
      ~rejection_through:None
      ~earliest_conflict_cursor:None
      ~operation:Delete_blocks_operation
      ~digest:fingerprint
    |> Result.get_ok
  in
  Types.
    { mutation_id = record.mutation_id
    ; fingerprint
    ; reason = Before_submission
    ; conflicts
    ; proof
    }
;;

let remote_won_proven_unexecuted
      ?rejection_through
      ?(conflict_kinds = [ Types.Frontier_fact_changed ])
      (record : outbox_record)
      ~batch_id
      ~earliest_conflict_cursor
  =
  let fingerprint = typed_mutation_fingerprint record.fingerprint in
  let conflicts = Types.delete_conflict_kind_set conflict_kinds |> Result.get_ok in
  let proof =
    Types.remote_won_proof
      ~reason:Types.Proven_unexecuted
      ~batch_id:(Some batch_id)
      ~t_before:record.submission_t_before
      ~rejection_through
      ~earliest_conflict_cursor:(Some earliest_conflict_cursor)
      ~operation:Types.Delete_blocks_operation
      ~digest:fingerprint
    |> Result.get_ok
  in
  Types.
    { mutation_id = record.mutation_id
    ; fingerprint
    ; reason = Proven_unexecuted
    ; conflicts
    ; proof
    }
;;

let existing_mutation database id fingerprint =
  match
    List.find_opt
      (fun (record : outbox_record) -> Graph.Uuid.equal id record.mutation_id)
      database.outbox
  with
  | Some record when not (String.equal record.fingerprint fingerprint) -> Error ()
  | Some { transport_state = Types.Blocked; _ } as blocked ->
    let record = Option.get blocked in
    (match record.blocked_prior_state, record.blocked_reason with
     | Some prior_transport_state, Some reason ->
       Ok
         (Some
            (Types.Existing_blocked
               { mutation_id = record.mutation_id
               ; fingerprint = typed_mutation_fingerprint record.fingerprint
               ; prior_transport_state
               ; reason
               ; same_id_retry_eligible = record.same_id_retry_eligible
               }))
     | _ -> Error ())
  | Some record ->
    Ok (Some (Types.Existing_applied (active_duplicate_commit database record)))
  | None ->
    (match find_receipt database id with
     | None -> Ok None
     | Some (_, existing_fingerprint, _)
       when not (String.equal existing_fingerprint fingerprint) -> Error ()
     | Some (_, _, Commit_receipt commit) ->
       Ok (Some (Types.Existing_applied (duplicate_commit database commit)))
     | Some (_, _, Discarded_receipt (commit, _)) ->
       Ok (Some (Types.Existing_discarded commit))
     | Some (_, _, Remote_won_entry receipt) ->
       Ok (Some (Types.Existing_remote_won receipt)))
;;

let has_block_precondition (expected : write_precondition) uuid =
  Outliner.Planner_contract.contains_uuid uuid expected.blocks
;;

let has_page_precondition (expected : write_precondition) uuid =
  Outliner.Planner_contract.contains_uuid uuid expected.pages
;;

let has_children_precondition (expected : write_precondition) parent =
  Outliner.Planner_contract.contains_children_scope parent expected.scopes
;;

let has_delete_structure_precondition database (expected : write_precondition) root =
  let snapshot = snapshot_of_database database in
  match logical_block_at snapshot root with
  | None -> Ok ()
  | Some (record : Types.block_record) ->
    let parent = record.block.parent in
    let page = record.block.page in
    let found =
      List.exists
        (fun (scope, _) ->
           match scope with
           | Types.Children_revision candidate -> Graph.Uuid.equal candidate parent
           | Page_tree_revision { page = candidate; _ } -> Graph.Uuid.equal candidate page
           | Journal_index_revision -> false)
        expected.scopes
    in
    if found
    then Ok ()
    else
      Error
        (Types.Missing_precondition
           (Some (Types.Page_tree_revision { page; maximum_depth = 1 })))
;;

let required_preconditions database (expected : write_precondition) = function
  | Types.Save_block { block; _ }
  | Set_task_status { block; _ }
  | Clear_task_status { block; _ } ->
    if has_block_precondition expected block
    then Ok ()
    else Error (Types.Missing_precondition None)
  | Delete_blocks { root; _ } ->
    if not (has_block_precondition expected root)
    then Error (Types.Missing_precondition None)
    else has_delete_structure_precondition database expected root
  | Insert_blocks { parent; _ } ->
    if
      (has_page_precondition expected parent || has_block_precondition expected parent)
      && has_children_precondition expected parent
    then Ok ()
    else Error (Types.Missing_precondition (Some (Types.Children_revision parent)))
  | Create_journal_page { page; _ } ->
    if has_page_precondition expected page
    then Ok ()
    else Error (Types.Missing_precondition None)
;;

let current_block_revision database uuid =
  let value = logical_block_at (snapshot_of_database database) uuid in
  logical_block_revision uuid value
;;

let current_page_revision database uuid =
  let value = logical_page_at (snapshot_of_database database) uuid in
  logical_page_revision uuid value
;;

let current_scope_revision database scope =
  revision_for_scope (snapshot_of_database database) scope
;;

let preconditions_match database (expected : write_precondition) =
  List.for_all
    (fun (uuid, revision) ->
       Types.Block_state_revision.equal revision (current_block_revision database uuid))
    expected.blocks
  && List.for_all
       (fun (uuid, revision) ->
          Types.Page_state_revision.equal revision (current_page_revision database uuid))
       expected.pages
  && List.for_all
       (fun (scope, revision) ->
          Types.Scope_revision.equal revision (current_scope_revision database scope))
       expected.scopes
;;

let tree_uuids = Outliner.Tree.uuids
let replace_all = Outliner.References.replace_all

let hard_delete_artifacts database ~now root =
  let snapshot = snapshot_of_database database in
  let authoritative = authoritative_database database in
  let rec subtree parent =
    child_items snapshot parent
    |> List.concat_map (fun (child : Types.child_member) ->
      child.block.block.uuid :: subtree child.block.block.uuid)
  in
  let initial_frontier = root :: subtree root |> List.sort_uniq Graph.Uuid.compare in
  let frontier_entities =
    List.filter_map
      (fun uuid ->
         Option.map (fun entity -> uuid, entity) (entity_of_uuid authoritative uuid))
      initial_frontier
  in
  let initial_entity_ids = List.map snd frontier_entities |> List.sort_uniq Int.compare in
  let comment_sources =
    initial_entity_ids
    |> List.concat_map (fun target ->
      Datascript.datoms
        authoritative
        Datascript.Avet
        ~a:"logseq.property.comments/blocks"
        ~v:(Datascript.Ref target)
        ()
      |> List.of_seq
      |> List.map (fun (datom : Datascript.datom) -> datom.e))
    |> List.sort_uniq Int.compare
  in
  let is_comments_area entity =
    values authoritative entity "block/tags"
    |> List.exists (function
      | Datascript.Ref tag ->
        (match one authoritative tag "db/ident" with
         | Some (Keyword "logseq.class/Comments" | String "logseq.class/Comments") -> true
         | Some _ | None -> false)
      | _ -> false)
  in
  let is_orphaned_comment_area entity =
    let targets =
      values authoritative entity "logseq.property.comments/blocks"
      |> List.filter_map reference_of_value
    in
    targets <> []
    && is_comments_area entity
    && List.for_all (fun target -> List.mem target initial_entity_ids) targets
  in
  let comment_frontier =
    comment_sources
    |> List.filter is_orphaned_comment_area
    |> List.filter_map (uuid_of_entity authoritative)
    |> List.concat_map (fun uuid -> uuid :: subtree uuid)
  in
  let frontier =
    List.sort_uniq Graph.Uuid.compare (initial_frontier @ comment_frontier)
  in
  let frontier_entities =
    List.filter_map
      (fun uuid ->
         Option.map (fun entity -> uuid, entity) (entity_of_uuid authoritative uuid))
      frontier
  in
  let incoming_source_entities =
    frontier_entities
    |> List.concat_map (fun (_, target) ->
      Datascript.datoms
        authoritative
        Datascript.Avet
        ~a:"block/refs"
        ~v:(Datascript.Ref target)
        ()
      |> List.of_seq
      |> List.map (fun (datom : Datascript.datom) -> datom.e))
    |> List.sort_uniq Int.compare
  in
  let frontier_contains uuid = List.exists (Graph.Uuid.equal uuid) frontier in
  let target_title uuid =
    logical_block_at snapshot uuid
    |> Option.map (fun (record : Types.block_record) -> record.block.title)
    |> Option.value ~default:""
  in
  let rewrite_title title target =
    let uuid = Graph.Uuid.to_string target in
    title
    |> fun title ->
    replace_all title ("[[" ^ uuid ^ "]]") (target_title target)
    |> fun title -> replace_all title ("((" ^ uuid ^ "))") (target_title target)
  in
  let block_patches =
    incoming_source_entities
    |> List.filter_map (fun entity ->
      Option.bind (uuid_of_entity authoritative entity) (fun block_uuid ->
        if frontier_contains block_uuid
        then None
        else
          Option.map
            (fun (record : Types.block_record) ->
               let removed = List.filter frontier_contains record.block.refs in
               let refs =
                 List.filter (fun uuid -> not (frontier_contains uuid)) record.block.refs
               in
               let title = List.fold_left rewrite_title record.block.title removed in
               { block_uuid; title; refs; updated_at_ms = now })
            (logical_block_at snapshot block_uuid)))
    |> List.sort_uniq (fun left right ->
      Graph.Uuid.compare left.block_uuid right.block_uuid)
  in
  let touched_pages =
    let records =
      frontier @ List.map (fun patch -> patch.block_uuid) block_patches
      |> List.filter_map (logical_block_at snapshot)
    in
    records
    |> List.map (fun (record : Types.block_record) -> record.block.page)
    |> List.sort_uniq Graph.Uuid.compare
  in
  let page_patches =
    List.map (fun page_uuid -> { page_uuid; updated_at_ms = now }) touched_pages
  in
  { frontier; block_patches; page_patches; property_guard = None; property_patches = [] }
;;

let default_property_delete_artifacts database ~now root =
  let authoritative = authoritative_database database in
  match entity_of_uuid authoritative root with
  | None -> Ok None
  | Some root_entity ->
    (match
       ( Option.bind
           (one authoritative root_entity "logseq.property/created-from-property")
           reference_of_value
       , values authoritative root_entity "block/closed-value-property" )
     with
     | Some property_entity, [] ->
       (match
          ( Option.bind
              (one authoritative property_entity "logseq.property/default-value")
              reference_of_value
          , Option.bind (one authoritative property_entity "db/ident") ident_of_value
          , entity_of_ident authoritative "logseq.property/empty-placeholder" )
        with
        | Some default_entity, Some property_ident, Some placeholder_entity
          when default_entity <> root_entity ->
          (match
             ( uuid_of_entity authoritative property_entity
             , uuid_of_entity authoritative placeholder_entity )
           with
           | Some property_uuid, Some replacement_uuid ->
             let holder_entities =
               Datascript.datoms authoritative Datascript.Aevt ~a:property_ident ()
               |> Seq.filter_map (fun (datom : Datascript.datom) ->
                 match datom.v with
                 | Datascript.Ref entity when entity = root_entity -> Some datom.e
                 | _ -> None)
               |> List.of_seq
               |> List.sort_uniq Int.compare
             in
             let rec collect_holders reversed = function
               | [] -> Ok (List.rev reversed)
               | holder :: rest ->
                 (match uuid_of_entity authoritative holder with
                  | None -> Error Types.Delete_unsupported_for_footprint
                  | Some holder_uuid ->
                    collect_holders
                      ({ holder_uuid
                       ; property_ident
                       ; replacement_uuid
                       ; updated_at_ms = now
                       }
                       :: reversed)
                      rest)
             in
             Result.bind (collect_holders [] holder_entities) (fun holders ->
               let rec collect_pages reversed = function
                 | [] -> Ok (List.sort_uniq Graph.Uuid.compare reversed)
                 | patch :: rest ->
                   (match entity_of_uuid authoritative patch.holder_uuid with
                    | None -> Error Types.Delete_unsupported_for_footprint
                    | Some holder
                      when Option.is_some (one authoritative holder "block/name") ->
                      collect_pages (patch.holder_uuid :: reversed) rest
                    | Some holder ->
                      (match
                         Option.bind
                           (Option.bind
                              (one authoritative holder "block/page")
                              reference_of_value)
                           (uuid_of_entity authoritative)
                       with
                       | None -> Error Types.Delete_unsupported_for_footprint
                       | Some page_uuid -> collect_pages (page_uuid :: reversed) rest))
               in
               Result.map
                 (fun holder_pages ->
                    Some
                      { frontier = []
                      ; block_patches = []
                      ; page_patches =
                          List.map
                            (fun page_uuid -> { page_uuid; updated_at_ms = now })
                            holder_pages
                      ; property_guard =
                          Some { property_uuid; property_ident; replacement_uuid }
                      ; property_patches = holders
                      })
                 (collect_pages [] holders))
           | None, _ | _, None -> Error Types.Delete_unsupported_for_footprint)
        | Some default_entity, _, _ when default_entity = root_entity -> Ok None
        | _ -> Error Types.Delete_unsupported_for_footprint)
     | Some _, _ :: _ | None, _ -> Ok None)
;;

let delete_artifacts database ~now root =
  Result.map
    (Option.value ~default:(hard_delete_artifacts database ~now root))
    (default_property_delete_artifacts database ~now root)
;;

let planned_effect database ~now = function
  | Types.Save_block { block; _ }
  | Set_task_status { block; _ }
  | Clear_task_status { block; _ } ->
    Ok ({ block_uuids = [ block ]; page_uuids = []; structure_interests = [] }, None)
  | Insert_blocks { tree; parent; _ } ->
    let snapshot = snapshot_of_database database in
    let page =
      Outliner.Graph_read.page_for_parent ~parent (logical_block_at snapshot parent)
    in
    Ok
      ( { block_uuids = tree_uuids tree
        ; page_uuids = [ page ]
        ; structure_interests =
            [ Types.Children_interest parent; Types.Page_tree_interest page ]
        }
      , None )
  | Delete_blocks { root; _ } ->
    let snapshot = snapshot_of_database database in
    (match logical_block_at snapshot root with
     | None ->
       let artifacts =
         { frontier = [ root ]
         ; block_patches = []
         ; page_patches = []
         ; property_guard = None
         ; property_patches = []
         }
       in
       Ok
         ( { block_uuids = [ root ]; page_uuids = []; structure_interests = [] }
         , Some artifacts )
     | Some _ ->
       Result.map
         (fun artifacts ->
            let records =
              (root :: artifacts.frontier)
              @ List.map (fun patch -> patch.holder_uuid) artifacts.property_patches
              |> List.filter_map (logical_block_at snapshot)
            in
            let parents =
              records
              |> List.map (fun (record : Types.block_record) -> record.block.parent)
              |> List.sort_uniq Graph.Uuid.compare
            in
            let pages =
              List.map (fun patch -> patch.page_uuid) artifacts.page_patches
              |> List.sort_uniq Graph.Uuid.compare
            in
            ( { block_uuids =
                  List.sort_uniq
                    Graph.Uuid.compare
                    (artifacts.frontier
                     @ [ root ]
                     @ List.map (fun patch -> patch.block_uuid) artifacts.block_patches
                     @ List.map
                         (fun patch -> patch.holder_uuid)
                         artifacts.property_patches)
              ; page_uuids = pages
              ; structure_interests =
                  List.map (fun parent -> Types.Children_interest parent) parents
                  @ List.map (fun page -> Types.Page_tree_interest page) pages
              }
            , Some artifacts ))
         (delete_artifacts database ~now root))
  | Create_journal_page { page; _ } ->
    Ok
      ( { block_uuids = []
        ; page_uuids = [ page ]
        ; structure_interests = [ Types.Journal_index_interest ]
        }
      , None )
;;

let dependency_shadows_for_snapshot snapshot mutation =
  let shadow_blocks = ref [] in
  let shadow_pages = ref [] in
  let add_page uuid =
    if
      not
        (List.exists
           (fun shadow -> Graph.Uuid.equal shadow.shadow_page_uuid uuid)
           !shadow_pages)
    then (
      match logical_page_at snapshot uuid with
      | None -> ()
      | Some (record : Types.page_record) ->
        shadow_pages
        := { shadow_page_uuid = record.page.uuid
           ; shadow_name = record.page.name
           ; shadow_page_title = record.page.title
           ; shadow_page_kind = record.page.kind
           ; shadow_page_created_at_ms = record.page.created_at_ms
           ; shadow_page_updated_at_ms = record.page.updated_at_ms
           ; shadow_recycled = record.page.recycled
           }
           :: !shadow_pages)
  in
  let rec add_block uuid =
    if
      not
        (List.exists
           (fun shadow -> Graph.Uuid.equal shadow.shadow_block_uuid uuid)
           !shadow_blocks)
    then (
      match logical_block_at snapshot uuid with
      | None -> add_page uuid
      | Some (record : Types.block_record) ->
        shadow_blocks
        := { shadow_block_uuid = record.block.uuid
           ; shadow_title = record.block.title
           ; shadow_parent = record.block.parent
           ; shadow_page = record.block.page
           ; shadow_order = record.block.order
           ; shadow_created_at_ms = record.block.created_at_ms
           ; shadow_updated_at_ms = record.block.updated_at_ms
           ; shadow_task_status = record.task_status
           }
           :: !shadow_blocks;
        add_page record.block.page;
        if
          (not (Graph.Uuid.equal record.block.parent record.block.uuid))
          && not (Graph.Uuid.equal record.block.parent record.block.page)
        then add_block record.block.parent)
  in
  (match mutation with
   | Types.Save_block { block; _ }
   | Set_task_status { block; _ }
   | Clear_task_status { block; _ } -> add_block block
   | Insert_blocks { parent; _ } -> add_block parent
   | Delete_blocks _ | Create_journal_page _ -> ());
  { shadow_blocks =
      List.sort
        (fun left right ->
           Graph.Uuid.compare left.shadow_block_uuid right.shadow_block_uuid)
        !shadow_blocks
  ; shadow_pages =
      List.sort
        (fun left right ->
           Graph.Uuid.compare left.shadow_page_uuid right.shadow_page_uuid)
        !shadow_pages
  }
;;

let dependency_shadows_for database mutation =
  dependency_shadows_for_snapshot (snapshot_of_database database) mutation
;;

let local_candidate_record
      database
      ~fingerprint
      ~effect_footprint
      ~delete_artifacts
      ~intent_time_ms
      mutation
  =
  let mutation_id = mutation_id mutation in
  let sequence =
    List.fold_left
      (fun maximum (record : outbox_record) -> Int.max maximum record.sequence)
      0
      database.outbox
    + 1
  in
  let planned_tx = (authoritative_database database).Datascript.max_tx + 1 in
  { mutation_id
  ; fingerprint
  ; mutation
  ; normalized_transaction =
      normalized_transaction
        database
        ~fingerprint
        ~intent_time_ms
        ~planned_tx
        ~sequence
        ~effect_footprint
        ~delete_artifacts
        mutation
  ; dependency_shadows = empty_dependency_shadows
  ; effect_footprint
  ; delete_artifacts
  ; intent_time_ms
  ; planned_tx
  ; sequence
  ; transport_state = Types.Queued
  ; protected_transaction = None
  ; attempt_count = 0
  ; blocked_prior_state = None
  ; blocked_reason = None
  ; same_id_retry_eligible = false
  ; acceptance_barrier = None
  ; submission_t_before = None
  ; submission_ordinal = None
  ; submission_count = None
  ; observed_origin_cursor = None
  ; stale_earliest_conflict_cursor = None
  ; stale_conflicts = []
  }
;;

let outbox_records_fit database ~sync_revision records =
  List.length records <= database.dependencies.limits.outbox_max_records
  && records
     |> List.fold_left
          (fun bytes record ->
             bytes + String.length (Persistence_outbox_v14.encode ~sync_revision record))
          0
     |> fun bytes -> bytes <= database.dependencies.limits.outbox_max_bytes
;;

let local_candidate_fits database candidate =
  outbox_records_fit
    database
    ~sync_revision:(database.sync_revision + 1)
    (database.outbox @ [ candidate ])
;;

let change_for_effect (footprint : effect_footprint) =
  Logical_change.footprint_members footprint
;;

let bounded_logical_summary database ~block_uuids ~page_uuids ~structure_interests =
  Logical_change.bounded_summary
    ~maximum_items:database.dependencies.limits.change_max_items
    ~maximum_bytes:database.dependencies.limits.change_max_bytes
    ~block_uuids
    ~page_uuids
    ~structure_interests
;;

let logical_change_for_effects database ~before ~after effects =
  let block_candidates, page_candidates, structure_interests =
    List.fold_left
      (fun (blocks, pages, interests) footprint ->
         let footprint : effect_footprint = footprint in
         ( footprint.block_uuids @ blocks
         , footprint.page_uuids @ pages
         , footprint.structure_interests @ interests ))
      ([], [], [])
      effects
  in
  let block_uuids =
    block_candidates
    |> List.sort_uniq Graph.Uuid.compare
    |> List.filter (fun uuid ->
      logical_block_at before uuid <> logical_block_at after uuid)
  in
  let page_uuids =
    page_candidates
    |> List.sort_uniq Graph.Uuid.compare
    |> List.filter (fun uuid -> logical_page_at before uuid <> logical_page_at after uuid)
  in
  if block_uuids = [] && page_uuids = []
  then Types.No_logical_change
  else
    bounded_logical_summary
      database
      ~block_uuids
      ~page_uuids
      ~structure_interests:(List.sort_uniq compare structure_interests)
;;

let mutation_has_logical_effect database ~now mutation =
  ignore now;
  let snapshot = snapshot_of_database database in
  match mutation with
  | Types.Save_block { block; _ }
  | Set_task_status { block; _ }
  | Clear_task_status { block; _ } -> Option.is_some (logical_block_at snapshot block)
  | Delete_blocks { root; _ } -> Option.is_some (logical_block_at snapshot root)
  | Insert_blocks _ | Create_journal_page _ -> true
;;

let open_owned ~sw dependencies inspection ~graph_name ownership =
  let current_generation = fresh_generation dependencies.monotonic_ns in
  let path = inspection.location.database_path in
  if not (Sys.file_exists path)
  then Error Types.Attachment_stale
  else (
    match read_outbox path, validate_durable_receipts path with
    | Error message, _ -> Error (Types.Corrupt_outbox message)
    | _, Error message -> Error (Types.Corrupt_mutation_receipt message)
    | Ok encoded, Ok () ->
      (match decode_outbox encoded with
       | Error message -> Error (Types.Corrupt_outbox message)
       | Ok (outbox, _)
         when List.exists (fun record -> not (outbox_record_is_canonical record)) outbox
         -> Error (Types.Corrupt_outbox "non-canonical overlay outbox record")
       | Ok (outbox, sync_revision) ->
         (match Storage.open_database path with
          | Error _ -> Error (Types.Restore_failed "unable to open mirror")
          | Ok connection ->
            let callbacks = Storage.connection_callbacks connection in
            let transferred = ref false in
            let installed_listener = ref None in
            Fun.protect
              ~finally:(fun () ->
                if not !transferred
                then (
                  Option.iter
                    (fun (connection, listener) ->
                       Datascript.unlisten connection listener)
                    !installed_listener;
                  ignore (Storage.close callbacks)))
              (fun () ->
                 match Storage.restore_database connection with
                 | Error _ ->
                   Error (Types.Restore_failed "unable to restore authoritative database")
                 | Ok authoritative_database ->
                   let authoritative_connection =
                     Datascript.Conn.from_db
                       { empty_db = Datascript.empty_db
                       ; init_db = Datascript.init_db
                       ; store = (fun ?storage:_ _ -> ())
                       }
                       authoritative_database
                   in
                   let authoritative_reports = ref [] in
                   let authoritative_listener =
                     Datascript.listen
                       authoritative_connection
                       "logseq-overlay-authoritative"
                       (fun report ->
                          authoritative_reports := report :: !authoritative_reports)
                   in
                   installed_listener
                   := Some (authoritative_connection, authoritative_listener);
                   let storage_session =
                     Logseq_db_storage.Storage_session.create
                       ~tail:
                         (Datascript.Storage.restore_tail_groups
                            (Storage.datascript_storage connection))
                       ~callbacks
                   in
                   let release_slot = ref None in
                   let checkpoint_metadata =
                     Storage.sync_metadata connection |> Result.get_ok
                   in
                   let checkpoint =
                     match inspection.presence with
                     | Types.Available { checkpoint; _ } ->
                       Types.Server_cursor.to_string checkpoint
                       |> String.split_on_char ':'
                       |> List.rev
                       |> List.hd
                       |> int_of_string
                     | Absent _ -> 0
                   in
                   let ( queryable_outbox
                       , queryable_block_effects
                       , queryable_page_effects
                       , queryable_children_effects )
                     =
                     queryable_outbox_root outbox
                   in
                   let database =
                     { lock = Eio.Mutex.create ()
                     ; notification_lock = Eio.Mutex.create ()
                     ; sw
                     ; dispatch_stream =
                         Eio.Stream.create dependencies.limits.dispatcher_capacity
                     ; dispatch_slots =
                         Eio.Semaphore.make dependencies.limits.dispatcher_capacity
                     ; dependencies
                     ; database_path = path
                     ; graph_uuid = inspection.location.graph_id
                     ; graph_name
                     ; schema = Graph.{ major = 65; minor = 33 }
                     ; admission_facts =
                         [ Graph.Remote_flag_true
                         ; Synced_graph_identity inspection.location.graph_id
                         ; Lossless_codec
                         ; Ownership_verified
                         ]
                     ; storage_session
                     ; ownership
                     ; release_slot
                     ; closed = false
                     ; generation = current_generation
                     ; projection = 0
                     ; authoritative_connection
                     ; authoritative_listener
                     ; authoritative_reports
                     ; receipts = []
                     ; outbox
                     ; queryable_outbox
                     ; queryable_block_effects
                     ; queryable_page_effects
                     ; queryable_children_effects
                     ; sync_revision
                     ; checkpoint
                     ; checkpoint_metadata
                     ; subscriptions = []
                     ; snapshots = []
                     }
                   in
                   release_slot := Some database;
                   Eio.Switch.on_release sw (fun () ->
                     match !release_slot with
                     | None -> ()
                     | Some database -> ignore (close database));
                   Eio.Fiber.fork_daemon ~sw (fun () ->
                     let rec dispatch () =
                       match Eio.Stream.take database.dispatch_stream with
                       | Stop_dispatch -> ()
                       | Dispatch_change (change, queued) ->
                         Eio.Semaphore.release database.dispatch_slots;
                         let subscriptions =
                           Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
                             List.filter
                               (fun (subscription : subscription) ->
                                  subscription.lifecycle = Active)
                               database.subscriptions)
                         in
                         let after_revision =
                           match change with
                           | Types.Exact { after_revision; _ }
                           | Projection_resync_required { after_revision; _ } ->
                             after_revision
                         in
                         List.iter
                           (fun (subscription : subscription) ->
                              if
                                Eio.Stream.length subscription.events
                                >= dependencies.limits.dispatcher_capacity
                              then (
                                while
                                  Option.is_some
                                    (Eio.Stream.take_nonblocking subscription.events)
                                do
                                  ()
                                done;
                                Eio.Stream.add
                                  subscription.events
                                  (Some
                                     (Types.Projection_resync_required
                                        { generation = database.generation
                                        ; after_revision
                                        ; reason = Dispatcher_retention_exceeded
                                        })))
                              else Eio.Stream.add subscription.events (Some change))
                           subscriptions;
                         Eio.Promise.resolve queued ();
                         dispatch ()
                     in
                     dispatch ();
                     `Stop_daemon);
                   transferred := true;
                   installed_listener := None;
                   Ok database))))
;;

let open_ ~sw dependencies inspection ~graph_name =
  if String.trim graph_name = ""
  then Error Types.Invalid_graph_name
  else (
    match inspection.presence with
    | Types.Absent _ -> Error Types.Mirror_absent
    | Types.Available _ ->
      let graph_directory = Filename.dirname inspection.location.database_path in
      (match Ownership.acquire ~graph_directory with
       | Error Ownership.Already_owned -> Error Types.Ownership_conflict
       | Error (Unavailable message) -> Error (Types.Open_resource_failed message)
       | Ok ownership ->
         let generation_matches =
           match inspection.presence, inspect_durable_mirror inspection.location with
           | ( Types.Available { generation = expected; _ }
             , Ok { presence = Available { generation = current; _ }; _ } ) ->
             Types.Mirror_generation.equal expected current
           | _ -> false
         in
         (match
            if generation_matches
            then open_owned ~sw dependencies inspection ~graph_name ownership
            else Error Types.Attachment_stale
          with
          | Ok _ as opened -> opened
          | Error _ as error ->
            ignore (Ownership.release ownership);
            error
          | exception exn ->
            ignore (Ownership.release ownership);
            Error (Types.Open_resource_failed (Printexc.to_string exn)))))
;;

let persist_outbox ?(terminal_batches = []) database =
  let records =
    List.map
      (Persistence_outbox_v14.encode ~sync_revision:database.sync_revision)
      database.outbox
  in
  let receipts =
    List.filter_map Persistence_receipt_v1.encode_mutation database.receipts
  in
  let terminal_batches =
    List.map Persistence_receipt_v1.encode_terminal_batch terminal_batches
  in
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database.database_path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       let rc_result rc =
         if Sqlite3.Rc.is_success rc then Ok () else Error (Sqlite3.errmsg sqlite)
       in
       Result.bind
         (rc_result (Sqlite3.exec sqlite "BEGIN IMMEDIATE"))
         (fun () ->
            let rollback message =
              ignore (Sqlite3.exec sqlite "ROLLBACK");
              Error message
            in
            match Logseq_db_storage.Sync_outbox_store.replace_database sqlite records with
            | Error message -> rollback message
            | Ok () ->
              (match
                 Logseq_db_storage.Mutation_receipt_store.upsert_mutations sqlite receipts
               with
               | Error message -> rollback message
               | Ok () ->
                 (match
                    Logseq_db_storage.Mutation_receipt_store.upsert_terminal_batches
                      sqlite
                      terminal_batches
                  with
                  | Error message -> rollback message
                  | Ok () ->
                    (match rc_result (Sqlite3.exec sqlite "COMMIT") with
                     | Ok () -> Ok ()
                     | Error message -> rollback message)))))
;;

let serialize_commit database operation =
  Eio.Mutex.use_rw ~protect:true database.notification_lock (fun () ->
    Eio.Semaphore.acquire database.dispatch_slots;
    let owns_reservation = ref true in
    Fun.protect
      ~finally:(fun () ->
        if !owns_reservation then Eio.Semaphore.release database.dispatch_slots)
      (fun () ->
         let change, outcome = operation () in
         (match change with
          | None ->
            Eio.Semaphore.release database.dispatch_slots;
            owns_reservation := false
          | Some change ->
            let queued, resolve_queued = Eio.Promise.create () in
            Eio.Stream.add
              database.dispatch_stream
              (Dispatch_change (change, resolve_queued));
            owns_reservation := false;
            Eio.Promise.await queued);
         outcome))
;;

let commit_local database ~expected mutation =
  serialize_commit database (fun () ->
    let callbacks, change, outcome =
      Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
        if database.closed
        then [], None, Error Types.Local_database_closed
        else (
          match Overlay_planner.validate mutation with
          | Error message -> [], None, Error (Types.Invalid_local_mutation message)
          | Ok () ->
            let id = mutation_id mutation in
            let fingerprint = fingerprint mutation in
            (match existing_mutation database id fingerprint with
             | Ok (Some existing) -> [], None, Ok (Types.Local_existing existing)
             | Error () -> [], None, Error Types.Mutation_identity_conflict
             | Ok None ->
               (match required_preconditions database expected mutation with
                | Error error -> [], None, Error error
                | Ok () when not (preconditions_match database expected) ->
                  [], None, Error Types.Target_precondition_conflict
                | Ok () ->
                  let intent_time_ms = database.dependencies.epoch_ms () in
                  (match planned_effect database ~now:intent_time_ms mutation with
                   | Error error -> [], None, Error error
                   | Ok (effect_footprint, delete_artifacts) ->
                     let candidate_record =
                       local_candidate_record
                         database
                         ~fingerprint
                         ~effect_footprint
                         ~delete_artifacts
                         ~intent_time_ms
                         mutation
                     in
                     if not (local_candidate_fits database candidate_record)
                     then [], None, Error Types.Planner_limit_exceeded
                     else (
                       let previous_projection = database.projection in
                       let previous_receipts = database.receipts in
                       let previous_outbox = database.outbox in
                       let previous_sync_revision = database.sync_revision in
                       let before = database.projection in
                       let candidate_after = before + 1 in
                       let applied =
                         mutation_has_logical_effect database ~now:intent_time_ms mutation
                       in
                       let after = if applied then candidate_after else before in
                       database.projection <- after;
                       let block_uuids, page_uuids, structure_interests =
                         change_for_effect effect_footprint
                       in
                       let summary =
                         if applied
                         then
                           bounded_logical_summary
                             database
                             ~block_uuids
                             ~page_uuids
                             ~structure_interests
                         else Types.No_logical_change
                       in
                       let commit =
                         { Types.mutation_id = id
                         ; status = (if applied then Applied else No_change)
                         ; generation = database.generation
                         ; before_projection_revision = projection_revision before
                         ; after_projection_revision = projection_revision after
                         ; logical_change_summary = summary
                         }
                       in
                       if not applied
                       then
                         database.receipts
                         <- (id, fingerprint, Commit_receipt commit) :: database.receipts;
                       if applied
                       then (
                         database.outbox <- database.outbox @ [ candidate_record ];
                         database.sync_revision <- database.sync_revision + 1);
                       match persist_outbox database with
                       | Error message ->
                         database.projection <- previous_projection;
                         database.receipts <- previous_receipts;
                         database.outbox <- previous_outbox;
                         database.sync_revision <- previous_sync_revision;
                         [], None, Error (Types.Local_commit_persistence_failed message)
                       | Ok () ->
                         if applied then refresh_queryable_outbox database;
                         database.receipts <- [];
                         if not applied
                         then [], None, Ok (Types.Local_committed commit)
                         else (
                           let change =
                             match summary with
                             | Types.Exact_logical_change _ ->
                               Types.Exact
                                 { generation = database.generation
                                 ; before_revision = projection_revision before
                                 ; after_revision = projection_revision after
                                 ; block_uuids
                                 ; page_uuids
                                 ; structure_interests
                                 }
                             | Logical_resync_required reason ->
                               Projection_resync_required
                                 { generation = database.generation
                                 ; after_revision = projection_revision after
                                 ; reason
                                 }
                             | No_logical_change -> assert false
                           in
                           let callbacks =
                             database.subscriptions
                             |> List.filter_map (fun (subscription : subscription) ->
                               match subscription.lifecycle, subscription.notify with
                               | Active, Some callback -> Some callback
                               | Active, None | Unlistened, _ -> None)
                           in
                           callbacks, Some change, Ok (Types.Local_committed commit))))))))
    in
    ignore callbacks;
    change, outcome)
;;

let retry_blocked database ~expected ~mutation_id =
  Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
    if database.closed
    then Error Types.Blocked_retry_database_closed
    else (
      match
        List.find_opt
          (fun (record : outbox_record) ->
             Graph.Uuid.equal mutation_id record.mutation_id
             && record.transport_state = Types.Blocked)
          database.outbox
      with
      | None -> Error Types.Blocked_mutation_missing
      | Some record when not record.same_id_retry_eligible ->
        Error Types.Blocked_retry_ineligible
      | Some _ when not (preconditions_match database expected) ->
        Error Types.Blocked_retry_precondition_conflict
      | Some record ->
        let previous_projection = database.projection in
        let previous_sync_revision = database.sync_revision in
        let logical_before = snapshot_of_database database in
        let previous_state = record.transport_state in
        let previous_prior = record.blocked_prior_state in
        let previous_reason = record.blocked_reason in
        let previous_eligible = record.same_id_retry_eligible in
        record.transport_state <- Types.Queued;
        record.blocked_prior_state <- None;
        record.blocked_reason <- None;
        record.same_id_retry_eligible <- false;
        let before = database.projection in
        let candidate_after = before + 1 in
        let logical_after =
          snapshot_for_sources database (authoritative_database database) database.outbox
        in
        let logical_change_summary =
          logical_change_for_effects
            database
            ~before:logical_before
            ~after:logical_after
            [ record.effect_footprint ]
        in
        let applied = logical_change_summary <> Types.No_logical_change in
        let after = if applied then candidate_after else before in
        database.projection <- after;
        database.sync_revision <- database.sync_revision + 1;
        (match persist_outbox database with
         | Error message ->
           database.projection <- previous_projection;
           database.sync_revision <- previous_sync_revision;
           record.transport_state <- previous_state;
           record.blocked_prior_state <- previous_prior;
           record.blocked_reason <- previous_reason;
           record.same_id_retry_eligible <- previous_eligible;
           Error (Types.Blocked_retry_persistence_failed message)
         | Ok () ->
           refresh_queryable_outbox database;
           Ok
             { Types.mutation_id
             ; status = (if applied then Applied else No_change)
             ; generation = database.generation
             ; before_projection_revision = projection_revision before
             ; after_projection_revision = projection_revision after
             ; logical_change_summary
             })))
;;

let discard_blocked database ~mutation_id =
  Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
    if database.closed
    then Error Types.Blocked_discard_database_closed
    else (
      match
        List.find_opt
          (fun (record : outbox_record) ->
             Graph.Uuid.equal mutation_id record.mutation_id
             && record.transport_state = Types.Blocked)
          database.outbox
      with
      | None -> Error Types.Blocked_discard_missing
      | Some record ->
        let previous_outbox = database.outbox in
        let previous_receipts = database.receipts in
        let previous_sync_revision = database.sync_revision in
        let revision = projection_revision database.projection in
        let commit =
          { Types.mutation_id
          ; generation = database.generation
          ; before_projection_revision = revision
          ; after_projection_revision = revision
          ; logical_change_summary = No_logical_change
          }
        in
        let prior_reason = Option.value record.blocked_reason ~default:Types.Rejected in
        database.outbox
        <- List.filter
             (fun (candidate : outbox_record) ->
                not (Graph.Uuid.equal mutation_id candidate.mutation_id))
             database.outbox;
        database.receipts
        <- (mutation_id, record.fingerprint, Discarded_receipt (commit, prior_reason))
           :: List.filter
                (fun (candidate, _, _) -> not (Graph.Uuid.equal mutation_id candidate))
                database.receipts;
        database.sync_revision <- database.sync_revision + 1;
        (match persist_outbox database with
         | Ok () ->
           refresh_queryable_outbox database;
           database.receipts <- [];
           Ok commit
         | Error message ->
           database.outbox <- previous_outbox;
           database.receipts <- previous_receipts;
           database.sync_revision <- previous_sync_revision;
           Error (Types.Blocked_discard_persistence_failed message))))
;;

let sync_token revision =
  token Types.sync_token_of_string (Printf.sprintf "sync-token:v1:%d" revision)
;;

let mutation_fingerprint value =
  token Types.Mutation_fingerprint.of_string ("mutation-fingerprint:v1:" ^ value)
;;

let crypto_item_id revision index mutation_id =
  token
    Types.Crypto_item_id.of_string
    (Printf.sprintf
       "crypto-item:v1:%d:%d:%s"
       revision
       index
       (Graph.Uuid.to_string mutation_id))
;;

let batch_id revision =
  token
    Types.Submission_batch_id.of_string
    (Printf.sprintf "submission-batch:v1:%d" revision)
;;

let descriptor (record : outbox_record) =
  { Types.mutation_id = record.mutation_id
  ; fingerprint = mutation_fingerprint record.fingerprint
  ; state = record.transport_state
  ; dependency_eligible = record.transport_state <> Types.Blocked
  ; attempt_count = record.attempt_count
  ; plaintext_bytes = String.length record.normalized_transaction
  ; protected_bytes = Option.map String.length record.protected_transaction
  }
;;

let inspect_sync database =
  Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
    if database.closed
    then Error Types.Sync_database_closed
    else
      Ok
        (Types.sync_view
           ~token:(sync_token database.sync_revision)
           ~checkpoint:(server_cursor database.checkpoint)
           ~submissions:(List.map descriptor database.outbox)))
;;

let find_outbox database id =
  List.find_opt
    (fun (record : outbox_record) -> Graph.Uuid.equal record.mutation_id id)
    database.outbox
;;

let batch_records database id =
  List.filter
    (fun (record : outbox_record) ->
       match record.transport_state with
       | Types.Submitted candidate | Accepted_pending_authoritative candidate ->
         Types.Submission_batch_id.equal candidate id
       | Queued | Delete_barrier_rejected_pending_authoritative _ | Blocked -> false)
    database.outbox
;;

let validate_rejection_partition records (partition : Types.rejection_member_partition) =
  Transition.validate_rejection_partition
    ~expected:(List.map (fun (record : outbox_record) -> record.mutation_id) records)
    partition
;;

let records_for_ids records ids =
  List.map
    (fun id ->
       List.find
         (fun (record : outbox_record) -> Graph.Uuid.equal record.mutation_id id)
         records)
    ids
;;

let block_tree_uuids = Outliner.Tree.uuids

let mutation_introduced_uuids = function
  | Types.Insert_blocks { tree; _ } -> block_tree_uuids tree
  | Create_journal_page { page; _ } -> [ page ]
  | Save_block _ | Delete_blocks _ | Set_task_status _ | Clear_task_status _ -> []
;;

let mutation_required_uuids = function
  | Types.Save_block { block; _ }
  | Delete_blocks { root = block; _ }
  | Set_task_status { block; _ }
  | Clear_task_status { block; _ } -> [ block ]
  | Insert_blocks { parent; _ } -> [ parent ]
  | Create_journal_page _ -> []
;;

let submission_records_are_in_sequence_order records =
  let rec loop previous = function
    | [] -> true
    | (record : outbox_record) :: rest ->
      record.sequence > previous && loop record.sequence rest
  in
  loop 0 records
;;

let ineligible_submission_dependency database selected =
  List.find_map
    (fun (record : outbox_record) ->
       let has_unselected_queued_owner required =
         database.outbox
         |> List.find_opt (fun (candidate : outbox_record) ->
           candidate.sequence < record.sequence
           && candidate.transport_state = Types.Queued
           && List.exists
                (Graph.Uuid.equal required)
                (mutation_introduced_uuids candidate.mutation))
         |> function
         | None -> false
         | Some owner ->
           not
             (List.exists
                (fun (candidate : outbox_record) -> candidate == owner)
                selected)
       in
       if
         List.exists has_unselected_queued_owner (mutation_required_uuids record.mutation)
       then Some record.mutation_id
       else None)
    selected
;;

let rejection_suffix_records records (partition : Types.rejection_member_partition) =
  let failed = records_for_ids records (Option.to_list partition.failed_member) in
  let unavailable =
    ref
      (partition.missing_uuids
       @ List.concat_map
           (fun (record : outbox_record) -> mutation_introduced_uuids record.mutation)
           failed)
  in
  records_for_ids records partition.unexecuted_suffix
  |> List.fold_left
       (fun (dependent, independent) (record : outbox_record) ->
          let is_dependent =
            mutation_required_uuids record.mutation
            |> List.exists (fun required ->
              List.exists (Graph.Uuid.equal required) !unavailable)
          in
          if is_dependent
          then (
            unavailable := mutation_introduced_uuids record.mutation @ !unavailable;
            record :: dependent, independent)
          else dependent, record :: independent)
       ([], [])
  |> fun (dependent, independent) -> List.rev dependent, List.rev independent
;;

let server_cursor_number cursor =
  Types.Server_cursor.to_string cursor
  |> String.split_on_char ':'
  |> List.rev
  |> List.hd
  |> int_of_string
;;

let expected_origin_cursor (record : outbox_record) =
  match
    record.submission_t_before, record.submission_ordinal, record.submission_count
  with
  | Some t_before, Some ordinal, Some count when ordinal >= 0 && ordinal < count ->
    Ok (server_cursor_number t_before + ordinal + 1)
  | _ -> Error "own transaction omitted its frozen submission interval"
;;

let strip_versioned_prefix prefix value =
  let prefix = prefix ^ ":v1:" in
  if
    String.length value >= String.length prefix
    && String.sub value 0 (String.length prefix) = prefix
  then String.sub value (String.length prefix) (String.length value - String.length prefix)
  else value
;;

let acceptance_barrier_is_current database (barrier : Types.acceptance_barrier) =
  server_cursor_number barrier.through = database.checkpoint
  && String.equal
       (strip_versioned_prefix "checksum" (Types.Checksum.to_string barrier.checksum))
       (strip_versioned_prefix "checksum" database.checkpoint_metadata.checksum)
;;

let rec authoritative_tree_is_present database ~parent (tree : Types.block_tree) =
  match block_of_database database tree.uuid with
  | None -> false
  | Some (record : Types.block_record) ->
    Graph.Uuid.equal record.block.parent parent
    && String.equal record.block.title tree.title
    && List.for_all
         (authoritative_tree_is_present database ~parent:tree.uuid)
         tree.children
;;

let option_satisfies predicate = function
  | Some value -> predicate value
  | None -> false
;;

let authoritative_satisfies_mutation_in database = function
  | Types.Save_block { block; title; _ } ->
    block_of_database database block
    |> option_satisfies (fun (record : Types.block_record) ->
      String.equal record.block.title title)
  | Insert_blocks { parent; tree; _ } ->
    authoritative_tree_is_present database ~parent tree
  | Delete_blocks { root; _ } -> Option.is_none (block_of_database database root)
  | Create_journal_page { page; title; journal_day; _ } ->
    page_of_database database page
    |> option_satisfies (fun (record : Types.page_record) ->
      String.equal record.page.title title
      && record.page.kind = Graph.Journal_page { journal_day })
  | Set_task_status { block; status; _ } ->
    block_of_database database block
    |> option_satisfies (fun (record : Types.block_record) ->
      record.task_status = Some status)
  | Clear_task_status { block; _ } ->
    block_of_database database block
    |> option_satisfies (fun (record : Types.block_record) ->
      Option.is_none record.task_status)
;;

let mutation_supersedes earlier later =
  match earlier, later with
  | Types.Save_block { block = earlier; _ }, Save_block { block = later; _ } ->
    Graph.Uuid.equal earlier later
  | ( (Set_task_status { block = earlier; _ } | Clear_task_status { block = earlier; _ })
    , (Set_task_status { block = later; _ } | Clear_task_status { block = later; _ }) ) ->
    Graph.Uuid.equal earlier later
  | _ -> false
;;

let rec authoritative_tree_satisfies database ~later ~parent (tree : Types.block_tree) =
  match block_of_database database tree.uuid with
  | None -> false
  | Some (record : Types.block_record) ->
    let title_superseded =
      List.exists
        (fun (later : outbox_record) ->
           match later.mutation with
           | Types.Save_block { block; _ } -> Graph.Uuid.equal block tree.uuid
           | _ -> false)
        later
    in
    Graph.Uuid.equal record.block.parent parent
    && (title_superseded || String.equal record.block.title tree.title)
    && List.for_all
         (authoritative_tree_satisfies database ~later ~parent:tree.uuid)
         tree.children
;;

let accepted_record_satisfied database records (record : outbox_record) =
  let later = List.filter (fun later -> later.sequence > record.sequence) records in
  if
    List.exists
      (fun (later : outbox_record) -> mutation_supersedes record.mutation later.mutation)
      later
  then true
  else (
    match record.mutation with
    | Types.Insert_blocks { parent; tree; _ } ->
      authoritative_tree_satisfies database ~later ~parent tree
    | mutation -> authoritative_satisfies_mutation_in database mutation)
;;

let begin_outbox_transition database ~expected transition =
  Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
    if database.closed
    then Error Types.Outbox_database_closed
    else if not (Types.sync_token_equal expected (sync_token database.sync_revision))
    then Error Types.Outbox_sync_token_conflict
    else (
      let make plan protection_request =
        Ok
          ( { transition_owner = database
            ; transition_revision = database.sync_revision
            ; transition
            ; plan
            ; protection_request
            ; transition_consumed = false
            }
          , protection_request )
      in
      match transition with
      | Types.Submit_group [] ->
        Error (Types.Outbox_transition_invalid "empty submit group")
      | Submit_group ids ->
        let duplicate = duplicate_by Graph.Uuid.equal ids in
        if Option.is_some duplicate
        then Error (Types.Outbox_transition_invalid "duplicate submit member")
        else (
          let records = List.map (find_outbox database) ids in
          if List.exists Option.is_none records
          then Error (Types.Outbox_transition_invalid "submit member is missing")
          else (
            let records = List.map Option.get records in
            let ineligible_dependency =
              ineligible_submission_dependency database records
            in
            if
              List.exists
                (fun (record : outbox_record) -> record.transport_state <> Types.Queued)
                records
            then Error (Types.Outbox_transition_invalid "submit member is not queued")
            else if not (submission_records_are_in_sequence_order records)
            then Error (Types.Outbox_transition_invalid "submit members are reordered")
            else if Option.is_some ineligible_dependency
            then
              Error
                (Types.Outbox_dependency_ineligible (Option.get ineligible_dependency))
            else if
              List.length records > 1
              && List.exists
                   (fun (record : outbox_record) ->
                      operation_of_mutation record.mutation
                      = Types.Delete_blocks_operation)
                   records
            then Error Types.Outbox_delete_requires_singleton
            else (
              let total_bytes =
                List.fold_left
                  (fun total (record : outbox_record) ->
                     total + String.length record.normalized_transaction)
                  0
                  records
              in
              if total_bytes > database.dependencies.limits.wire_batch_max_bytes
              then Error Types.Outbox_limit_exceeded
              else (
                let items =
                  records
                  |> List.concat_map (fun (record : outbox_record) ->
                    local_operations
                      ~fingerprint:record.fingerprint
                      ~intent_time_ms:record.intent_time_ms
                      ~next_tx:record.planned_tx
                      ~sequence:record.sequence
                      ~effect_footprint:record.effect_footprint
                      ~delete_artifacts:record.delete_artifacts
                      record.mutation
                    |> Sync_tx_codec.protected_plaintexts
                    |> Result.get_ok
                    |> List.map (fun value -> record.mutation_id, value))
                  |> List.mapi (fun index (mutation_id, value) ->
                    crypto_item_id database.sync_revision index mutation_id, value)
                in
                let request =
                  { protection_owner = database
                  ; protection_revision = database.sync_revision
                  ; protection_items = items
                  ; protection_consumed = false
                  }
                in
                make (Submit_plan records) (Some request)))))
      | Retry_group id ->
        let records = batch_records database id in
        if records = []
        then Error (Types.Outbox_transition_invalid "retry batch is missing")
        else if
          List.exists
            (fun (record : outbox_record) -> Option.is_none record.protected_transaction)
            records
        then Error (Types.Outbox_transition_invalid "retry batch has no protected bytes")
        else make (Retry_plan (id, records)) None
      | Accept_group { batch_id = id; barrier } ->
        (match read_terminal_batch database id with
         | Error message -> Error (Types.Outbox_transition_invalid message)
         | Ok (Some { terminal_outcome = Terminal_accepted accepted; _ })
           when Transition.acceptance_barriers_equal accepted barrier ->
           make Duplicate_plan None
         | Ok (Some { terminal_outcome = Terminal_accepted _; _ }) ->
           Error (Types.Outbox_transition_invalid "terminal acceptance mismatch")
         | Ok (Some { terminal_outcome = Terminal_proven_unexecuted _; _ }) ->
           Error
             (Types.Outbox_transition_invalid
                "acceptance contradicts proven conditional non-execution")
         | Ok None when batch_records database id = [] ->
           Error (Types.Outbox_transition_invalid "accept batch is missing")
         | Ok None ->
           let records = batch_records database id in
           let through = server_cursor_number barrier.through in
           let validate result (record : outbox_record) =
             Result.bind result (fun () ->
               Result.bind (expected_origin_cursor record) (fun expected ->
                 if expected > through
                 then Error "acceptance barrier precedes its own submission interval"
                 else if through <= database.checkpoint
                 then (
                   match record.observed_origin_cursor with
                   | Some cursor when server_cursor_number cursor = expected -> Ok ()
                   | None | Some _ ->
                     Error "covered acceptance has no durable origin evidence")
                 else Ok ()))
           in
           (match List.fold_left validate (Ok ()) records with
            | Error message -> Error (Types.Outbox_transition_invalid message)
            | Ok () ->
              if
                through = database.checkpoint
                && not (acceptance_barrier_is_current database barrier)
              then Error (Types.Outbox_transition_invalid "acceptance checksum mismatch")
              else make (Accept_plan (id, barrier)) None))
      | Reject_group { batch_id = id; resolution } ->
        (match read_terminal_batch database id with
         | Error message -> Error (Types.Outbox_transition_invalid message)
         | Ok (Some { terminal_outcome = Terminal_accepted _; _ }) ->
           Error (Types.Outbox_transition_invalid "batch already accepted")
         | Ok (Some { terminal_outcome = Terminal_proven_unexecuted _; _ }) ->
           make Duplicate_plan None
         | Ok None ->
           let records = batch_records database id in
           if records = []
           then Error (Types.Outbox_transition_invalid "reject batch is missing")
           else (
             match resolution with
             | Types.Stale _ -> make (Reject_plan (id, resolution)) None
             | Definitive { partition; _ } ->
               (match validate_rejection_partition records partition with
                | Error message -> Error (Types.Outbox_transition_invalid message)
                | Ok () -> make (Reject_plan (id, resolution)) None)))))
;;

let protection_plaintexts request = request.protection_items

let validate_protected_values ~request ~encrypted =
  if request.protection_consumed
  then Error Types.Crypto_result_stale
  else if request.protection_owner.sync_revision <> request.protection_revision
  then Error Types.Crypto_result_stale
  else
    Crypto_bridge.validate_results
      ~maximum_value_bytes:
        request.protection_owner.dependencies.limits.wire_batch_max_bytes
      ~expected:request.protection_items
      ~actual:encrypted
;;

let unprotection_ciphertexts request = request.unprotection_items

let validate_decrypted_values ~request ~plaintexts =
  if request.unprotection_consumed
  then Error Types.Crypto_result_stale
  else if
    match request.unprotection_owner with
    | Authoritative_unprotection (owner, revision) -> owner.sync_revision <> revision
    | Snapshot_unprotection (owner, revision) ->
      owner.snapshot_canceled
      || owner.snapshot_committed
      || Option.is_some owner.snapshot_persisted
      || owner.snapshot_crypto_revision <> revision
      || not owner.snapshot_awaiting_crypto
  then Error Types.Crypto_result_stale
  else
    Crypto_bridge.validate_results
      ~maximum_value_bytes:request.unprotection_limit_bytes
      ~expected:request.unprotection_items
      ~actual:plaintexts
;;

let make_batch preparation encrypted =
  let rec take_prefix count reversed values =
    if count = 0
    then List.rev reversed, values
    else (
      match values with
      | [] -> invalid_arg "encrypted value count is shorter than normalized transaction"
      | value :: rest -> take_prefix (count - 1) (value :: reversed) rest)
  in
  let records, id =
    match preparation.plan with
    | Submit_plan records -> records, batch_id (preparation.transition_revision + 1)
    | Retry_plan (id, records) -> records, id
    | Reject_plan (id, Definitive { partition; _ }) ->
      let records = batch_records preparation.transition_owner id in
      let _dependent, independent = rejection_suffix_records records partition in
      independent, batch_id (preparation.transition_revision + 1)
    | Accept_plan _ | Reject_plan (_, Stale _) | Duplicate_plan ->
      invalid_arg "transition has no submission batch"
  in
  let protected_transactions =
    match encrypted with
    | Some values ->
      let rec encode reversed remaining = function
        | [] ->
          if remaining = []
          then List.rev reversed
          else invalid_arg "encrypted value count exceeds normalized transaction"
        | (record : outbox_record) :: rest ->
          let expected =
            local_operations
              ~fingerprint:record.fingerprint
              ~intent_time_ms:record.intent_time_ms
              ~next_tx:record.planned_tx
              ~sequence:record.sequence
              ~effect_footprint:record.effect_footprint
              ~delete_artifacts:record.delete_artifacts
              record.mutation
            |> Sync_tx_codec.protected_plaintexts
            |> Result.get_ok
            |> List.length
          in
          let encrypted, remaining = take_prefix expected [] remaining in
          let operations =
            local_operations
              ~fingerprint:record.fingerprint
              ~intent_time_ms:record.intent_time_ms
              ~next_tx:record.planned_tx
              ~sequence:record.sequence
              ~effect_footprint:record.effect_footprint
              ~delete_artifacts:record.delete_artifacts
              record.mutation
          in
          let protected_transaction =
            Sync_tx_codec.encode_protected
              ~db:(authoritative_database preparation.transition_owner)
              operations
              ~encrypted_values:(List.map snd encrypted)
            |> Result.get_ok
          in
          encode (protected_transaction :: reversed) remaining rest
      in
      encode [] values records
    | None ->
      List.map
        (fun (record : outbox_record) -> Option.get record.protected_transaction)
        records
  in
  let wires =
    List.map2
      (fun (record : outbox_record) protected_transaction ->
         Types.submission_wire
           ~maximum_bytes:
             preparation.transition_owner.dependencies.limits.wire_batch_max_bytes
           ~mutation_id:record.mutation_id
           ~operation:(operation_of_mutation record.mutation)
           ~protected_transaction
         |> Result.get_ok)
      records
      protected_transactions
  in
  Types.submission_batch
    ~maximum_wires:preparation.transition_owner.dependencies.limits.outbox_max_records
    ~maximum_bytes:preparation.transition_owner.dependencies.limits.wire_batch_max_bytes
    ~batch_id:id
    ~t_before:(server_cursor preparation.transition_owner.checkpoint)
    ~wires
  |> Result.get_ok
;;

let outbox_fits_submission preparation records batch =
  let database = preparation.transition_owner in
  let id = Types.submission_batch_id batch in
  let t_before = Types.submission_batch_t_before batch in
  let count = List.length records in
  let protected_transactions =
    Types.submission_batch_wires batch
    |> List.map Types.submission_wire_protected_transaction
  in
  let capture_dependency_shadows =
    match preparation.plan with
    | Submit_plan _ -> true
    | Retry_plan _ | Accept_plan _ | Reject_plan _ | Duplicate_plan -> false
  in
  let replacements =
    List.combine records protected_transactions
    |> List.mapi (fun index ((record : outbox_record), protected_transaction) ->
      ( record
      , { record with
          transport_state = Types.Submitted id
        ; dependency_shadows =
            (if capture_dependency_shadows
             then dependency_shadows_for database record.mutation
             else record.dependency_shadows)
        ; protected_transaction = Some protected_transaction
        ; attempt_count = record.attempt_count + 1
        ; acceptance_barrier = None
        ; submission_t_before = Some t_before
        ; submission_ordinal = Some index
        ; submission_count = Some count
        ; observed_origin_cursor = None
        } ))
  in
  let candidate =
    List.map
      (fun record ->
         replacements
         |> List.find_opt (fun (source, _) -> source == record)
         |> Option.fold ~none:record ~some:snd)
      database.outbox
  in
  outbox_records_fit
    database
    ~sync_revision:(preparation.transition_revision + 1)
    candidate
;;

let outbox_submission_batch preparation ~encrypted =
  match preparation.plan, preparation.protection_request, encrypted with
  | Submit_plan _, Some request, Some (actual_request, encrypted)
    when actual_request == request ->
    (match validate_protected_values ~request ~encrypted with
     | Error error -> Error (Types.Outbox_crypto_error error)
     | Ok () ->
       let batch = make_batch preparation (Some encrypted) in
       let records =
         match preparation.plan with
         | Submit_plan records -> records
         | _ -> assert false
       in
       if not (outbox_fits_submission preparation records batch)
       then Error Types.Outbox_limit_exceeded
       else Ok (Some batch))
  | Submit_plan _, Some _, None -> Error Types.Outbox_crypto_required
  | Submit_plan _, Some _, Some _ -> Error Types.Outbox_crypto_unexpected
  | Retry_plan _, None, None ->
    let batch = make_batch preparation None in
    let records =
      match preparation.plan with
      | Retry_plan (_, records) -> records
      | _ -> assert false
    in
    if not (outbox_fits_submission preparation records batch)
    then Error Types.Outbox_limit_exceeded
    else Ok (Some batch)
  | Reject_plan (_, Definitive { partition; _ }), None, None ->
    let id =
      match preparation.plan with
      | Reject_plan (id, _) -> id
      | _ -> assert false
    in
    let records = batch_records preparation.transition_owner id in
    let _dependent, independent = rejection_suffix_records records partition in
    Ok
      (match independent with
       | [] -> None
       | _ -> Some (make_batch preparation None))
  | (Accept_plan _ | Reject_plan _ | Duplicate_plan), None, None -> Ok None
  | (Retry_plan _ | Accept_plan _ | Reject_plan _ | Duplicate_plan), _, Some _ ->
    Error Types.Outbox_crypto_unexpected
  | _ ->
    Error (Types.Outbox_transition_invalid "preparation crypto state is inconsistent")
;;

let update_submitted database ~capture_dependency_shadows records batch =
  let id = Types.submission_batch_id batch in
  let t_before = Types.submission_batch_t_before batch in
  let count = List.length records in
  let protected_transactions =
    Types.submission_batch_wires batch
    |> List.map Types.submission_wire_protected_transaction
  in
  List.iteri
    (fun index (record : outbox_record) ->
       if capture_dependency_shadows
       then record.dependency_shadows <- dependency_shadows_for database record.mutation;
       record.transport_state <- Types.Submitted id;
       record.acceptance_barrier <- None;
       record.attempt_count <- record.attempt_count + 1;
       record.submission_t_before <- Some t_before;
       record.submission_ordinal <- Some index;
       record.submission_count <- Some count;
       record.observed_origin_cursor <- None;
       record.protected_transaction <- Some (List.nth protected_transactions index))
    records
;;

let apply_outbox_transition database preparation ~encrypted =
  serialize_commit database (fun () ->
    let callbacks, change, outcome =
      Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
        if preparation.transition_owner != database
        then [], None, Error Types.Outbox_commit_generation_invalidated
        else if database.closed
        then [], None, Error Types.Outbox_commit_database_closed
        else if preparation.transition_consumed
        then [], None, Error Types.Outbox_preparation_consumed
        else (
          match outbox_submission_batch preparation ~encrypted with
          | Error error -> [], None, Error error
          | Ok _ when database.sync_revision <> preparation.transition_revision ->
            [], None, Error Types.Outbox_commit_token_conflict
          | Ok submission_batch ->
            preparation.transition_consumed <- true;
            Option.iter
              (fun request -> request.protection_consumed <- true)
              preparation.protection_request;
            if preparation.plan = Duplicate_plan
            then (
              let revision = projection_revision database.projection in
              ( []
              , None
              , Ok
                  { Types.generation = database.generation
                  ; before_projection_revision = revision
                  ; after_projection_revision = revision
                  ; sync_token = sync_token database.sync_revision
                  ; transition = preparation.transition
                  ; activity = Logically_inactive
                  ; logical_change_summary = No_logical_change
                  ; submission_batch = None
                  } ))
            else (
              let previous_sync_revision = database.sync_revision in
              let previous_projection = database.projection in
              let logical_before =
                match preparation.plan with
                | Accept_plan (_, barrier)
                  when server_cursor_number barrier.through <= database.checkpoint ->
                  Some (snapshot_of_database database)
                | Reject_plan (_, Definitive _) -> Some (snapshot_of_database database)
                | Submit_plan _ | Retry_plan _ | Accept_plan _
                | Reject_plan (_, Stale _)
                | Duplicate_plan -> None
              in
              let previous_outbox = database.outbox in
              let previous_receipts = database.receipts in
              let previous_records =
                List.map
                  (fun (record : outbox_record) ->
                     ( record
                     , record.transport_state
                     , record.dependency_shadows
                     , record.protected_transaction
                     , record.attempt_count
                     , record.blocked_prior_state
                     , record.blocked_reason
                     , record.same_id_retry_eligible
                     , record.acceptance_barrier
                     , record.submission_t_before
                     , record.submission_ordinal
                     , record.submission_count
                     , record.observed_origin_cursor
                     , record.stale_earliest_conflict_cursor
                     , record.stale_conflicts ))
                  database.outbox
              in
              let activity, affected_records =
                match preparation.plan with
                | Submit_plan records ->
                  let batch = Option.get submission_batch in
                  update_submitted database ~capture_dependency_shadows:true records batch;
                  Types.Logically_active, []
                | Retry_plan (id, records) ->
                  let batch = Option.get submission_batch in
                  if
                    not
                      (Types.Submission_batch_id.equal
                         id
                         (Types.submission_batch_id batch))
                  then invalid_arg "retry batch identity changed";
                  update_submitted
                    database
                    ~capture_dependency_shadows:false
                    records
                    batch;
                  Types.Logically_active, []
                | Accept_plan (id, barrier)
                  when server_cursor_number barrier.through > database.checkpoint ->
                  List.iter
                    (fun (record : outbox_record) ->
                       record.transport_state <- Types.Accepted_pending_authoritative id;
                       record.acceptance_barrier <- Some barrier)
                    (batch_records database id);
                  Types.Logically_active, []
                | Accept_plan (id, barrier) ->
                  let records = batch_records database id in
                  let current_root = authoritative_database database in
                  let barrier_is_behind =
                    server_cursor_number barrier.through < database.checkpoint
                  in
                  let incorporated, mismatched =
                    List.partition
                      (fun (record : outbox_record) ->
                         match record.mutation with
                         | Save_block _
                         | Insert_blocks _
                         | Create_journal_page _
                         | Set_task_status _
                         | Clear_task_status _
                           when barrier_is_behind -> true
                         | _ -> accepted_record_satisfied current_root records record)
                      records
                  in
                  List.iter
                    (fun (record : outbox_record) ->
                       record.blocked_prior_state <- Some record.transport_state;
                       record.blocked_reason <- Some Types.Authoritative_mismatch;
                       record.same_id_retry_eligible <- false;
                       record.acceptance_barrier <- None;
                       record.dependency_shadows <- empty_dependency_shadows;
                       record.transport_state <- Types.Blocked)
                    mismatched;
                  let receipt_revision = projection_revision database.projection in
                  database.receipts
                  <- List.fold_left
                       (fun receipts (record : outbox_record) ->
                          let commit =
                            { Types.mutation_id = record.mutation_id
                            ; status = Applied
                            ; generation = database.generation
                            ; before_projection_revision = receipt_revision
                            ; after_projection_revision = receipt_revision
                            ; logical_change_summary = No_logical_change
                            }
                          in
                          (record.mutation_id, record.fingerprint, Commit_receipt commit)
                          :: List.filter
                               (fun (candidate, _, _) ->
                                  not (Graph.Uuid.equal candidate record.mutation_id))
                               receipts)
                       database.receipts
                       incorporated;
                  database.outbox
                  <- List.filter
                       (fun (record : outbox_record) ->
                          not
                            (List.exists
                               (fun incorporated_record -> incorporated_record == record)
                               incorporated))
                       database.outbox;
                  Types.Logically_inactive, records
                | Reject_plan (id, Types.Stale { through }) ->
                  let records = batch_records database id in
                  List.iter
                    (fun (record : outbox_record) ->
                       record.transport_state
                       <- Types.Delete_barrier_rejected_pending_authoritative
                            { batch_id = id; through };
                       record.acceptance_barrier <- None;
                       record.stale_earliest_conflict_cursor <- None;
                       record.stale_conflicts <- [])
                    records;
                  Types.Logically_active, []
                | Reject_plan (id, Definitive { partition; _ }) ->
                  let records = batch_records database id in
                  let accepted = records_for_ids records partition.accepted_prefix in
                  let failed =
                    records_for_ids records (Option.to_list partition.failed_member)
                  in
                  let dependent, independent =
                    rejection_suffix_records records partition
                  in
                  List.iter
                    (fun (record : outbox_record) ->
                       record.transport_state <- Types.Accepted_pending_authoritative id)
                    accepted;
                  List.iter
                    (fun (record : outbox_record) ->
                       record.blocked_prior_state <- Some record.transport_state;
                       record.blocked_reason <- Some Types.Rejected;
                       record.same_id_retry_eligible <- false;
                       record.acceptance_barrier <- None;
                       record.dependency_shadows <- empty_dependency_shadows;
                       record.transport_state <- Types.Blocked)
                    (failed @ dependent);
                  Option.iter
                    (fun batch ->
                       update_submitted
                         database
                         ~capture_dependency_shadows:false
                         independent
                         batch)
                    submission_batch;
                  ( (if accepted = [] && independent = []
                     then Types.Logically_inactive
                     else Logically_active)
                  , failed @ dependent )
                | Duplicate_plan -> assert false
              in
              let logical_change_summary =
                match logical_before with
                | None -> Types.No_logical_change
                | Some before ->
                  let after =
                    snapshot_for_sources
                      database
                      (authoritative_database database)
                      database.outbox
                  in
                  logical_change_for_effects
                    database
                    ~before
                    ~after
                    (List.map
                       (fun (record : outbox_record) -> record.effect_footprint)
                       affected_records)
              in
              let logical_changed = logical_change_summary <> Types.No_logical_change in
              database.projection
              <- (if logical_changed then previous_projection + 1 else previous_projection);
              let terminal_batches =
                match preparation.plan with
                | Accept_plan (terminal_batch_id, terminal_acceptance_barrier) ->
                  [ { terminal_batch_id
                    ; terminal_outcome = Terminal_accepted terminal_acceptance_barrier
                    }
                  ]
                | Submit_plan _ | Retry_plan _ | Reject_plan _ | Duplicate_plan -> []
              in
              database.sync_revision <- database.sync_revision + 1;
              match persist_outbox ~terminal_batches database with
              | Error message ->
                database.sync_revision <- previous_sync_revision;
                database.projection <- previous_projection;
                database.outbox <- previous_outbox;
                database.receipts <- previous_receipts;
                List.iter
                  (fun ( record
                       , transport_state
                       , dependency_shadows
                       , protected_transaction
                       , attempt_count
                       , blocked_prior_state
                       , blocked_reason
                       , same_id_retry_eligible
                       , acceptance_barrier
                       , submission_t_before
                       , submission_ordinal
                       , submission_count
                       , observed_origin_cursor
                       , stale_earliest_conflict_cursor
                       , stale_conflicts ) ->
                     record.transport_state <- transport_state;
                     record.dependency_shadows <- dependency_shadows;
                     record.protected_transaction <- protected_transaction;
                     record.attempt_count <- attempt_count;
                     record.blocked_prior_state <- blocked_prior_state;
                     record.blocked_reason <- blocked_reason;
                     record.same_id_retry_eligible <- same_id_retry_eligible;
                     record.acceptance_barrier <- acceptance_barrier;
                     record.submission_t_before <- submission_t_before;
                     record.submission_ordinal <- submission_ordinal;
                     record.submission_count <- submission_count;
                     record.observed_origin_cursor <- observed_origin_cursor;
                     record.stale_earliest_conflict_cursor
                     <- stale_earliest_conflict_cursor;
                     record.stale_conflicts <- stale_conflicts)
                  previous_records;
                [], None, Error (Types.Outbox_commit_persistence_failed message)
              | Ok () ->
                refresh_queryable_outbox database;
                database.receipts <- [];
                let before_projection_revision =
                  projection_revision previous_projection
                in
                let after_projection_revision = projection_revision database.projection in
                let change =
                  Change_dispatcher.event
                    ~generation:database.generation
                    ~before_revision:before_projection_revision
                    ~after_revision:after_projection_revision
                    logical_change_summary
                in
                let callbacks =
                  match change with
                  | None -> []
                  | Some _ ->
                    database.subscriptions
                    |> List.filter_map (fun (subscription : subscription) ->
                      match subscription.lifecycle, subscription.notify with
                      | Active, Some callback -> Some callback
                      | Active, None | Unlistened, _ -> None)
                in
                ( callbacks
                , change
                , Ok
                    { Types.generation = database.generation
                    ; before_projection_revision
                    ; after_projection_revision
                    ; sync_token = sync_token database.sync_revision
                    ; transition = preparation.transition
                    ; activity
                    ; logical_change_summary
                    ; submission_batch
                    } ))))
    in
    ignore callbacks;
    change, outcome)
;;

let authoritative_crypto_item_id database revision index =
  token
    Types.Crypto_item_id.of_string
    (Printf.sprintf
       "crypto-item:v1:authoritative:%d:%d:%s"
       revision
       index
       (Graph.Uuid.to_string database.graph_uuid))
;;

let begin_authoritative database ~expected batch =
  Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
    if database.closed
    then Error Types.Authoritative_database_closed
    else if not (Types.sync_token_equal expected (sync_token database.sync_revision))
    then Error Types.Authoritative_sync_token_conflict
    else (
      let transactions = Types.authoritative_batch_transactions batch in
      let cursors = List.map Types.authoritative_transaction_cursor transactions in
      let rec continuous expected = function
        | [] -> true
        | cursor :: rest ->
          server_cursor_number cursor = expected && continuous (expected + 1) rest
      in
      if not (continuous (database.checkpoint + 1) cursors)
      then Error Types.Authoritative_cursor_discontinuous
      else (
        let wires =
          List.map
            (fun transaction ->
               Types.authoritative_transaction_payload transaction
               |> Types.encoded_transaction_to_string)
            transactions
        in
        let rec collect acc = function
          | [] -> Ok (List.rev acc |> List.concat)
          | wire :: rest ->
            Result.bind (Sync_tx_codec.protected_values wire) (fun values ->
              collect (values :: acc) rest)
        in
        match collect [] wires with
        | Error message -> Error (Types.Authoritative_decode_failed message)
        | Ok protected ->
          let request =
            match protected with
            | [] -> None
            | values ->
              Some
                { unprotection_owner =
                    Authoritative_unprotection (database, database.sync_revision)
                ; unprotection_limit_bytes =
                    database.dependencies.limits.wire_batch_max_bytes
                ; unprotection_items =
                    List.mapi
                      (fun index value ->
                         ( authoritative_crypto_item_id
                             database
                             database.sync_revision
                             index
                         , value ))
                      values
                ; unprotection_consumed = false
                }
          in
          Ok
            ( { authoritative_owner = database
              ; authoritative_revision = database.sync_revision
              ; authoritative_batch = batch
              ; authoritative_wires = wires
              ; authoritative_unprotection = request
              ; authoritative_state = Authoritative_awaiting
              }
            , request ))))
;;

let split_prefix count values =
  let rec loop remaining prefix values =
    if remaining = 0
    then Ok (List.rev prefix, values)
    else (
      match values with
      | [] -> Error "decrypted value count does not match protected values"
      | value :: rest -> loop (remaining - 1) (value :: prefix) rest)
  in
  loop count [] values
;;

let synchronized_record_operations (record : outbox_record) =
  local_operations
    ~fingerprint:record.fingerprint
    ~intent_time_ms:record.intent_time_ms
    ~next_tx:record.planned_tx
    ~sequence:record.sequence
    ~effect_footprint:record.effect_footprint
    ~delete_artifacts:record.delete_artifacts
    record.mutation
  |> Sync_tx_codec.synchronized_operations
;;

let expected_record_transaction_data database record =
  try
    Ok
      (Datascript.transact
         ~tx_meta:[ "skip-store?", Datascript.Bool true ]
         database
         (synchronized_record_operations record)
       : Datascript.tx_report)
        .tx_data
  with
  | exn -> Error (Printexc.to_string exn)
;;

let equal_transaction_data left right = List.sort compare left = List.sort compare right

let transaction_matches_record_at_cursor record cursor root_before transaction_data =
  match expected_origin_cursor record with
  | Error _ -> false
  | Ok expected_cursor ->
    if server_cursor_number cursor <> expected_cursor
    then false
    else (
      match expected_record_transaction_data root_before record with
      | Error _ -> false
      | Ok expected -> equal_transaction_data expected transaction_data)
;;

let transaction_data_shape transaction_data =
  transaction_data
  |> List.map (fun (datom : Datascript.datom) ->
    (if datom.added then "add:" else "retract:") ^ datom.a)
  |> String.concat ","
;;

let validate_active_transaction_origin owner cursor root_before transaction_data =
  let matches =
    List.filter
      (fun record ->
         transaction_matches_record_at_cursor record cursor root_before transaction_data)
      owner.outbox
  in
  match matches with
  | [] -> Ok None
  | [ record ] -> Ok (Some (record.mutation_id, cursor))
  | _ -> Error "authoritative transaction ambiguously matches local submissions"
;;

let validate_active_transaction_origins owner batch transaction_data roots_after =
  let cursors =
    Types.authoritative_batch_transactions batch
    |> List.map Types.authoritative_transaction_cursor
  in
  if
    List.length cursors <> List.length transaction_data
    || List.length transaction_data <> List.length roots_after
  then Error "authoritative transaction origins do not match their cursors"
  else (
    let rec contexts previous cursors transaction_data roots_after reversed =
      match cursors, transaction_data, roots_after with
      | cursor :: cursor_rest, data :: data_rest, root_after :: root_rest ->
        contexts
          root_after
          cursor_rest
          data_rest
          root_rest
          ((cursor, data, previous) :: reversed)
      | [], [], [] -> List.rev reversed
      | _ -> invalid_arg "authoritative transaction origin context mismatch"
    in
    let contexts =
      contexts (authoritative_database owner) cursors transaction_data roots_after []
    in
    let validated =
      List.fold_left
        (fun result (cursor, data, root_before) ->
           Result.bind result (fun reversed ->
             Result.map
               (fun evidence ->
                  Option.fold
                    ~none:reversed
                    ~some:(fun value -> value :: reversed)
                    evidence)
               (validate_active_transaction_origin owner cursor root_before data)))
        (Ok [])
        contexts
    in
    Result.bind validated (fun reversed ->
      let validated = List.rev reversed in
      let previous_checkpoint = owner.checkpoint in
      let through = server_cursor_number (Types.authoritative_batch_through batch) in
      let validate_accepted result (record : outbox_record) =
        Result.bind result (fun () ->
          match record.transport_state with
          | Types.Accepted_pending_authoritative _ ->
            Result.bind (expected_origin_cursor record) (fun expected ->
              if expected <= previous_checkpoint
              then (
                match record.observed_origin_cursor with
                | Some cursor when server_cursor_number cursor = expected -> Ok ()
                | None | Some _ ->
                  Error "accepted transaction has no durable origin evidence")
              else if expected <= through
              then
                if
                  List.exists
                    (fun (origin, cursor) ->
                       Graph.Uuid.equal origin record.mutation_id
                       && server_cursor_number cursor = expected)
                    validated
                then Ok ()
                else (
                  let actual =
                    contexts
                    |> List.find_opt (fun (cursor, _, _) ->
                      server_cursor_number cursor = expected)
                    |> Option.map (fun (_, data, _) -> transaction_data_shape data)
                    |> Option.value ~default:"missing-cursor"
                  in
                  let expected_shape =
                    contexts
                    |> List.find_opt (fun (cursor, _, _) ->
                      server_cursor_number cursor = expected)
                    |> fun context ->
                    Option.bind context (fun (_, _, root_before) ->
                      expected_record_transaction_data root_before record
                      |> Result.to_option)
                    |> Option.map transaction_data_shape
                    |> Option.value ~default:"simulation-failed"
                  in
                  Error
                    ("accepted transaction payload mismatch: expected="
                     ^ expected_shape
                     ^ "; actual="
                     ^ actual))
              else Ok ())
          | Queued
          | Submitted _
          | Delete_barrier_rejected_pending_authoritative _
          | Blocked -> Ok ())
      in
      Result.map
        (fun () -> validated)
        (List.fold_left validate_accepted (Ok ()) owner.outbox)))
;;

let entity_attribute_values database entity attribute =
  Datascript.datoms database Datascript.Eavt ~e:entity ~a:attribute ()
  |> List.of_seq
  |> List.map (fun (datom : Datascript.datom) -> datom.v)
;;

let entities_for_uuids database uuids =
  List.filter_map
    (fun uuid -> Option.map (fun entity -> uuid, entity) (entity_of_uuid database uuid))
    uuids
;;

let referenced_sources database attribute targets =
  List.concat_map
    (fun (_uuid, target) ->
       Datascript.datoms
         database
         Datascript.Avet
         ~a:attribute
         ~v:(Datascript.Ref target)
         ()
       |> List.of_seq
       |> List.map (fun (datom : Datascript.datom) -> datom.e))
    targets
  |> List.sort_uniq Int.compare
;;

let descendant_members database frontier =
  referenced_sources database "block/parent" frontier
  |> List.filter_map (uuid_of_entity database)
  |> List.sort_uniq Graph.Uuid.compare
;;

let page_lifecycle database uuid =
  match entity_of_uuid database uuid with
  | None -> None
  | Some entity ->
    Some
      ( entity_attribute_values database entity "block/journal-day"
      , entity_attribute_values database entity "logseq.property/deleted-at"
      , entity_attribute_values database entity "logseq.property/built-in?"
      , entity_attribute_values database entity "logseq.property/hide?"
      , entity_attribute_values database entity "block/tags" )
;;

let source_attribute_changed before after sources attribute =
  List.exists
    (fun entity ->
       entity_attribute_values before entity attribute
       <> entity_attribute_values after entity attribute)
    sources
;;

let delete_conflict_kinds_between before after (record : outbox_record) =
  let when_true condition value = if condition then Some value else None in
  let artifacts = Option.get record.delete_artifacts in
  let frontier = artifacts.frontier in
  let delete_root =
    match record.mutation with
    | Types.Delete_blocks { root; _ } -> root
    | Save_block _
    | Insert_blocks _
    | Create_journal_page _
    | Set_task_status _
    | Clear_task_status _ -> assert false
  in
  let before_frontier = entities_for_uuids before frontier in
  let after_frontier = entities_for_uuids after frontier in
  let frontier_changed =
    List.exists
      (fun uuid -> block_of_database before uuid <> block_of_database after uuid)
      frontier
  in
  let descendant_changed =
    descendant_members before before_frontier <> descendant_members after after_frontier
  in
  let before_incoming = referenced_sources before "block/refs" before_frontier in
  let after_incoming = referenced_sources after "block/refs" after_frontier in
  let incoming_changed = before_incoming <> after_incoming in
  let incoming_sources = List.sort_uniq Int.compare (before_incoming @ after_incoming) in
  let comment_changed =
    referenced_sources before "logseq.property.comments/blocks" before_frontier
    <> referenced_sources after "logseq.property.comments/blocks" after_frontier
  in
  let property_guard_state database (guard : delete_property_guard) =
    let root_entity = entity_of_uuid database delete_root in
    let property_entity = entity_of_uuid database guard.property_uuid in
    let replacement_entity = entity_of_uuid database guard.replacement_uuid in
    let entity_values entity attribute =
      Option.fold
        ~none:[]
        ~some:(fun entity -> entity_attribute_values database entity attribute)
        entity
    in
    let holders =
      match root_entity with
      | None -> []
      | Some root_entity ->
        Datascript.datoms database Datascript.Aevt ~a:guard.property_ident ()
        |> Seq.filter_map (fun (datom : Datascript.datom) ->
          match datom.v with
          | Datascript.Ref target when target = root_entity ->
            Some
              ( uuid_of_entity database datom.e
              , entity_attribute_values database datom.e guard.property_ident )
          | _ -> None)
        |> List.of_seq
        |> List.sort compare
    in
    ( root_entity
    , entity_values root_entity "logseq.property/created-from-property"
    , entity_values root_entity "block/closed-value-property"
    , property_entity
    , entity_values property_entity "db/ident"
    , entity_values property_entity "logseq.property/default-value"
    , replacement_entity
    , entity_values replacement_entity "block/uuid"
    , holders )
  in
  let property_holder_entities database =
    record.delete_artifacts
    |> Option.to_list
    |> List.concat_map (fun artifacts -> artifacts.property_patches)
    |> List.filter_map (fun (patch : delete_property_patch) ->
      Option.map
        (fun entity -> entity, patch.property_ident)
        (entity_of_uuid database patch.holder_uuid))
  in
  let before_property_holders = property_holder_entities before in
  let after_property_holders = property_holder_entities after in
  let default_property_holder_changed =
    match artifacts.property_guard with
    | None -> false
    | Some guard -> property_guard_state before guard <> property_guard_state after guard
  in
  let rewritten_title_changed =
    source_attribute_changed before after incoming_sources "block/title"
  in
  let footprint_entities =
    (List.map snd before_frontier
     @ List.map snd after_frontier
     @ incoming_sources
     @ List.map fst before_property_holders
     @ List.map fst after_property_holders
     @
     match artifacts.property_guard with
     | None -> []
     | Some _ ->
       List.filter_map
         Fun.id
         [ entity_of_uuid before delete_root; entity_of_uuid after delete_root ])
    |> List.sort_uniq Int.compare
  in
  let timestamp_changed =
    source_attribute_changed before after footprint_entities "block/created-at"
    || source_attribute_changed before after footprint_entities "block/updated-at"
  in
  let transaction_metadata_changed =
    source_attribute_changed before after footprint_entities "block/tx-id"
  in
  let page_lifecycle_changed =
    List.exists
      (fun uuid -> page_lifecycle before uuid <> page_lifecycle after uuid)
      record.effect_footprint.page_uuids
  in
  [ when_true frontier_changed Types.Frontier_fact_changed
  ; when_true descendant_changed Types.Descendant_closure_changed
  ; when_true incoming_changed Types.Incoming_reference_changed
  ; when_true comment_changed (Types.Auxiliary_write_footprint_changed Comment_area)
  ; when_true
      default_property_holder_changed
      (Types.Auxiliary_write_footprint_changed Default_property_holder)
  ; when_true
      rewritten_title_changed
      (Types.Auxiliary_write_footprint_changed Rewritten_source_title)
  ; when_true timestamp_changed (Types.Auxiliary_write_footprint_changed Timestamp)
  ; when_true
      transaction_metadata_changed
      (Types.Auxiliary_write_footprint_changed Transaction_metadata)
  ; when_true page_lifecycle_changed Types.Page_lifecycle_changed
  ]
  |> List.filter_map Fun.id
  |> List.sort_uniq compare
;;

let classify_stale_deletes owner batch transactions roots_after =
  let cursors =
    Types.authoritative_batch_transactions batch
    |> List.map Types.authoritative_transaction_cursor
  in
  let rec classify_record
            record
            batch_id
            rejection_through
            previous
            earliest
            conflicts
            boundary_root
            cursors
            transactions
            roots
    =
    match cursors, transactions, roots with
    | [], [], [] ->
      let conflicts = List.sort_uniq compare conflicts in
      (match boundary_root with
       | None -> Ok (`Pending (record.mutation_id, earliest, conflicts))
       | Some root_at_boundary ->
         (match record.mutation, earliest with
          | Types.Delete_blocks _, Some earliest ->
            Ok
              (`Remote_won
                  (record.mutation_id, batch_id, earliest, rejection_through, conflicts))
          | Delete_blocks { root; _ }, None
            when Option.is_none (block_of_database root_at_boundary root) ->
            Ok (`No_change (record.mutation_id, batch_id))
          | Delete_blocks _, None -> Ok (`Blocked (record.mutation_id, batch_id))
          | _ -> Error "stale delete state contains a non-delete mutation"))
    | cursor :: cursor_rest, _operations :: operation_rest, after :: root_rest ->
      if server_cursor_number cursor > server_cursor_number rejection_through
      then
        classify_record
          record
          batch_id
          rejection_through
          after
          earliest
          conflicts
          boundary_root
          cursor_rest
          operation_rest
          root_rest
      else (
        let current_conflicts =
          match record.mutation with
          | Types.Delete_blocks { root; _ } ->
            if Option.is_some (block_of_database after root)
            then delete_conflict_kinds_between previous after record
            else []
          | _ -> []
        in
        let is_conflict = current_conflicts <> [] in
        let earliest =
          if is_conflict && Option.is_none earliest then Some cursor else earliest
        in
        let conflicts = current_conflicts @ conflicts in
        let boundary_root =
          if Types.Server_cursor.equal cursor rejection_through
          then Some after
          else boundary_root
        in
        classify_record
          record
          batch_id
          rejection_through
          after
          earliest
          conflicts
          boundary_root
          cursor_rest
          operation_rest
          root_rest)
    | _ -> Error "authoritative transaction roots do not match their cursors"
  in
  let rec collect updates remote_won no_change blocked = function
    | [] ->
      Ok (List.rev updates, List.rev remote_won, List.rev no_change, List.rev blocked)
    | (record : outbox_record) :: rest ->
      (match record.transport_state with
       | Types.Delete_barrier_rejected_pending_authoritative { batch_id; through } ->
         Result.bind
           (classify_record
              record
              batch_id
              through
              (authoritative_database owner)
              record.stale_earliest_conflict_cursor
              record.stale_conflicts
              None
              cursors
              transactions
              roots_after)
           (function
             | `Pending update ->
               collect (update :: updates) remote_won no_change blocked rest
             | `Remote_won outcome ->
               collect updates (outcome :: remote_won) no_change blocked rest
             | `No_change outcome ->
               collect updates remote_won (outcome :: no_change) blocked rest
             | `Blocked outcome ->
               collect updates remote_won no_change (outcome :: blocked) rest)
       | Queued | Submitted _ | Accepted_pending_authoritative _ | Blocked ->
         collect updates remote_won no_change blocked rest)
  in
  collect [] [] [] [] owner.outbox
;;

let same_authoritative_decrypted_input left right =
  match left, right with
  | None, None -> true
  | Some (left_request, left_values), Some (right_request, right_values) ->
    left_request == right_request && left_values = right_values
  | None, Some _ | Some _, None -> false
;;

let prepare_authoritative_candidate preparation ~decrypted =
  match preparation.authoritative_state with
  | Authoritative_ready candidate
    when same_authoritative_decrypted_input
           candidate.authoritative_decrypted_input
           decrypted -> Ok (`Candidate candidate)
  | Authoritative_ready _ | Authoritative_deferred_state | Authoritative_consumed ->
    Error Types.Authoritative_preparation_consumed
  | Authoritative_awaiting ->
    let decrypted_values =
      match preparation.authoritative_unprotection, decrypted with
      | None, None -> Ok []
      | None, Some _ -> Error Types.Authoritative_crypto_unexpected
      | Some _, None -> Error Types.Authoritative_crypto_required
      | Some request, Some (actual_request, plaintexts) when actual_request == request ->
        (match validate_decrypted_values ~request ~plaintexts with
         | Error error -> Error (Types.Authoritative_crypto_error error)
         | Ok () -> Ok (List.map snd plaintexts))
      | Some _, Some _ -> Error Types.Authoritative_crypto_unexpected
    in
    Result.bind decrypted_values (fun plaintexts ->
      let rec decode database decoded expected_tx_data roots_after remaining wires =
        match wires with
        | [] ->
          if remaining = []
          then
            Ok
              (List.rev decoded, List.rev expected_tx_data, List.rev roots_after, database)
          else Error "decrypted value count does not match protected values"
        | wire :: rest ->
          Result.bind (Sync_tx_codec.protected_values wire) (fun protected ->
            Result.bind
              (split_prefix (List.length protected) remaining)
              (fun (plain, remaining) ->
                 Result.bind
                   (Sync_tx_codec.decode ~db:database ~decrypted_values:plain wire)
                   (fun operations ->
                      try
                        let report =
                          Datascript.with_tx
                            ~tx_meta:[ "skip-store?", Datascript.Bool true ]
                            database
                            operations
                        in
                        decode
                          report.db_after
                          (operations :: decoded)
                          (report.tx_data :: expected_tx_data)
                          (report.db_after :: roots_after)
                          remaining
                          rest
                      with
                      | exn -> Error (Printexc.to_string exn))))
      in
      match
        decode
          (authoritative_database preparation.authoritative_owner)
          []
          []
          []
          plaintexts
          preparation.authoritative_wires
      with
      | Error message -> Error (Types.Authoritative_decode_failed message)
      | Ok (transactions, expected_tx_data, roots_after, database) ->
        (match
           validate_active_transaction_origins
             preparation.authoritative_owner
             preparation.authoritative_batch
             expected_tx_data
             roots_after
         with
         | Error message -> Error (Types.Authoritative_integrity_failure message)
         | Ok validated_origins ->
           preparation.authoritative_state <- Authoritative_consumed;
           Option.iter
             (fun request -> request.unprotection_consumed <- true)
             preparation.authoritative_unprotection;
           let unresolved_submitted_deletes =
             List.filter_map
               (fun (record : outbox_record) ->
                  match record.transport_state, record.mutation with
                  | Types.Submitted batch_id, Types.Delete_blocks _ ->
                    Some (record, batch_id)
                  | ( Submitted _
                    , ( Save_block _
                      | Insert_blocks _
                      | Create_journal_page _
                      | Set_task_status _
                      | Clear_task_status _ ) ) -> None
                  | ( ( Queued
                      | Accepted_pending_authoritative _
                      | Delete_barrier_rejected_pending_authoritative _
                      | Blocked )
                    , _ ) -> None)
               preparation.authoritative_owner.outbox
           in
           (match
              classify_stale_deletes
                preparation.authoritative_owner
                preparation.authoritative_batch
                transactions
                roots_after
            with
            | Error message -> Error (Types.Authoritative_integrity_failure message)
            | Ok (stale_updates, stale_remote_won, stale_no_change, stale_blocked) ->
              let rec transaction_contexts previous transactions transaction_data roots =
                match transactions, transaction_data, roots with
                | ( transaction :: transaction_rest
                  , data :: data_rest
                  , root_after :: root_rest ) ->
                  ( Types.authoritative_transaction_cursor transaction
                  , data
                  , previous
                  , root_after )
                  :: transaction_contexts root_after transaction_rest data_rest root_rest
                | [], [], [] -> []
                | _ -> invalid_arg "authoritative transaction context mismatch"
              in
              let contexts =
                transaction_contexts
                  (authoritative_database preparation.authoritative_owner)
                  (Types.authoritative_batch_transactions preparation.authoritative_batch)
                  expected_tx_data
                  roots_after
              in
              let classify_submitted_delete (record, batch_id) =
                match record.submission_t_before with
                | None ->
                  Error
                    (Types.Authoritative_integrity_failure
                       "submitted delete omitted its durable t_before")
                | Some t_before ->
                  (match
                     List.find_opt
                       (fun (cursor, _, _, _) ->
                          server_cursor_number cursor > server_cursor_number t_before)
                       contexts
                   with
                   | None -> Ok (`Deferred batch_id)
                   | Some (cursor, transaction_data, root_before, root_after) ->
                     if
                       transaction_matches_record_at_cursor
                         record
                         cursor
                         root_before
                         transaction_data
                     then Ok (`Deferred batch_id)
                     else (
                       let conflicts =
                         delete_conflict_kinds_between root_before root_after record
                       in
                       if conflicts = []
                       then Ok (`Deferred batch_id)
                       else
                         Ok
                           (`Remote_won (record.mutation_id, batch_id, cursor, conflicts))))
              in
              let classified =
                List.fold_left
                  (fun result submitted ->
                     Result.bind result (fun outcomes ->
                       Result.map
                         (fun outcome -> outcome :: outcomes)
                         (classify_submitted_delete submitted)))
                  (Ok [])
                  unresolved_submitted_deletes
              in
              Result.bind classified (fun classified ->
                match
                  List.find_map
                    (function
                      | `Deferred batch_id -> Some batch_id
                      | `Remote_won _ -> None)
                    (List.rev classified)
                with
                | Some batch_id ->
                  preparation.authoritative_state <- Authoritative_deferred_state;
                  Ok (`Deferred (Types.Await_submission_outcome batch_id))
                | None ->
                  let submitted_remote_won =
                    List.filter_map
                      (function
                        | `Remote_won outcome -> Some outcome
                        | `Deferred _ -> None)
                      (List.rev classified)
                  in
                  let candidate =
                    { authoritative_preparation = preparation
                    ; authoritative_decrypted_input = decrypted
                    ; authoritative_transactions = transactions
                    ; authoritative_expected_tx_data = expected_tx_data
                    ; authoritative_roots_after = roots_after
                    ; validated_origins
                    ; submitted_remote_won
                    ; stale_updates
                    ; stale_remote_won
                    ; stale_no_change
                    ; stale_blocked
                    ; authoritative_db_after = database
                    }
                  in
                  preparation.authoritative_state <- Authoritative_ready candidate;
                  Ok (`Candidate candidate)))))
;;

let rec logical_tree_is_present snapshot ~parent (tree : Types.block_tree) =
  match logical_block_at snapshot tree.uuid with
  | None -> false
  | Some (record : Types.block_record) ->
    Graph.Uuid.equal record.block.parent parent
    && String.equal record.block.title tree.title
    && List.for_all (logical_tree_is_present snapshot ~parent:tree.uuid) tree.children
;;

let logical_snapshot_satisfies_mutation snapshot = function
  | Types.Save_block { block; title; _ } ->
    logical_block_at snapshot block
    |> option_satisfies (fun (record : Types.block_record) ->
      String.equal record.block.title title)
  | Insert_blocks { parent; tree; _ } -> logical_tree_is_present snapshot ~parent tree
  | Delete_blocks { root; _ } -> Option.is_none (logical_block_at snapshot root)
  | Create_journal_page { page; title; journal_day; _ } ->
    logical_page_at snapshot page
    |> option_satisfies (fun (record : Types.page_record) ->
      String.equal record.page.title title
      && record.page.kind = Graph.Journal_page { journal_day })
  | Set_task_status { block; status; _ } ->
    logical_block_at snapshot block
    |> option_satisfies (fun (record : Types.block_record) ->
      record.task_status = Some status)
  | Clear_task_status { block; _ } ->
    logical_block_at snapshot block
    |> option_satisfies (fun (record : Types.block_record) ->
      Option.is_none record.task_status)
;;

let ordinary_effect_footprint snapshot = function
  | Types.Save_block { block; _ }
  | Set_task_status { block; _ }
  | Clear_task_status { block; _ } ->
    { block_uuids = [ block ]; page_uuids = []; structure_interests = [] }
  | Insert_blocks { tree; parent; _ } ->
    let page =
      match logical_block_at snapshot parent with
      | Some (record : Types.block_record) -> record.block.page
      | None -> parent
    in
    { block_uuids = tree_uuids tree
    ; page_uuids = [ page ]
    ; structure_interests =
        [ Types.Children_interest parent; Types.Page_tree_interest page ]
    }
  | Create_journal_page { page; _ } ->
    { block_uuids = []
    ; page_uuids = [ page ]
    ; structure_interests = [ Types.Journal_index_interest ]
    }
  | Delete_blocks _ -> invalid_arg "ordinary_effect_footprint: delete mutation"
;;

let introduced_uuids = function
  | Types.Insert_blocks { tree; _ } -> tree_uuids tree
  | Create_journal_page { page; _ } -> [ page ]
  | Save_block _ | Delete_blocks _ | Set_task_status _ | Clear_task_status _ -> []
;;

let unavailable_dependency unavailable uuid =
  List.find_map
    (fun (candidate, mutation_id) ->
       if Graph.Uuid.equal candidate uuid then Some mutation_id else None)
    unavailable
;;

let missing_replan_dependency snapshot mutation =
  let missing uuid present = if present then None else Some uuid in
  match mutation with
  | Types.Save_block { block; _ }
  | Set_task_status { block; _ }
  | Clear_task_status { block; _ } ->
    missing block (Option.is_some (logical_block_at snapshot block))
  | Insert_blocks { parent; _ } ->
    let block_exists = Option.is_some (logical_block_at snapshot parent) in
    let page_exists =
      match logical_page_at snapshot parent with
      | Some (record : Types.page_record) -> not record.page.recycled
      | None -> false
    in
    missing parent (block_exists || page_exists)
  | Create_journal_page { page; _ } ->
    if Option.is_some (logical_page_at snapshot page) then Some page else None
  | Delete_blocks _ -> None
;;

let blocked_replan_record record reason =
  { record with
    transport_state = Types.Blocked
  ; dependency_shadows = empty_dependency_shadows
  ; protected_transaction = None
  ; blocked_prior_state = Some record.transport_state
  ; blocked_reason = Some reason
  ; same_id_retry_eligible = false
  ; acceptance_barrier = None
  }
;;

let replan_queued_ordinary database authoritative_database records =
  let records =
    List.stable_sort
      (fun (left : outbox_record) (right : outbox_record) ->
         Int.compare left.sequence right.sequence)
      records
  in
  let add_indexed_record records index select (record : outbox_record) =
    ( List.fold_left
        (fun index uuid ->
           let key = Graph.Uuid.to_string uuid in
           let preceding = Uuid_map.find_opt key index |> Option.value ~default:[] in
           Uuid_map.add key (preceding @ [ record ]) index)
        index
        (select (record.effect_footprint : effect_footprint))
    , record :: records )
  in
  let add_record records block_effects page_effects children_effects record =
    if not (record_is_logically_active record)
    then records, block_effects, page_effects, children_effects
    else (
      let block_effects, records =
        add_indexed_record records block_effects (fun value -> value.block_uuids) record
      in
      let page_effects, _ =
        add_indexed_record [] page_effects (fun value -> value.page_uuids) record
      in
      let children_effects, _ =
        add_indexed_record
          []
          children_effects
          (fun value ->
             List.filter_map
               (function
                 | Types.Children_interest parent -> Some parent
                 | Page_tree_interest _ | Journal_index_interest -> None)
               value.structure_interests)
          record
      in
      records, block_effects, page_effects, children_effects)
  in
  let rec loop
            accumulated
            block_effects
            page_effects
            children_effects
            unavailable
            replanned
            no_change
            blocked
    = function
    | [] -> List.rev accumulated, List.rev replanned, List.rev no_change, List.rev blocked
    | (record : outbox_record) :: rest ->
      (match record.transport_state, record.mutation with
       | Types.Queued, (Types.Delete_blocks _ as _mutation) ->
         let accumulated, block_effects, page_effects, children_effects =
           add_record accumulated block_effects page_effects children_effects record
         in
         loop
           accumulated
           block_effects
           page_effects
           children_effects
           unavailable
           replanned
           no_change
           blocked
           rest
       | Types.Queued, mutation ->
         let snapshot =
           { owner = database
           ; version =
               { Types.generation = database.generation
               ; projection_revision = projection_revision database.projection
               }
           ; authoritative_database = Some authoritative_database
           ; outbox = Some (List.rev accumulated)
           ; block_effects = Some block_effects
           ; page_effects = Some page_effects
           ; children_effects = Some children_effects
           ; released = false
           ; active_reads = 0
           ; drain_waiters = []
           }
         in
         if logical_snapshot_satisfies_mutation snapshot mutation
         then
           loop
             accumulated
             block_effects
             page_effects
             children_effects
             unavailable
             replanned
             (record :: no_change)
             blocked
             rest
         else (
           match missing_replan_dependency snapshot mutation with
           | Some uuid ->
             let reason =
               match unavailable_dependency unavailable uuid with
               | Some failed_mutation_id -> Types.Dependency_blocked failed_mutation_id
               | None -> Types.Planner_dependency_changed
             in
             let record = blocked_replan_record record reason in
             let unavailable =
               List.fold_left
                 (fun unavailable uuid -> (uuid, record.mutation_id) :: unavailable)
                 unavailable
                 (introduced_uuids mutation)
             in
             loop
               (record :: accumulated)
               block_effects
               page_effects
               children_effects
               unavailable
               replanned
               no_change
               (record :: blocked)
               rest
           | None ->
             let effect_footprint = ordinary_effect_footprint snapshot mutation in
             let planned_tx = authoritative_database.Datascript.max_tx + 1 in
             let record =
               { record with
                 normalized_transaction =
                   normalized_transaction_in
                     authoritative_database
                     ~fingerprint:record.fingerprint
                     ~intent_time_ms:record.intent_time_ms
                     ~planned_tx
                     ~sequence:record.sequence
                     ~effect_footprint
                     ~delete_artifacts:None
                     mutation
               ; effect_footprint
               ; dependency_shadows = empty_dependency_shadows
               ; planned_tx
               ; protected_transaction = None
               }
             in
             let accumulated, block_effects, page_effects, children_effects =
               add_record accumulated block_effects page_effects children_effects record
             in
             loop
               accumulated
               block_effects
               page_effects
               children_effects
               unavailable
               (record :: replanned)
               no_change
               blocked
               rest)
       | Types.Blocked, mutation ->
         let unavailable =
           List.fold_left
             (fun unavailable uuid -> (uuid, record.mutation_id) :: unavailable)
             unavailable
             (introduced_uuids mutation)
         in
         loop
           (record :: accumulated)
           block_effects
           page_effects
           children_effects
           unavailable
           replanned
           no_change
           blocked
           rest
       | ( ( Types.Submitted _
           | Accepted_pending_authoritative _
           | Delete_barrier_rejected_pending_authoritative _ )
         , _ ) ->
         let accumulated, block_effects, page_effects, children_effects =
           add_record accumulated block_effects page_effects children_effects record
         in
         loop
           accumulated
           block_effects
           page_effects
           children_effects
           unavailable
           replanned
           no_change
           blocked
           rest)
  in
  loop [] Uuid_map.empty Uuid_map.empty Uuid_map.empty [] [] [] [] records
;;

let changed_entity_uuids before after transaction_data =
  transaction_data
  |> List.concat
  |> List.map (fun (datom : Datascript.datom) -> datom.e)
  |> List.sort_uniq Int.compare
  |> List.concat_map (fun entity ->
    [ uuid_of_entity before entity; uuid_of_entity after entity ]
    |> List.filter_map Fun.id)
  |> List.sort_uniq Graph.Uuid.compare
;;

let page_dependents database page ~maximum =
  match entity_of_uuid database page with
  | None -> [], false
  | Some page_entity ->
    let rec collect remaining reversed sequence =
      match sequence () with
      | Seq.Nil -> List.rev reversed, false
      | Seq.Cons (_, _) when remaining = 0 -> List.rev reversed, true
      | Seq.Cons ((datom : Datascript.datom), rest) ->
        let reversed, remaining =
          match uuid_of_entity database datom.e with
          | None -> reversed, remaining
          | Some uuid -> uuid :: reversed, remaining - 1
        in
        collect remaining reversed rest
    in
    collect
      maximum
      []
      (Datascript.datoms
         database
         Datascript.Avet
         ~a:"block/page"
         ~v:(Datascript.Ref page_entity)
         ())
;;

let journal_membership = function
  | Some (record : Types.page_record) when not record.page.recycled ->
    (match record.page.kind with
     | Graph.Journal_page { journal_day } -> Some journal_day
     | Ordinary_page | Class_page | Property_page | Hidden_page | Built_in_page -> None)
  | None | Some _ -> None
;;

let logical_change_footprint
      ~before
      ~after
      ~authoritative_before
      ~authoritative_after
      ~transaction_data
      ~outbox_effects
  =
  let direct =
    changed_entity_uuids authoritative_before authoritative_after transaction_data
  in
  let outbox_blocks, outbox_pages =
    List.fold_left
      (fun (blocks, pages) (footprint : effect_footprint) ->
         footprint.block_uuids @ blocks, footprint.page_uuids @ pages)
      ([], [])
      outbox_effects
  in
  let page_candidates = List.sort_uniq Graph.Uuid.compare (direct @ outbox_pages) in
  let changed_pages =
    List.filter
      (fun uuid -> logical_page_at before uuid <> logical_page_at after uuid)
      page_candidates
  in
  let maximum_dependents = before.owner.dependencies.limits.change_max_items in
  let page_dependent_blocks, dependent_overflow =
    let rec collect remaining reversed = function
      | [] -> List.rev reversed, false
      | _ when remaining = 0 -> List.rev reversed, true
      | page :: rest ->
        let before_values, before_overflow =
          page_dependents authoritative_before page ~maximum:remaining
        in
        let remaining = remaining - List.length before_values in
        if before_overflow || remaining = 0
        then List.rev_append reversed before_values, true
        else (
          let after_values, after_overflow =
            page_dependents authoritative_after page ~maximum:remaining
          in
          let remaining = remaining - List.length after_values in
          if after_overflow
          then List.rev_append reversed (before_values @ after_values), true
          else
            collect
              remaining
              (List.rev_append after_values (List.rev_append before_values reversed))
              rest)
    in
    collect maximum_dependents [] changed_pages
  in
  let block_candidates =
    List.sort_uniq Graph.Uuid.compare (direct @ outbox_blocks @ page_dependent_blocks)
  in
  let block_uuids =
    List.filter
      (fun uuid ->
         let before_value = logical_block_at before uuid in
         let after_value = logical_block_at after uuid in
         before_value <> after_value)
      block_candidates
  in
  let parents, membership_pages =
    List.fold_left
      (fun (parents, pages) uuid ->
         let before = logical_block_at before uuid in
         let after = logical_block_at after uuid in
         let membership_equal =
           match before, after with
           | Some (before : Types.block_record), Some (after : Types.block_record) ->
             Graph.Uuid.equal before.block.parent after.block.parent
             && Graph.Uuid.equal before.block.page after.block.page
           | None, None -> true
           | None, Some _ | Some _, None -> false
         in
         if membership_equal
         then parents, pages
         else (
           let add_membership (parents, pages) = function
             | None -> parents, pages
             | Some (record : Types.block_record) ->
               record.block.parent :: parents, record.block.page :: pages
           in
           add_membership (add_membership (parents, pages) before) after))
      ([], [])
      block_uuids
  in
  let journal_changed =
    List.exists
      (fun uuid ->
         journal_membership (logical_page_at before uuid)
         <> journal_membership (logical_page_at after uuid))
      changed_pages
  in
  let membership_pages = List.sort_uniq Graph.Uuid.compare membership_pages in
  let structure_interests =
    List.map
      (fun parent -> Types.Children_interest parent)
      (List.sort_uniq Graph.Uuid.compare parents)
    @ List.map (fun page -> Types.Page_tree_interest page) membership_pages
    @ if journal_changed then [ Types.Journal_index_interest ] else []
  in
  ( block_uuids
  , List.sort_uniq Graph.Uuid.compare (changed_pages @ membership_pages)
  , List.sort_uniq compare structure_interests
  , dependent_overflow )
;;

let storage_session_error = function
  | Logseq_db_storage.Storage_session.Closed -> "storage session is closed"
  | Fatal message | Stage_failed message | Persistence_failed message -> message
  | Already_consumed -> "staged authoritative transaction was already consumed"
;;

let replay_authoritative database prepared =
  let transactions = prepared.authoritative_transactions in
  let expected = prepared.authoritative_expected_tx_data in
  let count = List.length transactions in
  if List.length expected <> count
  then Error "authoritative replay expectation count changed"
  else (
    database.authoritative_reports := [];
    let commit_id =
      Printf.sprintf
        "overlay-commit:v1:%d"
        (prepared.authoritative_preparation.authoritative_revision + 1)
    in
    try
      List.iteri
        (fun ordinal operations ->
           ignore
             (Datascript.transact_conn
                ~tx_meta:
                  [ "skip-store?", Datascript.Bool true
                  ; "logseq-overlay/commit-id", String commit_id
                  ; "logseq-overlay/batch-ordinal", Int ordinal
                  ; "logseq-overlay/batch-count", Int count
                  ]
                database.authoritative_connection
                operations
              : Datascript.tx_report))
        transactions;
      let reports = List.rev !(database.authoritative_reports) in
      let matches ordinal expected (report : Datascript.tx_report) =
        report.tx_data = expected
        && List.assoc_opt "logseq-overlay/commit-id" report.tx_meta
           = Some (Datascript.String commit_id)
        && List.assoc_opt "logseq-overlay/batch-ordinal" report.tx_meta
           = Some (Datascript.Int ordinal)
        && List.assoc_opt "logseq-overlay/batch-count" report.tx_meta
           = Some (Datascript.Int count)
      in
      if
        List.length reports = count
        && List.for_all
             Fun.id
             (List.mapi
                (fun ordinal (expected, report) -> matches ordinal expected report)
                (List.combine expected reports))
      then Ok ()
      else Error "authoritative sparse listener replay diverged from staged reports"
    with
    | exn -> Error (Printexc.to_string exn))
;;

let commit_authoritative_candidate database prepared =
  serialize_commit database (fun () ->
    let callbacks, change, outcome =
      Eio.Mutex.use_rw ~protect:true database.lock (fun () ->
        let preparation = prepared.authoritative_preparation in
        if preparation.authoritative_owner != database
        then [], None, Error Types.Authoritative_commit_generation_invalidated
        else if database.closed
        then [], None, Error Types.Authoritative_commit_database_closed
        else if database.sync_revision <> preparation.authoritative_revision
        then [], None, Error Types.Authoritative_commit_token_conflict
        else (
          match
            Logseq_db_storage.Storage_session.stage_transact_batch
              database.storage_session
              ~authoritative_before:(authoritative_database database)
              prepared.authoritative_transactions
          with
          | Error error ->
            ( []
            , None
            , Error
                (Types.Authoritative_commit_persistence_failed
                   (storage_session_error error)) )
          | Ok staged ->
            let through =
              Types.authoritative_batch_through preparation.authoritative_batch
              |> server_cursor_number
            in
            let authoritative_after = prepared.authoritative_db_after in
            let authoritative_before = authoritative_database database in
            let remote_won_queued =
              List.filter_map
                (fun (record : outbox_record) ->
                   match record.transport_state, record.mutation with
                   | Queued, Types.Delete_blocks { root; _ } ->
                     let after = block_of_database authoritative_after root in
                     let conflicts =
                       delete_conflict_kinds_between
                         authoritative_before
                         authoritative_after
                         record
                     in
                     if conflicts <> [] && Option.is_some after
                     then Some (record, conflicts)
                     else None
                   | _ -> None)
                database.outbox
            in
            let remote_won_submitted =
              List.filter_map
                (fun (mutation_id, batch_id, cursor, conflicts) ->
                   List.find_opt
                     (fun (record : outbox_record) ->
                        Graph.Uuid.equal record.mutation_id mutation_id)
                     database.outbox
                   |> Option.map (fun record -> record, batch_id, cursor, conflicts))
                prepared.submitted_remote_won
            in
            let record_for id =
              List.find_opt
                (fun (record : outbox_record) -> Graph.Uuid.equal record.mutation_id id)
                database.outbox
            in
            let stale_remote_won =
              List.filter_map
                (fun (id, batch_id, earliest, rejection_through, conflicts) ->
                   record_for id
                   |> Option.map (fun record ->
                     record, batch_id, earliest, rejection_through, conflicts))
                prepared.stale_remote_won
            in
            let resolved_stale =
              List.filter_map
                (fun (id, batch_id) ->
                   record_for id |> Option.map (fun record -> record, batch_id))
                prepared.stale_no_change
            in
            let blocked_stale =
              List.filter_map
                (fun (id, batch_id) ->
                   record_for id |> Option.map (fun record -> record, batch_id))
                prepared.stale_blocked
            in
            let covered_accepted =
              List.filter
                (fun (record : outbox_record) ->
                   match record.transport_state, record.acceptance_barrier with
                   | Accepted_pending_authoritative _, Some barrier ->
                     server_cursor_number barrier.through <= through
                   | _ -> false)
                database.outbox
            in
            let authoritative_root_at barrier =
              let target = server_cursor_number barrier.Types.through in
              if target <= database.checkpoint
              then Some authoritative_before
              else
                List.combine
                  (Types.authoritative_batch_transactions preparation.authoritative_batch)
                  prepared.authoritative_roots_after
                |> List.find_map (fun (transaction, root) ->
                  if
                    server_cursor_number
                      (Types.authoritative_transaction_cursor transaction)
                    = target
                  then Some root
                  else None)
            in
            let accepted_requirement_satisfied (record : outbox_record) =
              match record.acceptance_barrier with
              | None -> false
              | Some barrier ->
                let barrier_number = server_cursor_number barrier.through in
                (match record.mutation with
                 | Save_block _
                 | Insert_blocks _
                 | Create_journal_page _
                 | Set_task_status _
                 | Clear_task_status _
                   when barrier_number < database.checkpoint -> true
                 | _ ->
                   (match authoritative_root_at barrier, record.transport_state with
                    | Some root, Accepted_pending_authoritative batch_id ->
                      accepted_record_satisfied
                        root
                        (batch_records database batch_id)
                        record
                    | None, _ | Some _, _ -> false))
            in
            let resolved_accepted, mismatched_accepted =
              List.partition accepted_requirement_satisfied covered_accepted
            in
            let resolved_records = List.map fst resolved_stale @ resolved_accepted in
            let candidate_outbox =
              List.filter_map
                (fun (record : outbox_record) ->
                   if
                     List.exists (fun resolved -> resolved == record) resolved_records
                     || List.exists
                          (fun (remote_won, _) -> remote_won == record)
                          remote_won_queued
                     || List.exists
                          (fun (remote_won, _, _, _) -> remote_won == record)
                          remote_won_submitted
                     || List.exists
                          (fun (remote_won, _, _, _, _) -> remote_won == record)
                          stale_remote_won
                   then None
                   else if
                     List.exists
                       (fun mismatched -> mismatched == record)
                       mismatched_accepted
                   then
                     Some
                       { record with
                         transport_state = Blocked
                       ; dependency_shadows = empty_dependency_shadows
                       ; blocked_prior_state = Some record.transport_state
                       ; blocked_reason = Some Authoritative_mismatch
                       ; same_id_retry_eligible = false
                       ; acceptance_barrier = None
                       }
                   else if
                     List.exists (fun (blocked, _) -> blocked == record) blocked_stale
                   then
                     Some
                       { record with
                         transport_state = Blocked
                       ; dependency_shadows = empty_dependency_shadows
                       ; blocked_prior_state = Some record.transport_state
                       ; blocked_reason = Some Stale_barrier
                       ; same_id_retry_eligible = false
                       ; acceptance_barrier = None
                       }
                   else (
                     let record_with_origin_evidence () =
                       match
                         List.find_opt
                           (fun (id, _) -> Graph.Uuid.equal id record.mutation_id)
                           prepared.validated_origins
                       with
                       | None -> record
                       | Some (_, cursor) ->
                         { record with observed_origin_cursor = Some cursor }
                     in
                     match
                       List.find_opt
                         (fun (id, _, _) -> Graph.Uuid.equal id record.mutation_id)
                         prepared.stale_updates
                     with
                     | None -> Some (record_with_origin_evidence ())
                     | Some (_, earliest, conflicts) ->
                       Some
                         { (record_with_origin_evidence ()) with
                           stale_earliest_conflict_cursor = earliest
                         ; stale_conflicts = conflicts
                         }))
                database.outbox
            in
            let candidate_outbox, replanned_queued, no_change_queued, blocked_queued =
              replan_queued_ordinary database authoritative_after candidate_outbox
            in
            let receipt_revision = projection_revision database.projection in
            let candidate_receipts =
              List.fold_left
                (fun receipts (record : outbox_record) ->
                   let commit =
                     { Types.mutation_id = record.mutation_id
                     ; status =
                         (if
                            List.exists (fun (stale, _) -> stale == record) resolved_stale
                          then No_change
                          else Applied)
                     ; generation = database.generation
                     ; before_projection_revision = receipt_revision
                     ; after_projection_revision = receipt_revision
                     ; logical_change_summary = No_logical_change
                     }
                   in
                   (record.mutation_id, record.fingerprint, Commit_receipt commit)
                   :: List.filter
                        (fun (candidate, _, _) ->
                           not (Graph.Uuid.equal candidate record.mutation_id))
                        receipts)
                database.receipts
                resolved_records
            in
            let candidate_receipts =
              List.fold_left
                (fun receipts ((record : outbox_record), conflicts) ->
                   ( record.mutation_id
                   , record.fingerprint
                   , Remote_won_entry
                       (remote_won_before_submission ~conflict_kinds:conflicts record) )
                   :: List.filter
                        (fun (candidate, _, _) ->
                           not (Graph.Uuid.equal candidate record.mutation_id))
                        receipts)
                candidate_receipts
                remote_won_queued
            in
            let candidate_receipts =
              List.fold_left
                (fun receipts (record, batch_id, cursor, conflicts) ->
                   ( record.mutation_id
                   , record.fingerprint
                   , Remote_won_entry
                       (remote_won_proven_unexecuted
                          ~conflict_kinds:conflicts
                          record
                          ~batch_id
                          ~earliest_conflict_cursor:cursor) )
                   :: List.filter
                        (fun (candidate, _, _) ->
                           not (Graph.Uuid.equal candidate record.mutation_id))
                        receipts)
                candidate_receipts
                remote_won_submitted
            in
            let candidate_receipts =
              List.fold_left
                (fun receipts
                  (record, batch_id, earliest, rejection_through, conflicts) ->
                   ( record.mutation_id
                   , record.fingerprint
                   , Remote_won_entry
                       (remote_won_proven_unexecuted
                          ~rejection_through
                          ~conflict_kinds:conflicts
                          record
                          ~batch_id
                          ~earliest_conflict_cursor:earliest) )
                   :: List.filter
                        (fun (candidate, _, _) ->
                           not (Graph.Uuid.equal candidate record.mutation_id))
                        receipts)
                candidate_receipts
                stale_remote_won
            in
            let candidate_receipts =
              List.fold_left
                (fun receipts (record : outbox_record) ->
                   let commit =
                     { Types.mutation_id = record.mutation_id
                     ; status = No_change
                     ; generation = database.generation
                     ; before_projection_revision = receipt_revision
                     ; after_projection_revision = receipt_revision
                     ; logical_change_summary = No_logical_change
                     }
                   in
                   (record.mutation_id, record.fingerprint, Commit_receipt commit)
                   :: List.filter
                        (fun (candidate, _, _) ->
                           not (Graph.Uuid.equal candidate record.mutation_id))
                        receipts)
                candidate_receipts
                no_change_queued
            in
            let terminal_receipts =
              List.map
                (fun (record : outbox_record) ->
                   let receipt =
                     if List.exists (fun (stale, _) -> stale == record) resolved_stale
                     then
                       Types.No_change_receipt
                         { mutation_id = record.mutation_id
                         ; fingerprint = typed_mutation_fingerprint record.fingerprint
                         }
                     else
                       Applied_receipt
                         { mutation_id = record.mutation_id
                         ; fingerprint = typed_mutation_fingerprint record.fingerprint
                         }
                   in
                   Types.{ receipt; transport_disposition = Clear_transport_owner })
                resolved_records
            in
            let terminal_receipts =
              terminal_receipts
              @ List.map
                  (fun ((record : outbox_record), conflicts) ->
                     Types.
                       { receipt =
                           Remote_won_receipt
                             (remote_won_before_submission
                                ~conflict_kinds:conflicts
                                record)
                       ; transport_disposition = No_transport_owner
                       })
                  remote_won_queued
            in
            let terminal_receipts =
              terminal_receipts
              @ List.map
                  (fun (record, batch_id, cursor, conflicts) ->
                     Types.
                       { receipt =
                           Remote_won_receipt
                             (remote_won_proven_unexecuted
                                ~conflict_kinds:conflicts
                                record
                                ~batch_id
                                ~earliest_conflict_cursor:cursor)
                       ; transport_disposition =
                           Retain_terminal_owner_until_response batch_id
                       })
                  remote_won_submitted
            in
            let terminal_receipts =
              terminal_receipts
              @ List.map
                  (fun (record, batch_id, earliest, rejection_through, conflicts) ->
                     Types.
                       { receipt =
                           Remote_won_receipt
                             (remote_won_proven_unexecuted
                                ~rejection_through
                                ~conflict_kinds:conflicts
                                record
                                ~batch_id
                                ~earliest_conflict_cursor:earliest)
                       ; transport_disposition = Clear_transport_owner
                       })
                  stale_remote_won
            in
            let terminal_receipts =
              terminal_receipts
              @ List.map
                  (fun (record : outbox_record) ->
                     Types.
                       { receipt =
                           No_change_receipt
                             { mutation_id = record.mutation_id
                             ; fingerprint = typed_mutation_fingerprint record.fingerprint
                             }
                       ; transport_disposition = No_transport_owner
                       })
                  no_change_queued
            in
            let terminal_batches =
              List.map
                (fun (record, batch_id, _cursor, _conflicts) ->
                   { terminal_batch_id = batch_id
                   ; terminal_outcome =
                       Terminal_proven_unexecuted
                         { mutation_id = record.mutation_id
                         ; fingerprint = record.fingerprint
                         }
                   })
                remote_won_submitted
              @ List.map
                  (fun (record, batch_id, _, _, _) ->
                     { terminal_batch_id = batch_id
                     ; terminal_outcome =
                         Terminal_proven_unexecuted
                           { mutation_id = record.mutation_id
                           ; fingerprint = record.fingerprint
                           }
                     })
                  stale_remote_won
              @ List.map
                  (fun (record, batch_id) ->
                     { terminal_batch_id = batch_id
                     ; terminal_outcome =
                         Terminal_proven_unexecuted
                           { mutation_id = record.mutation_id
                           ; fingerprint = record.fingerprint
                           }
                     })
                  (resolved_stale @ blocked_stale)
            in
            let checksum =
              Types.authoritative_batch_checksum preparation.authoritative_batch
              |> Option.map Types.Checksum.to_string
              |> Option.map (strip_versioned_prefix "checksum")
              |> Option.value ~default:database.checkpoint_metadata.checksum
            in
            let metadata =
              Logseq_db_types.Sync_checkpoint.create
                ~graph_id:database.graph_uuid
                ~schema:database.schema
                ~applied_server_t:through
                ~checksum
              |> Result.get_ok
            in
            let outbox =
              List.map
                (Persistence_outbox_v14.encode
                   ~sync_revision:(database.sync_revision + 1))
                candidate_outbox
            in
            let receipts =
              List.filter_map Persistence_receipt_v1.encode_mutation candidate_receipts
            in
            (match
               Logseq_db_storage.Storage_session
               .commit_staged_with_sync_metadata_outbox_and_receipts
                 database.storage_session
                 staged
                 metadata
                 outbox
                 receipts
                 (List.map Persistence_receipt_v1.encode_terminal_batch terminal_batches)
             with
             | Error error ->
               ( []
               , None
               , Error
                   (Types.Authoritative_commit_persistence_failed
                      (storage_session_error error)) )
             | Ok () ->
               preparation.authoritative_state <- Authoritative_consumed;
               let before_projection = database.projection in
               let before_snapshot = snapshot_of_database database in
               (match replay_authoritative database prepared with
                | Error message ->
                  database.closed <- true;
                  [], None, Error (Types.Authoritative_commit_fatal_state message)
                | Ok () ->
                  database.outbox <- candidate_outbox;
                  database.receipts <- [];
                  refresh_queryable_outbox database;
                  let candidate_projection = before_projection + 1 in
                  let after_snapshot =
                    snapshot_for_sources database authoritative_after candidate_outbox
                  in
                  let transitioned_records =
                    resolved_records
                    @ List.map fst remote_won_queued
                    @ List.map (fun (record, _, _, _) -> record) remote_won_submitted
                    @ List.map (fun (record, _, _, _, _) -> record) stale_remote_won
                    @ List.map fst blocked_stale
                    @ mismatched_accepted
                    @ no_change_queued
                    @ blocked_queued
                    @ replanned_queued
                  in
                  let block_uuids, page_uuids, structure_interests, fanout_overflow =
                    logical_change_footprint
                      ~before:before_snapshot
                      ~after:after_snapshot
                      ~authoritative_before
                      ~authoritative_after
                      ~transaction_data:prepared.authoritative_expected_tx_data
                      ~outbox_effects:
                        (List.map
                           (fun (record : outbox_record) -> record.effect_footprint)
                           transitioned_records)
                  in
                  let changed =
                    block_uuids <> [] || page_uuids <> [] || structure_interests <> []
                  in
                  database.projection
                  <- (if changed then candidate_projection else before_projection);
                  database.checkpoint <- through;
                  database.checkpoint_metadata <- metadata;
                  database.sync_revision <- database.sync_revision + 1;
                  let before_revision = projection_revision before_projection in
                  let after_revision = projection_revision database.projection in
                  let logical_change_summary =
                    if fanout_overflow
                    then Types.Logical_resync_required Change_limit_exceeded
                    else if changed
                    then
                      bounded_logical_summary
                        database
                        ~block_uuids
                        ~page_uuids
                        ~structure_interests
                    else No_logical_change
                  in
                  let change =
                    Change_dispatcher.event
                      ~generation:database.generation
                      ~before_revision
                      ~after_revision
                      logical_change_summary
                  in
                  let callbacks =
                    match change with
                    | None -> []
                    | Some _ ->
                      database.subscriptions
                      |> List.filter_map (fun (subscription : subscription) ->
                        match subscription.lifecycle, subscription.notify with
                        | Active, Some callback -> Some callback
                        | Active, None | Unlistened, _ -> None)
                  in
                  ( callbacks
                  , change
                  , Ok
                      { Types.generation = database.generation
                      ; before_projection_revision = before_revision
                      ; after_projection_revision = after_revision
                      ; checkpoint = server_cursor through
                      ; sync_token = sync_token database.sync_revision
                      ; terminal_receipts
                      ; replanned_queued_ids =
                          List.map
                            (fun (record : outbox_record) -> record.mutation_id)
                            replanned_queued
                      ; blocked_ids =
                          List.map
                            (fun (record : outbox_record) -> record.mutation_id)
                            mismatched_accepted
                          @ List.map (fun (record, _) -> record.mutation_id) blocked_stale
                          @ List.map
                              (fun (record : outbox_record) -> record.mutation_id)
                              blocked_queued
                      ; logical_change_summary
                      } )))))
    in
    ignore callbacks;
    change, outcome)
;;

let apply_authoritative database preparation ~decrypted =
  match prepare_authoritative_candidate preparation ~decrypted with
  | Error error -> Error error
  | Ok (`Deferred reason) -> Ok (Authoritative_deferred reason)
  | Ok (`Candidate candidate) ->
    Result.map
      (fun commit -> Authoritative_applied commit)
      (commit_authoritative_candidate database candidate)
;;
