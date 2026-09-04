module Database = Logseq_overlay_db.Database
module Types = Logseq_overlay_db.Types

let fail format = Printf.ksprintf failwith format

let get_ok label = function
  | Ok value -> value
  | Error _ -> fail "%s failed" label
;;

let parse_arguments () =
  let block_count = ref 100_000 in
  let requested_outbox_sizes = ref [ 0; 1; 32; 128; 1_024; 4_096 ] in
  let rec loop = function
    | [] -> ()
    | "--block-count" :: value :: rest ->
      block_count := int_of_string value;
      loop rest
    | "--outbox-records" :: value :: rest ->
      requested_outbox_sizes := [ int_of_string value ];
      loop rest
    | argument :: _ -> fail "unknown argument: %s" argument
  in
  loop (List.tl (Array.to_list Sys.argv));
  !block_count, List.sort_uniq Int.compare !requested_outbox_sizes
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let rss_bytes () =
  let channel =
    Unix.open_process_in (Printf.sprintf "ps -o rss= -p %d" (Unix.getpid ()))
  in
  let kilobytes = input_line channel |> String.trim |> int_of_string in
  ignore (Unix.close_process_in channel);
  kilobytes * 1_024
;;

let dependencies clock =
  let limits =
    { Types.response_budget_bytes = 8 * 1_024 * 1_024
    ; outbox_max_records = 4_096
    ; outbox_max_bytes = 8 * 1_024 * 1_024
    ; change_max_items = 4_096
    ; change_max_bytes = 8 * 1_024 * 1_024
    ; dispatcher_capacity = 128
    ; wire_batch_max_bytes = 8 * 1_024 * 1_024
    }
  in
  Database.dependencies
    ~epoch_ms:(fun () ->
      clock := Int64.succ !clock;
      !clock)
    ~monotonic_ns:(fun () -> Int64.mul !clock 1_000_000L)
    ~limits
  |> get_ok "dependencies"
;;

type measurement =
  { elapsed_ms : float
  ; allocation_bytes : float
  ; rss_bytes : int
  }

let measure operation =
  let allocation_before = Gc.allocated_bytes () in
  let started = Unix.gettimeofday () in
  operation ();
  let elapsed_ms = (Unix.gettimeofday () -. started) *. 1_000. in
  let allocation_bytes = Gc.allocated_bytes () -. allocation_before in
  Gc.full_major ();
  Gc.compact ();
  let rss_bytes = rss_bytes () in
  { elapsed_ms; allocation_bytes; rss_bytes }
;;

let measure_probe operation = measure operation

let with_snapshot database operation =
  let snapshot = Database.current_snapshot database |> get_ok "measurement snapshot" in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () -> operation snapshot)
;;

let measure_point_read database block_count =
  let requested =
    List.init 64 (fun index -> Fixture_generator.block_uuid (index mod block_count))
  in
  with_snapshot database (fun snapshot ->
    measure (fun () ->
      let results =
        Database.get_blocks snapshot requested |> get_ok "measured get_blocks"
      in
      if List.length results <> 64 then fail "measured get_blocks cardinality mismatch"))
;;

let performance_page =
  Logseq_db_types.Graph_types.Uuid.of_string "10000000-0000-4000-8000-000000000001"
  |> get_ok "performance page UUID"
;;

let measure_structure database =
  with_snapshot database (fun snapshot ->
    measure (fun () ->
      match
        Database.get_structure
          snapshot
          (Types.Children { parent = performance_page; limit = 200; cursor = None })
        |> get_ok "measured get_structure"
      with
      | Types.Children_result { items; _ } when List.length items = 200 -> ()
      | Children_result _ | Page_tree_result _ ->
        fail "measured get_structure cardinality mismatch"))
;;

let measure_journals database =
  with_snapshot database (fun snapshot ->
    measure (fun () ->
      let result =
        Database.get_journals snapshot ~limit:200 ~cursor:None
        |> get_ok "measured get_journals"
      in
      if List.length result.items <> 200
      then fail "measured get_journals cardinality mismatch"))
;;

let server_cursor value =
  Types.Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" value)
  |> get_ok "server cursor"
;;

let server_cursor_number cursor =
  Types.Server_cursor.to_string cursor
  |> String.split_on_char ':'
  |> List.rev
  |> List.hd
  |> int_of_string
;;

let authoritative_wire operations =
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  Codec.to_string ~mode:Codec.Verbose (Transit.Array operations)
  |> Types.encoded_transaction_of_string ~maximum_bytes:(8 * 1_024 * 1_024)
  |> get_ok "authoritative wire"
;;

