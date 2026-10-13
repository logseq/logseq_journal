type cursor = Logseq_db_types.Server_cursor.t
type checksum = string

type rejection_reason =
  | Stale
  | Db_transact_failed
  | Empty_tx_data
  | Invalid_tx
  | Invalid_t_before
  | Snapshot_upload_in_progress

type rejection =
  { reason : rejection_reason
  ; t : cursor option
  ; checksum : checksum option
  ; success_tx_ids : Logseq_db_types.Graph_types.Uuid.t list
  ; failed_tx_id : Logseq_db_types.Graph_types.Uuid.t option
  ; missing_block_uuids : Logseq_db_types.Graph_types.Uuid.t list
  ; error_detail : string option
  ; data : string option
  }

type user_presence =
  { user_id : string
  ; email : string option
  ; username : string option
  ; name : string option
  }

module Client = struct
  type transaction =
    { tx : string
    ; tx_id : Logseq_db_types.Graph_types.Uuid.t option
    ; outliner_op : string option
    }

  type message =
    | Hello of { client : string }
    | Presence of { editing_block_uuid : string option }
    | Pull of { since : cursor option }
    | Tx_batch of
        { client_revision : string option
        ; t_before : cursor
        ; txs : transaction list
        }
    | Ping
end

module Server = struct
  type pull_transaction =
    { t : cursor
    ; tx : string
    ; outliner_op : string option
    }

  type message =
    | Hello of
        { t : cursor
        ; checksum : checksum option
        }
    | Online_users of { online_users : user_presence list }
    | Presence of
        { user_id : string
        ; editing_block_uuid : string option
        }
    | Pull_ok of
        { t : cursor
        ; checksum : checksum option
        ; txs : pull_transaction list
        }
    | Tx_batch_ok of
        { t : cursor
        ; checksum : checksum option
        }
    | Changed of { t : cursor }
    | Tx_reject of rejection
    | Pong
    | Error of { message : string }
end

type direction =
  | Client
  | Server

type error_kind =
  | Invalid_json
  | Expected_object
  | Missing_field of string
  | Unexpected_fields of string list
  | Unsupported_message_type of string
  | Invalid_field of { expected : string }
  | Limit_exceeded of { maximum : int }

type codec_error =
  { direction : direction
  ; message_type : string option
  ; path : string list
  ; kind : error_kind
  }

type decode_context =
  { direction : direction
  ; message_type : string option
  }

let ( let* ) = Result.bind

let error context path kind =
  Error { direction = context.direction; message_type = context.message_type; path; kind }
;;

let maximum_wire_bytes = function
  | Client -> Logseq_db_types.Limits.maximum_request_bytes
  | Server -> Logseq_db_types.Limits.maximum_response_bytes
;;

let maximum_metadata_bytes = 4_096

let is_decimal value =
  String.length value > 0
  && String.for_all
       (function
         | '0' .. '9' -> true
         | _ -> false)
       value
;;

let render_path path =
  List.fold_left
    (fun rendered segment ->
       if is_decimal segment
       then rendered ^ "[" ^ segment ^ "]"
       else rendered ^ "." ^ segment)
    "$"
    path
;;

let direction_name = function
  | Client -> "client"
  | Server -> "server"
;;

let error_to_string (error : codec_error) =
  let prefix = direction_name error.direction ^ " sync protocol" in
  let message_type =
    match error.message_type with
    | None -> ""
    | Some value -> " " ^ value
  in
  let location = " at " ^ render_path error.path in
  let detail =
    match error.kind with
    | Invalid_json -> "invalid JSON"
    | Expected_object -> "expected an object"
    | Missing_field field -> "missing field " ^ field
    | Unexpected_fields fields -> "unexpected fields " ^ String.concat ", " fields
    | Unsupported_message_type message_type -> "unsupported message type " ^ message_type
    | Invalid_field { expected } -> "invalid field; expected " ^ expected
    | Limit_exceeded { maximum } ->
      Printf.sprintf "size limit exceeded; maximum %d bytes" maximum
  in
  prefix ^ message_type ^ location ^ ": " ^ detail
