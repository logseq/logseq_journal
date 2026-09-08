let failures = ref []
let fail format = Printf.ksprintf (fun message -> failures := message :: !failures) format
let path root relative = Filename.concat root relative

let rec repository_root directory =
  if Sys.file_exists (Filename.concat directory ".git")
  then directory
  else (
    let parent = Filename.dirname directory in
    if parent = directory
    then failwith "unable to locate repository root"
    else repository_root parent)
;;

let require_file root relative =
  let candidate = path root relative in
  if not (Sys.file_exists candidate && not (Sys.is_directory candidate))
  then fail "required file is missing: %s" relative
;;

let forbid_path root relative =
  if Sys.file_exists (path root relative) then fail "forbidden path exists: %s" relative
;;

let read_file filename =
  let channel = open_in_bin filename in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let contains text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > text_length
    then false
    else if String.sub text offset needle_length = needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let count_occurrences text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop offset count =
    if needle_length = 0 || offset + needle_length > text_length
    then count
    else if String.sub text offset needle_length = needle
    then loop (offset + needle_length) (count + 1)
    else loop (offset + 1) count
  in
  loop 0 0
;;

let require_occurrences root relative needle expected =
  let candidate = path root relative in
  if not (Sys.file_exists candidate && not (Sys.is_directory candidate))
  then fail "required text file is missing: %s" relative
  else (
    let actual = count_occurrences (read_file candidate) needle in
    if actual <> expected
    then
      fail "expected %d occurrences of %S in %s, found %d" expected needle relative actual)
;;

let rec dart_files root relative =
  let candidate = path root relative in
  if not (Sys.file_exists candidate)
  then []
  else if Sys.is_directory candidate
  then
    Sys.readdir candidate
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter (fun name -> String.length name = 0 || name.[0] <> '.')
    |> List.concat_map (fun name -> dart_files root (Filename.concat relative name))
  else if Filename.check_suffix relative ".dart"
  then [ relative ]
  else []
;;

let require_allowed_dart_files root directory allowed =
  dart_files root directory
  |> List.iter (fun relative ->
    if not (List.mem relative allowed)
    then fail "Dart product or unsupported test file exists: %s" relative)
;;

let rec files_with_suffixes root relative suffixes =
  let candidate = path root relative in
  if not (Sys.file_exists candidate)
  then []
  else if Sys.is_directory candidate
  then
    Sys.readdir candidate
    |> Array.to_list
    |> List.sort String.compare
    |> List.filter (fun name -> String.length name = 0 || name.[0] <> '.')
    |> List.concat_map (fun name ->
      files_with_suffixes root (Filename.concat relative name) suffixes)
  else if List.exists (Filename.check_suffix relative) suffixes
  then [ relative ]
  else []
;;

let ocaml_product_files root = files_with_suffixes root "app" [ ".ml"; ".mli" ]

let forbid_text root relative needles =
  let candidate = path root relative in
  if Sys.file_exists candidate && not (Sys.is_directory candidate)
  then (
    let contents = read_file candidate in
    List.iter
      (fun needle ->
         if contains contents needle
         then fail "forbidden text %S exists in %s" needle relative)
      needles)
;;

let require_text root relative needles =
  let candidate = path root relative in
  if not (Sys.file_exists candidate && not (Sys.is_directory candidate))
  then fail "required text file is missing: %s" relative
  else (
    let contents = read_file candidate in
    List.iter
      (fun needle ->
         if not (contains contents needle)
         then fail "required text %S is missing from %s" needle relative)
      needles)
;;

let text_between text ~start_marker ~end_marker =
  let marker_offset marker from =
    let marker_length = String.length marker in
    let rec find offset =
      if offset + marker_length > String.length text
      then None
      else if String.sub text offset marker_length = marker
      then Some offset
      else find (offset + 1)
    in
    find from
  in
  match marker_offset start_marker 0 with
  | None -> None
  | Some start_offset ->
    let content_start = start_offset + String.length start_marker in
    Option.map
      (fun end_offset -> String.sub text content_start (end_offset - content_start))
      (marker_offset end_marker content_start)
;;

let test_sync_error_card_is_temporary_and_error_only root =
  let application = read_file (path root "app/application.ml") in
  match
    text_between
      application
      ~start_marker:"  let overlays =\n    match sync_error with"
      ~end_marker:"  in\n  let body ="
  with
  | None -> fail "unable to locate the Timeline sync-error overlay"
  | Some overlay ->
    List.iter
      (fun obsolete ->
         if contains overlay obsolete
         then fail "sync-error card retains obsolete action text %S" obsolete)
      [ "Reset local copy"
      ; "Reset local graph copy"
      ; "request-local-cache-reset"
      ; "cache_reset_available"
      ; "on_cache_reset_requested"
      ];
    List.iter
      (fun required ->
         if not (contains application required)
         then fail "sync-error timeout behavior is missing %S" required)
      [ "let sync_error_card_lifetime = Core.Time_ns.Span.of_sec 5."
      ; "let sync_error_timer_key ="
      ; "let sync_error_timer_callback ="
      ; "Core.Time_ns.add now sync_error_card_lifetime"
      ; "Int64.equal current_sequence scheduled_sequence"
      ]
;;

let contains_dune_internal_module_path contents =
  let is_identifier_character = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  let is_uppercase = function
    | 'A' .. 'Z' -> true
    | _ -> false
  in
  let length = String.length contents in
  let rec identifier_contains_private_separator offset stop =
    offset + 2 < stop
    && ((contents.[offset] = '_'
         && contents.[offset + 1] = '_'
         && is_uppercase contents.[offset + 2])
        || identifier_contains_private_separator (offset + 1) stop)
  in
  let rec scan offset =
    if offset >= length
    then false
    else if
      is_uppercase contents.[offset]
      && (offset = 0 || not (is_identifier_character contents.[offset - 1]))
    then (
      let rec identifier_end cursor =
        if cursor < length && is_identifier_character contents.[cursor]
        then identifier_end (cursor + 1)
        else cursor
      in
      let stop = identifier_end (offset + 1) in
      identifier_contains_private_separator offset stop || scan stop)
    else scan (offset + 1)
  in
  scan 0
;;

let test_public_api_only_test_boundaries root =
  let test_roots = [ "logseq_sync/test"; "logseq_db_worker/test"; "test" ] in
  let ocaml_files =
    List.concat_map
      (fun relative -> files_with_suffixes root relative [ ".ml"; ".mli" ])
      test_roots
    |> List.filter (fun relative -> relative <> "test/source_boundary_test.ml")
  in
  List.iter
    (fun relative ->
       if contains_dune_internal_module_path (read_file (path root relative))
       then fail "test source names an unexposed Dune module: %s" relative)
    ocaml_files;
  List.concat_map
    (fun relative -> files_with_suffixes root relative [ "dune" ])
    test_roots
  |> List.iter (fun relative ->
    forbid_text root relative [ ".objs/byte"; ".objs/native" ]);
  require_file root "logseq_sync/test/core_contract.ml";
  require_file root "logseq_sync/test/runner_contract.ml";
  require_file root "logseq_sync/test/sync_protocol_contract.ml";
  forbid_path root "logseq_sync/test/test_support.ml"
;;

let test_logseq_sync_suite_boundary root =
  let sync_test_files = files_with_suffixes root "logseq_sync/test" [ ".ml"; "dune" ] in
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "T.case"
         ; "T.run"
         ; "T.require"
         ; "T.fail"
         ; "Logseq_db_worker"
         ; "Logseq_db_worker__"
         ; "Logseq_db_worker_test_support"
         ; "logseq_db_worker"
         ])
    sync_test_files;
  require_text root "logseq_sync/test/test_sync.ml" [ "Alcotest.run" ];
  require_text root "logseq_sync/test/dune" [ "alcotest" ];
  forbid_text root "logseq_sync/lib/pure_reducer/dune" [ "alcotest" ];
  forbid_text root "logseq_sync/lib/effect_runner/dune" [ "alcotest" ];
  require_text root "dune-project" [ "(alcotest (and :with-test (= 1.7.0)))" ];
  require_text root "logseq_sync.opam" [ "\"alcotest\" {with-test & = \"1.7.0\"}" ];
  require_text root "logseq_sync.opam.locked" [ "\"alcotest\" {= \"1.7.0\" & with-test}" ];
  List.iter
    (forbid_path root)
    [ "logseq_sync/test/test_capabilities.ml"
    ; "logseq_sync/test/test_catalog.ml"
    ; "logseq_sync/test/test_catalog_store.ml"
    ; "logseq_sync/test/test_e2ee_session.ml"
    ; "logseq_sync/test/test_graph_key.ml"
    ; "logseq_sync/test/test_network_scope.ml"
    ; "logseq_sync/test/test_transport_ownership.ml"
    ]
;;

