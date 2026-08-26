module Worker = Logseq_db_worker
module Protocol = Worker.Protocol
module Engine = Worker.Engine
module Uuid = Worker.Graph_types.Uuid
module Snapshot = Logseq_db_worker__Snapshot
module Storage = Logseq_db_worker__Logseq_sqlite_storage
module Session = Logseq_db_worker__Storage_session
module Adapter_fixture = Logseq_db_worker_test_support.Adapter_fixture

let block_count = 100_000
let deep_tree_depth = 64
let large_sibling_count = 1_000
let high_reference_count = 1_024
let warmup_samples = 20
let measured_samples = 100

let expected_fixture_sha256 =
  "534a3e9f71595299c74956b4acfd8c3afd903a6222315ea834b45ece580075eb"
;;

let page_uuid_text = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
let page_title = "Performance Page"
let fail format = Printf.ksprintf failwith format

let uuid text =
  match Uuid.of_string text with
  | Ok value -> value
  | Error message -> fail "invalid benchmark UUID %s: %s" text message
;;

let block_uuid_text index = Printf.sprintf "00000000-0000-4000-8000-%012x" (index + 1)

let indexed_uuid family index =
  uuid (Printf.sprintf "%08x-0000-4000-8000-%012x" family (index + 1))
;;

let monotonic_seconds () = Int64.to_float (Mtime_clock.elapsed_ns ()) /. 1_000_000_000.

let timed operation =
  let started = monotonic_seconds () in
  let value = operation () in
  value, monotonic_seconds () -. started
;;

let ensure_directory path =
  if Sys.file_exists path
  then (if not (Sys.is_directory path) then fail "%s is not a directory" path)
  else Unix.mkdir path 0o700
;;

let rec directory_bytes path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.fold_left
         (fun total name -> Int64.add total (directory_bytes (Filename.concat path name)))
         0L
  | { st_size; _ } -> Int64.of_int st_size
;;

let commit session tx_ops =
  let staged =
    match Session.stage_transact session tx_ops with
    | Ok staged -> staged
    | Error _ -> fail "unable to stage performance fixture transaction"
  in
  match Session.commit_staged session staged with
  | Ok () -> ()
  | Error _ -> fail "unable to persist performance fixture transaction"
;;

let parent_index index =
  if index = 0
  then None
  else if index < deep_tree_depth
  then Some (index - 1)
  else if index > 64 && index <= 64 + large_sibling_count
  then Some 64
  else None
;;

let order index =
  if index < deep_tree_depth
  then "00000000"
  else if index = 64
  then "00000001"
  else if index <= 1_064
  then Printf.sprintf "%08d" (index - 65)
  else if index = 1_065
  then "00000002"
  else Printf.sprintf "%08d" (index - 1_062)
;;

let reference_text index =
  if index <> 1_065
  then ""
  else
    List.init high_reference_count (fun offset -> block_uuid_text (1_066 + offset))
    |> String.concat ","
;;

let feed_fixture_identity context =
  let feed text = context := Digestif.SHA256.feed_string !context text in
  feed (Printf.sprintf "page|%s|%s\n" page_uuid_text page_title);
  for index = 0 to block_count - 1 do
    let parent =
      match parent_index index with
      | None -> page_uuid_text
      | Some parent -> block_uuid_text parent
    in
    feed
      (Printf.sprintf
         "block|%s|Performance block %d|%s|%s|%s\n"
         (block_uuid_text index)
         index
         parent
         (order index)
         (reference_text index))
  done
;;

let fixture_sha256 () =
  let context = ref Digestif.SHA256.empty in
  feed_fixture_identity context;
  Digestif.SHA256.(to_hex (get !context))
;;

