type phase =
  | Fetching_graph_key
  | Fetching_user_keys
  | Awaiting_password
  | Ready
  | Failed

type platform =
  { has_private_key : managed_sync_origin:Uri.t -> user_id:string -> bool
  ; unlock_private_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> password:string
      -> private_key_package:string
      -> (unit, string) result
  }

type t =
  { platform : platform
  ; managed_sync_origin : Uri.t
  ; user_id : string
  ; graph_id : Graph_types.Uuid.t
  ; graph_name : string
  ; mutable phase : phase
  ; mutable encrypted_graph_key : string option
  ; mutable private_key_package : string option
  }

let create ~platform ~managed_sync_origin ~user_id ~graph_id ~graph_name =
  { platform
  ; managed_sync_origin
  ; user_id
  ; graph_id
  ; graph_name
  ; phase = Fetching_graph_key
  ; encrypted_graph_key = None
  ; private_key_package = None
  }
;;

let phase t = t.phase
let graph_name t = t.graph_name
let encrypted_graph_key t = t.encrypted_graph_key

let bounded_string field = function
  | `String value
    when String.length value > 0
         && String.length value <= 65_536
         && String.is_valid_utf_8 value
         && not (String.contains value '\000') -> Ok value
  | `String _
  | `Assoc _
  | `List _
  | `Tuple _
  | `Variant _
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _ -> Error ("E2EE response " ^ field ^ " must be a bounded non-empty string")
;;

let graph_key_response source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc [ ("encrypted-aes-key", value) ] -> bounded_string "encrypted-aes-key" value
    | `Assoc _ | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ ->
      Error "E2EE graph-key response must contain exactly one encrypted-aes-key string"
  with
  | Yojson.Json_error _ -> Error "E2EE response must be valid JSON"
;;

let user_keys_response source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc
        [ ("public-key", public_key); ("encrypted-private-key", encrypted_private_key) ]
    | `Assoc
        [ ("encrypted-private-key", encrypted_private_key); ("public-key", public_key) ]
      ->
      (match bounded_string "public-key" public_key with
       | Error _ as error -> error
       | Ok _ -> bounded_string "encrypted-private-key" encrypted_private_key)
    | `Assoc _ | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ ->
      Error
        "E2EE user-key response must contain exactly public-key and \
         encrypted-private-key strings"
  with
  | Yojson.Json_error _ -> Error "E2EE response must be valid JSON"
;;

let accept_graph_key_response t source =
  ignore t.graph_id;
  match graph_key_response source with
  | Error _ as error -> error
  | Ok encrypted_graph_key ->
    (match Action.wrapped_graph_key_of_string encrypted_graph_key with
     | None -> Error "E2EE graph-key response contains invalid wrapped ciphertext"
     | Some _ ->
       t.encrypted_graph_key <- Some encrypted_graph_key;
       if
         t.platform.has_private_key
           ~managed_sync_origin:t.managed_sync_origin
           ~user_id:t.user_id
       then t.phase <- Ready
       else t.phase <- Fetching_user_keys;
       Ok ())
;;

let accept_user_keys_response t source =
  if t.phase <> Fetching_user_keys
  then Error "E2EE user keys are unsolicited"
  else (
    match user_keys_response source with
    | Error _ as error -> error
    | Ok private_key_package ->
      t.private_key_package <- Some private_key_package;
      t.phase <- Awaiting_password;
      Ok ())
;;

let submit_password t password =
  if t.phase <> Awaiting_password
  then Error "E2EE password is unsolicited"
  else if
    String.length password = 0
    || String.length password > 4096
    || (not (String.is_valid_utf_8 password))
    || String.contains password '\000'
  then Error "E2EE password must be bounded non-empty UTF-8 text"
  else (
    match t.private_key_package, t.encrypted_graph_key with
    | Some private_key_package, Some encrypted_graph_key ->
      (match
         t.platform.unlock_private_key
           ~managed_sync_origin:t.managed_sync_origin
           ~user_id:t.user_id
           ~password
           ~private_key_package
       with
       | Error _ as error -> error
       | Ok () ->
         ignore encrypted_graph_key;
         t.phase <- Ready;
         Ok ())
    | Some _, None | None, Some _ | None, None -> Error "E2EE session is incomplete")
;;

let clear t =
  t.encrypted_graph_key <- None;
  t.private_key_package <- None;
  t.phase <- Failed
;;