let test_logseq_sync_package_boundary root =
  List.iter
    (require_file root)
    [ "logseq_db_types.opam"
    ; "logseq_db_types.opam.locked"
    ; "logseq_db_storage.opam"
    ; "logseq_db_storage.opam.locked"
    ; "logseq_sync.opam"
    ; "logseq_sync.opam.locked"
    ; "logseq_db_worker.opam"
    ; "logseq_db_types/lib/dune"
    ; "logseq_db_types/lib/graph_types.ml"
    ; "logseq_db_types/lib/graph_types.mli"
    ; "logseq_db_types/lib/sync_checkpoint.ml"
    ; "logseq_db_types/lib/sync_checkpoint.mli"
    ; "logseq_db_storage/lib/dune"
    ; "logseq_db_storage/lib/sync_checkpoint_store.ml"
    ; "logseq_db_storage/lib/sync_checkpoint_store.mli"
    ; "logseq_sync/lib/pure_reducer/dune"
    ; "logseq_sync/lib/pure_reducer/core.ml"
    ; "logseq_sync/lib/pure_reducer/sync_protocol.ml"
    ; "logseq_sync/lib/effect_runner/dune"
    ; "logseq_sync/lib/effect_runner/effect_runner.ml"
    ; "logseq_sync/lib/effect_runner/platform/platform_crypto.ml"
    ; "logseq_sync/spec/pure_reducer/dune"
    ; "logseq_sync/spec/pure_reducer/core.mli"
    ; "logseq_sync/spec/pure_reducer/sync_protocol.mli"
    ; "logseq_sync/spec/effect_runner/dune"
    ; "logseq_sync/spec/effect_runner/effect_runner.mli"
    ];
  List.iter
    (forbid_path root)
    [ "spec/dune"
    ; "spec/sync_action.mli"
    ; "spec/sync_startup_phase.mli"
    ; "logseq_sync/spec/client.mli"
    ; "logseq_sync/spec/action.mli"
    ; "logseq_sync/spec/startup_phase.mli"
    ; "logseq_sync/spec/api.mli"
    ; "logseq_sync/spec/dune"
    ; "logseq_sync/spec/core.mli"
    ; "logseq_sync/spec/effect_runner.mli"
    ; "logseq_sync/spec/sync_protocol.mli"
    ; "logseq_sync/lib/api.ml"
    ; "logseq_sync/lib/dune"
    ; "logseq_sync/lib/core.ml"
    ; "logseq_sync/lib/effect_runner.ml"
    ; "logseq_sync/lib/pure_core.ml"
    ; "logseq_sync/lib/sync_protocol.ml"
    ; "logseq_sync/lib/sync_protocol_core.ml"
    ; "logseq_db_worker/lib/graph_types.ml"
    ; "logseq_db_worker/lib/graph_types.mli"
    ; "logseq_db_worker/lib/admission.ml"
    ; "logseq_db_worker/lib/admission.mli"
    ; "logseq_db_worker/lib/logseq_sqlite_codec.ml"
    ; "logseq_db_worker/lib/logseq_sqlite_codec.mli"
    ; "logseq_db_worker/lib/logseq_sqlite_storage.ml"
    ; "logseq_db_worker/lib/logseq_sqlite_storage.mli"
    ; "logseq_db_worker/lib/storage_session.ml"
    ; "logseq_db_worker/lib/storage_session.mli"
    ; "logseq_db_worker/lib/sync_meta.ml"
    ; "logseq_db_worker/lib/sync_meta.mli"
    ; "logseq_db_worker/lib/sync_manager.ml"
    ; "logseq_db_worker/lib/sync_manager.mli"
    ; "logseq_db_worker/lib/sync_pending.ml"
    ; "logseq_db_worker/lib/sync_pending.mli"
    ; "logseq_db_worker/lib/sync_platform_crypto_stubs.c"
    ; "logseq_db_worker/lib/sync_gzip_stubs.c"
    ];
  require_text
    root
    "dune-project"
    [ "(package\n (name logseq_db_types)"
    ; "(package\n (name logseq_db_storage)"
    ; "(package\n (name logseq_sync)"
    ; "(package\n (name logseq_db_worker)"
    ];
  require_occurrences root "dune-project" "(logseq_overlay_db (= 0.1.0))" 2;
  require_text
    root
    "logseq_sync/spec/pure_reducer/dune"
    [ "(name logseq_sync_pure_reducer)"; "(public_name logseq_sync.pure_reducer)" ];
  require_text
    root
    "logseq_sync/spec/effect_runner/dune"
    [ "(name logseq_sync_effect_runner)"
    ; "(public_name logseq_sync.effect_runner)"
    ; "logseq_sync.pure_reducer"
    ];
  require_text root "logseq_sync/lib/effect_runner/dune" [ "(private_modules" ];
  require_text
    root
    "logseq_db_worker/lib/dune"
    [ "logseq_overlay_db"; "logseq_sync.pure_reducer" ];
  forbid_text root "logseq_db_worker/lib/dune" [ "logseq_db_storage"; "datascript" ];
  require_text root "logseq_db_storage.opam" [ "\"logseq_db_types\" {= \"0.1.0\"}" ];
  require_text root "logseq_sync.opam" [ "\"logseq_overlay_db\" {= \"0.1.0\"}" ];
  require_text root "logseq_sync.opam.locked" [ "\"logseq_overlay_db\" {= \"0.1.0\"}" ];
  forbid_text root "logseq_sync.opam" [ "\"logseq_db_storage\""; "\"datascript_ocaml\"" ];
  require_text
    root
    "logseq_db_worker.opam"
    [ "\"logseq_overlay_db\" {= \"0.1.0\"}"; "\"logseq_sync\" {= \"0.1.0\"}" ];
  require_text
    root
    "logseq_db_worker.opam.locked"
    [ "\"logseq_overlay_db\" {= \"0.1.0\"}"; "\"logseq_sync\" {= \"0.1.0\"}" ];
  require_text root "logseq_journal.opam.locked" [ "\"logseq_overlay_db\" {= \"0.1.0\"}" ];
  forbid_text
    root
    "logseq_db_worker.opam"
    [ "\"logseq_db_storage\""; "\"datascript_ocaml\"" ];
  forbid_text
    root
    "logseq_db_worker.opam"
    [ "\"bigstringaf\""
    ; "\"ca-certs-nss\""
    ; "\"cstruct\""
    ; "\"domain-name\""
    ; "\"faraday\""
    ; "\"httpun\""
    ; "\"httpun-eio\""
    ; "\"httpun-ws\""
    ; "\"mirage-crypto-rng\""
    ; "\"tls\""
    ; "\"tls-eio\""
    ];
  forbid_text
    root
    "logseq_db_worker/contract/protocol.mli"
    [ "| Read of"
    ; "| Mutate of"
    ; "| V2 of"
    ; "Graph_invalidated"
    ; "type invalidation ="
    ; "and read_command ="
    ; "Logseq_db_types.Mutation"
    ; "and mutation ="
    ; "and structural_mutation ="
    ; "and page_mutation ="
    ; "and property_mutation ="
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "Logseq_db_worker"
         ; "Logseq_db_worker__"
         ; "logseq_db_worker/lib"
         ; "logseq_db_worker.sync_spec"
         ])
    (files_with_suffixes root "logseq_sync/lib" [ ".ml"; ".mli"; ".c"; "dune" ]
     @ files_with_suffixes root "logseq_sync/spec" [ ".ml"; ".mli"; "dune" ]);
  List.iter
    (fun relative ->
       forbid_text root relative [ "Logseq_sync"; "Logseq_sync__"; "logseq_sync/lib" ])
    (files_with_suffixes root "logseq_db_storage" [ ".ml"; ".mli"; ".c"; "dune" ]);
  forbid_text
    root
    "logseq_db_worker/lib/logseq_db_worker.mli"
    [ "Sync_action"
    ; "Sync_manager"
    ; "Sync_pending"
    ; "Sync_protocol"
    ; "Sync_replay"
    ; "Sync_websocket"
    ]
;;

let test_injected_logseq_sync_api_boundary root =
  List.iter
    (require_file root)
    [ "logseq_sync/spec/pure_reducer/dune"
    ; "logseq_sync/spec/pure_reducer/core.mli"
    ; "logseq_sync/spec/pure_reducer/sync_protocol.mli"
    ; "logseq_sync/spec/effect_runner/dune"
    ; "logseq_sync/spec/effect_runner/effect_runner.mli"
    ; "logseq_sync/lib/pure_reducer/dune"
    ; "logseq_sync/lib/pure_reducer/sync_protocol.ml"
    ; "logseq_sync/lib/pure_reducer/core.ml"
    ; "logseq_sync/lib/effect_runner/dune"
    ; "logseq_sync/lib/effect_runner/effect_runner.ml"
    ; "logseq_sync/test/core_contract.ml"
    ; "logseq_sync/test/runner_contract.ml"
    ];
  List.iter
    (forbid_path root)
    [ "logseq_sync/spec/api.mli"
    ; "logseq_sync/spec/dune"
    ; "logseq_sync/spec/core.mli"
    ; "logseq_sync/spec/effect_runner.mli"
    ; "logseq_sync/spec/sync_protocol.mli"
    ; "logseq_sync/lib/api.ml"
    ; "logseq_sync/lib/dune"
    ; "logseq_sync/lib/core.ml"
    ; "logseq_sync/lib/effect_runner.ml"
    ; "logseq_sync/lib/pure_core.ml"
    ; "logseq_sync/lib/sync_protocol.ml"
    ; "logseq_sync/lib/sync_protocol_core.ml"
    ; "logseq_sync/test/api_contract.ml"
    ];
  require_text
    root
    "logseq_sync/spec/pure_reducer/dune"
    [ "(name logseq_sync_pure_reducer)"
    ; "(public_name logseq_sync.pure_reducer)"
    ; "(modules core sync_protocol)"
    ; "(virtual_modules core sync_protocol)"
    ; "(default_implementation logseq_sync_pure_reducer_impl)"
    ];
  require_text
    root
    "logseq_sync/spec/effect_runner/dune"
    [ "(name logseq_sync_effect_runner)"
    ; "(public_name logseq_sync.effect_runner)"
    ; "(modules effect_runner)"
    ; "(virtual_modules effect_runner)"
    ; "(default_implementation logseq_sync_effect_runner_impl)"
    ; "logseq_sync.pure_reducer"
    ];
  require_text
    root
    "logseq_sync/spec/pure_reducer/core.mli"
    [ "type t"
    ; "type event ="
    ; "type runner_effect"
    ; "type worker_effect"
    ; "type instruction ="
    ; "val initial : config -> (t, create_error) result"
    ; "val step : t -> event -> transition"
    ; "| Run of runner_effect"
    ; "| Delegate of worker_effect"
    ; "| Publish of output"
    ; "Sync_protocol.Client.message"
    ; "Sync_protocol.Server.message"
    ];
  forbid_text
    root
    "logseq_sync/spec/pure_reducer/core.mli"
    [ "type effect ="; "val effect :" ];
  require_text
    root
    "logseq_sync/spec/effect_runner/effect_runner.mli"
    [ "type t"
    ; "val create"
    ; "post:(Logseq_sync_pure_reducer.Core.event -> unit)"
    ; "val submit : t -> Logseq_sync_pure_reducer.Core.runner_effect -> unit"
    ; "val shutdown : t -> unit"
    ];
  forbid_text
    root
    "logseq_sync/lib/pure_reducer/core.ml"
    [ "mutable"; " := "; "Effect.perform"; "Eio"; "Unix"; "Sys."; "Logseq_db_worker" ];
  require_text
    root
    "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml"
    [ "module Pure = Logseq_db_worker_pure_reducer.Core"
    ; "module Worker_runner = Logseq_db_worker_effect_runner.Effect_runner"
    ; "module Sync_runner = Logseq_sync_effect_runner.Effect_runner"
    ; "Db.create"
    ; "Db.post"
    ; "Db.request"
    ];
  forbid_text
    root
    "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml"
    [ "Logseq_sync.Api"; "Core.handle"; "Core.resume" ];
  let worker_files =
    files_with_suffixes root "logseq_db_worker" [ ".ml"; ".mli"; "dune" ]
  in
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "Logseq_sync."; "Logseq_sync__"; ".logseq_sync_impl.objs" ])
    worker_files
