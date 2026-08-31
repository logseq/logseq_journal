module Core = Logseq_sync_pure_reducer.Core
module Sync_protocol = Logseq_sync_pure_reducer.Sync_protocol

type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string

type runtime =
  { fork : sw:Eio.Switch.t -> (unit -> unit) -> unit
  ; sleep : float -> unit
  ; monotonic_ns : unit -> int64
  }

let runtime ~fork ~sleep ~monotonic_ns = Ok { fork; sleep; monotonic_ns }

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
      -> (Websocket_eio.t, string) result
  ; send_websocket : Websocket_eio.t -> string -> (unit, string) result
  ; close_websocket : Websocket_eio.t -> unit
  }

type tls_authenticator = X509.Authenticator.t

let tls_authenticator authenticator = authenticator

let system_tls_authenticator () =
  Ca_certs_nss.authenticator ()
  |> Result.map_error (fun (`Msg message) -> Invalid_dependency message)
;;

let transport ~tls_authenticator ~network ~clock =
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
  { has_private_key : managed_sync_origin:Uri.t -> user_id:string -> bool
  ; unlock_private_key :
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
  ; delete_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:Core.graph_id
      -> (unit, string) result
  ; delete_account_secrets :
      managed_sync_origin:Uri.t -> user_id:string -> (unit, string) result
  }

let secrets
      ~has_private_key
      ~unlock_private_key
      ~unlock_graph_key
      ~load_wrapped_graph_key
      ~verify_and_save_wrapped_graph_key
      ~delete_wrapped_graph_key
      ~delete_account_secrets
  =
  Ok
    { has_private_key
    ; unlock_private_key
    ; unlock_graph_key
    ; load_wrapped_graph_key
    ; verify_and_save_wrapped_graph_key
    ; delete_wrapped_graph_key
    ; delete_account_secrets
    }
;;

type crypto =
  { decrypt_private_key :
      password:string
      -> iterations:int
      -> salt:string
      -> iv:string
      -> ciphertext:string
      -> (string, string) result
  ; decrypt_graph_key : private_key:string -> ciphertext:string -> (string, string) result
  ; encrypt_aes_gcm : key:string -> plaintext:string -> (string * string, string) result
  ; decrypt_aes_gcm :
      key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

let crypto ~decrypt_private_key ~decrypt_graph_key ~encrypt_aes_gcm ~decrypt_aes_gcm =
  Ok { decrypt_private_key; decrypt_graph_key; encrypt_aes_gcm; decrypt_aes_gcm }
;;

let apple_secrets () =
  secrets
    ~has_private_key:Platform_crypto.has_private_key
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
    ~delete_wrapped_graph_key:Platform_crypto.delete_wrapped_graph_key
    ~delete_account_secrets:Platform_crypto.delete_account_secrets
;;

let apple_crypto () =
  let adapter = Platform_crypto.crypto in
  crypto
    ~decrypt_private_key:adapter.decrypt_private_key
    ~decrypt_graph_key:adapter.decrypt_graph_key
    ~encrypt_aes_gcm:adapter.encrypt_aes_gcm
    ~decrypt_aes_gcm:adapter.decrypt_aes_gcm
;;

type dependencies =
  { runtime : runtime
  ; transport : transport
  ; local_store : local_store
  ; artifact_store : artifact_store
  ; secrets : secrets
  ; crypto : crypto
  }

let dependencies ~runtime ~transport ~local_store ~artifact_store ~secrets ~crypto =
  ignore runtime.monotonic_ns;
  ignore secrets.has_private_key;
  ignore secrets.verify_and_save_wrapped_graph_key;
  ignore secrets.delete_wrapped_graph_key;
  ignore secrets.delete_account_secrets;
  ignore crypto.decrypt_private_key;
  ignore crypto.decrypt_graph_key;
  Ok { runtime; transport; local_store; artifact_store; secrets; crypto }
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
    ; closed = false
    }
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

let perform_http t request =
  let response =
    t.dependencies.transport.perform_http ~sw:t.sw request
    |> Result.map_error (fun message -> Core.Effect_failed message)
  in
  Result.bind response (successful_response request)
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

let execute_request
  : type a.
    t -> a Core.effect_ticket -> a Core.runner_request -> (a, Core.effect_error) result
  =
  fun t ticket request ->
  match request with
  | Core.Load_catalog account -> load_catalog t.dependencies.local_store account
  | Save_catalog { account; cache } ->
    save_catalog t.dependencies.local_store account cache
  | Fetch_catalog authenticated ->
    let request =
      Http.catalog
        ~base_url:authenticated.account.managed_sync_origin
        ~token:authenticated.token
    in
    Result.bind (perform_http t request) (fun response ->
      Catalog.decode response.body
      |> Result.map_error (fun message -> Core.Effect_failed message))
  | Fetch_snapshot_baseline authorized ->
    let request =
      Http.snapshot_baseline
        ~base_url:authorized.graph.account.managed_sync_origin
        ~graph_id:authorized.graph.graph_id
        ~token:authorized.token
    in
    Result.map (fun response -> response.Http_eio.body) (perform_http t request)
  | Fetch_snapshot_metadata authorized ->
    let request =
      Http.snapshot_metadata
        ~base_url:authorized.graph.account.managed_sync_origin
        ~graph_id:authorized.graph.graph_id
        ~token:authorized.token
    in
    Result.map (fun response -> response.Http_eio.body) (perform_http t request)
  | Fetch_e2ee_graph_key authorized ->
    let request =
      Http.e2ee_graph_key
        ~base_url:authorized.graph.account.managed_sync_origin
        ~graph_id:authorized.graph.graph_id
        ~token:authorized.token
    in
    Result.map (fun response -> response.Http_eio.body) (perform_http t request)
  | Fetch_e2ee_user_keys authenticated ->
    let request =
      Http.e2ee_user_keys
        ~base_url:authenticated.account.managed_sync_origin
        ~token:authenticated.token
    in
    Result.map (fun response -> response.Http_eio.body) (perform_http t request)
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
      Bootstrap.cleanup (raw :: destination :: temporary_paths);
      let request = Http.artifact ~uri:download.uri ~token:download.scope.token in
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
                 { graph_id = download.scope.graph.graph_id
                 ; received_bytes = Int64.of_int progress.received_bytes
                 ; total_bytes = Option.map Int64.of_int progress.total_bytes
                 }))
      |> Result.map_error (fun message -> Core.Effect_failed message)
      |> fun response ->
      Result.bind response (fun response ->
        Result.bind (successful_response request response) (fun response ->
          Result.bind
            (Bootstrap.artifact_row_count response.headers)
            (fun expected_rows ->
               Result.map
                 (fun () ->
                    Bootstrap.cleanup (raw :: temporary_paths);
                    Core.staged_artifact
                      ~id
                      ~scope:download.scope.graph
                      ~path:destination
                      ~expected_rows)
                 (Bootstrap.peel_gzip_layers
                    ~decompress_gzip:Artifact_decoder.decompress_gzip
                    ~maximum_bytes:download.maximum_bytes
                    ~source:raw
                    ~destination
                    ~temporary_paths))
          |> Result.map_error (fun message -> Core.Effect_failed message))))
  | Load_and_unlock_graph_key scope ->
    let account = scope.account in
    (match
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
    let account = request.scope.graph.account in
    Result.bind
      (t.dependencies.secrets.unlock_graph_key
         ~managed_sync_origin:account.managed_sync_origin
         ~user_id:account.user_id
         ~encrypted_graph_key:request.encrypted_graph_key)
      (fun key ->
         Result.map
           (fun () -> store_key t ticket request.scope.graph key)
           (t.dependencies.secrets.verify_and_save_wrapped_graph_key
              ~managed_sync_origin:account.managed_sync_origin
              ~user_id:account.user_id
              ~graph_id:request.scope.graph.graph_id
              ~encrypted_graph_key:request.encrypted_graph_key))
    |> map_error
  | Unlock_private_key request ->
    let account = request.scope.account in
    t.dependencies.secrets.unlock_private_key
      ~managed_sync_origin:account.managed_sync_origin
      ~user_id:account.user_id
      ~password:request.password
      ~private_key_package:request.private_key_package
    |> map_error
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
  Hashtbl.filter_map_inplace
    (fun _ (connection, websocket) ->
       if scope_matches scope (Core.runner_effect_scope (Core.Close_websocket connection))
       then (
         t.dependencies.transport.close_websocket websocket;
         None)
       else Some (connection, websocket))
    t.websockets
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
             (fun () -> execute_request t ticket request)
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
        let result =
          try
            Some
              (Eio.Fiber.first
                 (fun () ->
                    t.dependencies.transport.connect_websocket
                      ~sw:t.sw
                      ~uri:request.uri
                      ~token:request.token
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
                        Hashtbl.remove t.websockets key;
                        if (not t.closed) && not operation.cancelled
                        then t.post (Core.Websocket_closed (request.scope, message))))
                 (fun () ->
                    Eio.Promise.await cancelled;
                    raise Runner_cancelled))
          with
          | Runner_cancelled -> None
        in
        Hashtbl.remove t.operations key;
        match result with
        | None -> ()
        | Some (Error message) ->
          if (not t.closed) && not operation.cancelled
          then t.post (Core.Websocket_closed (request.scope, Some message))
        | Some (Ok websocket) ->
          if t.closed || operation.cancelled
          then t.dependencies.transport.close_websocket websocket
          else (
            Hashtbl.replace t.websockets key (request.scope, websocket);
            t.post (Core.Websocket_opened request.scope)))
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
      Hashtbl.filter_map_inplace
        (fun _ (actual, websocket) ->
           if actual = scope
           then (
             t.dependencies.transport.close_websocket websocket;
             None)
           else Some (actual, websocket))
        t.websockets)
;;

let shutdown t =
  if not t.closed
  then (
    t.closed <- true;
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
    Hashtbl.iter
      (fun _ (_, websocket) -> t.dependencies.transport.close_websocket websocket)
      t.websockets;
    Hashtbl.clear t.websockets;
    Hashtbl.clear t.operations)
;;
