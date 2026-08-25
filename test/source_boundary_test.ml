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
  let current_bonsai_flutter_revision = "5f8f540e4ccfd1e1807294aec8ac5f229161e2da" in
  let obsolete_bonsai_flutter_revisions =
    [ "6f2562e09d74d347a50b90541abdb4900e1e23da"
    ; "9b345b90fea476391d19092675abd665655e586a"
    ; "a6bd9aa9906c0e49f0cc365e5ba33270e89655e6"
    ; "d5f8d36b5539550cbc2466311acda4d8c609032e"
    ; "a51276a09eb1cdf9c87f07ac4c7558ed7c6b2d69"
    ; "26f5bf6c3b4cdd61ccd5c1660f6cf9f72fe523da"
    ; "066179956545cc12871862879fc906f09519788c"
    ; "f6d27175632d26e759532f6ee81e8d1383490533"
    ; "2dc30ce5f112eb79f84bfd238d2dd48e43e218cf"
    ; "d182690aeaa82ad0a972756205c62e3b598e3c24"
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
    ; "logseq_db_worker/lib/outliner/graph_read.ml"
    ; "logseq_db_worker/lib/outliner/graph_read.mli"
    ; "logseq_db_worker/lib/outliner/planner_contract.ml"
    ; "logseq_db_worker/lib/outliner/planner_contract.mli"
    ; "flutter/lib/application_host_adapter.dart"
    ; "flutter/lib/main.dart"
    ; "flutter/test/application_host_adapter_test.dart"
    ; "flutter/test/widget_test.dart"
    ; "test/test_material_icons_artifact.sh"
    ; "tool/verify_material_icons_font.sh"
    ];
  require_text
    root
    "logseq_db_worker/lib/outliner/graph_read.mli"
    [ "val values"
    ; "val one"
    ; "val string_value"
    ; "val reference_value"
    ; "val has_true"
    ; "val entities_by_uuid"
    ; "val uuid_of_entity"
    ; "val is_page"
    ; "val children"
    ];
  require_text
    root
    "logseq_db_worker/lib/outliner/planner_contract.mli"
    [ "type t ="
    ; "tx_ops : Datascript.tx_op list"
    ; "status : Protocol.mutation_status"
    ; "type error ="
    ; "Unsupported_semantics of string"
    ; "Built_in_protected"
    ];
  let outliner_planners =
    [ "save_block"
    ; "insert_blocks"
    ; "move_blocks"
    ; "indent_outdent"
    ; "delete_blocks"
    ; "pages"
    ; "properties"
    ]
  in
  List.iter
    (fun planner ->
       List.iter
         (fun suffix ->
            forbid_text
              root
              ("logseq_db_worker/lib/outliner/" ^ planner ^ suffix)
              [ "type t =\n  { tx_ops"; "type error =" ])
         [ ".ml"; ".mli" ])
    outliner_planners;
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "let values db entity attr ="
         ; "let string_value db entity attr ="
         ; "let reference_value db entity attr ="
         ; "let has_true db entity attr ="
         ; "let entities_by_uuid db uuid ="
         ; "let uuid_of_entity db entity ="
         ; "let is_page db entity ="
         ; "let children db parent ="
         ])
    [ "logseq_db_worker/lib/outliner/delete_blocks.ml"
    ; "logseq_db_worker/lib/outliner/indent_outdent.ml"
    ; "logseq_db_worker/lib/outliner/insert_blocks.ml"
    ; "logseq_db_worker/lib/outliner/move_blocks.ml"
    ; "logseq_db_worker/lib/outliner/pages.ml"
    ; "logseq_db_worker/lib/outliner/properties.ml"
    ; "logseq_db_worker/lib/outliner/references.ml"
    ; "logseq_db_worker/lib/outliner/save_block.ml"
    ];
  List.iter
    (fun relative -> forbid_text root relative [ "let one db entity attr =" ])
    [ "logseq_db_worker/lib/outliner/delete_blocks.ml"
    ; "logseq_db_worker/lib/outliner/indent_outdent.ml"
    ; "logseq_db_worker/lib/outliner/insert_blocks.ml"
    ; "logseq_db_worker/lib/outliner/move_blocks.ml"
    ; "logseq_db_worker/lib/outliner/pages.ml"
    ; "logseq_db_worker/lib/outliner/save_block.ml"
    ];
  require_text
    root
    "logseq_db_worker/lib/mutation_plan.ml"
    [ "include Outliner.Planner_contract" ];
  forbid_text
    root
    "logseq_db_worker/lib/mutation_plan.ml"
    [ "type t ="; "type error ="; "| Ok plan ->" ];
  forbid_text
    root
    "logseq_db_worker/lib/mutation_plan.mli"
    [ "type t ="; "type error =" ];
  forbid_text
    root
    "logseq_db_worker/lib/outliner/pages.ml"
    [ "Save_block.Built_in_protected" ];
  forbid_text
    root
    "logseq_db_worker/lib/outliner/indent_outdent.ml"
    [ "Move_blocks.Unsupported_semantics" ];
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
    [ "Material_icon_catalog.Add"
    ; "Material_icon_catalog.Arrow_upward"
    ; "Material_icon_catalog.Refresh"
    ];
  require_text root "app/journal_header.ml" [ "Material_icon_catalog.Account_circle" ];
  require_text
    root
    "app/journal_header.ml"
    [ "Ui.Widget.Sliver.app_bar"
    ; "~pinned:true"
    ; "~floating:false"
    ; "~snap:false"
    ; "~stretch:false"
    ; "~automatically_imply_leading:false"
    ; "~center_title:true"
    ];
  forbid_text
    root
    "app/journal_header.ml"
    [ "Ui.Widget.safe_area"
    ; "journal-header-stack"
    ; "journal-header-surface"
    ; "journal-header-content-height"
    ];
  require_text
    root
    "app/application.ml"
    [ "Journal_header.sliver"
    ; "Ui.Widget.Scroll_view.vertical"
    ; "journal-scroll"
    ; "~floating_action_button:capture"
    ; "~floating_action_button_location:Ui.Material.End_float"
    ];
  forbid_text
    root
    "app/application.ml"
    [ "Journal_header.view"; "~bottom_navigation_bar"; "let bottom_navigation_bar" ];
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
    [ "Ui.Native_widget.Swipe_action"; "Ui.Native_widget.Slidable.dismissible" ];
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
  require_occurrences root "app/application.ml" "Ui.Style.Color.rgb" 1;
  require_occurrences root "app/journal_visual_tokens.ml" "Ui.Style.Color.rgb" 1;
  require_occurrences root "app/journal_visual_tokens.ml" "Ui.Style.Color.argb" 0;
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
    ; "Ui.Material.list_tile"
    ; "Ui.Native_widget.Expandable_message_composer"
    ; "~floating_action_button:capture"
    ];
  List.iter
    (fun relative -> require_text root relative [ "Ui.Material.divider" ])
    [ "app/journal_header.ml"; "app/journal_timeline.ml" ];
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
    ; "App.View.create"
    ; "Ui.Theme.application"
    ; "Ui.Material.alert_dialog"
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
  require_file root "flutter/lib/application.dart";
  require_text
    root
    "flutter/lib/application.dart"
    [ "await JournalAmplify.configure()"
    ; "runApp"
    ; "Unable to configure authentication"
    ; "Retry"
    ];
  require_occurrences root "flutter/lib/application.dart" "MaterialApp(" 1;
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
