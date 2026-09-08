module Database = Logseq_overlay_db.Database
module Graph = Logseq_db_types.Graph_types
module T = Test_support
module Types = Logseq_overlay_db.Types
open Types

let snapshot_is_coherent _database snapshot =
  let first =
    Database.graph_info snapshot |> T.require_ok ~behavior:"coherent graph info"
  in
  let second =
    Database.graph_info snapshot |> T.require_ok ~behavior:"coherent graph info"
  in
  T.require
    (Types.Generation.equal first.version.generation second.version.generation
     && Types.Projection_revision.equal
          first.version.projection_revision
          second.version.projection_revision)
    "one snapshot did not retain one coherent version"
;;

let explicit_pages_preserve_order _database snapshot =
  match
    Database.get_pages snapshot [ T.missing_page_uuid; T.page_uuid ]
    |> T.require_ok ~behavior:"UUID page lookup order and missing values"
  with
  | [ Missing_page { uuid = missing; _ }; Present_page { value; _ } ] ->
    T.require
      (Graph.Uuid.equal missing T.missing_page_uuid)
      "missing page UUID was reordered";
    T.require
      (Graph.Uuid.equal value.page.uuid T.page_uuid)
      "present page UUID was reordered"
  | _ -> Alcotest.fail "explicit page lookup did not preserve Missing/Present order"
;;

let page_lookup_preserves_kind_tags_and_recycle_metadata _database snapshot =
  let built_in_tag = T.uuid "00000002-5389-0208-3000-000000000000" in
  match
    Database.get_pages snapshot [ T.page_uuid; built_in_tag ]
    |> T.require_ok ~behavior:"complete page metadata"
  with
  | [ Present_page { value = ordinary; _ }; Present_page { value = built_in; _ } ] ->
    T.require (ordinary.page.tags <> []) "ordinary page tags were discarded";
    T.require
      (ordinary.page.kind = Graph.Ordinary_page && not ordinary.page.recycled)
      "ordinary page kind or recycle state was fabricated";
    T.require
      (built_in.page.kind = Graph.Built_in_page)
      "built-in page was flattened to Ordinary_page"
  | _ -> Alcotest.fail "complete page metadata fixture pages are missing"
;;

let point_reads_preserve_property_summaries database =
  let behavior = "point reads preserve property summaries" in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let lookup uuid =
    Transit.Array
      [ Transit.Keyword "block/uuid"; Transit.Uuid (Graph.Uuid.to_string uuid) ]
  in
  let wire =
    Codec.to_string
      ~mode:Codec.Verbose
      (Transit.Array
         [ Transit.Array
             [ Keyword "db/add"
             ; lookup T.page_uuid
             ; Keyword "logseq.property/public?"
             ; Bool true
             ]
         ; Transit.Array
             [ Keyword "db/add"
             ; lookup T.authoritative_block_uuid
             ; Keyword "logseq.property/public?"
             ; Bool true
             ]
         ])
    |> encoded_transaction_of_string ~maximum_bytes:4_096
    |> T.require_ok ~behavior
  in
  let cursor = Server_cursor.of_string "server-cursor:v1:1" |> T.require_ok ~behavior in
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
  T.require (Option.is_none crypto) "boolean property unexpectedly requested crypto";
  let application =
    match
      Database.apply_authoritative database preparation ~decrypted:None
      |> T.require_ok ~behavior
    with
    | Database.Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "property batch was deferred"
  in
  ignore application;
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  let has_public_property properties =
    List.exists
      (fun (property : Graph.property_summary) ->
         String.equal property.ident "logseq.property/public?"
         && property.values = [ Graph.Checkbox_value true ])
      properties
  in
  (match Database.get_pages snapshot [ T.page_uuid ] |> T.require_ok ~behavior with
   | [ Present_page { value; _ } ] ->
     T.require
       (has_public_property value.page.properties)
       "page property summary was discarded"
   | _ -> Alcotest.fail "property fixture page is missing");
  (match
     Database.get_blocks snapshot [ T.authoritative_block_uuid ] |> T.require_ok ~behavior
   with
   | [ Present_block { value; _ } ] ->
     T.require
       (has_public_property value.block.properties)
       "block property summary was discarded"
   | _ -> Alcotest.fail "property fixture block is missing");
  Database.release_snapshot snapshot
;;

let authoritative_block_is_projected_by_uuid_and_structure _database snapshot =
  (match
     Database.get_blocks snapshot [ T.authoritative_block_uuid ]
     |> T.require_ok ~behavior:"authoritative block UUID projection"
   with
   | [ Present_block { value; _ } ] ->
     T.require
       (String.equal value.block.title "Authoritative block")
       "authoritative block title changed"
   | _ -> Alcotest.fail "authoritative block is missing by UUID");
  match
    Database.get_structure
      snapshot
      (Children { parent = T.page_uuid; limit = 32; cursor = None })
    |> T.require_ok ~behavior:"authoritative children projection"
  with
  | Children_result { items; _ } ->
    T.require
      (List.exists
         (fun (item : child_member) ->
            Graph.Uuid.equal item.block.block.uuid T.authoritative_block_uuid)
         items)
      "authoritative child is absent from its page"
  | Page_tree_result _ -> Alcotest.fail "children request returned page tree"
;;

let empty_children_retain_scope _database snapshot =
  match
    Database.get_structure
      snapshot
      (Children { parent = T.missing_block_uuid; limit = 32; cursor = None })
    |> T.require_ok ~behavior:"empty parent structure scope"
  with
  | Children_result { parent; revision_scope = Children_revision scoped; items = []; _ }
    when Graph.Uuid.equal parent T.missing_block_uuid
         && Graph.Uuid.equal scoped T.missing_block_uuid -> ()
  | _ -> Alcotest.fail "empty children result did not retain its parent scope"
;;

let page_tree_result_includes_depth _database snapshot =
  match
    Database.get_structure
      snapshot
      (Page_tree { page = T.page_uuid; maximum_depth = 2; limit = 200; cursor = None })
    |> T.require_ok ~behavior:"page-tree depth"
  with
  | Page_tree_result { page; maximum_depth = 2; _ } when Graph.Uuid.equal page T.page_uuid
    -> ()
  | _ -> Alcotest.fail "page-tree result lost its maximum depth"
;;

