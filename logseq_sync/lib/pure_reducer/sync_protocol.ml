type cursor = int
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

let field name fields = List.assoc_opt name fields

let required_field context path name fields =
  match field name fields with
  | Some value -> Ok value
  | None -> error context path (Missing_field name)
;;

let bounded_string context path ?(maximum = maximum_metadata_bytes) = function
  | `String value when String.length value <= maximum -> Ok value
  | `String _ -> error context path (Limit_exceeded { maximum })
  | _ -> error context path (Invalid_field { expected = "string" })
;;

let required_string context path ?maximum name fields =
  let* value = required_field context path name fields in
  bounded_string context (path @ [ name ]) ?maximum value
;;

let optional_string context path ?maximum name fields =
  match field name fields with
  | None -> Ok None
  | Some value ->
    let* value = bounded_string context (path @ [ name ]) ?maximum value in
    Ok (Some value)
;;

let optional_nullable_string context path ?maximum name fields =
  match field name fields with
  | None | Some `Null -> Ok None
  | Some value ->
    let* value = bounded_string context (path @ [ name ]) ?maximum value in
    Ok (Some value)
;;

let required_nullable_string context path ?maximum name fields =
  let* value = required_field context path name fields in
  match value with
  | `Null -> Ok None
  | value ->
    let* value = bounded_string context (path @ [ name ]) ?maximum value in
    Ok (Some value)
;;

let non_negative_int context path = function
  | `Int value when value >= 0 -> Ok value
  | `Int _ -> error context path (Invalid_field { expected = "non-negative integer" })
  | _ -> error context path (Invalid_field { expected = "non-negative integer" })
;;

let required_cursor context path name fields =
  let* value = required_field context path name fields in
  non_negative_int context (path @ [ name ]) value
;;

let optional_cursor context path name fields =
  match field name fields with
  | None -> Ok None
  | Some value ->
    let* value = non_negative_int context (path @ [ name ]) value in
    Ok (Some value)
;;

let checksum_value context path = function
  | `String value
    when String.length value = 16
         && String.for_all
              (function
                | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
                | _ -> false)
              value -> Ok value
  | `String _ ->
    error context path (Invalid_field { expected = "16-character hexadecimal checksum" })
  | _ ->
    error context path (Invalid_field { expected = "16-character hexadecimal checksum" })
;;

let optional_checksum context path fields =
  match field "checksum" fields with
  | None -> Ok None
  | Some value ->
    let* value = checksum_value context (path @ [ "checksum" ]) value in
    Ok (Some value)
;;

let uuid_value context path = function
  | `String value ->
    (match Logseq_db_types.Graph_types.Uuid.of_string value with
     | Ok uuid -> Ok uuid
     | Error _ -> error context path (Invalid_field { expected = "UUID string" }))
  | _ -> error context path (Invalid_field { expected = "UUID string" })
;;

let optional_uuid context path name fields =
  match field name fields with
  | None -> Ok None
  | Some value ->
    let* value = uuid_value context (path @ [ name ]) value in
    Ok (Some value)
;;

let list context path decode = function
  | `List values ->
    let rec loop index decoded = function
      | [] -> Ok (List.rev decoded)
      | value :: rest ->
        let* value = decode (path @ [ string_of_int index ]) value in
        loop (index + 1) (value :: decoded) rest
    in
    loop 0 [] values
  | _ -> error context path (Invalid_field { expected = "array" })
;;

let required_list context path name decode fields =
  let* value = required_field context path name fields in
  list context (path @ [ name ]) decode value
;;

let optional_uuid_list context path name fields =
  match field name fields with
  | None -> Ok []
  | Some value -> list context (path @ [ name ]) (uuid_value context) value
;;

