let failures = ref []
let fail format = Printf.ksprintf (fun message -> failures := message :: !failures) format
let path root relative = Filename.concat root relative

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

let require_file root relative =
  let filename = path root relative in
  if not (Sys.file_exists filename && not (Sys.is_directory filename))
  then fail "required file is missing: %s" relative
;;

let require_text root relative needles =
  let filename = path root relative in
  if not (Sys.file_exists filename && not (Sys.is_directory filename))
  then fail "required text file is missing: %s" relative
  else (
    let contents = read_file filename in
    List.iter
      (fun needle ->
         if not (contains contents needle)
         then fail "required text %S is missing from %s" needle relative)
      needles)
;;

let forbid_text root relative needles =
  let filename = path root relative in
  if Sys.file_exists filename && not (Sys.is_directory filename)
  then (
    let contents = read_file filename in
    List.iter
      (fun needle ->
         if contains contents needle
         then fail "forbidden text %S exists in %s" needle relative)
      needles)
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

let test_package_metadata root =
  List.iter
    (require_file root)
    [ "logseq_overlay_db.opam"
    ; "logseq_overlay_db.opam.locked"
    ; "logseq_overlay_db/spec/dune"
    ; "logseq_overlay_db/spec/types.mli"
    ; "logseq_overlay_db/spec/database.mli"
    ];
  require_text
    root
    "dune-project"
    [ "(name logseq_overlay_db)"
    ; "(logseq_db_types (= 0.1.0))"
    ; "(logseq_db_storage (= 0.1.0))"
    ];
  require_text
    root
    "logseq_overlay_db/spec/dune"
    [ "(name logseq_overlay_db)"
    ; "(public_name logseq_overlay_db)"
    ; "(modules types database)"
    ; "(virtual_modules types database)"
    ; "(default_implementation logseq_overlay_db_impl)"
    ; "(libraries eio logseq_db_types)"
    ];
  require_text
    root
    "logseq_overlay_db.opam"
    [ "name: \"logseq_overlay_db\""
    ; "\"logseq_db_types\" {= \"0.1.0\"}"
    ; "\"logseq_db_storage\" {= \"0.1.0\"}"
    ; "\"eio\" {= \"1.2\"}"
    ]
;;