;;

let test_standalone_sync_protocol_boundary root =
  require_text
    root
    "logseq_sync/spec/pure_reducer/sync_protocol.mli"
    [ "type cursor = int"
    ; "type checksum = string"
    ; "module Client : sig"
    ; "module Server : sig"
    ; "type codec_error ="
    ; "val encode_client_message"
    ; "val decode_client_message"
    ; "val encode_server_message"
    ; "val decode_server_message"
    ; "val error_to_string"
    ];
  forbid_text
    root
    "logseq_sync/spec/pure_reducer/sync_protocol.mli"
    [ "Logseq_sync_pure_core"; "Sync_protocol_core" ];
  require_text
    root
    "logseq_sync/lib/pure_reducer/dune"
    [ "(name logseq_sync_pure_reducer_impl)"
    ; "(public_name logseq_sync.pure_reducer.impl)"
    ; "(implements logseq_sync_pure_reducer)"
    ; "(modules core sync_protocol)"
    ];
  List.iter
    (forbid_path root)
    [ "logseq_sync/lib/pure_reducer/checksum.ml"
    ; "logseq_sync/lib/pure_reducer/checksum.mli"
    ; "logseq_sync/lib/pure_reducer/pure_tx.ml"
    ];
  require_text
    root
    "logseq_sync/lib/pure_reducer/sync_protocol.ml"
    [ "type cursor = int"
    ; "type checksum = string"
    ; "module Client = struct"
    ; "module Server = struct"
    ; "let decode_client_message"
    ; "let encode_server_message"
    ];
  forbid_text
    root
    "logseq_sync/lib/pure_reducer/sync_protocol.ml"
    [ "Sync_protocol_core"; "include Logseq_sync_pure_core" ];
  require_text
    root
    "logseq_sync/lib/pure_reducer/core.ml"
    [ "Sync_protocol.Client.message"
    ; "Sync_protocol.Server.message"
    ; "Sync_protocol.codec_error"
    ];
  forbid_text
    root
    "logseq_sync/lib/pure_reducer/core.ml"
    [ "type authoritative_message ="
    ; "let parse_authoritative_message"
    ; "let pull_payload"
    ; "let submission_payload"
    ; "pending_payload"
    ; "Websocket_frame"
    ; "non-authoritative WebSocket message"
    ; "Sync_protocol_core"
    ; "Core_protocol"
    ; "Protocol_adapter"
    ; "export_client_message"
    ; "import_server_message"
    ; "import_rejection_reason"
    ];
  require_text
    root
    "logseq_sync/lib/effect_runner/effect_runner.ml"
    [ "Sync_protocol.decode_server_message"
    ; "Sync_protocol.encode_client_message"
    ; "Core.Websocket_message"
    ; "Core.Websocket_protocol_error"
    ];
  forbid_text
    root
    "logseq_sync/lib/effect_runner/effect_runner.ml"
    [ "Core.Websocket_frame" ];
  require_text
    root
    "logseq_sync/test/sync_protocol_contract.ml"
    [ "module Protocol = Logseq_sync_pure_reducer.Sync_protocol"
    ; "all client messages round trip"
    ; "all server messages round trip"
    ; "unknown fields are strict and safe"
    ; "protocol validation is fail closed"
    ]
;;

let test_bonsai_flutter_dune_closure_names root =
  require_text root "logseq_sync/lib/effect_runner/dune" [ "logseq_sync.pure_reducer" ];
  require_text root "logseq_db_worker/lib/dune" [ "logseq_sync.pure_reducer" ];
  let pure_dune = "logseq_sync/lib/pure_reducer/dune" in
  forbid_text
    root
    pure_dune
    [ "eio"; "unix"; "x509"; "tls"; "httpun"; "logseq_db_storage"; "platform_crypto" ];
  List.iter
    (forbid_path root)
    [ "logseq_sync/lib/pure_core.ml"
    ; "logseq_sync/lib/sync_protocol_core.ml"
    ; "logseq_sync/lib/core.ml"
    ; "logseq_sync/lib/sync_protocol.ml"
    ; "logseq_sync/lib/effect_runner.ml"
    ]
;;

let test_worker_owned_overlay_orchestration root =
  let forbidden_raw_data_plane =
    [ "Datascript.db"
    ; "Datascript.tx_op"
    ; "Logseq_db_storage"
    ; "Sync_checkpoint.t"
    ; "outbox_records : string list"
    ; "projection_transactions"
    ; "authoritative_database"
    ; "projected_database"
    ]
  in
  List.iter
    (fun relative -> forbid_text root relative forbidden_raw_data_plane)
    (files_with_suffixes root "logseq_sync/spec" [ ".mli" ]
     @ files_with_suffixes root "logseq_sync/lib" [ ".ml"; ".mli" ]);
  let sync_files = files_with_suffixes root "logseq_sync" [ ".ml"; ".mli" ] in
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "Engine.t"; "Engine.open_"; "Engine.close"; "Logseq_db_worker" ])
    sync_files;
  require_text
    root
    "logseq_sync/spec/pure_reducer/core.mli"
    [ "Logseq_overlay_db.Types"; "type worker_effect =" ];
  require_text
    root
    "logseq_db_worker/lib/effect_runner/effect_runner.ml"
    [ "Logseq_overlay_db.Database"; "Logseq_overlay_db.Types" ];
  forbid_text
    root
    "logseq_db_worker/lib/effect_runner/effect_runner.ml"
    [ "Logseq_db_worker_engine"
    ; "Engine."
    ; "Mutation."
    ; "Datascript."
    ; "Logseq_db_storage"
    ];
  require_text
    root
    "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml"
    [ "Logseq_db_worker_pure_reducer.Core"
    ; "Logseq_db_worker_effect_runner.Effect_runner"
    ; "Sync_runner.create"
    ];
  forbid_text
    root
    "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml"
    [ "Core.graph_backend"
    ; "Core.mutate"
    ; "Core.Engine"
    ; "Mutation.to_yojson mutation"
    ; "Db.Engine"
    ]
;;

let test_logseq_sync_install_manifest filename =
  let contents = read_file filename in
  if
    not
      (contains
         contents
         {|"_build/install/default/lib/logseq_sync/pure_reducer/logseq_sync_pure_reducer.cmi"|})
  then fail "installed logseq_sync package is missing its pure-reducer interface";
  List.iter
    (fun module_name ->
       if
         not
           (contains
              contents
              (Printf.sprintf
                 {|"_build/install/default/lib/logseq_sync/pure_reducer/logseq_sync_pure_reducer__%s.cmi"|}
                 module_name))
       then fail "installed pure-reducer library is missing public %s" module_name)
    [ "Core"; "Sync_protocol" ];
  if
    not
      (contains
         contents
         {|"_build/install/default/lib/logseq_sync/effect_runner/logseq_sync_effect_runner.cmi"|})
  then fail "installed logseq_sync package is missing its effect-runner interface";
  if
    not
      (contains
         contents
         {|"_build/install/default/lib/logseq_sync/effect_runner/logseq_sync_effect_runner__Effect_runner.cmi"|})
  then fail "installed effect-runner library is missing public Effect_runner";
  List.iter
    (fun obsolete ->
       if contains contents obsolete
       then fail "obsolete combined Logseq_sync interface remains installed: %s" obsolete)
    [ {|"_build/install/default/lib/logseq_sync/logseq_sync.cmi"|}
    ; "/logseq_sync__Core.cmi"
    ; "/logseq_sync__Effect_runner.cmi"
    ; "/logseq_sync__Sync_protocol.cmi"
    ]
;;

let test_logseq_overlay_db_install_manifest filename =
  let contents = read_file filename in
  List.iter
    (fun installed_interface ->
       if not (contains contents installed_interface)
       then fail "installed logseq_overlay_db package is missing %s" installed_interface)
    [ "/logseq_overlay_db/types.mli"; "/logseq_overlay_db/database.mli" ];
  List.iter
    (fun (source, compiled) ->
       if not (contains contents ("/impl/" ^ source ^ ".mli"))
       then fail "installed overlay implementation is missing private module %s" source;
       if not (contains contents ("/impl/.private/" ^ compiled ^ ".cmi"))
       then fail "installed overlay module is not compiled into .private: %s" source;
       if contains contents ("/logseq_overlay_db/" ^ source ^ ".mli")
       then fail "installed overlay virtual library exposes private module %s" source)
    [ "queryable_outbox", "logseq_overlay_db__logseq_overlay_db_impl__Queryable_outbox"
    ; "overlay_read", "logseq_overlay_db__logseq_overlay_db_impl__Overlay_read"
    ; "overlay_planner", "logseq_overlay_db__logseq_overlay_db_impl__Overlay_planner"
    ; "transition", "logseq_overlay_db__logseq_overlay_db_impl__Transition"
    ; ( "authoritative_store"
      , "logseq_overlay_db__logseq_overlay_db_impl__Authoritative_store" )
    ]
;;