let decode_client_transaction context path = function
  | `Assoc fields ->
    let* () = check_fields context path [ "tx"; "tx-id"; "outliner-op" ] fields in
    let* tx =
      required_string context path ~maximum:(maximum_wire_bytes Client) "tx" fields
    in
    let* tx_id = optional_uuid context path "tx-id" fields in
    let* outliner_op = optional_nullable_string context path "outliner-op" fields in
    Ok Client.{ tx; tx_id; outliner_op }
  | _ -> error context path (Invalid_field { expected = "transaction object" })
;;

let decode_pull_transaction context path = function
  | `Assoc fields ->
    let* () = check_fields context path [ "t"; "tx"; "outliner-op" ] fields in
    let* t = required_cursor context path "t" fields in
    let* tx =
      required_string context path ~maximum:(maximum_wire_bytes Server) "tx" fields
    in
    let* outliner_op = optional_nullable_string context path "outliner-op" fields in
    Ok Server.{ t; tx; outliner_op }
  | _ -> error context path (Invalid_field { expected = "pull transaction object" })
;;

let decode_user_presence context path = function
  | `Assoc fields ->
    let* () =
      check_fields context path [ "user-id"; "email"; "username"; "name" ] fields
    in
    let* user_id = required_string context path "user-id" fields in
    let* email = optional_nullable_string context path "email" fields in
    let* username = optional_nullable_string context path "username" fields in
    let* name = optional_nullable_string context path "name" fields in
    Ok { user_id; email; username; name }
  | _ -> error context path (Invalid_field { expected = "user presence object" })
;;

let rejection_reason context path = function
  | `String "stale" -> Ok Stale
  | `String "db transact failed" -> Ok Db_transact_failed
  | `String "empty tx data" -> Ok Empty_tx_data
  | `String "invalid tx" -> Ok Invalid_tx
  | `String "invalid t-before" -> Ok Invalid_t_before
  | `String "snapshot upload in progress" -> Ok Snapshot_upload_in_progress
  | `String _ ->
    error context path (Invalid_field { expected = "known rejection reason" })
  | _ -> error context path (Invalid_field { expected = "known rejection reason" })
;;

let validate_rejection context rejection =
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

let decode_rejection context fields =
  let allowed =
    [ "type"
    ; "reason"
    ; "t"
    ; "checksum"
    ; "success-tx-ids"
    ; "failed-tx-id"
    ; "missing-block-uuids"
    ; "error-detail"
    ; "data"
    ]
  in
  let* () = check_fields context [] allowed fields in
  let* reason_json = required_field context [] "reason" fields in
  let* reason = rejection_reason context [ "reason" ] reason_json in
  let* t = optional_cursor context [] "t" fields in
  let* checksum = optional_checksum context [] fields in
  let* success_tx_ids = optional_uuid_list context [] "success-tx-ids" fields in
  let* failed_tx_id = optional_uuid context [] "failed-tx-id" fields in
  let* missing_block_uuids = optional_uuid_list context [] "missing-block-uuids" fields in
  let* error_detail = optional_string context [] "error-detail" fields in
  let* data = optional_string context [] "data" fields in
  validate_rejection
    context
    { reason
    ; t
    ; checksum
    ; success_tx_ids
    ; failed_tx_id
    ; missing_block_uuids
    ; error_detail
    ; data
    }
;;

let decode_client_fields context message_type fields =
  match message_type with
  | "hello" ->
    let* () = check_fields context [] [ "type"; "client" ] fields in
    let* client = required_string context [] "client" fields in
    Ok (Client.Hello { client })
  | "presence" ->
    let* () = check_fields context [] [ "type"; "editing-block-uuid" ] fields in
    let* editing_block_uuid =
      optional_nullable_string context [] "editing-block-uuid" fields
    in
    Ok (Client.Presence { editing_block_uuid })
  | "pull" ->
    let* () = check_fields context [] [ "type"; "since" ] fields in
    let* since = optional_cursor context [] "since" fields in
    Ok (Client.Pull { since })
  | "tx/batch" ->
    let* () =
      check_fields context [] [ "type"; "client-revision"; "t-before"; "txs" ] fields
    in
    let* client_revision = optional_string context [] "client-revision" fields in
    let* t_before = required_cursor context [] "t-before" fields in
    let* txs =
      required_list context [] "txs" (decode_client_transaction context) fields
    in
    Ok (Client.Tx_batch { client_revision; t_before; txs })
  | "ping" ->
    let* () = check_fields context [] [ "type" ] fields in
    Ok Client.Ping
  | unsupported -> error context [] (Unsupported_message_type unsupported)