let test_canonical_modules root =
  require_text
    root
    "logseq_overlay_db/spec/types.mli"
    [ "module Graph = Logseq_db_types.Graph_types"
    ; "module Generation"
    ; "module Projection_revision"
    ; "type local_mutation ="
    ; "Save_block of"
    ; "Insert_blocks of"
    ; "Delete_blocks of"
    ; "Create_journal_page of"
    ; "Set_task_status of"
    ; "Clear_task_status of"
    ; "type projection_change ="
    ; "Projection_resync_required of"
    ; "type local_commit_outcome ="
    ; "type authoritative_batch"
    ];
  require_text
    root
    "logseq_overlay_db/spec/database.mli"
    [ "module Graph = Logseq_db_types.Graph_types"
    ; "type t"
    ; "type snapshot"
    ; "val current_snapshot"
    ; "val release_snapshot"
    ; "val get_blocks"
    ; "val get_pages"
    ; "val get_journals"
    ; "val get_structure"
    ; "val commit_local"
    ; "val inspect_sync"
    ; "val begin_authoritative"
    ; "val apply_authoritative"
    ; "val apply_outbox_transition"
    ; "-> limits:Types.capability_limits\n  -> (dependencies, Types.limits_error) result"
    ; "val supply_snapshot_unprotection_batch\n\
      \  :  prepared_snapshot_activation\n\
      \  -> request:unprotection_request\n\
      \  -> plaintexts:(Types.crypto_item_id * string) list"
    ; "type authoritative_application =\n\
      \  | Authoritative_applied of Types.authoritative_commit\n\
      \  | Authoritative_deferred of Types.authoritative_defer"
    ; "val delete_mirror\n  :  mirror_inspection"
    ; "val collect_garbage\n  :  mirror_inspection"
    ; "val inspect_mirror\n\
      \  :  application_support_directory:string\n\
      \  -> graph_id:Graph.Uuid.t"
    ; "val prepare_snapshot_activation\n\
      \  :  dependencies\n\
      \  -> mirror_inspection\n\
      \  -> path:string"
    ; "val commit_snapshot_activation\n\
      \  :  prepared_snapshot_activation\n\
      \  -> (mirror_inspection, Types.snapshot_activation_error) result"
    ; "val open_\n\
      \  :  sw:Eio.Switch.t\n\
      \  -> dependencies\n\
      \  -> mirror_inspection\n\
      \  -> graph_name:string"
    ];
  forbid_text
    root
    "logseq_overlay_db/spec/database.mli"
    [ "Logseq_overlay_db.Types"
    ; "type mirror_location"
    ; "type attachment"
    ; "type snapshot_artifact"
    ; "type prepared_snapshot_commit"
    ; "val mirror_location"
    ; "val attachment"
    ; "val snapshot_artifact"
    ; "val finish_snapshot_activation"
    ; "val cancel_snapshot_commit"
    ; "type limits"
    ; "type prepared_local"
    ; "type local_preparation"
    ; "type protected_values"
    ; "type decrypted_values"
    ; "type prepared_outbox_commit"
    ; "type prepared_authoritative_commit"
    ; "type authoritative_finish"
    ; "val limits"
    ; "val prepare_local"
    ; "val cancel_local"
    ; "val protected_values"
    ; "val decrypted_values"
    ; "val finish_outbox_transition"
    ; "val commit_outbox_transition"
    ; "val cancel_outbox_transition"
    ; "val cancel_outbox_commit"
    ; "val finish_authoritative"
    ; "val commit_authoritative"
    ; "val cancel_authoritative"
    ; "val cancel_authoritative_commit"
    ];
  require_text
    root
    "logseq_overlay_db/spec/types.mli"
    [ "; checksum : checksum option"
    ; "type crypto_result_error ="
    ; "| Snapshot_crypto_result_error of crypto_result_error"
    ; "type local_commit_error ="
    ; "type outbox_transition_error ="
    ; "| Outbox_crypto_error of crypto_result_error"
    ; "type authoritative_transition_error ="
    ; "| Authoritative_crypto_error of crypto_result_error"
    ; "type snapshot_activation_error ="
    ; "| Mirror_absent"
    ; "| Invalid_graph_name"
    ; "| Snapshot_commit_persistence_failed of string"
    ];
  forbid_text
    root
    "logseq_overlay_db/spec/types.mli"
    [ "type snapshot_activation_commit"
    ; "type attachment_error"
    ; "type snapshot_input_error"
    ; "type snapshot_prepare_error"
    ; "type snapshot_commit_error"
    ; "type dependencies_error"
    ; "type local_prepare_error"
    ; "type outbox_prepare_error"
    ; "type outbox_commit_error"
    ; "type authoritative_prepare_error"
    ; "type authoritative_commit_error"
    ; "Crypto_result_canceled"
    ]
;;

let test_public_boundary root =
  files_with_suffixes root "logseq_overlay_db/spec" [ ".mli"; "dune" ]
  |> List.iter (fun relative ->
    forbid_text
      root
      relative
      [ "Datascript.db"
      ; "Datascript.conn"
      ; "Datascript.entity_id"
      ; "Datascript.tx_op"
      ; "Logseq_sync"
      ; "Logseq_db_worker"
      ; "Logseq_db_types.Mutation"
      ; "string list outbox"
      ]);
  files_with_suffixes root "logseq_overlay_db" [ ".ml"; ".mli" ]
  |> List.filter (fun relative -> not (contains relative "/test/"))
  |> List.iter (fun relative ->
    forbid_text root relative [ "projected_db"; "projected_conn"; "Projected_connection" ]);
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
  let types_path = path root "logseq_overlay_db/spec/types.mli" in
  if Sys.file_exists types_path
  then (
    let types = read_file types_path in
    List.iter
      (fun forbidden ->
         if contains types forbidden
         then fail "obsolete unsupported scaffold %S exists in canonical Types" forbidden)
      [ "type unsupported"; "Unsupported_" ];
    List.iter
      (fun forbidden ->
         if contains types forbidden
         then fail "generic write capability %S exists in canonical Types" forbidden)
      [ "create_page_kind"
      ; "property_selector"
      ; "property_value"
      ; "insert_position"
      ; "Move_blocks"
      ; "Rename_page"
      ; "Set_property"
      ; "Remove_property"
      ])