let performance_database db =
  let page_entity = Datascript.Temp_id "performance-page" in
  let block_entity index =
    Datascript.Temp_id (Printf.sprintf "performance-block-%d" index)
  in
  let add entity attribute value = Datascript.Add (entity, attribute, value) in
  let reference entity = Datascript.Ref_to entity in
  let timestamp = Datascript.Int 1_704_067_200_000 in
  let page_ops =
    [ add page_entity "block/uuid" (Datascript.Uuid page_uuid_text)
    ; add page_entity "block/title" (Datascript.String page_title)
    ; add page_entity "block/name" (Datascript.String "performance page")
    ; add page_entity "block/created-at" timestamp
    ; add page_entity "block/updated-at" timestamp
    ]
  in
  let rec blocks index ops =
    if index < 0
    then ops
    else (
      let entity = block_entity index in
      let parent =
        match parent_index index with
        | None -> page_entity
        | Some parent -> block_entity parent
      in
      blocks
        (index - 1)
        (add entity "block/uuid" (Datascript.Uuid (block_uuid_text index))
         :: add
              entity
              "block/title"
              (Datascript.String (Printf.sprintf "Performance block %d" index))
         :: add entity "block/parent" (reference parent)
         :: add entity "block/page" (reference page_entity)
         :: add entity "block/order" (Datascript.String (order index))
         :: add entity "block/created-at" timestamp
         :: add entity "block/updated-at" timestamp
         :: ops))
  in
  let hub = block_entity 1_065 in
  let references =
    List.init high_reference_count (fun offset ->
      add hub "block/refs" (reference (block_entity (1_066 + offset))))
  in
  (Datascript.with_tx
     ~tx_meta:[ "skip-store?", Datascript.Bool true ]
     db
     (page_ops @ blocks (block_count - 1) references))
    .db_after
;;

let seed_performance_graph graph_dir =
  let database_path = Filename.concat graph_dir "db.sqlite" in
  let connection =
    match Storage.open_database database_path with
    | Ok connection -> connection
    | Error _ -> fail "unable to open performance fixture database"
  in
  let db =
    match Storage.restore_database connection with
    | Ok db -> db
    | Error _ -> fail "unable to restore performance fixture database"
  in
  let db = performance_database db in
  let forcing_tail =
    match Datascript.datoms db Datascript.Eavt () |> Seq.uncons with
    | None -> fail "performance fixture has no datoms"
    | Some (datom, _) ->
      [ List.init (Datascript.Storage.tail_compaction_threshold + 1) (fun _ -> datom) ]
  in
  let session =
    Session.create
      ~db
      ~tail:forcing_tail
      ~callbacks:(Storage.connection_callbacks connection)
  in
  Fun.protect
    ~finally:(fun () ->
      match Session.close session with
      | Ok () -> ()
      | Error _ -> fail "unable to close performance fixture database")
    (fun () -> commit session [])
;;

let generate support_root =
  if Filename.is_relative support_root then fail "support root must be absolute";
  ensure_directory support_root;
  let support_root = Unix.realpath support_root in
  let sources = Filename.concat support_root "sources" in
  ensure_directory sources;
  let source_graph_dir = Filename.concat sources "performance-100000-v1" in
  if Sys.file_exists source_graph_dir then fail "performance source already exists";
  let graph_dir = Adapter_fixture.create_oracle_graph sources "performance-100000-v1" in
  seed_performance_graph graph_dir;
  let actual_hash = fixture_sha256 () in
  if not (String.equal actual_hash expected_fixture_sha256)
  then fail "performance fixture hash mismatch: %s" actual_hash;
  let catalog =
    match Snapshot.create_catalog ~application_support_directory:support_root with
    | Ok catalog -> catalog
    | Error _ -> fail "unable to create performance snapshot catalog"
  in
  let token, snapshot_seconds =
    timed (fun () ->
      match Snapshot.create catalog ~source_graph_dir:graph_dir with
      | Ok token -> token
      | Error _ -> fail "unable to publish performance snapshot")
  in
  let resolved =
    match Snapshot.resolve catalog token with
    | Ok resolved -> resolved
    | Error _ -> fail "unable to resolve performance snapshot"
  in
  let bytes = directory_bytes resolved.graph_dir in
  `Assoc
    [ "formatVersion", `Int 1
    ; "supportRoot", `String support_root
    ; "snapshotToken", `String (Uuid.to_string token)
    ; "graphDir", `String resolved.graph_dir
    ; "fixtureContentSha256", `String actual_hash
    ; "fixtureBytes", `Intlit (Int64.to_string bytes)
    ; "snapshotBytesPerSecond", `Float (Int64.to_float bytes /. snapshot_seconds)
    ]
