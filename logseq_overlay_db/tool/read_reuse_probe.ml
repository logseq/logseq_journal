module D = Logseq_overlay_db.Database
module T = Logseq_overlay_db.Types
module G = Logseq_db_types.Graph_types
module A = Logseq_db_storage.Audit_datascript
module F = Fixture_generator

let require b label = if not b then failwith label

module S = Logseq_db_storage.Logseq_sqlite_storage

let ok label = function
  | Ok x -> x
  | Error _ -> failwith label
;;

let uuid x = G.Uuid.of_string x |> ok "uuid"
let phase = ref "setup"
let allocated_work = ref 0.

let measure name f =
  A.reset ();
  let allocated = Gc.allocated_bytes () in
  let t = Unix.gettimeofday () in
  let x = f () in
  allocated_work := Gc.allocated_bytes () -. allocated;
  Printf.printf
    "%s\n%!"
    (Yojson.Safe.to_string
       (`Assoc
           [ "scenario", `String !phase
           ; "api", `String name
           ; "ms", `Float ((Unix.gettimeofday () -. t) *. 1000.)
           ; "allocated_bytes", `Float (Gc.allocated_bytes () -. allocated)
           ; "metrics", A.json ()
           ]));
  x
;;

let run name f =
  let result = measure name (fun () -> f () |> ok name) in
  if
    String.starts_with ~prefix:"get_" name
    || String.starts_with ~prefix:"commit_local/" name
  then (
    let digest =
      Marshal.to_string result [ Marshal.No_sharing ] |> Digest.string |> Digest.to_hex
    in
    Printf.printf
      "%s\n%!"
      (Yojson.Safe.to_string
         (`Assoc [ "result", `String name; "digest", `String digest ])));
  A.assert_released ();
  result
;;

let deps () =
  D.dependencies
    ~epoch_ms:(fun () -> 1788739200000L)
    ~monotonic_ns:(fun () -> 0L)
    ~limits:
      T.
        { response_budget_bytes = 8 * 1024 * 1024
        ; outbox_max_records = 4096
        ; outbox_max_bytes = 32 * 1024 * 1024
        ; change_max_items = 4096
        ; change_max_bytes = 8 * 1024 * 1024
        ; dispatcher_capacity = 128
        ; wire_batch_max_bytes = 8 * 1024 * 1024
        }
;;

let page = uuid "10000000-0000-4000-8000-000000000001"
let wide = uuid "10000000-0000-4000-8000-000000000002"
let block = F.block_uuid 99990
let mid i = F.mutation_uuid (10000 + i)

let snap db f =
  let s = D.current_snapshot db |> ok "snap" in
  Fun.protect ~finally:(fun () -> D.release_snapshot s) (fun () -> f s)
;;

let empty () = D.write_precondition ~blocks:[] ~pages:[] ~scopes:[] |> ok "empty"

let block_pre db b =
  snap db (fun s ->
    match D.get_blocks s [ b ] |> ok "get revision" with
    | [ T.Present_block { revision; _ } ] ->
      D.write_precondition ~blocks:[ b, revision ] ~pages:[] ~scopes:[] |> ok "pre"
    | _ -> failwith "missing pre block")
;;

let insert_pre db p =
  snap db (fun s ->
    let rev =
      match D.get_pages s [ p ] |> ok "page revision" with
      | [ T.Present_page { revision; _ } ] -> revision
      | _ -> failwith "page"
    in
    match
      D.get_structure s (T.Children { parent = p; limit = 1; cursor = None })
      |> ok "children revision"
    with
    | T.Children_result { revision_scope; scope_revision; _ } ->
      D.write_precondition
        ~blocks:[]
        ~pages:[ p, rev ]
        ~scopes:[ revision_scope, scope_revision ]
      |> ok "insert pre"
    | _ -> failwith "children")
;;

let commit db name expected mutation =
  run ("commit_local/" ^ name) (fun () -> D.commit_local db ~expected mutation)
;;

let token db = D.inspect_sync db |> ok "sync" |> T.sync_view_token

