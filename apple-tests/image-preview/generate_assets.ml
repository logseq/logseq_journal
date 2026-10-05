(* Extend an isolated warm-start fixture through public storage/cache APIs only.
   Arguments: SUPPORT_ROOT PNG_DIRECTORY [JOURNAL_PAGE_UUID]. *)
module G = Logseq_db_types.Graph_types
module Storage = Logseq_db_storage.Logseq_sqlite_storage
module Session = Logseq_db_storage.Storage_session
module Cache = Logseq_sync_effect_runner.Asset_cache
module Codec = Logseq_sync_effect_runner.Asset_codec
module Asset = Logseq_db_types.Asset_descriptor
module Core = Logseq_sync_pure_reducer.Core

let get = function
  | Ok value -> value
  | Error _ -> failwith "Synthetic Timeline image fixture preparation failed"
;;

let support = Sys.argv.(1)
let graph = "60000000-0000-4000-8000-000000000001"
let graph_id = get (G.Uuid.of_string graph)

let root =
  Datascript.Lookup_ref ("block/uuid", Uuid "80000000-0000-4000-a000-000000000001")
;;

let now = Unix.localtime (Unix.time ())

let title =
  Printf.sprintf "%04d-%02d-%02d" (now.tm_year + 1900) (now.tm_mon + 1) now.tm_mday
;;

let page_uuid =
  if Array.length Sys.argv > 3
  then Sys.argv.(3)
  else
    Printf.sprintf
      "00000001-%04d-%02d%02d-0000-000000000000"
      (now.tm_year + 1900)
      (now.tm_mon + 1)
      now.tm_mday
;;

let page = Datascript.Lookup_ref ("block/uuid", Uuid page_uuid)

let connection =
  get
    (Storage.open_database
       (Filename.concat
          support
          ("logseq-db-worker/synced-graphs/" ^ graph ^ "/db.sqlite")))
;;

let before = get (Storage.restore_database connection)

let session =
  Session.create
    ~tail:(Datascript.Storage.restore_tail_groups (Storage.datascript_storage connection))
    ~callbacks:(Storage.connection_callbacks connection)
;;

let scope : Core.graph_scope =
  { account =
      { managed_sync_origin = Uri.of_string "https://api.logseq.io"
      ; user_id = "user-1"
      ; account_generation = 1
      ; presentation_generation = 1
      ; lifecycle_generation = 1L
      }
  ; graph_id
  ; graph_generation = 1
  }
;;

let cache =
  get
    (Cache.create
       ~root:(Filename.concat support "logseq-db-worker/assets")
       ~scope
       ~budget_bytes:268435456L
       ~maximum_file_bytes:(8 * 1024 * 1024))
;;

let metadata = ref []

let operations =
  [ "red"; "blue"; "green" ]
  |> List.mapi (fun index color ->
    let uuid = Printf.sprintf "92000000-0000-4000-8000-%012d" (index + 1) in
    let id = Datascript.Temp_id ("timeline-" ^ color) in
    let channel = open_in_bin (Filename.concat Sys.argv.(2) (color ^ ".png")) in
    let bytes =
      Fun.protect
        ~finally:(fun () -> close_in channel)
        (fun () -> really_input_string channel (in_channel_length channel))
    in
    let checksum = Codec.checksum bytes in
    let asset = get (G.Uuid.of_string uuid) in
    let version = get (Asset.version ~checksum ~file_type:"png") in
    let handle =
      get (Cache.publish cache ~asset ~version ~current:(fun () -> true) ~plaintext:bytes)
    in
    let path = Option.get (Cache.path cache handle) in
    metadata
    := `Assoc [ "color", `String color; "fileName", `String (Filename.basename path) ]
       :: !metadata;
    Cache.release cache handle;
    Datascript.
      [ Add (id, "block/uuid", Uuid uuid)
      ; Add (id, "block/title", String (color ^ ".png"))
      ; Add (id, "block/parent", Ref_to root)
      ; Add (id, "block/page", Ref_to page)
      ; Add (id, "block/order", String (Printf.sprintf "a0A%06dU" index))
      ; Add (id, "block/tags", Ref_to (Ident "logseq.class/Asset"))
      ; Add (id, "logseq.property.asset/type", String "png")
      ; Add (id, "logseq.property.asset/checksum", String checksum)
      ; Add (id, "logseq.property.asset/size", Int64 (Int64.of_int (String.length bytes)))
      ; Add (id, "logseq.property.asset/width", Int64 640L)
      ; Add (id, "logseq.property.asset/height", Int64 420L)
      ; Add
          ( id
          , "logseq.property.asset/remote-metadata"
          , Map [ Keyword "checksum", String checksum; Keyword "type", String "png" ] )
      ; Add (root, "block/refs", Ref_to id)
      ])
  |> List.concat
;;

let operations =
  operations
  @ Datascript.
      [ Add (root, "block/title", String "Timeline gallery fixture")
      ; Add (page, "block/name", String title)
      ; Add (page, "block/title", String title)
      ; Add
          ( page
          , "block/journal-day"
          , Int64
              (Int64.of_int
                 (((now.tm_year + 1900) * 10000) + ((now.tm_mon + 1) * 100) + now.tm_mday))
          )
      ]
;;

let staged = get (Session.stage_transact session ~authoritative_before:before operations)
let () = ignore (get (Session.commit_staged session staged))
let () = ignore (get (Session.close session))
let () = Cache.close cache
let () = Yojson.Safe.to_channel stdout (`List (List.rev !metadata))
let () = print_newline ()