;;

let decode_server_fields context message_type fields =
  match message_type with
  | "hello" ->
    let* () = check_fields context [] [ "type"; "t"; "checksum" ] fields in
    let* t = required_cursor context [] "t" fields in
    let* checksum = optional_checksum context [] fields in
    Ok (Server.Hello { t; checksum })
  | "online-users" ->
    let* () = check_fields context [] [ "type"; "online-users" ] fields in
    let* online_users =
      required_list context [] "online-users" (decode_user_presence context) fields
    in
    Ok (Server.Online_users { online_users })
  | "presence" ->
    let* () =
      check_fields context [] [ "type"; "user-id"; "editing-block-uuid" ] fields
    in
    let* user_id = required_string context [] "user-id" fields in
    let* editing_block_uuid =
      required_nullable_string context [] "editing-block-uuid" fields
    in
    Ok (Server.Presence { user_id; editing_block_uuid })
  | "pull/ok" ->
    let* () = check_fields context [] [ "type"; "t"; "checksum"; "txs" ] fields in
    let* t = required_cursor context [] "t" fields in
    let* checksum = optional_checksum context [] fields in
    let* txs = required_list context [] "txs" (decode_pull_transaction context) fields in
    Ok (Server.Pull_ok { t; checksum; txs })
  | "tx/batch/ok" ->
    let* () = check_fields context [] [ "type"; "t"; "checksum" ] fields in
    let* t = required_cursor context [] "t" fields in
    let* checksum = optional_checksum context [] fields in
    Ok (Server.Tx_batch_ok { t; checksum })
  | "changed" ->
    let* () = check_fields context [] [ "type"; "t" ] fields in
    let* t = required_cursor context [] "t" fields in
    Ok (Server.Changed { t })
  | "tx/reject" ->
    let* rejection = decode_rejection context fields in
    Ok (Server.Tx_reject rejection)
  | "pong" ->
    let* () = check_fields context [] [ "type" ] fields in
    Ok Server.Pong
  | "error" ->
    let* () = check_fields context [] [ "type"; "message" ] fields in
    let* message = required_string context [] "message" fields in
    Ok (Server.Error { message })
  | unsupported -> error context [] (Unsupported_message_type unsupported)
;;