;;

module Wire = struct
  type header = { kind : string [@key "type"] } [@@deriving yojson { strict = false }]

  type client_transaction =
    { tx : string
    ; tx_id : Logseq_db_types.Graph_types.Uuid.t option [@key "tx-id"] [@default None]
    ; outliner_op : string option [@key "outliner-op"] [@default None]
    }
  [@@deriving yojson]

  type pull_transaction =
    { t : int64
    ; tx : string
    ; outliner_op : string option [@key "outliner-op"] [@default None]
    }
  [@@deriving yojson]

  type user_presence =
    { user_id : string [@key "user-id"]
    ; email : string option [@default None]
    ; username : string option [@default None]
    ; name : string option [@default None]
    }
  [@@deriving yojson]

  type client_hello =
    { kind : string [@key "type"]
    ; client : string
    }
  [@@deriving yojson]

  type client_presence =
    { kind : string [@key "type"]
    ; editing_block_uuid : string option [@key "editing-block-uuid"] [@default None]
    }
  [@@deriving yojson]

  type client_pull =
    { kind : string [@key "type"]
    ; since : int64 option [@default None]
    }
  [@@deriving yojson]

  type client_tx_batch =
    { kind : string [@key "type"]
    ; client_revision : string option [@key "client-revision"] [@default None]
    ; t_before : int64 [@key "t-before"]
    ; txs : client_transaction list
    }
  [@@deriving yojson]

  type client_ping = { kind : string [@key "type"] } [@@deriving yojson]

  type server_hello =
    { kind : string [@key "type"]
    ; t : int64
    ; checksum : string option [@default None]
    }
  [@@deriving yojson]

  type server_online_users =
    { kind : string [@key "type"]
    ; online_users : user_presence list [@key "online-users"]
    }
  [@@deriving yojson]

  type server_presence =
    { kind : string [@key "type"]
    ; user_id : string [@key "user-id"]
    ; editing_block_uuid : string option [@key "editing-block-uuid"]
    }
  [@@deriving yojson]

  type server_pull_ok =
    { kind : string [@key "type"]
    ; t : int64
    ; checksum : string option [@default None]
    ; txs : pull_transaction list
    }
  [@@deriving yojson]

  type server_tx_batch_ok =
    { kind : string [@key "type"]
    ; t : int64
    ; checksum : string option [@default None]
    }
  [@@deriving yojson]

  type server_changed =
    { kind : string [@key "type"]
    ; t : int64
    }
  [@@deriving yojson]

  type server_tx_reject =
    { kind : string [@key "type"]
    ; reason : string
    ; t : int64 option [@default None]
    ; checksum : string option [@default None]
    ; success_tx_ids : Logseq_db_types.Graph_types.Uuid.t list
          [@key "success-tx-ids"] [@default []]
    ; failed_tx_id : Logseq_db_types.Graph_types.Uuid.t option
          [@key "failed-tx-id"] [@default None]
    ; missing_block_uuids : Logseq_db_types.Graph_types.Uuid.t list
          [@key "missing-block-uuids"] [@default []]
    ; error_detail : string option [@key "error-detail"] [@default None]
    ; data : string option [@default None]
    }
  [@@deriving yojson]

  type server_pong = { kind : string [@key "type"] } [@@deriving yojson]

  type server_error =
    { kind : string [@key "type"]
    ; message : string
    }
  [@@deriving yojson]

  type baseline =
    { kind : string [@key "type"]
    ; t : int64
    }
  [@@deriving yojson { strict = false }]
end

(* Structural checks preserve the public safe diagnostics. They never construct
   protocol values: every record is decoded by its generated Wire codec. *)
type shape =
  | Text of int
  | Nullable_text of int
  | Cursor
  | Uuid
  | Checksum
  | Rejection_reason
  | Array of shape
  | Object of (string * bool * shape) list

let maximum_wire_cursor = 9007199254740991L
let metadata = Text maximum_metadata_bytes
let nullable_metadata = Nullable_text maximum_metadata_bytes
let required name shape = name, true, shape
let optional name shape = name, false, shape

