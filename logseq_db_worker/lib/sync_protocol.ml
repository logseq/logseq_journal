type pull_tx =
  { t : int
  ; tx : string
  ; outliner_op : string option
  }

type reject_reason =
  | Stale
  | Db_transact_failed
  | Empty_tx_data
  | Invalid_tx
  | Invalid_t_before
  | Snapshot_upload_in_progress

type server_message =
  | Hello of
      { t : int
      ; checksum : string option
      }
  | Pull_ok of
      { t : int
      ; checksum : string option
      ; txs : pull_tx list
      }
  | Changed of { t : int }
  | Tx_batch_ok of
      { t : int
      ; checksum : string option
      }
  | Tx_reject of
      { reason : reject_reason
      ; t : int option
      ; success_tx_ids : string list
      ; failed_tx_id : string option
      ; data : string option
      }
  | Server_error of { message : string }
  | Pong
  | Online_users

type outgoing_tx =
  { tx : string
  ; tx_id : string
  ; outliner_op : string option
  }

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let field name fields = List.assoc_opt name fields

let string name fields =
  match field name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (name ^ " must be a string")
  | None -> Error ("missing field: " ^ name)
;;

let non_negative_int name fields =
  match field name fields with
  | Some (`Int value) when value >= 0 -> Ok value
  | Some _ -> Error (name ^ " must be a non-negative integer")
  | None -> Error ("missing field: " ^ name)
;;

let checksum name fields =
  let hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  bind (string name fields) (fun value ->
    if String.length value = 16 && String.for_all hex value
    then Ok value
    else Error (name ^ " must be a 16-character lowercase hexadecimal checksum"))
;;

let optional_checksum name fields =
  match field name fields with
  | None -> Ok None
  | Some _ -> bind (checksum name fields) (fun value -> Ok (Some value))
;;

let optional_string name fields =
  match field name fields with
  | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (name ^ " must be a string")
;;

let optional_nullable_string name fields =
  match field name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (name ^ " must be a string or null")
;;

let optional_non_negative_int name fields =
  match field name fields with
  | None -> Ok None
  | Some (`Int value) when value >= 0 -> Ok (Some value)
  | Some _ -> Error (name ^ " must be a non-negative integer")
;;

let valid_uuid value =
  match Graph_types.Uuid.of_string value with
  | Ok _ -> true
  | Error _ -> false
;;

let optional_uuid name fields =
  bind (optional_string name fields) (function
    | None -> Ok None
    | Some value when valid_uuid value -> Ok (Some value)
    | Some _ -> Error (name ^ " must be a UUID"))
;;

let optional_uuid_list name fields =
  match field name fields with
  | None -> Ok []
  | Some (`List values) ->
    let rec decode decoded = function
      | [] -> Ok (List.rev decoded)
      | `String value :: rest when valid_uuid value -> decode (value :: decoded) rest
      | _ -> Error (name ^ " must contain only UUID strings")
    in
    decode [] values
  | Some _ -> Error (name ^ " must be an array")
;;

let decode_pull_tx = function
  | `Assoc fields ->
    bind (non_negative_int "t" fields) (fun t ->
      bind (string "tx" fields) (fun tx ->
        bind (optional_nullable_string "outliner-op" fields) (fun outliner_op ->
          Ok { t; tx; outliner_op })))
  | _ -> Error "pull transaction must be an object"
;;

let decode_list decode = function
  | `List values ->
    let rec loop decoded = function
      | [] -> Ok (List.rev decoded)
      | value :: rest -> bind (decode value) (fun item -> loop (item :: decoded) rest)
    in
    loop [] values
  | _ -> Error "txs must be an array"
;;

let reject_reason = function
  | "stale" -> Ok Stale
  | "db transact failed" -> Ok Db_transact_failed
  | "empty tx data" -> Ok Empty_tx_data
  | "invalid tx" -> Ok Invalid_tx
  | "invalid t-before" -> Ok Invalid_t_before
  | "snapshot upload in progress" -> Ok Snapshot_upload_in_progress
  | value -> Error ("unsupported tx/reject reason: " ^ value)
;;

let decode_reject fields =
  bind (string "reason" fields) (fun reason_text ->
    bind (reject_reason reason_text) (fun reason ->
      bind (optional_non_negative_int "t" fields) (fun t ->
        bind (optional_uuid_list "success-tx-ids" fields) (fun success_tx_ids ->
          bind (optional_uuid "failed-tx-id" fields) (fun failed_tx_id ->
            bind (optional_string "data" fields) (fun data ->
              let valid =
                match reason with
                | Stale ->
                  Option.is_some t && success_tx_ids = [] && Option.is_none failed_tx_id
                | Db_transact_failed ->
                  Option.is_some t
                  && List.mem_assoc "success-tx-ids" fields
                  && Option.is_some failed_tx_id
                | Empty_tx_data
                | Invalid_tx
                | Invalid_t_before
                | Snapshot_upload_in_progress ->
                  success_tx_ids = [] && Option.is_none failed_tx_id
              in
              if valid
              then Ok (Tx_reject { reason; t; success_tx_ids; failed_tx_id; data })
              else Error "tx/reject fields do not match its reason"))))))
;;

let decode_json = function
  | `Assoc fields ->
    bind (string "type" fields) (function
      | "hello" ->
        bind (non_negative_int "t" fields) (fun t ->
          bind (optional_checksum "checksum" fields) (fun checksum ->
            Ok (Hello { t; checksum })))
      | "pull/ok" ->
        bind (non_negative_int "t" fields) (fun t ->
          bind (optional_checksum "checksum" fields) (fun checksum ->
            match field "txs" fields with
            | None -> Error "missing field: txs"
            | Some txs ->
              bind (decode_list decode_pull_tx txs) (fun txs ->
                Ok (Pull_ok { t; checksum; txs }))))
      | "changed" -> bind (non_negative_int "t" fields) (fun t -> Ok (Changed { t }))
      | "tx/batch/ok" ->
        bind (non_negative_int "t" fields) (fun t ->
          bind (optional_checksum "checksum" fields) (fun checksum ->
            Ok (Tx_batch_ok { t; checksum })))
      | "tx/reject" -> decode_reject fields
      | "error" ->
        bind (string "message" fields) (fun message -> Ok (Server_error { message }))
      | "pong" -> Ok Pong
      | "online-users" ->
        (match field "online-users" fields with
         | Some (`List _) -> Ok Online_users
         | Some _ -> Error "online-users must be an array"
         | None -> Error "missing field: online-users")
      | message_type -> Error ("unsupported server message: " ^ message_type))
  | _ -> Error "server message must be a JSON object"