;;

let config ~support_root ~graph_dir =
  match
    Worker.Config.create
      ~application_support_directory:support_root
      ~target:(Native_local_graph { graph_name = Filename.basename graph_dir; graph_dir })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Protocol.maximum_response_bytes
      ~default_page_size:Protocol.default_page_size
  with
  | Ok config -> config
  | Error message -> fail "invalid performance config: %s" message
;;

let dependencies =
  Engine.
    { clocks =
        { epoch_ms = (fun () -> Int64.of_float (Unix.gettimeofday () *. 1_000.))
        ; monotonic_ns =
            (fun () -> Int64.of_float (monotonic_seconds () *. 1_000_000_000.))
        }
    ; cursor_authentication_key = Bytes.of_string "performance-cursor-key-32-bytes!"
    ; crypto = Worker.Sync_e2ee.unavailable_crypto
    ; unlock_graph_key =
        (fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
          Error "crypto unavailable")
    }
;;

let execute engine ~family ~index command =
  Engine.execute
    engine
    Protocol.{ api_version; request_id = indexed_uuid family index; command }
;;

let require_success label = function
  | Protocol.Succeeded _ as response -> response
  | Protocol.Failed failure ->
    fail "%s failed: %s" label (Worker.Error.message failure.error)
;;

let read ?(label = "read") engine ~family ~index command =
  execute engine ~family ~index (Protocol.Read command) |> require_success label
;;

let save engine index title =
  let basis =
    match Engine.basis engine with
    | Some basis -> basis
    | None -> fail "performance engine has no basis"
  in
  execute
    engine
    ~family:0x30000000
    ~index
    (Protocol.Mutate
       (Structural
          (Save_block
             { block = uuid (block_uuid_text 0)
             ; title
             ; context =
                 { mutation_id = indexed_uuid 0x40000000 index; expected_basis = basis }
             })))
  |> require_success "Save_block"
  |> ignore
;;

let measure_samples ~warmup ~samples operation =
  for index = 0 to warmup - 1 do
    operation index |> ignore
  done;
  List.init samples (fun offset ->
    let _, seconds = timed (fun () -> operation (warmup + offset)) in
    seconds *. 1_000.)
;;

let nearest_rank_p95 samples =
  let sorted = List.sort Float.compare samples |> Array.of_list in
  if Array.length sorted = 0 then fail "cannot estimate a percentile without samples";
  let rank = int_of_float (ceil (0.95 *. float_of_int (Array.length sorted))) in
  sorted.(max 0 (rank - 1))
;;

