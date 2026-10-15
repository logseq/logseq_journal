module Core = Logseq_sync_pure_reducer.Core
module Sync_protocol = Logseq_sync_pure_reducer.Sync_protocol
module Asset_cache = Bootstrap.Asset_cache

type unlock_failure_category = Token | Transport | Http_status | Decode | Crypto

type unlock_failure_trace =
  { operation_id : string
  ; mutable category : unlock_failure_category option
  ; mutable http_status : int option
  }

let unlock_failure_trace = Eio.Fiber.create_key ()

let observe_unlock_failure category =
  if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1" then
    Option.iter (fun trace -> trace.category <- Some category) (Eio.Fiber.get unlock_failure_trace)
;;

let observe_unlock_http_status status =
  if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1" then
    Option.iter (fun trace -> trace.http_status <- Some status) (Eio.Fiber.get unlock_failure_trace)
;;

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
      -> on_close:(Core.websocket_termination -> unit)
      -> (Websocket_eio.t, Websocket_eio.connect_error) result
  ; send_websocket : Websocket_eio.t -> string -> (unit, string) result
  ; await_websocket_retired : Websocket_eio.t -> unit
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
  | Error message ->
    observe_unlock_failure Token;
    Error message
  | Ok token ->
    (match perform token with
     | Ok _ as result -> result
     | Error Unauthorized ->
       provider.invalidate account ~token;
       (match provider.acquire account with
        | Error message ->
          observe_unlock_failure Token;
          Error message
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
      ; await_websocket_retired = Websocket_eio.await_retired
      ; close_websocket = Websocket_eio.close
      ; abort_websocket = Websocket_eio.abort
      ; activate_websocket = Websocket_eio.activate
      }
;;

type local_store =
  { application_support_directory : string
  ; asset_cache_budget_bytes : int64
  ; asset_maximum_file_bytes : int
  ; asset_pending_budget_bytes : int64
  }

let existing_directory path =
  String.length path > 0 && Sys.file_exists path && (Unix.stat path).st_kind = Unix.S_DIR
;;

let local_store
      ?(asset_cache_budget_bytes = 268435456L)
      ?(asset_maximum_file_bytes = 8 * 1024 * 1024)
      ?(asset_pending_budget_bytes = 268435456L)
      ~application_support_directory
      ()
  =
  if
    asset_cache_budget_bytes <= 0L
    || asset_cache_budget_bytes > 268435456L
    || asset_maximum_file_bytes <= 0
    || asset_maximum_file_bytes > 8 * 1024 * 1024
    || asset_pending_budget_bytes <= 0L
    || asset_pending_budget_bytes > 268435456L
  then Error (Invalid_dependency "Asset storage limits exceed the supported bounds")
  else if existing_directory application_support_directory
  then
    Ok
      { application_support_directory
      ; asset_cache_budget_bytes
      ; asset_maximum_file_bytes
      ; asset_pending_budget_bytes
      }
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
  ; asset_identity : (Core.graph_scope * string) option
  ; mutable cancelled : bool
  ; cancel : unit -> unit
  }

type key_entry =
  { scope : Core.graph_scope
  ; bytes : bytes
  }

(* Transfer lanes bound request counts; this shared semaphore bounds the
   in-flight byte footprint of those lanes. Each admitted download or upload
   reserves its worst-case wire plus plaintext footprint before buffers are
   held, in 64 KiB units, so total asset memory stays bounded independently
   of the lane permits. *)
let asset_byte_unit = 65536
let asset_byte_budget_units = 1024

(* The private effect cannot be reconstructed by callers. Its identity must
   stay replay-protected for as long as a caller can retain and resubmit it,
   without retaining historical effects (or their scope strings) ourselves. *)
module Submitted_effects = Weak.Make (struct
    type t = Core.runner_effect

    let equal = ( == )
    let hash instruction = Hashtbl.hash (Core.runner_effect_diagnostic instruction)
  end)

type websocket_owner =
  { physical_scope : Core.connection_scope
  ; operation : operation
  ; pending : Websocket_eio.t option ref
  ; finished : unit Eio.Promise.t
  ; mutable retirement_requested : bool
  }

type t =
  { sw : Eio.Switch.t
  ; dependencies : dependencies
  ; post : Core.event -> unit
  ; operations : (string, operation) Hashtbl.t
  ; submitted_operations : Submitted_effects.t
  ; keys : (string, key_entry) Hashtbl.t
  ; websockets : (string, Core.connection_scope * Websocket_eio.t) Hashtbl.t
  ; mutable websocket_owner : websocket_owner option
  ; mutable last_retired_websocket : Core.connection_scope option
  ; asset_download_slots : Eio.Semaphore.t
  ; asset_upload_slots : Eio.Semaphore.t
  ; asset_codec_slot : Eio.Semaphore.t
  ; asset_byte_budget : Eio.Semaphore.t
  ; asset_byte_reservation_lock : Eio.Semaphore.t
  ; secret_lock : Eio.Mutex.t
  ; asset_caches : (Core.graph_scope, Asset_cache.t) Hashtbl.t
  ; asset_leases : ((Core.graph_scope * string), unit) Hashtbl.t
  ; mutable closed : bool
  }

let create ~sw dependencies ~post =
  Ok
    { sw
    ; dependencies
    ; post
    ; operations = Hashtbl.create 32
    ; submitted_operations = Submitted_effects.create 32
    ; keys = Hashtbl.create 8
    ; websockets = Hashtbl.create 4
    ; websocket_owner = None
    ; last_retired_websocket = None
    ; asset_download_slots = Eio.Semaphore.make 3
    ; asset_upload_slots = Eio.Semaphore.make 1
    ; asset_codec_slot = Eio.Semaphore.make 1
    ; asset_byte_budget = Eio.Semaphore.make asset_byte_budget_units
    ; asset_byte_reservation_lock = Eio.Semaphore.make 1
    ; secret_lock = Eio.Mutex.create ()
    ; asset_caches = Hashtbl.create 4
    ; asset_leases = Hashtbl.create 16
    ; closed = false
    }
