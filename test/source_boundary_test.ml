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
  let current_bonsai_flutter_revision = "a51276a09eb1cdf9c87f07ac4c7558ed7c6b2d69" in
  let obsolete_bonsai_flutter_revisions =
    [ "26f5bf6c3b4cdd61ccd5c1660f6cf9f72fe523da"
    ; "066179956545cc12871862879fc906f09519788c"
    ]
  in
  List.iter
    (fun relative ->
       require_occurrences root relative current_bonsai_flutter_revision 2;
       forbid_text root relative obsolete_bonsai_flutter_revisions)
    [ "logseq_journal.opam"; "logseq_journal.opam.locked" ];
  List.iter
    (require_file root)
    [ "bonsai-flutter.sexp"
    ; "app/application.ml"
    ; "app/journal_repository.ml"
    ; "app/journal_schema.ml"
    ; "app/journal_model.ml"
    ; "app/journal_model.mli"
    ; "app/journal_time.ml"
    ; "app/journal_time.mli"
    ; "app/journal_timeline_state.ml"
    ; "app/journal_timeline_state.mli"
    ; "app/journal_worker.ml"
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
    ];
  require_allowed_dart_files
    root
    "flutter/lib"
    [ "flutter/lib/application_host_adapter.dart"; "flutter/lib/main.dart" ];
  require_allowed_dart_files
    root
    "flutter/test"
    [ "flutter/test/application_host_adapter_test.dart"
    ; "flutter/test/journal_runtime_golden_test.dart"
    ; "flutter/test/widget_test.dart"
    ];
  require_allowed_dart_files
    root
    "flutter/integration_test"
    [ "flutter/integration_test/journal_runtime_flow_test.dart" ];
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
    ];
  match List.rev !failures with
  | [] -> print_endline "source boundary is clean"
  | failures ->
    List.iter prerr_endline failures;
    exit 1
;;
