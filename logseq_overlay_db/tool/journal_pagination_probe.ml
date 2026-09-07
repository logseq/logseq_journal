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
let journal_uuid n = uuid (Printf.sprintf "81000000-0000-4000-8000-%012d" n)

let date n =
  if n < 32
  then 20260901
  else (
    let tm = Unix.gmtime (1_788_220_800. -. (float_of_int (n - 31) *. 86400.)) in
    ((tm.tm_year + 1900) * 10000) + ((tm.tm_mon + 1) * 100) + tm.tm_mday)
;;

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

let samples : (string * Yojson.Safe.t) list ref = ref []

let measured name snapshot ~limit ~cursor =
  A.reset ();
  let start = Unix.gettimeofday () in
  let result =
    D.get_journals snapshot ~from_day:0 ~through_day:99999999 ~limit ~cursor |> ok name
  in
  let elapsed = (Unix.gettimeofday () -. start) *. 1000. in
  let metrics = A.json () in
  let count key =
    match Hashtbl.find_opt A.metrics key with
    | Some (n, _) -> n
    | None -> 0
  in
  if String.starts_with ~prefix:"synthetic" name
  then
    List.iter
      (fun (item : T.journal_item) ->
         if String.starts_with ~prefix:"81000000" (G.Uuid.to_string item.page.page.uuid)
         then
           require
             (List.length item.page.page.properties >= 20 && item.page.page.tags <> [])
             "property-rich journal fixture lost its properties or tags")
      result.items;
  require (count "datoms:Aevt:*:db/ident" = 0) "global property enumeration";
  require (count "datoms:Aevt:*:block/name" = 0) "named-page enumeration";
  require (count "seek:Eavt:entity:*" = 0) "unrelated EAVT range";
  require
    (count "full_page_hydration" <= List.length result.items)
    "probe hydrated a page";
  let json =
    `Assoc
      [ "name", `String name
      ; "limit", `Int limit
      ; "items", `Int (List.length result.items)
      ; "has_more", `Bool (Option.is_some result.next_cursor)
      ; "elapsed_ms", `Float elapsed
      ; "metrics", metrics
      ]
  in
  samples := (name, metrics) :: !samples;
  Yojson.Safe.to_string json |> print_endline;
  flush stdout;
  result
;;

let audit name database =
  let snapshot = D.current_snapshot database |> ok "snapshot" in
  Fun.protect
    ~finally:(fun () -> D.release_snapshot snapshot)
    (fun () ->
       let first = measured (name ^ ":first-1") snapshot ~limit:1 ~cursor:None in
       ignore (measured (name ^ ":first-200") snapshot ~limit:200 ~cursor:None);
       Option.iter
         (fun cursor ->
            ignore
              (measured
                 (name ^ ":same-date-continuation")
                 snapshot
                 ~limit:1
                 ~cursor:(Some cursor)))
         first.next_cursor;
       let rec advance count cursor boundary =
         if count >= 10200
         then Option.map (fun c -> c, boundary) cursor
         else (
           let page =
             D.get_journals snapshot ~from_day:0 ~through_day:99999999 ~limit:200 ~cursor
             |> ok "advance"
           in
           let boundary =
             match List.rev page.items with
             | item :: _ -> item.T.journal_day
             | [] -> boundary
           in
           match page.next_cursor with
           | None -> None
           | Some c -> advance (count + List.length page.items) (Some c) boundary)
       in
       Option.iter
         (fun (cursor, boundary) ->
            let page =
              measured (name ^ ":after-10200") snapshot ~limit:1 ~cursor:(Some cursor)
            in
            require (List.length page.items = 1) "late page missing";
            require
              (List.for_all (fun day -> day <= boundary) !A.days)
              "late cursor read newer dates")
         (advance 0 None 99999999))
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

let seed support unrelated =
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
    let base =
      Datascript.datoms database Datascript.Eavt ()
      |> List.of_seq
      |> List.filter (fun (d : Datascript.datom) -> d.a <> "block/journal-day")
    in
    let tx =
      List.fold_left (fun current (d : Datascript.datom) -> max current d.tx) 0 base + 1
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
    let datom e a v = Datascript.{ e; a; v; tx; added = true } in
    let journals =
      List.init 12050 (fun n ->
        let e = 100000 + (2 * n) in
        [ datom e "block/uuid" (Uuid (G.Uuid.to_string (journal_uuid n)))
        ; datom e "block/name" (String (Printf.sprintf "audit journal %d" n))
        ; datom e "block/title" (String (Printf.sprintf "Audit journal %d" n))
        ; datom e "block/journal-day" (Int (date n))
        ; datom e "block/tags" (Ref tag)
        ]
        @ List.init 20 (fun p ->
          datom e (Printf.sprintf "audit.property/p%d" p) (Ref tag)))
      |> List.concat
    in
    let unrelated =
      List.init unrelated (fun n ->
        let e = 100001 + (2 * n) in
        [ datom e "block/uuid" (Uuid (Printf.sprintf "82000000-0000-4000-8000-%012d" n))
        ; datom e "block/title" (String "Unrelated entity")
        ]
        @
        if n mod 2 = 0
        then [ datom e "block/name" (String (Printf.sprintf "unrelated page %d" n)) ]
        else
          [ datom e "block/page" (Ref 100001)
          ; datom e "block/parent" (Ref 100001)
          ; datom e "block/order" (String (Printf.sprintf "a%08d" n))
          ])
      |> List.concat
    in
    let invalid =
      [ datom 900000 "block/journal-day" (Int 20260902)
      ; datom 900001 "block/journal-day" (Int 20260902)
      ; datom 900001 "block/uuid" (Uuid "85000000-0000-4000-8000-000000000001")
      ; datom 900001 "block/name" (String "built in journal")
      ; datom 900001 "block/title" (String "Built in journal")
      ; datom 900001 "logseq.property/built-in?" (Bool true)
      ]
    in
    Datascript.init_db
      ~schema:(Datascript.schema database)
      (base @ journals @ unrelated @ invalid));
  graph_id, path