;;

let asset_root t =
  Filename.concat
    t.dependencies.local_store.application_support_directory
    "logseq-db-worker/assets"
;;

let delete_account_assets ?except_id t (account : Core.account_scope) =
  Hashtbl.iter
    (fun id (operation : operation) ->
       match operation.asset_identity with
       | Some (scope, _)
         when Some id <> except_id
              && Uri.equal scope.account.managed_sync_origin account.managed_sync_origin
              && String.equal scope.account.user_id account.user_id ->
         operation.cancelled <- true;
         operation.cancel ()
       | Some _ | None -> ())
    t.operations;
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
  then (
    observe_unlock_failure Http_status;
    effect_error
      (Printf.sprintf "sync HTTP request failed with status %d" response.status))
  else (
    match Http.validate_response_content_type request response.headers with
    | Error message ->
      observe_unlock_failure Decode;
      effect_error message
    | Ok () -> Ok response)
;;

let perform_authenticated_http t account make_request =
  authenticated_operation t.dependencies.id_token_provider ~account ~perform:(fun token ->
    let request = make_request token in
    match t.dependencies.transport.perform_http ~sw:t.sw request with
    | Error message ->
      (* Http_eio validates Content-Type before returning a response. Its two
         producer-owned codes retain the decode boundary without logging the
         arbitrary media type suffix. Numeric status is no longer available. *)
      observe_unlock_failure
        (if message = "sync HTTP response is missing Content-Type"
            || String.starts_with ~prefix:"sync HTTP response has unsupported Content-Type " message
         then Decode else Transport);
      Error (Request_failed message)
    | Ok response when response.Http_eio.status = 401 ->
      observe_unlock_http_status response.status;
      observe_unlock_failure Http_status;
      Error Unauthorized
    | Ok response when response.Http_eio.status = 403 ->
      observe_unlock_http_status response.status;
      observe_unlock_failure Http_status;
      Error Forbidden
    | Ok response ->
      observe_unlock_http_status response.status;
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

let unlock_log_count = Atomic.make 0

let unlock_log format =
  Printf.ksprintf (fun fields ->
    if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1" then (
      let count = Atomic.fetch_and_add unlock_log_count 1 in
      try
        if count < 256 then Printf.eprintf "[journal-unlock] source=runner %s\n%!" fields
        else if count = 256 then Printf.eprintf "[journal-unlock] source=runner limit=reached\n%!"
      with _ -> ())) format
;;

(* Opt-in structural metadata only. Counts are top-level field occurrences;
   no arbitrary names or values can reach the logger. The independent64KiB
   observation cap avoids copying/parsing large responses for diagnostics. *)
let observe_graph_key_response_shape body =
  if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1"
     && Atomic.get unlock_log_count <= 256
  then Option.iter (fun trace ->
    let kind, known, unknown, present, base64_kind =
      if String.length body > 65_536 then "unavailable", "unavailable", "unavailable", "unavailable", "unavailable"
      else try
        let json = Yojson.Safe.from_string body in
        let value_kind = function
          | `String _ -> "string" | `Null -> "null" | `Bool _ -> "boolean"
          | `Int _ | `Intlit _ | `Float _ -> "number"
          | `Assoc _ -> "object" | `List _ -> "array" in
        let base64_kind = match json with
          | `Assoc fields ->
            (match List.assoc_opt "encrypted-aes-key-base64" fields with
             | None -> "absent" | Some value -> value_kind value)
          | _ -> "absent" in
        let kind, known, unknown = match json with
          | `Assoc fields ->
            let known, unknown = List.fold_left (fun (known, unknown) (name, _) ->
              if String.equal name "encrypted-aes-key"
                 || String.equal name "encrypted-aes-key-base64" then known+1, unknown
              else known, unknown+1) (0, 0) fields in
            "object", known, unknown
          | `List _ -> "array", 0, 0
          | `String _ -> "string", 0, 0
          | `Null -> "null", 0, 0
          | `Bool _ -> "boolean", 0, 0
          | `Int _ | `Intlit _ | `Float _ -> "number", 0, 0 in
        let present = match json with
          | `Assoc fields -> List.mem_assoc "encrypted-aes-key" fields
          | _ -> false in
        kind, string_of_int known, string_of_int unknown, string_of_bool present, base64_kind
      with _ -> "invalid", "unavailable", "unavailable", "unavailable", "unavailable"
    in
    unlock_log "op=%s request=fetch-e2ee-graph-key phase=response-shape json_kind=%s known_fields=%s unknown_fields=%s encrypted_key_present=%s base64_field_kind=%s"
      trace.operation_id kind known unknown present base64_kind) (Eio.Fiber.get unlock_failure_trace)
;;

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
         |> Result.map_error (fun message ->
           observe_unlock_failure Decode;
           Core.Effect_failed message))
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
         observe_graph_key_response_shape response.Http_eio.body;
         E2ee.graph_key_response response.Http_eio.body
         |> Result.map_error (fun message ->
           observe_unlock_failure Decode;
           Core.Effect_failed message))
  | Fetch_e2ee_user_keys account ->
    Result.bind
      (perform_authenticated_http t account (fun token ->
         Http.e2ee_user_keys ~base_url:account.managed_sync_origin ~token))
      (fun response ->
         E2ee.user_keys_response response.Http_eio.body
         |> Result.map_error (fun message ->
           observe_unlock_failure Decode;
           Core.Effect_failed message))
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