let cursor n =
  T.Server_cursor.of_string ("server-cursor:v1:" ^ string_of_int n) |> ok "cursor"
;;

let authoritative db n ops =
  let wire =
    Transit_native.Transit.Json.to_string
      ~mode:Transit_native.Transit.Json.Verbose
      (Transit_core.Json.Array ops)
    |> T.encoded_transaction_of_string ~maximum_bytes:(8 * 1024 * 1024)
    |> ok "wire"
  in
  let batch =
    T.authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:(8 * 1024 * 1024)
      ~transactions:[ T.authoritative_transaction ~cursor:(cursor n) ~transaction:wire ]
      ~through:(cursor n)
      ~checksum:None
    |> ok "batch"
  in
  let expected = token db in
  let prep, crypto =
    run "begin_authoritative" (fun () -> D.begin_authoritative db ~expected batch)
  in
  let decrypted =
    Option.map
      (fun r ->
         let vs =
           measure "unprotection_ciphertexts" (fun () -> D.unprotection_ciphertexts r)
         in
         ( r
         , List.map
             (fun (id, v) ->
                ( id
                , if String.starts_with ~prefix:"encrypted:" v
                  then String.sub v 10 (String.length v - 10)
                  else v ))
             vs ))
      crypto
  in
  run "apply_authoritative" (fun () -> D.apply_authoritative db prep ~decrypted)
;;

let remote_add b attr v =
  let open Transit_core.Json in
  Array
    [ Keyword "db/add"
    ; Array [ Keyword "block/uuid"; Uuid (G.Uuid.to_string b) ]
    ; Keyword attr
    ; v
    ]
;;

let failures = ref []

let gate label condition =
  if (not condition) && Sys.argv.(2) <> "plain" then failures := label :: !failures
;;

let calls key = fst (A.get key)

let metadata_gate name =
  gate (name ^ ": ident enumeration") (calls "datoms:Aevt:*:db/ident" <= 1);
  A.logical_counts ()
  |> List.iter (fun (key, (n, _)) ->
    if String.starts_with ~prefix:"definition:" key then gate (name ^ ": " ^ key) (n <= 1))
;;

let block_gate name =
  metadata_gate name;
  A.logical_counts ()
  |> List.iter (fun (key, (n, _)) ->
    if String.starts_with ~prefix:"logical_block:" key
    then gate (name ^ ": " ^ key) (n <= 1))
;;

let get_pages db s ids =
  let first = run "get_pages/64" (fun () -> D.get_pages s ids) in
  metadata_gate "get_pages";
  let counts = A.logical_counts () in
  let second = run "get_pages/64-repeat" (fun () -> D.get_pages s ids) in
  require (first = second) "repeated page results";
  gate "page contexts must not survive calls" (counts = A.logical_counts ());
  ignore db
;;

let submit db ids =
  let prep, crypto =
    D.begin_outbox_transition db ~expected:(token db) (T.Submit_group ids)
    |> ok "submit prepare"
  in
  let encrypted = Option.map (fun r -> r, D.protection_plaintexts r) crypto in
  let result = D.apply_outbox_transition db prep ~encrypted |> ok "submit apply" in
  let wires =
    Option.get result.T.submission_batch
    |> T.submission_batch_wires
    |> List.map T.submission_wire_protected_transaction
  in
  Printf.printf
    "%s\n%!"
    (Yojson.Safe.to_string
       (`Assoc [ "submitted_transactions", `List (List.map (fun s -> `String s) wires) ]))
;;

let capture_transactions db ids =
  let preparation, crypto =
    D.begin_outbox_transition db ~expected:(token db) (T.Submit_group ids)
    |> ok "capture preparation"
  in
  let plaintexts = Option.fold ~none:[] ~some:D.protection_plaintexts crypto in
  A.assert_released ();
  Printf.printf
    "%s\n%!"
    (Yojson.Safe.to_string
       (`Assoc
           [ "prepared_plaintexts", `List (List.map (fun (_, s) -> `String s) plaintexts)
           ]));
  ignore (Sys.opaque_identity preparation)
;;