let released_snapshot_rejects_new_reads database =
  let snapshot =
    Database.current_snapshot database
    |> T.require_ok ~behavior:"snapshot release lifecycle"
  in
  Database.release_snapshot snapshot;
  match Database.graph_info snapshot with
  | Error Snapshot_released -> ()
  | Error _ -> Alcotest.fail "released snapshot returned the wrong lifecycle error"
  | Ok _ -> Alcotest.fail "released snapshot accepted a new read"
;;

let cursor text =
  Graph.Cursor.of_string text |> T.require_ok ~behavior:("parse cursor " ^ text)
;;

let projection_number snapshot =
  Database.snapshot_version snapshot
  |> fun version ->
  Types.Projection_revision.to_string version.projection_revision
  |> String.split_on_char ':'
  |> List.rev
  |> List.hd
  |> int_of_string
;;

let version_two_cursor snapshot offset =
  cursor (Printf.sprintf "cursor:v2:%d:%d" (projection_number snapshot) offset)
;;

let require_invalid_read behavior = function
  | Error (Invalid_read_request _) -> ()
  | Error _ -> Alcotest.failf "%s returned the wrong read error" behavior
  | Ok _ -> Alcotest.failf "%s was accepted" behavior
;;

let fixed_snapshot_cursor_is_projection_bound _database snapshot =
  let first =
    Database.get_structure
      snapshot
      (Children { parent = T.page_uuid; limit = 1; cursor = None })
    |> T.require_ok ~behavior:"projection-bound fixed-snapshot structure cursor"
  in
  match first with
  | Children_result { next_cursor = Some cursor; _ } ->
    T.require
      (String.equal
         (Graph.Cursor.to_string cursor)
         (Printf.sprintf "cursor:v2:%d:1" (projection_number snapshot)))
      "structure cursor did not use the deterministic v2 payload";
    ignore
      (Database.get_structure
         snapshot
         (Children { parent = T.page_uuid; limit = 1; cursor = Some cursor })
       |> T.require_ok ~behavior:"projection-bound fixed-snapshot structure cursor")
  | Children_result _ -> Alcotest.fail "fixture did not produce a structure cursor"
  | Page_tree_result _ -> Alcotest.fail "children read returned a page-tree result"
;;

let journal_cursor_is_snapshot_bound_and_paginates database =
  let behavior = "journal cursor is projection-bound" in
  let create ordinal uuid journal_day =
    let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
    let revision =
      match Database.get_pages snapshot [ uuid ] |> T.require_ok ~behavior with
      | [ Missing_page { revision; _ } ] -> revision
      | _ -> Alcotest.fail "fresh journal UUID is already present"
    in
    Database.release_snapshot snapshot;
    let expected =
      Database.write_precondition ~blocks:[] ~pages:[ uuid, revision ] ~scopes:[]
      |> T.require_ok ~behavior
    in
    let mutation =
      Create_journal_page
        { mutation_id = T.mutation_uuid ordinal
        ; page = uuid
        ; title = Printf.sprintf "Journal %d" journal_day
        ; journal_day
        }
    in
    ignore (T.commit_mutation database ~expected mutation ~behavior)
  in
  let first_uuid = T.uuid "33333333-3333-4333-8333-333333333331" in
  let second_uuid = T.uuid "33333333-3333-4333-8333-333333333332" in
  let third_uuid = T.uuid "33333333-3333-4333-8333-333333333333" in
  create 500 first_uuid 20260901;
  create 501 second_uuid 20260902;
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  let first =
    Database.get_journals
      ~from_day:0
      ~through_day:99_999_999
      snapshot
      ~limit:1
      ~cursor:None
    |> T.require_ok ~behavior
  in
  let cursor =
    match first.items, first.next_cursor with
    | [ item ], Some cursor ->
      T.require (item.journal_day = 20260902) "journal order is not descending";
      cursor
    | _ -> Alcotest.fail "first journal page did not return one item and a cursor"
  in
  let second =
    Database.get_journals
      ~from_day:0
      ~through_day:99_999_999
      snapshot
      ~limit:1
      ~cursor:(Some cursor)
    |> T.require_ok ~behavior
  in
  (match second.items with
   | [ item ] -> T.require (item.journal_day = 20260901) "cursor skipped journal"
   | _ -> Alcotest.fail "second journal page has the wrong cardinality");
  Database.release_snapshot snapshot;
  create 502 third_uuid 20260903;
  let newer = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_journals
       ~from_day:0
       ~through_day:99_999_999
       newer
       ~limit:1
       ~cursor:(Some cursor)
   with
   | Error Stale_read_cursor -> ()
   | Error _ -> Alcotest.fail "cross-snapshot cursor returned the wrong error"
   | Ok _ -> Alcotest.fail "cross-snapshot cursor was accepted");
  Database.release_snapshot newer
;;