let retire_websocket_owner ?(abort = false) t scope =
  match t.websocket_owner with
  | Some owner when owner.physical_scope = scope ->
    if abort
    then (
      owner.operation.cancelled <- true;
      owner.operation.cancel ());
    if not owner.retirement_requested
    then (
      owner.retirement_requested <- true;
      (match !(owner.pending) with
       | Some handle -> t.dependencies.transport.close_websocket handle
       | None ->
         owner.operation.cancelled <- true;
         owner.operation.cancel ());
      (* submit runs on the event consumer. Joining here would deadlock a callback
         waiting to publish into its full sink. The waiter is never a callback. *)
      t.dependencies.runtime.fork ~sw:t.sw (fun () ->
        (try Eio.Promise.await owner.finished with
         | Eio.Cancel.Cancelled _ ->
           Eio.Cancel.protect (fun () -> Eio.Promise.await owner.finished));
        (match t.websocket_owner with
         | Some current when current == owner -> t.websocket_owner <- None
         | _ -> ());
        t.last_retired_websocket <- Some scope;
        if not t.closed then t.post (Core.Websocket_retired scope)))
  | _ when t.last_retired_websocket = Some scope -> ()
  | _ ->
    t.dependencies.runtime.fork ~sw:t.sw (fun () ->
      if not t.closed then t.post (Core.Websocket_retired scope))
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
       scope_matches
         scope
         { (Core.effect_scope_of_graph connection.Core.graph) with
           connection_generation = Some connection.connection_generation
         })
    t.dependencies.transport.abort_websocket;
  match t.websocket_owner with
  | Some owner
    when scope_matches
           scope
           { (Core.effect_scope_of_graph owner.physical_scope.graph) with
             connection_generation = Some owner.physical_scope.connection_generation
           } -> retire_websocket_owner ~abort:true t owner.physical_scope
  | _ -> ()
;;

let unlock_request_kind : type a. a Core.runner_request -> string option = function
  | Core.Fetch_catalog _ -> Some "fetch-catalog"
  | Fetch_e2ee_graph_key _ -> Some "fetch-e2ee-graph-key"
  | Fetch_e2ee_user_keys _ -> Some "fetch-e2ee-user-keys"
  | Load_and_unlock_graph_key _ -> Some "load-and-unlock-graph-key"
  | Fetch_and_unlock_graph_key _ -> Some "fetch-and-unlock-graph-key"
  | Unlock_private_key _ -> Some "unlock-private-key"
  | _ -> None
;;

let unlock_result : type a. (a, Core.effect_error) result -> string = function
  | Ok _ -> "ok"
  | Error (Core.Crypto_failed (Invalid_key_material, _)) -> "invalid-key-material"
  | Error (Crypto_failed (Crypto_provider_unavailable, _)) -> "crypto-provider-unavailable"
  | Error (Effect_failed message) ->
    (match message with
     | "Authentication failed." -> "authentication-failed"
     | "Authorization failed." -> "authorization-failed"
     | "localPrivateKeyUnavailable" -> "local-private-key-unavailable"
     | "wrappedGraphKeyUnavailable" -> "wrapped-graph-key-unavailable"
     | "cryptoOperationFailed" -> "crypto-failed"
     | _ ->
       let prefix = "sync HTTP request failed with status " in
       let length = String.length prefix in
       if String.length message = length + 3
          && String.sub message 0 length = prefix
          && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub message length 3)
       then "http-" ^ String.sub message length 3
       else "effect-failed")
;;

exception Runner_cancelled

let submit_request : type a. t -> a Core.effect_ticket -> a Core.runner_request -> unit =
  fun t ticket request ->
  let id = Core.effect_ticket_id ticket |> Core.effect_id_to_string in
  let diagnostic_kind = unlock_request_kind request in
  let failure_trace =
    if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1" && Option.is_some diagnostic_kind
    then Some { operation_id = id; category = None; http_status = None }
    else None
  in
  let began = Unix.gettimeofday () in
  Option.iter (fun kind -> unlock_log "op=%s request=%s phase=begin" id kind) diagnostic_kind;
  let cancelled, resolve_cancelled = Eio.Promise.create () in
  let operation =
    { scope = Core.effect_ticket_scope ticket
    ; asset_identity = None
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
                let run () = Platform_crypto.with_diagnostic_operation id (fun () -> execute_request t ticket request) in
                match failure_trace with
                | None -> run ()
                | Some trace -> Eio.Fiber.with_binding unlock_failure_trace trace run)
             (fun () ->
                Eio.Promise.await cancelled;
                raise Runner_cancelled))
      with
      | Runner_cancelled -> None
    in
    Hashtbl.remove t.operations id;
    Option.iter (fun kind ->
      let outcome = match result with
        | None -> "cancelled"
        | Some _ when t.closed || operation.cancelled -> "retired"
        | Some result -> unlock_result result in
      let category = match result with
        | None -> "cancelled"
        | Some _ when t.closed || operation.cancelled -> "retired"
        | Some (Ok _) -> "none"
        | Some (Error error) ->
          let observed = Option.bind failure_trace (fun trace -> trace.category) in
          let observed = match observed, error with
            | Some _ as category, _ -> category
            | None, Core.Crypto_failed _ -> Some Crypto
            | None, Effect_failed _ when kind = "unlock-private-key"
                || kind = "fetch-and-unlock-graph-key" || kind = "load-and-unlock-graph-key" -> Some Crypto
            | None, _ -> None in
          (match observed with
           | Some Token -> "token"
           | Some Transport -> "transport"
           | Some Http_status -> "http"
           | Some Decode -> "decode"
           | Some Crypto -> "crypto"
           | None -> "unknown") in
      let http_status = Option.bind failure_trace (fun trace -> trace.http_status)
        |> Option.fold ~none:"none" ~some:string_of_int in
      unlock_log "op=%s request=%s phase=end result=%s failure_category=%s http_status=%s elapsed_ms=%.0f"
        id kind outcome category http_status (Float.max 0. ((Unix.gettimeofday () -. began) *. 1000.))) diagnostic_kind;
    match result with
    | Some result when (not t.closed) && not operation.cancelled ->
      t.post (Core.Runner_completed (Core.Completion (ticket, result)))
    | Some _ | None -> ())