let duplicate_names names =
  let sorted = List.sort String.compare names in
  let rec loop duplicates = function
    | left :: (right :: _ as rest) when String.equal left right ->
      loop (left :: duplicates) rest
    | _ :: rest -> loop duplicates rest
    | [] -> List.sort_uniq String.compare duplicates
  in
  loop [] sorted
;;

let check_fields context path allowed fields =
  let names = List.map fst fields in
  match duplicate_names names with
  | _ :: _ -> error context path (Invalid_field { expected = "unique object fields" })
  | [] ->
    let unexpected =
      List.filter (fun name -> not (List.mem name allowed)) names
      |> List.sort_uniq String.compare
    in
    (match unexpected with
     | [] -> Ok ()
     | _ :: _ -> error context path (Unexpected_fields unexpected))
;;

let rec validate context path shape json =
  let invalid expected = error context path (Invalid_field { expected }) in
  match shape, json with
  | Text maximum, `String value | Nullable_text maximum, `String value ->
    if String.length value <= maximum
    then Ok ()
    else error context path (Limit_exceeded { maximum })
  | Text _, _
  | Nullable_text _, (`Assoc _ | `List _ | `Bool _ | `Int _ | `Intlit _ | `Float _) ->
    invalid "string"
  | Nullable_text _, `Null -> Ok ()
  | Cursor, value ->
    let number =
      match value with
      | `Int value -> Some (Int64.of_int value)
      | `Intlit value
        when String.length value > 0
             && String.for_all
                  (function
                    | '0' .. '9' -> true
                    | _ -> false)
                  value -> Int64.of_string_opt value
      | _ -> None
    in
    (match number with
     | Some value when value >= 0L && value <= maximum_wire_cursor -> Ok ()
     | _ -> invalid "integer cursor between 0 and 9007199254740991")
  | Uuid, `String value ->
    (match Logseq_db_types.Graph_types.Uuid.of_string value with
     | Ok _ -> Ok ()
     | Error _ -> invalid "UUID string")
  | Uuid, _ -> invalid "UUID string"
  | Checksum, `String value
    when String.length value = 16
         && String.for_all
              (function
                | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
                | _ -> false)
              value -> Ok ()
  | Checksum, _ -> invalid "16-character hexadecimal checksum"
  | ( Rejection_reason
    , `String
        ( "stale"
        | "db transact failed"
        | "empty tx data"
        | "invalid tx"
        | "invalid t-before"
        | "snapshot upload in progress" ) ) -> Ok ()
  | Rejection_reason, _ -> invalid "known rejection reason"
  | Array item, `List values ->
    let rec loop index = function
      | [] -> Ok ()
      | value :: rest ->
        let* () = validate context (path @ [ string_of_int index ]) item value in
        loop (index + 1) rest
    in
    loop 0 values
  | Array _, _ -> invalid "array"
  | Object schema, `Assoc fields ->
    let* () =
      check_fields context path (List.map (fun (name, _, _) -> name) schema) fields
    in
    let rec loop = function
      | [] -> Ok ()
      | (name, is_required, shape) :: rest ->
        let* () =
          match List.assoc_opt name fields with
          | None when is_required -> error context path (Missing_field name)
          | None -> Ok ()
          | Some json -> validate context (path @ [ name ]) shape json
        in
        loop rest
    in
    loop schema
  | Object _, _ -> invalid "object"
  | _ -> invalid "string"
;;

let client_transaction_shape =
  Object
    [ required "tx" (Text (maximum_wire_bytes Client))
    ; optional "tx-id" Uuid
    ; optional "outliner-op" nullable_metadata
    ]
;;

let pull_transaction_shape =
  Object
    [ required "t" Cursor
    ; required "tx" (Text (maximum_wire_bytes Server))
    ; optional "outliner-op" nullable_metadata
    ]
;;

let user_presence_shape =
  Object
    [ required "user-id" metadata
    ; optional "email" nullable_metadata
    ; optional "username" nullable_metadata
    ; optional "name" nullable_metadata
    ]
;;

