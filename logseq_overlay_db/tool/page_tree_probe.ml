module D = Logseq_overlay_db.Database
module T = Logseq_overlay_db.Types
module G = Logseq_db_types.Graph_types
module A = Logseq_db_storage.Audit_datascript
module Storage = Logseq_db_storage.Logseq_sqlite_storage

let ok label = function
  | Ok value -> value
  | Error _ -> failwith label
;;

let require condition label = if not condition then failwith label
let uuid text = G.Uuid.of_string text |> ok "UUID"
let block_uuid n = uuid (Printf.sprintf "81000000-0000-4000-8000-%012d" n)

let dependencies () =
  let limits : T.capability_limits =
    { response_budget_bytes = 8 * 1024 * 1024
    ; outbox_max_records = 4096
    ; outbox_max_bytes = 8 * 1024 * 1024
    ; change_max_items = 4096
    ; change_max_bytes = 8 * 1024 * 1024
    ; dispatcher_capacity = 128
    ; wire_batch_max_bytes = 8 * 1024 * 1024
    }
  in
  D.dependencies
    ~epoch_ms:(fun () -> 1_788_220_800_000L)
    ~monotonic_ns:(fun () -> 0L)
    ~limits
  |> ok "dependencies"
;;

let with_database support graph_id f =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let inspection =
        D.inspect_mirror ~application_support_directory:support ~graph_id |> ok "inspect"
      in
      let db =
        D.open_ ~sw (dependencies ()) inspection ~graph_name:"Journal pagination audit"
        |> ok "open"
      in
      Fun.protect ~finally:(fun () -> ignore (D.close db |> ok "close")) (fun () -> f db)))
;;

let rewrite_root path transform =
  let connection = Storage.open_database path |> ok "edge open" in
  let original = Storage.restore_database connection |> ok "edge restore" in
  let database = transform original in
  let callbacks = Storage.connection_callbacks connection in
  callbacks.begin_staging () |> ok "edge begin staging";
  Datascript.store ~storage:callbacks.storage database;
  let batch =
    callbacks.finish_staging
      None
      [ Datascript.Storage.tail_address, Datascript.Storage_tail [] ]
    |> ok "edge finish staging"
  in
  Storage.commit_batch callbacks batch |> ok "edge commit";
  Storage.close callbacks |> ok "edge close"
;;

let page = uuid "10000000-0000-4000-8000-000000000001"
let verify_access = ref false
let instrumented = ref true
let samples = ref []

let read snapshot page depth limit cursor =
  match
    D.get_structure snapshot (T.Page_tree { page; maximum_depth = depth; limit; cursor })
    |> ok "tree"
  with
  | T.Page_tree_result { items; next_cursor; _ } -> items, next_cursor
  | T.Children_result _ -> failwith "unexpected children"
;;

