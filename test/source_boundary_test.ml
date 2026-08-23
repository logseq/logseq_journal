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

let has_exact_dependency contents ~package ~version =
  contains contents (Printf.sprintf "\"%s\" {= \"%s\"}" package version)
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

let () =
  if Array.length Sys.argv > 2
  then failwith "usage: source_boundary_test [REPOSITORY_ROOT]";
  let root =
    if Array.length Sys.argv = 2 then Sys.argv.(1) else repository_root (Sys.getcwd ())
  in
  test_exact_dependency_matching ();
  require_exact_dependency
    root
    "logseq_journal.opam.locked"
    ~package:"ocaml-ios64"
    ~version:"5.1.1";
  let current_bonsai_flutter_revision = "a6bd9aa9906c0e49f0cc365e5ba33270e89655e6" in
  let obsolete_bonsai_flutter_revisions =
    [ "d5f8d36b5539550cbc2466311acda4d8c609032e"
    ; "a51276a09eb1cdf9c87f07ac4c7558ed7c6b2d69"
    ; "26f5bf6c3b4cdd61ccd5c1660f6cf9f72fe523da"
    ; "066179956545cc12871862879fc906f09519788c"
    ; "f6d27175632d26e759532f6ee81e8d1383490533"
    ; "2dc30ce5f112eb79f84bfd238d2dd48e43e218cf"
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
  List.iter
    (require_file root)
    [ "bonsai-flutter.sexp"
    ; "app/application.ml"
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
    ; "logseq_db_worker/lib/sync_auth.ml"
    ; "logseq_db_worker/lib/sync_auth.mli"
    ; "logseq_db_worker/lib/sync_bootstrap.ml"
    ; "logseq_db_worker/lib/sync_bootstrap.mli"
    ; "logseq_db_worker/lib/sync_catalog.ml"
    ; "logseq_db_worker/lib/sync_catalog.mli"
    ; "logseq_db_worker/lib/sync_http.ml"
    ; "logseq_db_worker/lib/sync_http.mli"
    ; "logseq_db_worker/lib/sync_e2ee_session.ml"
    ; "logseq_db_worker/lib/sync_e2ee_session.mli"
    ; "logseq_db_worker/lib/sync_manager.ml"
    ; "logseq_db_worker/lib/sync_manager.mli"
    ; "logseq_db_worker/lib/sync_websocket.ml"
    ; "logseq_db_worker/lib/sync_websocket.mli"
    ; "flutter/lib/application_host_adapter.dart"
    ; "flutter/lib/main.dart"
    ; "flutter/test/application_host_adapter_test.dart"
    ; "flutter/test/widget_test.dart"
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
    [ "flutter/lib/application.dart"
    ; "flutter/lib/application_host_adapter.dart"
    ; "flutter/lib/main.dart"
    ];
  require_allowed_dart_files
    root
    "flutter/test"
    [ "flutter/test/application_host_adapter_test.dart"
    ; "flutter/test/logseq_db_worker_host_adapter_test.dart"
    ; "flutter/test/journal_runtime_golden_test.dart"
    ; "flutter/test/widget_test.dart"
    ];
  require_allowed_dart_files
    root
    "flutter/integration_test"
    [ "flutter/integration_test/journal_runtime_flow_test.dart"
    ; "flutter/integration_test/logseq_db_worker_ios_device_test.dart"
    ; "flutter/integration_test/logseq_db_worker_runtime_flow_test.dart"
    ; "flutter/integration_test/runtime_flow_fixture.dart"
    ];
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
    ; "CustomScrollView"
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
    ; "capture-cancel"
    ; "Cancel journal entry"
    ; "New entry"
    ; "Ui.Navigation.Standard Ui.Navigation.None"
    ];
  forbid_text root "app/journal_capture.ml" [ "request_cancel" ];
  forbid_text
    root
    "app/application.ml"
    [ "Ui.Navigation.Modal_bottom_sheet.Handle_semantics"
    ; "Ui.Navigation.Modal_bottom_sheet.Detents"
    ; "Ui.Navigation.Modal_bottom_sheet.Sizing.Detented"
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
    ; "Ui.Navigation.Modal_bottom_sheet"
    ; "Ui.Navigation.Modal_bottom_sheet.Sizing.Scroll_controlled"
    ; "journal-capture-sheet"
    ; "Journal_capture.can_pop"
    ; "~obscure_text:true"
    ; "Sync_manager.Submit_e2ee_password"
    ; "request-local-cache-reset"
    ; "cancel-local-cache-reset"
    ; "confirm-local-cache-reset"
    ; "Sync_manager.Delete_local_cache"
    ; "Sync_manager.Return_to_graph_picker"
    ; "journal-account-menu"
    ; "journal-account-switch-graph"
    ; "journal-account-sign-out"
    ; "Ui.Widget.Scroll_view.vertical"
    ; "graph-picker-scroll"
    ; "graph-picker-toolbar"
    ; "graph-picker-refresh-icon"
    ; "Refresh the authorized graph catalog"
    ; "pending local changes"
    ; "download a fresh snapshot"
    ];
  require_text
    root
    "app/journal_platform.ml"
    [ "sign_out_request"
    ; "is_prepare_to_terminate_event"
    ; "termination_ready_request"
    ];
  require_text
    root
    "flutter/lib/application_host_adapter.dart"
    [ "Amplify.Auth.signOut()"
    ; "https://api.logseq.io"
    ; "prepareToTerminate"
    ; "prepareToTerminateEvent"
    ; "terminationReadyRequest"
    ];
  forbid_text
    root
    "flutter/lib/application_host_adapter.dart"
    [ "String.fromEnvironment('LOGSEQ_SYNC_BASE_URL')" ];
  require_file root "flutter/lib/application.dart";
  require_text
    root
    "flutter/lib/application.dart"
    [ "await JournalAmplify.configure()"
    ; "runApp"
    ; "Unable to configure authentication"
    ; "Retry"
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
    "logseq_db_worker/lib/sync_http_eio.ml"
    [ "Httpun_eio.Client.create_connection"; "Httpun_eio.Client.request" ];
  forbid_text
    root
    "logseq_db_worker/lib/sync_http_eio.ml"
    [ "let start_connection"; "HTTP parser did not consume network input" ];
  require_text root "logseq_db_worker/lib/dune" [ "httpun-eio" ];
  require_text
    root
    "logseq_db_worker/lib/error.ml"
    [ "Ownership_recovery"; "ownershipRecovery" ];
  require_text
    root
    "logseq_db_worker/lib/engine.ml"
    [ "Ownership recovery could not be verified" ];
  forbid_text root "app/application.ml" [ "timeline-task:" ];
  require_text
    root
    "app/journal_graph_projection.mli"
    [ "type child_summary"; "type timeline_entry"; "type timeline_entry_page" ];
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
    "logseq_db_worker/lib/engine.ml"
    [ "Datascript.serializable"
    ; "validate_storage_header connection"
    ; "let structurally_valid schema db"
    ];
  require_occurrences root "logseq_db_worker/lib/engine.ml" "tree_structurally_valid" 2;
  forbid_text
    root
    "logseq_db_worker/lib/storage_session.ml"
    [ "db |> Datascript.serializable |> Datascript.from_serializable"
    ; "Datascript.from_serializable"
    ];
  files_with_suffixes root "logseq_db_worker" [ ".ml"; ".mli" ]
  |> List.iter (fun relative ->
    forbid_text root relative [ "Datascript.from_serializable" ]);
  match List.rev !failures with
  | [] -> print_endline "source boundary is clean"
  | failures ->
    List.iter prerr_endline failures;
    exit 1
;;