let rejection_shape =
  [ required "reason" Rejection_reason
  ; optional "t" Cursor
  ; optional "checksum" Checksum
  ; optional "success-tx-ids" (Array Uuid)
  ; optional "failed-tx-id" Uuid
  ; optional "missing-block-uuids" (Array Uuid)
  ; optional "error-detail" metadata
  ; optional "data" metadata
  ]
;;

let decode_dto context schema decoder json =
  let* () = validate context [] (Object (required "type" metadata :: schema)) json in
  match Logseq_db_types.Json_codec.decode decoder json with
  | Ok dto -> Ok dto
  | Error _ -> error context [] (Invalid_field { expected = "valid protocol fields" })
;;

let cursor value = Logseq_db_types.Server_cursor.of_int64 value |> Result.get_ok
let cursor_value value = Logseq_db_types.Server_cursor.to_int64 value

let client_transaction (value : Wire.client_transaction) : Client.transaction =
  { tx = value.tx; tx_id = value.tx_id; outliner_op = value.outliner_op }
;;

let pull_transaction (value : Wire.pull_transaction) : Server.pull_transaction =
  { t = cursor value.t; tx = value.tx; outliner_op = value.outliner_op }
;;

let user_presence (value : Wire.user_presence) : user_presence =
  { user_id = value.user_id
  ; email = value.email
  ; username = value.username
  ; name = value.name
  }
;;

let rejection_reason = function
  | "stale" -> Stale
  | "db transact failed" -> Db_transact_failed
  | "empty tx data" -> Empty_tx_data
  | "invalid tx" -> Invalid_tx
  | "invalid t-before" -> Invalid_t_before
  | "snapshot upload in progress" -> Snapshot_upload_in_progress
  | _ -> assert false
;;

let rejection_reason_string = function
  | Stale -> "stale"
  | Db_transact_failed -> "db transact failed"
  | Empty_tx_data -> "empty tx data"
  | Invalid_tx -> "invalid tx"
  | Invalid_t_before -> "invalid t-before"
  | Snapshot_upload_in_progress -> "snapshot upload in progress"
;;

let validate_rejection context (rejection : rejection) =
  let operational_fields_absent =
    rejection.checksum = None
    && rejection.success_tx_ids = []
    && rejection.failed_tx_id = None
    && rejection.missing_block_uuids = []
    && rejection.error_detail = None
  in
  let valid =
    match rejection.reason with
    | Stale | Snapshot_upload_in_progress ->
      Option.is_some rejection.t && operational_fields_absent
    | Empty_tx_data | Invalid_tx | Invalid_t_before ->
      Option.is_none rejection.t && operational_fields_absent
    | Db_transact_failed -> Option.is_some rejection.t
  in
  if valid
  then Ok rejection
  else
    error
      context
      []
      (Invalid_field { expected = "fields allowed for the selected rejection reason" })
;;

let decode_client_fields context message_type json =
  match message_type with
  | "hello" ->
    let* dto =
      decode_dto context [ required "client" metadata ] Wire.client_hello_of_yojson json
    in
    Ok (Client.Hello { client = dto.client })
  | "presence" ->
    let* dto =
      decode_dto
        context
        [ optional "editing-block-uuid" nullable_metadata ]
        Wire.client_presence_of_yojson
        json
    in
    Ok (Client.Presence { editing_block_uuid = dto.editing_block_uuid })
  | "pull" ->
    let* dto =
      decode_dto context [ optional "since" Cursor ] Wire.client_pull_of_yojson json
    in
    Ok (Client.Pull { since = Option.map cursor dto.since })
  | "tx/batch" ->
    let* dto =
      decode_dto
        context
        [ optional "client-revision" metadata
        ; required "t-before" Cursor
        ; required "txs" (Array client_transaction_shape)
        ]
        Wire.client_tx_batch_of_yojson
        json
    in
    Ok
      (Client.Tx_batch
         { client_revision = dto.client_revision
         ; t_before = cursor dto.t_before
         ; txs = List.map client_transaction dto.txs
         })
  | "ping" ->
    let* _ = decode_dto context [] Wire.client_ping_of_yojson json in
    Ok Client.Ping
  | unsupported -> error context [] (Unsupported_message_type unsupported)