let decode direction decode_fields wire =
  let context = { direction; message_type = None } in
  let maximum = maximum_wire_bytes direction in
  if String.length wire > maximum
  then error context [] (Limit_exceeded { maximum })
  else (
    try
      match Yojson.Safe.from_string wire with
      | `Assoc fields ->
        let* message_type = required_string context [] "type" fields in
        let context = { context with message_type = Some message_type } in
        decode_fields context message_type fields
      | _ -> error context [] Expected_object
    with
    | Yojson.Json_error _ -> error context [] Invalid_json)
;;

let decode_client_message = decode Client decode_client_fields
let decode_server_message = decode Server decode_server_fields
let uuid_json uuid = `String (Logseq_db_types.Graph_types.Uuid.to_string uuid)

let add_optional name encode value fields =
  match value with
  | None -> fields
  | Some value -> fields @ [ name, encode value ]
;;

let nullable_string_json = function
  | None -> `Null
  | Some value -> `String value
;;

let client_transaction_json (transaction : Client.transaction) =
  [ "tx", `String transaction.Client.tx ]
  |> add_optional "tx-id" uuid_json transaction.tx_id
  |> add_optional "outliner-op" (fun value -> `String value) transaction.outliner_op
  |> fun fields -> `Assoc fields
;;

let client_message_json = function
  | Client.Hello { client } ->
    `Assoc [ "type", `String "hello"; "client", `String client ]
  | Client.Presence { editing_block_uuid } ->
    let fields = [ "type", `String "presence" ] in
    let fields =
      add_optional
        "editing-block-uuid"
        (fun value -> `String value)
        editing_block_uuid
        fields
    in
    `Assoc fields
  | Client.Pull { since } ->
    let fields = [ "type", `String "pull" ] in
    `Assoc (add_optional "since" (fun value -> `Int value) since fields)
  | Client.Tx_batch { client_revision; t_before; txs } ->
    let fields = [ "type", `String "tx/batch" ] in
    let fields =
      add_optional "client-revision" (fun value -> `String value) client_revision fields
    in
    `Assoc
      (fields
       @ [ "t-before", `Int t_before
         ; "txs", `List (List.map client_transaction_json txs)
         ])
  | Client.Ping -> `Assoc [ "type", `String "ping" ]
;;

let user_presence_json (user : user_presence) =
  [ "user-id", `String user.user_id ]
  |> add_optional "email" (fun value -> `String value) user.email
  |> add_optional "username" (fun value -> `String value) user.username
  |> add_optional "name" (fun value -> `String value) user.name
  |> fun fields -> `Assoc fields
;;

let pull_transaction_json (transaction : Server.pull_transaction) =
  [ "t", `Int transaction.Server.t; "tx", `String transaction.tx ]
  |> add_optional "outliner-op" (fun value -> `String value) transaction.outliner_op
  |> fun fields -> `Assoc fields
;;

let rejection_reason_json = function
  | Stale -> "stale"
  | Db_transact_failed -> "db transact failed"
  | Empty_tx_data -> "empty tx data"
  | Invalid_tx -> "invalid tx"
  | Invalid_t_before -> "invalid t-before"
  | Snapshot_upload_in_progress -> "snapshot upload in progress"
;;

let add_non_empty_list name encode values fields =
  match values with
  | [] -> fields
  | _ :: _ -> fields @ [ name, `List (List.map encode values) ]
;;

let rejection_json (rejection : rejection) =
  [ "type", `String "tx/reject"
  ; "reason", `String (rejection_reason_json rejection.reason)
  ]
  |> add_optional "t" (fun value -> `Int value) rejection.t
  |> add_optional "checksum" (fun value -> `String value) rejection.checksum
  |> add_non_empty_list "success-tx-ids" uuid_json rejection.success_tx_ids
  |> add_optional "failed-tx-id" uuid_json rejection.failed_tx_id
  |> add_non_empty_list "missing-block-uuids" uuid_json rejection.missing_block_uuids
  |> add_optional "error-detail" (fun value -> `String value) rejection.error_detail
  |> add_optional "data" (fun value -> `String value) rejection.data
  |> fun fields -> `Assoc fields
;;

let server_message_json = function
  | Server.Hello { t; checksum } ->
    let fields = [ "type", `String "hello"; "t", `Int t ] in
    `Assoc (add_optional "checksum" (fun value -> `String value) checksum fields)
  | Server.Online_users { online_users } ->
    `Assoc
      [ "type", `String "online-users"
      ; "online-users", `List (List.map user_presence_json online_users)
      ]
  | Server.Presence { user_id; editing_block_uuid } ->
    `Assoc
      [ "type", `String "presence"
      ; "user-id", `String user_id
      ; "editing-block-uuid", nullable_string_json editing_block_uuid
      ]
  | Server.Pull_ok { t; checksum; txs } ->
    let fields = [ "type", `String "pull/ok"; "t", `Int t ] in
    let fields = add_optional "checksum" (fun value -> `String value) checksum fields in
    `Assoc (fields @ [ "txs", `List (List.map pull_transaction_json txs) ])
  | Server.Tx_batch_ok { t; checksum } ->
    let fields = [ "type", `String "tx/batch/ok"; "t", `Int t ] in
    `Assoc (add_optional "checksum" (fun value -> `String value) checksum fields)
  | Server.Changed { t } -> `Assoc [ "type", `String "changed"; "t", `Int t ]
  | Server.Tx_reject rejection -> rejection_json rejection
  | Server.Pong -> `Assoc [ "type", `String "pong" ]
  | Server.Error { message } ->
    `Assoc [ "type", `String "error"; "message", `String message ]
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