let test_final_overlay_data_plane_boundary root =
  List.iter
    (require_file root)
    [ "logseq_overlay_db/spec/types.mli"
    ; "logseq_overlay_db/spec/database.mli"
    ; "logseq_overlay_db/lib/database.ml"
    ];
  List.iter
    (forbid_path root)
    [ "logseq_db_types/lib/mutation.ml"
    ; "logseq_db_types/lib/mutation.mli"
    ; "logseq_db_worker/lib/engine.ml"
    ; "logseq_db_worker/lib/engine.mli"
    ; "logseq_db_worker/lib/read_model.ml"
    ; "logseq_db_worker/lib/read_model.mli"
    ; "logseq_db_worker/lib/query.ml"
    ; "logseq_db_worker/lib/query.mli"
    ; "logseq_db_worker/lib/mutation_plan.ml"
    ; "logseq_db_worker/lib/mutation_plan.mli"
    ; "logseq_db_worker/lib/outliner_order.ml"
    ; "logseq_db_worker/lib/outliner_order.mli"
    ; "logseq_db_worker/lib/ownership.ml"
    ; "logseq_db_worker/lib/ownership.mli"
    ; "logseq_db_worker/lib/synced_mirror.ml"
    ; "logseq_db_worker/lib/synced_mirror.mli"
    ; "logseq_db_worker/lib/synced_snapshot_parser.ml"
    ; "logseq_db_worker/lib/synced_snapshot_parser.mli"
    ; "logseq_db_worker/lib/outliner"
    ; "logseq_db_worker/test/test_engine_managed.ml"
    ; "logseq_db_worker/test/test_storage_atomicity.ml"
    ; "logseq_db_worker/test/test_performance.ml"
    ; "logseq_db_worker/test/fixtures/protocol/v1-command-catalog.json"
    ; "logseq_db_worker/test/fixtures/protocol/v1-operation-contracts.json"
    ; "logseq_db_worker/test/fixtures/protocol/v1-outcome-catalog.json"
    ; "logseq_db_worker/test/fixtures/performance/100000-blocks-v1.manifest.json"
    ; "logseq_db_worker/test/fixtures/performance/reference-apple-silicon-v1.json"
    ; "logseq_db_worker/tool/performance_benchmark.ml"
    ; "logseq_db_worker/tool/test_performance.sh"
    ; "logseq_sync/lib/pure_reducer/pure_tx.ml"
    ; "logseq_sync/lib/pure_reducer/checksum.ml"
    ; "logseq_sync/lib/pure_reducer/checksum.mli"
    ; "logseq_db_types/test/test_mutation_identity.ml"
    ; "logseq_db_types/test/dune"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "Datascript.db"
         ; "Datascript.conn"
         ; "Datascript.entity_id"
         ; "Datascript.tx_op"
         ; "Logseq_db_types.Mutation"
         ; "projected_db"
         ; "projected_conn"
         ; "Projected_connection"
         ])
    (files_with_suffixes root "logseq_overlay_db/spec" [ ".mli" ]);
  forbid_text
    root
    "logseq_db_storage/lib/storage_session.mli"
    [ "val current_db"; "db:Datascript.db"; "Persistent_sorted_set.t" ];
  forbid_text
    root
    "logseq_overlay_db/lib/database.ml"
    [ "mutable authoritative_blocks"
    ; "mutable authoritative_pages"
    ; "mutable blocks : (Graph.block_uuid * Types.block_record) list"
    ; "mutable pages : (Graph.page_uuid * Types.page_record) list"
    ; "blocks : (Graph.block_uuid * Types.block_record) list"
    ; "pages : (Graph.page_uuid * Types.page_record) list"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "Logseq_db_types.Mutation"
         ; "Logseq_db_worker_engine"
         ; "Engine."
         ; "Datascript."
         ; "Logseq_db_storage"
         ; "Storage_session"
         ; "projected_db"
         ; "projected_conn"
         ])
    (files_with_suffixes root "logseq_db_worker/contract" [ ".ml"; ".mli"; "dune" ]
     @ files_with_suffixes root "logseq_db_worker/spec" [ ".ml"; ".mli"; "dune" ]
     @ files_with_suffixes root "logseq_db_worker/lib" [ ".ml"; ".mli"; "dune" ]
     @ files_with_suffixes root "logseq_db_worker/bonsai" [ ".ml"; ".mli"; "dune" ]);
  List.iter
    (fun relative -> forbid_text root relative [ "Logseq_overlay_db"; "Logseq_sync" ])
    (ocaml_product_files root);
  forbid_text root "app/dune" [ "logseq_sync"; "logseq_overlay_db" ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "type graph_info ="; "basis : int64"; "expected_basis" ])
    [ "logseq_db_types/lib/graph_types.ml"; "logseq_db_types/lib/graph_types.mli" ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "type state ="; "type t ="; "type pending ="; "type success =" ])
    [ "logseq_db_types/lib/sync_status.ml"; "logseq_db_types/lib/sync_status.mli" ]
;;

let test_repository_local_runtime_tests root =
  List.iter
    (forbid_path root)
    [ "logseq_db_worker/test/test_cross_runtime.ml"
    ; "logseq_db_worker/tool/logseq_oracle.cljs"
    ];
  forbid_text root "logseq_db_worker/test/dune" [ "test_cross_runtime" ];
  let forbidden_external_runtime =
    [ "../logseq-oracle"
    ; "../logseq-worker-interop"
    ; "nbb-logseq"
    ; "\"pnpm\""
    ; "command_output \"git\""
    ; "let node_script"
    ; "\"/usr/bin/curl\""
    ; "--oracle-logseq-repo"
    ; "--interop-logseq-repo"
    ]
  in
  files_with_suffixes root "logseq_db_worker/test" [ ".ml"; ".mli" ]
  |> List.iter (fun relative -> forbid_text root relative forbidden_external_runtime);
  match files_with_suffixes root "logseq_db_worker" [ ".cljs" ] with
  | [] -> ()
  | files -> fail "ClojureScript test dependencies remain: %s" (String.concat ", " files)
;;

let test_sync_transport_is_websocket_only root =
  let obsolete_symbols =
    [ "Http_pull"
    ; "Transaction_submission"
    ; "Fetch_http_pull"
    ; "Submit_http_transaction"
    ; "Http_pull_loaded"
    ; "Http_transaction_loaded"
    ; "Awaiting_http_pull_token"
    ; "Http_pull_in_flight"
    ; "Http_catchup_applied"
    ; "Awaiting_http_submission_token"
    ; "recover_after_http_pull"
    ; "decode_http_pull_response"
    ; "httpPull"
    ; "transactionSubmission"
    ]
  in
  List.iter
    (fun relative -> forbid_text root relative obsolete_symbols)
    [ "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml"
    ; "app/journal_platform.ml"
    ; "flutter/lib/application_host_adapter.dart"
    ];
  forbid_text
    root
    "logseq_sync/lib/effect_runner/eio/http.ml"
    [ "\"since\", string_of_int"; "graph_path graph_id \"tx/batch\"" ];
  forbid_text
    root
    "logseq_sync/lib/effect_runner/eio/http.mli"
    [ "val pull"; "val transaction_batch" ]
;;

let has_exact_dependency contents ~package ~version =
  contains contents (Printf.sprintf "\"%s\" {= \"%s\"}" package version)
;;

let test_startup_phase_ownership root =
  require_text
    root
    "logseq_sync/spec/pure_reducer/core.mli"
    [ "type sync_phase ="
    ; "| Offline"
    ; "| Connecting"
    ; "| Pulling"
    ; "| Submitting"
    ; "| Current"
    ; "| Paused"
    ; "sync_phase : sync_phase"
    ];
  forbid_text
    root
    "logseq_sync/spec/pure_reducer/core.mli"
    [ "type phase ="
    ; "| Signed_out"
    ; "| Loading_catalog"
    ; "| Awaiting_selection"
    ; "| Restoring_local"
    ; "| Bootstrapping"
    ; "| Awaiting_e2ee_password"
    ; "| Opening_graph"
    ; "| Graph_open"
    ; "| Sync_paused"
    ];
  require_text
    root
    "logseq_db_worker/lib/logseq_db_worker.mli"
    [ "type graph_phase ="
    ; "| Graph_closed"
    ; "| Graph_opening"
    ; "| Graph_open"
    ; "| Graph_closing"
    ; "| Graph_failed"
    ; "type graph_state ="
    ];
  require_text
    root
    "app/journal_startup.mli"
    [ "type startup_phase ="
    ; "| Signed_out"
    ; "| Loading_catalog"
    ; "| Awaiting_selection"
    ; "| Restoring_local"
    ; "| Bootstrapping"
    ; "| Awaiting_e2ee_password"
    ; "| Ready"
    ; "type startup_error_owner ="
    ; "type startup_recovery ="
    ; "type startup_error ="
    ; "type startup_state ="
    ; "val derive"
    ];
  forbid_text
    root
    "app/application.ml"
    [ "Logseq_sync.Core.phase"; "snapshot.Logseq_sync.Core.phase" ]
;;

let require_exact_dependency root relative ~package ~version =
  let candidate = path root relative in
  if not (Sys.file_exists candidate && not (Sys.is_directory candidate))
  then fail "required dependency file is missing: %s" relative
  else if not (has_exact_dependency (read_file candidate) ~package ~version)
  then fail "required dependency %s.%s is missing from %s" package version relative
;;

let test_exact_dependency_matching () =
  let exact = "depends: [\n  \"ocaml-ios64\" {= \"5.1.1\"}\n]\n" in
  let wrong_version = "depends: [\n  \"ocaml-ios64\" {= \"5.3.0\"}\n]\n" in
  let unpinned = "depends: [\n  \"ocaml-ios64\"\n]\n" in
  if not (has_exact_dependency exact ~package:"ocaml-ios64" ~version:"5.1.1")
  then fail "exact dependency matcher rejected the required iOS compiler";
  if has_exact_dependency "depends: []\n" ~package:"ocaml-ios64" ~version:"5.1.1"
  then fail "exact dependency matcher accepted an absent iOS compiler";
  if has_exact_dependency wrong_version ~package:"ocaml-ios64" ~version:"5.1.1"
  then fail "exact dependency matcher accepted a conflicting iOS compiler version";
  if has_exact_dependency unpinned ~package:"ocaml-ios64" ~version:"5.1.1"
  then fail "exact dependency matcher accepted an unpinned iOS compiler"
;;

let test_deployed_managed_sync_e2e_boundary root =
  let source = "logseq_db_worker/test/test_managed_sync_e2e.ml" in
  let dune = "logseq_db_worker/test/dune" in
  require_file root source;
  require_text
    root
    source
    [ "https://api.logseq.io"
    ; "Service.service"
    ; "Worker_runtime.start"
    ; "Service.Graph_request"
    ; "V2_list_journals"
    ; "V2_insert_blocks"
    ; "V2_get_block"
    ; "V2_delete_blocks"
    ; "flutter/JournalE2EECrypto.swift"
    ; "LOGSEQ_JOURNAL_E2EE_TEST_FILE_KEYCHAIN"
    ; "DYLD_INSERT_LIBRARIES"
    ; "-emit-library"
    ];
  require_text
    root
    "logseq_db_worker/test/managed_sync_e2e_support.ml"
    [ "LOGSEQ_DB_WORKER_E2E_USERNAME"
    ; "LOGSEQ_DB_WORKER_E2E_PASSWORD"
    ; "LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD"
    ; "LOGSEQ_DB_WORKER_E2E_GRAPH_NAME"
    ];
  require_text
    root
    "logseq_db_worker/tool/cognito_e2e_login.sh"
    [ "--data-binary @-"
    ; "AWSCognitoIdentityProviderService.InitiateAuth"
    ; "https://cognito-idp.us-east-1.amazonaws.com/"
    ];
  forbid_text
    root
    source
    [ "Core.step"
    ; "Piaf.Server"
    ; "inet_addr_loopback"
    ; "test-ca.pem"
    ; "localhost.pem"
    ; "localhost-key.pem"
    ; "sender-bearer-token"
    ; "receiver-bearer-token"
    ; "--managed-sync-client"
    ; "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE"
    ; "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE"
    ; "Create_ordinary_page"
    ; "Delete_page"
    ; "Permanently_delete_recycled_page"
    ; "List_pages"
    ; "expected_basis"
    ; "Logseq_db_types.Mutation"
    ];
  List.iter
    (forbid_path root)
    [ "logseq_db_worker/test/fixtures/sync/test-ca.pem"
    ; "logseq_db_worker/test/fixtures/sync/localhost.pem"
    ; "logseq_db_worker/test/fixtures/sync/localhost-key.pem"
    ];
  require_text
    root
    dune
    [ "(executable\n (name test_managed_sync_e2e)"
    ; "(rule\n (alias managed-sync-online-e2e)"
    ];
  forbid_text root dune [ "(test\n (name test_managed_sync_e2e)" ];
  forbid_text root "logseq_db_worker.opam" [ "\"piaf\""; "\"ptime\""; "\"x509\"" ]