let rich_properties db =
  let open Transit_core.Json in
  let add entity attr value =
    Array [ Keyword "db/add"; Int entity; Keyword attr; value ]
  in
  let definition n ident kind =
    [ add n "db/ident" (Keyword ident)
    ; add n "block/uuid" (Uuid (G.Uuid.to_string (mid n)))
    ; add n "block/title" (String ident)
    ; add n "block/tags" (Array [ Keyword "db/ident"; Keyword "logseq.class/Property" ])
    ; add n "logseq.property/type" (Keyword kind)
    ]
  in
  let map label =
    Map
      [ String "label", String label
      ; String "items", Array [ Uuid (G.Uuid.to_string page); Int 7 ]
      ]
  in
  ignore
    (authoritative
       db
       3
       (definition 300001 "test.property/read-map" "map"
        @ definition 300002 "test.property/read-collection" "collection"
        @ [ remote_add page "test.property/read-map" (map "first")
          ; remote_add wide "test.property/read-map" (map "second")
          ; remote_add
              page
              "test.property/read-collection"
              (Array [ String "first"; Uuid (G.Uuid.to_string page) ])
          ; remote_add
              wide
              "test.property/read-collection"
              (Array [ String "second"; Uuid (G.Uuid.to_string wide) ])
          ]));
  snap db (fun s ->
    let values =
      run "get_pages/rich-properties" (fun () -> D.get_pages s [ page; wide; page ])
    in
    metadata_gate "rich properties";
    match values with
    | [ T.Present_page { value = a; _ }; T.Present_page { value = b; _ }; again ] ->
      let prop (p : T.page_record) ident =
        List.find (fun (v : G.property_summary) -> v.ident = ident) p.page.properties
      in
      let map_a = prop a "test.property/read-map"
      and map_b = prop b "test.property/read-map" in
      require
        (map_a.values <> map_b.values && again = List.hd values)
        "rich property values leaked";
      (match map_a.values with
       | [ G.Map_value _ ] -> ()
       | _ -> failwith "map classification");
      (match (prop a "test.property/read-collection").values with
       | [ G.Collection_value _ ] -> ()
       | _ -> failwith "collection classification")
    | _ -> failwith "rich property pages")
;;

let shadow_insert db =
  let target = F.block_uuid 30 in
  ignore
    (commit
       db
       "Save_block/shadow-setup"
       (block_pre db target)
       (T.Save_block { mutation_id = mid 20; block = target; title = "Shadow title" }));
  submit db [ mid 20 ];
  let expected = insert_pre db page in
  ignore
    (commit
       db
       "Insert_blocks/present-dependency-shadow"
       expected
       (T.Insert_blocks
          { mutation_id = mid 22
          ; parent = page
          ; tree = T.{ uuid = mid 501; title = "Before shadow removal"; children = [] }
          }));
  gate "present shadows need no full sibling payload" (calls "datoms:Eavt:entity:*" <= 2);
  let open Transit_core.Json in
  ignore
    (authoritative
       db
       4
       [ Array
           [ Keyword "db/retractEntity"
           ; Array [ Keyword "block/uuid"; Uuid (G.Uuid.to_string target) ]
           ]
       ]);
  let expected = insert_pre db page in
  ignore
    (commit
       db
       "Insert_blocks/dependency-shadow"
       expected
       (T.Insert_blocks
          { mutation_id = mid 21
          ; parent = page
          ; tree = T.{ uuid = mid 500; title = "After shadow"; children = [] }
          }));
  metadata_gate "shadow insert";
  gate "shadow insertion scans once" (calls "datoms:Avet:*:block/parent:value" = 1);
  snap db (fun s ->
    match D.get_blocks s [ target ] |> ok "shadow visibility" with
    | [ T.Present_block { value; _ } ] ->
      require (value.block.title = "Shadow title") "lost shadow"
    | _ -> failwith "authoritative miss hid dependency shadow")
;;