let measured name snapshot page depth limit cursor =
  A.reset ();
  let allocated = Gc.allocated_bytes () in
  let start = Unix.gettimeofday () in
  let items, next = read snapshot page depth limit cursor in
  let elapsed_ms = (Unix.gettimeofday () -. start) *. 1000. in
  let allocation_bytes = Gc.allocated_bytes () -. allocated in
  let metrics = A.json () in
  let calls key =
    match Hashtbl.find_opt A.metrics key with
    | Some (n, _) -> n
    | None -> 0
  in
  let datom_calls, datom_rows =
    Hashtbl.fold
      (fun k (c, r) (cs, rs) ->
         if
           List.exists
             (fun prefix -> String.starts_with ~prefix k)
             [ "datoms:"; "find:"; "seek:"; "rseek:" ]
         then cs + c, rs + r
         else cs, rs)
      A.metrics
      (0, 0)
  in
  let json =
    `Assoc
      [ "name", `String name
      ; "depth", `Int depth
      ; "limit", `Int limit
      ; "items", `Int (List.length items)
      ; "has_more", `Bool (Option.is_some next)
      ; "elapsed_ms", `Float elapsed_ms
      ; "allocation_bytes", `Float allocation_bytes
      ; "instrumented", `Bool !instrumented
      ; ("datom_calls", if !instrumented then `Int datom_calls else `Null)
      ; ("datom_rows", if !instrumented then `Int datom_rows else `Null)
      ; ("query_calls", if !instrumented then `Int (calls "query") else `Null)
      ; "metrics", metrics
      ]
  in
  print_endline (Yojson.Safe.to_string json);
  flush stdout;
  samples := (name, metrics) :: !samples;
  if !verify_access
  then (
    require
      (calls "logical_block_hydration" = List.length items)
      "hydrated outside selected window";
    require
      (calls "block_revision" = List.length items)
      "computed revisions outside selected window";
    require (calls "datoms:Aevt:*:db/ident" = 0) "global ident enumeration";
    require (calls "seek:Eavt:entity:*" = 0) "unrelated entity range scan");
  List.iter
    (fun (item : T.tree_member) ->
       match D.get_blocks snapshot [ item.block.block.uuid ] |> ok "point" with
       | [ T.Present_block { value; revision } ] ->
         require (value = item.block && revision = item.revision) "point equivalence"
       | _ -> failwith "missing selected block")
    items;
  items, next
;;

let audit support graph_id name page depth =
  List.iter
    (fun limit ->
       with_database support graph_id (fun database ->
         let snapshot = D.current_snapshot database |> ok "snapshot" in
         Fun.protect
           ~finally:(fun () -> D.release_snapshot snapshot)
           (fun () ->
              let tag = Printf.sprintf "%s:d%d:l%d" name depth limit in
              let _, next = measured (tag ^ ":cold") snapshot page depth limit None in
              ignore (measured (tag ^ ":warm") snapshot page depth limit None);
              Option.iter
                (fun c ->
                   ignore
                     (measured (tag ^ ":continuation") snapshot page depth limit (Some c)))
                next)))
    [ 1; 200 ]
;;

let seed support ~width ~deep ~unrelated ~branch_growth ~duplicate_facts =
  let graph_id, path =
    Fixture_generator.seed_mirror ~application_support_directory:support ~block_count:0
  in
  rewrite_root path (fun database ->
    let definitions =
      List.init 20 (fun n ->
        let ident = Printf.sprintf "audit.property/p%d" n in
        let e = Datascript.Temp_id ident in
        [ Datascript.Add (e, "db/ident", Keyword ident)
        ; Add (e, "block/uuid", Uuid (Printf.sprintf "83000000-0000-4000-8000-%012d" n))
        ; Add (e, "block/title", String ident)
        ; Add (e, "block/tags", Ref_to (Ident "logseq.class/Property"))
        ; Add (e, "logseq.property/type", Keyword "node")
        ; Add (e, "db/valueType", Keyword "db.type/ref")
        ; Add (e, "db/cardinality", Keyword "db.cardinality/one")
        ; Add (e, "db/index", Bool true)
        ])
      |> List.concat
    in
    let database = Datascript.db_with definitions database in
    let base = Datascript.datoms database Datascript.Eavt () |> List.of_seq in
    let tx = List.fold_left (fun t (d : Datascript.datom) -> max t d.tx) 0 base + 1 in
    let parent =
      (Datascript.find_datom
         database
         Datascript.Avet
         ~a:"block/uuid"
         ~v:(Uuid (G.Uuid.to_string page))
         ()
       |> Option.get)
        .e
    in
    let tag =
      (Datascript.find_datom
         database
         Datascript.Avet
         ~a:"db/ident"
         ~v:(Keyword "logseq.class/Tag")
         ()
       |> Option.get)
        .e
    in
    let d e a v = Datascript.{ e; a; v; tx; added = true } in
    let entity n = 100000 + (n * 4) in
    let node n p order =
      let e = entity n in
      [ d e "block/uuid" (Uuid (G.Uuid.to_string (block_uuid n)))
      ; d e "block/title" (String "Rich block")
      ; d e "block/parent" (Ref p)
      ; d e "block/page" (Ref parent)
      ; d e "block/order" (String order)
      ; d e "block/tags" (Ref tag)
      ]
      @ List.init 20 (fun p -> d e (Printf.sprintf "audit.property/p%d" p) (Ref tag))
    in
    let roots =
      List.init width (fun n -> node n parent (Printf.sprintf "a%08d" (n / 2)))
      |> List.concat
    in
    let descendants =
      List.init deep (fun n ->
        node (width + n) (if n = 0 then entity 0 else entity (width + n - 1)) "a0")
      |> List.concat
    in
    let extra =
      List.init branch_growth (fun n ->
        node (width + deep + n) (entity (width - 1)) (Printf.sprintf "a%08d" n))
      |> List.concat
    in
    let others =
      List.init unrelated (fun n ->
        let e = 100001 + (n * 4) in
        [ d e "block/uuid" (Uuid (Printf.sprintf "82000000-0000-4000-8000-%012d" n))
        ; d e "block/title" (String (String.make 2048 'x'))
        ; d e "block/name" (String (Printf.sprintf "unrelated %d" n))
        ])
      |> List.concat
    in
    let bad e fields = List.map (fun (a, v) -> d e a v) fields in
    let invalid =
      bad 900000 [ "block/parent", Ref parent; "block/order", String "a0" ]
      @ bad
          900001
          [ "block/uuid", Uuid "85000000-0000-4000-8000-000000000001"
          ; "block/parent", Ref parent
          ; "block/page", Ref parent
          ; "block/order", String "a0"
          ]
      @ bad
          900002
          [ "block/uuid", Uuid "85000000-0000-4000-8000-000000000002"
          ; "block/parent", Ref parent
          ; "block/page", Ref 990000
          ; "block/title", String "Invalid page reference"
          ; "block/order", String "a9"
          ]
    in
    Datascript.init_db
      ~schema:(Datascript.schema database)
      (base
       @ roots
       @ descendants
       @ extra
       @ others
       @ invalid
       @
       if duplicate_facts
       then
         List.map
           (fun (datom : Datascript.datom) -> { datom with e = datom.e + 1000000 })
           (roots @ descendants)
         @ List.filter
             (fun (datom : Datascript.datom) ->
                datom.e = entity 2 && datom.a = "block/parent")
             roots
       else []));
  graph_id, path
;;

let audit_local support graph_id =
  with_database support graph_id (fun database ->
    let local_page = uuid "86000000-0000-4000-8000-000000000001" in
    let root = uuid "86000000-0000-4000-8000-000000000002" in
    let child = uuid "86000000-0000-4000-8000-000000000003" in
    let grandchild = uuid "86000000-0000-4000-8000-000000000004" in
    let snapshot f =
      let s = D.current_snapshot database |> ok "local snapshot" in
      Fun.protect ~finally:(fun () -> D.release_snapshot s) (fun () -> f s)
    in
    let expected =
      snapshot (fun s ->
        let revision =
          match D.get_pages s [ local_page ] |> ok "missing local page" with
          | [ T.Missing_page { revision; _ } ] -> revision
          | _ -> failwith "local page exists"
        in
        D.write_precondition ~blocks:[] ~pages:[ local_page, revision ] ~scopes:[]
        |> ok "page guard")
    in
    ignore
      (D.commit_local
         database
         ~expected
         (T.Create_journal_page
            { mutation_id = Fixture_generator.mutation_uuid 9900
            ; page = local_page
            ; journal_day = 20260907
            ; title = "Logical local page"
            })
       |> ok "create page");
    let expected =
      snapshot (fun s ->
        let revision =
          match D.get_pages s [ local_page ] |> ok "local page" with
          | [ T.Present_page { revision; _ } ] -> revision
          | _ -> failwith "missing local page"
        in
        let scope, token =
          match
            D.get_structure
              s
              (T.Children { parent = local_page; limit = 1; cursor = None })
            |> ok "children"
          with
          | T.Children_result { revision_scope; scope_revision; _ } ->
            revision_scope, scope_revision
          | _ -> failwith "wrong children result"
        in
        D.write_precondition
          ~blocks:[]
          ~pages:[ local_page, revision ]
          ~scopes:[ scope, token ]
        |> ok "insert guard")
    in
    ignore
      (D.commit_local
         database
         ~expected
         (T.Insert_blocks
            { mutation_id = Fixture_generator.mutation_uuid 9901
            ; parent = local_page
            ; tree =
                { uuid = root
                ; title = "Local root"
                ; children =
                    [ { uuid = child
                      ; title = "Local child"
                      ; children =
                          [ { uuid = grandchild
                            ; title = "Local grandchild"
                            ; children = []
                            }
                          ]
                      }
                    ]
                }
            })
       |> ok "insert tree");
    snapshot (fun pinned ->
      let expected =
        let revision =
          match D.get_blocks pinned [ root ] |> ok "root" with
          | [ T.Present_block { revision; _ } ] -> revision
          | _ -> failwith "root missing"
        in
        D.write_precondition ~blocks:[ root, revision ] ~pages:[] ~scopes:[]
        |> ok "root guard"
      in
      ignore
        (D.commit_local
           database
           ~expected
           (T.Save_block
              { mutation_id = Fixture_generator.mutation_uuid 9902
              ; block = root
              ; title = "Saved local root"
              })
         |> ok "save");
      snapshot (fun current ->
        let items, next = measured "local:first-1" current local_page 64 1 None in
        require
          ((List.hd items).block.rendered_page_title = "Logical local page")
          "cached authoritative page title replaced local title";
        Option.iter
          (fun cursor ->
             ignore (measured "local:offset-1" current local_page 64 1 (Some cursor)))
          next;
        let all, _ = measured "local:all-200" current local_page 64 200 None in
        require (List.length all = 3) "nested local nodes missing";
        let revision = (List.hd all).revision in
        let scope, token =
          match
            D.get_structure
              current
              (T.Children { parent = local_page; limit = 1; cursor = None })
            |> ok "delete children"
          with
          | T.Children_result { revision_scope; scope_revision; _ } ->
            revision_scope, scope_revision
          | _ -> failwith "delete children"
        in
        let expected =
          D.write_precondition
            ~blocks:[ root, revision ]
            ~pages:[]
            ~scopes:[ scope, token ]
          |> ok "delete guard"
        in
        ignore
          (D.commit_local
             database
             ~expected
             (T.Delete_blocks { mutation_id = Fixture_generator.mutation_uuid 9903; root })
           |> ok "delete");
        snapshot (fun deleted ->
          let items, next = measured "local:deleted" deleted local_page 64 1 None in
          require (items = [] && next = None) "local tombstone consumes window");
        ignore (measured "local:snapshot-after-delete" current local_page 64 1 None));
      let old, _ = measured "local:snapshot-before-save" pinned local_page 64 1 None in
      require
        ((List.hd old).block.block.title = "Local root")
        "snapshot lost local effect root"))
;;

let audit_duplicate_facts directory =
  let support = Filename.concat directory "duplicates" in
  let graph_id, _ =
    seed support ~width:3 ~deep:3 ~unrelated:0 ~branch_growth:0 ~duplicate_facts:true
  in
  with_database support graph_id (fun database ->
    let snapshot = D.current_snapshot database |> ok "duplicate snapshot" in
    Fun.protect
      ~finally:(fun () -> D.release_snapshot snapshot)
      (fun () ->
         let items, next = measured "duplicates:all" snapshot page 64 200 None in
         require
           (List.length items = 5 && next = None)
           "duplicate identities or invalid parent fields changed tree cardinality";
         require
           (List.length
              (List.sort_uniq
                 G.Uuid.compare
                 (List.map (fun (item : T.tree_member) -> item.block.block.uuid) items))
            = 5)
           "duplicate UUIDs in tree response";
         ignore (measured "duplicates:first-1" snapshot page 64 1 None)))
;;

let () =
  let mode = Sys.argv.(1) in
  verify_access := mode = "verify";
  instrumented := mode <> "release";
  match Array.to_list Sys.argv |> List.tl |> List.tl with
  | [ "synthetic"; directory ] ->
    audit_duplicate_facts directory;
    List.iter
      (fun (name, width, deep, unrelated, growth) ->
         let support = Filename.concat directory name in
         let graph_id, _ =
           seed
             support
             ~width
             ~deep
             ~unrelated
             ~branch_growth:growth
             ~duplicate_facts:false
         in
         List.iter (audit support graph_id name page) [ 1; 64; 512 ];
         if name = "wide" then audit_local support graph_id)
      [ "narrow", 2, 300, 0, 0
      ; "wide", 400, 10, 0, 0
      ; "wide-unrelated", 400, 10, 5000, 0
      ; "wide-descendants", 400, 10, 0, 500
      ];
    if !verify_access
    then (
      let normalize = function
        | `Assoc fields ->
          `Assoc (List.sort compare (List.remove_assoc "sqlite_restore" fields))
        | x -> x
      in
      List.iter
        (fun suffix ->
           List.iter
             (fun other ->
                require
                  (normalize (List.assoc ("wide" ^ suffix) !samples)
                   = normalize (List.assoc (other ^ suffix) !samples))
                  ("unvisited growth affected prefix: " ^ other ^ suffix))
             [ "wide-unrelated"; "wide-descendants" ])
        [ ":d1:l1:warm"; ":d64:l1:warm"; ":d512:l1:warm" ])
  | [ "mirror"; support; graph_id ] ->
    let graph_id = uuid graph_id in
    let selected =
      with_database support graph_id (fun database ->
        let snapshot = D.current_snapshot database |> ok "snapshot" in
        let journals =
          D.get_journals
            snapshot
            ~from_day:0
            ~through_day:99999999
            ~limit:200
            ~cursor:None
          |> ok "journals"
        in
        let best =
          List.fold_left
            (fun (count, page) (j : T.journal_item) ->
               let items, _ = read snapshot j.page.page.uuid 64 200 None in
               if List.length items > count
               then List.length items, j.page.page.uuid
               else count, page)
            (0, (List.hd journals.items).page.page.uuid)
            journals.items
          |> snd
        in
        D.release_snapshot snapshot;
        best)
    in
    Printf.eprintf "mirror page %s\n%!" (G.Uuid.to_string selected);
    List.iter (audit support graph_id "mirror" selected) [ 1; 64 ]
  | _ -> failwith "expected MODE synthetic DIRECTORY or MODE mirror SUPPORT GRAPH_ID"
;;