;;

let local_journals database =
  for n = 1 to 8 do
    let page = uuid (Printf.sprintf "80000000-0000-4000-8000-%012d" n) in
    let snapshot = D.current_snapshot database |> ok "local snapshot" in
    let revision =
      match D.get_pages snapshot [ page ] |> ok "local page" with
      | [ T.Missing_page { revision; _ } ] -> revision
      | _ -> failwith "local already exists"
    in
    D.release_snapshot snapshot;
    let expected =
      D.write_precondition ~blocks:[] ~pages:[ page, revision ] ~scopes:[]
      |> ok "precondition"
    in
    ignore
      (D.commit_local
         database
         ~expected
         (T.Create_journal_page
            { mutation_id = Fixture_generator.mutation_uuid (900 + n)
            ; page
            ; title = Printf.sprintf "Local audit journal %d" n
            ; journal_day = 20260901
            })
       |> ok "local commit")
  done
;;

let audit_edges directory =
  let support = Filename.concat directory "duplicates" in
  let graph_id, path =
    Fixture_generator.seed_mirror ~application_support_directory:support ~block_count:0
  in
  rewrite_root path (fun database ->
    let datoms = Datascript.datoms database Datascript.Eavt () |> List.of_seq in
    let repeated =
      List.filter (fun (d : Datascript.datom) -> d.a = "block/journal-day") datoms
    in
    let database =
      Datascript.init_db ~schema:(Datascript.schema database) (datoms @ repeated)
    in
    let count =
      Datascript.datoms database Datascript.Aevt ~a:"block/journal-day" ()
      |> List.of_seq
      |> List.length
    in
    require
      (count = 2 * List.length repeated)
      "duplicate fixture did not retain physical datoms";
    database);
  with_database support graph_id (fun database ->
    let snapshot = D.current_snapshot database |> ok "duplicates snapshot" in
    let rec collect cursor acc =
      let page =
        D.get_journals snapshot ~from_day:0 ~through_day:99999999 ~limit:200 ~cursor
        |> ok "duplicates page"
      in
      let acc = List.rev_append page.items acc in
      match page.next_cursor with
      | None -> acc
      | Some c -> collect (Some c) acc
    in
    let items = collect None [] in
    require (List.length items = 512) "duplicate physical datoms changed journal count";
    require
      (List.length
         (List.sort_uniq
            G.Uuid.compare
            (List.map (fun (i : T.journal_item) -> i.page.page.uuid) items))
       = 512)
      "duplicate journal results";
    ignore (measured "repeated-physical-datoms" snapshot ~limit:1 ~cursor:None);
    D.release_snapshot snapshot);
  let support = Filename.concat directory "missing-index" in
  let graph_id, path =
    Fixture_generator.seed_mirror ~application_support_directory:support ~block_count:0
  in
  rewrite_root path (fun database ->
    Datascript.with_schema
      database
      (List.map
         (fun (name, (attribute : Datascript.schema_attr)) ->
            ( name
            , if name = "block/journal-day"
              then { attribute with indexed = false }
              else attribute ))
         (Datascript.schema database)));
  with_database support graph_id (fun database ->
    let snapshot = D.current_snapshot database |> ok "missing-index snapshot" in
    A.reset ();
    (match
       D.get_journals snapshot ~from_day:0 ~through_day:99999999 ~limit:1 ~cursor:None
     with
     | Error (T.Invalid_read_request _) -> ()
     | _ -> failwith "missing AVET index did not fail closed");
    require (Hashtbl.length A.metrics = 0) "missing index fell back to data reads";
    print_endline
      "{\"name\":\"missing-index\",\"result\":\"Invalid_read_request\",\"data_accesses\":0}";
    D.release_snapshot snapshot)
;;

let () =
  match Array.to_list Sys.argv with
  | [ _; "mirror"; support; graph_id ] ->
    with_database support (uuid graph_id) (audit "downloaded-mirror")
  | [ _; "edges"; directory ] -> audit_edges directory
  | [ _; "synthetic"; directory ] ->
    List.iter
      (fun unrelated ->
         let support = Filename.concat directory (string_of_int unrelated) in
         let graph_id, _ = seed support unrelated in
         with_database support graph_id (fun database ->
           let name = Printf.sprintf "synthetic-%d" unrelated in
           audit name database;
           local_journals database;
           audit (name ^ "-local") database))
      [ 12050; 100000 ];
    let metrics name = List.assoc name !samples in
    let without_storage = function
      | `Assoc fields -> `Assoc (List.remove_assoc "sqlite_restore" fields)
      | x -> x
    in
    List.iter
      (fun suffix ->
         require
           (without_storage (metrics ("synthetic-12050" ^ suffix))
            = without_storage (metrics ("synthetic-100000" ^ suffix)))
           ("unrelated graph growth changed logical accesses: " ^ suffix))
      [ ":first-1"
      ; ":first-200"
      ; ":same-date-continuation"
      ; ":after-10200"
      ; "-local:first-1"
      ; "-local:first-200"
      ; "-local:after-10200"
      ]
  | _ -> failwith "expected synthetic DIRECTORY or mirror SUPPORT GRAPH_UUID"
;;