let structure_cursors_accept_request_shape_reuse_and_reject_projection database =
  let behavior = "structure cursors are offsets bound only to projection" in
  let insert ordinal uuid =
    let expected = T.insert_precondition database ~parent:T.page_uuid ~behavior in
    let mutation =
      Insert_blocks
        { mutation_id = T.mutation_uuid ordinal
        ; parent = T.page_uuid
        ; tree = { uuid; title = Printf.sprintf "Child %d" ordinal; children = [] }
        }
    in
    ignore (T.commit_mutation database ~expected mutation ~behavior)
  in
  insert 520 (T.uuid "44444444-4444-4444-8444-444444444441");
  insert 521 (T.uuid "44444444-4444-4444-8444-444444444442");
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  let first =
    Database.get_structure
      snapshot
      (Children { parent = T.page_uuid; limit = 1; cursor = None })
    |> T.require_ok ~behavior
  in
  let cursor =
    match first with
    | Children_result { items = [ _ ]; next_cursor = Some cursor; _ } -> cursor
    | _ -> Alcotest.fail "children limit did not return one item and a cursor"
  in
  (match
     Database.get_structure
       snapshot
       (Children { parent = T.page_uuid; limit = 1; cursor = Some cursor })
     |> T.require_ok ~behavior
   with
   | Children_result { items = [ _ ]; _ } -> ()
   | _ -> Alcotest.fail "children cursor did not return the next item");
  (match
     Database.get_structure
       snapshot
       (Children { parent = T.missing_block_uuid; limit = 1; cursor = Some cursor })
   with
   | Ok (Children_result { items = []; next_cursor = None; _ }) -> ()
   | Error _ -> Alcotest.fail "bounded offset was rejected for another parent"
   | Ok _ -> Alcotest.fail "cross-parent offset returned an unexpected result");
  let tree_first =
    Database.get_structure
      snapshot
      (Page_tree { page = T.page_uuid; maximum_depth = 2; limit = 1; cursor = None })
    |> T.require_ok ~behavior
  in
  let tree_cursor =
    match tree_first with
    | Page_tree_result { items = [ _ ]; next_cursor = Some cursor; _ } -> cursor
    | _ -> Alcotest.fail "page-tree limit did not return one item and a cursor"
  in
  (match
     Database.get_structure
       snapshot
       (Page_tree
          { page = T.page_uuid; maximum_depth = 1; limit = 1; cursor = Some tree_cursor })
   with
   | Ok (Page_tree_result _) -> ()
   | Error _ -> Alcotest.fail "bounded offset was rejected for another tree depth"
   | Ok _ -> Alcotest.fail "cross-depth offset returned the wrong result");
  Database.release_snapshot snapshot;
  insert 522 (T.uuid "44444444-4444-4444-8444-444444444443");
  let newer = Database.current_snapshot database |> T.require_ok ~behavior in
  (match
     Database.get_structure
       newer
       (Children { parent = T.page_uuid; limit = 1; cursor = Some cursor })
   with
   | Error Stale_read_cursor -> ()
   | Error _ -> Alcotest.fail "cross-snapshot structure cursor returned the wrong error"
   | Ok _ -> Alcotest.fail "structure cursor was accepted for another snapshot");
  Database.release_snapshot newer
;;

let malformed_and_out_of_range_cursors_are_rejected _database snapshot =
  let projection = projection_number snapshot in
  [ "cursor:v1:0:0:obsolete-mac"
  ; "cursor:v2"
  ; "cursor:v3:0:0"
  ; Printf.sprintf "cursor:v2:%d:not-an-offset" projection
  ; Printf.sprintf "cursor:v2:not-a-projection:0"
  ; Printf.sprintf "cursor:v2:%d:-1" projection
  ; Printf.sprintf "cursor:v2:%d:10001" projection
  ; Printf.sprintf "cursor:v2:%d:999999999999999999999999999999" projection
  ; Printf.sprintf "cursor:v2:%d:0:extra" projection
  ]
  |> List.iter (fun value ->
    Database.get_journals
      ~from_day:0
      ~through_day:99_999_999
      snapshot
      ~limit:1
      ~cursor:(Some (cursor value))
    |> require_invalid_read ("malformed cursor " ^ value));
  Database.get_journals
    snapshot
    ~from_day:0
    ~through_day:99_999_999
    ~limit:1
    ~cursor:(Some (version_two_cursor snapshot 10_000))
  |> require_invalid_read "obsolete journal offset boundary"
;;

let page_limits_are_enforced_before_pagination _database snapshot =
  let children limit =
    Database.get_structure
      snapshot
      (Children { parent = T.page_uuid; limit; cursor = None })
  in
  Database.get_journals ~from_day:0 ~through_day:99_999_999 snapshot ~limit:0 ~cursor:None
  |> require_invalid_read "zero journal page limit";
  Database.get_journals
    ~from_day:0
    ~through_day:99_999_999
    snapshot
    ~limit:201
    ~cursor:None
  |> require_invalid_read "oversized journal page limit";
  children 0 |> require_invalid_read "zero children page limit";
  children 201 |> require_invalid_read "oversized children page limit";
  children Int.max_int |> require_invalid_read "overflowing children page limit";
  ignore
    (Database.get_journals
       ~from_day:0
       ~through_day:99_999_999
       snapshot
       ~limit:200
       ~cursor:None
     |> T.require_ok ~behavior:"maximum journal page limit");
  ignore (children 200 |> T.require_ok ~behavior:"maximum children page limit")
;;

let verify_continuation_above_maximum_offset_fails_the_page database =
  let behavior = "continuation traversal is bounded at 10,000" in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let page =
    Transit.Array
      [ Transit.Keyword "block/uuid"; Transit.Uuid (Graph.Uuid.to_string T.page_uuid) ]
  in
  let operations =
    List.init 10_002 (fun ordinal ->
      let entity = Transit.String (Printf.sprintf "bounded-child-%d" ordinal) in
      let add attribute value =
        Transit.Array
          [ Transit.Keyword "db/add"; entity; Transit.Keyword attribute; value ]
      in
      [ add
          "block/uuid"
          (Transit.Uuid (Printf.sprintf "66666666-6666-4666-8666-%012d" ordinal))
      ; add "block/title" (Transit.String "x")
      ; add "block/parent" page
      ; add "block/page" page
      ; add "block/order" (Transit.String (Printf.sprintf "z%08d" ordinal))
      ; add "block/created-at" (Transit.Int 1_704_067_200_000)
      ; add "block/updated-at" (Transit.Int 1_704_067_200_000)
      ])
    |> List.concat
  in
  let transaction =
    Transit.Array operations
    |> Codec.to_string ~mode:Codec.Verbose
    |> encoded_transaction_of_string ~maximum_bytes:(64 * 1_024 * 1_024)
    |> T.require_ok ~behavior
  in
  let server_cursor =
    Server_cursor.of_string "server-cursor:v1:1" |> T.require_ok ~behavior
  in
  let batch =
    authoritative_batch
      ~maximum_count:1
      ~maximum_bytes:(64 * 1_024 * 1_024)
      ~transactions:[ authoritative_transaction ~cursor:server_cursor ~transaction ]
      ~through:server_cursor
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let preparation, crypto =
    Database.begin_authoritative database ~expected:(sync_view_token sync) batch
    |> T.require_ok ~behavior
  in
  let decrypted_values =
    Option.map
      (fun request ->
         let plaintexts = Database.unprotection_ciphertexts request in
         request, plaintexts)
      crypto
  in
  let application =
    match
      Database.apply_authoritative database preparation ~decrypted:decrypted_values
      |> T.require_ok ~behavior
    with
    | Database.Authoritative_applied commit -> commit
    | Authoritative_deferred _ -> Alcotest.fail "authoritative fixture was deferred"
  in
  ignore application;
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       let at_boundary =
         Database.get_structure
           snapshot
           (Children
              { parent = T.page_uuid
              ; limit = 1
              ; cursor = Some (version_two_cursor snapshot 9_999)
              })
         |> T.require_ok ~behavior
       in
       (match at_boundary with
        | Children_result { items = [ _ ]; next_cursor = Some next; _ } ->
          T.require
            (String.equal
               (Graph.Cursor.to_string next)
               (Printf.sprintf "cursor:v2:%d:10000" (projection_number snapshot)))
            "the exact 10,000 continuation was not emitted"
        | _ -> Alcotest.fail "the exact continuation boundary did not return one item");
       match
         Database.get_structure
           snapshot
           (Children
              { parent = T.page_uuid
              ; limit = 1
              ; cursor = Some (version_two_cursor snapshot 10_000)
              })
       with
       | Error Read_limit_exceeded -> ()
       | Error _ -> Alcotest.fail "overflow continuation returned the wrong read error"
       | Ok _ -> Alcotest.fail "overflow continuation returned a false page result")