;;

let submit_nonasset t instruction =
  if not t.closed
  then (
    match instruction with
    | Core.Asset_io _ | Core.Protected_io _ ->
      invalid_arg "Effect requires its dedicated interpreter"
    | Core.Request (ticket, request) -> submit_request t ticket request
    | Cancel_effects scope -> cancel_scope t scope
    | Schedule_timer request ->
      let id = Core.runner_effect_diagnostic instruction in
      let cancelled, resolve_cancelled = Eio.Promise.create () in
      let operation =
        { scope = request.scope
        ; asset_identity = None
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
      (match t.websocket_owner with
       | Some owner when owner.physical_scope = request.scope -> ()
       | Some _ ->
         t.dependencies.runtime.fork ~sw:t.sw (fun () ->
           if not t.closed
           then
             t.post
               (Core.Websocket_closed
                  ( request.scope
                  , Core.Protocol_failure "Previous WebSocket owner has not retired" )))
       | None ->
         let key = Core.runner_effect_diagnostic instruction in
         let cancelled, resolve_cancelled = Eio.Promise.create () in
         let finished, resolve_finished = Eio.Promise.create () in
         let pending = ref None in
         let operation =
           { scope = Core.runner_effect_scope instruction
           ; asset_identity = None
           ; cancelled = false
           ; cancel =
               (fun () ->
                 ignore (Eio.Promise.try_resolve resolve_cancelled () : bool);
                 Option.iter t.dependencies.transport.abort_websocket !pending)
           }
         in
         let owner =
           { physical_scope = request.scope
           ; operation
           ; pending
           ; finished
           ; retirement_requested = false
           }
         in
         t.websocket_owner <- Some owner;
         Hashtbl.replace t.operations key operation;
         t.dependencies.runtime.fork ~sw:t.sw (fun () ->
           let registered = ref false in
           Fun.protect
             ~finally:(fun () ->
               Hashtbl.remove t.operations key;
               if not !registered
               then Option.iter t.dependencies.transport.abort_websocket !pending;
               Eio.Cancel.protect (fun () ->
                 Option.iter t.dependencies.transport.await_websocket_retired !pending);
               ignore (Eio.Promise.try_resolve resolve_finished () : bool))
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
                      ~on_close:(fun termination ->
                        Hashtbl.remove t.websockets key;
                        if (not t.closed) && not operation.cancelled
                        then
                          Eio.Fiber.first
                            (fun () ->
                               t.post (Core.Websocket_closed (request.scope, termination)))
                            (fun () -> Eio.Promise.await cancelled))
                  in
                  (match result with
                   | Ok handle -> pending := Some handle
                   | Error _ -> ());
                  result
                in
                let termination = function
                  | Websocket_eio.Unauthorized ->
                    Core.Authentication_failure "Authentication failed."
                  | Websocket_eio.Forbidden ->
                    Core.Authentication_failure "Authorization failed."
                  | Websocket_eio.Authentication_failed message ->
                    Core.Authentication_failure message
                  | Websocket_eio.Protocol_failed message -> Core.Protocol_failure message
                  | Websocket_eio.Connection_failed message ->
                    Core.Recoverable_close (Some message)
                in
                let connect_with_token () =
                  match
                    t.dependencies.id_token_provider.acquire request.scope.graph.account
                  with
                  | Error message -> Error (Core.Authentication_failure message)
                  | Ok token ->
                    (match connect token with
                     | Error Websocket_eio.Unauthorized ->
                       t.dependencies.id_token_provider.invalidate
                         request.scope.graph.account
                         ~token;
                       (match
                          t.dependencies.id_token_provider.acquire
                            request.scope.graph.account
                        with
                        | Error message -> Error (Core.Authentication_failure message)
                        | Ok refreshed -> Result.map_error termination (connect refreshed))
                     | result -> Result.map_error termination result)
                in
                try
                  Eio.Fiber.first
                    (fun () ->
                       let result = connect_with_token () in
                       if (not t.closed) && not operation.cancelled
                       then (
                         match result with
                         | Error termination ->
                           t.post (Core.Websocket_closed (request.scope, termination))
                         | Ok handle ->
                           (match
                              t.dependencies.transport.activate_websocket
                                handle
                                ~on_open:(fun () ->
                                  Hashtbl.replace t.websockets key (request.scope, handle);
                                  registered := true;
                                  t.post (Core.Websocket_opened request.scope))
                            with
                            | Ok () ->
                              t.dependencies.transport.await_websocket_retired handle
                            | Error error ->
                              t.post
                                (Core.Websocket_closed (request.scope, termination error)))))
                    (fun () ->
                       Eio.Promise.await cancelled;
                       raise Runner_cancelled)
                with
                | Runner_cancelled -> ())))
    | Send_websocket request ->
      (match Sync_protocol.encode_client_message request.message with
       | Error error -> t.post (Core.Websocket_protocol_error (request.scope, error))
       | Ok payload ->
         let sent = ref false in
         Hashtbl.iter
           (fun _ (scope, websocket) ->
              if scope = request.scope
              then (
                sent := true;
                match t.dependencies.transport.send_websocket websocket payload with
                | Ok () -> ()
                | Error message ->
                  t.post
                    (Core.Websocket_closed
                       (request.scope, Core.Recoverable_close (Some message)))))
           t.websockets;
         if not !sent
         then
           t.post
             (Core.Websocket_closed
                (request.scope, Core.Recoverable_close (Some "WebSocket is unavailable"))))
    | Close_websocket scope -> retire_websocket_owner t scope)
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

let asset_cache_failure = function
  | Asset_cache.Full -> Core.Asset_storage_full
  | Checksum_mismatch -> Core.Asset_checksum_mismatch
  | Stale -> Core.Asset_invalid_content "Asset scope is no longer current"
  | Invalid message | Io message -> Core.Asset_invalid_content message