;;

let decode_server_message wire =
  try decode_json (Yojson.Safe.from_string wire) with
  | Yojson.Json_error message -> Error message
;;

let decode_http_pull_response wire =
  bind (decode_server_message wire) (function
    | Pull_ok _ as message -> Ok message
    | _ -> Error "HTTP pull response must be pull/ok")
;;

let validate_pull_continuity ~applied_t = function
  | Pull_ok { t; txs; _ } ->
    if applied_t < 0
    then Error "applied server t must be non-negative"
    else if t < applied_t
    then Error "pull response is older than the applied server t"
    else if t = applied_t
    then
      if List.for_all (fun tx -> tx.t <= applied_t) txs
      then Ok ()
      else Error "duplicate pull contains a future transaction"
    else (
      let rec loop expected = function
        | [] ->
          if expected - 1 = t
          then Ok ()
          else Error "pull response t does not match its final transaction"
        | tx :: rest ->
          if tx.t = expected
          then loop (expected + 1) rest
          else Error "pull response contains a server t gap"
      in
      loop (applied_t + 1) txs)
  | _ -> Error "cursor continuity can only validate pull/ok"
;;

let validate_checksum ~local ~remote =
  if String.equal local remote then Ok () else Error "entity checksum mismatch"
;;

let encode_hello ~client =
  Yojson.Safe.to_string (`Assoc [ "type", `String "hello"; "client", `String client ])
;;

let encode_pull ~since =
  if since < 0 then invalid_arg "since must be non-negative";
  Yojson.Safe.to_string (`Assoc [ "type", `String "pull"; "since", `Int since ])
;;

let decode_tx_batch_ids wire =
  try
    match Yojson.Safe.from_string wire with
    | `Assoc fields ->
      let names = List.map fst fields |> List.sort String.compare in
      if names <> [ "t-before"; "txs"; "type" ]
      then Error "tx/batch fields are invalid"
      else (
        match List.assoc_opt "type" fields, List.assoc_opt "txs" fields with
        | Some (`String "tx/batch"), Some (`List txs) when txs <> [] ->
          let rec decode ids = function
            | [] ->
              let unique = List.sort_uniq Graph_types.Uuid.compare ids in
              if List.length unique = List.length ids
              then Ok (List.rev ids)
              else Error "tx/batch contains duplicate transaction IDs"
            | `Assoc entry :: rest ->
              (match List.assoc_opt "tx-id" entry with
               | Some (`String value) ->
                 Result.bind (Graph_types.Uuid.of_string value) (fun tx_id ->
                   decode (tx_id :: ids) rest)
               | Some _ | None -> Error "tx/batch entry has no valid transaction ID")
            | _ :: _ -> Error "tx/batch entry must be an object"
          in
          decode [] txs
        | Some _, _ | None, _ -> Error "message is not a tx/batch")
    | _ -> Error "tx/batch must be an object"
  with
  | Yojson.Json_error message -> Error message
;;

let encode_outgoing_tx entry =
  let fields = [ "tx", `String entry.tx; "tx-id", `String entry.tx_id ] in
  let fields =
    match entry.outliner_op with
    | None -> fields
    | Some value -> fields @ [ "outliner-op", `String value ]
  in
  `Assoc fields
;;

let encode_tx_batch ~t_before txs =
  if t_before < 0
  then Error "t-before must be non-negative"
  else if txs = []
  then Error "tx/batch must contain at least one transaction"
  else if List.exists (fun entry -> not (valid_uuid entry.tx_id)) txs
  then Error "every tx-id must be a UUID"
  else if List.exists (fun entry -> String.length entry.tx = 0) txs
  then Error "every transaction must contain Transit data"
  else
    Ok
      (Yojson.Safe.to_string
         (`Assoc
             [ "type", `String "tx/batch"
             ; "t-before", `Int t_before
             ; "txs", `List (List.map encode_outgoing_tx txs)
             ]))
;;
