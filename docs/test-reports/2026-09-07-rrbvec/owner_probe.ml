module Timeline = Journal_timeline_state
module Worker = Macos_mutation_runtime_test
module T = Test_support
module Database = Logseq_overlay_db.Database
module Types = Logseq_overlay_db.Types
module Graph = Logseq_db_types.Graph_types

let check condition message = if not condition then failwith message
let ok = Result.get_ok

let measure name iterations operation =
  Gc.full_major ();
  let before = Gc.quick_stat () in
  let start = Mtime_clock.counter () in
  let checksum = ref 0 in
  for _ = 1 to iterations do
    checksum := !checksum + operation ()
  done;
  let ns = Mtime.Span.to_uint64_ns (Mtime_clock.count start) in
  Gc.minor ();
  let after = Gc.quick_stat () in
  let words =
    after.minor_words
    -. before.minor_words
    +. (after.major_words -. before.major_words)
    -. (after.promoted_words -. before.promoted_words)
  in
  Printf.printf
    "PROBE %s %s\n%!"
    name
    (Yojson.Safe.to_string
       (`Assoc
           [ "iterations", `Int iterations
           ; "elapsed_ns", `Intlit (Int64.to_string ns)
           ; "allocated_words", `Float words
           ; "minor_collections", `Int (after.minor_collections - before.minor_collections)
           ; "major_collections", `Int (after.major_collections - before.major_collections)
           ; "checksum", `Int !checksum
           ]))
;;

let live name =
  Gc.full_major ();
  Printf.printf "LIVE %s %d\n%!" name (Gc.stat ()).live_words
;;

let block index source =
  Journal_model.create
    ~id:(Printf.sprintf "70000000-0000-4000-8000-%012d" index)
    ~page_id:"71000000-0000-4000-8000-000000000001"
    ~journal_day:20260809
    ~parent_id:None
    ~sibling_order:(Printf.sprintf "%012d" index)
    ~source
    ~task_state:Journal_model.No_status
    ~child_count:1
    ~creation_time:
      (Journal_time.create
         ~instant_unix_ms:1786204800000L
         ~local_day:20260809
         ~local_minute_of_day:0
       |> ok)
    ~revision:"block-1"
    ~last_mutation_id:"72000000-0000-4000-8000-000000000001"
  |> ok
;;

let timeline size =
  let blocks = List.init size (fun index -> block index "Entry") in
  let entries =
    List.map
      (fun value -> Journal_graph_projection.{ block = value; child_summaries = [] })
      blocks
  in
  let feed : Journal_graph_projection.feed =
    { days =
        [ { page =
              { id = "71000000-0000-4000-8000-000000000001"
              ; day = 20260809
              ; title = "Today"
              }
          ; entries
          ; has_more_entries = false
          ; continuation = None
          }
        ]
    ; slot_count = size
    ; has_more_days = false
    }
  in
  let state =
    Timeline.empty ~today:20260809
    |> fun state ->
    Timeline.begin_request state ~generation:1L (Feed { before_day = None })
    |> fun state -> Timeline.apply_feed state ~generation:1L feed
  in
  let replacement = block (size - 1) "Changed" in
  let profile =
    Journal_visual_tokens.select_row_profile
      ~preset:Balanced
      ~viewport_width:390.
      ~text_scale:1.
  in
  let positions = List.sort_uniq Int.compare [ 0; size / 2; max 0 (size - 40) ] in
  for sample = 1 to 7 do
    List.iter
      (fun first ->
         let viewed =
           Timeline.observe_visible_range
             state
             ~first_index:first
             ~last_exclusive:(min size (first + 20))
         in
         measure (Printf.sprintf "window-%d-%d" first sample) 10000 (fun () ->
           let window = Timeline.current_window viewed in
           check (List.length window.slots <= 40) "unbounded timeline output";
           window.first_index + List.length window.slots);
         measure (Printf.sprintf "prepare-%d-%d" first sample) 500 (fun () ->
           let geometry = Timeline.extent_geometry viewed ~profile in
           let window = Timeline.current_window viewed in
           List.length geometry.overrides + List.length window.slots))
      positions;
    measure (Printf.sprintf "update-%d" sample) 3000 (fun () ->
      let updated = Timeline.replace_block state replacement in
      Timeline.retained_slot_count updated);
    measure (Printf.sprintf "splice-%d" sample) 1000 (fun () ->
      let expanded = Timeline.expand state ~parent_id:(Journal_model.id replacement) in
      let collapsed =
        Timeline.collapse expanded ~parent_id:(Journal_model.id replacement)
      in
      check (Timeline.retained_slot_count collapsed <= 512) "splice exceeds retention cap";
      Timeline.retained_slot_count collapsed)
  done;
  live "timeline-before-staging";
  let deleted, staged =
    Timeline.stage_delete state ~block_id:(Journal_model.id (List.nth blocks (size / 2)))
    |> Option.get
  in
  let states = Array.init 128 (fun _ -> Timeline.replace_block deleted replacement) in
  live "timeline-retaining-128-updates-and-staged";
  let restored = Timeline.undo_delete states.(127) staged in
  check (Timeline.retained_slot_count restored = size) "undo lost retained state";
  ignore (Sys.opaque_identity states);
  ignore (Sys.opaque_identity staged);
  live "timeline-after-undo-release"
;;

let worker size =
  for sample = 1 to 7 do
    Worker.with_worker (fun worker ->
      let generation =
        match Worker.outcome worker 2000 Worker.P.V2_graph_info with
        | V2_graph_info_outcome { generation; _ } -> generation
        | _ -> failwith "missing generation"
      in
      let ordinal = ref 10000 in
      let publish () =
        incr ordinal;
        Worker.save worker !ordinal T.authoritative_block_uuid (string_of_int !ordinal);
        ignore (Worker.last_push worker);
        1
      in
      let pull after limit =
        Worker.outcome worker 2001 (Worker.P.V2_pull_changes { generation; after; limit })
      in
      measure (Printf.sprintf "publish-%d" sample) size publish;
      let windows, through =
        match pull None 100000 with
        | V2_changes { windows; through; _ } -> windows, through
        | _ -> failwith "missing retained windows"
      in
      check (List.length windows = size) "window retention count mismatch";
      let middle = (List.nth windows (size / 2)).id in
      measure (Printf.sprintf "pull-front-%d" sample) 1000 (fun () ->
        match pull None 7 with
        | V2_changes { windows; _ } -> List.length windows
        | _ -> failwith "pull failed");
      measure (Printf.sprintf "pull-middle-%d" sample) 1000 (fun () ->
        match pull (Some middle) 7 with
        | V2_changes { windows; _ } -> List.length windows
        | _ -> failwith "cursor failed");
      live "worker-before-ack";
      measure (Printf.sprintf "ack-%d" sample) 1 (fun () ->
        ignore
          (Worker.outcome worker 2002 (Worker.P.V2_ack_changes { generation; through }));
        1);
      live "worker-after-ack";
      check
        (match pull (Some through) 100 with
         | V2_changes { windows = []; _ } -> true
         | _ -> false)
        "ack did not clear suffix";
      measure (Printf.sprintf "interleaved-%d" sample) 10 (fun () ->
        ignore (publish ());
        match pull None 1 with
        | V2_changes { windows = [ _ ]; through; _ } ->
          ignore
            (Worker.outcome worker 2003 (Worker.P.V2_ack_changes { generation; through }));
          1
        | _ -> failwith "interleaved pull lost window"))
  done
;;

let overlay size shared =
  T.with_temp_directory "rrbvec-overlay-probe-" (fun support ->
    let graph, path =
      Fixture_generator.seed_mirror
        ~application_support_directory:support
        ~block_count:(max 128 size)
    in
    Fixture_generator.seed_outbox
      ~database_path:path
      ~block_count:(if shared then 1 else max 128 size)
      ~count:size;
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let deps =
          Database.dependencies
            ~epoch_ms:(fun () -> 1704067200000L)
            ~monotonic_ns:(fun () -> 0L)
            ~limits:
              { Types.response_budget_bytes = 8 * 1024 * 1024
              ; outbox_max_records = 4096
              ; outbox_max_bytes = 8 * 1024 * 1024
              ; change_max_items = 4096
              ; change_max_bytes = 8 * 1024 * 1024
              ; dispatcher_capacity = 128
              ; wire_batch_max_bytes = 8 * 1024 * 1024
              }
          |> ok
        in
        let inspection =
          Database.inspect_mirror ~application_support_directory:support ~graph_id:graph
          |> ok
        in
        let database =
          Database.open_ ~sw deps inspection ~graph_name:"rrbvec-probe" |> ok
        in
        let snapshot = Database.current_snapshot database |> ok in
        let uuid = Fixture_generator.block_uuid 0 in
        let cursor = ref 0 in
        let replan () =
          incr cursor;
          let module Transit = Transit_core.Json in
          let module Codec = Transit_native.Transit.Json in
          let wire =
            Transit.Array
              [ Transit.Array
                  [ Transit.Keyword "db/add"
                  ; Transit.Array
                      [ Transit.Keyword "block/uuid"
                      ; Transit.Uuid (Graph.Uuid.to_string uuid)
                      ]
                  ; Transit.Keyword "rrbvec/probe"
                  ; Transit.Int !cursor
                  ]
              ]
            |> Codec.to_string ~mode:Codec.Verbose
          in
          let cursor =
            Types.Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" !cursor)
            |> ok
          in
          let batch =
            Types.authoritative_batch
              ~maximum_count:1
              ~maximum_bytes:4096
              ~transactions:
                [ Types.authoritative_transaction
                    ~cursor
                    ~transaction:
                      (Types.encoded_transaction_of_string ~maximum_bytes:4096 wire |> ok)
                ]
              ~through:cursor
              ~checksum:None
            |> ok
          in
          let view = Database.inspect_sync database |> ok in
          let prepared, crypto =
            Database.begin_authoritative
              database
              ~expected:(Types.sync_view_token view)
              batch
            |> ok
          in
          check (crypto = None) "unexpected crypto";
          match Database.apply_authoritative database prepared ~decrypted:None |> ok with
          | Database.Authoritative_applied commit ->
            List.length commit.replanned_queued_ids
          | Authoritative_deferred _ -> failwith "replan deferred"
        in
        let page = T.uuid "10000000-0000-4000-8000-000000000001" in
        for sample = 1 to 7 do
          measure (Printf.sprintf "replan-%d" sample) 1 replan;
          let current = Database.current_snapshot database |> ok in
          measure (Printf.sprintf "block-read-%d" sample) 100 (fun () ->
            let blocks = Database.get_blocks current [ uuid ] |> ok in
            check
              (match blocks with
               | [ Types.Present_block { value; _ } ] ->
                 value.block.title
                 = Printf.sprintf "Pending title %d" (if shared then size - 1 else 0)
               | _ -> false)
              "effect replay order mismatch";
            List.length blocks);
          measure (Printf.sprintf "page-read-%d" sample) 100 (fun () ->
            List.length (Database.get_pages current [ page ] |> ok));
          measure (Printf.sprintf "structure-read-%d" sample) 20 (fun () ->
            ignore
              (Database.get_structure
                 current
                 (Types.Children { parent = page; limit = 100; cursor = None })
               |> ok);
            1);
          Database.release_snapshot current
        done;
        live "overlay-frozen-root-retained";
        ignore (Database.get_blocks snapshot [ uuid ] |> ok);
        Database.release_snapshot snapshot;
        live "overlay-frozen-root-released";
        Database.close database |> ok)))
;;

let () =
  let size = int_of_string Sys.argv.(2) in
  match Sys.argv.(1) with
  | "timeline" -> timeline size
  | "worker" -> worker size
  | "overlay" -> overlay size (bool_of_string Sys.argv.(3))
  | _ -> failwith "unknown owner"
;;

let () = print_endline "OWNER_PROBE_PASSED"
