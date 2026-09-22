module Core = Logseq_sync_pure_reducer.Core
module Sync_protocol = Logseq_sync_pure_reducer.Sync_protocol

type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string

type runtime =
  { fork : sw:Eio.Switch.t -> (unit -> unit) -> unit
  ; sleep : float -> unit
  }

let runtime ~fork ~sleep = Ok { fork; sleep }

type transport =
  { perform_http : sw:Eio.Switch.t -> Http.request -> (Http_eio.response, string) result
  ; download :
      sw:Eio.Switch.t
      -> request:Http.request
      -> destination:string
      -> maximum_bytes:int
      -> on_progress:(Bootstrap.progress -> unit)
      -> (Http_eio.response, string) result
  ; connect_websocket :
      sw:Eio.Switch.t
      -> uri:Uri.t
      -> token:string
      -> maximum_frame_bytes:int
      -> on_message:(string -> unit)
      -> on_close:(string option -> unit)
      -> (Websocket_eio.t, Websocket_eio.connect_error) result
  ; send_websocket : Websocket_eio.t -> string -> (unit, string) result
  ; close_websocket : Websocket_eio.t -> unit
  ; abort_websocket : Websocket_eio.t -> unit
  ; activate_websocket :
      Websocket_eio.t
      -> on_open:(unit -> unit)
      -> (unit, Websocket_eio.connect_error) result
  }

type tls_authenticator = X509.Authenticator.t

type id_token_provider =
  { acquire : Core.account_scope -> (string, string) result
  ; invalidate : Core.account_scope -> token:string -> unit
  }

let id_token_provider ~acquire ~invalidate = { acquire; invalidate }

type authenticated_failure =
  | Unauthorized
  | Forbidden
  | Request_failed of string

let authenticated_failure = function
  | Unauthorized -> "Authentication failed."
  | Forbidden -> "Authorization failed."
  | Request_failed message -> message
;;

let authenticated_operation provider ~account ~perform =
  match provider.acquire account with
  | Error message -> Error message
  | Ok token ->
    (match perform token with
     | Ok _ as result -> result
     | Error Unauthorized ->
       provider.invalidate account ~token;
       (match provider.acquire account with
        | Error message -> Error message
        | Ok refreshed -> Result.map_error authenticated_failure (perform refreshed))
     | Error failure -> Error (authenticated_failure failure))
;;

let tls_authenticator authenticator = authenticator