;;

let asset_graph_key t scope = function
  | Plaintext -> Ok None
  | Encrypted None -> Error Core.Asset_locked
  | Encrypted (Some handle) ->
    if Core.graph_key_handle_scope handle <> scope
    then Error Core.Asset_locked
    else
      key t handle
      |> Result.map Option.some
      |> Result.map_error (fun _ -> Core.Asset_locked)
;;

let with_asset_slot slots work =
  Eio.Semaphore.acquire slots;
  Fun.protect ~finally:(fun () -> Eio.Semaphore.release slots) work
;;

let asset_wire_bytes ~maximum_plaintext_bytes encrypted =
  if encrypted
  then (4 * ((maximum_plaintext_bytes + 18) / 3)) + 128
  else maximum_plaintext_bytes
;;

let with_byte_reservation t bytes work =
  let units = (max bytes 0 + asset_byte_unit - 1) / asset_byte_unit in
  if units > asset_byte_budget_units
  then Error Core.Asset_size_rejected
  else (
    let acquired = ref 0 in
    Fun.protect
      ~finally:(fun () ->
        for _ = 1 to !acquired do
          Eio.Semaphore.release t.asset_byte_budget
        done)
      (fun () ->
         with_asset_slot t.asset_byte_reservation_lock (fun () ->
           for _ = 1 to units do
             Eio.Semaphore.acquire t.asset_byte_budget;
             incr acquired
           done);
         work ()))
;;

let fetch_asset_admitted
      t
      ~cache
      ~encryption
      ~maximum_plaintext_bytes
      ~current
      ~(scope : Core.graph_scope)
      ~asset
      ~(version : Logseq_db_types.Asset_descriptor.version)
  =
  let ( let* ) = Result.bind in
  if maximum_plaintext_bytes < 0 || maximum_plaintext_bytes > 100 * 1024 * 1024
  then Error (Core.Asset_invalid_content "Invalid asset size limit")
  else
    let* graph_key = asset_graph_key t scope encryption in
    let base_url = scope.account.managed_sync_origin in
    let* () =
      Http.validate_base_url base_url
      |> Result.map_error (fun message -> Core.Asset_invalid_content message)
    in
    let path =
      Printf.sprintf
        "/assets/%s/%s.%s"
        (Graph_types.Uuid.to_string scope.graph_id)
        (Graph_types.Uuid.to_string asset)
        version.file_type
    in
    let uri = Uri.with_path base_url path in
    let maximum_response_bytes =
      asset_wire_bytes ~maximum_plaintext_bytes (Option.is_some graph_key)
    in
    let last_failure = ref Core.Asset_authentication in
    let* response =
      authenticated_operation
        t.dependencies.id_token_provider
        ~account:scope.account
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
            last_failure := Core.Asset_network;
            Error (Request_failed message)
          | Ok response when response.status = 401 ->
            last_failure := Core.Asset_authentication;
            Error Unauthorized
          | Ok response when response.status = 403 ->
            last_failure := Core.Asset_revoked_access;
            Error Forbidden
          | Ok response -> Ok response)
      |> Result.map_error (fun _ -> !last_failure)
    in
    let* () =
      match response.status with
      | status when status >= 200 && status < 300 -> Ok ()
      | 404 -> Error Core.Asset_not_found
      | 408 | 429 | 500 | 502 | 503 | 504 -> Error Core.Asset_network
      | status ->
        Error (Core.Asset_invalid_content (Printf.sprintf "Asset HTTP status %d" status))
    in
    if t.closed || not (current ())
    then Error Core.Asset_cancelled
    else
      with_asset_slot t.asset_codec_slot (fun () ->
        if t.closed || not (current ())
        then Error Core.Asset_cancelled
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
              ~expected_checksum:version.checksum
              response.body
            |> Result.map_error (fun message ->
              if message = "Asset checksum mismatch"
              then Core.Asset_checksum_mismatch
              else Core.Asset_invalid_content message)
          in
          Asset_cache.publish
            cache
            ~asset
            ~version
            ~current:(fun () -> (not t.closed) && current ())
            ~plaintext
          |> Result.map_error asset_cache_failure))
;;

let fetch_asset
      t
      ~cache
      ~encryption
      ~maximum_plaintext_bytes
      ~current
      ~scope
      ~asset
      ~version
  =
  with_asset_slot t.asset_download_slots (fun () ->
    if t.closed || not (current ())
    then Error Core.Asset_cancelled
    else (
      let encrypted =
        match encryption with
        | Plaintext -> false
        | Encrypted _ -> true
      in
      let reservation =
        asset_wire_bytes ~maximum_plaintext_bytes encrypted + maximum_plaintext_bytes
      in
      with_byte_reservation t reservation (fun () ->
        fetch_asset_admitted
          t
          ~cache
          ~encryption
          ~maximum_plaintext_bytes
          ~current
          ~scope
          ~asset
          ~version)))
;;