;;

let decode_server_fields context message_type json =
  match message_type with
  | "hello" ->
    let* dto =
      decode_dto
        context
        [ required "t" Cursor; optional "checksum" Checksum ]
        Wire.server_hello_of_yojson
        json
    in
    Ok (Server.Hello { t = cursor dto.t; checksum = dto.checksum })
  | "online-users" ->
    let* dto =
      decode_dto
        context
        [ required "online-users" (Array user_presence_shape) ]
        Wire.server_online_users_of_yojson
        json
    in
    Ok (Server.Online_users { online_users = List.map user_presence dto.online_users })
  | "presence" ->
    let* dto =
      decode_dto
        context
        [ required "user-id" metadata; required "editing-block-uuid" nullable_metadata ]
        Wire.server_presence_of_yojson
        json
    in
    Ok
      (Server.Presence
         { user_id = dto.user_id; editing_block_uuid = dto.editing_block_uuid })
  | "pull/ok" ->
    let* dto =
      decode_dto
        context
        [ required "t" Cursor
        ; optional "checksum" Checksum
        ; required "txs" (Array pull_transaction_shape)
        ]
        Wire.server_pull_ok_of_yojson
        json
    in
    Ok
      (Server.Pull_ok
         { t = cursor dto.t
         ; checksum = dto.checksum
         ; txs = List.map pull_transaction dto.txs
         })
  | "tx/batch/ok" ->
    let* dto =
      decode_dto
        context
        [ required "t" Cursor; optional "checksum" Checksum ]
        Wire.server_tx_batch_ok_of_yojson
        json
    in
    Ok (Server.Tx_batch_ok { t = cursor dto.t; checksum = dto.checksum })
  | "changed" ->
    let* dto =
      decode_dto context [ required "t" Cursor ] Wire.server_changed_of_yojson json
    in
    Ok (Server.Changed { t = cursor dto.t })
  | "tx/reject" ->
    let* dto = decode_dto context rejection_shape Wire.server_tx_reject_of_yojson json in
    let* rejection =
      validate_rejection
        context
        { reason = rejection_reason dto.reason
        ; t = Option.map cursor dto.t
        ; checksum = dto.checksum
        ; success_tx_ids = dto.success_tx_ids
        ; failed_tx_id = dto.failed_tx_id
        ; missing_block_uuids = dto.missing_block_uuids
        ; error_detail = dto.error_detail
        ; data = dto.data
        }
    in
    Ok (Server.Tx_reject rejection)
  | "pong" ->
    let* _ = decode_dto context [] Wire.server_pong_of_yojson json in
    Ok Server.Pong
  | "error" ->
    let* dto =
      decode_dto context [ required "message" metadata ] Wire.server_error_of_yojson json
    in
    Ok (Server.Error { message = dto.message })
  | unsupported -> error context [] (Unsupported_message_type unsupported)
;;

let decode ?maximum direction decode_fields wire =
  let context = { direction; message_type = None } in
  let maximum = Option.value maximum ~default:(maximum_wire_bytes direction) in
  if String.length wire > maximum
  then error context [] (Limit_exceeded { maximum })
  else (
    try
      match Yojson.Safe.from_string wire with
      | `Assoc fields as json ->
        let* () =
          match List.assoc_opt "type" fields with
          | None -> error context [] (Missing_field "type")
          | Some json -> validate context [ "type" ] metadata json
        in
        (match Wire.header_of_yojson json with
         | Ok header ->
           decode_fields { context with message_type = Some header.kind } header.kind json
         | Error _ ->
           error context [] (Invalid_field { expected = "message discriminator" }))
      | _ -> error context [] Expected_object
    with
    | Yojson.Json_error _ -> error context [] Invalid_json)
;;

let decode_snapshot_baseline =
  decode
    ~maximum:Logseq_db_types.Limits.maximum_snapshot_baseline_response_bytes
    Server
    (fun context message_type json ->
       if message_type <> "pull/ok"
       then error context [] (Unsupported_message_type message_type)
       else (
         match json with
         | `Assoc fields ->
           let* () =
             match List.assoc_opt "t" fields with
             | None -> error context [] (Missing_field "t")
             | Some json -> validate context [ "t" ] Cursor json
           in
           (match Logseq_db_types.Json_codec.decode Wire.baseline_of_yojson json with
            | Ok dto -> Ok (cursor dto.t)
            | Error _ ->
              error context [] (Invalid_field { expected = "snapshot baseline" }))
         | _ -> error context [] Expected_object))