let system_tls_authenticator () =
  Ca_certs_nss.authenticator ()
  |> Result.map_error (fun (`Msg message) -> Invalid_dependency message)
;;

type websocket_liveness =
  | Disabled
  | Ping_pong of
      { interval_seconds : float
      ; timeout_seconds : float
      }

let transport ~tls_authenticator ~network ~clock ~websocket_liveness =
  let valid = function
    | Disabled -> true
    | Ping_pong { interval_seconds; timeout_seconds } ->
      Float.is_finite interval_seconds
      && Float.is_finite timeout_seconds
      && interval_seconds > 0.
      && timeout_seconds > 0.
  in
  let liveness =
    match websocket_liveness with
    | Disabled -> Websocket_eio.Disabled
    | Ping_pong { interval_seconds; timeout_seconds } ->
      Websocket_eio.Ping_pong { interval_seconds; timeout_seconds }
  in
  if not (valid websocket_liveness)
  then
    Error (Invalid_dependency "WebSocket liveness durations must be finite and positive")
  else
    Ok
      { perform_http =
          (fun ~sw request ->
            Http_eio.perform ~sw ~authenticator:tls_authenticator ~network ~clock request)
      ; download =
          (fun ~sw ~request ~destination ~maximum_bytes ~on_progress ->
            Http_eio.download
              ~sw
              ~authenticator:tls_authenticator
              ~network
              ~clock
              ~request
              ~destination
              ~maximum_bytes
              ~on_progress)
      ; connect_websocket =
          (fun ~sw ~uri ~token ~maximum_frame_bytes ~on_message ~on_close ->
            Websocket_eio.connect
              ~liveness
              ~sw
              ~authenticator:tls_authenticator
              ~network
              ~clock
              ~uri
              ~token
              ~maximum_frame_bytes
              ~on_message
              ~on_close)
      ; send_websocket = Websocket_eio.send
      ; close_websocket = Websocket_eio.close
      ; abort_websocket = Websocket_eio.abort
      ; activate_websocket = Websocket_eio.activate
      }
;;

type local_store = { application_support_directory : string }

let existing_directory path =
  String.length path > 0 && Sys.file_exists path && (Unix.stat path).st_kind = Unix.S_DIR
;;

let local_store ~application_support_directory =
  if existing_directory application_support_directory
  then Ok { application_support_directory }
  else Error (Invalid_dependency "application support directory does not exist")
;;

type artifact_store = { staging_directory : string }

let artifact_store ~staging_directory =
  if String.length staging_directory = 0
  then Error (Invalid_dependency "staging directory must not be empty")
  else Ok { staging_directory }
;;

type wrapped_key_load_error =
  | Wrapped_graph_key_unavailable of string
  | Local_private_key_unavailable of string

type secrets =
  { unlock_private_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> password:string
      -> private_key_package:string
      -> (unit, string) result
  ; unlock_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> encrypted_graph_key:string
      -> (string, string) result
  ; load_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:Core.graph_id
      -> (string, wrapped_key_load_error) result
  ; verify_and_save_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:Core.graph_id
      -> encrypted_graph_key:string
      -> (unit, string) result
  ; delete_account_secrets :
      managed_sync_origin:Uri.t -> user_id:string -> (unit, string) result
  }

let secrets
      ~unlock_private_key
      ~unlock_graph_key
      ~load_wrapped_graph_key
      ~verify_and_save_wrapped_graph_key
      ~delete_account_secrets
  =
  Ok
    { unlock_private_key
    ; unlock_graph_key
    ; load_wrapped_graph_key
    ; verify_and_save_wrapped_graph_key
    ; delete_account_secrets
    }
;;

type crypto =
  { encrypt_aes_gcm : key:string -> plaintext:string -> (string * string, string) result
  ; decrypt_aes_gcm :
      key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

let crypto ~encrypt_aes_gcm ~decrypt_aes_gcm = Ok { encrypt_aes_gcm; decrypt_aes_gcm }

let apple_secrets () =
  secrets
    ~unlock_private_key:Platform_crypto.unlock_private_key
    ~unlock_graph_key:Platform_crypto.unlock_graph_key
    ~load_wrapped_graph_key:(fun ~managed_sync_origin ~user_id ~graph_id ->
      match
        Platform_crypto.load_wrapped_graph_key ~managed_sync_origin ~user_id ~graph_id
      with
      | Ok key -> Ok key
      | Error (Platform_crypto.Wrapped_graph_key_unavailable message) ->
        Error (Wrapped_graph_key_unavailable message)
      | Error (Platform_crypto.Local_private_key_unavailable message) ->
        Error (Local_private_key_unavailable message))
    ~verify_and_save_wrapped_graph_key:Platform_crypto.verify_and_save_wrapped_graph_key
    ~delete_account_secrets:Platform_crypto.delete_account_secrets
;;

let apple_crypto () =
  let adapter = Platform_crypto.crypto in
  crypto ~encrypt_aes_gcm:adapter.encrypt_aes_gcm ~decrypt_aes_gcm:adapter.decrypt_aes_gcm
;;

type dependencies =
  { runtime : runtime
  ; transport : transport
  ; local_store : local_store
  ; artifact_store : artifact_store
  ; secrets : secrets
  ; crypto : crypto
  ; id_token_provider : id_token_provider
  }

let dependencies
      ~runtime
      ~transport
      ~local_store
      ~artifact_store
      ~secrets
      ~crypto
      ~id_token_provider
  =
  Ok
    { runtime
    ; transport
    ; local_store
    ; artifact_store
    ; secrets
    ; crypto
    ; id_token_provider
    }
;;

type operation =
  { scope : Core.effect_scope
  ; mutable cancelled : bool
  ; cancel : unit -> unit
  }

type key_entry =
  { scope : Core.graph_scope
  ; bytes : bytes
  }

type t =
  { sw : Eio.Switch.t
  ; dependencies : dependencies
  ; post : Core.event -> unit
  ; operations : (string, operation) Hashtbl.t
  ; keys : (string, key_entry) Hashtbl.t
  ; websockets : (string, Core.connection_scope * Websocket_eio.t) Hashtbl.t
  ; asset_download_slots : Eio.Semaphore.t
  ; asset_upload_slots : Eio.Semaphore.t
  ; asset_codec_slot : Eio.Semaphore.t
  ; secret_lock : Eio.Mutex.t
  ; asset_caches : (Core.graph_scope, Asset_cache.t) Hashtbl.t
  ; mutable closed : bool
  }

let create ~sw dependencies ~post =
  Ok
    { sw
    ; dependencies
    ; post
    ; operations = Hashtbl.create 32
    ; keys = Hashtbl.create 8
    ; websockets = Hashtbl.create 4
    ; asset_download_slots = Eio.Semaphore.make 3
    ; asset_upload_slots = Eio.Semaphore.make 1
    ; asset_codec_slot = Eio.Semaphore.make 1
    ; secret_lock = Eio.Mutex.create ()
    ; asset_caches = Hashtbl.create 4
    ; closed = false
    }
;;

let asset_root t =
  Filename.concat
    t.dependencies.local_store.application_support_directory
    "logseq-db-worker/assets"
;;

let delete_account_assets t (account : Core.account_scope) =
  Hashtbl.filter_map_inplace
    (fun (scope : Core.graph_scope) cache ->
       if
         Uri.equal scope.account.managed_sync_origin account.managed_sync_origin
         && String.equal scope.account.user_id account.user_id
       then (
         Asset_cache.close cache;
         None)
       else Some cache)
    t.asset_caches;
  Asset_cache.delete_account ~root:(asset_root t) ~account
;;

let catalog_root local_store =
  Filename.concat
    local_store.application_support_directory
    "logseq-db-worker/sync-catalogs"
;;

let cache_path local_store (account : Core.account_scope) =
  let identity = account.user_id ^ "\000" ^ Uri.to_string account.managed_sync_origin in
  let name = Digestif.SHA256.digest_string identity |> Digestif.SHA256.to_hex in
  Filename.concat (catalog_root local_store) (name ^ ".json")
;;

let load_catalog local_store account =
  let path = cache_path local_store account in
  if not (Sys.file_exists path)
  then Ok None
  else (
    try
      let channel = open_in_bin path in
      let source =
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () -> really_input_string channel (in_channel_length channel))
      in
      Core.decode_catalog_cache source
      |> Result.map Option.some
      |> Result.map_error (fun message -> Core.Effect_failed message)
    with
    | Sys_error message -> Error (Core.Effect_failed message))
;;

let ensure_directory path =
  try
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then Ok ()
      else Error (Core.Effect_failed (path ^ " is not a directory"))
    else (
      Unix.mkdir path 0o700;
      Ok ())
  with
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Core.Effect_failed
         (Printf.sprintf "%s(%s): %s" operation target (Unix.error_message error)))
;;

let save_catalog local_store account cache =
  if not (String.equal account.Core.user_id (Core.catalog_cache_user_id cache))
  then Error (Core.Effect_failed "catalog cache owner does not match its account scope")
  else (
    let worker_root =
      Filename.concat local_store.application_support_directory "logseq-db-worker"
    in
    Result.bind (ensure_directory worker_root) (fun () ->
      Result.bind
        (ensure_directory (catalog_root local_store))
        (fun () ->
           let path = cache_path local_store account in
           try
             let channel = open_out_bin path in
             Fun.protect
               ~finally:(fun () -> close_out_noerr channel)
               (fun () -> output_string channel (Core.encode_catalog_cache cache));
             Ok ()
           with
           | Sys_error message -> Error (Core.Effect_failed message))))
;;

let effect_error message = Error (Core.Effect_failed message)

let successful_response request (response : Http_eio.response) =
  if response.status < 200 || response.status >= 300
  then
    effect_error
      (Printf.sprintf "sync HTTP request failed with status %d" response.status)
  else (
    match Http.validate_response_content_type request response.headers with
    | Error message -> effect_error message
    | Ok () -> Ok response)
;;

let perform_authenticated_http t account make_request =
  authenticated_operation t.dependencies.id_token_provider ~account ~perform:(fun token ->
    let request = make_request token in
    match t.dependencies.transport.perform_http ~sw:t.sw request with
    | Error message -> Error (Request_failed message)
    | Ok response when response.Http_eio.status = 401 -> Error Unauthorized
    | Ok response when response.Http_eio.status = 403 -> Error Forbidden
    | Ok response ->
      successful_response request response
      |> Result.map_error (function
          | Core.Effect_failed message | Crypto_failed (_, message) ->
          Request_failed message))
  |> Result.map_error (fun message -> Core.Effect_failed message)
;;

let key t handle =
  let id = Core.graph_key_handle_id handle in
  match Hashtbl.find_opt t.keys id with
  | Some entry when entry.scope = Core.graph_key_handle_scope handle ->
    Ok (Bytes.to_string entry.bytes)
  | Some _ | None -> effect_error "graph key handle is unavailable or out of scope"
;;

let decrypt_protected_value t handle source =
  match key t handle with
  | Error (Core.Effect_failed message | Crypto_failed (_, message)) -> Error message
  | Ok graph_key ->
    let crypto : E2ee.crypto =
      { decrypt_aes_gcm = t.dependencies.crypto.decrypt_aes_gcm }
    in
    Result.bind (E2ee.decrypt_value ~crypto ~graph_key source) (function
      | Transit_core.Json.String plaintext -> Ok plaintext
      | _ -> Error "decrypted protected value must be a string")
;;

let encrypt_protected_values t handle plaintexts =
  match key t handle with
  | Error (Core.Effect_failed message | Crypto_failed (_, message)) -> Error message
  | Ok graph_key ->
    let rec encrypt encrypted = function
      | [] -> Ok (List.rev encrypted)
      | plaintext :: rest ->
        (match t.dependencies.crypto.encrypt_aes_gcm ~key:graph_key ~plaintext with
         | Ok value -> encrypt (value :: encrypted) rest
         | Error message -> Error message)
    in
    encrypt [] plaintexts
;;

let store_key t ticket scope plaintext =
  let id = "graph-key-" ^ Core.effect_id_to_string (Core.effect_ticket_id ticket) in
  Hashtbl.replace t.keys id { scope; bytes = Bytes.of_string plaintext };
  Core.graph_key_handle ~id ~scope
;;

let map_error result = Result.map_error (fun message -> Core.Effect_failed message) result
let run_secret_action t action = Eio.Mutex.use_rw ~protect:true t.secret_lock action

let execute_request
  : type a.
    t -> a Core.effect_ticket -> a Core.runner_request -> (a, Core.effect_error) result
  =
  fun t ticket request ->
  match request with
  | Core.Load_catalog account -> load_catalog t.dependencies.local_store account
  | Save_catalog { account; cache } ->
    save_catalog t.dependencies.local_store account cache
  | Fetch_catalog account ->
    Result.bind
      (perform_authenticated_http t account (fun token ->
         Http.catalog ~base_url:account.managed_sync_origin ~token))
      (fun response ->
         Catalog.decode response.body
         |> Result.map_error (fun message -> Core.Effect_failed message))
  | Fetch_snapshot_baseline graph ->
    Result.map
      (fun response -> response.Http_eio.body)
      (perform_authenticated_http t graph.account (fun token ->
         Http.snapshot_baseline
           ~base_url:graph.account.managed_sync_origin
           ~graph_id:graph.graph_id
           ~token))
  | Fetch_snapshot_metadata graph ->
    Result.map
      (fun response -> response.Http_eio.body)
      (perform_authenticated_http t graph.account (fun token ->
         Http.snapshot_metadata
           ~base_url:graph.account.managed_sync_origin
           ~graph_id:graph.graph_id
           ~token))
  | Fetch_e2ee_graph_key graph ->
    Result.bind
      (perform_authenticated_http t graph.account (fun token ->
         Http.e2ee_graph_key
           ~base_url:graph.account.managed_sync_origin
           ~graph_id:graph.graph_id
           ~token))
      (fun response ->
         E2ee.graph_key_response response.Http_eio.body
         |> Result.map_error (fun message -> Core.Effect_failed message))
  | Fetch_e2ee_user_keys account ->
    Result.bind
      (perform_authenticated_http t account (fun token ->
         Http.e2ee_user_keys ~base_url:account.managed_sync_origin ~token))
      (fun response ->
         E2ee.user_keys_response response.Http_eio.body
         |> Result.map_error (fun message -> Core.Effect_failed message))
  | Download_snapshot download ->
    let staging = t.dependencies.artifact_store.staging_directory in
    let ensure_staging () =
      if Sys.file_exists staging
      then existing_directory staging
      else (
        try
          Unix.mkdir staging 0o700;
          true
        with
        | Unix.Unix_error _ -> false)
    in
    if not (ensure_staging ())
    then effect_error "snapshot staging directory is unavailable"
    else (
      let id = Core.effect_id_to_string (Core.effect_ticket_id ticket) in
      let raw = Filename.concat staging ("snapshot-" ^ id ^ ".download") in
      let destination = Filename.concat staging ("snapshot-" ^ id ^ ".artifact") in
      let temporary_paths =
        [ Filename.concat staging ("snapshot-" ^ id ^ ".gzip-1")
        ; Filename.concat staging ("snapshot-" ^ id ^ ".gzip-2")
        ]
      in
      let base_url = download.scope.account.managed_sync_origin in
      let bearer_authorized = Http.same_origin base_url download.uri in
      let download_once token =
        let request = Http.artifact ~base_url ~uri:download.uri ~token in
        let response =
          t.dependencies.transport.download
            ~sw:t.sw
            ~request
            ~destination:raw
            ~maximum_bytes:download.maximum_bytes
            ~on_progress:(fun progress ->
              if not t.closed
              then
                t.post
                  (Core.Snapshot_download_progress
                     { graph_id = download.scope.graph_id
                     ; received_bytes = Int64.of_int progress.received_bytes
                     ; total_bytes = Option.map Int64.of_int progress.total_bytes
                     }))
          |> Result.map_error (fun message -> Core.Effect_failed message)
        in
        Result.map (fun response -> request, response) response
      in
      let response =
        let perform token =
          match download_once token with
          | Error (Core.Effect_failed message | Crypto_failed (_, message)) ->
            Error (Request_failed message)
          | Ok (_, response) when bearer_authorized && response.Http_eio.status = 401 ->
            Error Unauthorized
          | Ok (_, response) when response.Http_eio.status = 403 -> Error Forbidden
          | Ok (request, response) ->
            successful_response request response
            |> Result.map_error (function
                | Core.Effect_failed message | Crypto_failed (_, message) ->
                Request_failed message)
        in
        (if bearer_authorized
         then
           authenticated_operation
             t.dependencies.id_token_provider
             ~account:download.scope.account
             ~perform:(fun token -> perform (Some token))
         else Result.map_error authenticated_failure (perform None))
        |> Result.map_error (fun message -> Core.Effect_failed message)
      in
      Result.bind response (fun response ->
        Result.bind (Bootstrap.artifact_row_count response.headers) (fun expected_rows ->
          Result.map
            (fun () ->
               Bootstrap.cleanup (raw :: temporary_paths);
               Core.staged_artifact
                 ~id
                 ~scope:download.scope
                 ~path:destination
                 ~expected_rows)
            (Bootstrap.peel_gzip_layers
               ~decompress_gzip:Artifact_decoder.decompress_gzip
               ~maximum_bytes:download.maximum_bytes
               ~source:raw
               ~destination
               ~temporary_paths))
        |> Result.map_error (fun message -> Core.Effect_failed message)))
  | Load_and_unlock_graph_key scope ->
    run_secret_action t (fun () ->
      let account = scope.account in
      match
        t.dependencies.secrets.load_wrapped_graph_key
          ~managed_sync_origin:account.managed_sync_origin
          ~user_id:account.user_id
          ~graph_id:scope.graph_id
      with
      | Error
          (Wrapped_graph_key_unavailable message | Local_private_key_unavailable message)
        -> effect_error message
      | Ok encrypted_graph_key ->
        t.dependencies.secrets.unlock_graph_key
          ~managed_sync_origin:account.managed_sync_origin
          ~user_id:account.user_id
          ~encrypted_graph_key
        |> Result.map (store_key t ticket scope)
        |> map_error)
  | Fetch_and_unlock_graph_key request ->
    run_secret_action t (fun () ->
      let account = request.scope.account in
      Result.bind
        (t.dependencies.secrets.unlock_graph_key
           ~managed_sync_origin:account.managed_sync_origin
           ~user_id:account.user_id
           ~encrypted_graph_key:request.encrypted_graph_key)
        (fun key ->
           Result.map
             (fun () -> store_key t ticket request.scope key)
             (t.dependencies.secrets.verify_and_save_wrapped_graph_key
                ~managed_sync_origin:account.managed_sync_origin
                ~user_id:account.user_id
                ~graph_id:request.scope.graph_id
                ~encrypted_graph_key:request.encrypted_graph_key))
      |> map_error)
  | Unlock_private_key request ->
    run_secret_action t (fun () ->
      let account = request.scope in
      t.dependencies.secrets.unlock_private_key
        ~managed_sync_origin:account.managed_sync_origin
        ~user_id:account.user_id
        ~password:request.password
        ~private_key_package:request.private_key_package
      |> map_error)
  | Delete_account_secrets account ->
    run_secret_action t (fun () ->
      match delete_account_assets t account with
      | Error _ -> Error (Core.Effect_failed "Account asset cache could not be removed.")
      | Ok () ->
        t.dependencies.secrets.delete_account_secrets
          ~managed_sync_origin:account.managed_sync_origin
          ~user_id:account.user_id
        |> map_error)
  | Encrypt_protected_values request ->
    Result.bind
      (Result.map_error
         (function
           | Core.Effect_failed message | Crypto_failed (_, message) ->
             Core.Crypto_failed (Invalid_key_material, message))
         (key t request.key))
      (fun key ->
         let rec encrypt acc = function
           | [] -> Ok (List.rev acc)
           | plaintext :: rest ->
             (match t.dependencies.crypto.encrypt_aes_gcm ~key ~plaintext with
              | Ok encrypted -> encrypt (encrypted :: acc) rest
              | Error message ->
                Error (Core.Crypto_failed (Crypto_provider_unavailable, message)))
         in
         encrypt [] request.plaintexts)
  | Decrypt_protected_values request ->
    Result.bind
      (Result.map_error
         (function
           | Core.Effect_failed message | Crypto_failed (_, message) ->
             Core.Crypto_failed (Invalid_key_material, message))
         (key t request.key))
      (fun key ->
         let rec decrypt acc = function
           | [] -> Ok (List.rev acc)
           | (iv, ciphertext) :: rest ->
             (match t.dependencies.crypto.decrypt_aes_gcm ~key ~iv ~ciphertext with
              | Ok plaintext -> decrypt (plaintext :: acc) rest
              | Error message ->
                Error (Core.Crypto_failed (Crypto_provider_unavailable, message)))
         in
         decrypt [] request.protected_values)
;;

let field_matches expected actual =
  match expected with
  | None -> true
  | Some expected -> Some expected = actual
;;

let scope_matches expected actual =
  field_matches expected.Core.account_generation actual.Core.account_generation
  && field_matches expected.graph_generation actual.graph_generation
  && field_matches expected.connection_generation actual.connection_generation
  && field_matches expected.presentation_generation actual.presentation_generation
  && field_matches expected.lifecycle_generation actual.lifecycle_generation
;;

let zeroize bytes = Bytes.fill bytes 0 (Bytes.length bytes) '\000'

let retire_websockets ?(remove = true) t matches retire =
  let selected =
    Hashtbl.fold
      (fun key (scope, websocket) selected ->
         if matches scope then (key, websocket) :: selected else selected)
      t.websockets
      []
  in
  if remove then List.iter (fun (key, _) -> Hashtbl.remove t.websockets key) selected;
  List.iter (fun (_, websocket) -> retire websocket) selected
;;

let cancel_scope t scope =
  Hashtbl.iter
    (fun _ (operation : operation) ->
       if scope_matches scope operation.scope
       then (
         operation.cancelled <- true;
         operation.cancel ()))
    t.operations;
  Hashtbl.filter_map_inplace
    (fun _ (entry : key_entry) ->
       let entry_scope = Core.effect_scope_of_graph entry.scope in
       if scope_matches scope entry_scope
       then (
         zeroize entry.bytes;
         None)
       else Some entry)
    t.keys;
  retire_websockets
    t
    (fun connection ->
       scope_matches scope (Core.runner_effect_scope (Core.Close_websocket connection)))
    t.dependencies.transport.abort_websocket
;;

exception Runner_cancelled

let submit_request : type a. t -> a Core.effect_ticket -> a Core.runner_request -> unit =
  fun t ticket request ->
  let id = Core.effect_ticket_id ticket |> Core.effect_id_to_string in
  let cancelled, resolve_cancelled = Eio.Promise.create () in
  let operation =
    { scope = Core.effect_ticket_scope ticket
    ; cancelled = false
    ; cancel = (fun () -> ignore (Eio.Promise.try_resolve resolve_cancelled () : bool))
    }
  in
  Hashtbl.replace t.operations id operation;
  t.dependencies.runtime.fork ~sw:t.sw (fun () ->
    let result =
      try
        Some
          (Eio.Fiber.first
             (fun () ->
                if operation.cancelled || t.closed then raise Runner_cancelled;
                execute_request t ticket request)
             (fun () ->
                Eio.Promise.await cancelled;
                raise Runner_cancelled))
      with
      | Runner_cancelled -> None
    in
    Hashtbl.remove t.operations id;
    match result with
    | Some result when (not t.closed) && not operation.cancelled ->
      t.post (Core.Runner_completed (Core.Completion (ticket, result)))
    | Some _ | None -> ())
;;

let submit t instruction =
  if not t.closed
  then (
    match instruction with
    | Core.Request (ticket, request) -> submit_request t ticket request
    | Cancel_effects scope -> cancel_scope t scope
    | Schedule_timer request ->
      let id = Core.runner_effect_diagnostic instruction in
      let cancelled, resolve_cancelled = Eio.Promise.create () in
      let operation =
        { scope = request.scope
        ; cancelled = false
        ; cancel =
            (fun () -> ignore (Eio.Promise.try_resolve resolve_cancelled () : bool))
        }
      in
      Hashtbl.replace t.operations id operation;
      t.dependencies.runtime.fork ~sw:t.sw (fun () ->
        (try
           Eio.Fiber.first
             (fun () -> t.dependencies.runtime.sleep request.delay_seconds)
             (fun () ->
                Eio.Promise.await cancelled;
                raise Runner_cancelled)
         with
         | Runner_cancelled -> ());
        Hashtbl.remove t.operations id;
        if (not t.closed) && not operation.cancelled
        then t.post (Core.Timer_elapsed request.id))
    | Start_websocket request ->
      let key = Core.runner_effect_diagnostic instruction in
      let cancelled, resolve_cancelled = Eio.Promise.create () in
      let operation =
        { scope = Core.runner_effect_scope instruction
        ; cancelled = false
        ; cancel =
            (fun () -> ignore (Eio.Promise.try_resolve resolve_cancelled () : bool))
        }
      in
      Hashtbl.replace t.operations key operation;
      t.dependencies.runtime.fork ~sw:t.sw (fun () ->
        let pending = ref None
        and registered = ref false in
        Fun.protect
          ~finally:(fun () ->
            Hashtbl.remove t.operations key;
            if not !registered
            then Option.iter t.dependencies.transport.abort_websocket !pending)
          (fun () ->
             let connect token =
               let result =
                 t.dependencies.transport.connect_websocket
                   ~sw:t.sw
                   ~uri:request.uri
                   ~token
                   ~maximum_frame_bytes:Logseq_db_types.Limits.maximum_response_bytes
                   ~on_message:(fun payload ->
                     if (not t.closed) && not operation.cancelled
                     then (
                       match Sync_protocol.decode_server_message payload with
                       | Ok message ->
                         t.post (Core.Websocket_message (request.scope, message))
                       | Error error ->
                         t.post (Core.Websocket_protocol_error (request.scope, error))))
                   ~on_close:(fun message ->
                     let current =
                       match Hashtbl.find_opt t.websockets key, !pending with
                       | Some (_, actual), Some expected -> actual == expected
                       | None, _ -> true
                       | Some _, None -> false
                     in
                     if current
                     then (
                       Hashtbl.remove t.websockets key;
                       if (not t.closed) && not operation.cancelled
                       then t.post (Core.Websocket_closed (request.scope, message))))
               in
               (match result with
                | Ok handle -> pending := Some handle
                | Error _ -> ());
               result
             in
             let connect_with_token () =
               authenticated_operation
                 t.dependencies.id_token_provider
                 ~account:request.scope.graph.account
                 ~perform:(fun token ->
                   match connect token with
                   | Ok websocket -> Ok websocket
                   | Error Websocket_eio.Unauthorized -> Error Unauthorized
                   | Error Websocket_eio.Forbidden -> Error Forbidden
                   | Error (Websocket_eio.Connection_failed message) ->
                     Error (Request_failed message))
             in
             let result =
               try
                 Some
                   (Eio.Fiber.first connect_with_token (fun () ->
                      Eio.Promise.await cancelled;
                      raise Runner_cancelled))
               with
               | Runner_cancelled -> None
             in
             if (not t.closed) && not operation.cancelled
             then (
               match result with
               | None -> ()
               | Some (Error message) ->
                 t.post (Core.Websocket_closed (request.scope, Some message))
               | Some (Ok websocket) ->
                 (match
                    t.dependencies.transport.activate_websocket
                      websocket
                      ~on_open:(fun () ->
                        Option.iter
                          (fun (_, old) -> t.dependencies.transport.abort_websocket old)
                          (Hashtbl.find_opt t.websockets key);
                        Hashtbl.replace t.websockets key (request.scope, websocket);
                        registered := true;
                        t.post (Core.Websocket_opened request.scope))
                  with
                  | Ok () -> ()
                  | Error _ ->
                    t.post
                      (Core.Websocket_closed
                         (request.scope, Some "WebSocket closed before activation"))))))
    | Send_websocket request ->
      (match Sync_protocol.encode_client_message request.message with
       | Error error -> t.post (Core.Websocket_protocol_error (request.scope, error))
       | Ok payload ->
         Hashtbl.iter
           (fun _ (scope, websocket) ->
              if scope = request.scope
              then ignore (t.dependencies.transport.send_websocket websocket payload))
           t.websockets)
    | Close_websocket scope ->
      retire_websockets
        ~remove:false
        t
        (( = ) scope)
        t.dependencies.transport.close_websocket)
;;

let shutdown t =
  if not t.closed
  then (
    t.closed <- true;
    Hashtbl.iter (fun _ cache -> Asset_cache.close cache) t.asset_caches;
    Hashtbl.clear t.asset_caches;
    let all =
      Core.
        { account_generation = None
        ; graph_generation = None
        ; connection_generation = None
        ; presentation_generation = None
        ; lifecycle_generation = None
        }
    in
    cancel_scope t all;
    Hashtbl.clear t.operations)
;;

type asset_encryption =
  | Plaintext
  | Encrypted of Core.graph_key_handle option

module Asset_transfer = Logseq_sync_pure_reducer.Asset_transfer

let asset_cache_failure = function
  | Asset_cache.Full -> Asset_transfer.Storage_full
  | Checksum_mismatch -> Asset_transfer.Checksum_mismatch
  | Stale -> Asset_transfer.Invalid_content "Asset scope is no longer current"
  | Invalid message | Io message -> Asset_transfer.Invalid_content message
;;

let asset_graph_key t scope = function
  | Plaintext -> Ok None
  | Encrypted None -> Error Asset_transfer.Locked
  | Encrypted (Some handle) ->
    if Core.graph_key_handle_scope handle <> scope
    then Error Asset_transfer.Locked
    else
      key t handle
      |> Result.map Option.some
      |> Result.map_error (fun _ -> Asset_transfer.Locked)
;;

let with_asset_slot slots work =
  Eio.Semaphore.acquire slots;
  Fun.protect ~finally:(fun () -> Eio.Semaphore.release slots) work
;;

let fetch_asset_admitted
      t
      ~cache
      ~encryption
      ~maximum_plaintext_bytes
      ~current
      (ticket : Asset_transfer.ticket)
  =
  let ( let* ) = Result.bind in
  if maximum_plaintext_bytes < 0 || maximum_plaintext_bytes > 100 * 1024 * 1024
  then Error (Asset_transfer.Invalid_content "Invalid asset size limit")
  else
    let* graph_key = asset_graph_key t ticket.scope encryption in
    let base_url = ticket.scope.account.managed_sync_origin in
    let* () =
      Http.validate_base_url base_url
      |> Result.map_error (fun message -> Asset_transfer.Invalid_content message)
    in
    let path =
      Printf.sprintf
        "/assets/%s/%s.%s"
        (Graph_types.Uuid.to_string ticket.scope.graph_id)
        (Graph_types.Uuid.to_string ticket.asset)
        ticket.version.file_type
    in
    let uri = Uri.with_path base_url path in
    let maximum_response_bytes =
      match graph_key with
      | None -> maximum_plaintext_bytes
      | Some _ -> (4 * ((maximum_plaintext_bytes + 18) / 3)) + 128
    in
    let last_failure = ref Asset_transfer.Authentication in
    let* response =
      authenticated_operation
        t.dependencies.id_token_provider
        ~account:ticket.scope.account
        ~perform:(fun token ->
          let request : Http.request =
            { operation = Get
            ; uri
            ; headers = [ "authorization", "Bearer " ^ token ]
            ; maximum_response_bytes
            ; expected_content_type = Asset_binary
            }
          in
          match t.dependencies.transport.perform_http ~sw:t.sw request with
          | Error message ->
            last_failure := Asset_transfer.Network;
            Error (Request_failed message)
          | Ok response when response.status = 401 ->
            last_failure := Asset_transfer.Authentication;
            Error Unauthorized
          | Ok response when response.status = 403 ->
            last_failure := Asset_transfer.Invalid_content "Asset access revoked";
            Error Forbidden
          | Ok response -> Ok response)
      |> Result.map_error (fun _ -> !last_failure)
    in
    let* () =
      match response.status with
      | status when status >= 200 && status < 300 -> Ok ()
      | 404 -> Error Asset_transfer.Not_found
      | 408 | 429 | 500 | 502 | 503 | 504 -> Error Asset_transfer.Network
      | status ->
        Error
          (Asset_transfer.Invalid_content (Printf.sprintf "Asset HTTP status %d" status))
    in
    if t.closed || not (current ticket)
    then Error (Asset_transfer.Invalid_content "Asset request expired")
    else
      with_asset_slot t.asset_codec_slot (fun () ->
        if t.closed || not (current ticket)
        then Error (Asset_transfer.Invalid_content "Asset request expired")
        else (
          let crypto : Asset_codec.crypto =
            { encrypt = t.dependencies.crypto.encrypt_aes_gcm
            ; decrypt = t.dependencies.crypto.decrypt_aes_gcm
            }
          in
          let* plaintext =
            Asset_codec.decode
              ~maximum_plaintext_bytes
              ~crypto
              ~key:graph_key
              ~expected_checksum:ticket.version.checksum
              response.body
            |> Result.map_error (fun message ->
              if message = "Asset checksum mismatch"
              then Asset_transfer.Checksum_mismatch
              else Asset_transfer.Invalid_content message)
          in
          Asset_cache.publish
            cache
            ~asset:ticket.asset
            ~version:ticket.version
            ~current:(fun () -> (not t.closed) && current ticket)
            ~plaintext
          |> Result.map_error asset_cache_failure))
;;

let fetch_asset t ~cache ~encryption ~maximum_plaintext_bytes ~current ticket =
  with_asset_slot t.asset_download_slots (fun () ->
    if t.closed || not (current ticket)
    then Error (Asset_transfer.Invalid_content "Asset request expired")
    else
      fetch_asset_admitted t ~cache ~encryption ~maximum_plaintext_bytes ~current ticket)
;;

let asset_operation_id (scope : Core.graph_scope) suffix =
  Printf.sprintf
    "asset:%d:%d:%Ld:%s:%s"
    scope.Core.account.account_generation
    scope.graph_generation
    scope.account.lifecycle_generation
    (Graph_types.Uuid.to_string scope.graph_id)
    suffix
;;

let submit_asset
      t
      ~scope
      ~cache
      ~encryption
      ~maximum_plaintext_bytes
      ~current
      ~post
      instruction
  =
  let fork ~id work deliver =
    if (not t.closed) && not (Hashtbl.mem t.operations id)
    then (
      let cancelled, resolve = Eio.Promise.create () in
      let operation =
        { scope = Core.effect_scope_of_graph scope
        ; cancelled = false
        ; cancel = (fun () -> ignore (Eio.Promise.try_resolve resolve () : bool))
        }
      in
      Hashtbl.add t.operations id operation;
      t.dependencies.runtime.fork ~sw:t.sw (fun () ->
        Fun.protect
          ~finally:(fun () -> Hashtbl.remove t.operations id)
          (fun () ->
             let result =
               try
                 Some
                   (Eio.Fiber.first
                      (fun () ->
                         if operation.cancelled || t.closed then raise Runner_cancelled;
                         work ())
                      (fun () ->
                         Eio.Promise.await cancelled;
                         raise Runner_cancelled))
               with
               | Runner_cancelled -> None
             in
             Option.iter
               (fun result -> deliver ((not t.closed) && not operation.cancelled) result)
               result)))
  in
  let execute (ticket : Asset_transfer.ticket) cache_only =
    if ticket.scope = scope && current ticket
    then
      fork
        ~id:(asset_operation_id scope (string_of_int ticket.id))
        (fun () ->
           if cache_only
           then
             Asset_cache.lookup cache ~asset:ticket.asset ~version:ticket.version
             |> Result.map_error asset_cache_failure
           else
             fetch_asset t ~cache ~encryption ~maximum_plaintext_bytes ~current ticket
             |> Result.map Option.some)
        (fun live result ->
           if live && current ticket
           then
             post
               (if cache_only
                then Asset_transfer.Cache_checked (ticket, result)
                else
                  Asset_transfer.Downloaded
                    ( ticket
                    , Result.bind result (function
                        | Some handle -> Ok handle
                        | None -> Error Asset_transfer.Not_found) ))
           else (
             match result with
             | Ok (Some handle) -> Asset_cache.release cache handle
             | Ok None | Error _ -> ()))
  in
  match instruction with
  | Asset_transfer.Check_cache ticket -> execute ticket true
  | Fetch ticket -> execute ticket false
  | Cancel ticket ->
    if ticket.scope = scope
    then
      Option.iter
        (fun (operation : operation) ->
           operation.cancelled <- true;
           operation.cancel ())
        (Hashtbl.find_opt
           t.operations
           (asset_operation_id scope (string_of_int ticket.id)))
  | Release_handle handle -> Asset_cache.release cache handle
  | Retry_after { id; seconds } ->
    fork
      ~id:(asset_operation_id scope ("timer:" ^ string_of_int id))
      (fun () -> t.dependencies.runtime.sleep seconds)
      (fun live () -> if live then post (Asset_transfer.Retry_elapsed id))
  | Notify _ | Backpressure _ | Capacity_available -> ()
;;

let close_asset_scope t scope =
  Hashtbl.iter
    (fun id (operation : operation) ->
       if
         String.starts_with ~prefix:"asset:" id
         && operation.scope = Core.effect_scope_of_graph scope
       then (
         operation.cancelled <- true;
         operation.cancel ()))
    t.operations;
  Option.iter Asset_cache.close (Hashtbl.find_opt t.asset_caches scope);
  Hashtbl.remove t.asset_caches scope
;;

let scoped_asset_cache t scope =
  match Hashtbl.find_opt t.asset_caches scope with
  | Some cache -> Ok cache
  | None ->
    let root = asset_root t in
    Asset_cache.create
      ~root
      ~scope
      ~budget_bytes:268435456L
      ~maximum_file_bytes:(8 * 1024 * 1024)
    |> Result.map (fun cache ->
      Hashtbl.add t.asset_caches scope cache;
      cache)
;;

let run_scoped_asset t ~(context : Core.asset_context) ~current ~post instruction =
  if not t.closed
  then (
    let cache =
      match instruction with
      | Asset_transfer.Release_handle _ | Cancel _ ->
        (match Hashtbl.find_opt t.asset_caches context.scope with
         | Some cache -> Ok cache
         | None -> Error Asset_cache.Stale)
      | _ -> scoped_asset_cache t context.scope
    in
    match cache with
    | Ok cache ->
      let encryption = if context.encrypted then Encrypted context.key else Plaintext in
      submit_asset
        t
        ~scope:context.scope
        ~cache
        ~encryption
        ~maximum_plaintext_bytes:(8 * 1024 * 1024)
        ~current
        ~post
        instruction
    | Error error ->
      let failure = asset_cache_failure error in
      (match instruction with
       | Asset_transfer.Check_cache ticket when current ticket ->
         post (Asset_transfer.Cache_checked (ticket, Error failure))
       | Fetch ticket when current ticket ->
         post (Asset_transfer.Downloaded (ticket, Error failure))
       | _ -> ()))
;;

let retain_asset_file t ~scope ~handle =
  if t.closed
  then None
  else
    Option.bind (Hashtbl.find_opt t.asset_caches scope) (fun cache ->
      Option.bind (Asset_cache.retain cache handle) (fun lease ->
        match Asset_cache.path cache lease with
        | Some path -> Some (lease, path)
        | None ->
          Asset_cache.release cache lease;
          None))
;;

let release_asset_file t ~scope ~handle =
  Option.iter
    (fun cache -> Asset_cache.release cache handle)
    (Hashtbl.find_opt t.asset_caches scope)
;;

let delete_graph_assets t (request : Core.mirror_deletion) =
  let scopes =
    Hashtbl.fold
      (fun (scope : Core.graph_scope) _ acc ->
         if
           scope.graph_id = request.graph_id
           && scope.account.user_id = request.account.user_id
           && Uri.equal
                scope.account.managed_sync_origin
                request.account.managed_sync_origin
         then scope :: acc
         else acc)
      t.asset_caches
      []
  in
  List.iter (close_asset_scope t) scopes;
  Asset_cache.delete_graph
    ~root:(asset_root t)
    ~account:request.account
    ~graph_id:request.graph_id
  |> Result.map_error (fun _ -> "The graph asset cache could not be removed.")
;;

type upload_failure =
  | Upload_network
  | Upload_authentication
  | Upload_locked
  | Upload_missing_source
  | Upload_size_rejected
  | Upload_revoked_access
  | Upload_invalid_content
  | Upload_cancelled

let read_upload_source ~maximum_plaintext_bytes source_file =
  try
    let input = open_in_bin source_file in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
         let stat = Unix.fstat (Unix.descr_of_in_channel input) in
         if stat.st_kind <> Unix.S_REG
         then Error Upload_invalid_content
         else if stat.st_size > maximum_plaintext_bytes
         then Error Upload_size_rejected
         else (
           let bytes = really_input_string input stat.st_size in
           match input_char input with
           | _ -> Error Upload_invalid_content
           | exception End_of_file -> Ok bytes))
  with
  | Sys_error _ | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Upload_missing_source
  | End_of_file | Unix.Unix_error _ -> Error Upload_invalid_content
;;

let upload_asset_admitted
      t
      ~(context : Core.asset_context)
      ~asset
      ~version
      ~source_file
      ~maximum_plaintext_bytes
      ~current
  =
  let ( let* ) = Result.bind in
  let valid () = (not t.closed) && current () in
  if not (valid ())
  then Error Upload_cancelled
  else if maximum_plaintext_bytes < 0 || maximum_plaintext_bytes > 100 * 1024 * 1024
  then Error Upload_size_rejected
  else (
    let encryption = if context.encrypted then Encrypted context.key else Plaintext in
    let* graph_key =
      asset_graph_key t context.scope encryption
      |> Result.map_error (fun _ -> Upload_locked)
    in
    let* body =
      with_asset_slot t.asset_codec_slot (fun () ->
        if not (valid ())
        then Error Upload_cancelled
        else
          let* plaintext = read_upload_source ~maximum_plaintext_bytes source_file in
          if
            not
              (String.equal
                 (Asset_codec.checksum plaintext)
                 version.Logseq_db_types.Asset_descriptor.checksum)
          then Error Upload_invalid_content
          else (
            let crypto : Asset_codec.crypto =
              { encrypt = t.dependencies.crypto.encrypt_aes_gcm
              ; decrypt = t.dependencies.crypto.decrypt_aes_gcm
              }
            in
            Asset_codec.encode ~maximum_plaintext_bytes ~crypto ~key:graph_key plaintext
            |> Result.map_error (fun _ -> Upload_invalid_content)))
    in
    let base_url = context.scope.account.managed_sync_origin in
    let* () =
      Http.validate_base_url base_url
      |> Result.map_error (fun _ -> Upload_invalid_content)
    in
    let path =
      Printf.sprintf
        "/assets/%s/%s.%s"
        (Graph_types.Uuid.to_string context.scope.graph_id)
        (Graph_types.Uuid.to_string asset)
        version.file_type
    in
    let failure = ref Upload_authentication in
    let* response =
      authenticated_operation
        t.dependencies.id_token_provider
        ~account:context.scope.account
        ~perform:(fun token ->
          if not (valid ())
          then (
            failure := Upload_cancelled;
            Error (Request_failed "Asset upload expired"))
          else (
            let request : Http.request =
              { operation = Put body
              ; uri = Uri.with_path base_url path
              ; headers =
                  [ "authorization", "Bearer " ^ token
                  ; "x-amz-meta-checksum", version.checksum
                  ; "x-amz-meta-type", version.file_type
                  ; "content-type", "application/octet-stream"
                  ]
              ; maximum_response_bytes = 65536
              ; expected_content_type = Asset_binary
              }
            in
            match t.dependencies.transport.perform_http ~sw:t.sw request with
            | Error message ->
              failure := Upload_network;
              Error (Request_failed message)
            | Ok response when response.status = 401 ->
              failure := Upload_authentication;
              Error Unauthorized
            | Ok response when response.status = 403 ->
              failure := Upload_revoked_access;
              Error Forbidden
            | Ok response -> Ok response))
      |> Result.map_error (fun _ -> !failure)
    in
    if not (valid ())
    then Error Upload_cancelled
    else (
      match response.status with
      | status when status >= 200 && status < 300 -> Ok ()
      | 413 -> Error Upload_size_rejected
      | 408 | 429 | 500 | 502 | 503 | 504 -> Error Upload_network
      | _ -> Error Upload_invalid_content))
;;

let upload_asset t ~context ~asset ~version ~source_file ~maximum_plaintext_bytes ~current
  =
  with_asset_slot t.asset_upload_slots (fun () ->
    upload_asset_admitted
      t
      ~context
      ~asset
      ~version
      ~source_file
      ~maximum_plaintext_bytes
      ~current)
;;

let staged_asset_path t ~scope ~file =
  if t.closed
  then None
  else (
    match scoped_asset_cache t scope with
    | Error _ -> None
    | Ok cache -> Asset_cache.staged_path cache ~file)
;;

let release_staged_asset t ~scope ~file =
  if t.closed
  then Error "Asset storage is closed"
  else (
    match scoped_asset_cache t scope with
    | Error _ -> Error "Asset staging is unavailable"
    | Ok cache ->
      Result.map_error
        (fun _ -> "Unable to release staged asset")
        (Asset_cache.release_staged cache ~file))
;;

let stage_asset t ~scope ~operation ~file_type ~source_file =
  if t.closed
  then Error "Asset storage is closed"
  else (
    match scoped_asset_cache t scope with
    | Error _ -> Error "Asset staging is unavailable"
    | Ok cache ->
      Asset_cache.stage
        cache
        ~operation
        ~file_type
        ~source_file
        ~pending_budget_bytes:268435456L
      |> Result.map (fun staged -> staged.Asset_cache.file, staged.checksum, staged.size)
      |> Result.map_error (function
        | Asset_cache.Full -> "Pending attachments have reached the storage limit"
        | Invalid message -> message
        | Io _ | Stale | Checksum_mismatch -> "Unable to copy the selected attachment"))
;;

let prune_staged_assets t ~scope ~keep =
  if t.closed
  then Error "Asset storage is closed"
  else (
    match scoped_asset_cache t scope with
    | Error _ -> Error "Asset staging is unavailable"
    | Ok cache ->
      Asset_cache.prune_staged cache ~keep
      |> Result.map_error (fun _ -> "Unable to reconcile staged assets"))
;;

let retain_staged_file t ~scope ~file =
  if t.closed
  then None
  else (
    match scoped_asset_cache t scope with
    | Error _ -> None
    | Ok cache ->
      Option.bind (Asset_cache.retain_staged cache ~file) (fun lease ->
        match Asset_cache.path cache lease with
        | Some path -> Some (lease, path)
        | None ->
          Asset_cache.release cache lease;
          None))
;;