let close_asset_scope ?except_id t scope =
  Hashtbl.iter
    (fun id (operation : operation) ->
       if
         String.starts_with ~prefix:"asset:" id
         && Some id <> except_id
         && Option.fold
              ~none:false
              ~some:(fun (actual, _) -> actual = scope)
              operation.asset_identity
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
      ~budget_bytes:t.dependencies.local_store.asset_cache_budget_bytes
      ~maximum_file_bytes:t.dependencies.local_store.asset_maximum_file_bytes
    |> Result.map (fun cache ->
      Hashtbl.add t.asset_caches scope cache;
      cache)
;;

let retain_asset_file t ~scope ~handle =
  if t.closed
  then None
  else
    Option.bind (Hashtbl.find_opt t.asset_caches scope) (fun cache ->
      Option.bind (Asset_cache.retain cache handle) (fun lease ->
        match Asset_cache.path cache lease with
        | Some path -> Hashtbl.replace t.asset_leases (scope, lease) (); Some (lease, path)
        | None ->
          Asset_cache.release cache lease;
          None))
;;

let release_asset_file t ~scope ~handle =
  Hashtbl.remove t.asset_leases (scope, handle);
  Option.iter
    (fun cache -> Asset_cache.release cache handle)
    (Hashtbl.find_opt t.asset_caches scope)
;;

let cancel_graph_asset_operations ?except_id t (request : Core.mirror_deletion) =
  Hashtbl.iter
    (fun id (operation : operation) ->
       match operation.asset_identity with
       | Some (scope, _)
         when Some id <> except_id
              && scope.graph_id = request.graph_id
              && scope.account.user_id = request.account.user_id
              && Uri.equal
                   scope.account.managed_sync_origin
                   request.account.managed_sync_origin ->
         operation.cancelled <- true;
         operation.cancel ()
       | Some _ | None -> ())
    t.operations
;;

let delete_graph_assets ?except_id t (request : Core.mirror_deletion) ~current =
  cancel_graph_asset_operations ?except_id t request;
  let same_target (scope : Core.graph_scope) =
    scope.graph_id = request.graph_id && scope.account.user_id = request.account.user_id
    && Uri.equal scope.account.managed_sync_origin request.account.managed_sync_origin in
  let busy () =
    Hashtbl.fold (fun id (operation : operation) busy ->
      busy || (Some id <> except_id && Option.fold ~none:false
        ~some:(fun (scope, _) -> same_target scope) operation.asset_identity)) t.operations false
    || Hashtbl.fold (fun (scope, _) () busy -> busy || same_target scope) t.asset_leases false in
  let rec await_retirement attempts =
    if not (current ()) then Error "The graph cleanup was cancelled."
    else if not (busy ()) then Ok ()
    else if attempts = 0 then Error "Attachment resources are still in use."
    else (t.dependencies.runtime.sleep 0.005; await_retirement (attempts - 1)) in
  Result.bind (await_retirement 1000) (fun () ->
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
  List.iter (close_asset_scope ?except_id t) scopes;
  Asset_cache.delete_graph
    ~root:(asset_root t)
    ~account:request.account
    ~graph_id:request.graph_id
  |> Result.map_error (fun _ -> "The graph asset cache could not be removed."))
;;

let read_upload_source ~maximum_plaintext_bytes source_file =
  try
    let input = open_in_bin source_file in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
         let stat = Unix.fstat (Unix.descr_of_in_channel input) in
         if stat.st_kind <> Unix.S_REG
         then Error (Core.Asset_invalid_content "Invalid upload content")
         else if stat.st_size > maximum_plaintext_bytes
         then Error Core.Asset_size_rejected
         else (
           let bytes = really_input_string input stat.st_size in
           match input_char input with
           | _ -> Error (Core.Asset_invalid_content "Invalid upload content")
           | exception End_of_file -> Ok bytes))
  with
  | Sys_error _ | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Core.Asset_missing_source
  | End_of_file | Unix.Unix_error _ ->
    Error (Core.Asset_invalid_content "Invalid upload content")
;;

let put_asset_admitted
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
  then Error Core.Asset_cancelled
  else if maximum_plaintext_bytes < 0 || maximum_plaintext_bytes > 100 * 1024 * 1024
  then Error Core.Asset_size_rejected
  else (
    let encryption = if context.encrypted then Encrypted context.key else Plaintext in
    let* graph_key =
      asset_graph_key t context.scope encryption
      |> Result.map_error (fun _ -> Core.Asset_locked)
    in
    let* body =
      with_asset_slot t.asset_codec_slot (fun () ->
        if not (valid ())
        then Error Core.Asset_cancelled
        else
          let* plaintext = read_upload_source ~maximum_plaintext_bytes source_file in
          if
            not
              (String.equal
                 (Asset_codec.checksum plaintext)
                 version.Logseq_db_types.Asset_descriptor.checksum)
          then Error (Core.Asset_invalid_content "Invalid upload content")
          else (
            let crypto : Asset_codec.crypto =
              { encrypt = t.dependencies.crypto.encrypt_aes_gcm
              ; decrypt = t.dependencies.crypto.decrypt_aes_gcm
              }
            in
            Asset_codec.encode ~maximum_plaintext_bytes ~crypto ~key:graph_key plaintext
            |> Result.map_error (fun _ ->
              Core.Asset_invalid_content "Invalid upload content")))
    in
    let base_url = context.scope.account.managed_sync_origin in
    let* () =
      Http.validate_base_url base_url
      |> Result.map_error (fun _ -> Core.Asset_invalid_content "Invalid upload content")
    in
    let path =
      Printf.sprintf
        "/assets/%s/%s.%s"
        (Graph_types.Uuid.to_string context.scope.graph_id)
        (Graph_types.Uuid.to_string asset)
        version.file_type
    in
    let failure = ref Core.Asset_authentication in
    let* response =
      authenticated_operation
        t.dependencies.id_token_provider
        ~account:context.scope.account
        ~perform:(fun token ->
          if not (valid ())
          then (
            failure := Core.Asset_cancelled;
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
              failure := Core.Asset_network;
              Error (Request_failed message)
            | Ok response when response.status = 401 ->
              failure := Core.Asset_authentication;
              Error Unauthorized
            | Ok response when response.status = 403 ->
              failure := Core.Asset_revoked_access;
              Error Forbidden
            | Ok response -> Ok response))
      |> Result.map_error (fun _ -> !failure)
    in
    if not (valid ())
    then Error Core.Asset_cancelled
    else (
      match response.status with
      | status when status >= 200 && status < 300 -> Ok ()
      | 413 -> Error Core.Asset_size_rejected
      | 408 | 429 | 500 | 502 | 503 | 504 -> Error Core.Asset_network
      | _ -> Error (Core.Asset_invalid_content "Invalid upload content")))