;;

let continuation_above_maximum_offset_fails_the_page () =
  let behavior = "continuation traversal is bounded at 10,000" in
  let limits =
    { Types.response_budget_bytes = 64 * 1_024 * 1_024
    ; outbox_max_records = 4_096
    ; outbox_max_bytes = 64 * 1_024 * 1_024
    ; change_max_items = 4_096
    ; change_max_bytes = 4 * 1_024 * 1_024
    ; dispatcher_capacity = 32
    ; wire_batch_max_bytes = 64 * 1_024 * 1_024
    }
  in
  T.with_database_using_limits
    ~behavior
    limits
    verify_continuation_above_maximum_offset_fails_the_page
;;

let pinned_snapshot_keeps_optimistic_outbox_root database =
  let behavior = "pinned snapshot keeps its optimistic outbox root" in
  let expected =
    let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
    Fun.protect
      ~finally:(fun () -> Database.release_snapshot snapshot)
      (fun () ->
         let revision =
           match
             Database.get_blocks snapshot [ T.authoritative_block_uuid ]
             |> T.require_ok ~behavior
           with
           | [ Present_block { revision; _ } ] -> revision
           | _ -> Alcotest.fail "save fixture block is missing"
         in
         Database.write_precondition
           ~blocks:[ T.authoritative_block_uuid, revision ]
           ~pages:[]
           ~scopes:[]
         |> T.require_ok ~behavior)
  in
  let commit =
    match
      T.commit_mutation
        database
        ~expected
        (Save_block
           { mutation_id = T.mutation_uuid 600
           ; block = T.authoritative_block_uuid
           ; title = "Pinned optimistic title"
           })
        ~behavior
    with
    | Local_committed commit -> commit
    | Local_existing _ -> Alcotest.fail "fresh save mutation already existed"
  in
  let pinned = Database.current_snapshot database |> T.require_ok ~behavior in
  let block_title snapshot =
    match
      Database.get_blocks snapshot [ T.authoritative_block_uuid ]
      |> T.require_ok ~behavior
    with
    | [ Present_block { value; _ } ] -> value.block.title
    | _ -> Alcotest.fail "save fixture block is missing"
  in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot pinned)
    (fun () ->
       T.require
         (String.equal (block_title pinned) "Pinned optimistic title")
         "pinned snapshot omitted the optimistic title";
       let view = Database.inspect_sync database |> T.require_ok ~behavior in
       let preparation, request =
         Database.begin_outbox_transition
           database
           ~expected:(sync_view_token view)
           (Submit_group [ commit.mutation_id ])
         |> T.require_ok ~behavior
       in
       let request =
         match request with
         | Some request -> request
         | None -> Alcotest.fail "save submission omitted its protection request"
       in
       let encrypted =
         Database.protection_plaintexts request
         |> List.map (fun (item, plaintext) -> item, "encrypted:" ^ plaintext)
       in
       let submitted =
         Database.apply_outbox_transition
           database
           preparation
           ~encrypted:(Some (request, encrypted))
         |> T.require_ok ~behavior
       in
       let batch =
         match submitted.submission_batch with
         | Some batch -> batch
         | None -> Alcotest.fail "save submission omitted its wire batch"
       in
       let partition =
         { accepted_prefix = []
         ; failed_member = Some commit.mutation_id
         ; unexecuted_suffix = []
         ; acceptance_barrier = None
         ; missing_uuids = []
         ; diagnostics = [ "deterministic pinned-snapshot rejection" ]
         }
       in
       let view = Database.inspect_sync database |> T.require_ok ~behavior in
       let preparation, crypto =
         Database.begin_outbox_transition
           database
           ~expected:(sync_view_token view)
           (Reject_group
              { batch_id = submission_batch_id batch
              ; resolution = Definitive { reason = Invalid_request; partition }
              })
         |> T.require_ok ~behavior
       in
       T.require (Option.is_none crypto) "rejection unexpectedly requested crypto";
       ignore
         (Database.apply_outbox_transition database preparation ~encrypted:None
          |> T.require_ok ~behavior);
       T.require
         (String.equal (block_title pinned) "Pinned optimistic title")
         "a later rejection mutated the pinned snapshot outbox root";
       let current = Database.current_snapshot database |> T.require_ok ~behavior in
       Fun.protect
         ~finally:(fun () -> Database.release_snapshot current)
         (fun () ->
            T.require
              (not (String.equal (block_title current) "Pinned optimistic title"))
              "definitive rejection did not roll back the current projection"))
;;

let graph_info_uses_uuid_and_no_basis _database snapshot =
  let info =
    Database.graph_info snapshot |> T.require_ok ~behavior:"logical graph info"
  in
  T.require (Graph.Uuid.equal info.graph_uuid T.graph_uuid) "graph info UUID is wrong";
  T.require (info.graph_name = "oracle-graph") "graph info name is wrong"
;;

let admission_is_not_snapshot_versioned database _snapshot =
  let inspection =
    Database.inspect_admission database
    |> T.require_ok ~behavior:"administrative admission inspection"
  in
  T.require
    (inspection.active_records <= inspection.maximum_records
     && inspection.active_bytes <= inspection.maximum_bytes)
    "admission usage exceeds its declared bound"