;;

let () =
  if Array.length Sys.argv > 4
  then
    failwith
      "usage: source_boundary_test [REPOSITORY_ROOT [SYNC_INSTALL_MANIFEST \
       [OVERLAY_INSTALL_MANIFEST]]]";
  let root =
    if Array.length Sys.argv >= 2 then Sys.argv.(1) else repository_root (Sys.getcwd ())
  in
  if Array.length Sys.argv >= 3 then test_logseq_sync_install_manifest Sys.argv.(2);
  if Array.length Sys.argv = 4 then test_logseq_overlay_db_install_manifest Sys.argv.(3);
  test_exact_dependency_matching ();
  test_deployed_managed_sync_e2e_boundary root;
  test_public_api_only_test_boundaries root;
  test_logseq_sync_suite_boundary root;
  test_logseq_sync_package_boundary root;
  test_injected_logseq_sync_api_boundary root;
  test_standalone_sync_protocol_boundary root;
  test_bonsai_flutter_dune_closure_names root;
  test_worker_owned_overlay_orchestration root;
  test_final_overlay_data_plane_boundary root;
  test_startup_phase_ownership root;
  test_repository_local_runtime_tests root;
  test_sync_transport_is_websocket_only root;
  test_sync_error_card_is_temporary_and_error_only root;
  require_exact_dependency
    root
    "logseq_journal.opam.locked"
    ~package:"ocaml-ios64"
    ~version:"5.1.1";
  let current_bonsai_flutter_revision = "84e588d0698ad3543d9a93ee2f9cf3a1ba82d05b" in
  let obsolete_bonsai_flutter_revisions =
    [ "5101a51d980c53bf9aab1e9420321ea8a7d58f9b"
    ; "3d2a540d886839fb243ce78f4bcc38da13c600a9"
    ; "f4377637a33cdc450204734d033bbcbb861e06bb"
    ; "1755441c24d718206a3d61af0882c0727f810d46"
    ; "6f2562e09d74d347a50b90541abdb4900e1e23da"
    ; "9b345b90fea476391d19092675abd665655e586a"
    ; "a6bd9aa9906c0e49f0cc365e5ba33270e89655e6"
    ; "d5f8d36b5539550cbc2466311acda4d8c609032e"
    ; "a51276a09eb1cdf9c87f07ac4c7558ed7c6b2d69"
    ; "26f5bf6c3b4cdd61ccd5c1660f6cf9f72fe523da"
    ; "066179956545cc12871862879fc906f09519788c"
    ; "f6d27175632d26e759532f6ee81e8d1383490533"
    ; "2dc30ce5f112eb79f84bfd238d2dd48e43e218cf"
    ; "d182690aeaa82ad0a972756205c62e3b598e3c24"
    ; "5f8f540e4ccfd1e1807294aec8ac5f229161e2da"
    ; "fcde784654ee5b8557afc3c966d840f2b1331912"
    ; "de1196c2663b43388ebf04bd0612c5050edef753"
    ]
  in
  List.iter
    (fun (relative, occurrences) ->
       require_occurrences root relative current_bonsai_flutter_revision occurrences;
       forbid_text root relative obsolete_bonsai_flutter_revisions)
    [ "logseq_journal.opam", 2
    ; "logseq_journal.opam.locked", 2
    ; "logseq_db_worker.opam", 2
    ; "logseq_db_worker.opam.locked", 1
    ];
  let dependency_manifests =
    [ "logseq_db_storage.opam"
    ; "logseq_overlay_db.opam"
    ; "logseq_sync.opam"
    ; "logseq_journal.opam"
    ; "logseq_db_worker.opam"
    ; "logseq_db_storage.opam.locked"
    ; "logseq_overlay_db.opam.locked"
    ; "logseq_sync.opam.locked"
    ; "logseq_journal.opam.locked"
    ; "logseq_db_worker.opam.locked"
    ]
  in
  let current_datascript_revision = "40345cc2f59214daa88b33b8aec711337d20afa7" in
  List.iter
    (fun relative ->
       require_occurrences root relative current_datascript_revision 2;
       forbid_text
         root
         relative
         [ "b1029d6a7210baae15f56d7c5df383c150ca07cef90"
         ; "5895af25101de15f56d7c5df383c150ca07cef90"
         ])
    dependency_manifests;
  let current_melange_transit_revision = "35f8afe7d6506863c7253e67a20befb3dde5c18f" in
  List.iter
    (fun (relative, occurrences) ->
       require_occurrences root relative current_melange_transit_revision occurrences;
       forbid_text
         root
         relative
         [ "b298260eb67d96710cb26eaad96a40c81b1af21b"
         ; "a64270a1ed5c8ad3ff7e05dbb60e83ad0465ae93"
         ; "melange-transit-native.0.1.0"
         ; "melange-transit-core.0.1.0"
         ; "melange-transit-native.0.1.1"
         ; "melange-transit-core.0.1.1"
         ])
    [ "logseq_db_storage.opam", 2
    ; "logseq_overlay_db.opam", 2
    ; "logseq_sync.opam", 2
    ; "logseq_journal.opam", 2
    ; "logseq_db_worker.opam", 2
    ; "logseq_db_storage.opam.locked", 2
    ; "logseq_overlay_db.opam.locked", 2
    ; "logseq_sync.opam.locked", 2
    ; "logseq_journal.opam.locked", 2
    ; "logseq_db_worker.opam.locked", 2
    ];
  require_occurrences root "dune-project" "(melange-transit-native (= 0.1.2))" 5;
  require_occurrences root "dune-project" "(melange-transit-core (= 0.1.2))" 1;
  List.iter
    (fun relative ->
       require_exact_dependency
         root
         relative
         ~package:"melange-transit-native"
         ~version:"0.1.2")
    dependency_manifests;
  List.iter
    (fun relative ->
       require_exact_dependency
         root
         relative
         ~package:"melange-transit-core"
         ~version:"0.1.2")
    [ "logseq_journal.opam"
    ; "logseq_sync.opam.locked"
    ; "logseq_journal.opam.locked"
    ; "logseq_db_worker.opam.locked"
    ];
  List.iter
    (require_file root)
    [ "bonsai-flutter.sexp"
    ; "app/application.ml"
    ; "app/material_icon_catalog.ml"
    ; "app/material_icon_catalog.mli"
    ; "app/journal_calendar.ml"
    ; "app/journal_graph_projection.ml"
    ; "app/journal_graph_projection.mli"
    ; "app/journal_graph_request.ml"
    ; "app/journal_graph_runtime.ml"
    ; "app/journal_graph_runtime.mli"
    ; "app/journal_model.ml"
    ; "app/journal_model.mli"
    ; "app/journal_time.ml"
    ; "app/journal_time.mli"
    ; "app/journal_timeline_state.ml"
    ; "app/journal_timeline_state.mli"
    ; "logseq_sync/lib/effect_runner/storage/bootstrap.ml"
    ; "logseq_sync/lib/effect_runner/storage/bootstrap.mli"
    ; "logseq_sync/lib/effect_runner/protocol/catalog.ml"
    ; "logseq_sync/lib/effect_runner/protocol/catalog.mli"
    ; "logseq_sync/lib/effect_runner/eio/http.ml"
    ; "logseq_sync/lib/effect_runner/eio/http.mli"
    ; "flutter/lib/application_host_adapter.dart"
    ; "flutter/lib/main.dart"
    ; "flutter/test/application_host_adapter_test.dart"
    ; "flutter/test/widget_test.dart"
    ; "test/test_material_icons_artifact.sh"
    ; "tool/verify_material_icons_font.sh"
    ];
  require_text
    root
    "app/material_icon_catalog.mli"
    [ "type t ="
    ; "Account_circle"
    ; "Add"
    ; "Arrow_upward"
    ; "Chevron_left"
    ; "Chevron_right"
    ; "Circle"
    ; "Delete"
    ; "Expand_more"
    ; "Refresh"
    ; "val create"
    ];
  require_text root "app/material_icon_catalog.ml" [ "MaterialIcons"; "Ui.Widget.icon" ];
  require_text root "app/dune" [ "material_icon_catalog" ];
  List.iter
    (fun relative ->
       if
         not
           (String.equal relative "app/material_icon_catalog.ml"
            || String.equal relative "app/material_icon_catalog.mli")
       then forbid_text root relative [ "MaterialIcons"; "Ui.Widget.icon"; "0xe" ])
    (ocaml_product_files root);
  require_text
    root
    "app/application.ml"
    [ "Material_icon_catalog.Refresh"
    ; "Ui.Material.navigation_bar"
    ; "Ui.Native_widget.Expandable_message_composer.create_with_handler"
    ];
  require_text root "app/journal_header.ml" [ "Material_icon_catalog.Account_circle" ];
  require_text
    root
    "app/journal_header.ml"
    [ "Ui.Material.App_bar.sliver"
    ; "Ui.Material.Tooltip.plain"
    ; "~pinned:true"
    ; "~floating:false"
    ; "~snap:false"
    ; "~center_title:true"
    ; "~expanded_height:(toolbar_height +. 8.)"
    ; "~collapsed_height:(toolbar_height +. 8.)"
    ];
  forbid_text
    root
    "app/journal_header.ml"
    [ "Ui.Widget.safe_area"
    ; "Ui.Widget.Sliver.app_bar"
    ; "journal-header-flexible-space"
    ; "journal-header-divider"
    ; "journal-header-stack"
    ; "journal-header-surface"
    ; "journal-header-content-height"
    ];
  forbid_text
    root
    "app/application.ml"
    [ "Ui.Widget.button"; "Ui.Material.choice_chip"; "Ui.Material.list_tile" ];
  require_text
    root
    "app/application.ml"
    [ "Journal_header.sliver"
    ; "Ui.Material.Chip.filter"
    ; "Ui.Material.Dialog.alert"
    ; "Ui.Material.text_button"
    ; "Ui.Material.Tooltip.plain"
    ; "Ui.Widget.Scroll_view.vertical"
    ; "journal-scroll"
    ; "?floating_action_button:(if favorites_selected then None else Some capture)"
    ; "~floating_action_button_location:Ui.Material.End_float"
    ];
  forbid_text root "app/journal_header.ml" [ "~variant:Ui.Material.App_bar.Medium" ];
  forbid_text root "app/application.ml" [ "Journal_header.view" ];
  forbid_text root "app/journal_timeline.ml" [ "Ui.Widget.Scroll_view.vertical" ];
  require_text root "app/journal_timeline.ml" [ "Ui.Widget.Sliver.padding" ];
  require_text
    root
    "app/journal_row.ml"
    [ "Material_icon_catalog.Chevron_left"
    ; "Material_icon_catalog.Chevron_right"
    ; "Material_icon_catalog.Expand_more"
    ];
  require_text
    root
    "app/journal_timeline.ml"
    [ "Material_icon_catalog.Circle"
    ; "Material_icon_catalog.Delete"
    ; "Ui.Native_widget.Slidable.action"
    ; "Ui.Native_widget.Slidable.action_pane"
    ; "Ui.Native_widget.Slidable.create_with_handler"
    ; "Ui.Native_widget.Morphing_surface.create"
    ; "~drag_dismissible:false"
    ];
  forbid_text
    root
    "app/journal_timeline.ml"
    [ "Ui.Native_widget.Swipe_action"
    ; "Ui.Native_widget.Slidable.dismissible"
    ; "quick_status_actions"
    ; "extent_ratio:0.8"
    ];
  List.iter
    (forbid_path root)
    [ "flutter/lib/app"
    ; "flutter/lib/core"
    ; "flutter/lib/features"
    ; "flutter/test/app"
    ; "flutter/test/features"
    ; "flutter/test/support"
    ; "flutter/integration_test/app_runtime_flow_test.dart"
    ; "flutter/integration_test/attachment_flow_test.dart"
    ; "flutter/integration_test/capture_flow_test.dart"
    ; "app/journal_feed_state.ml"
    ; "app/journal_feed_state.mli"
    ; "test/feed_app_test.ml"
    ; "test/feed_state_test.ml"
    ; "test/schema_repository_test.ml"
    ; "app/journal_repository.ml"
    ; "app/journal_repository.mli"
    ; "app/journal_schema.ml"
    ; "app/journal_schema.mli"
    ; "app/journal_storage.ml"
    ; "app/journal_storage.mli"
    ; "app/journal_storage_path.ml"
    ; "app/journal_storage_path.mli"
    ; "app/journal_worker.ml"
    ; "app/journal_worker.mli"
    ; "app/journal_process_recovery.ml"
    ; "app/journal_process_recovery.mli"
    ; "flutter/lib/journal_account_shell.dart"
    ; "flutter/lib/journal_e2ee.dart"
    ; "flutter/lib/journal_snapshot_progress.dart"
    ; "flutter/lib/journal_sync_transport.dart"
    ];
  require_allowed_dart_files
    root
    "flutter/lib"
    [ "flutter/lib/application_host_adapter.dart"
    ; "flutter/lib/journal_platform_menu.dart"
    ; "flutter/lib/journal_tail_fade.dart"
    ; "flutter/lib/journal_date_row.dart"
    ; "flutter/lib/journal_root_navigation.dart"
    ; "flutter/lib/journal_widget_registry.dart"
    ; "flutter/lib/main.dart"
    ];
  require_allowed_dart_files
    root
    "flutter/test"
    [ "flutter/test/application_host_adapter_test.dart"
    ; "flutter/test/macos_edit_menu_test.dart"
    ; "flutter/test/journal_tail_fade_test.dart"
    ; "flutter/test/journal_root_navigation_test.dart"
    ; "flutter/test/logseq_db_worker_host_adapter_test.dart"
    ; "flutter/test/journal_runtime_golden_test.dart"
    ; "flutter/test/journal_header_layout_test.dart"
    ; "flutter/test/widget_test.dart"
    ];
  require_allowed_dart_files
    root
    "flutter/integration_test"
    [ "flutter/integration_test/encrypted_offline_warm_start_test.dart" ];
  require_file root "flutter/integration_test/encrypted_offline_warm_start_test.dart";
  require_text
    root
    "logseq_db_worker/tool/test_macos_runtime_flow.sh"
    [ "encrypted-offline-warm-start"
    ; "integration_test/encrypted_offline_warm_start_test.dart"
    ; "LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE=memory"
    ; "LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE=memory"
    ];
  forbid_text
    root
    "logseq_db_worker/tool/test_macos_runtime_flow.sh"
    [ "logseq_db_worker_runtime_flow_test.dart" ];
  require_occurrences root "app/application.ml" "Ui.Style.Color.rgb" 1;
  require_occurrences root "app/journal_visual_tokens.ml" "Ui.Style.Color.rgb" 1;
  forbid_text root "app/application.ml" [ "let color"; "(color " ];
  List.iter
    (fun relative ->
       if
         not
           (String.equal relative "app/application.ml"
            || String.equal relative "app/journal_visual_tokens.ml")
       then forbid_text root relative [ "Ui.Style.Color.rgb"; "Ui.Style.Color.argb" ])
    (ocaml_product_files root);
  require_text
    root
    "app/journal_visual_tokens.ml"
    [ "module Color_exceptions = struct"
    ; "type presentation"
    ; "let status_rail_color"
    ; "let destructive_swipe_action"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "type palette"
         ; "type interaction"
         ; "neutral_badge"
         ; "sheet_surface"
         ; "sheet_outline"
         ; "modal_scrim"
         ; "sheet_primary_action"
         ; "sheet_secondary_action"
         ; "sheet_error"
         ; "Tokens.palette"
         ; "Tokens.interaction"
         ; "Journal_visual_tokens.palette"
         ; "Journal_visual_tokens.interaction"
         ])
    (ocaml_product_files root);
  require_text
    root
    "app/application.ml"
    [ "Ui.Theme.System"
    ; "~high_contrast_dark"
    ; "Ui.Material.text_button"
    ; "Ui.Native_widget.Expandable_message_composer.create_with_handler"
    ; "?floating_action_button:(if favorites_selected then None else Some capture)"
    ];
  require_text root "app/journal_timeline.ml" [ "Ui.Material.divider" ];
  forbid_text root "app/journal_header.ml" [ "Ui.Material.divider" ];
  forbid_text
    root
    "app/journal_timeline.ml"
    [ "let group_separator"
    ; "journal-group-divider"
    ; "Timeline.Bottom_clearance"
    ; "journal-bottom-clearance"
    ];
  List.iter
    (fun relative -> forbid_text root relative [ "Bottom_clearance"; "safe_bottom" ])
    [ "app/journal_timeline_state.ml"
    ; "app/journal_timeline_state.mli"
    ; "app/journal_timeline.ml"
    ; "app/journal_timeline.mli"
    ; "app/journal_visual_tokens.ml"
    ; "app/journal_visual_tokens.mli"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "bottom_inset"; "minimum_height"; "expanded_vertical_overhead" ])
    [ "app/journal_visual_tokens.ml"; "app/journal_visual_tokens.mli" ];
  forbid_text
    root
    "app/application.ml"
    [ "Ui.Theme.Light"
    ; "~barrier_color"
    ; "~bottom_sheet"
    ; "Ui.Native_widget.Message_composer.create_with_handler"
    ; "journal-capture-composer-safe-area"
    ];
  forbid_text root "flutter/ios/Runner/Info.plist" [ "UIUserInterfaceStyle" ];
  let forbidden_dart_text =
    [ "package:logseq_journal/app/"
    ; "package:logseq_journal/core/"
    ; "package:logseq_journal/features/"
    ; "import 'app/"
    ; "package:file_selector/"
    ; "package:path_provider/"
    ; "package:sqlite3/"
    ; "JournalTimelineController"
    ; "JournalTimelinePage"
    ; "MaterialIconRetention"
    ; "JournalApp("
    ; "runApp(const JournalApp"
    ; "JournalDatabase"
    ; "JournalRepository"
    ; "JournalEntry"
    ; "SliverList"
    ; "TextSpan"
    ; "WidgetSpan"
    ; "Image.file"
    ; "package:sqflite/"
    ; "package:drift/"
    ; "showModalBottomSheet"
    ; "JournalCapture"
    ; "CaptureController"
    ; "TextEditingController"
    ]
  in
  dart_files root "flutter/lib"
  @ dart_files root "flutter/test"
  @ dart_files root "flutter/integration_test"
  |> List.iter (fun relative -> forbid_text root relative forbidden_dart_text);
  require_text
    root
    "flutter/lib/journal_root_navigation.dart"
    [ "PrimaryScrollController(" ];
  dart_files root "flutter/lib"
  |> List.iter (fun relative -> forbid_text root relative [ "CustomScrollView" ]);
  forbid_text
    root
    "flutter/pubspec.yaml"
    [ "name: logseq_journal\n"
    ; "\n  crypto:"
    ; "\n  file_selector:"
    ; "\n  flutter_localizations:"
    ; "\n  image:"
    ; "\n  path:"
    ; "\n  path_provider:"
    ; "\n  sqlite3:"
    ];
  require_text
    root
    "flutter/pubspec.yaml"
    [ "dev_dependencies:\n"; "  integration_test:\n    sdk: flutter\n" ];
  forbid_text
    root
    "flutter/macos/Flutter/GeneratedPluginRegistrant.swift"
    [ "file_selector"; "FileSelectorPlugin"; "PathProviderPlugin" ];
  List.iter
    (fun relative ->
       forbid_text root relative [ "com.apple.security.files.user-selected" ])
    [ "flutter/macos/Runner/DebugProfile.entitlements"
    ; "flutter/macos/Runner/Release.entitlements"
    ];
  let obsolete_product_symbols =
    [ "Search_route"
    ; "pending_search"
    ; "Search_boundary"
    ; "Load_preview"
    ; "load_preview"
    ; "Preview_loaded"
    ; "preview_state"
    ; "search_page"
    ; "search_cursor"
    ; "attachment_path"
    ; "Attachment_loaded"
    ; "token_parser"
    ; "Token_index"
    ; "Picker_result"
    ; "Journal_worker.Search"
    ; "SearchPage"
    ; "SearchController"
    ; "journal_search"
    ; "GraphDocumentBroker"
    ; "journal.sqlite3"
    ; "Date_selection"
    ; "Date_view"
    ; "open_date"
    ; "cancel_date"
    ; "date_page"
    ; "journal-date-selection"
    ; "journal-date-dialog"
    ; "open-date"
    ; "date-cancel"
    ; "menu-unconfirmed"
    ; "more-unconfirmed"
    ; "fab_horizontal_inset"
    ; "journal-capture-alignment"
    ; "Children_continuation"
    ; "apply_block_page"
    ; "divider_inset"
    ; "shadow_size"
    ; "shadow_alpha"
    ; "journal-row-child-count"
    ]
  in
  let deferred_capability_symbols =
    [ "Inline_flow"
    ; "Measured_extent_list"
    ; "Local_image"
    ; "pick_file"
    ; "pick_media"
    ; "expanded_semantics"
    ]
  in
  ocaml_product_files root
  |> List.iter (fun relative ->
    forbid_text root relative obsolete_product_symbols;
    forbid_text root relative deferred_capability_symbols);
  forbid_text root "app/application.ml" [ "timeline-open:"; "timeline-disclosure:" ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "Sync_receive"
         ; "websocket_open_request"
         ; "websocket_send_request"
         ; "decode_sync_event"
         ])
    [ "app/application.ml"
    ; "app/journal_graph_request.ml"
    ; "app/journal_graph_request.mli"
    ; "app/journal_platform.ml"
    ; "app/journal_platform.mli"
    ];
  forbid_text root "app/journal_row.ml" [ "Tokens.row_geometry.corner_radius" ];
  forbid_text
    root
    "app/application.ml"
    [ "let capture_page"
    ; "journal-capture-route"
    ; "journal-capture-sheet"
    ; "capture-discard-dialog-page"
    ; "Open full Capture editor"
    ; "Continue Capture"
    ; "capture_launch"
    ; "Journal_routes.open_capture"
    ; "Journal_routes.capture"
    ; "Journal_routes.update_capture"
    ; "capture-cancel"
    ; "Cancel journal entry"
    ; "New entry"
    ; "Ui.Navigation.Standard Ui.Navigation.None"
    ];
  forbid_text root "app/journal_capture.ml" [ "request_cancel" ];
  forbid_text
    root
    "app/journal_routes.ml"
    [ "Capture_view"; "open_capture"; "update_capture" ];
  require_text
    root
    "app/application.ml"
    [ "Ui.Navigation.Modal_bottom_sheet.create"
    ; "Ui.Navigation.Modal_bottom_sheet.Handle_semantics.create"
    ; "Ui.Navigation.Modal_bottom_sheet.Detents.create"
    ; "Ui.Navigation.Modal_bottom_sheet.Sizing.Detented"
    ; "journal-status-sheet-page:"
    ; "journal-status-sheet-option:"
    ; "Set status"
    ];
  forbid_text
    root
    "app/application.ml"
    [ "Ui.Navigation.Modal_bottom_sheet.Sizing.Content_bounded"
    ; "Ui.Navigation.Modal_bottom_sheet.Sizing.Scroll_controlled"
    ; "~keyboard_inset_bottom:environment.keyboard_insets.bottom"
    ; "~border_radius:geometry.top_corner_radius"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "capture_sheet_detents"
         ; "capture_sheet_geometry"
         ; "resolve_capture_sheet_geometry"
         ; "keyboard_inset_bottom"
         ; "top_corner_radius"
         ])
    [ "app/journal_visual_tokens.ml"; "app/journal_visual_tokens.mli" ];
  require_text
    root
    "app/application.ml"
    [ "timeline-toggle-children:"
    ; "Journal_model.child_count block > 0"
    ; "~obscure_text:true"
    ; "Graph_service.Submit_e2ee_password"
    ; "request-local-cache-reset"
    ; "cancel-local-cache-reset"
    ; "confirm-local-cache-reset"
    ; "Graph_service.Delete_local_cache"
    ; "Graph_service.Return_to_graph_picker"
    ; "journal-account-menu"
    ; "journal-account-switch-graph"
    ; "journal-account-sign-out"
    ; "Ui.Widget.Scroll_view.vertical"
    ; "graph-picker-scroll"
    ; "graph-picker-toolbar"
    ; "graph-picker-refresh-icon"
    ; "Refresh the authorized graph catalog"
    ; "pending local changes"
    ; "then returns to graph selection"
    ; "App.View.create"
    ; "Ui.Theme.application"
    ; "Ui.Material.Dialog.alert"
    ; "Ui.Navigation.Modal_dialog"
    ; "Bonsai_flutter.Host_effect.show_snack_bar"
    ; "Ui.Material.filled_button"
    ; "Ui.Material.filled_tonal_button"
    ; "Ui.Material.outlined_button"
    ; "Ui.Material.text_button"
    ; "journal-account-dialog-page"
    ; "local-cache-reset-dialog-page"
    ; "detail-discard-dialog-page"
    ];
  forbid_text
    root
    "app/application.ml"
    [ "Ui.Material.dialog"
    ; "let page_body"
    ; "timeline_notice_view"
    ; "journal-delete-snackbar"
    ; "journal-delete-snackbar-position"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "snackbar_surface"; "snackbar_primary_text"; "snackbar_action_text" ])
    [ "app/journal_visual_tokens.ml"; "app/journal_visual_tokens.mli" ];
  require_text
    root
    "app/journal_platform.ml"
    [ "sign_out_request"; "is_prepare_to_terminate_event"; "termination_ready_request" ];
  require_text
    root
    "flutter/lib/application_host_adapter.dart"
    [ "Amplify.Auth.signOut()"
    ; "https://api.logseq.io"
    ; "prepareToTerminate"
    ; "prepareToTerminateEvent"
    ; "terminationReadyRequest"
    ; "SlidableAutoCloseBehavior"
    ];
  forbid_text
    root
    "flutter/lib/application_host_adapter.dart"
    [ "String.fromEnvironment('LOGSEQ_SYNC_BASE_URL')" ];
  require_text root "bonsai-flutter.sexp" [ "(mode custom)"; "(main lib/main.dart)" ];
  forbid_text root "bonsai-flutter.sexp" [ "(mode managed_adapter)" ];
  require_file root "flutter/lib/main.dart";
  require_text
    root
    "flutter/lib/main.dart"
    [ "JournalAmplify.configure()"
    ; "amplifyReady: amplifyReady"
    ; "runApp"
    ; "Unable to configure authentication"
    ; "Retry"
    ];
  require_occurrences root "flutter/lib/main.dart" "MaterialApp(" 1;
  forbid_path root "flutter/lib/application.dart";
  List.iter
    (fun relative -> forbid_text root relative [ "FLUTTER_TARGET" ])
    [ "flutter/macos/Flutter/Flutter-Debug.xcconfig"
    ; "flutter/macos/Flutter/Flutter-Release.xcconfig"
    ; "flutter/ios/Flutter/Debug.xcconfig"
    ; "flutter/ios/Flutter/Release.xcconfig"
    ];
  require_text
    root
    "flutter/macos/Runner/AppDelegate.swift"
    [ "applicationShouldTerminate"
    ; ".terminateLater"
    ; "reply(toApplicationShouldTerminate:"
    ; "Darwin.exit(EXIT_SUCCESS)"
    ];
  require_text
    root
    "logseq_sync/lib/effect_runner/eio/http_eio.ml"
    [ "Httpun_eio.Client.create_connection"; "Httpun_eio.Client.request" ];
  forbid_text
    root
    "logseq_sync/lib/effect_runner/eio/http_eio.ml"
    [ "let start_connection"; "HTTP parser did not consume network input" ];
  require_text root "logseq_sync/lib/effect_runner/dune" [ "httpun-eio" ];
  List.iter
    (require_file root)
    [ "logseq_sync/lib/effect_runner/eio/tls_client_eio.ml"
    ; "logseq_sync/lib/effect_runner/eio/tls_client_eio.mli"
    ];
  require_occurrences root "logseq_sync/lib/effect_runner/dune" "tls_client_eio" 2;
  require_text
    root
    "logseq_sync/lib/effect_runner/eio/tls_client_eio.ml"
    [ "Mirage_crypto_rng_unix.use_default"
    ; "Domain_name.of_string"
    ; "Domain_name.host"
    ; "Tls.Config.client"
    ; "~alpn_protocols:[ \"http/1.1\" ]"
    ; "Eio.Net.connect"
    ; "Tls_eio.client_of_flow"
    ; "Eio.Cancel.Cancelled"
    ];
  List.iter
    (fun relative ->
       require_text
         root
         relative
         [ "Tls_client_eio.initialize_rng ()"; "Tls_client_eio.connect" ];
       forbid_text
         root
         relative
         [ "Mirage_crypto_rng_unix.use_default"
         ; "Domain_name.of_string"
         ; "Domain_name.host"
         ; "Tls.Config.client"
         ; "Eio.Net.getaddrinfo_stream"
         ; "Eio.Net.connect"
         ; "Tls_eio.client_of_flow"
         ])
    [ "logseq_sync/lib/effect_runner/eio/http_eio.ml"
    ; "logseq_sync/lib/effect_runner/eio/websocket_eio.ml"
    ];
  require_text
    root
    "logseq_db_worker/contract/error.ml"
    [ "Ownership_recovery"; "ownershipRecovery" ];
  forbid_text root "app/application.ml" [ "timeline-task:" ];
  require_text
    root
    "app/journal_graph_projection.mli"
    [ "type child_summary"
    ; "type timeline_entry"
    ; "type timeline_entry_page"
    ; "expected_revision : string"
    ; "expected_parent_revision : string"
    ; "revision:string"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "expected_revision : int"
         ; "expected_parent_revision : int"
         ; "minimum_basis"
         ; "mutable basis"
         ; "basis : int64 option"
         ])
    [ "app/journal_graph_projection.mli"
    ; "app/journal_graph_projection.ml"
    ; "app/journal_graph_runtime.mli"
    ; "app/journal_graph_runtime.ml"
    ; "app/application.ml"
    ];
  require_text
    root
    "app/journal_timeline_state.mli"
    [ "Top_level"; "Child_preview"; "Children_loading"; "Children_more"; "epoch : int64" ];
  require_text
    root
    "app/journal_visual_tokens.mli"
    [ "type fixed_extent_role"
    ; "val block_extent"
    ; "val fixed_extent"
    ; "type preview_geometry"
    ];
  forbid_text
    root
    "logseq_db_storage/lib/storage_session.ml"
    [ "db |> Datascript.serializable |> Datascript.from_serializable"
    ; "Datascript.from_serializable"
    ];
  files_with_suffixes root "logseq_db_worker" [ ".ml"; ".mli" ]
  @ files_with_suffixes root "logseq_db_storage" [ ".ml"; ".mli" ]
  |> List.iter (fun relative ->
    forbid_text root relative [ "Datascript.from_serializable" ]);
  List.iter
    (forbid_path root)
    [ "logseq_sync/lib/core/action.ml"
    ; "logseq_sync/lib/core/auth.ml"
    ; "logseq_sync/lib/core/e2ee_session.ml"
    ; "logseq_sync/lib/core/manager.ml"
    ; "logseq_sync/lib/core/network_scope.ml"
    ; "logseq_sync/lib/core/protocol.ml"
    ; "logseq_sync/lib/core/startup_phase.ml"
    ; "logseq_sync/lib/core/state.ml"
    ; "logseq_sync/lib/core/websocket.ml"
    ; "logseq_sync/lib/storage/pending.ml"
    ; "logseq_sync/lib/storage/replay.ml"
    ; "logseq_sync/lib/storage/tx.ml"
    ];
  forbid_text
    root
    "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml"
    [ "interpret_local_action"; "interpret_network_action"; "Local_completion" ];
  require_text
    root
    "logseq_sync/lib/pure_reducer/core.ml"
    [ "type diagnostics"; "type state ="; "let state core = core.public_state" ];
  require_text
    root
    "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.mli"
    [ "Client_command_completed"; "Client_state_changed of state" ];
  forbid_text
    root
    "logseq_sync/spec/action.mli"
    [ "Logseq_sync_core"; "Logseq_sync_storage"; "Logseq_sync_eio" ];
  forbid_text
    root
    "app/application.ml"
    [ "phase=%d"
    ; "Sync_diagnostics"
    ; "sync_diagnostics"
    ; "sync-diagnostics"
    ; "Sync diagnostics"
    ; "journal-diagnostics-copy"
    ; "journal-diagnostics-export"
    ];
  forbid_text root "app/application.mli" [ "sync_diagnostic"; "Sync_diagnostic" ];
  List.iter
    (require_file root)
    [ "logseq_db_worker/spec/pure_reducer/core.mli"
    ; "logseq_db_worker/spec/pure_reducer/dune"
    ; "logseq_db_worker/spec/effect_runner/effect_runner.mli"
    ; "logseq_db_worker/spec/effect_runner/dune"
    ; "logseq_db_worker/lib/pure_reducer/core.ml"
    ; "logseq_db_worker/lib/pure_reducer/dune"
    ; "logseq_db_worker/lib/effect_runner/effect_runner.ml"
    ; "logseq_db_worker/lib/effect_runner/dune"
    ];
  List.iter
    (forbid_path root)
    [ "logseq_db_worker/spec/pure_reducer/core.ml"
    ; "logseq_db_worker/spec/effect_runner/effect_runner.ml"
    ];
  require_text
    root
    "logseq_db_worker/spec/pure_reducer/dune"
    [ "(public_name logseq_db_worker.pure_reducer)"
    ; "(virtual_modules core)"
    ; "(default_implementation logseq_db_worker_pure_reducer_impl)"
    ];
  require_text
    root
    "logseq_db_worker/spec/effect_runner/dune"
    [ "(public_name logseq_db_worker.effect_runner)"
    ; "(virtual_modules effect_runner)"
    ; "(default_implementation logseq_db_worker_effect_runner_impl)"
    ];
  forbid_text
    root
    "logseq_db_worker/lib/pure_reducer/core.ml"
    [ "Eio."; "Unix."; "Sqlite3."; "Engine."; "Hashtbl"; "mutable"; "Effect.perform" ];
  forbid_text
    root
    "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml"
    [ "module Managed_coordinator"
    ; "Graph_bound"
    ; "Engine.open_"
    ; "Engine.execute"
    ; "Engine.close"
    ; "Core.step"
    ; "pending_mutations"
    ; "Graph_lifecycle"
    ];
  forbid_text
    root
    "logseq_db_worker/lib/logseq_db_worker.ml"
    [ "Engine."
    ; "Synced_mirror."
    ; "module Synced_mirror"
    ; "Worker.Session_context"
    ; "Logseq_sync_effect_runner"
    ];
  List.iter
    (forbid_path root)
    [ "logseq_db_worker/lib/snapshot.ml"
    ; "logseq_db_worker/lib/snapshot.mli"
    ; "logseq_db_worker/lib/backup.ml"
    ; "logseq_db_worker/lib/backup.mli"
    ; "logseq_db_worker/lib/graph_locator.ml"
    ; "logseq_db_worker/lib/graph_locator.mli"
    ; "logseq_db_worker/lib/derived_sidecars.ml"
    ; "logseq_db_worker/lib/derived_sidecars.mli"
    ; "logseq_db_worker/cli"
    ; "logseq_db_worker/test/test_cli.ml"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "Snapshot" ^ " of"
         ; "Import_" ^ "snapshot"
         ; "Synced_mirror" ^ " of"
         ; "Native_local_" ^ "graph"
         ; "import" ^ "Snapshot"
         ; "nativeLocal" ^ "Graph"
         ; "synced" ^ "Mirror"
         ])
    [ "logseq_db_worker/contract/config.mli"
    ; "logseq_db_worker/contract/config.ml"
    ; "logseq_db_worker/spec/pure_reducer/core.mli"
    ; "logseq_db_worker/lib/pure_reducer/core.ml"
    ];
  require_text
    root
    "app/application.ml"
    [ "open-diagnostics"
    ; "close-diagnostics"
    ; "journal-account-diagnostics"
    ; "journal-startup-diagnostics"
    ; "journal-diagnostics-dialog-page"
    ; "Overlay DB"
    ; "Outbox records"
    ; "Protected payload"
    ; "Origin evidence"
    ];
  List.iter
    (fun relative ->
       forbid_text root relative [ "history : string list"; "append_diagnostic_history" ])
    [ "logseq_sync/spec/pure_reducer/core.mli"
    ; "logseq_sync/lib/pure_reducer/core.ml"
    ; "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.mli"
    ; "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml"
    ];
  forbid_text root "app/application.ml" [ "Recent sync transitions" ];
  require_text
    root
    "logseq_db_worker/lib/effect_runner/effect_runner.ml"
    [ "Database.inspect_admission"; "V2_admission_outcome" ];
  forbid_text root "app/application.ml" [ "Database.inspect_admission" ];
  require_text
    root
    "logseq_db_worker/contract/error.mli"
    [ "type cause"
    ; "type causal_trace"
    ; "val trace"
    ; "val wrap"
    ; "val create_with_origin"
    ];
  require_text
    root
    "app/application.ml"
    [ "type worker_error_occurrence"
    ; "worker_errors : worker_error_occurrence list"
    ; "journal-error-info-page"
    ; "newest_first_worker_errors"
    ];
  require_text
    root
    "app/journal_header.ml"
    [ "journal-error-info-button"; "Review Logseq DB worker errors" ];
  forbid_text
    root
    "app/journal_graph_runtime.mli"
    [ "Feed_failed of\n      { request_generation : int64\n      ; message : string"
    ; "Open_failed of Logseq_db_worker.Error.t"
    ; "Rejected of string"
    ];
  forbid_text
    root
    "app/application.ml"
    [ "| Open_failed error -> terminal_graph_state state (Logseq_db_worker.Error.message \
       error)"
    ; "graph_error : string option"
    ; "capture_error : string option"
    ; "sync_error : string option"
    ];
  List.iter
    (forbid_path root)
    [ "logseq_db_worker/test/adapter_fixture.ml"
    ; "logseq_db_worker/test/structural_fixture.ml"
    ; "logseq_db_worker/test/test_fixture_generator.ml"
    ; "logseq_db_worker/tool/fixture_generator.ml"
    ; "logseq_db_worker/tool/generate_fixtures.ml"
    ; "logseq_db_worker/tool/mutation_identity_benchmark.ml"
    ; "test/journal_runtime_golden_fixture.ml"
    ; "test/managed_application_fixture.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_01_unowned_snapshot_progress.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_02_duplicate_mirror_inspection.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_03_duplicate_graph_attachment.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_04_duplicate_websocket_open.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_05_message_after_websocket_close.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_06_unsolicited_authoritative_apply.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_07_restore_accepts_old_catalog.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_08_reused_graph_token_challenge.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_09_unsolicited_local_commit.ml"
    ; "logseq_sync/test/test_pure_reducer_bad_case_10_mismatched_outbox_commit.ml"
    ];
  List.iter
    (require_file root)
    [ "test/application_view_test.ml"
    ; "test/logseq_db_worker_application_integration_test.ml"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "get_calendar_request"
         ; "decode_calendar"
         ; "format_journal_days_request"
         ; "decode_formatted_journal_days"
         ; "time_zone_id"
         ; "utc_offset_seconds"
         ; "lifecycle_generation"
         ])
    [ "app/journal_platform.ml"
    ; "app/journal_platform.mli"
    ; "app/journal_calendar.ml"
    ; "app/journal_calendar.mli"
    ; "app/journal_time.ml"
    ; "app/journal_time.mli"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "JournalCalendarSnapshot"
         ; "CalendarChangeReason"
         ; "formatJournalDays"
         ; "calendarChanged"
         ; "timeZoneId"
         ; "utcOffsetSeconds"
         ])
    [ "flutter/lib/application_host_adapter.dart"
    ; "flutter/macos/Runner/MainFlutterWindow.swift"
    ; "flutter/ios/Runner/AppDelegate.swift"
    ];
  require_text
    root
    "app/application.ml"
    [ "Journal_calendar.Sampler.sample"; "Journal_calendar.present_journal_day" ];
  match List.rev !failures with
  | [] -> print_endline "source boundary is clean"
  | failures ->
    List.iter prerr_endline failures;
    exit 1
;;