;;

let put_asset
      t
      ~(context : Core.asset_context)
      ~asset
      ~version
      ~source_file
      ~maximum_plaintext_bytes
      ~current
  =
  with_asset_slot t.asset_upload_slots (fun () ->
    let reservation =
      asset_wire_bytes
        ~maximum_plaintext_bytes
        (context.encrypted && Option.is_some context.key)
      + maximum_plaintext_bytes
    in
    with_byte_reservation t reservation (fun () ->
      put_asset_admitted
        t
        ~context
        ~asset
        ~version
        ~source_file
        ~maximum_plaintext_bytes
        ~current))
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
  match scoped_asset_cache t scope with
  | Error _ -> Error "Asset staging is unavailable"
  | Ok cache ->
    Result.map_error
      (fun _ -> "Unable to release staged asset")
      (Asset_cache.release_staged cache ~file)
;;

let prune_staged_assets t ~scope ~keep =
  if t.closed
  then Error Core.Asset_cancelled
  else (
    match scoped_asset_cache t scope with
    | Error error -> Error (asset_cache_failure error)
    | Ok cache ->
      let retained = Hashtbl.create (List.length keep) in
      List.iter (fun file -> Hashtbl.replace retained file ()) keep;
      Asset_cache.prune_staged cache ~keep:(fun file -> Ok (Hashtbl.mem retained file))
      |> Result.map_error asset_cache_failure)
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
        | Some path -> Hashtbl.replace t.asset_leases (scope, lease) (); Some (lease, path)
        | None ->
          Asset_cache.release cache lease;
          None))
;;

let execute_asset ?except_id t (request : Core.asset_io_request) ~current =
  let scope = request.context.scope in
  let map_unit result = Result.map (fun () -> Core.Asset_unit) result in
  let storage_result result =
    Result.map_error (fun message -> Core.Asset_invalid_content message) result
  in
  let cache action =
    Result.bind
      (scoped_asset_cache t scope |> Result.map_error asset_cache_failure)
      action
  in
  match request.action with
  | Core.Check_asset_cache (asset, version) ->
    cache (fun cache ->
      Asset_cache.lookup cache ~asset ~version
      |> Result.map (fun handle -> Core.Asset_cached handle)
      |> Result.map_error asset_cache_failure)
  | Fetch_asset { asset; version; maximum_plaintext_bytes } ->
    cache (fun cache ->
      let encryption =
        if request.context.encrypted then Encrypted request.context.key else Plaintext
      in
      fetch_asset
        t
        ~cache
        ~encryption
        ~maximum_plaintext_bytes
        ~current
        ~scope
        ~asset
        ~version
      |> Result.map (fun handle -> Core.Asset_downloaded handle))
  | Stage_asset_file { operation; file_type; source_file } ->
    cache (fun cache ->
      Asset_cache.stage
        cache
        ~operation
        ~file_type
        ~source_file
        ~pending_budget_bytes:t.dependencies.local_store.asset_pending_budget_bytes
      |> Result.map (fun staged ->
        Core.Asset_staged
          { file = staged.Asset_cache.file
          ; checksum = staged.checksum
          ; size = staged.size
          })
      |> Result.map_error asset_cache_failure)
  | Put_asset_file { asset; version; file; maximum_plaintext_bytes } ->
    (match staged_asset_path t ~scope ~file with
     | None -> Error Core.Asset_missing_source
     | Some source_file ->
       put_asset
         t
         ~context:request.context
         ~asset
         ~version
         ~source_file
         ~maximum_plaintext_bytes
         ~current
       |> map_unit)
  | Retain_asset_file handle ->
    Ok (Core.Asset_retained (retain_asset_file t ~scope ~handle))
  | Retain_staged_file file ->
    Ok (Core.Asset_retained (retain_staged_file t ~scope ~file))
  | Release_asset_file handle ->
    release_asset_file t ~scope ~handle;
    Ok Core.Asset_unit
  | Release_staged_file file ->
    release_staged_asset t ~scope ~file |> storage_result |> map_unit
  | Prune_asset_staging keep ->
    prune_staged_assets t ~scope ~keep
    |> Result.map (fun count -> Core.Asset_pruned count)
  | Close_asset_scope ->
    close_asset_scope ?except_id t scope;
    Ok Core.Asset_unit
  | Delete_graph_assets ->
    let deletion : Core.mirror_deletion =
      { account = scope.account
      ; graph_id = scope.graph_id
      ; scope = Core.effect_scope_of_graph scope
      }
    in
    delete_graph_assets ?except_id t deletion ~current |> storage_result |> map_unit
  | Delete_account_assets ->
    delete_account_assets ?except_id t scope.account
    |> Result.map_error asset_cache_failure
    |> map_unit
  | Asset_retry_after seconds ->
    t.dependencies.runtime.sleep seconds;
    Ok Core.Asset_retry_elapsed
  | Cancel_asset_operation target ->
    Hashtbl.iter
      (fun _ (pending : operation) ->
         if pending.asset_identity = Some (scope, target)
         then (
           pending.cancelled <- true;
           pending.cancel ()))
      t.operations;
    Ok Core.Asset_unit
;;

let scoped_operation_id kind (scope : Core.graph_scope) ticket =
  Printf.sprintf
    "%s:%S:%S:%d:%d:%Ld:%S:%d:%S"
    kind
    (Uri.to_string scope.account.managed_sync_origin)
    scope.account.user_id
    scope.account.account_generation
    scope.account.presentation_generation
    scope.account.lifecycle_generation
    (Graph_types.Uuid.to_string scope.graph_id)
    scope.graph_generation
    ticket
;;

let claim_operation t instruction =
  if Submitted_effects.mem t.submitted_operations instruction
  then false
  else (
    Submitted_effects.add t.submitted_operations instruction;
    true)
;;