let deletion_comments db =
  let open Transit_core.Json in
  let root = F.block_uuid 40001
  and area = F.block_uuid 40002
  and child = F.block_uuid 40003
  and source = F.block_uuid 40004 in
  let lookup id = Array [ Keyword "block/uuid"; Uuid (G.Uuid.to_string id) ] in
  ignore
    (authoritative
       db
       5
       [ remote_add root "block/title" (String "Comment target")
       ; remote_add
           area
           "block/tags"
           (Array [ Keyword "db/ident"; Keyword "logseq.class/Comments" ])
       ; remote_add area "logseq.property.comments/blocks" (lookup root)
       ; remote_add child "block/parent" (lookup area)
       ; remote_add
           source
           "block/title"
           (String ("See ((" ^ G.Uuid.to_string root ^ "))"))
       ; remote_add source "block/refs" (lookup root)
       ]);
  let expected = block_pre db root in
  ignore
    (commit
       db
       "Delete_blocks/comments-and-incoming-reference"
       expected
       (T.Delete_blocks { mutation_id = mid 30; root }));
  block_gate "comments deletion";
  snap db (fun s ->
    match D.get_blocks s [ root; area; child; source ] |> ok "comments footprint" with
    | [ T.Missing_block _
      ; T.Missing_block _
      ; T.Missing_block _
      ; T.Present_block { value; _ }
      ] ->
      require
        (value.block.title = "See Comment target" && value.block.refs = [])
        "incoming reference rewrite"
    | _ -> failwith "comments frontier changed")
;;

let structural_eligibility db =
  let open Transit_core.Json in
  let add e a v = Array [ Keyword "db/add"; Int e; Keyword a; v ] in
  let parent = Array [ Keyword "block/uuid"; Uuid (G.Uuid.to_string page) ] in
  ignore
    (authoritative
       db
       6
       [ add 300010 "block/uuid" (Uuid (G.Uuid.to_string (mid 601)))
       ; add 300010 "block/parent" parent
       ; add 300010 "block/order" (String "b00")
       ; add 300020 "block/parent" parent
       ; add 300020 "block/order" (String "z0")
       ; add 300030 "block/uuid" (Uuid (G.Uuid.to_string (mid 602)))
       ; add 300030 "block/parent" parent
       ]);
  let expected = insert_pre db page in
  ignore
    (commit
       db
       "Insert_blocks/structural-eligibility"
       expected
       (T.Insert_blocks
          { mutation_id = mid 31
          ; parent = page
          ; tree = T.{ uuid = mid 603; title = "After incomplete sibling"; children = [] }
          }));
  metadata_gate "structural eligibility";
  gate "structural eligibility one scan" (calls "datoms:Avet:*:block/parent:value" = 1);
  snap db (fun s ->
    match D.get_blocks s [ mid 603; mid 601 ] |> ok "eligibility orders" with
    | [ T.Present_block { value; _ }; T.Missing_block _ ] ->
      require (value.block.order = "b01") "structural eligibility tightened"
    | _ -> failwith "incomplete sibling hydration")
;;

