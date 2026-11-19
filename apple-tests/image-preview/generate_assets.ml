(* Extend an isolated warm-start fixture through public storage and asset-cache APIs.
   Arguments: SUPPORT_ROOT PNG_DIRECTORY [JOURNAL_PAGE_UUID]. *)
module G = Logseq_db_types.Graph_types
module Storage = Logseq_db_storage.Logseq_sqlite_storage
module Session = Logseq_db_storage.Storage_session
module Codec = Logseq_sync_native_crypto.Asset_codec
module Asset = Logseq_db_types.Asset_descriptor

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

let with_asset_publication publish =
  let module Cache = Logseq_sync_assets.Cache in
  let scope : Logseq_sync_assets.Namespace.graph_scope =
    { account =
        { managed_sync_origin = Uri.of_string "https://api.logseq.io"
        ; user_id = "user-1"
        }
    ; graph_id
    }
  in
  let open_cache () =
    Cache.create
      ~root:support
      ~scope
      ~budget_bytes:268435456L
      ~maximum_file_bytes:(8 * 1024 * 1024)
    |> get
  in
  let cache = ref (open_cache ()) in
  Fun.protect
    ~finally:(fun () -> Cache.close !cache)
    (fun () ->
       publish (fun ~asset ~version ~bytes ->
         let crypto : Codec.crypto =
           { encrypt = (fun ~key:_ ~plaintext:_ -> Error "Unencrypted fixture")
           ; decrypt = (fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "Unencrypted fixture")
           }
         in
         let verified =
           Codec.decode
             ~maximum_plaintext_bytes:(String.length bytes)
             ~crypto
             ~key:None
             ~expected:version
             bytes
           |> get
         in
         let handle =
           Cache.publish !cache ~asset ~current:(fun () -> true) ~verified |> get
         in
         let path = Cache.path !cache handle |> Option.get in
         if In_channel.with_open_bin path In_channel.input_all <> bytes
         then failwith "Fixture asset cache bytes changed";
         Cache.release !cache handle;
         Cache.close !cache;
         cache := open_cache ();
         let restored = Cache.lookup !cache ~asset ~version |> get |> Option.get in
         let restored_path = Cache.path !cache restored |> Option.get in
         if restored_path <> path
         then failwith "Fixture asset path changed after reopening";
         Cache.release !cache restored;
         path))
;;

type metadata =
  { color : string
  ; fileName : string
  }
[@@deriving yojson]

type metadata_list = metadata list [@@deriving yojson]

let metadata = ref []

let operations =
  with_asset_publication (fun publish ->
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
      let path = publish ~asset ~version ~bytes in
      metadata := { color; fileName = Filename.basename path } :: !metadata;
      Datascript.
        [ Add (id, "block/uuid", Uuid uuid)
        ; Add (id, "block/title", String (color ^ ".png"))
        ; Add (id, "block/parent", Ref_to root)
        ; Add (id, "block/page", Ref_to page)
        ; Add (id, "block/order", String (Printf.sprintf "a0A%06dU" index))
        ; Add (id, "block/tags", Ref_to (Ident "logseq.class/Asset"))
        ; Add (id, "logseq.property.asset/type", String "png")
        ; Add (id, "logseq.property.asset/checksum", String checksum)
        ; Add
            (id, "logseq.property.asset/size", Int64 (Int64.of_int (String.length bytes)))
        ; Add (id, "logseq.property.asset/width", Int64 640L)
        ; Add (id, "logseq.property.asset/height", Int64 420L)
        ; Add
            ( id
            , "logseq.property.asset/remote-metadata"
            , Map [ Keyword "checksum", String checksum; Keyword "type", String "png" ] )
        ; Add (root, "block/refs", Ref_to id)
        ])
    |> List.concat)
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
let () = Yojson.Safe.to_channel stdout (metadata_list_to_yojson (List.rev !metadata))
let () = print_newline ()