let submit_asset_io t instruction ticket (request : Core.asset_io_request) =
  let id =
    scoped_operation_id "asset" request.context.scope (Core.asset_ticket_id ticket)
  in
  if claim_operation t instruction
  then (
    (match request.action with
     | Core.Delete_graph_assets ->
       let scope = request.context.scope in
       cancel_graph_asset_operations t
         { Core.account = scope.account; graph_id = scope.graph_id; scope = Core.effect_scope_of_graph scope }
     | _ -> ());
    let cancelled, resolve_cancelled = Eio.Promise.create () in
    let operation =
      { scope = Core.effect_scope_of_graph request.context.scope
      ; asset_identity = Some (request.context.scope, request.operation)
      ; cancelled = false
      ; cancel = (fun () -> ignore (Eio.Promise.try_resolve resolve_cancelled () : bool))
      }
    in
    Hashtbl.add t.operations id operation;
    t.dependencies.runtime.fork ~sw:t.sw (fun () ->
      let current () = (not t.closed) && not operation.cancelled in
      let result =
        Fun.protect
          ~finally:(fun () -> Hashtbl.remove t.operations id)
          (fun () ->
             try
               Eio.Fiber.first
                 (fun () ->
                    if not (current ()) then raise Runner_cancelled;
                    execute_asset ~except_id:id t request ~current)
                 (fun () ->
                    Eio.Promise.await cancelled;
                    raise Runner_cancelled)
             with
             | Runner_cancelled -> Error Core.Asset_cancelled
             | error -> Error (Core.Asset_invalid_content (Printexc.to_string error)))
      in
      (* A completed resource must reach the reducer even after cancellation.
         The reducer owns acceptance and issues cleanup for stale resources. *)
      t.post (Core.Runner_completed (Core.Asset_completion (ticket, result)))))
;;

let execute_protected t (request : Core.protected_request) =
  let valid handle = Core.graph_key_handle_scope handle = request.protected_scope in
  let run handle action =
    if valid handle
    then Result.map_error (fun message -> Core.Effect_failed message) (action ())
    else Error (Core.Effect_failed "Protected request graph key is out of scope")
  in
  match request.protected_action with
  | Core.Encrypt_values (handle, values) ->
    run handle (fun () -> encrypt_protected_values t handle values)
    |> Result.map (fun values -> Core.Encrypted_values values)
  | Decrypt_value (handle, source) ->
    run handle (fun () -> decrypt_protected_value t handle source)
    |> Result.map (fun value -> Core.Decrypted_value value)
;;

let submit_protected t instruction ticket (request : Core.protected_request) =
  let id =
    scoped_operation_id
      "protected"
      request.protected_scope
      (Core.protected_ticket_id ticket)
  in
  if claim_operation t instruction
  then (
    let cancelled, resolve_cancelled = Eio.Promise.create () in
    let operation =
      { scope = Core.effect_scope_of_graph request.protected_scope
      ; asset_identity = None
      ; cancelled = false
      ; cancel = (fun () -> ignore (Eio.Promise.try_resolve resolve_cancelled () : bool))
      }
    in
    Hashtbl.add t.operations id operation;
    t.dependencies.runtime.fork ~sw:t.sw (fun () ->
      let result =
        Fun.protect
          ~finally:(fun () -> Hashtbl.remove t.operations id)
          (fun () ->
             try
               Eio.Fiber.first
                 (fun () ->
                    if t.closed || operation.cancelled then raise Runner_cancelled;
                    execute_protected t request)
                 (fun () ->
                    Eio.Promise.await cancelled;
                    raise Runner_cancelled)
             with
             | Runner_cancelled ->
               Error (Core.Effect_failed "Protected request cancelled")
             | error -> Error (Core.Effect_failed (Printexc.to_string error)))
      in
      t.post (Core.Runner_completed (Core.Protected_completion (ticket, result)))))
;;

let cleanup_asset_action = function
  | Core.Release_asset_file _
  | Release_staged_file _
  | Close_asset_scope
  | Delete_graph_assets
  | Delete_account_assets
  | Cancel_asset_operation _ -> true
  | Check_asset_cache _
  | Fetch_asset _
  | Stage_asset_file _
  | Put_asset_file _
  | Retain_asset_file _
  | Retain_staged_file _
  | Prune_asset_staging _
  | Asset_retry_after _ -> false
;;

let submit t instruction =
  match instruction with
  | Core.Asset_io (ticket, ({ action = Core.Delete_graph_assets; _ } as request)) ->
    (* Deletion may wait for native leases. It must not block the event consumer
       that delivers their release, and shutdown must revoke its execution. *)
    if t.closed
    then t.post (Core.Runner_completed (Core.Asset_completion (ticket, Error Core.Asset_cancelled)))
    else submit_asset_io t instruction ticket request
  | Core.Asset_io (ticket, request) ->
    if cleanup_asset_action request.action
    then (
      if claim_operation t instruction
      then (
        let result =
          try
            Fun.protect
              ~finally:(fun () ->
                if t.closed then close_asset_scope t request.context.scope)
              (fun () -> execute_asset t request ~current:(fun () -> false))
          with
          | error -> Error (Core.Asset_invalid_content (Printexc.to_string error))
        in
        t.post (Core.Runner_completed (Core.Asset_completion (ticket, result)))))
    else if t.closed
    then (
      if claim_operation t instruction
      then
        t.post
          (Core.Runner_completed
             (Core.Asset_completion (ticket, Error Core.Asset_cancelled))))
    else submit_asset_io t instruction ticket request
  | Protected_io (ticket, request) ->
    if t.closed
    then (
      if claim_operation t instruction
      then
        t.post
          (Core.Runner_completed
             (Core.Protected_completion
                (ticket, Error (Core.Effect_failed "Protected request cancelled")))))
    else submit_protected t instruction ticket request
  | _ -> submit_nonasset t instruction
;;