let block_lookup uuid =
  let module Transit = Transit_core.Json in
  Transit.Array
    [ Transit.Keyword "block/uuid"
    ; Transit.Uuid (Logseq_db_types.Graph_types.Uuid.to_string uuid)
    ]
;;

let commit_authoritative database ~cursor wire =
  let transaction =
    Types.authoritative_transaction ~cursor:(server_cursor cursor) ~transaction:wire
  in
  let batch =
    Types.authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:(8 * 1_024 * 1_024)
      ~transactions:[ transaction ]
      ~through:(server_cursor cursor)
      ~checksum:None
    |> get_ok "authoritative batch"
  in
  let sync = Database.inspect_sync database |> get_ok "authoritative sync view" in
  let preparation, crypto =
    match
      Database.begin_authoritative database ~expected:(Types.sync_view_token sync) batch
    with
    | Ok value -> value
    | Error Types.Authoritative_cursor_discontinuous ->
      fail "begin authoritative cursor %d is discontinuous" cursor
    | Error (Types.Authoritative_decode_failed message) ->
      fail "begin authoritative cursor %d decode failed: %s" cursor message
    | Error _ -> fail "begin authoritative cursor %d failed" cursor
  in
  if Option.is_some crypto
  then fail "performance authoritative transaction requested crypto";
  match
    Database.apply_authoritative database preparation ~decrypted:None
    |> get_ok "apply authoritative"
  with
  | Database.Authoritative_applied _ -> ()
  | Authoritative_deferred _ -> fail "performance authoritative transaction deferred"
;;

let measure_rebase database cursor =
  let module Transit = Transit_core.Json in
  incr cursor;
  let wire =
    authoritative_wire
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Keyword "db/current-tx"
          ; Transit.Keyword "logseq-overlay/performance-rebase"
          ; Transit.Int !cursor
          ]
      ]
  in
  measure_probe (fun () -> commit_authoritative database ~cursor:!cursor wire)
;;

let measure_single_block_classification database cursor ordinal =
  let module Transit = Transit_core.Json in
  incr cursor;
  let block = Fixture_generator.block_uuid ordinal in
  let wire =
    authoritative_wire
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; block_lookup block
          ; Transit.Keyword "block/updated-at"
          ; Transit.Int (1_704_067_300_000 + !cursor)
          ]
      ]
  in
  measure_probe (fun () -> commit_authoritative database ~cursor:!cursor wire)
;;

let delete_precondition database block =
  with_snapshot database (fun snapshot ->
    let block_revision, parent =
      match Database.get_blocks snapshot [ block ] |> get_ok "delete block revision" with
      | [ Types.Present_block { value; revision } ] -> revision, value.block.parent
      | _ -> fail "delete performance target is missing"
    in
    let scope, scope_revision =
      match
        Database.get_structure
          snapshot
          (Types.Children { parent; limit = 200; cursor = None })
        |> get_ok "delete structure revision"
      with
      | Types.Children_result { revision_scope; scope_revision; _ } ->
        revision_scope, scope_revision
      | Page_tree_result _ -> fail "delete performance scope is not children"
    in
    Database.write_precondition
      ~blocks:[ block, block_revision ]
      ~pages:[]
      ~scopes:[ scope, scope_revision ]
    |> get_ok "delete precondition")
;;

let measure_delete_conflict database cursor ordinal =
  let block = Fixture_generator.block_uuid ordinal in
  let mutation =
    Types.Delete_blocks
      { mutation_id = Fixture_generator.mutation_uuid (10_000 + ordinal); root = block }
  in
  ignore
    (Database.commit_local
       database
       ~expected:(delete_precondition database block)
       mutation
     |> get_ok "commit performance delete"
     : Types.local_commit_outcome);
  let module Transit = Transit_core.Json in
  incr cursor;
  let wire =
    authoritative_wire
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; block_lookup block
          ; Transit.Keyword "block/updated-at"
          ; Transit.Int (1_704_067_400_000 + !cursor)
          ]
      ]
  in
  measure_probe (fun () -> commit_authoritative database ~cursor:!cursor wire)
;;

let measure_reopen open_database =
  measure (fun () ->
    let database = open_database () in
    Database.close database |> get_ok "close measured reopen")
;;

let measurement_json measurement =
  `Assoc
    [ "wall_time_ms", `Float measurement.elapsed_ms
    ; "allocation_bytes", `Float measurement.allocation_bytes
    ; "rss_bytes", `Int measurement.rss_bytes
    ]
;;