;;

let journals_reject_legacy_offsets _database snapshot =
  Database.get_journals
    ~from_day:0
    ~through_day:99_999_999
    snapshot
    ~limit:1
    ~cursor:(Some (version_two_cursor snapshot 0))
  |> require_invalid_read "obsolete journal offset"
;;

let indexed_journals_preserve_selection database =
  let behavior = "indexed journal selection" in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let journal_uuid n = T.uuid (Printf.sprintf "71000000-0000-4000-8000-%012d" n) in
  List.iter
    (fun n ->
       let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
       let revision =
         match
           Database.get_pages snapshot [ journal_uuid n ] |> T.require_ok ~behavior
         with
         | [ Missing_page { revision; _ } ] -> revision
         | _ -> Alcotest.fail "local journal already exists"
       in
       Database.release_snapshot snapshot;
       let expected =
         Database.write_precondition
           ~blocks:[]
           ~pages:[ journal_uuid n, revision ]
           ~scopes:[]
         |> T.require_ok ~behavior
       in
       ignore
         (T.commit_mutation
            database
            ~expected
            (Create_journal_page
               { mutation_id = T.mutation_uuid (800 + n)
               ; page = journal_uuid n
               ; title = Printf.sprintf "Local journal %d" n
               ; journal_day = 20260903
               })
            ~behavior))
    [ 0; 4 ];
  let add e a v = Transit.Array [ Keyword "db/add"; Int e; Keyword a; v ] in
  let journal n day =
    let e = 10000 + (n * 30) in
    [ add e "block/uuid" (Uuid (Graph.Uuid.to_string (journal_uuid n)))
    ; add e "block/name" (String (Printf.sprintf "indexed-%d" n))
    ; add e "block/title" (String (Printf.sprintf "Indexed %d" n))
    ; add e "block/journal-day" (Int day)
    ; add e "logseq.property/public?" (Bool true)
    ]
  in
  let large_tie = List.init 128 (fun n -> n + 10) in
  let ops =
    List.concat_map (fun n -> journal n 20260903) large_tie
    @ journal 3 20260903
    @ journal 2 20260903
    @ journal 1 20260903
    @ journal 4 20260903
    @ journal 5 20260901
    @ journal 6 20260904
    @ [ add 10180 "logseq.property/built-in?" (Bool true) ]
    @ [ add 10210 "block/journal-day" (Int 20260905)
      ; add 10210 "block/name" (String "malformed")
      ]
  in
  let wire =
    Codec.to_string ~mode:Codec.Verbose (Transit.Array ops)
    |> encoded_transaction_of_string ~maximum_bytes:262144
    |> T.require_ok ~behavior
  in
  let cursor = Server_cursor.of_string "server-cursor:v1:1" |> T.require_ok ~behavior in
  let batch =
    authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:262144
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
  let decrypted =
    Option.map (fun request -> request, Database.unprotection_ciphertexts request) crypto
  in
  (match
     Database.apply_authoritative database preparation ~decrypted
     |> T.require_ok ~behavior
   with
   | Database.Authoritative_applied _ -> ()
   | Authoritative_deferred _ -> Alcotest.fail "journal fixture deferred");
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       let rec collect cursor acc =
         let result =
           Database.get_journals
             ~from_day:0
             ~through_day:99_999_999
             snapshot
             ~limit:1
             ~cursor
           |> T.require_ok ~behavior
         in
         T.require (List.length result.items <= 1) "journal limit exceeded";
         let acc = acc @ result.items in
         match result.next_cursor with
         | None -> acc
         | Some cursor ->
           T.require (List.length acc < 256) "journal cursor repeated a result";
           collect (Some cursor) acc
       in
       let range ?(cursor = None) from_day through_day limit =
         Database.get_journals snapshot ~from_day ~through_day ~limit ~cursor
       in
       let first = range 20260903 20260903 2 |> T.require_ok ~behavior in
       Alcotest.(check int) "same-day range limit" 2 (List.length first.items);
       let cursor =
         match first.next_cursor with
         | Some c -> c
         | None -> Alcotest.fail "tie cursor missing"
       in
       range ~cursor:(Some cursor) 20260901 20260903 2
       |> require_invalid_read "cursor cannot change query bounds";
       let rec collect_range cursor acc =
         let result = range ~cursor 20260903 20260903 2 |> T.require_ok ~behavior in
         let acc = acc @ result.items in
         match result.next_cursor with
         | None -> acc
         | Some c ->
           T.require (List.length acc < 256) "range cursor repeated";
           collect_range (Some c) acc
       in
       let tied = collect_range None [] in
       Alcotest.(check (list string))
         "same-date range includes local overlap once"
         (List.map
            (fun n -> Graph.Uuid.to_string (journal_uuid n))
            ([ 0; 1; 2; 3; 4 ] @ large_tie))
         (List.map (fun (i : journal_item) -> Graph.Uuid.to_string i.page.page.uuid) tied);
       let older = range 20260901 20260902 1 |> T.require_ok ~behavior in
       Alcotest.(check (list int))
         "bounds precede limit and override moved overlap"
         [ 20260901 ]
         (List.map (fun (i : journal_item) -> i.journal_day) older.items);
       T.require (Option.is_none older.next_cursor) "empty probe returned a continuation";
       List.iter
         (fun (lo, hi) ->
            let empty = range lo hi 1 |> T.require_ok ~behavior in
            T.require
              (empty.items = [] && empty.next_cursor = None)
              "empty range returned journals")
         [ 20260904, 20260905; 20260905, 20260901; 0, 0 ];
       let projection = projection_number snapshot in
       List.iter
         (fun source ->
            range
              ~cursor:(Some (Graph.Cursor.of_string source |> Result.get_ok))
              20260903
              20260903
              1
            |> require_invalid_read "malformed date cursor")
         [ "journal:v1"
         ; Printf.sprintf "journal:v1:%d:20260903:20260903:no-date:no-uuid" projection
         ];
       let items = collect None [] in
       Alcotest.(check (list string))
         "date descending and UUID ascending"
         (List.map
            (fun n -> Graph.Uuid.to_string (journal_uuid n))
            ([ 0; 1; 2; 3; 4 ] @ large_tie @ [ 5 ]))
         (List.map
            (fun (i : journal_item) -> Graph.Uuid.to_string i.page.page.uuid)
            items);
       List.iter
         (fun (item : journal_item) ->
            match
              Database.get_pages snapshot [ item.page.page.uuid ]
              |> T.require_ok ~behavior
            with
            | [ Present_page { value; revision } ] ->
              T.require
                (value = item.page && revision = item.revision)
                "journal hydration differs from exact page lookup"
            | _ -> Alcotest.fail "selected journal is missing")
         items)
