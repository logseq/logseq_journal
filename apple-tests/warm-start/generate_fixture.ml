module Graph = Logseq_db_types.Graph_types
module Core = Logseq_sync_pure_reducer.Core
module Storage = Logseq_db_storage.Logseq_sqlite_storage
module Session = Logseq_db_storage.Storage_session

let seed_graph ~support ~row_count ~child_count ~history_days index =
  let graph_id =
    Graph.Uuid.of_string (Printf.sprintf "60000000-0000-4000-8000-%012d" index)
    |> Result.get_ok
  in
  let database_path = Test_support.seed_mirror ~graph_id support in
  let expected = Printf.sprintf "Graph %d — Encrypted offline Journal — 中文 👩🏽‍💻" index in
  let now = Unix.localtime (Unix.time ()) in
  let day = ((now.tm_year + 1900) * 10_000) + ((now.tm_mon + 1) * 100) + now.tm_mday in
  let page_uuid =
    Printf.sprintf
      "00000001-%04d-%02d%02d-0000-000000000000"
      (now.tm_year + 1900)
      (now.tm_mon + 1)
      now.tm_mday
  in
  let page_title =
    Printf.sprintf "%04d-%02d-%02d" (now.tm_year + 1900) (now.tm_mon + 1) now.tm_mday
  in
  let connection = Storage.open_database database_path |> Result.get_ok in
  let before = Storage.restore_database connection |> Result.get_ok in
  let session =
    Session.create
      ~tail:
        (Datascript.Storage.restore_tail_groups (Storage.datascript_storage connection))
      ~callbacks:(Storage.connection_callbacks connection)
  in
  let page = Datascript.Temp_id "native-warm-page" in
  let block = Datascript.Temp_id "native-warm-block" in
  let row ~key ~uuid ~title ~order ~parent =
    let fixture_ref = Datascript.Temp_id key in
    Datascript.
      [ Add (fixture_ref, "block/uuid", Uuid uuid)
      ; Add (fixture_ref, "block/title", String title)
      ; Add (fixture_ref, "block/order", String order)
      ; Add (fixture_ref, "block/parent", Ref_to parent)
      ; Add (fixture_ref, "block/page", Ref_to page)
      ]
  in
  let extra_rows =
    List.init (row_count - 1) (fun offset ->
      let index = offset + 2 in
      let title =
        if index mod 25 = 0
        then
          Printf.sprintf
            "Native row %04d — 中文 👩🏽‍💻 العربية\n%s"
            index
            (String.concat
               "\n"
               (List.init 8 (fun line ->
                  Printf.sprintf
                    "Long paragraph %d: Native text must wrap and remain readable at \
                     every supported width."
                    (line + 1))))
        else Printf.sprintf "Native row %04d — readable content" index
      in
      row
        ~key:(Printf.sprintf "native-list-%d" index)
        ~uuid:(Printf.sprintf "80000000-0000-4000-a000-%012d" index)
        ~title
        ~order:(Printf.sprintf "a0U%06dU" index)
        ~parent:page)
    |> List.concat
  in
  let children =
    List.init child_count (fun offset ->
      let index = offset + 1 in
      row
        ~key:(Printf.sprintf "native-child-%d" index)
        ~uuid:(Printf.sprintf "80000000-0000-4000-b000-%012d" (index + 1))
        ~title:(Printf.sprintf "Native child %02d — nested content" index)
        ~order:(Printf.sprintf "a0U%06dU" index)
        ~parent:block)
    |> List.concat
  in
  let history =
    List.init history_days (fun offset ->
      let days_ago = offset + 1 in
      let time, _ =
        Unix.mktime { now with tm_mday = now.tm_mday - days_ago; tm_hour = 12 }
      in
      let date = Unix.localtime time in
      let day =
        ((date.tm_year + 1900) * 10000) + ((date.tm_mon + 1) * 100) + date.tm_mday
      in
      let title =
        Printf.sprintf
          "%04d-%02d-%02d"
          (date.tm_year + 1900)
          (date.tm_mon + 1)
          date.tm_mday
      in
      let page = Datascript.Temp_id ("history-page-" ^ string_of_int days_ago) in
      Datascript.
        [ Add
            ( page
            , "block/uuid"
            , Uuid
                (Printf.sprintf
                   "00000001-%04d-%02d%02d-0000-000000000000"
                   (date.tm_year + 1900)
                   (date.tm_mon + 1)
                   date.tm_mday) )
        ; Add (page, "block/name", String title)
        ; Add (page, "block/title", String title)
        ; Add (page, "block/journal-day", Int day)
        ]
      @ (List.init 12 (fun index ->
           let key = Datascript.Temp_id (Printf.sprintf "history-%d-%d" days_ago index) in
           Datascript.
             [ Add
                 ( key
                 , "block/uuid"
                 , Uuid (Printf.sprintf "81000000-0000-4000-a000-%06d%06d" days_ago index)
                 )
             ; Add
                 ( key
                 , "block/title"
                 , String
                     (Printf.sprintf
                        "History %s row %02d — readable content%s"
                        title
                        (index + 1)
                        (if index = 5
                         then
                           "\n"
                           ^ String.concat
                               "\n"
                               (List.init 8 (fun line ->
                                  Printf.sprintf
                                    "Long history paragraph %d: Native text must remain \
                                     readable while dates replace one another."
                                    (line + 1)))
                         else "")) )
             ; Add (key, "block/order", String (Printf.sprintf "a0U%06dU" index))
             ; Add (key, "block/parent", Ref_to page)
             ; Add (key, "block/page", Ref_to page)
             ])
         |> List.concat))
    |> List.concat
  in
  let staged =
    Session.stage_transact
      session
      ~authoritative_before:before
      (Datascript.
         [ Add (page, "block/uuid", Uuid page_uuid)
         ; Add (page, "block/name", String page_title)
         ; Add (page, "block/title", String page_title)
         ; Add (page, "block/journal-day", Int day)
         ; Add (block, "block/uuid", Uuid "80000000-0000-4000-a000-000000000001")
         ; Add (block, "block/title", String expected)
         ; Add (block, "block/order", String "a0")
         ; Add (block, "block/parent", Ref_to page)
         ; Add (block, "block/page", Ref_to page)
         ]
       @ extra_rows
       @ children
       @ history)
    |> Result.get_ok
  in
  Session.commit_staged session staged |> Result.get_ok;
  Session.close session |> Result.get_ok;
  let graph : Core.graph =
    { graph_id
    ; name = Printf.sprintf "Native encrypted graph %d" index
    ; schema = { major = 65; minor = 33; exact = true }
    ; encrypted = true
    }
  in
  ( graph
  , `Assoc
      [ "graphId", `String (Graph.Uuid.to_string graph_id)
      ; "graphDir", `String (Filename.dirname database_path)
      ; "expectedTimelineText", `String expected
      ] )