let benchmark ~open_database ~database_path ~block_count required_sizes =
  List.map
    (fun active_outbox_records ->
       Fixture_generator.seed_outbox
         ~database_path
         ~block_count
         ~count:active_outbox_records;
       let active_outbox_bytes = Fixture_generator.outbox_bytes ~database_path in
       let reopen_samples = List.init 5 (fun _ -> measure_reopen open_database) in
       let database = open_database () in
       ignore (measure_point_read database block_count : measurement);
       ignore (measure_structure database : measurement);
       ignore (measure_journals database : measurement);
       let point_samples =
         List.init 5 (fun _ -> measure_point_read database block_count)
       in
       let structure_samples = List.init 5 (fun _ -> measure_structure database) in
       let journal_samples = List.init 5 (fun _ -> measure_journals database) in
       let cursor =
         Database.inspect_sync database
         |> get_ok "benchmark checkpoint"
         |> Types.sync_view_checkpoint
         |> server_cursor_number
         |> ref
       in
       let single_block_samples =
         if active_outbox_records = 0
         then (
           ignore
             (measure_single_block_classification database cursor (block_count - 10)
              : measurement);
           List.init 5 (fun ordinal ->
             measure_single_block_classification
               database
               cursor
               (block_count - ordinal - 1)))
         else []
       in
       let rebase_samples =
         if active_outbox_records = 128 || active_outbox_records = 4_096
         then (
           ignore (measure_rebase database cursor : measurement);
           List.init 5 (fun _ -> measure_rebase database cursor))
         else []
       in
       let delete_conflict_samples =
         if active_outbox_records = 4_096
         then (
           Database.close database |> get_ok "close before delete benchmark";
           Fixture_generator.seed_outbox ~database_path ~block_count ~count:4_095;
           let database = open_database () in
           let samples =
             List.init 5 (fun ordinal -> measure_delete_conflict database cursor ordinal)
           in
           Database.close database |> get_ok "close delete benchmark";
           samples)
         else (
           Database.close database |> get_ok "close overlay";
           [])
       in
       let values select = List.map select point_samples in
       `Assoc
         [ "active_outbox_records", `Int active_outbox_records
         ; "active_outbox_bytes", `Int active_outbox_bytes
         ; "status", `String "Measured"
         ; ( "wall_time_samples"
           , `List
               (List.map
                  (fun value -> `Float value)
                  (values (fun value -> value.elapsed_ms))) )
         ; ( "allocation_samples"
           , `List
               (List.map
                  (fun value -> `Float value)
                  (values (fun value -> value.allocation_bytes))) )
         ; ( "rss_samples"
           , `List
               (List.map
                  (fun value -> `Int value)
                  (values (fun value -> value.rss_bytes))) )
         ; "get_blocks_64", `List (List.map measurement_json point_samples)
         ; "get_structure_200", `List (List.map measurement_json structure_samples)
         ; "get_journals_200", `List (List.map measurement_json journal_samples)
         ; ( "single_block_change_classification"
           , `List (List.map measurement_json single_block_samples) )
         ; "replan_and_diff", `List (List.map measurement_json rebase_samples)
         ; "reopen", `List (List.map measurement_json reopen_samples)
         ; "delete_conflict", `List (List.map measurement_json delete_conflict_samples)
         ])
    required_sizes
;;

let () =
  let block_count, required_sizes = parse_arguments () in
  if block_count <= 0 then fail "block count must be positive";
  if List.exists (fun size -> size < 0 || size > 4_096) required_sizes
  then fail "outbox size is outside admission bounds";
  let checksum = Fixture_generator.fixture_checksum ~block_count in
  let support = Filename.temp_file "overlay-performance-" "" in
  Sys.remove support;
  Unix.mkdir support 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree support)
    (fun () ->
       let graph_id, database_path =
         Fixture_generator.seed_mirror ~application_support_directory:support ~block_count
       in
       let clock = ref 1_704_067_200_000L in
       let dependencies = dependencies clock in
       Eio_main.run (fun _environment ->
         Eio.Switch.run (fun sw ->
           let open_database () =
             let inspection =
               Database.inspect_mirror ~application_support_directory:support ~graph_id
               |> get_ok "inspect mirror"
             in
             match
               Database.open_
                 ~sw
                 dependencies
                 inspection
                 ~graph_name:"performance-fixture"
             with
             | Ok database -> database
             | Error (Types.Restore_failed message)
             | Error (Corrupt_authoritative_store message)
             | Error (Corrupt_outbox message)
             | Error (Corrupt_mutation_receipt message)
             | Error (Open_resource_failed message) ->
               fail "open overlay failed: %s" message
             | Error _ -> fail "open overlay failed"
           in
           let samples =
             benchmark ~open_database ~database_path ~block_count required_sizes
           in
           Yojson.Safe.pretty_to_channel
             stdout
             (`Assoc
                 [ "block_count", `Int block_count
                 ; "fixture_checksum", `String checksum
                 ; "samples", `List samples
                 ]);
           output_char stdout '\n')))
;;
