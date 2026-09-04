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

let journal_result_has_dedicated_scope _database snapshot =
  let result =
    Database.get_journals snapshot ~limit:32 ~cursor:None
    |> T.require_ok ~behavior:"journal index result"
  in
  match result.revision_scope with
  | Journal_index_revision -> ()
  | Children_revision _ | Page_tree_revision _ ->
    Alcotest.fail "journal result reused a non-journal structure scope"
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

let page_tree_scope_includes_depth _database snapshot =
  match
    Database.get_structure
      snapshot
      (Page_tree { page = T.page_uuid; maximum_depth = 2; limit = 200; cursor = None })
    |> T.require_ok ~behavior:"page-tree depth scope"
  with
  | Page_tree_result
      { page
      ; maximum_depth = 2
      ; revision_scope = Page_tree_revision { page = scoped; maximum_depth = 2 }
      ; _
      }
    when Graph.Uuid.equal page T.page_uuid && Graph.Uuid.equal scoped T.page_uuid -> ()
  | _ -> Alcotest.fail "page-tree result lost its maximum-depth revision scope"
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
    let journals =
      Database.get_journals snapshot ~limit:1 ~cursor:None |> T.require_ok ~behavior
    in
    Database.release_snapshot snapshot;
    let expected =
      Database.write_precondition
        ~blocks:[]
        ~pages:[ uuid, revision ]
        ~scopes:[ journals.revision_scope, journals.scope_revision ]
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
    Database.get_journals snapshot ~limit:1 ~cursor:None |> T.require_ok ~behavior
  in
  let cursor =
    match first.items, first.next_cursor with
    | [ item ], Some cursor ->
      T.require (item.journal_day = 20260902) "journal order is not descending";
      cursor
    | _ -> Alcotest.fail "first journal page did not return one item and a cursor"
  in
  let second =
    Database.get_journals snapshot ~limit:1 ~cursor:(Some cursor)
    |> T.require_ok ~behavior
  in
  (match second.items with
   | [ item ] -> T.require (item.journal_day = 20260901) "cursor skipped journal"
   | _ -> Alcotest.fail "second journal page has the wrong cardinality");
  Database.release_snapshot snapshot;
  create 502 third_uuid 20260903;
  let newer = Database.current_snapshot database |> T.require_ok ~behavior in
  (match Database.get_journals newer ~limit:1 ~cursor:(Some cursor) with
   | Error (Invalid_read_request _) -> ()
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
   | Error (Invalid_read_request _) -> ()
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
    Database.get_journals snapshot ~limit:1 ~cursor:(Some (cursor value))
    |> require_invalid_read ("malformed cursor " ^ value));
  let boundary =
    Database.get_journals
      snapshot
      ~limit:1
      ~cursor:(Some (version_two_cursor snapshot 10_000))
    |> T.require_ok ~behavior:"10,000 cursor offset boundary"
  in
  T.require
    (boundary.items = [] && Option.is_none boundary.next_cursor)
    "the exact 10,000 cursor boundary did not behave as a valid offset"
;;

let page_limits_are_enforced_before_pagination _database snapshot =
  let children limit =
    Database.get_structure
      snapshot
      (Children { parent = T.page_uuid; limit; cursor = None })
  in
  Database.get_journals snapshot ~limit:0 ~cursor:None
  |> require_invalid_read "zero journal page limit";
  Database.get_journals snapshot ~limit:201 ~cursor:None
  |> require_invalid_read "oversized journal page limit";
  children 0 |> require_invalid_read "zero children page limit";
  children 201 |> require_invalid_read "oversized children page limit";
  children Int.max_int |> require_invalid_read "overflowing children page limit";
  ignore
    (Database.get_journals snapshot ~limit:200 ~cursor:None
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

let cases =
  [ T.snapshot_case
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
      "journal listing carries Journal_index_revision"
      journal_result_has_dedicated_scope
  ; T.snapshot_case
      "empty parent retains discoverable children scope"
      empty_children_retain_scope
  ; T.snapshot_case
      "page-tree revision scope includes maximum depth"
      page_tree_scope_includes_depth
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
