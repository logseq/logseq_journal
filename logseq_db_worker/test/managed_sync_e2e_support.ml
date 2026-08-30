type credentials =
  { username : string
  ; password : string
  ; e2ee_password : string
  ; graph_name : string
  }

type cognito_session =
  { user_id : string
  ; id_token : string
  }

let maximum_credential_bytes = 4_096
let contains_nul value = String.contains value '\000'

let credential getenv name =
  match getenv name with
  | None -> Error (name ^ " is required")
  | Some value when String.length value = 0 -> Error (name ^ " must not be empty")
  | Some value when contains_nul value -> Error (name ^ " must not contain NUL")
  | Some value when String.length value > maximum_credential_bytes ->
    Error (name ^ " is too large")
  | Some value -> Ok value
;;

let credentials_from_environment getenv =
  match
    ( credential getenv "LOGSEQ_DB_WORKER_E2E_USERNAME"
    , credential getenv "LOGSEQ_DB_WORKER_E2E_PASSWORD"
    , credential getenv "LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD"
    , credential getenv "LOGSEQ_DB_WORKER_E2E_GRAPH_NAME" )
  with
  | Ok username, Ok password, Ok e2ee_password, Ok graph_name ->
    Ok { username; password; e2ee_password; graph_name }
  | Error message, _, _, _
  | _, Error message, _, _
  | _, _, Error message, _
  | _, _, _, Error message -> Error message
;;

let base64url_value = function
  | 'A' .. 'Z' as character -> Ok (Char.code character - Char.code 'A')
  | 'a' .. 'z' as character -> Ok (Char.code character - Char.code 'a' + 26)
  | '0' .. '9' as character -> Ok (Char.code character - Char.code '0' + 52)
  | '-' -> Ok 62
  | '_' -> Ok 63
  | _ -> Error "ID token payload is not base64url"
;;

let base64url_decode value =
  let length = String.length value in
  if length = 0 || length mod 4 = 1
  then Error "ID token payload is malformed"
  else (
    let output = Buffer.create (length * 3 / 4) in
    let rec decode offset =
      if offset = length
      then Ok (Buffer.contents output)
      else (
        let remaining = length - offset in
        let count = min 4 remaining in
        if count = 1
        then Error "ID token payload is malformed"
        else (
          let rec values index acc =
            if index = count
            then Ok (List.rev acc)
            else (
              match base64url_value value.[offset + index] with
              | Error _ as error -> error
              | Ok decoded -> values (index + 1) (decoded :: acc))
          in
          match values 0 [] with
          | Error _ as error -> error
          | Ok decoded ->
            let get index = if index < count then List.nth decoded index else 0 in
            Buffer.add_char output (Char.chr ((get 0 lsl 2) lor (get 1 lsr 4)));
            if count >= 3
            then
              Buffer.add_char
                output
                (Char.chr (((get 1 land 0x0f) lsl 4) lor (get 2 lsr 2)));
            if count = 4
            then Buffer.add_char output (Char.chr (((get 2 land 0x03) lsl 6) lor get 3));
            decode (offset + count)))
    in
    decode 0)
;;

let token_subject token =
  if String.length token = 0 || String.length token > 65_536 || contains_nul token
  then Error "Cognito ID token is invalid"
  else (
    match String.split_on_char '.' token with
    | [ _header; payload; _signature ] ->
      (match base64url_decode payload with
       | Error _ -> Error "Cognito ID token payload is invalid"
       | Ok decoded ->
         (try
            let open Yojson.Safe.Util in
            let subject = Yojson.Safe.from_string decoded |> member "sub" |> to_string in
            if
              String.length subject = 0
              || String.length subject > 256
              || contains_nul subject
            then Error "Cognito ID token subject is invalid"
            else Ok subject
          with
          | _ -> Error "Cognito ID token subject is missing"))
    | _ -> Error "Cognito ID token is malformed")
;;

let cognito_session_of_response response =
  if String.length response = 0 || String.length response > 65_536
  then Error "Cognito response is invalid"
  else (
    try
      let open Yojson.Safe.Util in
      let id_token =
        Yojson.Safe.from_string response
        |> member "AuthenticationResult"
        |> member "IdToken"
        |> to_string
      in
      match token_subject id_token with
      | Error _ as error -> error
      | Ok user_id -> Ok { user_id; id_token }
    with
    | _ -> Error "Cognito authentication did not return an ID token")
;;

let named_encrypted_graph ~name graphs =
  let matching =
    List.filter
      (fun graph -> String.equal graph.Logseq_db_types.Managed_graph.name name)
      graphs
  in
  match matching with
  | [ graph ] when graph.encrypted -> Ok graph
  | [ _ ] -> Error "the configured graph must be encrypted"
  | [] -> Error "the configured graph is absent"
  | _ -> Error "the configured graph name must be unique"
;;

let catalog_graph ~name = function
  | [] -> Ok None
  | graphs ->
    (match named_encrypted_graph ~name graphs with
     | Ok graph -> Ok (Some graph)
     | Error _ as error -> error)
;;

let read_bounded channel maximum =
  let buffer = Buffer.create 4_096 in
  let chunk = Bytes.create 4_096 in
  let rec loop total =
    let count = input channel chunk 0 (Bytes.length chunk) in
    if count = 0
    then Ok (Buffer.contents buffer)
    else if total + count > maximum
    then Error "authentication response is too large"
    else (
      Buffer.add_subbytes buffer chunk 0 count;
      loop (total + count))
  in
  loop 0
;;

let rec repository_root directory =
  if Sys.file_exists (Filename.concat directory "dune-project")
  then Ok directory
  else (
    let parent = Filename.dirname directory in
    if String.equal parent directory
    then Error "the repository root is unavailable"
    else repository_root parent)
;;

let authenticate credentials =
  let payload =
    Yojson.Safe.to_string
      (`Assoc
          [ "AuthFlow", `String "USER_PASSWORD_AUTH"
          ; "ClientId", `String "69cs1lgme7p8kbgld8n5kseii6"
          ; ( "AuthParameters"
            , `Assoc
                [ "USERNAME", `String credentials.username
                ; "PASSWORD", `String credentials.password
                ] )
          ])
  in
  match repository_root (Sys.getcwd ()) with
  | Error _ as error -> error
  | Ok root ->
    let helper = Filename.concat root "logseq_db_worker/tool/cognito_e2e_login.sh" in
    let executable = "/bin/sh" in
    let arguments = [| executable; helper |] in
    if not (Sys.file_exists helper)
    then Error "the macOS credential helper is unavailable"
    else (
      try
        let stdout, stdin, stderr =
          Unix.open_process_args_full executable arguments (Unix.environment ())
        in
        output_string stdin payload;
        flush stdin;
        close_out stdin;
        let response = read_bounded stdout 65_536 in
        let _ = read_bounded stderr 8_192 in
        let status = Unix.close_process_full (stdout, stdin, stderr) in
        match status, response with
        | Unix.WEXITED 0, Ok response -> cognito_session_of_response response
        | Unix.WEXITED 0, Error message -> Error message
        | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ ->
          Error "Cognito authentication failed"
      with
      | _ -> Error "Cognito authentication helper failed")
;;