let latency_json samples =
  `Assoc
    [ "samples", `Int (List.length samples)
    ; "p95Milliseconds", `Float (nearest_rank_p95 samples)
    ]
;;

let report_latency name samples =
  Printf.eprintf
    "%s p95: %.3f ms (%d samples)\n%!"
    name
    (nearest_rank_p95 samples)
    (List.length samples)
;;

let command_output program arguments =
  let channel =
    Unix.open_process_args_in program (Array.of_list (program :: arguments))
  in
  let buffer = Buffer.create 128 in
  (try
     while true do
       Buffer.add_string buffer (input_line channel);
       Buffer.add_char buffer '\n'
     done
   with
   | End_of_file -> ());
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> String.trim (Buffer.contents buffer)
  | _ -> fail "environment command failed: %s" program
;;

let page_continuation = function
  | Protocol.Succeeded { success = Children_result { continuation; _ }; _ } ->
    continuation
  | _ -> None
;;

let boundedness engine =
  let page = uuid page_uuid_text in
  let depth64_accepted =
    match
      read
        ~label:"depth-64 Get_page_tree"
        engine
        ~family:0x50000000
        ~index:1
        (Get_page_tree { page; maximum_depth = 64; limit = 64; cursor = None })
    with
    | Succeeded { success = Page_tree_result page; _ } ->
      List.exists
        (fun (item : Worker.Graph_types.block_tree_item) -> item.depth = 63)
        page.items
    | _ -> false
  in
  let depth65_rejected =
    match
      execute
        engine
        ~family:0x50000000
        ~index:2
        (Read (Get_page_tree { page; maximum_depth = 65; limit = 64; cursor = None }))
    with
    | Failed failure -> Worker.Error.code failure.error = Invalid_request
    | Succeeded _ -> false
  in
  let sibling_parent = uuid (block_uuid_text 64) in
  let first =
    read
      ~label:"large-sibling Get_children"
      engine
      ~family:0x50000000
      ~index:3
      (Get_children { parent = sibling_parent; limit = 100; cursor = None })
  in
  let sibling_deterministic =
    match page_continuation first with
    | None -> false
    | Some cursor ->
      let query index =
        match
          read
            ~label:"large-sibling continuation"
            engine
            ~family:0x50000000
            ~index
            (Get_children { parent = sibling_parent; limit = 100; cursor = Some cursor })
        with
        | Succeeded { success = Children_result page; _ } ->
          page.items, Option.is_some page.continuation
        | _ -> assert false
      in
      let first_items, first_continues = query 4 in
      let second_items, second_continues = query 5 in
      first_items = second_items && first_continues && second_continues
  in
  let references =
    read
      ~label:"high-cardinality Get_references"
      engine
      ~family:0x50000000
      ~index:6
      (Get_references
         { target = uuid (block_uuid_text 1_065)
         ; direction = Referred_from
         ; limit = 200
         ; cursor = None
         })
  in
  let reference_bytes = Protocol.encoded_response_bytes references in
  `Assoc
    [ "depth64Accepted", `Bool depth64_accepted
    ; "depth65Rejected", `Bool depth65_rejected
    ; "largeSiblingPaginationDeterministic", `Bool sibling_deterministic
    ; ( "highReferencesWithinResponseBudget"
      , `Bool (reference_bytes <= Protocol.maximum_response_bytes) )
    ; "highReferencesResponseBytes", `Int reference_bytes
    ]
;;

let measure ~support_root ~graph_dir ~fixture_hash ~snapshot_throughput ~build_profile =
  let engine_result, cold_open_seconds =
    timed (fun () -> Engine.open_ ~dependencies (config ~support_root ~graph_dir))
  in
  let engine =
    match engine_result with
    | Ok engine -> engine
    | Error error -> fail "cold open failed: %s" (Worker.Error.message error)
  in
  Printf.eprintf "cold open: %.3f ms\n%!" (cold_open_seconds *. 1_000.);
  Fun.protect
    ~finally:(fun () ->
      match Engine.close engine with
      | Ok () -> ()
      | Error message -> fail "performance engine close failed: %s" message)
    (fun () ->
       let graph_bytes = directory_bytes graph_dir in
       let _, first_backup_seconds =
         timed (fun () -> save engine 0 "Performance block 0 backup-established")
       in
       let get_block_samples =
         measure_samples ~warmup:warmup_samples ~samples:measured_samples (fun index ->
           read
             engine
             ~family:0x60000000
             ~index
             (Get_block { block = uuid (block_uuid_text 0) }))
       in
       report_latency "Get_block" get_block_samples;
       let get_children_samples =
         measure_samples ~warmup:warmup_samples ~samples:measured_samples (fun index ->
           read
             engine
             ~family:0x61000000
             ~index
             (Get_children
                { parent = uuid (block_uuid_text 64); limit = 100; cursor = None }))
       in
       report_latency "Get_children(100)" get_children_samples;
       let mutation_samples =
         measure_samples ~warmup:warmup_samples ~samples:measured_samples (fun index ->
           save
             engine
             (index + 1)
             (Printf.sprintf "Performance block 0 mutation %d" index))
       in
       report_latency "post-backup Save_block" mutation_samples;
       let boundedness = boundedness engine in
       let resource_usage = Core_unix.Resource_usage.get `Self in
       `Assoc
         [ "formatVersion", `Int 1
         ; "fixtureContentSha256", `String fixture_hash
         ; ( "environment"
           , `Assoc
               [ "architecture", `String (command_output "/usr/bin/uname" [ "-m" ])
               ; ( "memoryBytes"
                 , `Intlit (command_output "/usr/sbin/sysctl" [ "-n"; "hw.memsize" ]) )
               ; ( "cpu"
                 , `String
                     (command_output
                        "/usr/sbin/sysctl"
                        [ "-n"; "machdep.cpu.brand_string" ]) )
               ; "os", `String (command_output "/usr/bin/sw_vers" [ "-productVersion" ])
               ; "sqliteVersion", `String (Sqlite3.sqlite_version_info ())
               ; "buildProfile", `String build_profile
               ; ( "cacheCondition"
                 , `String
                     "fresh measurement process; normal host filesystem cache; no \
                      privileged eviction" )
               ; "rssSampler", `String "getrusage(RUSAGE_SELF).ru_maxrss"
               ] )
         ; ( "measurements"
           , `Assoc
               [ "coldOpenMilliseconds", `Float (cold_open_seconds *. 1_000.)
               ; "peakRssBytes", `Intlit (Int64.to_string resource_usage.maxrss)
               ] )
         ; ( "latency"
           , `Assoc
               [ "getBlock", latency_json get_block_samples
               ; "getChildren100", latency_json get_children_samples
               ; "postBackupSaveBlock", latency_json mutation_samples
               ] )
         ; "boundedness", boundedness
         ; ( "throughput"
           , `Assoc
               [ "snapshotBytesPerSecond", `Float snapshot_throughput
               ; ( "firstBackupBytesPerSecond"
                 , `Float (Int64.to_float graph_bytes /. first_backup_seconds) )
               ] )
         ])
;;

let write_json path json =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () ->
       Yojson.Safe.pretty_to_channel channel json;
       output_char channel '\n')
;;

let argument name arguments =
  let rec find = function
    | [] -> fail "%s is required" name
    | key :: value :: _ when String.equal key name -> value
    | _ :: rest -> find rest
  in
  find arguments
;;

let usage =
  "usage: performance_benchmark generate --support-root ROOT | measure --support-root \
   ROOT --graph-dir DIR --fixture-hash SHA256 --snapshot-throughput BYTES_PER_SECOND \
   --build-profile release --output FILE"
;;

let () =
  try
    match Array.to_list Sys.argv |> List.tl with
    | "generate" :: arguments ->
      generate (argument "--support-root" arguments)
      |> Yojson.Safe.pretty_to_channel stdout;
      output_char stdout '\n'
    | "measure" :: arguments ->
      let output = argument "--output" arguments in
      measure
        ~support_root:(argument "--support-root" arguments)
        ~graph_dir:(argument "--graph-dir" arguments)
        ~fixture_hash:(argument "--fixture-hash" arguments)
        ~snapshot_throughput:
          (float_of_string (argument "--snapshot-throughput" arguments))
        ~build_profile:(argument "--build-profile" arguments)
      |> write_json output
    | _ -> fail "%s" usage
  with
  | Failure message ->
    prerr_endline message;
    exit 1
;;