;;

let page_tree_preserves_valid_windows_and_snapshots database =
  let behavior = "page-tree valid windows and snapshots" in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let id n = T.uuid (Printf.sprintf "73000000-0000-4000-8000-%012d" n) in
  let page = id 99 in
  let add e a v = Transit.Array [ Keyword "db/add"; Int e; Keyword a; v ] in
  let lookup uuid =
    Transit.Array [ Keyword "block/uuid"; Uuid (Graph.Uuid.to_string uuid) ]
  in
  let apply number ops =
    let wire =
      Codec.to_string ~mode:Codec.Verbose (Transit.Array ops)
      |> encoded_transaction_of_string ~maximum_bytes:262144
      |> T.require_ok ~behavior
    in
    let cursor =
      Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" number)
      |> T.require_ok ~behavior
    in
    let batch =
      authoritative_batch
        ~maximum_count:16
        ~maximum_bytes:262144
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
    let decrypted =
      Option.map
        (fun request -> request, Database.unprotection_ciphertexts request)
        crypto
    in
    match
      Database.apply_authoritative database preparation ~decrypted
      |> T.require_ok ~behavior
    with
    | Database.Authoritative_applied _ -> ()
    | Authoritative_deferred _ -> Alcotest.fail "tree fixture was deferred"
  in
  let node n parent order =
    let e = 10000 + (n * 17) in
    [ add e "block/uuid" (Uuid (Graph.Uuid.to_string (id n)))
    ; add e "block/title" (String (Printf.sprintf "Node %d" n))
    ; add e "block/parent" (lookup parent)
    ; add e "block/page" (lookup page)
    ; add e "block/order" (String order)
    ; add e "logseq.property/public?" (Bool true)
    ]
  in
  let without attr ops =
    List.filter
      (function
        | Transit.Array [ _; _; Keyword a; _ ] -> a <> attr
        | _ -> true)
      ops
  in
  apply
    1
    ([ add 20000 "block/uuid" (Uuid (Graph.Uuid.to_string page))
     ; add 20000 "block/name" (String "tree-window")
     ; add 20000 "block/title" (String "Original page")
     ]
     @ node 1 page "a1"
     @ node 0 page "a1"
     @ node 2 (id 0) "a0"
     @ node 3 (id 2) "a0"
     @ node 4 page "a2"
     @ without "block/title" (node 5 page "a0")
     @ without "block/order" (node 6 page "a0")
     @ without "block/uuid" (node 7 page "a0")
     @ without "block/page" (node 8 page "a3")
     @ (without "block/page" (node 9 page "a0")
        @ [ add (10000 + (9 * 17)) "block/page" (Int 29000) ])
     @ node 10 (id 5) "a0");
  let read snapshot depth limit cursor =
    match
      Database.get_structure
        snapshot
        (Page_tree { page; maximum_depth = depth; limit; cursor })
      |> T.require_ok ~behavior
    with
    | Page_tree_result { items; next_cursor; _ } -> items, next_cursor
    | Children_result _ -> Alcotest.fail "tree returned children"
  in
  let verify snapshot depth expected =
    List.iter
      (fun limit ->
         let rec collect cursor acc =
           let items, next = read snapshot depth limit cursor in
           List.iter
             (fun (item : tree_member) ->
                match
                  Database.get_blocks snapshot [ item.block.block.uuid ]
                  |> T.require_ok ~behavior
                with
                | [ Present_block { value; revision } ] ->
                  T.require
                    (value = item.block && revision = item.revision)
                    "tree content or revision differs from point read";
                  T.require
                    (Graph.Uuid.equal item.parent value.block.parent)
                    "tree parent differs"
                | _ -> Alcotest.fail "tree includes missing block")
             items;
           let acc = List.rev_append items acc in
           match next with
           | None -> List.rev acc
           | Some c ->
             T.require (List.length items = limit) "invalid candidates consumed slots";
             collect (Some c) acc
         in
         let all = collect None [] in
         Alcotest.(check (list (pair string int)))
           "DFS, ties, and depth"
           (List.map (fun (n, d) -> Graph.Uuid.to_string (id n), d) expected)
           (List.map
              (fun (i : tree_member) -> Graph.Uuid.to_string i.block.block.uuid, i.depth)
              all))
      [ 1; 2; 200 ]
  in
  let pinned = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot pinned)
    (fun () ->
       verify pinned 0 [ 0, 0; 1, 0; 4, 0 ];
       verify pinned 1 [ 0, 0; 2, 1; 1, 0; 4, 0 ];
       verify pinned 64 [ 0, 0; 2, 1; 3, 2; 1, 0; 4, 0 ];
       let first, cursor = read pinned 64 1 None in
       T.require (List.length first = 1 && Option.is_some cursor) "missing continuation";
       let expected =
         match Database.get_blocks pinned [ id 1 ] |> T.require_ok ~behavior with
         | [ Present_block { revision; _ } ] ->
           Database.write_precondition ~blocks:[ id 1, revision ] ~pages:[] ~scopes:[]
           |> T.require_ok ~behavior
         | _ -> Alcotest.fail "delete fixture missing"
       in
       ignore
         (Database.commit_local
            database
            ~expected
            (Delete_blocks { mutation_id = T.mutation_uuid 951; root = id 1 })
          |> T.require_ok ~behavior);
       let deleted = Database.current_snapshot database |> T.require_ok ~behavior in
       Fun.protect
         ~finally:(fun () -> Database.release_snapshot deleted)
         (fun () -> verify deleted 64 [ 0, 0; 2, 1; 3, 2; 4, 0 ]);
       apply 2 [ add 20000 "block/title" (String "Updated page") ];
       let current = Database.current_snapshot database |> T.require_ok ~behavior in
       Fun.protect
         ~finally:(fun () -> Database.release_snapshot current)
         (fun () ->
            (* The remote page patch conflicts with the frozen delete footprint. *)
            verify current 64 [ 0, 0; 2, 1; 3, 2; 1, 0; 4, 0 ];
            (match
               Database.get_structure
                 current
                 (Page_tree { page; maximum_depth = 64; limit = 1; cursor })
             with
             | Error Stale_read_cursor -> ()
             | _ -> Alcotest.fail "old cursor accepted by new projection");
            let latest, _ = read current 64 1 None in
            T.require
              ((List.hd latest).block.rendered_page_title = "Updated page")
              "logical page title cache is stale");
       verify pinned 64 [ 0, 0; 2, 1; 3, 2; 1, 0; 4, 0 ];
       let old, _ = read pinned 64 1 cursor in
       T.require
         ((List.hd old).block.rendered_page_title = "Original page")
         "old snapshot lost page title")