;;

let decode_client_message = decode Client decode_client_fields
let decode_server_message = decode Server decode_server_fields

let wire_client_transaction (value : Client.transaction) : Wire.client_transaction =
  { tx = value.tx; tx_id = value.tx_id; outliner_op = value.outliner_op }
;;

let wire_pull_transaction (value : Server.pull_transaction) : Wire.pull_transaction =
  { t = cursor_value value.t; tx = value.tx; outliner_op = value.outliner_op }
;;

let wire_user_presence (value : user_presence) : Wire.user_presence =
  { user_id = value.user_id
  ; email = value.email
  ; username = value.username
  ; name = value.name
  }
;;

let client_message_json = function
  | Client.Hello { client } -> Wire.client_hello_to_yojson { kind = "hello"; client }
  | Client.Presence { editing_block_uuid } ->
    Wire.client_presence_to_yojson { kind = "presence"; editing_block_uuid }
  | Client.Pull { since } ->
    Wire.client_pull_to_yojson { kind = "pull"; since = Option.map cursor_value since }
  | Client.Tx_batch { client_revision; t_before; txs } ->
    Wire.client_tx_batch_to_yojson
      { kind = "tx/batch"
      ; client_revision
      ; t_before = cursor_value t_before
      ; txs = List.map wire_client_transaction txs
      }
  | Client.Ping -> Wire.client_ping_to_yojson { kind = "ping" }
;;

let server_message_json = function
  | Server.Hello { t; checksum } ->
    Wire.server_hello_to_yojson { kind = "hello"; t = cursor_value t; checksum }
  | Server.Online_users { online_users } ->
    Wire.server_online_users_to_yojson
      { kind = "online-users"; online_users = List.map wire_user_presence online_users }
  | Server.Presence { user_id; editing_block_uuid } ->
    Wire.server_presence_to_yojson { kind = "presence"; user_id; editing_block_uuid }
  | Server.Pull_ok { t; checksum; txs } ->
    Wire.server_pull_ok_to_yojson
      { kind = "pull/ok"
      ; t = cursor_value t
      ; checksum
      ; txs = List.map wire_pull_transaction txs
      }
  | Server.Tx_batch_ok { t; checksum } ->
    Wire.server_tx_batch_ok_to_yojson
      { kind = "tx/batch/ok"; t = cursor_value t; checksum }
  | Server.Changed { t } ->
    Wire.server_changed_to_yojson { kind = "changed"; t = cursor_value t }
  | Server.Tx_reject rejection ->
    Wire.server_tx_reject_to_yojson
      { kind = "tx/reject"
      ; reason = rejection_reason_string rejection.reason
      ; t = Option.map cursor_value rejection.t
      ; checksum = rejection.checksum
      ; success_tx_ids = rejection.success_tx_ids
      ; failed_tx_id = rejection.failed_tx_id
      ; missing_block_uuids = rejection.missing_block_uuids
      ; error_detail = rejection.error_detail
      ; data = rejection.data
      }
  | Server.Pong -> Wire.server_pong_to_yojson { kind = "pong" }
  | Server.Error { message } -> Wire.server_error_to_yojson { kind = "error"; message }
;;

let encode decode_message json =
  let wire = Yojson.Safe.to_string json in
  let* _ = decode_message wire in
  Ok wire
;;

let encode_client_message message =
  encode decode_client_message (client_message_json message)
;;

let encode_server_message message =
  encode decode_server_message (server_message_json message)
;;