;;

let () =
  let support = Sys.argv.(1) in
  let row_count = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 1 in
  let child_count =
    if Array.length Sys.argv > 3 then int_of_string Sys.argv.(3) else 35
  in
  let graph_count = if Array.length Sys.argv > 4 then int_of_string Sys.argv.(4) else 1 in
  if row_count < 1 || row_count > 5000
  then invalid_arg "Fixture rows must be between 1 and 5000";
  if child_count < 0 || child_count > 5000
  then invalid_arg "Fixture children must be between 0 and 5000";
  if graph_count < 1 || graph_count > 4
  then invalid_arg "Fixture graphs must be between 1 and 4";
  let history_days = int_of_string Sys.argv.(5) in
  if history_days < 0 || history_days > 30
  then invalid_arg "History days must be between 0 and 30";
  let graphs, descriptors =
    List.init graph_count (fun offset ->
      seed_graph ~support ~row_count ~child_count ~history_days (offset + 1))
    |> List.split
  in
  let selected = (List.hd graphs).graph_id in
  let cache =
    Core.catalog_cache ~user_id:"user-1" ~graphs ~selected_graph:(Some selected)
  in
  let catalog = Filename.concat support "logseq-db-worker/sync-catalogs" in
  Unix.mkdir catalog 0o700;
  (* The existing public runner contract's api.logseq.io/user-1 fixture path. *)
  let file =
    Filename.concat
      catalog
      "748ac0b0c274b30bc6fc1da756958deab4ebdef06a2d6373a377e2b4d8cec6df.json"
  in
  let output = open_out_bin file in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () -> output_string output (Core.encode_catalog_cache cache));
  Yojson.Safe.to_channel
    stdout
    (`Assoc
        [ "formatVersion", `Int 2
        ; "supportRoot", `String support
        ; "baseUrl", `String "https://api.logseq.io"
        ; "userId", `String "user-1"
        ; "graphs", `List descriptors
        ; "rootRowCount", `Int row_count
        ; "childRowCount", `Int child_count
        ]);
  print_newline ()
;;