;;

let favorites_resolve_order_filter_and_snapshot database =
  let behavior = "favorites resolved snapshot read" in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let id n = T.uuid (Printf.sprintf "74000000-0000-4000-8000-%012d" n) in
  let lookup uuid =
    Transit.Array [ Keyword "block/uuid"; Uuid (Graph.Uuid.to_string uuid) ]
  in
  let add n a v = Transit.Array [ Keyword "db/add"; Int (30000 + n); Keyword a; v ] in
  let apply number ops =
    let wire =
      Codec.to_string ~mode:Codec.Verbose (Transit.Array ops)
      |> encoded_transaction_of_string ~maximum_bytes:4_194_304
      |> T.require_ok ~behavior
    in
    let cursor =
      Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" number)
      |> T.require_ok ~behavior
    in
    let batch =
      authoritative_batch
        ~maximum_count:16
        ~maximum_bytes:4_194_304
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
    let decrypted = Option.map (fun r -> r, Database.unprotection_ciphertexts r) crypto in
    match
      match Database.apply_authoritative database preparation ~decrypted with
      | Error
          (Authoritative_decode_failed message | Authoritative_integrity_failure message)
        -> Alcotest.fail message
      | result -> T.require_ok ~behavior result
    with
    | Database.Authoritative_applied commit ->
      if number = 7
      then (
        match commit.logical_change_summary with
        | Exact_logical_change { block_uuids; _ } ->
          T.require
            (List.exists (Graph.Uuid.equal (id 1)) block_uuids)
            "link-only change omitted membership invalidation"
        | _ -> Alcotest.fail "link-only change did not publish an exact change")
    | Authoritative_deferred _ -> Alcotest.fail "favorites fixture deferred"
  in
  let with_snapshot f =
    let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
    Fun.protect
      ~finally:(fun () -> Database.release_snapshot snapshot)
      (fun () -> f snapshot)
  in
  let read snapshot limit cursor =
    Database.get_favorites snapshot ~limit ~cursor |> T.require_ok ~behavior
  in
  let all snapshot =
    let rec collect count cursor acc =
      T.require (count < 20) "favorites cursor did not terminate";
      let page = read snapshot 1 cursor in
      T.require (List.length page.items <= 1) "favorite scan limit exceeded";
      let acc = acc @ page.items in
      match page.next_cursor with
      | None -> acc
      | Some c -> collect (count + 1) (Some c) acc
    in
    collect 0 None []
  in
  let memberships items =
    List.map (fun (i : favorite_item) -> Graph.Uuid.to_string i.membership_uuid) items
  in
  apply
    1
    [ Transit.Array
        [ Keyword "db/retractEntity"
        ; lookup (T.uuid "00000004-1018-5888-4100-000000000000")
        ]
    ];
  with_snapshot (fun snapshot ->
    let empty = read snapshot 2 None in
    T.require
      (empty.favorites_page = None && empty.items = [] && empty.next_cursor = None)
      "absent favorites is not empty";
    List.iter
      (fun limit ->
         Database.get_favorites snapshot ~limit ~cursor:None
         |> require_invalid_read "favorites invalid limit")
      [ 0; 201 ];
    Database.get_favorites
      snapshot
      ~limit:1
      ~cursor:(Some (cursor "bad-favorites-cursor"))
    |> require_invalid_read "malformed favorite cursor");
  let page n title name =
    [ add n "block/uuid" (Uuid (Graph.Uuid.to_string (id n)))
    ; add n "block/title" (String title)
    ; add n "block/name" (String name)
    ]
  in
  let member n order target =
    [ add n "block/uuid" (Uuid (Graph.Uuid.to_string (id n)))
    ; add n "block/title" (String "")
    ; add n "block/parent" (lookup (id 99))
    ; add n "block/page" (lookup (id 99))
    ; add n "block/order" (String order)
    ]
    @
    match target with
    | None -> []
    | Some target -> [ add n "block/link" (lookup target) ]
  in
  apply
    2
    (page 99 "$$$favorites" "$$$favorites"
     @ page 98 "Ordinary favorite" "ordinary favorite");
  apply
    3
    (member 1 "a1" (Some (id 98))
     @ member 0 "a0" None
     @ member 2 "a2" (Some T.authoritative_block_uuid)
     @ member 3 "a3" (Some (id 98)));
  with_snapshot (fun pinned ->
    let first = read pinned 1 None in
    T.require
      (first.items = [] && Option.is_some first.next_cursor)
      "filtered page lost continuation: page=%s items=%d cursor=%b"
      (Option.fold ~none:"none" ~some:Graph.Uuid.to_string first.favorites_page)
      (List.length first.items)
      (Option.is_some first.next_cursor);
    let items = all pinned in
    Alcotest.(check (list string))
      "membership order and duplicate targets"
      (List.map (fun n -> Graph.Uuid.to_string (id n)) [ 1; 2; 3 ])
      (memberships items);
    (match items with
     | [ { target = Favorite_page { title; _ }; _ }
       ; { target = Favorite_block { title = block_title; _ }; _ }
       ; _
       ] ->
       T.require
         (title = "Ordinary favorite" && block_title = "Authoritative block")
         "membership title leaked"
     | _ -> Alcotest.fail "favorite target kinds were lost");
    let expected =
      match
        Database.get_blocks pinned [ T.authoritative_block_uuid ]
        |> T.require_ok ~behavior
      with
      | [ Present_block { revision; _ } ] ->
        Database.write_precondition
          ~blocks:[ T.authoritative_block_uuid, revision ]
          ~pages:[]
          ~scopes:[]
        |> T.require_ok ~behavior
      | _ -> Alcotest.fail "favorite block fixture missing"
    in
    ignore
      (T.commit_mutation
         database
         ~expected
         (Save_block
            { mutation_id = T.mutation_uuid 980
            ; block = T.authoritative_block_uuid
            ; title = "Local favorite title"
            })
         ~behavior);
    with_snapshot (fun latest ->
      (match Database.get_favorites latest ~limit:1 ~cursor:first.next_cursor with
       | Error Stale_read_cursor -> ()
       | _ -> Alcotest.fail "favorite cursor mixed projections");
      T.require
        (List.exists
           (fun (i : favorite_item) ->
              match i.target with
              | Favorite_block { title = "Local favorite title"; _ } -> true
              | _ -> false)
           (all latest))
        "favorites missed overlay title");
    T.require (all pinned = items) "pinned favorites changed with overlay";
    apply 4 [ add 98 "logseq.property/deleted-at" (Int 123) ];
    with_snapshot (fun latest ->
      Alcotest.(check (list string))
        "recycled page filtered"
        [ Graph.Uuid.to_string (id 2) ]
        (memberships (all latest)));
    apply
      5
      [ Transit.Array
          [ Keyword "db/retract"
          ; lookup (id 98)
          ; Keyword "logseq.property/deleted-at"
          ; Int 123
          ]
      ; add 1 "block/link" (lookup T.authoritative_block_uuid)
      ; add 2 "block/link" (lookup (id 98))
      ; add 3 "block/order" (String "Zz")
      ];
    with_snapshot (fun latest ->
      Alcotest.(check (list string))
        "link rewrites and reordered memberships"
        (List.map (fun n -> Graph.Uuid.to_string (id n)) [ 3; 1; 2 ])
        (memberships (all latest)));
    apply
      6
      [ Transit.Array
          [ Keyword "db/add"
          ; lookup T.page_uuid
          ; Keyword "logseq.property/deleted-at"
          ; Int 456
          ]
      ];
    with_snapshot (fun latest ->
      Alcotest.(check (list string))
        "ancestor recycling filters block target"
        (List.map (fun n -> Graph.Uuid.to_string (id n)) [ 3; 2 ])
        (memberships (all latest))));
  with_snapshot (fun before ->
    let cursor = (read before 1 None).next_cursor in
    apply 7 [ add 1 "block/link" (lookup (id 98)) ];
    with_snapshot (fun after ->
      T.require
        (Database.snapshot_version before <> Database.snapshot_version after)
        "link-only transaction did not advance the logical projection";
      match Database.get_favorites after ~limit:1 ~cursor with
      | Error Stale_read_cursor -> ()
      | _ -> Alcotest.fail "link-only rewrite accepted stale favorite cursor"));
  apply 8 (List.init 10_001 (fun n -> add (1000 + n) "block/parent" (lookup (id 99))));
  with_snapshot (fun snapshot ->
    match Database.get_favorites snapshot ~limit:1 ~cursor:None with
    | Error Read_limit_exceeded -> ()
    | _ -> Alcotest.fail "malformed memberships escaped the structural scan budget");
  let released = Database.current_snapshot database |> T.require_ok ~behavior in
  Database.release_snapshot released;
  match Database.get_favorites released ~limit:1 ~cursor:None with
  | Error Snapshot_released -> ()
  | _ -> Alcotest.fail "released favorites snapshot accepted"