;;

let test_persistence_codec_ownership root =
  List.iter
    (require_file root)
    [ "logseq_overlay_db/lib/persistence_json.ml"
    ; "logseq_overlay_db/lib/persistence_outbox_v14.ml"
    ; "logseq_overlay_db/lib/persistence_receipt_v1.ml"
    ];
  require_text
    root
    "logseq_overlay_db/lib/dune"
    [ "persistence_json"
    ; "persistence_outbox_v14"
    ; "persistence_receipt_v1"
    ; "(pps ppx_deriving_yojson)"
    ];
  require_text
    root
    "logseq_overlay_db/lib/persistence_outbox_v14.ml"
    [ "[@@deriving yojson]"; "let encode"; "let decode" ];
  require_text
    root
    "logseq_overlay_db/lib/persistence_receipt_v1.ml"
    [ "[@@deriving yojson]"
    ; "let encode_mutation"
    ; "let decode_mutation"
    ; "let encode_terminal_batch"
    ; "let decode_terminal_batch"
    ];
  List.iter
    (fun relative -> require_text root relative [ "ppx_deriving_yojson" ])
    [ "dune-project"; "logseq_overlay_db.opam"; "logseq_overlay_db.opam.locked" ];
  require_text
    root
    "logseq_overlay_db/lib/database.ml"
    [ "Persistence_outbox_v14.encode"
    ; "Persistence_outbox_v14.decode"
    ; "Persistence_receipt_v1.encode_mutation"
    ; "Persistence_receipt_v1.decode_mutation"
    ; "Persistence_receipt_v1.encode_terminal_batch"
    ; "Persistence_receipt_v1.decode_terminal_batch"
    ];
  forbid_text
    root
    "logseq_overlay_db/lib/database.ml"
    [ "let uuid_to_json"
    ; "let tree_to_json"
    ; "let mutation_to_json"
    ; "let effect_footprint_to_json"
    ; "let dependency_shadows_to_json"
    ; "let delete_artifacts_to_json"
    ; "let transport_state_to_json"
    ; "let block_reason_to_json"
    ; "let acceptance_barrier_to_json"
    ; "let outbox_record_to_string"
    ; "let durable_receipt_to_row"
    ; "let terminal_batch_to_row"
    ];
  List.iter
    (fun relative ->
       forbid_text
         root
         relative
         [ "Persistence_json"
         ; "Persistence_outbox_v14"
         ; "Persistence_receipt_v1"
         ; "ppx_deriving_yojson"
         ])
    (files_with_suffixes root "logseq_overlay_db/spec" [ ".mli"; "dune" ])
;;

let test_install_manifest root install_manifest =
  let filename =
    if (not (Filename.is_relative install_manifest)) || Sys.file_exists install_manifest
    then install_manifest
    else path root install_manifest
  in
  if not (Sys.file_exists filename)
  then fail "install manifest is missing: %s" install_manifest
  else (
    let contents = read_file filename in
    List.iter
      (fun public_module ->
         if not (contains contents public_module)
         then fail "install manifest does not expose %s" public_module)
      [ "logseq_overlay_db/types.mli"; "logseq_overlay_db/database.mli" ];
    List.iter
      (fun private_module ->
         let compiled =
           "impl/.private/logseq_overlay_db__logseq_overlay_db_impl__"
           ^ private_module
           ^ ".cmi"
         in
         if not (contains contents compiled)
         then fail "install manifest does not keep %s private" private_module)
      [ "Persistence_json"; "Persistence_outbox_v14"; "Persistence_receipt_v1" ])
;;

let () =
  if Array.length Sys.argv <> 3
  then failwith "usage: logseq_overlay_db_boundary_test REPOSITORY_ROOT INSTALL_MANIFEST";
  let root = Sys.argv.(1) in
  test_package_metadata root;
  test_canonical_modules root;
  test_public_boundary root;
  test_persistence_codec_ownership root;
  test_install_manifest root Sys.argv.(2);
  match List.rev !failures with
  | [] -> print_endline "logseq_overlay_db package boundary: ok"
  | failures ->
    List.iter prerr_endline failures;
    exit 1
;;