let selected db =
  snap db (fun s ->
    ignore (run "get_blocks/empty" (fun () -> D.get_blocks s []));
    gate "empty block datoms" (A.logical_counts () = []);
    List.iter
      (fun (name, ids) ->
         let first = run name (fun () -> D.get_blocks s ids) in
         block_gate name;
         let counts = A.logical_counts () in
         let second = run (name ^ "-repeat") (fun () -> D.get_blocks s ids) in
         require (first = second) "repeat block results";
         gate "block contexts must not survive calls" (counts = A.logical_counts ()))
      [ "get_blocks/1", [ block ]
      ; "get_blocks/64", List.init 64 F.block_uuid
      ; "get_blocks/duplicates", [ block; mid 9000; block; mid 9000 ]
      ];
    get_pages
      db
      s
      (List.init 64 (fun n -> uuid (Printf.sprintf "10000000-0000-4000-8001-%012d" n))));
  let old = D.current_snapshot db |> ok "old snapshot" in
  let root = mid 200 in
  ignore (run "get_blocks/before-insert" (fun () -> D.get_blocks old [ root; root ]));
  let tree =
    T.
      { uuid = root
      ; title = "Read reuse root"
      ; children =
          List.init 9 (fun i ->
            { uuid = mid (201 + i); title = "Read reuse child"; children = [] })
      }
  in
  let expected = insert_pre db page in
  ignore
    (commit
       db
       "Insert_blocks/10"
       expected
       (T.Insert_blocks { mutation_id = mid 5; tree; parent = page }));
  metadata_gate "insert";
  gate "insert one sibling enumeration" (calls "datoms:Avet:*:block/parent:value" = 1);
  gate "insert no full sibling payload scan" (calls "seek:Eavt:entity:*" = 0);
  snap db (fun s ->
    match D.get_blocks s [ root ] |> ok "insert visibility" with
    | [ T.Present_block _ ] -> ()
    | _ -> failwith "cached missing escaped");
  (match D.get_blocks old [ root ] |> ok "old snapshot" with
   | [ T.Missing_block _ ] -> ()
   | _ -> failwith "old snapshot changed");
  let expected = block_pre db root in
  ignore
    (commit
       db
       "Delete_blocks/10-overlay"
       expected
       (T.Delete_blocks { mutation_id = mid 6; root }));
  block_gate "overlay delete";
  capture_transactions db [ mid 5 ];
  let expected =
    snap db (fun s ->
      let rev =
        match D.get_pages s [ page ] |> ok "extra page pre" with
        | [ T.Present_page { revision; _ } ] -> revision
        | _ -> failwith "extra page"
      in
      let scopes =
        List.map
          (fun parent ->
             match
               D.get_structure s (T.Children { parent; limit = 1; cursor = None })
               |> ok "extra scope"
             with
             | T.Children_result { revision_scope; scope_revision; _ } ->
               revision_scope, scope_revision
             | _ -> failwith "scope")
          [ wide; page ]
      in
      D.write_precondition ~blocks:[] ~pages:[ page, rev ] ~scopes |> ok "extra pre")
  in
  let tree = T.{ uuid = mid 300; title = "Additional scopes"; children = [] } in
  ignore
    (commit
       db
       "Insert_blocks/additional-scopes"
       expected
       (T.Insert_blocks { mutation_id = mid 8; tree; parent = page }));
  metadata_gate "insert extra scopes";
  if !allocated_work >= 400_000_000.
  then
    Printf.printf
      "%s\n%!"
      (Yojson.Safe.to_string
         (`Assoc
             [ ( "allocation_tradeoff"
               , `String "wide admission exceeds the measured baseline allocation range" )
             ; "allocated_bytes", `Float !allocated_work
             ]));
  gate
    "insert extra scopes share target scan"
    (calls "datoms:Avet:*:block/parent:value" = 2);
  let stale =
    measure "commit_local/stale-children" (fun () ->
      D.commit_local
        db
        ~expected
        (T.Insert_blocks
           { mutation_id = mid 9; tree = { tree with uuid = mid 301 }; parent = page }))
  in
  (match stale with
   | Error T.Target_precondition_conflict -> ()
   | _ -> failwith "stale children admitted");
  let target = F.block_uuid 99980 in
  let expected = block_pre db target in
  ignore
    (commit
       db
       "Delete_blocks/1-authoritative"
       expected
       (T.Delete_blocks { mutation_id = mid 7; root = target }));
  block_gate "authoritative delete";
  capture_transactions db [ mid 7 ];
  let root = F.block_uuid 1000 in
  let descendants = List.init 9 (fun i -> F.block_uuid ((i + 2) * 1000)) in
  ignore
    (authoritative
       db
       1
       (List.map
          (fun child ->
             remote_add
               child
               "block/parent"
               (Transit_core.Json.Array
                  [ Keyword "block/uuid"; Uuid (G.Uuid.to_string root) ]))
          descendants));
  let expected = block_pre db root in
  ignore
    (commit
       db
       "Delete_blocks/10-authoritative-interleaved"
       expected
       (T.Delete_blocks { mutation_id = mid 10; root }));
  block_gate "authoritative tree delete";
  let old_pages = D.get_pages old [ page; wide; page ] |> ok "old pages" in
  ignore
    (authoritative
       db
       2
       [ remote_add page "block/title" (Transit_core.Json.String "Changed page title")
       ; remote_add page "logseq.property/public?" (Bool true)
       ; remote_add wide "logseq.property/public?" (Bool false)
       ]);
  snap db (fun s ->
    let ids = [ page; wide; page; mid 9000; mid 9000 ] in
    let pages =
      run "get_pages/distinct-values-and-misses" (fun () -> D.get_pages s ids)
    in
    metadata_gate "distinct values";
    let property (p : T.page_record) =
      List.find_map
        (fun (d : G.property_summary) ->
           if d.ident = "logseq.property/public?" then Some d.values else None)
        p.T.page.properties
    in
    (match pages with
     | [ T.Present_page { value = a; _ }
       ; T.Present_page { value = b; _ }
       ; again
       ; T.Missing_page _
       ; missing
       ] ->
       require
         (a.page.title = "Changed page title"
          && property a = Some [ G.Checkbox_value true ]
          && property b = Some [ G.Checkbox_value false ])
         "page values leaked";
       require
         (again = List.hd pages && missing = List.nth pages 3)
         "duplicate page ordering"
     | _ -> failwith "page batch shape");
    let left, right =
      Eio.Fiber.pair
        (fun () -> D.get_pages s ids |> ok "concurrent left")
        (fun () -> D.get_pages s ids |> ok "concurrent right")
    in
    require (left = pages && right = pages) "concurrent results";
    match D.get_blocks s [ F.block_uuid 1 ] |> ok "rendered title" with
    | [ T.Present_block { value; _ } ] ->
      require
        (value.rendered_page_title = "Changed page title")
        "stale rendered page title"
    | _ -> failwith "title block");
  require
    (D.get_pages old [ page; wide; page ] |> ok "old page repeat" = old_pages)
    "old page snapshot changed";
  rich_properties db;
  shadow_insert db;
  deletion_comments db;
  structural_eligibility db;
  D.release_snapshot old;
  (match D.get_blocks old [] with
   | Error T.Snapshot_released -> ()
   | _ -> failwith "empty released snapshot");
  let s = D.current_snapshot db |> ok "closing snapshot" in
  D.close db |> ok "close";
  (match D.get_blocks s [] with
   | Error T.Database_closed | Error T.Snapshot_generation_invalidated -> ()
   | _ -> failwith "empty closed database");
  D.release_snapshot s
;;

let () =
  let out = Sys.argv.(1) in
  let graph, path =
    F.seed_mirror ~application_support_directory:out ~block_count:100000
  in
  let inspection =
    D.inspect_mirror ~application_support_directory:out ~graph_id:graph |> ok "inspect"
  in
  let connection = S.open_database path |> ok "fixture identity open" in
  let database = S.restore_database connection |> ok "fixture identity restore" in
  let hash, count =
    Datascript.datoms database Datascript.Eavt ()
    |> Seq.fold_left
         (fun (hash, count) datom ->
            ( Digestif.SHA256.feed_string
                hash
                (Marshal.to_string datom [ Marshal.No_sharing ])
            , count + 1 ))
         (Digestif.SHA256.empty, 0)
  in
  Printf.printf
    "%s\n%!"
    (Yojson.Safe.to_string
       (`Assoc
           [ "fixture_datoms", `Int count
           ; "fixture_sha256", `String (Digestif.SHA256.get hash |> Digestif.SHA256.to_hex)
           ]));
  S.close (S.connection_callbacks connection) |> ok "fixture identity close";
  phase := "100000-blocks-empty-outbox";
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let db =
        D.open_ ~sw (deps () |> ok "dependencies") inspection ~graph_name:"Read reuse"
        |> ok "open"
      in
      selected db));
  Printf.printf
    "%s\n%!"
    (Yojson.Safe.to_string
       (`Assoc [ "failed_gates", `List (List.rev_map (fun s -> `String s) !failures) ]));
  if !failures <> [] && Sys.argv.(2) = "check" then exit 1
;;