;;

let cases =
  [ T.database_case
      "favorites resolve order, filtering, and snapshot consistency"
      favorites_resolve_order_filter_and_snapshot
  ; T.database_case
      "page-tree preserves valid windows and snapshots"
      page_tree_preserves_valid_windows_and_snapshots
  ; T.snapshot_case "journal offsets are obsolete" journals_reject_legacy_offsets
  ; T.database_case
      "indexed journals preserve selection and exact hydration"
      indexed_journals_preserve_selection
  ; T.snapshot_case
      "one lease pins one authoritative/outbox/version tuple"
      snapshot_is_coherent
  ; T.snapshot_case
      "UUID page lookups preserve order and typed missing values"
      explicit_pages_preserve_order
  ; T.snapshot_case
      "authoritative block projects through UUID and structure reads"
      authoritative_block_is_projected_by_uuid_and_structure
  ; T.snapshot_case
      "page lookup preserves kind, tags, and recycle metadata"
      page_lookup_preserves_kind_tags_and_recycle_metadata
  ; T.database_case
      "point reads preserve property summaries"
      point_reads_preserve_property_summaries
  ; T.snapshot_case
      "empty parent retains discoverable children scope"
      empty_children_retain_scope
  ; T.snapshot_case
      "page-tree result includes maximum depth"
      page_tree_result_includes_depth
  ; T.database_case
      "reads started after release fail with Snapshot_released"
      released_snapshot_rejects_new_reads
  ; T.snapshot_case
      "fixed-snapshot cursor is deterministic and projection-bound"
      fixed_snapshot_cursor_is_projection_bound
  ; T.database_case
      "journal cursor paginates and is snapshot-bound"
      journal_cursor_is_snapshot_bound_and_paginates
  ; T.database_case
      "structure cursors reuse offsets across request shapes and reject projections"
      structure_cursors_accept_request_shape_reuse_and_reject_projection
  ; T.snapshot_case
      "malformed and out-of-range cursors fail closed"
      malformed_and_out_of_range_cursors_are_rejected
  ; T.snapshot_case
      "page limits are enforced before pagination"
      page_limits_are_enforced_before_pagination
  ; Alcotest.test_case
      "continuation beyond 10,000 fails the whole page"
      `Quick
      continuation_above_maximum_offset_fails_the_page
  ; T.database_case
      "pinned snapshot retains an immutable optimistic outbox root"
      pinned_snapshot_keeps_optimistic_outbox_root
  ; T.snapshot_case
      "graph info exposes UUID logical version and no basis"
      graph_info_uses_uuid_and_no_basis
  ; T.snapshot_case
      "admission inspection is administrative"
      admission_is_not_snapshot_versioned
  ]
;;

let () = Alcotest.run "logseq_overlay_db reads" [ "public reads", cases ]
