(* Secondary warnings must preserve the operation result and finish cleanup. *)
let report_warning message =
  try output_string stderr message; flush stderr with _ -> ()
;;

module Upload = Logseq_db_worker_pure_reducer.Asset_upload
module Core = Logseq_db_worker_pure_reducer.Core
module Database = Logseq_overlay_db.Database
module Overlay = Logseq_overlay_db.Types
module Protocol = Logseq_db_worker_contract.Protocol
module Graph = Logseq_db_types.Graph_types
module Sync = Logseq_sync_pure_reducer.Core
module Transit = Transit_core.Json
module Transit_codec = Transit_native.Transit.Json

type token_owner =
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; account_generation : int
  }
[@@warning "-69"]

type id_token_request =
  { challenge_id : string
  ; owner : token_owner
  ; epoch : int
  }

type token_entry =
  { owner : token_owner
  ; token : string
  ; reuse_deadline_ns : int64
  }

type token_flight =
  { request : id_token_request
  ; outcome : (string, string) result Eio.Promise.t
  ; resolve : (string, string) result Eio.Promise.u
  }

type id_token_cache =
  { wall_clock_s : unit -> float
  ; monotonic_ns : unit -> int64
  ; request : id_token_request -> unit
  ; lock : Eio.Mutex.t
  ; mutable authenticated_user : string option
  ; mutable entry : token_entry option
  ; mutable flight : token_flight option
  ; mutable next_challenge : int
  ; mutable epoch : int
  ; mutable stopped : bool
  }

let id_token_request_id request = request.challenge_id

let id_token_cache ~wall_clock_s ~monotonic_ns ~request =
  { wall_clock_s
  ; monotonic_ns
  ; request
  ; lock = Eio.Mutex.create ()
  ; authenticated_user = None
  ; entry = None
  ; flight = None
  ; next_challenge = 1
  ; epoch = 0
  ; stopped = false
  }
;;

let token_owner (account : Sync.account_scope) =
  { managed_sync_origin = account.managed_sync_origin
  ; user_id = account.user_id
  ; account_generation = account.account_generation
  }
;;

let base64url_value = function
  | 'A' .. 'Z' as character -> Some (Char.code character - Char.code 'A')
  | 'a' .. 'z' as character -> Some (Char.code character - Char.code 'a' + 26)
  | '0' .. '9' as character -> Some (Char.code character - Char.code '0' + 52)
  | '-' -> Some 62
  | '_' -> Some 63
  | _ -> None
;;

let base64url_decode value =
  let length = String.length value in
  if length = 0 || length mod 4 = 1
  then None
  else (
    let output = Buffer.create (length * 3 / 4) in
    let rec decode offset =
      if offset = length
      then Some (Buffer.contents output)
      else (
        let count = min 4 (length - offset) in
        if count = 1
        then None
        else (
          let decoded = Array.make 4 0 in
          let rec read index =
            if index = count
            then true
            else (
              match base64url_value value.[offset + index] with
              | None -> false
              | Some byte ->
                decoded.(index) <- byte;
                read (index + 1))
          in
          if not (read 0)
          then None
          else (
            Buffer.add_char
              output
              (Char.chr ((decoded.(0) lsl 2) lor (decoded.(1) lsr 4)));
            if count >= 3
            then
              Buffer.add_char
                output
                (Char.chr (((decoded.(1) land 0x0f) lsl 4) lor (decoded.(2) lsr 2)));
            if count = 4
            then
              Buffer.add_char
                output
                (Char.chr (((decoded.(2) land 0x03) lsl 6) lor decoded.(3)));
            decode (offset + count))))
    in
    decode 0)
;;

type token_claims = { exp : int64 } [@@deriving of_yojson { strict = false }]

let token_expiration token =
  if String.length token = 0 || String.length token > 1024 * 1024
  then Error "ID token response is invalid."
  else (
    match String.split_on_char '.' token with
    | [ header; payload; signature ]
      when String.length header > 0 && String.length signature > 0 ->
      (match base64url_decode payload with
       | None -> Error "ID token response is invalid."
       | Some decoded ->
         (try
            Yojson.Safe.from_string decoded
            |> Logseq_db_types.Json_codec.decode token_claims_of_yojson
            |> Result.map (fun claims -> Int64.to_float claims.exp)
            |> Result.map_error (fun _ -> "ID token response is invalid.")
          with
          | Yojson.Json_error _ -> Error "ID token response is invalid."))
    | _ -> Error "ID token response is invalid.")
;;

let cancel_token_flight cache message =
  match cache.flight with
  | None -> ()
  | Some flight ->
    cache.flight <- None;
    ignore (Eio.Promise.try_resolve flight.resolve (Error message) : bool)
;;

let clear_id_token_cache cache message =
  cache.entry <- None;
  cache.epoch <- cache.epoch + 1;
  cancel_token_flight cache message
;;

let reconcile_authenticated_user cache ~user_id =
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    if cache.authenticated_user <> user_id
    then (
      cache.authenticated_user <- user_id;
      clear_id_token_cache cache "ID token request is no longer current."))
;;

let reusable_token cache owner =
  match cache.entry with
  | Some entry
    when entry.owner = owner
         && Int64.compare (cache.monotonic_ns ()) entry.reuse_deadline_ns < 0 ->
    Some entry.token
  | Some _ ->
    cache.entry <- None;
    None
  | None -> None
;;

type token_acquisition =
  | Cached_token of string
  | Await_token of (string, string) result Eio.Promise.t
  | Start_token_request of token_flight
  | Token_cache_stopped

let start_token_request cache owner =
  let outcome, resolve = Eio.Promise.create () in
  let request =
    { challenge_id = Printf.sprintf "id-token-%d" cache.next_challenge
    ; owner
    ; epoch = cache.epoch
    }
  in
  cache.next_challenge <- cache.next_challenge + 1;
  let flight = { request; outcome; resolve } in
  cache.flight <- Some flight;
  Start_token_request flight
;;

let acquire_id_token cache ~(account : Sync.account_scope) =
  let owner = token_owner account in
  let acquisition =
    Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
      if cache.stopped
      then Token_cache_stopped
      else (
        (match cache.authenticated_user with
         | Some user_id when not (String.equal user_id owner.user_id) ->
           clear_id_token_cache cache "ID token request is no longer current."
         | None | Some _ -> ());
        cache.authenticated_user <- Some owner.user_id;
        match reusable_token cache owner with
        | Some token -> Cached_token token
        | None ->
          (match cache.flight with
           | Some flight when flight.request.owner = owner -> Await_token flight.outcome
           | Some _ ->
             clear_id_token_cache cache "ID token request is no longer current.";
             start_token_request cache owner
           | None -> start_token_request cache owner)))
  in
  match acquisition with
  | Cached_token token -> Ok token
  | Await_token outcome -> Eio.Promise.await outcome
  | Token_cache_stopped -> Error "ID token cache is stopped."
  | Start_token_request flight ->
    (try cache.request flight.request with
     | _ ->
       Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
         match cache.flight with
         | Some current when current.request = flight.request ->
           cache.flight <- None;
           ignore
             (Eio.Promise.try_resolve current.resolve (Error "ID token is unavailable.")
              : bool)
         | None | Some _ -> ()));
    Eio.Promise.await flight.outcome
;;

let provide_id_token cache request token =
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    match cache.flight with
    | Some flight
      when flight.request = request && request.epoch = cache.epoch && not cache.stopped ->
      cache.flight <- None;
      let result =
        Result.bind (token_expiration token) (fun expiration ->
          let now = cache.wall_clock_s () in
          if Float.compare expiration now <= 0
          then Error "ID token response is expired."
          else (
            let reuse_seconds = min 86_400. (expiration -. now -. 3_600.) in
            if Float.compare reuse_seconds 0. > 0
            then (
              let duration_ns = Int64.of_float (reuse_seconds *. 1_000_000_000.) in
              cache.entry
              <- Some
                   { owner = request.owner
                   ; token
                   ; reuse_deadline_ns = Int64.add (cache.monotonic_ns ()) duration_ns
                   });
            Ok token))
      in
      ignore (Eio.Promise.try_resolve flight.resolve result : bool)
    | None | Some _ -> ())
;;

let reject_id_token cache request _message =
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    match cache.flight with
    | Some flight when flight.request = request ->
      cache.flight <- None;
      ignore
        (Eio.Promise.try_resolve flight.resolve (Error "ID token is unavailable.") : bool)
    | None | Some _ -> ())
;;

let invalidate_id_token cache ~(account : Sync.account_scope) ~token =
  let owner = token_owner account in
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    match cache.entry with
    | Some entry when entry.owner = owner && String.equal entry.token token ->
      cache.entry <- None
    | None | Some _ -> ())
;;

let shutdown_id_token_cache cache =
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    if not cache.stopped
    then (
      cache.stopped <- true;
      cache.authenticated_user <- None;
      clear_id_token_cache cache "ID token cache is stopped."))
;;

module Authorized_graphs = Set.Make (String)

type runtime =
  { fork : sw:Eio.Switch.t -> (unit -> unit) -> unit
  ; sleep : float -> unit
  }

type sync_runner =
  { submit : Sync.runner_effect -> unit
  ; shutdown : unit -> unit
  }

type dependencies =
  { runtime : runtime
  ; config : Logseq_db_worker_contract.Config.t
  ; overlay : Database.dependencies
  ; sync_runner : sync_runner
  ; publish : Core.output -> unit
  }

type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string

type waiter =
  { request : Protocol.request
  ; resolve : Protocol.response Eio.Promise.u
  }

type asset_waiter =
  { request : Sync.asset_request
  ; resolve : Sync.asset_output Eio.Promise.u
  ; mutable delivered : Sync.asset_output option
  ; mutable accepted : bool
  ; mutable reclaimed : bool
  ; mutable diagnostic : Logseq_db_types.Failure_diagnostic.t option
  }

type notice_diagnostic_key = Upload_notice of Graph.Uuid.t | Download_notice of Graph.Uuid.t

type notice_diagnostic =
  { scope : Sync.graph_scope
  ; key : notice_diagnostic_key
  ; detail : Logseq_db_types.Failure_diagnostic.t
  ; ticket_id : int
  }

type protected_waiter =
  { protected_request : Sync.protected_request
  ; protected_resolve : Sync.protected_output Eio.Promise.u
  }

type change_window =
  { encoded_bytes : int
  ; id : string
  ; predecessor : string
  ; successor : string
  ; block_uuids : Graph.block_uuid list
  ; page_uuids : Graph.page_uuid list
  ; structure_interests : Protocol.v2_structure_interest list
  }

type database_session =
  { graph_scope : Sync.graph_scope
  ; database : Database.t
  ; subscription : Database.subscription
  ; mutable generation : string
  ; mutable next_window : int
  ; mutable acknowledged_through : string
  ; mutable windows : change_window Rrbvec.t
  ; mutable changefeed : Core.Changefeed_owner.t
  }

type observation_result = (int64 * Protocol.response, string) result

type observation_slot =
  { registration : int64
  ; logical_id : Graph.Uuid.t
  ; observation_scope : Sync.graph_scope
  ; database_id : string
  ; request : Protocol.request
  ; maximum_bytes : int
  ; current : unit -> bool
  ; notify : epoch:int64 -> unit
  ; initial : observation_result Eio.Promise.t
  ; initial_resolve : observation_result Eio.Promise.u
  ; mutable subscription : Database.subscription option
  ; mutable closing : bool
  ; mutable work : int
  ; mutable idle : unit Eio.Promise.t * unit Eio.Promise.u
  }

type asset_cleanup_job=
  {cleanup_id:int64;cleanup_scope:Sync.graph_scope;finished:unit Eio.Promise.t;
   mutable children:asset_cleanup_job Rrbvec.t}
type asset_cleanup_snapshot={snapshot_scope:Sync.graph_scope;snapshot_jobs:asset_cleanup_job Rrbvec.t}
type writer_job={writer_operation:Core.Writer_fence.operation;writer_scope:Sync.graph_scope;
  writer_finished:unit Eio.Promise.t;writer_resolve:unit Eio.Promise.u}
module Cleanup_ids=Set.Make(Int64)

type t =
  { sw : Eio.Switch.t
  ; dependencies : dependencies
  ; post : Core.event -> unit
  ; upload_operations : (Upload.ticket, unit Eio.Promise.u) Hashtbl.t
  ; protected_waiters : (string, protected_waiter) Hashtbl.t
  ; asset_waiters : (string, asset_waiter) Hashtbl.t
  ; mutable notice_diagnostics : notice_diagnostic list
  ; asset_operations : (Logseq_sync_pure_reducer.Asset_transfer.ticket, string) Hashtbl.t
  ; mutable next_asset_operation : int64
  ; upload_staging_lock : Eio.Mutex.t
  ; mutable staging_reconciled : Sync.graph_scope list
  ; local_imports : (Sync.graph_scope * Graph.Uuid.t * string, Graph.Uuid.t) Hashtbl.t
  ; recovery_current : Core.upload_recovery_ticket -> bool
  ; upload_current : Upload.ticket -> bool
  ; asset_current : Logseq_sync_pure_reducer.Asset_transfer.ticket -> bool
  ; observation_slots : (int64 * Graph.Uuid.t, observation_slot) Hashtbl.t
  ; mutable observation_registry : Core.Observation_registry.t
  ; mutable orphan_cleanup : Core.Orphan_cleanup.t
  ; mutable orphan_cleanup_running : bool
  ; mutable next_asset_cleanup : int64
  ; mutable next_asset_barrier : int64
  ; asset_cleanup_jobs : (int64,asset_cleanup_job) Hashtbl.t
  ; asset_cleanup_barriers : (int64,unit Eio.Promise.u) Hashtbl.t
  ; sync_io_waiters : (int64,Sync.effect_scope * (unit,string)result Eio.Promise.u)Hashtbl.t
  ; cancelled_asset_jobs : (Logseq_sync_pure_reducer.Asset_transfer.ticket,asset_cleanup_job)Hashtbl.t
  ; asset_result_sources : ((Sync.graph_scope*string),Logseq_sync_pure_reducer.Asset_transfer.ticket)Hashtbl.t
  ; asset_cleanup_stopped : unit Eio.Promise.t * unit Eio.Promise.u
  ; resource_cleanup_owners : ((Sync.graph_scope * string),asset_cleanup_job) Hashtbl.t
  ; mutable writer_fence : Core.Writer_fence.t
  ; writer_jobs : (int64,writer_job)Hashtbl.t
  ; durable_slots : Eio.Semaphore.t
  ; databases : (string, database_session) Hashtbl.t
  ; inspections : (string, Database.mirror_inspection) Hashtbl.t
  ; waiters : (int64, waiter) Hashtbl.t
  ; waiter_lock : Eio.Mutex.t
  ; attachments : (Sync.graph_scope, string) Hashtbl.t
  ; session_snapshots : (Sync.graph_scope, Sync.snapshot) Hashtbl.t
  ; mutable attached : (string * Sync.graph_scope) option
  ; mutable next_database_id : int64
  ; mutable stopped : bool
  ; mutable latest_snapshot : Sync.snapshot option
  ; mutable authorized_graphs : Authorized_graphs.t
  ; mutable deletion_owner : Sync.mirror_deletion option
  }

let runtime ~fork ~sleep = Ok { fork; sleep }
let sync_runner ~submit ~shutdown () = { submit; shutdown }

let dependencies ~runtime ~config ~overlay ~sync_runner ~publish =
  Ok { runtime; config; overlay; sync_runner; publish }
;;

let create ~sw dependencies ~post ~recovery_current ~upload_current ~asset_current =
  Ok
    { sw
    ; dependencies
    ; post
    ; asset_current
    ; upload_current
    ; recovery_current
    ; upload_operations = Hashtbl.create 32
    ; protected_waiters = Hashtbl.create 32
    ; asset_waiters = Hashtbl.create 32
    ; notice_diagnostics = []
    ; asset_operations = Hashtbl.create 8
    ; next_asset_operation = 0L
    ; upload_staging_lock = Eio.Mutex.create ()
    ; staging_reconciled = []
    ; local_imports = Hashtbl.create 32
    ; observation_slots = Hashtbl.create 32
    ; observation_registry = Core.Observation_registry.empty
    ; orphan_cleanup = Core.Orphan_cleanup.empty
    ; orphan_cleanup_running = false
    ; next_asset_cleanup = 0L
    ; next_asset_barrier = 0L
    ; asset_cleanup_jobs = Hashtbl.create 16
    ; asset_cleanup_barriers = Hashtbl.create 16
    ; sync_io_waiters = Hashtbl.create 4
    ; cancelled_asset_jobs = Hashtbl.create 16
    ; asset_result_sources = Hashtbl.create 16
    ; asset_cleanup_stopped = Eio.Promise.create ()
    ; resource_cleanup_owners = Hashtbl.create 16
    ; writer_fence = Core.Writer_fence.empty
    ; writer_jobs = Hashtbl.create 32
    ; durable_slots = Eio.Semaphore.make 8
    ; databases = Hashtbl.create 4
    ; inspections = Hashtbl.create 4
    ; waiters = Hashtbl.create 32
    ; waiter_lock = Eio.Mutex.create ()
    ; attachments = Hashtbl.create 3
    ; session_snapshots = Hashtbl.create 3
    ; attached = None
    ; next_database_id = 0L
    ; stopped = false
    ; latest_snapshot = None
    ; authorized_graphs = Authorized_graphs.empty
    ; deletion_owner = None
    }
;;

let with_upload_store t action =
  let root = t.dependencies.config.application_support_directory in
  let path = Filename.concat root "asset-upload-intents.sqlite" in
  try
    let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
    Unix.close fd;
    let db = Sqlite3.db_open path in
    Fun.protect
      ~finally:(fun () -> (if not (Sqlite3.db_close db) then report_warning "journal: phase=cleanup operation=closeSqlite scope=temporaryStorageHandle code=closePending recovery=reopen\n" ))
      (fun () ->
         Unix.chmod path 0o600;
         Result.bind
           (Logseq_db_storage.Asset_upload_store.initialize_database db)
           (fun () -> action db))
    |> Result.map (fun value ->
      let fd = Unix.openfile root [ Unix.O_RDONLY ] 0 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
      value)
  with
  | exn -> Error (Printexc.to_string exn)
;;

let asset_request t ~scope action =
  let operation = "worker-asset:" ^ Int64.to_string t.next_asset_operation in
  t.next_asset_operation <- Int64.succ t.next_asset_operation;
  { Sync.scope; operation; action }
;;

let post_asset_request t request = t.post (Core.Sync_event (Sync.Asset_requested request))

let send_asset t ~scope action =
  Eio.Cancel.protect (fun () -> post_asset_request t (asset_request t ~scope action))
;;

let reclaim_asset_output t (output : Sync.asset_output) =
  let action =
    match output.result with
    | Ok (Sync.Asset_staged { file; _ }) -> Some (Sync.Release_staged_file file)
    | Ok (Sync.Asset_deletion_prepared deletion) -> Some (Sync.Cancel_graph_asset_deletion deletion)
    | Ok
        ( Asset_retained (Some (handle, _))
        | Asset_cached (Some handle)
        | Asset_downloaded handle ) -> Some (Sync.Release_asset_file handle)
    | Ok _ | Error _ -> None
  in
  Option.iter (send_asset t ~scope:output.request.scope) action
;;

let reclaim_waiter t waiter =
  if (not waiter.accepted) && not waiter.reclaimed
  then (
    waiter.reclaimed <- true;
    Option.iter (reclaim_asset_output t) waiter.delivered)
;;

let current_graph_scope t (scope : Sync.graph_scope) =
  match t.latest_snapshot with
  | Some snapshot -> not t.stopped
      && snapshot.startup.account_generation = scope.account.account_generation
      && (if snapshot.resident_graphs=[] then
        snapshot.startup.graph_generation=scope.graph_generation && snapshot.selected_graph=Some scope.graph_id
        else List.mem scope.graph_id snapshot.resident_graphs
          && (match Hashtbl.find_opt t.session_snapshots scope with
              | Some own -> own.selected_graph=Some scope.graph_id && own.startup.graph_generation=scope.graph_generation
              | None -> Hashtbl.mem t.attachments scope))
  | None -> false
;;

let publish_scoped_asset_detail t scope detail =
  if current_graph_scope t scope then (
    let module D = Logseq_db_types.Failure_diagnostic in
    try t.dependencies.publish (Core.Diagnostic (D.signal_prefix ^ D.encode detail)) with _ -> ())
;;

let asset_call ?(started = fun _ -> ()) ?on_diagnostic t ~scope action =
  let request = asset_request t ~scope action in
  let promise, resolve = Eio.Promise.create () in
  let waiter =
    { request; resolve; delivered = None; accepted = false; reclaimed = false; diagnostic = None }
  in
  Hashtbl.add t.asset_waiters request.operation waiter;
  Fun.protect
    ~finally:(fun () ->
      Hashtbl.remove t.asset_waiters request.operation;
      if not waiter.accepted
      then (
        reclaim_waiter t waiter;
        send_asset t ~scope (Sync.Cancel_asset_operation request.operation)))
    (fun () ->
       started request.operation;
       post_asset_request t request;
       let output = Eio.Promise.await promise in
       waiter.accepted <- true;
       (match output.Sync.result, waiter.diagnostic with
        | Error Sync.Asset_cancelled, _ | Ok _, _ | _, None -> ()
        | Error _, Some detail ->
          (try (Option.value on_diagnostic ~default:(publish_scoped_asset_detail t scope)) detail with _ -> ()));
       waiter.diagnostic <- None;
       output.Sync.result)
;;

let protected_call t action =
  let key =
    match action with
    | Sync.Encrypt_values (key, _) | Decrypt_value (key, _) -> key
  in
  let operation = "worker-protected:" ^ Int64.to_string t.next_asset_operation in
  t.next_asset_operation <- Int64.succ t.next_asset_operation;
  let request =
    { Sync.protected_operation = operation
    ; protected_scope = Sync.graph_key_handle_scope key
    ; protected_action = action
    }
  in
  let promise, resolve = Eio.Promise.create () in
  Hashtbl.add
    t.protected_waiters
    operation
    { protected_request = request; protected_resolve = resolve };
  Fun.protect
    ~finally:(fun () -> Hashtbl.remove t.protected_waiters operation)
    (fun () ->
       t.post (Core.Sync_event (Sync.Protected_requested request));
       (Eio.Promise.await promise).Sync.protected_result)
;;

let encrypt_protected_values t key plaintexts =
  match protected_call t (Sync.Encrypt_values (key, plaintexts)) with
  | Ok (Sync.Encrypted_values values) -> Ok values
  | Ok _ -> Error "Unexpected protected encryption completion"
  | Error (Sync.Effect_failed message | Crypto_failed (_, message)) -> Error message
;;

let decrypt_protected_value t key source =
  match protected_call t (Sync.Decrypt_value (key, source)) with
  | Ok (Sync.Decrypted_value value) -> Ok value
  | Ok _ -> Error "Unexpected protected decryption completion"
  | Error (Sync.Effect_failed message | Crypto_failed (_, message)) -> Error message
;;

let asset_failure_message = function
  | Sync.Asset_invalid_content source ->
    let module D = Logseq_db_types.Failure_diagnostic in
    Option.value (D.decode source)
      ~default:(D.of_source ~operation:"assetPreview" ~reason:"invalidContent" source)
    |> D.message
  | Asset_network -> "Asset network request failed"
  | Asset_not_found | Asset_missing_source -> "Asset source is unavailable"
  | Asset_checksum_mismatch -> "Asset checksum mismatch"
  | Asset_authentication -> "Asset authentication failed"
  | Asset_locked -> "Asset encryption key is unavailable"
  | Asset_storage_full -> "Asset storage is full"
  | Asset_size_rejected -> "Asset size exceeds the limit"
  | Asset_revoked_access -> "Asset access was revoked"
  | Asset_cancelled -> "Asset operation was cancelled"
;;

let asset_unit ?(on_failure = fun _ -> ()) ?on_diagnostic t ~scope action =
  let detail = ref None in
  match asset_call ~on_diagnostic:(fun value -> detail := Some value) t ~scope action with
  | Ok Sync.Asset_unit -> Ok ()
  | Error failure ->
    (try match !detail with
      | Some detail -> (Option.value on_diagnostic ~default:(publish_scoped_asset_detail t scope)) detail
      | None -> on_failure failure with _ -> ());
    Error (asset_failure_message failure)
  | Ok _ ->
    (try on_failure (Sync.Asset_invalid_content "Unexpected asset completion") with _ -> ());
    Error "Unexpected asset completion"
;;

let reserve_writer t scope =
  if t.stopped then Error "The Worker stopped before graph operation admission." else
  let next,outcome=Core.Writer_fence.admit t.writer_fence scope in
  t.writer_fence<-next;
  Result.map_error(function Core.Writer_fence.Fenced->"The graph incarnation is quiescing."
    |Full->"Graph operation capacity is full.")outcome
  |> Result.map(fun writer_operation->
    let writer_finished,writer_resolve=Eio.Promise.create() in
    let job={writer_operation;writer_scope=scope;writer_finished;writer_resolve} in
    Hashtbl.add t.writer_jobs(Core.Writer_fence.operation_id writer_operation)job;job)
;;
let finish_writer t job =
  t.writer_fence<-Core.Writer_fence.finish t.writer_fence job.writer_operation;
  Hashtbl.remove t.writer_jobs(Core.Writer_fence.operation_id job.writer_operation);
  ignore(Eio.Promise.try_resolve job.writer_resolve():bool)
;;
let with_writer t scope action =
  Result.bind(reserve_writer t scope)(fun job->
    Fun.protect ~finally:(fun()->finish_writer t job) action)
;;

let with_staging_lock t action =
  Eio.Mutex.lock t.upload_staging_lock;
  Fun.protect
    ~finally:(fun () -> Eio.Mutex.unlock t.upload_staging_lock)
    (fun () ->
       match action () with
       | result ->
         if Result.is_error result then t.staging_reconciled <- [];
         result
       | exception error ->
         t.staging_reconciled <- [];
         raise error)
;;

let reconcile_staging t (scope : Sync.graph_scope) ~current =
  if (not (current ())) || t.stopped
  then Error "Stale staging recovery"
  else if List.mem scope t.staging_reconciled
  then Ok ()
  else (
    Hashtbl.filter_map_inplace (fun (owner,_,_) operation -> if owner=scope then None else Some operation) t.local_imports;
    let keep =
      with_upload_store t (fun db ->
        let rec read after reversed =
          if (not (current ())) || t.stopped
          then Error "Stale staging recovery"
          else
            Result.bind
              (Logseq_db_storage.Asset_upload_store.list
                 db
                 ~origin:(Uri.to_string scope.account.managed_sync_origin)
                 ~account:scope.account.user_id
                 ~graph:scope.graph_id
                 ~after
                 ~limit:128)
              (fun intents ->
                 let reversed =
                   List.fold_left
                     (fun files intent ->
                        let module I = Logseq_db_types.Asset_upload_intent in
                        if intent.I.phase <> I.Cancelled then
                          Hashtbl.replace t.local_imports
                            (scope, intent.asset, intent.version.checksum) intent.operation_id;
                        intent.staged_file :: files)
                     reversed
                     intents
                 in
                 match List.rev intents with
                 | [] -> Ok (List.rev reversed)
                 | last :: _ when List.length intents = 128 ->
                   read
                     (Some last.Logseq_db_types.Asset_upload_intent.operation_id)
                     reversed
                 | _ -> Ok (List.rev reversed))
        in
        read None [])
    in
    Result.bind keep (fun keep ->
      if (not (current ())) || t.stopped
      then Error "Stale staging recovery"
      else (
        match asset_call t ~scope (Sync.Prune_asset_staging keep) with
        | Ok (Sync.Asset_pruned _) ->
          if current ()
          then (
            t.staging_reconciled <- scope :: t.staging_reconciled;
            Ok ())
          else Error "Stale staging recovery"
        | Error failure -> Error (asset_failure_message failure)
        | Ok _ -> Error "Unexpected staging recovery completion")))
;;

let save_upload t intent expected =
  with_upload_store t (fun db ->
    Logseq_db_storage.Asset_upload_store.save db ~expected intent)
  |> Result.map_error (fun message -> Upload.Persistence_failed message)
;;

let worker_error ~code message =
  Logseq_db_worker_contract.Error.create ~code ~message ~details:[] |> Result.get_ok
;;

let diagnostic_error
      ?(code = Logseq_db_worker_contract.Error.Storage_busy)
      ~operation
      ~reason
      ?source
      ()
  =
  let module E = Logseq_db_worker_contract.Error in
  let module D = Logseq_db_types.Failure_diagnostic in
  let diagnostic =
    match source with
    | None -> D.create ~operation ~reason ()
    | Some source -> D.of_source ~operation ~reason source
  in
  let message = D.message diagnostic in
  let origin =
    E.create_cause
      ~component:E.Managed_sync
      ~operation:(D.operation diagnostic)
      ~code:(Some (D.reason diagnostic))
      ~message
    |> Result.get_ok
  in
  E.create_with_origin
    ~code
    ~message
    ~details:[ E.{ name = D.detail_name; value = Detail_string (D.encode diagnostic) } ]
    ~origin
  |> Result.get_ok
;;

let crypto_result_reason = function
  | Overlay.Crypto_result_missing_item _ -> "missing cryptographic item"
  | Crypto_result_extra_item _ -> "extra cryptographic item"
  | Crypto_result_duplicate_item _ -> "duplicate cryptographic item"
  | Crypto_result_reordered -> "reordered cryptographic items"
  | Crypto_result_stale -> "stale cryptographic result"
  | Crypto_result_limit_exceeded -> "cryptographic result limit exceeded"
;;

let outbox_transition_error error =
  let reason, source =
    match error with
    | Overlay.Outbox_database_closed | Outbox_commit_database_closed ->
      "databaseClosed", None
    | Outbox_sync_token_conflict | Outbox_commit_token_conflict -> "tokenConflict", None
    | Outbox_transition_invalid s -> "transitionInvalid", Some s
    | Outbox_dependency_ineligible _ -> "missingPrecondition", None
    | Outbox_delete_requires_singleton -> "unsupportedFootprint", None
    | Outbox_limit_exceeded -> "limitExceeded", None
    | Outbox_crypto_required -> "cryptoRequired", None
    | Outbox_crypto_unexpected -> "cryptoUnexpected", None
    | Outbox_crypto_error e -> "cryptoInvalid", Some (crypto_result_reason e)
    | Outbox_preparation_consumed -> "preparationConsumed", None
    | Outbox_commit_generation_invalidated -> "generationInvalidated", None
    | Outbox_commit_busy -> "busy", None
    | Outbox_commit_persistence_failed s -> "persistenceFailed", Some s
    | Outbox_commit_integrity_failure s -> "integrityFailed", Some s
  in
  diagnostic_error ~operation:"applyOutbox" ~reason ?source ()
;;

let mirror_error error =
  let reason, source =
    match error with
    | Overlay.Invalid_application_support_directory -> "invalidPath", None
    | Mirror_location_unavailable s -> "resourceFailed", Some s
    | Mirror_inspection_failed s -> "inspectionFailed", Some s
  in
  diagnostic_error ~operation:"inspectMirror" ~reason ?source ()
;;

let snapshot_activation_error error =
  let reason, source =
    match error with
    | Overlay.Invalid_snapshot_path -> "invalidPath", None
    | Invalid_expected_rows -> "invalidExpectedRows", None
    | Snapshot_input_too_large -> "inputTooLarge", None
    | Mirror_exists -> "mirrorExists", None
    | Stale_snapshot_inspection -> "staleInspection", None
    | Snapshot_state_error state ->
      let source = match state with
        | Overlay.Snapshot_root_unavailable -> "snapshot root directory is unavailable"
        | Snapshot_next_after_persist_or_commit -> "snapshot next batch requested after persist or commit"
        | Snapshot_crypto_batch_pending -> "snapshot crypto batch is pending"
        | Snapshot_supply_after_persist_or_commit -> "snapshot supply requested after persist or commit"
        | Snapshot_persist_awaiting_crypto -> "snapshot persist requested while awaiting crypto"
        | Snapshot_checkpoint_invalid `Schema_negative -> "sync schema version must be non-negative"
        | Snapshot_checkpoint_invalid `Checksum_invalid -> "sync checksum must be 16 lowercase hexadecimal characters"
        | Snapshot_checkpoint_invalid `Unknown -> "snapshot checkpoint is invalid" in
      "stateError", Some source
    | Snapshot_crypto_result_error e -> "cryptoInvalid", Some (crypto_result_reason e)
    | Snapshot_crypto_error s -> "cryptoInvalid", Some s
    | Snapshot_parse_error s -> "parseFailed", Some s
    | Snapshot_limit_exceeded -> "limitExceeded", None
    | Snapshot_preparation_canceled -> "cancelled", None
    | Snapshot_commit_stale -> "staleCommit", None
    | Snapshot_commit_consumed -> "commitConsumed", None
    | Snapshot_commit_persistence_failed s -> "persistenceFailed", Some s
  in
  diagnostic_error ~operation:"activateSnapshot" ~reason ?source ()
;;

let open_error error =
  let reason, source =
    match error with
    | Overlay.Mirror_absent -> "mirrorAbsent", None
    | Invalid_graph_name -> "invalidRequest", None
    | Ownership_conflict -> "ownershipConflict", None
    | Attachment_stale -> "attachmentStale", None
    | Restore_failed s -> "restoreFailed", Some s
    | Corrupt_authoritative_store s -> "corruptStore", Some s
    | Corrupt_outbox s -> "corruptOutbox", Some s
    | Corrupt_mutation_receipt s -> "corruptReceipt", Some s
    | Open_resource_failed s -> "resourceFailed", Some s
  in
  diagnostic_error ~operation:"attachGraph" ~reason ?source ()
;;

let listen_error error =
  let reason, source =
    match error with
    | Overlay.Listen_database_closed -> "databaseClosed", None
    | Subscription_inactive | Subscription_already_active -> "stateError", None
    | Listen_capacity_unavailable -> "capacityUnavailable", None
    | Listen_fatal_state s -> "fatalState", Some s
  in
  diagnostic_error ~operation:"attachGraph" ~reason ?source ()
;;

let sync_read_error = function
  | Overlay.Sync_database_closed ->
    diagnostic_error ~operation:"inspectSync" ~reason:"databaseClosed" ()
  | Sync_fatal_state source ->
    diagnostic_error ~operation:"inspectSync" ~reason:"fatalState" ~source ()
;;

let close_error = function
  | Overlay.Close_failed source ->
    diagnostic_error ~operation:"closeDatabase" ~reason:"closeFailed" ~source ()
  | Fatal_close source ->
    diagnostic_error ~operation:"closeDatabase" ~reason:"fatalState" ~source ()
;;

let local_commit_error error =
  let code, reason, source =
    match error with
    | Overlay.Local_commit_busy ->
      Logseq_db_worker_contract.Error.Storage_busy, "busy", None
    | Local_commit_persistence_failed s -> Storage_busy, "persistenceFailed", Some s
    | Local_commit_fatal_state s -> Storage_busy, "fatalState", Some s
    | Local_database_closed -> Conflict, "databaseClosed", None
    | Invalid_local_mutation s -> Conflict, "invalidMutation", Some s
    | Mutation_identity_conflict -> Conflict, "identityConflict", None
    | Missing_precondition _ -> Conflict, "missingPrecondition", None
    | Target_precondition_conflict -> Conflict, "preconditionConflict", None
    | Planner_limit_exceeded -> Conflict, "limitExceeded", None
    | Delete_unsupported_for_footprint -> Conflict, "unsupportedFootprint", None
  in
  diagnostic_error ~code ~operation:"commitLocal" ~reason ?source ()
;;

let effect_error message =
  let module D = Logseq_db_types.Failure_diagnostic in
  let module E = Logseq_db_worker_contract.Error in
  match D.decode message with
  | None -> worker_error ~code:E.Storage_busy message
  | Some detail ->
    E.create ~code:E.Storage_busy ~message:(D.message detail)
      ~details:[ E.{name=D.detail_name;value=Detail_string (D.encode detail)} ]
    |> Result.get_ok
;;

let failure request code message =
  Protocol.failed ~request_id:request.Protocol.request_id (worker_error ~code message)
;;

let response request outcome =
  Protocol.V2_response
    { api_version = Protocol.api_version
    ; request_id = request.Protocol.request_id
    ; outcome
    }
;;

let task_status_to_protocol = function
  | Overlay.Status_uuid uuid -> uuid
  | Legacy_status_ident _ -> invalid_arg "legacy intent escaped durable replay"
;;

let task_status_of_protocol uuid = Overlay.Status_uuid uuid

let block_record ?(tag_titles = []) (value : Overlay.block_record)
  : Protocol.v2_block_record
  =
  { block = value.block
  ; task_status = Option.map task_status_to_protocol value.task_status
  ; rendered_page_title = value.rendered_page_title
  ; tag_titles
  }
;;

let revision_scope_to_protocol = function
  | Overlay.Children_revision parent -> Protocol.V2_children_revision parent
;;

let structure_interest_to_protocol = function
  | Overlay.Children_interest parent -> Protocol.V2_children_interest parent
  | Page_tree_interest page -> V2_page_tree_interest page
  | Journal_index_interest -> V2_journal_index_interest
;;

let resync_reason = function
  | Overlay.Change_limit_exceeded -> "changeLimitExceeded"
  | Dispatcher_retention_exceeded -> "dispatcherRetentionExceeded"
  | Generation_changed -> "generationChanged"
  | Publication_recovered -> "publicationRecovered"
;;

let publish_projection_change t session = function
  | Overlay.Exact
      { generation
      ; before_revision
      ; after_revision
      ; block_uuids
      ; page_uuids
      ; structure_interests
      } ->
    let generation = Overlay.Generation.to_string generation in
    if not (String.equal generation session.generation)
    then (
      session.generation <- generation;
      session.changefeed<-Core.Changefeed_owner.invalidate session.changefeed;
      session.windows <- Rrbvec.empty;
      session.next_window <- 1;
      session.acknowledged_through <- "change-window:v1:0");
    let id = Printf.sprintf "change-window:v1:%d" session.next_window in
    session.next_window <- session.next_window + 1;
    let window:Protocol.v2_change_window=
      {id;predecessor=Overlay.Projection_revision.to_string before_revision;
       successor=Overlay.Projection_revision.to_string after_revision;block_uuids;page_uuids;
       structure_interests=List.map structure_interest_to_protocol structure_interests} in
    let encoded_bytes=Protocol.encoded_response_bytes(Protocol.V2_response
      {api_version=Protocol.api_version;request_id=session.graph_scope.graph_id;
       outcome=Protocol.V2_changes{generation;from_exclusive=None;through=id;next=None;windows=[window]}}) in
    let retained,keep=Core.Changefeed_owner.retain_window session.changefeed ~encoded_bytes in
    session.changefeed<-retained;
    if keep then session.windows<-Rrbvec.push_back session.windows
      {encoded_bytes;id;predecessor=window.predecessor;successor=window.successor;
       block_uuids;page_uuids;structure_interests=window.structure_interests}
    else (session.windows<-Rrbvec.empty;session.acknowledged_through<-id);
    (try
       report_warning ("journal-timeline: " ^ Yojson.Safe.to_string (`Assoc
         [ "stage", `String "worker-change-window"; "generation", `String generation
         ; "window", `String id
         ; "beforeProjection", `String (Overlay.Projection_revision.to_string before_revision)
         ; "projection", `String (Overlay.Projection_revision.to_string after_revision)
         ; "blockCount", `Int (List.length block_uuids)
         ; "pageCount", `Int (List.length page_uuids)
         ; "interestCount", `Int (List.length structure_interests)
         ]) ^ "\n")
     with _ -> ());
    t.post
      (Core.Projection_push_for_scope
         (session.graph_scope, if keep then Protocol.V2_changes_available
            { api_version = Protocol.api_version; generation; through = id }
          else Protocol.V2_resync_required_push{api_version=Protocol.api_version;generation;
            reason="changeHistoryRetentionExceeded"}))
  | Overlay.Projection_resync_required { generation; reason; _ } ->
    let generation = Overlay.Generation.to_string generation in
    if not (String.equal generation session.generation) then session.next_window <- 1;
    session.generation <- generation;
    session.changefeed<-Core.Changefeed_owner.invalidate session.changefeed;
    session.windows <- Rrbvec.empty;
    session.acknowledged_through
    <- Printf.sprintf "change-window:v1:%d" (session.next_window - 1);
    t.post
      (Core.Projection_push_for_scope
         (session.graph_scope, Protocol.V2_resync_required_push
            { api_version = Protocol.api_version
            ; generation
            ; reason = resync_reason reason
            }))
;;

let report_current_graph t (scope : Sync.graph_scope) code =
  if current_graph_scope t scope then
    t.dependencies.publish (Core.Diagnostic code)
;;

let failure_detail ?source ~operation ~reason () =
  let module D = Logseq_db_types.Failure_diagnostic in
  match source with
  | None -> D.create ~operation ~reason ()
  | Some source -> D.of_source ~operation ~reason source
;;

let publish_failure report detail =
  let module D = Logseq_db_types.Failure_diagnostic in
  try report (D.signal_prefix ^ D.encode detail) with _ -> ()
;;

let exception_failure ~operation ~reason error =
  let module D = Logseq_db_types.Failure_diagnostic in
  let literal = match error with Failure source | Invalid_argument source -> Some source | _ -> None in
  let detail = failure_detail ?source:literal ~operation ~reason () in
  if D.source_class detail <> "unknown" then detail
  else failure_detail ~source:(Printexc.to_string error) ~operation ~reason ()
;;

let asset_failure_detail ~operation failure =
  let reason, source = match failure with
    | Sync.Asset_network -> "networkFailed", None
    | Asset_not_found -> "notFound", None
    | Asset_missing_source -> "missingSource", None
    | Asset_checksum_mismatch -> "checksumMismatch", None
    | Asset_authentication -> "authenticationFailed", None
    | Asset_locked -> "locked", None
    | Asset_storage_full -> "storageFull", None
    | Asset_size_rejected -> "sizeRejected", None
    | Asset_revoked_access -> "revokedAccess", None
    | Asset_cancelled -> "cancelled", None
    | Asset_invalid_content source -> "invalidContent", Some source in
  failure_detail ?source ~operation ~reason ()
;;

let report_asset_failure ?detail t scope operation = function
  | Sync.Asset_cancelled -> ()
  | failure ->
    let detail = match detail with
      | None -> asset_failure_detail ~operation failure
      | Some detail ->
        let module D = Logseq_db_types.Failure_diagnostic in
        D.of_source ~operation ~reason:(D.reason detail) (D.encode detail) in
    publish_failure (report_current_graph t scope) detail
;;

let report_source_failure t scope operation reason source =
  publish_failure (report_current_graph t scope) (failure_detail ~source ~operation ~reason ())
;;

let clear_notice_diagnostic ?ticket_id t scope key =
  t.notice_diagnostics <- List.filter (fun item -> item.scope <> scope || item.key <> key
    || Option.fold ~none:false ~some:(fun id -> item.ticket_id<>id) ticket_id)
    t.notice_diagnostics
;;

let queue_notice_diagnostic t scope key ticket_id detail =
  clear_notice_diagnostic t scope key;
  if current_graph_scope t scope then (
    let module D = Logseq_db_types.Failure_diagnostic in
    let operation = match key with Upload_notice _ -> "assetUpload" | Download_notice _ -> "assetDownload" in
    let detail = D.of_source ~operation ~reason:(D.reason detail) (D.encode detail) in
    let rec take n = function [] -> [] | _ when n=0 -> [] | x::xs -> x::take (n-1) xs in
    t.notice_diagnostics <- take 64 ({scope;key;detail;ticket_id} ::
      List.filter (fun item -> current_graph_scope t item.scope) t.notice_diagnostics))
;;

let publish_asset_notice t scope notice output =
  let key, failed, settled = match notice with
    | Core.Upload_status {operation;status;_} ->
      Some (Upload_notice operation), (match status with Upload.Failed_upload _ -> true | _ -> false),
      (match status with Upload.Uploaded | Cancelled -> true | _ -> false)
    | Asset_availability {asset;availability;_} ->
      Some (Download_notice asset), (match availability with
        Logseq_sync_pure_reducer.Asset_transfer.Failed {retry_scheduled=false;_} -> true | _ -> false),
      (match availability with Logseq_sync_pure_reducer.Asset_transfer.Ready _ -> true | _ -> false)
    | Asset_demand_accepted _ | Asset_backpressure _ | Asset_capacity_available -> None, false, false in
  let detail = Option.bind key (fun key ->
    let found = List.find_opt (fun item -> item.scope=scope && item.key=key) t.notice_diagnostics in
    if settled then clear_notice_diagnostic t scope key;
    Option.map (fun item -> item.detail) found) in
  if not t.stopped then t.dependencies.publish output;
  if failed then Option.iter (publish_scoped_asset_detail t scope) detail
;;

let observation_work_start slot =
  if slot.work = 0 then slot.idle <- Eio.Promise.create ();
  slot.work <- slot.work + 1
;;

let observation_work_finish slot =
  slot.work <- slot.work - 1;
  if slot.work = 0 then ignore (Eio.Promise.try_resolve (snd slot.idle) () : bool)
;;

let close_observation t slot =
  slot.closing <- true;
  Option.iter Database.unlisten slot.subscription;
  slot.subscription <- None;
  if slot.work > 0 then Eio.Promise.await (fst slot.idle);
  Hashtbl.remove t.observation_slots (slot.registration, slot.logical_id)
;;

let observation_scope t ~registration ~id =
  Core.Observation_registry.scope t.observation_registry ~registration ~id
;;

let release_observation t ~registration ~id ~scope =
  let next, decision =
    Core.Observation_registry.release t.observation_registry ~registration ~id ~scope
  in
  t.observation_registry <- next;
  match decision with
  | Wrong_owner -> Error "Observation cleanup owner mismatch"
  | Release_full -> Error "Observation cleanup storage is full"
  | Release | Already_released | Unknown ->
    Option.iter
      (close_observation t)
      (Hashtbl.find_opt t.observation_slots (registration, id));
    t.observation_registry
    <- Core.Observation_registry.released t.observation_registry ~registration ~id ~scope;
    Ok ()
;;

let release_unallocated_observation t ~registration ~id ~owner =
  if Hashtbl.mem t.observation_slots (registration, id)
  then Error "Known observation requires physical cleanup with its stored owner"
  else (
    let next, result =
      Core.Observation_registry.release_unallocated
        t.observation_registry
        ~registration
        ~id
        ~owner
    in
    t.observation_registry <- next;
    match result with
    | Unknown | Already_released -> Ok ()
    | _ -> Error "Unallocated observation cleanup was refused")
;;

let release_observations_checked t ~registration =
  let slots=Hashtbl.to_seq_values t.observation_slots
    |> Seq.filter(fun slot->slot.registration=registration) |> Rrbvec.of_seq in
  Rrbvec.fold_left(fun result slot->
    let released=release_observation t ~registration ~id:slot.logical_id ~scope:slot.observation_scope in
    match result with Error _->result|Ok()->released)(Ok())slots
;;
let release_observations t ~registration=ignore(release_observations_checked t ~registration)
;;
let close_database_by_id ?scope t database_id =
  let scope = match scope with
    | Some _ -> scope
    | None -> Option.bind t.attached (fun (id, scope) ->
        if id=database_id then Some scope else None) in
  match Hashtbl.find_opt t.databases database_id with
  | None -> Ok ()
  | Some session ->
    let slots=Hashtbl.to_seq_values t.observation_slots
      |> Seq.filter (fun slot->slot.database_id=database_id) |> List.of_seq in
    List.iter (fun slot->ignore (release_observation t ~registration:slot.registration
      ~id:slot.logical_id ~scope:slot.observation_scope)) slots;
    Database.unlisten session.subscription;
    let result = Database.close session.database in
    (match result with
     | Ok () -> ()
     | Error error ->
       Option.iter (fun (scope:Sync.graph_scope) ->
         match t.latest_snapshot with
         | Some snapshot when not t.stopped
             && snapshot.startup.account_generation=scope.account.account_generation
             && (snapshot.startup.graph_generation=scope.graph_generation
                 || snapshot.selected_graph=None) ->
           (* Returning to the picker advances graph_generation before its
              owned detach runs; a newly selected graph fences that close. *)
           let module D=Logseq_db_types.Failure_diagnostic in
           let reason,source=match error with Overlay.Close_failed s->"closeFailed",s | Fatal_close s->"fatalState",s in
           let detail=D.of_source ~operation:"closeDatabase" ~reason source in
           t.dependencies.publish (Core.Diagnostic(D.signal_prefix ^ D.encode detail))
         | _ -> ()) scope;
       report_warning "journal: operation=closeDatabase code=cleanupPending\n");
    Hashtbl.remove t.databases database_id;
    Hashtbl.filter_map_inplace (fun _ id -> if id=database_id then None else Some id) t.attachments;
    (match t.attached with Some (id,_) when id=database_id -> t.attached <- None | _ -> ());
    Result.map_error
      close_error
      result
;;

let close_attached t =
  match t.attached with
  | None -> Ok ()
  | Some (database_id, scope) ->
    t.attached <- None;
    close_database_by_id ~scope t database_id
;;

let overlay_scope_of_protocol = function
  | Protocol.V2_children_scope parent -> Overlay.Children_revision parent
;;

let parse_preconditions (value : Protocol.v2_preconditions) =
  let rec blocks reversed = function
    | [] -> Ok (List.rev reversed)
    | (uuid, revision) :: rest ->
      (match Overlay.Block_state_revision.of_string revision with
       | Error message -> Error message
       | Ok revision -> blocks ((uuid, revision) :: reversed) rest)
  in
  let rec pages reversed = function
    | [] -> Ok (List.rev reversed)
    | (uuid, revision) :: rest ->
      (match Overlay.Page_state_revision.of_string revision with
       | Error message -> Error message
       | Ok revision -> pages ((uuid, revision) :: reversed) rest)
  in
  let rec scopes reversed = function
    | [] -> Ok (List.rev reversed)
    | (scope, revision) :: rest ->
      (match Overlay.Scope_revision.of_string revision with
       | Error message -> Error message
       | Ok revision ->
         scopes ((overlay_scope_of_protocol scope, revision) :: reversed) rest)
  in
  Result.bind (blocks [] value.blocks) (fun blocks ->
    Result.bind (pages [] value.pages) (fun pages ->
      Result.bind (scopes [] value.scopes) (fun scopes ->
        Database.write_precondition ~blocks ~pages ~scopes
        |> Result.map_error (fun _ -> "duplicate write precondition"))))
;;

let rec block_tree (value : Protocol.v2_block_tree) : Overlay.block_tree =
  { uuid = value.uuid
  ; title = value.title
  ; children = List.map block_tree value.children
  }
;;

let rec append_node (node:Protocol.v2_append_node) : Overlay.append_node =
  {uuid=node.block_id;title=node.title;task_status=node.task_status;children=Rrbvec.map append_node node.children}
;;

let journal_append_title format day =
  let module Title=Logseq_db_types.Journal_title in
  let render pattern=Title.format ~pattern ~year:(day/10000) ~month:(day/100 mod 100) ~day:(day mod 100) in
  match render(Option.value format ~default:Title.default_format) with
  |Some title->title|None->Option.get(render Title.default_format)
;;

let local_mutation ?append_title = function
  | Protocol.V2_append_journal{mutation_id;page;journal_day;root}->
    let title=Option.value append_title ~default:(journal_append_title None journal_day) in
    Ok(Protocol.{blocks=[];pages=[];scopes=[]},Overlay.Append_journal
      {mutation_id;page;journal_day;title;root=append_node root})
  | Protocol.V2_set_asset_reference { mutation_id; block; previous; asset; preconditions }
    ->
    Ok (preconditions, Overlay.Set_asset_reference { mutation_id; block; previous; asset })
  | Protocol.V2_save_block { mutation_id; block; title; preconditions } ->
    Ok (preconditions, Overlay.Save_block { mutation_id; block; title })
  | V2_insert_blocks { mutation_id; parent; roots = [ root ]; preconditions } ->
    Ok
      ( preconditions
      , Overlay.Insert_blocks
          { mutation_id; parent; tree = block_tree root; asset = None } )
  | V2_insert_blocks _ -> Error "insertBlocks requires exactly one root"
  | V2_delete_blocks { mutation_id; root; preconditions } ->
    Ok (preconditions, Overlay.Delete_blocks { mutation_id; root })
  | V2_create_journal_page { mutation_id; page; journal_day; title; preconditions } ->
    Ok
      ( preconditions
      , Overlay.Create_journal_page { mutation_id; page; journal_day; title } )
  | V2_set_task_status { mutation_id; block; status; preconditions } ->
    Ok
      ( preconditions
      , Overlay.Set_task_status
          { mutation_id; block; status = task_status_of_protocol status } )
  | V2_clear_task_status { mutation_id; block; preconditions } ->
    Ok (preconditions, Overlay.Clear_task_status { mutation_id; block })
  | V2_graph_info
  | V2_inspect_admission
  | V2_get_asset_descriptors _
  | V2_list_assets _
  | V2_list_task_statuses _
  | V2_get_task_status_definitions _
  | V2_list_favorites _
  | V2_list_journals _
  | V2_get_page _
  | V2_get_outline_block _
  | V2_get_outline_block_summary _
  | V2_get_children _
  | V2_get_page_tree _
  | V2_pull_changes _
  | V2_ack_changes _ -> Error "not a local mutation"
;;

let local_status = function
  | Overlay.Applied -> Protocol.V2_applied
  | No_change -> V2_no_change
  | Already_applied -> V2_already_applied
;;

let committed_outcome (commit : Overlay.local_commit) =
  Protocol.V2_mutation_committed
    { mutation_id = commit.mutation_id
    ; status = local_status commit.status
    ; generation = Overlay.Generation.to_string commit.generation
    ; before_projection_revision =
        Overlay.Projection_revision.to_string commit.before_projection_revision
    ; after_projection_revision =
        Overlay.Projection_revision.to_string commit.after_projection_revision
    }
;;

let execute_mutation database request command =
  match local_mutation command with
  | Error message -> failure request Unsupported_semantics message
  | Ok (raw_preconditions, mutation) ->
    (match parse_preconditions raw_preconditions with
     | Error message -> failure request Conflict message
     | Ok expected ->
       (match Database.commit_local database ~expected mutation with
        | Error error -> Protocol.failed ~request_id:request.Protocol.request_id (local_commit_error error)
        | Ok (Overlay.Local_existing (Overlay.Existing_applied commit)) ->
          response request (committed_outcome commit)
        | Ok (Local_existing _) ->
          failure request Conflict "The mutation ID already has a terminal outcome."
        | Ok (Local_committed commit) -> response request (committed_outcome commit)))
;;

let inspect_admission database request =
  match Database.inspect_admission database with
  | Error _ -> failure request Closed_session "Admission information is unavailable."
  | Ok inspection ->
    response
      request
      (Protocol.V2_admission_outcome
         { active_records = inspection.active_records
         ; active_bytes = inspection.active_bytes
         ; protected_wire_bytes = inspection.protected_wire_bytes
         ; retained_origin_evidence_bytes = inspection.retained_origin_evidence_bytes
         ; maximum_records = inspection.maximum_records
         ; maximum_bytes = inspection.maximum_bytes
         })
;;

let read_failure ?code request error =
  let fail default message = failure request (Option.value code ~default) message in
  let safe_message reason source =
    Logseq_db_types.Failure_diagnostic.of_source
      ~operation:"workerOperation"
      ~reason
      source
    |> Logseq_db_types.Failure_diagnostic.message
  in
  match error with
  | Overlay.Stale_read_cursor ->
    fail Stale_read_cursor "The read continuation is no longer current."
  | Invalid_read_request source -> fail Invalid_request (safe_message "invalidRequest" source)
  | Read_limit_exceeded ->
    fail Response_too_large "The read exceeded its resource limit."
  | Database_closed | Snapshot_released | Snapshot_generation_invalidated ->
    fail Closed_session "The read snapshot is no longer available."
  | Fatal_read_state source -> fail Corrupt_storage (safe_message "fatalState" source)
;;

let read_snapshot ?snapshot ?(release_snapshot=true) ~on_enrichment_error ~response_budget_bytes database request command =
  match (match snapshot with Some snapshot->Ok snapshot | None->Database.current_snapshot database) with
  | Error _ -> failure request Closed_session "The graph snapshot is unavailable."
  | Ok snapshot ->
    Fun.protect
      ~finally:(fun () -> if release_snapshot then Database.release_snapshot snapshot)
      (fun () ->
         let query_evidence query ?target items has_continuation =
           try
             let version = Database.snapshot_version snapshot in
             let fields =
               [ "stage", `String "worker-query"; "query", `String query
               ; "request", `String (Graph.Uuid.to_string request.request_id)
               ; "generation", `String (Overlay.Generation.to_string version.generation)
               ; "projection", `String (Overlay.Projection_revision.to_string version.projection_revision)
               ; "itemCount", `Int (List.length items)
               ; "items", `List (List.take 16 items |> List.map (fun u -> `String (Graph.Uuid.to_string u)))
               ; "hasContinuation", `Bool has_continuation
               ; "truncated", `Bool (List.length items > 16)
               ] @ Option.fold ~none:[] ~some:(fun u -> ["target", `String (Graph.Uuid.to_string u)]) target in
             report_warning ("journal-timeline: " ^ Yojson.Safe.to_string (`Assoc fields) ^ "\n")
           with _ -> ()
         in
         let page_read_evidence result uuid =
           try
             let version = Database.snapshot_version snapshot in
             report_warning
               ("journal-page-read: "
                ^ Yojson.Safe.to_string
                    (`Assoc
                       [ "result", `String result
                       ; "request", `String (Graph.Uuid.to_string request.request_id)
                       ; "target", `String (Graph.Uuid.to_string uuid)
                       ; "generation", `String (Overlay.Generation.to_string version.generation)
                       ; "projection", `String
                           (Overlay.Projection_revision.to_string version.projection_revision)
                       ])
                ^ "\n")
           with _ -> ()
         in
         let titles = Hashtbl.create 16 in
         let block_record (value : Overlay.block_record) =
           let missing =
             List.filter
               (fun uuid -> not (Hashtbl.mem titles (Graph.Uuid.to_string uuid)))
               value.block.tags
           in
           if missing <> []
           then (
             match Database.get_pages snapshot missing with
             | Ok pages ->
               List.iter
                 (function
                   | Overlay.Present_page { value; _ } ->
                     Hashtbl.replace
                       titles
                       (Graph.Uuid.to_string value.page.uuid)
                       (Some value.page.title)
                   | Overlay.Missing_page { uuid; _ } ->
                     Hashtbl.replace titles (Graph.Uuid.to_string uuid) None)
                 pages
             | Error _ -> on_enrichment_error ());
           let tag_titles =
             List.filter_map
               (fun uuid ->
                  Option.join (Hashtbl.find_opt titles (Graph.Uuid.to_string uuid)))
               value.block.tags
           in
           block_record ~tag_titles value
         in
         let read command = match command with
         | Protocol.V2_graph_info ->
           (match Database.graph_info snapshot with
            | Error error -> read_failure ~code:Corrupt_storage request error
            | Ok info ->
              let limits = info.Overlay.limits in
              response
                request
                (Protocol.V2_graph_info_outcome
                   { graph_uuid = info.graph_uuid
                   ; graph_name = info.graph_name
                   ; schema = info.schema
                   ; admission_facts = info.admission_facts
                   ; journal_title_format = info.journal_title_format
                   ; limits =
                       { response_budget_bytes = limits.response_budget_bytes
                       ; outbox_max_records = limits.outbox_max_records
                       ; outbox_max_bytes = limits.outbox_max_bytes
                       ; change_max_items = limits.change_max_items
                       ; change_max_bytes = limits.change_max_bytes
                       ; dispatcher_capacity = limits.dispatcher_capacity
                       ; wire_batch_max_bytes = limits.wire_batch_max_bytes
                       }
                   ; generation = Overlay.Generation.to_string info.version.generation
                   ; projection_revision =
                       Overlay.Projection_revision.to_string
                         info.version.projection_revision
                   }))
         | V2_inspect_admission ->
           failure request Invalid_request "The command is not a snapshot read."
         | V2_list_task_statuses { limit; cursor } ->
           (match Database.get_task_statuses snapshot ~limit ~cursor with
            | Error error -> read_failure request error
            | Ok result ->
              response
                request
                (Protocol.V2_task_statuses_outcome
                   { property_uuid = result.property_uuid
                   ; default_status = result.default_status
                   ; items = result.items
                   ; next_cursor = result.next_cursor
                   }))
         | V2_get_task_status_definitions { statuses } ->
           (match Database.get_task_status_definitions snapshot statuses with
            | Error error -> read_failure request error
            | Ok result ->
              response request (Protocol.V2_task_status_definitions_outcome result))
         | V2_list_favorites { limit; cursor } ->
           (match Database.get_favorites snapshot ~limit ~cursor with
            | Error error -> read_failure request error
            | Ok result ->
              let items =
                List.map
                  (fun (item : Overlay.favorite_item) ->
                     let target =
                       match item.target with
                       | Overlay.Favorite_page { uuid; title; revision } ->
                         Protocol.V2_favorite_page
                           { uuid
                           ; title
                           ; revision = Overlay.Page_state_revision.to_string revision
                           }
                       | Overlay.Favorite_block { uuid; title; task_status; revision } ->
                         Protocol.V2_favorite_block
                           { uuid
                           ; title
                           ; task_status = Option.map task_status_to_protocol task_status
                           ; revision = Overlay.Block_state_revision.to_string revision
                           }
                     in
                     Protocol.
                       { membership_uuid = item.membership_uuid
                       ; membership_order = item.membership_order
                       ; membership_revision =
                           Overlay.Block_state_revision.to_string item.membership_revision
                       ; target
                       })
                  result.items
              in
              response
                request
                (Protocol.V2_favorites_outcome
                   { favorites_page = result.favorites_page
                   ; generation = Overlay.Generation.to_string result.version.generation
                   ; projection_revision =
                       Overlay.Projection_revision.to_string
                         result.version.projection_revision
                   ; items
                   ; next_cursor = result.next_cursor
                   }))
         | V2_get_asset_descriptors { assets } ->
           (match Database.get_asset_descriptors snapshot assets with
            | Error error -> read_failure request error
            | Ok items ->
              let version = Database.snapshot_version snapshot in
              response
                request
                (Protocol.V2_assets_outcome
                   { items
                   ; next_cursor = None
                   ; generation = Overlay.Generation.to_string version.generation
                   ; projection_revision =
                       Overlay.Projection_revision.to_string version.projection_revision
                   }))
         | V2_list_assets { recursive; roots; limit; cursor } ->
           (match
              Database.get_assets_under_roots snapshot ~recursive ~roots ~limit ~cursor
            with
            | Error error -> read_failure request error
            | Ok result ->
              let version = Database.snapshot_version snapshot in
              response
                request
                (Protocol.V2_assets_outcome
                   { items = result.assets
                   ; next_cursor = result.next_cursor
                   ; generation = Overlay.Generation.to_string version.generation
                   ; projection_revision =
                       Overlay.Projection_revision.to_string version.projection_revision
                   }))
         | V2_list_journals { from_day; through_day; limit; cursor; _ } ->
           (match
              Database.get_journals snapshot ~from_day ~through_day ~limit ~cursor
            with
            | Error error -> read_failure request error
            | Ok result ->
              query_evidence "journals"
                (List.map (fun (item : Overlay.journal_item) -> item.page.page.uuid) result.items)
                (Option.is_some result.next_cursor);
              let items =
                result.items
                |> List.map (fun (item : Overlay.journal_item) ->
                  Protocol.
                    { page = item.page.page
                    ; journal_day = item.journal_day
                    ; revision = Overlay.Page_state_revision.to_string item.revision
                    })
              in
              response
                request
                (Protocol.V2_journals_outcome { items; next_cursor = result.next_cursor }))
         | V2_get_page { page; _ } ->
           (match Database.get_pages snapshot [ page ] with
            | Ok [ Overlay.Present_page { value; revision } ] ->
              page_read_evidence "present" value.page.uuid;
              response
                request
                (Protocol.V2_page_outcome
                   (V2_present_page
                      { page = value.page
                      ; revision = Overlay.Page_state_revision.to_string revision
                      }))
            | Ok [ Missing_page { uuid; revision } ] ->
              page_read_evidence "missing" uuid;
              response
                request
                (Protocol.V2_page_outcome
                   (V2_missing_page
                      { uuid; revision = Overlay.Page_state_revision.to_string revision }))
            | Error error -> read_failure ~code:Corrupt_storage request error
            | Ok _ -> failure request Corrupt_storage "The page lookup failed.")
         | V2_get_outline_block { block; _ } ->
           (match Database.get_outline_blocks snapshot [ block ] with
            | Ok [ Overlay.Present_block { value; revision } ] ->
              response
                request
                (Protocol.V2_block_outcome
                   (V2_present_block
                      { value = block_record value
                      ; revision = Overlay.Block_state_revision.to_string revision
                      }))
            | Ok [ Missing_block { uuid; revision } ] ->
              response
                request
                (Protocol.V2_block_outcome
                   (V2_missing_block
                      { uuid; revision = Overlay.Block_state_revision.to_string revision }))
            | Error error -> read_failure ~code:Corrupt_storage request error
            | Ok _ -> failure request Corrupt_storage "The block lookup failed.")
         | V2_get_outline_block_summary { block; limit; cursor } ->
           let version = Database.snapshot_version snapshot in
           let summary lookup page scope_revision items next_cursor =
             response
               request
               (Protocol.V2_block_summary_outcome
                  { lookup
                  ; page
                  ; scope_revision
                  ; items
                  ; next_cursor
                  ; generation = Overlay.Generation.to_string version.generation
                  ; projection_revision =
                      Overlay.Projection_revision.to_string version.projection_revision
                  })
           in
           if limit < 1 || limit > Protocol.maximum_page_size
           then failure request Invalid_request "Invalid block summary limit."
           else (
             match Database.get_outline_blocks snapshot [ block ] with
             | Ok [ Overlay.Missing_block { uuid; revision } ] ->
               summary
                 (V2_missing_block
                    { uuid; revision = Overlay.Block_state_revision.to_string revision })
                 None
                 ""
                 []
                 None
             | Ok [ Overlay.Present_block { value; revision } ] ->
               let lookup =
                 Protocol.V2_present_block
                   { value = block_record value
                   ; revision = Overlay.Block_state_revision.to_string revision
                   }
               in
               (match Database.get_pages snapshot [ value.block.page ] with
                | Ok [ Overlay.Present_page { value = page; revision } ] ->
                  let page =
                    Some
                      (Protocol.V2_present_page
                         { page = page.page
                         ; revision = Overlay.Page_state_revision.to_string revision
                         })
                  in
                  (match
                     Database.get_structure
                       snapshot
                       (Overlay.Children { parent = block; limit; cursor })
                   with
                   | Ok
                       (Overlay.Children_result { scope_revision; items; next_cursor; _ })
                     ->
                     summary
                       lookup
                       page
                       (Overlay.Scope_revision.to_string scope_revision)
                       (List.map
                          (fun (item : Overlay.child_member) ->
                             Protocol.
                               { value = block_record item.block
                               ; revision =
                                   Overlay.Block_state_revision.to_string item.revision
                               })
                          items)
                       next_cursor
                   | Error error -> read_failure request error
                   | Ok (Page_tree_result _) ->
                     failure
                       request
                       Invalid_request
                       "The target children query returned a page tree.")
                | Ok [ Missing_page { uuid; revision } ] ->
                  summary
                    lookup
                    (Some
                       (V2_missing_page
                          { uuid
                          ; revision = Overlay.Page_state_revision.to_string revision
                          }))
                    ""
                    []
                    None
                | Error error -> read_failure ~code:Corrupt_storage request error
                | Ok _ ->
                  failure request Corrupt_storage "The target page lookup failed.")
             | Error error -> read_failure request error
             | Ok _ -> failure request Corrupt_storage "The target block lookup failed.")
         | V2_get_children { parent; limit; cursor; _ } ->
           (match
              Database.get_structure snapshot (Overlay.Children { parent; limit; cursor })
            with
            | Ok
                (Overlay.Children_result
                   { parent; revision_scope; scope_revision; items; next_cursor }) ->
              query_evidence "children" ~target:parent
                (List.map (fun (item : Overlay.child_member) -> item.block.block.uuid) items)
                (Option.is_some next_cursor);
              response
                request
                (Protocol.V2_children_outcome
                   { parent
                   ; revision_scope = revision_scope_to_protocol revision_scope
                   ; scope_revision = Overlay.Scope_revision.to_string scope_revision
                   ; items =
                       List.map
                         (fun (item : Overlay.child_member) ->
                            Protocol.
                              { value = block_record item.Overlay.block
                              ; revision =
                                  Overlay.Block_state_revision.to_string item.revision
                              })
                         items
                   ; next_cursor
                   })
            | Error error -> read_failure request error
            | Ok (Page_tree_result _) ->
              failure request Invalid_request "The children query returned a page tree.")
         | V2_get_page_tree { page; maximum_depth; limit; cursor; _ } ->
           (match
              Database.get_structure
                snapshot
                (Overlay.Page_tree { page; maximum_depth; limit; cursor })
            with
            | Ok (Overlay.Page_tree_result { page; maximum_depth; items; next_cursor }) ->
              query_evidence "page-tree" ~target:page
                (List.map (fun (item : Overlay.tree_member) -> item.block.block.uuid) items)
                (Option.is_some next_cursor);
              response
                request
                (Protocol.V2_page_tree_outcome
                   { page
                   ; maximum_depth
                   ; items =
                       List.map
                         (fun (item : Overlay.tree_member) ->
                            Protocol.
                              { value = block_record item.Overlay.block
                              ; revision =
                                  Overlay.Block_state_revision.to_string item.revision
                              ; depth = item.depth
                              ; parent = item.parent
                              })
                         items
                   ; next_cursor
                   })
            | Error error -> read_failure request error
            | Ok (Children_result _) ->
              failure request Invalid_request "The page-tree query returned children.")
         | V2_set_asset_reference _
         | V2_save_block _
         | V2_insert_blocks _
         | V2_append_journal _
         | V2_delete_blocks _
         | V2_create_journal_page _
         | V2_set_task_status _
         | V2_clear_task_status _
         | V2_pull_changes _
         | V2_ack_changes _ ->
           failure request Invalid_request "The command is not a snapshot read."
         in
         let budget=min response_budget_bytes Protocol.maximum_response_bytes in
         (* Reuse this pinned snapshot and enrichment cache across bounded
            attempts. The client budget and query identity stay unchanged;
            storage returns a shorter complete page with its true next cursor. *)
         let rec fit command =
           let result=read command in
           if Protocol.encoded_response_bytes result<=budget then result
           else match Protocol.smaller_read_page command with
             | Some smaller -> fit smaller
             | None -> failure request Response_too_large "The encoded read singleton exceeded its byte limit."
         in fit command)
;;

let index_after session cursor =
  if String.equal cursor session.acknowledged_through
  then Some 0
  else if
    match Rrbvec.peek_back_opt session.windows with
    | Some window -> String.equal window.id cursor
    | None -> false
  then Some (Rrbvec.length session.windows)
  else (
    let position = ref 0 in
    Rrbvec.find_map
      (fun window ->
         incr position;
         if String.equal window.id cursor then Some !position else None)
      session.windows)
;;

let cursor_resync session request reason =
  response
    request
    (Protocol.V2_resync_required { generation = session.generation; reason })
;;

let pull_changes session request generation after limit =
  if not (String.equal generation session.generation)
  then cursor_resync session request "generationChanged"
  else (
    let start =
      match after with
      | None -> Some 0
      | Some cursor -> index_after session cursor
    in
    match start with
    | None -> cursor_resync session request "changeCursorUnavailable"
    | Some start ->
      let available = Rrbvec.length session.windows - start in
      let count = min (max 0 limit) available in
      let selected = Rrbvec.subvec session.windows start (start + count) |> Option.get in
      let through =
        match Rrbvec.peek_back_opt selected with
        | Some window -> window.id
        | None -> Option.value after ~default:session.acknowledged_through
      in
      let next = if count < available then Some through else None in
      response
        request
        (Protocol.V2_changes
           { generation
           ; from_exclusive = after
           ; through
           ; next
           ; windows =
               Rrbvec.fold_right
                 (fun (window : change_window) rest ->
                    Protocol.
                      { id = window.id
                      ; predecessor = window.predecessor
                      ; successor = window.successor
                      ; block_uuids = window.block_uuids
                      ; page_uuids = window.page_uuids
                      ; structure_interests = window.structure_interests
                      }
                    :: rest)
                 selected
                 []
           }))
;;

let acknowledge_changes session request generation through =
  if not (String.equal generation session.generation)
  then cursor_resync session request "generationChanged"
  else (
    match index_after session through with
    | None -> cursor_resync session request "changeCursorUnavailable"
    | Some start ->
      let removed=Rrbvec.subvec session.windows 0 start |> Option.get in
      let encoded_bytes=Rrbvec.fold_left(fun total window->total+window.encoded_bytes)0 removed in
      session.changefeed<-Core.Changefeed_owner.release_windows session.changefeed ~count:start ~encoded_bytes;
      session.windows
      <- Rrbvec.subvec session.windows start (Rrbvec.length session.windows) |> Option.get;
      session.acknowledged_through <- through;
      response request (Protocol.V2_changes_acknowledged { generation; through }))
;;

let execute_database ~on_enrichment_error session ~response_budget_bytes request =
  match request.Protocol.command with
  | Protocol.V2_pull_changes { generation; after; limit } ->
    if Core.Changefeed_owner.legacy session.changefeed then pull_changes session request generation after limit
    else failure request Invalid_request "The changefeed is owned by the registered coordinator."
  | V2_ack_changes { generation; through } ->
    if Core.Changefeed_owner.legacy session.changefeed then acknowledge_changes session request generation through
    else failure request Invalid_request "The changefeed is owned by the registered coordinator."
  | V2_append_journal _ ->
    failure request Unsupported_semantics "Atomic Append requires a registered durable intent."
  | V2_inspect_admission ->
    let result=inspect_admission session.database request in
    if Protocol.encoded_response_bytes result<=min response_budget_bytes Protocol.maximum_response_bytes
    then result else failure request Response_too_large "The encoded admission result exceeded its byte limit."
  | ( V2_set_asset_reference _
    | V2_save_block _
    | V2_insert_blocks _
    | V2_delete_blocks _
    | V2_create_journal_page _
    | V2_set_task_status _
    | V2_clear_task_status _ ) as command ->
    execute_mutation session.database request command
  | command ->
    read_snapshot ~on_enrichment_error ~response_budget_bytes session.database request command
;;

let observation_alive t slot = (not t.stopped) && (not slot.closing) && slot.current ()

let sample_observation ?snapshot t slot request =
  Fun.protect
    ~finally:(fun () -> Option.iter Database.release_snapshot snapshot)
    (fun () ->
       match Hashtbl.find_opt t.databases slot.database_id with
       | None -> Error "Observation graph is no longer attached"
       | Some session ->
         if not (observation_alive t slot)
         then Error "Observation execution was retired"
         else (
           let response =
             read_snapshot
               ?snapshot
               ~release_snapshot:(Option.is_none snapshot)
               ~on_enrichment_error:(fun _ -> ())
               ~response_budget_bytes:
                 (min slot.maximum_bytes t.dependencies.config.response_budget_bytes)
               session.database
               request
               request.Protocol.command
           in
           if observation_alive t slot
           then Ok response
           else Error "Observation execution was retired"))
;;

let invalidate_observation t slot _change =
  if observation_alive t slot
  then (
    let next, epoch =
      Core.Observation_registry.advance
        t.observation_registry
        ~registration:slot.registration
        ~id:slot.logical_id
    in
    t.observation_registry <- next;
    Option.iter (fun epoch -> slot.notify ~epoch) epoch)
;;

let register_observation
      t
      ~registration
      ~id
      ~scope
      ~request
      ~maximum_bytes
      ~current
      ~notify
  =
  if
    t.stopped
    || (not (current ()))
    || request.Protocol.api_version <> Protocol.api_version
  then Error "Observation execution is not current"
  else (
    let next, decision =
      Core.Observation_registry.reserve
        t.observation_registry
        ~registration
        ~id
        ~scope
        ~command:request.command
        ~maximum_bytes
    in
    t.observation_registry <- next;
    match decision with
    | Existing ->
      (match Hashtbl.find_opt t.observation_slots (registration, id) with
       | Some slot ->
         Eio.Promise.await slot.initial
         |> Result.map (fun (epoch, Protocol.V2_response response) ->
           epoch, Protocol.V2_response { response with request_id = request.request_id })
       | None -> Error "Observation allocation is unavailable")
    | Retired | Mismatch | Full | Invalid -> Error "Observation registration was refused"
    | Start ->
      (match Hashtbl.find_opt t.attachments scope with
       | None ->
         ignore (release_observation t ~registration ~id ~scope);
         Error "Observation graph is no longer attached"
       | Some database_id ->
         let initial, initial_resolve = Eio.Promise.create () in
         let slot =
           { registration
           ; logical_id = id
           ; observation_scope = scope
           ; database_id
           ; request
           ; maximum_bytes
           ; current
           ; notify
           ; initial
           ; initial_resolve
           ; subscription = None
           ; closing = false
           ; work = 0
           ; idle = Eio.Promise.create ()
           }
         in
         Hashtbl.add t.observation_slots (registration, id) slot;
         observation_work_start slot;
         let result = ref (Error "Observation registration interrupted") in
         Eio.Cancel.protect (fun () ->
           Fun.protect
             ~finally:(fun () ->
               if slot.closing
               then (
                 Option.iter Database.unlisten slot.subscription;
                 slot.subscription <- None);
               observation_work_finish slot;
               (match !result with
                | Error _ -> ignore (release_observation t ~registration ~id ~scope)
                | Ok _ -> ());
               ignore (Eio.Promise.try_resolve slot.initial_resolve !result : bool))
             (fun () ->
                (result
                 := try
                      match Hashtbl.find_opt t.databases database_id with
                      | None -> Error "Observation graph is no longer attached"
                      | Some session ->
                        (match Database.listen session.database with
                         | Error _ -> Error "Observation listener could not register"
                         | Ok (subscription, snapshot) ->
                           slot.subscription <- Some subscription;
                           (match sample_observation ~snapshot t slot request with
                            | Error _ as error -> error
                            | Ok response ->
                              (match
                                 Database.activate_subscription
                                   subscription
                                   ~notify:(invalidate_observation t slot)
                               with
                               | Error _ -> Error "Observation replay could not activate"
                               | Ok () -> Ok (0L, response))))
                    with
                    | _ -> Error "Observation registration failed");
                !result))))
;;
let refresh_observation t ~registration ~id ~scope ~request_id =
  match Hashtbl.find_opt t.observation_slots (registration, id) with
  | None -> Error "Observation registration is not active"
  | Some slot ->
    let _, decision =
      Core.Observation_registry.reserve
        t.observation_registry
        ~registration
        ~id
        ~scope
        ~command:slot.request.command
        ~maximum_bytes:slot.maximum_bytes
    in
    if decision <> Core.Observation_registry.Existing
    then Error "Observation owner mismatch"
    else (
      let initial = Eio.Promise.await slot.initial in
      match initial with
      | Error _ as error -> error
      | Ok _ when not (observation_alive t slot) ->
        Error "Observation execution was retired"
      | Ok _ ->
        let next, epoch =
          Core.Observation_registry.advance t.observation_registry ~registration ~id
        in
        t.observation_registry <- next;
        (match epoch with
         | None -> Error "Observation epoch is unavailable"
         | Some epoch ->
           observation_work_start slot;
           Fun.protect
             ~finally:(fun () -> observation_work_finish slot)
             (fun () ->
                let outcome =
                  sample_observation t slot { slot.request with request_id }
                in
                match outcome with
                | Ok response
                  when Core.Observation_registry.current
                         t.observation_registry
                         ~registration
                         ~id
                         ~epoch -> Ok (epoch, response)
                | Ok _ -> Error "Observation read was superseded"
                | Error _ as error -> error)))
;;
let sync_result ?event ?(lifecycle = Core.Lifecycle_unchanged) () =
  Core.{ event; lifecycle }
;;

let attached_session t scope =
  Option.bind (Hashtbl.find_opt t.attachments scope) (Hashtbl.find_opt t.databases)
;;

let retire_changefeed t ~registration =
  Hashtbl.iter(fun _ session->session.changefeed<-Core.Changefeed_owner.retire session.changefeed ~registration) t.databases
;;
let coordinated_changefeed t ~registration ~scope ~request ~maximum_bytes ~current =
  if t.stopped || not(current ()) || request.Protocol.api_version<>Protocol.api_version
      || maximum_bytes<=0 || maximum_bytes>Protocol.maximum_response_bytes
  then Error "The registered changefeed execution is unavailable"
  else match attached_session t scope with
  | None -> Error "The scoped changefeed database is no longer attached"
  | Some session ->
    let state,claimed=Core.Changefeed_owner.claim session.changefeed ~registration in
    session.changefeed<-state;
    if not claimed then Error "Another registration still owns the changefeed" else
    let generation=match request.command with
      | Protocol.V2_pull_changes query->Some query.generation
      | V2_ack_changes query->Some query.generation
      | _->None in
    if Option.exists(fun generation->generation<>session.generation) generation
    then Ok(cursor_resync session request "generationChanged") else
    match request.command with
    | Protocol.V2_pull_changes query ->
      if query.generation<>session.generation then Ok(cursor_resync session request "generationChanged") else
      (match Core.Changefeed_owner.pull state ~registration ~request ~maximum_bytes with
       | Refused->Error "The pending changefeed batch must be applied and acknowledged first"
       | Cached response->Ok response
       | Read ->
         let rec fit limit =
           let response=pull_changes session request query.generation query.after limit in
           if Protocol.encoded_response_bytes response<=maximum_bytes then response
           else if limit>1 then fit(max 1(limit/2)) else
             failure request Response_too_large "The change window exceeds its encoded-byte budget" in
         let response=fit query.limit in
         (match response with
          | Protocol.V2_response{outcome=Protocol.V2_changes _;_}->
            Result.map(fun state->session.changefeed<-state;response)
              (Core.Changefeed_owner.remember state ~registration ~request ~maximum_bytes response)
          | _ -> Ok response))
    | V2_ack_changes _ when Core.Changefeed_owner.needs_resync state ->
      Ok(cursor_resync session request "changeHistoryInvalidated")
    | V2_ack_changes query when Core.Changefeed_owner.may_ack state ~registration
        ~generation:query.generation ~through:query.through ->
      let response=acknowledge_changes session request query.generation query.through in
      session.changefeed<-Core.Changefeed_owner.acknowledged session.changefeed ~registration ~request response;
      Ok response
    | V2_ack_changes _ -> Error "The changefeed ACK is not backed by this owner's delivered batch"
    | _ -> Error "This operation is not Changes or its ACK"
;;

let run_durable_mutation t ~(scope:Sync.graph_scope) ~request_id ~intent ~current =
  let module Wire=Logseq_db_worker_contract.Mutation_pure_wire in
  let fail error=Protocol.failed ~request_id error in
  match Wire.restore ~origin:scope.account.managed_sync_origin ~user:scope.account.user_id ~graph:scope.graph_id intent with
  | Error message->Wire.Rejected(failure {Protocol.api_version=Protocol.api_version;request_id;command=Protocol.V2_graph_info}
      Invalid_request message)
  | Ok wire->
    let request=Protocol.{api_version;request_id;command=Wire.command wire} in
    if t.stopped || not(current()) then Wire.Unknown else
    match attached_session t scope with
    | None->Wire.Unknown
    | Some session->
      let existing ()=Database.find_local_intent session.database ~namespace:(Wire.namespace wire)
        ~mutation_id:(Wire.mutation_id wire) in
      let matching prepared=Database.local_intent_payload prepared=intent in
      let reject error=Wire.Rejected(fail(local_commit_error error)) in
      let prepare ()=match existing() with
        | Error _->Error Wire.Unknown
        | Ok(Some prepared) when matching prepared->Ok prepared
        | Ok(Some _)->Error(reject Overlay.Mutation_identity_conflict)
        | Ok None->
          let append_title=match request.command with
            | Protocol.V2_append_journal{journal_day;_}->
              (match Database.current_snapshot session.database with
               | Error _->Error Wire.Unknown
               | Ok snapshot->Fun.protect ~finally:(fun()->Database.release_snapshot snapshot)(fun()->
                 match Database.graph_info snapshot with
                 | Error _->Error Wire.Unknown
                 | Ok info->Ok(Some(journal_append_title info.journal_title_format journal_day))))
            | _->Ok None in
          Result.bind append_title(fun append_title->
            match local_mutation ?append_title request.command with
            | Error message->Error(Wire.Rejected(failure request Unsupported_semantics message))
            | Ok(raw,mutation)->
              match parse_preconditions raw with
              | Error message->Error(Wire.Rejected(failure request Conflict message))
              | Ok expected->
                match Database.persist_local_intent session.database ~namespace:(Wire.namespace wire)
                  ~payload:intent ~expected mutation with
                | Ok prepared->Ok prepared
                | Error(Overlay.Invalid_local_mutation _ as error)
                | Error(Overlay.Mutation_identity_conflict as error)->
                  (* Concurrent first preparations may sample different formats;
                     only the one exact stored wire wins, never a new intent. *)
                  (match existing() with
                   | Ok(Some prepared) when matching prepared->Ok prepared
                   | _->Error(reject error))
                | Error _->Error Wire.Unknown) in
      match prepare() with
      | Error outcome->outcome
      | Ok prepared->
        if t.stopped || not(current()) then Wire.Unknown else
        match Database.commit_local_intent session.database prepared with
        | Error _->
          (match Database.inspect_local_intent session.database prepared with
           | Ok(Database.Intent_rejected error)->reject error|_->Wire.Unknown)
        | Ok proof->Wire.Committed(response request(committed_outcome(Database.intent_commit_outcome proof)))
;;

let durable_mutation t ~scope ~request_id ~intent ~current =
  let module Wire=Logseq_db_worker_contract.Mutation_pure_wire in
  match reserve_writer t scope with
  |Error _->Wire.Unknown
  |Ok job->
    (* Reservation precedes any semaphore wait or fork. Once submitted, only the
       physical protected task releases it, even if its Service waiter cancels. *)
    let submitted=ref false and acquired=ref false in
    let promise,resolve=Eio.Promise.create() in
    Fun.protect
      ~finally:(fun()->if not !submitted then (
        if !acquired then Eio.Semaphore.release t.durable_slots;
        finish_writer t job))
      (fun()->
        Eio.Semaphore.acquire t.durable_slots;acquired:=true;
        Eio.Cancel.protect(fun()->
          t.dependencies.runtime.fork ~sw:t.sw(fun()->
            Fun.protect ~finally:(fun()->
              Eio.Semaphore.release t.durable_slots;finish_writer t job)
              (fun()->
                let outcome=try run_durable_mutation t ~scope ~request_id ~intent ~current with _->Wire.Unknown in
                ignore(Eio.Promise.try_resolve resolve outcome:bool)));
          submitted:=true);
        Eio.Promise.await promise)
;;

let confirm_mutation_unfenced t ~(scope : Sync.graph_scope) ~request_id ~intent ~original ~current =
  let module Wire = Logseq_db_worker_contract.Mutation_pure_wire in
  let request command =
    { Protocol.api_version = Protocol.api_version; request_id; command }
  in
  let fail message = failure (request Protocol.V2_graph_info) Conflict message in
  match
    Wire.restore
      ~origin:scope.account.managed_sync_origin
      ~user:scope.account.user_id
      ~graph:scope.graph_id
      intent
  with
  | Error message -> fail message
  | Ok wire ->
    if t.stopped || not (current ())
    then fail "The confirmation presentation retired."
    else (
      match attached_session t scope with
      | None -> fail "The scoped database is no longer attached."
      | Some session ->
        let checked =
          Result.bind
            (Database.find_local_intent
               session.database
               ~namespace:(Wire.namespace wire)
               ~mutation_id:(Wire.mutation_id wire))
            (function
              | None -> Error Overlay.Mutation_identity_conflict
              | Some prepared when Database.local_intent_payload prepared <> intent ->
                Error Overlay.Mutation_identity_conflict
              | Some prepared -> Database.inspect_local_intent session.database prepared)
        in
        (match checked with
         | Ok (Database.Intent_committed proof) ->
           let commit = Database.intent_commit_outcome proof in
           let actual =
             ( Overlay.Generation.to_string commit.generation
             , Overlay.Projection_revision.to_string commit.before_projection_revision
             , Overlay.Projection_revision.to_string commit.after_projection_revision )
           in
           if actual <> original || not (current ())
           then fail "The original commit evidence does not match."
           else (
             let command =
               match Wire.command wire with
               | Protocol.V2_append_journal{root;_}->
                 Protocol.V2_get_outline_block_summary{block=root.block_id;limit=Protocol.default_page_size;cursor=None}
               | Protocol.V2_create_journal_page { page; _ } ->
                 Protocol.V2_get_page { page; revision = None }
               | V2_insert_blocks { roots = root :: _; _ } ->
                 V2_get_outline_block_summary
                   { block = root.uuid
                   ; limit = Protocol.default_page_size
                   ; cursor = None
                   }
               | V2_save_block { block; _ }
               | V2_set_task_status { block; _ }
               | V2_clear_task_status { block; _ }
               | V2_set_asset_reference { block; _ } ->
                 V2_get_outline_block_summary
                   { block; limit = Protocol.default_page_size; cursor = None }
               | V2_delete_blocks { root; _ } ->
                 V2_get_outline_block_summary
                   { block = root; limit = Protocol.default_page_size; cursor = None }
               | _ -> assert false
             in
             let result =
               execute_database
                 ~on_enrichment_error:(fun _ -> ())
                 session
                 ~response_budget_bytes:t.dependencies.config.response_budget_bytes
                 (request command)
             in
             if current ()
             then result
             else fail "The confirmation presentation retired during readback.")
         | _ -> fail "No immutable original commit evidence is available."))
;;

let confirm_mutation t ~scope ~request_id ~intent ~original ~current =
  match reserve_writer t scope with
  |Error message->failure {Protocol.api_version=Protocol.api_version;request_id;command=Protocol.V2_graph_info} Conflict message
  |Ok job->Fun.protect ~finally:(fun()->finish_writer t job)
    (fun()->confirm_mutation_unfenced t ~scope ~request_id ~intent ~original ~current)
;;

let recover_mutations_unfenced t ~(scope:Sync.graph_scope) ~request_id ~after ~maximum_items ~maximum_bytes ~current =
  let module Wire=Logseq_db_worker_contract.Mutation_pure_wire in
  let fail error=Error(Logseq_db_worker_contract.Error.message(local_commit_error error)) in
  if maximum_items<=0 || maximum_items>256 || maximum_bytes<=0
     || maximum_bytes>Wire.maximum_recovery_bytes || Option.exists(fun after->after<=0L)after
  then Error "Invalid durable recovery budget or cursor"
  else if t.stopped || not(current()) then Error "Durable recovery authority retired"
  else match attached_session t scope with
  | None->Error "The scoped database is no longer attached."
  | Some session->
    let namespace=Wire.namespace_for_owner ~origin:scope.account.managed_sync_origin
      ~user:scope.account.user_id ~graph:scope.graph_id in
    (* Fetch one indexed row at a time: the existing cursor belongs to a full
       database page. This bounds resident payload bytes without guessing a row
       cursor or skipping a row that does not fit the caller's remaining budget. *)
    let rec loop cursor items =
      if t.stopped || not(current()) then Error "Durable recovery authority retired" else
      match Database.pending_local_intents session.database ~namespace ~after:cursor ~limit:1 with
      | Error error->fail error
      | Ok page->
        (match page.items with
         | []->Ok Wire.{items;next=None}
         | [prepared]->
           let intent=Database.local_intent_payload prepared in
           (match Wire.restore ~origin:scope.account.managed_sync_origin ~user:scope.account.user_id ~graph:scope.graph_id intent with
            | Error _->Error "Stored durable intent owner or payload is invalid"
            | Ok wire->
              (match Database.inspect_local_intent session.database prepared with
               | Error error->fail error
               | Ok resolution->
                 let outcome=match resolution with
                   | Database.Intent_pending->Wire.Unknown
                   | Intent_rejected error->Wire.Rejected(Protocol.failed ~request_id (local_commit_error error))
                   | Intent_committed proof->Wire.Committed(response
                       {Protocol.api_version=Protocol.api_version;request_id;command=Wire.command wire}
                       (committed_outcome(Database.intent_commit_outcome proof))) in
                 let candidate=Wire.{items=Rrbvec.push_back items {intent;outcome};next=page.next} in
                 if Wire.recovery_page_bytes candidate>maximum_bytes then
                   if Rrbvec.is_empty items then Error "A complete durable recovery item exceeds the byte budget"
                   else Ok Wire.{items;next=cursor}
                 else if candidate.next=None || Rrbvec.length candidate.items=maximum_items then Ok candidate
                 else loop candidate.next candidate.items))
         | _->Error "Durable recovery returned an invalid bounded page") in
    Result.bind(loop after Rrbvec.empty)(fun page->
      if not(current()) || t.stopped then Error "Durable recovery authority retired"
      else if Wire.recovery_page_bytes page>maximum_bytes then Error "Durable recovery envelope exceeds the byte budget"
      else Ok page)
;;

let recover_mutations t ~scope ~request_id ~after ~maximum_items ~maximum_bytes ~current =
  with_writer t scope(fun()->recover_mutations_unfenced t ~scope ~request_id ~after ~maximum_items ~maximum_bytes ~current)
;;

let acknowledge_mutation_unfenced t ~(scope:Sync.graph_scope) ~intent ~original ~current =
  let module Wire=Logseq_db_worker_contract.Mutation_pure_wire in
  let fail error=Error(Logseq_db_worker_contract.Error.message(local_commit_error error)) in
  match Wire.restore ~origin:scope.account.managed_sync_origin ~user:scope.account.user_id ~graph:scope.graph_id intent with
  | Error _->Error "Durable intent owner or payload is invalid"
  | Ok wire->
    if t.stopped || not(current()) then Error "Durable acknowledgement authority retired" else
    match attached_session t scope with
    | None->Error "The scoped database is no longer attached."
    | Some session->
      (match Database.find_local_intent session.database ~namespace:(Wire.namespace wire) ~mutation_id:(Wire.mutation_id wire) with
       | Error error->fail error
       | Ok None->Error "No durable intent evidence is available"
       | Ok(Some prepared) when Database.local_intent_payload prepared<>intent->Error "Durable intent identity does not match"
       | Ok(Some prepared)->
         match Database.inspect_local_intent session.database prepared with
         | Error error->fail error
         | Ok resolution->
           if not(current()) then Error "Durable acknowledgement authority retired" else
           let acknowledged=match original,resolution with
             | None,Database.Intent_rejected _->Database.acknowledge_rejected_local_intent session.database prepared
             | Some expected,Intent_committed proof->
               let commit=Database.intent_commit_outcome proof in
               let actual=Overlay.Generation.to_string commit.generation,
                 Overlay.Projection_revision.to_string commit.before_projection_revision,
                 Overlay.Projection_revision.to_string commit.after_projection_revision in
               if expected=actual then Database.acknowledge_local_intent session.database proof
               else Error Overlay.Mutation_identity_conflict
             | _->Error(Overlay.Invalid_local_mutation "Intent has no matching settled acknowledgement proof") in
           match acknowledged with
           | Error error->fail error
           | Ok() when current() && not t.stopped->Ok()
           | Ok()->Error "Durable acknowledgement completed after authority retired")
;;

let acknowledge_mutation t ~scope ~intent ~original ~current =
  with_writer t scope(fun()->acknowledge_mutation_unfenced t ~scope ~intent ~original ~current)
;;

let protected_envelope (iv, ciphertext) =
  Transit_codec.to_string (Transit.Array [ Transit.Binary iv; Transit.Binary ciphertext ])
;;

let protect_request t key request =
  match key with
  | None -> Error (effect_error "The graph key is unavailable for protected values.")
  | Some key ->
    let plaintexts = Database.protection_plaintexts request in
    let raw = List.map snd plaintexts in
    (match encrypt_protected_values t key raw with
     | Error message -> Error (effect_error message)
     | Ok encrypted ->
       let encrypted =
         List.map2
           (fun (id, _) value -> id, protected_envelope value)
           plaintexts
           encrypted
       in
       Ok (request, encrypted))
;;

let unprotect_request t key request =
  match key with
  | None -> Error (effect_error "The graph key is unavailable for protected values.")
  | Some key ->
    let rec decrypt reversed = function
      | [] -> Ok (List.rev reversed)
      | (id, ciphertext) :: rest ->
        (match decrypt_protected_value t key ciphertext with
         | Error message -> Error (effect_error message)
         | Ok plaintext -> decrypt ((id, plaintext) :: reversed) rest)
    in
    (match decrypt [] (Database.unprotection_ciphertexts request) with
     | Error _ as error -> error
     | Ok plaintexts -> Ok (request, plaintexts))
;;

let authoritative_transition_error error =
  let module Error = Logseq_db_worker_contract.Error in
  let module Diagnostic = Logseq_db_types.Authoritative_diagnostic in
  let diagnostic =
    match error with
    | Overlay.Authoritative_decode_failed source -> Diagnostic.decode source
    | Overlay.Authoritative_integrity_failure source ->
      Some (Diagnostic.integrity_of_source source)
    | _ -> None
  in
  let bounded =
    match error with
    | Overlay.Authoritative_crypto_error e ->
      Some ("cryptoInvalid", crypto_result_reason e)
    | Authoritative_commit_persistence_failed s -> Some ("persistenceFailed", s)
    | Authoritative_commit_fatal_state s -> Some ("fatalState", s)
    | _ -> None
  in
  let code, category, message =
    match error with
    | Overlay.Authoritative_database_closed ->
      ( Error.Closed_session
      , "authoritativeDatabaseClosed"
      , "Authoritative database is closed." )
    | Overlay.Authoritative_sync_token_conflict ->
      ( Error.Conflict
      , "authoritativeSyncTokenConflict"
      , "Authoritative sync version changed." )
    | Overlay.Authoritative_cursor_discontinuous ->
      ( Error.Ambiguous_sync_state
      , "authoritativeCursorDiscontinuous"
      , "Authoritative transaction cursors are not continuous." )
    | Overlay.Authoritative_checksum_mismatch ->
      ( Error.Ambiguous_sync_state
      , "authoritativeChecksumMismatch"
      , "Authoritative checksum does not match." )
    | Overlay.Authoritative_crypto_required ->
      ( Error.Invalid_request
      , "authoritativeCryptoRequired"
      , "Authoritative transition requires decrypted values." )
    | Overlay.Authoritative_crypto_unexpected ->
      ( Error.Invalid_request
      , "authoritativeCryptoUnexpected"
      , "Authoritative transition received unexpected decrypted values." )
    | Overlay.Authoritative_crypto_error _ ->
      ( Error.Unsupported_value
      , "authoritativeCryptoInvalid"
      , "Authoritative decrypted values are invalid." )
    | Overlay.Authoritative_decode_failed _ ->
      ( Error.Unsupported_semantics
      , "authoritativeDecodeFailed"
      , Option.fold
          ~none:"Authoritative transaction format is unsupported."
          ~some:Diagnostic.message
          diagnostic )
    | Overlay.Authoritative_origin_unresolved ->
      ( Error.Ambiguous_sync_state
      , "authoritativeOriginUnresolved"
      , "Authoritative transaction origin is unresolved." )
    | Overlay.Authoritative_preparation_consumed ->
      ( Error.Invalid_request
      , "authoritativePreparationConsumed"
      , "Authoritative preparation was already consumed." )
    | Overlay.Authoritative_prepare_busy ->
      Error.Storage_busy, "authoritativePrepareBusy", "Authoritative preparation is busy."
    | Overlay.Authoritative_integrity_failure _ ->
      ( Error.Ambiguous_sync_state
      , "authoritativeIntegrityFailure"
      , Option.fold
          ~none:"Authoritative integrity validation failed."
          ~some:Diagnostic.message
          diagnostic )
    | Overlay.Authoritative_commit_database_closed ->
      ( Error.Closed_session
      , "authoritativeCommitDatabaseClosed"
      , "Authoritative database closed before commit." )
    | Overlay.Authoritative_commit_token_conflict ->
      ( Error.Conflict
      , "authoritativeCommitTokenConflict"
      , "Authoritative sync version changed before commit." )
    | Overlay.Authoritative_commit_generation_invalidated ->
      ( Error.Conflict
      , "authoritativeCommitGenerationInvalidated"
      , "Authoritative database generation changed before commit." )
    | Overlay.Authoritative_commit_busy ->
      Error.Storage_busy, "authoritativeCommitBusy", "Authoritative commit is busy."
    | Overlay.Authoritative_commit_persistence_failed _ ->
      ( Error.Ambiguous_sync_state
      , "authoritativeCommitPersistenceFailed"
      , "Authoritative commit could not be persisted." )
    | Overlay.Authoritative_commit_fatal_state _ ->
      ( Error.Closed_session
      , "authoritativeCommitFatalState"
      , "Authoritative storage requires recovery." )
  in
  let bounded =
    Option.map
      (fun (reason, source) ->
         Logseq_db_types.Failure_diagnostic.of_source
           ~operation:"applyAuthoritative"
           ~reason
           source)
      bounded
  in
  let message =
    Option.fold ~none:message ~some:Logseq_db_types.Failure_diagnostic.message bounded
  in
  let origin =
    Error.create_cause
      ~component:Error.Managed_sync
      ~operation:"applyAuthoritative"
      ~code:(Some category)
      ~message
    |> Result.get_ok
  in
  let details =
    match diagnostic with
    | None -> []
    | Some detail ->
      [ Error.
          { name = Diagnostic.detail_name
          ; value = Detail_string (Diagnostic.encode detail)
          }
      ]
  in
  let details =
    details
    @ Option.fold
        ~none:[]
        ~some:(fun value ->
          let module D = Logseq_db_types.Failure_diagnostic in
          [ Error.{ name = D.detail_name; value = Detail_string (D.encode value) } ])
        bounded
  in
  Error.create_with_origin ~code ~message ~details ~origin |> Result.get_ok
;;

let deletion_authorized t (request : Sync.mirror_deletion) =
  match t.latest_snapshot with
  | Some snapshot ->
    snapshot.startup.authenticated
    && snapshot.startup.account_generation = request.account.account_generation
    && snapshot.selected_graph <> Some request.graph_id
    && snapshot.local_deletion = Some (Sync.Deletion_in_progress Sync.Deleting_mirror)
    && Authorized_graphs.mem (Graph.Uuid.to_string request.graph_id) t.authorized_graphs
  | None -> false
;;

let deletion_current t request =
  (not t.stopped) && t.deletion_owner = Some request && deletion_authorized t request
;;

let report_asset_diagnostic t ~scope ~operation ~request_operation detail =
  let module D = Logseq_db_types.Failure_diagnostic in
  let current = current_graph_scope t scope ||
    Option.fold ~none:false ~some:(fun request ->
      deletion_current t request && request.account=scope.Sync.account
      && request.graph_id=scope.graph_id) t.deletion_owner in
  match Hashtbl.find_opt t.asset_waiters request_operation with
  | Some waiter when current && waiter.request.scope=scope
      && not waiter.accepted && waiter.delivered=None && D.operation detail=operation ->
    waiter.diagnostic <- Some detail
  | Some _ | None -> ()
;;

let sync_retirement_directory path =
  let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
;;

let rec make_retirement_directory path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } -> ()
  | _ -> failwith "Local retirement path is not a physical directory"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    make_retirement_directory (Filename.dirname path);
    Unix.mkdir path 0o700; sync_retirement_directory (Filename.dirname path)
;;

let local_retirement_directory t (scope : Sync.graph_scope) =
  let identity = Digest.to_hex (Digest.string
    (Uri.to_string scope.account.managed_sync_origin ^ "\000" ^ scope.account.user_id)) in
  Filename.concat t.dependencies.config.application_support_directory
    (Filename.concat "logseq-db-worker/local-copy-retirements"
       (Filename.concat identity (Graph.Uuid.to_string scope.graph_id)))
;;

let fresh_retirement () =
  let bytes = In_channel.with_open_bin "/dev/urandom" (fun input -> really_input_string input 16) in
  let hex = String.concat "" (List.init 16 (fun n -> Printf.sprintf "%02x" (Char.code bytes.[n]))) in
  Sync.retirement_id_of_string (Printf.sprintf "%s-%s-4%s-8%s-%s"
    (String.sub hex 0 8) (String.sub hex 8 4) (String.sub hex 13 3)
    (String.sub hex 17 3) (String.sub hex 20 12)) |> Result.get_ok
;;

let write_local_retirement path expected captured =
  let json = `Assoc ["version",`Int 1
    ; "expected", `String (Overlay.Mirror_generation.to_string expected)
    ; "uploads", Logseq_db_storage.Asset_upload_store.captured_graph_to_yojson captured] |> Yojson.Safe.to_string in
  let temporary = path ^ ".part" in
  let fd = Unix.openfile temporary [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_TRUNC] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
       let rec write offset =
         if offset < String.length json
         then (
      let n = Unix.write_substring fd json offset (String.length json-offset) in
           if n = 0
           then failwith "retirement journal write stalled"
           else write (offset + n))
       in
    write 0; Unix.fsync fd);
  Unix.rename temporary path; sync_retirement_directory (Filename.dirname path)
;;

let remove_local_retirement path =
  Unix.unlink path; sync_retirement_directory (Filename.dirname path)
;;

let mirror_deletion_detail = function
  | Overlay.Mirror_delete_busy -> failure_detail ~operation:"deleteMirror" ~reason:"busy" ()
  | Mirror_delete_stale -> failure_detail ~operation:"deleteMirror" ~reason:"attachmentStale" ()
  | Mirror_delete_failed source -> failure_detail ~source ~operation:"deleteMirror" ~reason:"deleteFailed" ()
;;

let finish_local_retirement ?(on_diagnostic = fun _ -> ()) t scope deletion captured ~commit =
  let ( let* ) = Result.bind in
  let* () = if commit then
    with_upload_store t (fun db -> Logseq_db_storage.Asset_upload_store.delete_captured_graph db captured)
    |> Result.map_error (fun source ->
      on_diagnostic (failure_detail ~source ~operation:"deleteMirror" ~reason:"persistenceFailed" ()); source)
    else Ok () in
  asset_unit ~on_failure:(fun failure ->
    if failure <> Sync.Asset_cancelled then on_diagnostic (asset_failure_detail ~operation:"deleteMirror" failure))
    ~on_diagnostic:(fun detail ->
      let module D = Logseq_db_types.Failure_diagnostic in
      on_diagnostic (D.of_source ~operation:"deleteMirror" ~reason:"cleanupFailed" (D.encode detail))) t ~scope
    (if commit then Sync.Commit_graph_asset_deletion deletion else Sync.Cancel_graph_asset_deletion deletion)
;;

let recover_local_retirements ?on_diagnostic t (scope : Sync.graph_scope) =
  let report = Option.value on_diagnostic ~default:(fun detail ->
    publish_failure (report_current_graph t scope) detail) in
  let ( let* ) = Result.bind in
  let directory = local_retirement_directory t scope in
  if not (Sys.file_exists directory) then Ok () else
  Array.fold_left (fun result name ->
    let* () = result in
         if not (Filename.check_suffix name ".json")
         then Ok ()
         else (
    try
      let journal_path = Filename.concat directory name in
      let retirement = String.sub name 0 (String.length name - 5) |> Sync.retirement_id_of_string |> Result.get_ok in
      let open Yojson.Safe.Util in
      let json = Yojson.Safe.from_file journal_path in
      if json |> member "version" |> to_int <> 1 then failwith "Unsupported retirement journal";
      let expected = json |> member "expected" |> to_string |> Overlay.Mirror_generation.of_string |> Result.get_ok in
      let captured = json |> member "uploads" |> Logseq_db_storage.Asset_upload_store.captured_graph_of_yojson |> Result.get_ok in
      if not (Logseq_db_storage.Asset_upload_store.captured_graph_matches captured
        ~origin:(Uri.to_string scope.account.managed_sync_origin) ~account:scope.account.user_id ~graph:scope.graph_id)
      then failwith "Retirement journal account mismatch";
      let* prepared, generation = Database.prepare_mirror_deletion
        ~application_support_directory:t.dependencies.config.application_support_directory
        ~graph_id:scope.graph_id ~retirement
               |> Result.map_error (fun error ->
                 report (mirror_deletion_detail error);
                 "Retirement recovery is blocked by mirror ownership or an unknown \
                  commit state.")
             in
      Fun.protect ~finally:(fun () -> Database.cancel_mirror_deletion prepared) (fun () ->
        let committed = Database.mirror_deletion_committed prepared in
        let original = Overlay.Mirror_generation.equal generation expected in
                  if (not committed) && not original
                  then (
                    report (failure_detail ~operation:"deleteMirror" ~reason:"ownershipConflict" ());
                    Error
                      "Retirement recovery conflict; the captured resources were \
                       preserved.")
                  else (
          let deletion = Sync.asset_deletion_reference ~scope ~retirement in
                    let* () =
                      finish_local_retirement ~on_diagnostic:report t scope deletion captured ~commit:committed
                    in
                    if committed
                    then (
                      try remove_local_retirement journal_path with
                      | error ->
                        report (exception_failure ~operation:"deleteMirror" ~reason:"cleanupFailed" error);
                        report_warning "journal: phase=retirement operation=removeCoordinatorJournal code=cleanupPending\n")
                    else remove_local_retirement journal_path;
                    Ok ()))
           with
           | error ->
             report (exception_failure ~operation:"deleteMirror" ~reason:"restoreFailed" error);
             Error "Local copy recovery is incomplete; its resources were preserved."))
      (Ok ())
      (try Sys.readdir directory with error ->
        report (exception_failure ~operation:"deleteMirror" ~reason:"restoreFailed" error);
        raise error)
;;

let handle_sync_worker_effect t = function
  | Sync.Inspect_mirror request ->
    let recovery = with_staging_lock t (fun () -> recover_local_retirements t request.scope) in
    (match recovery with
     | Error message -> Error (effect_error message)
     | Ok () ->
       (match
       Database.inspect_mirror
         ~application_support_directory:
           t.dependencies.config.application_support_directory
         ~graph_id:request.graph.graph_id
     with
     | Error error -> Error (mirror_error error)
     | Ok inspection ->
       Hashtbl.replace
         t.inspections
         (Graph.Uuid.to_string request.graph.graph_id)
         inspection;
       (match Database.mirror_presence inspection with
        | Overlay.Absent _ ->
          Ok (sync_result ~event:(Sync.Mirror_inspected (Mirror_absent request.scope)) ())
        | Available _ ->
             Ok (sync_result ~event:(Sync.Mirror_inspected (Mirror_available request)) ()))))
  | Activate_snapshot request ->
    let key = Graph.Uuid.to_string (Sync.snapshot_activation_scope request).graph_id in
    (match Hashtbl.find_opt t.inspections key with
     | None -> Error (effect_error "The snapshot mirror inspection is stale.")
     | Some inspection ->
       let cursor = (Sync.snapshot_activation_cursor request) in
       (match
          Database.prepare_snapshot_activation
            t.dependencies.overlay
            inspection
            ~path:(Sync.staged_artifact_path (Sync.snapshot_activation_artifact request))
            ~applied_server_cursor:cursor
            ~expected_checksum:None
            ~expected_rows:(Sync.staged_artifact_expected_rows (Sync.snapshot_activation_artifact request))
        with
        | Error error -> Error (snapshot_activation_error error)
        | Ok prepared ->
          Fun.protect
            ~finally:(fun () -> Database.cancel_snapshot_activation prepared)
            (fun () ->
               let rec supply () =
                 match Database.next_snapshot_unprotection_batch prepared with
                 | Error error -> Error (snapshot_activation_error error)
                 | Ok None -> Ok ()
                 | Ok (Some crypto_request) ->
                   let ciphertexts = Database.unprotection_ciphertexts crypto_request in
                   let plaintexts =
                     match (Sync.snapshot_activation_key request) with
                     | None -> Ok ciphertexts
                     | Some graph_key ->
                       let rec decrypt reversed = function
                         | [] -> Ok (List.rev reversed)
                         | (id, ciphertext) :: rest ->
                           (match decrypt_protected_value t graph_key ciphertext with
                            | Error message -> Error message
                            | Ok plaintext -> decrypt ((id, plaintext) :: reversed) rest)
                       in
                       decrypt [] ciphertexts
                   in
                   (match plaintexts with
                    | Error message -> Error (effect_error message)
                    | Ok plaintexts ->
                      (match
                         Database.supply_snapshot_unprotection_batch
                           prepared
                           ~request:crypto_request
                           ~plaintexts
                       with
                       | Error error -> Error (snapshot_activation_error error)
                       | Ok () -> supply ()))
               in
               match supply () with
               | Error error -> Error error
               | Ok () ->
                 (match Database.commit_snapshot_activation prepared with
                  | Error error -> Error (snapshot_activation_error error)
                  | Ok inspection ->
                    Hashtbl.replace t.inspections key inspection;
                    Ok
                      (sync_result
                         ~event:(Sync.Snapshot_activated (Sync.snapshot_activation_completed request))
                         ())))))
  | Delete_mirror request ->
    let ( let* ) = Result.bind in
    let current () = deletion_current t request in
    let report detail =
      if current () then publish_failure
        (fun signal -> t.dependencies.publish (Core.Diagnostic signal)) detail in
    let scope : Sync.graph_scope = {account=request.account;graph_id=request.graph_id;graph_generation=0} in
    let result = try
      let* () = if current () then Ok () else Error "The graph account is no longer current." in
      let* () = match Hashtbl.fold (fun (actual:Sync.graph_scope) _ found -> found || actual.graph_id=request.graph_id) t.attachments false with
        | true ->
          report (failure_detail ~operation:"deleteMirror" ~reason:"busy" ());
          Error "Switch to another graph before deleting."
        | false -> Ok () in
      let* () = with_staging_lock t (fun () -> recover_local_retirements ~on_diagnostic:report t scope) in
      let retirement = fresh_retirement () in
      (* Ownership is acquired before any asset retirement or intent mutation. *)
      let* prepared, expected = Database.prepare_mirror_deletion
        ~application_support_directory:t.dependencies.config.application_support_directory
        ~graph_id:request.graph_id ~retirement
        |> Result.map_error (fun error ->
          report (mirror_deletion_detail error);
          match error with
          | Overlay.Mirror_delete_busy -> "The local copy is still in use. Close attachment previews and try again."
          | _ -> "The local copy changed. Refresh and try again.") in
      Fun.protect ~finally:(fun () -> Database.cancel_mirror_deletion prepared) (fun () ->
        let same_target (actual : Sync.graph_scope) = actual.graph_id=scope.graph_id
          && actual.account.user_id=scope.account.user_id
          && Uri.equal actual.account.managed_sync_origin scope.account.managed_sync_origin in
        Hashtbl.iter (fun (ticket : Upload.ticket) resolve ->
          if same_target ticket.scope then ignore (Eio.Promise.try_resolve resolve () : bool)) t.upload_operations;
        let rec drain attempts =
          if not (current ()) then Error "The graph account is no longer current."
          else if not (Hashtbl.fold (fun (ticket : Upload.ticket) _ busy -> busy || same_target ticket.scope) t.upload_operations false)
          then Ok ()
          else if attempts=0 then (
            report (failure_detail ~operation:"deleteMirror" ~reason:"busy" ());
            Error "The local copy is still in use. Try again.")
          else (t.dependencies.runtime.sleep 0.005; drain (attempts-1)) in
        let* () = drain 1000 in
        with_staging_lock t (fun () ->
          let* () = if current () then Ok () else Error "The graph account is no longer current." in
          let* captured = with_upload_store t (fun db -> Logseq_db_storage.Asset_upload_store.capture_graph db
            ~origin:(Uri.to_string request.account.managed_sync_origin) ~account:request.account.user_id ~graph:request.graph_id)
            |> Result.map_error (fun source ->
              report (failure_detail ~source ~operation:"deleteMirror" ~reason:"persistenceFailed" ()); source) in
          let directory = local_retirement_directory t scope in
          make_retirement_directory directory;
          let path = Filename.concat directory (Sync.retirement_id_to_string retirement ^ ".json") in
          write_local_retirement path expected captured;
          let deletion = Sync.asset_deletion_reference ~scope ~retirement in
          let committed = ref false in
          let abort () =
                 if not !committed
                 then (
              match finish_local_retirement ~on_diagnostic:report t scope deletion captured ~commit:false with
              | Ok () -> remove_local_retirement path
                   | Error _ -> report_warning "journal: phase=retirement operation=abortLocalRetirement code=cleanupPending\n")
               in
          Fun.protect ~finally:abort (fun () ->
            let* () = match asset_call t ~scope (Sync.Prepare_graph_asset_deletion retirement) with
              | Ok (Sync.Asset_deletion_prepared actual) when actual=deletion -> Ok ()
              | Error error ->
                if error <> Sync.Asset_cancelled then report (asset_failure_detail ~operation:"deleteMirror" error);
                Error (asset_failure_message error)
              | _ ->
                report (failure_detail ~source:"Unexpected attachment retirement response." ~operation:"deleteMirror" ~reason:"invalidContent" ());
                Error "Unexpected attachment retirement response." in
            let* () = if current () then Ok () else Error "The graph account is no longer current." in
            let* _ = Database.commit_mirror_deletion prepared
              |> Result.map_error (fun error ->
                report (mirror_deletion_detail error);
                "Local deletion did not commit; its resources were preserved.") in
            committed := true;
            let report_code code =
              if not t.stopped && current () then t.dependencies.publish (Core.Diagnostic code) in
            if not (Database.mirror_deletion_committed prepared)
            then report_code "worker.confirmMirrorRetirement";
            (* The mirror receipt is the durable commit authority. Cleanup failure
               retains this coordinator journal for exact replay, not a broad sweep. *)
            (try
                    if Database.mirror_deletion_committed prepared
                    then (
                 match finish_local_retirement ~on_diagnostic:report t scope deletion captured ~commit:true with
                 | Ok () -> remove_local_retirement path
                      | Error _ -> report_code "worker.finishLocalRetirement")
                  with
                  | error ->
                    let detail = exception_failure ~operation:"deleteMirror" ~reason:"cleanupFailed" error in
                    if current () then publish_failure
                      (fun signal -> t.dependencies.publish (Core.Diagnostic signal)) detail;
                    report_code "worker.finishLocalRetirement");
            Hashtbl.remove t.inspections (Graph.Uuid.to_string request.graph_id);
            Ok ())))
      with
      | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
      | error ->
        report (exception_failure ~operation:"deleteMirror" ~reason:"deleteFailed" error);
        Error "The local copy could not be deleted. Check available storage and try again."
    in
    Ok (sync_result ~event:(Sync.Mirror_deleted (request, result)) ())
  | Attach_graph request ->
    (match t.latest_snapshot with
     | Some snapshot when snapshot.resident_graphs<>[] -> ()
     | _ -> ignore (close_attached t));
    let key = Graph.Uuid.to_string request.graph.graph_id in
    (match Hashtbl.find_opt t.inspections key with
     | None -> Error (effect_error "The graph attachment inspection is stale.")
     | Some inspection ->
       (match
          Database.open_ ~sw:t.sw t.dependencies.overlay inspection ~graph_name:request.graph.name
        with
        | Error error -> Error (open_error error)
        | Ok database ->
          (match Database.listen database with
           | Error error ->
             ignore (Database.close database);
             Error (listen_error error)
           | Ok (subscription, predecessor) ->
             let version = Database.snapshot_version predecessor in
             Database.release_snapshot predecessor;
             let database_id = "managed-" ^ Int64.to_string t.next_database_id in
             t.next_database_id <- Int64.succ t.next_database_id;
             let session =
               { graph_scope = request.scope
               ; database
               ; subscription
               ; generation = Overlay.Generation.to_string version.generation
               ; next_window = 1
               ; acknowledged_through = "change-window:v1:0"
               ; windows = Rrbvec.empty
               ; changefeed=Core.Changefeed_owner.empty
               }
             in
             Hashtbl.replace t.databases database_id session;
             Hashtbl.replace t.attachments request.scope database_id;
             t.attached <- Some (database_id, request.scope);
             (match
                Database.activate_subscription subscription ~notify:(fun change ->
                  publish_projection_change t session change)
              with
              | Error error ->
                ignore (close_database_by_id t database_id);
                Error (listen_error error)
              | Ok () ->
                let sync = Database.inspect_sync database in
                let opened =
                  Core.database_opened ~database_id ~graph_id:request.graph.graph_id
                in
                (match sync with
                 | Error error ->
                   ignore (close_database_by_id t database_id);
                   Error (sync_read_error error)
                 | Ok sync ->
                   Ok
                     (sync_result
                        ~event:(Sync.Graph_attached { scope = request.scope; sync })
                        ~lifecycle:
                          (Core.Lifecycle_opened (opened, request.scope.graph_generation))
                        ()))))))
  | Detach_graph scope ->
    let closed =
      match Hashtbl.find_opt t.attachments scope with
      | Some database_id -> close_database_by_id ~scope t database_id
      | None -> Ok ()
    in
    Result.map
      (fun () ->
         sync_result
           ~event:(Sync.Graph_detached (scope, Ok ()))
           ~lifecycle:(Core.Lifecycle_closed scope.graph_generation)
           ())
      closed
  | Reset_managed_account account ->
    let owned=Hashtbl.fold (fun (scope:Sync.graph_scope) id result ->
      if scope.account.user_id=account.user_id && scope.account.managed_sync_origin=account.managed_sync_origin
         && scope.account.account_generation=account.account_generation then (scope,id)::result else result) t.attachments [] in
    List.iter (fun (scope,id)->ignore(close_database_by_id ~scope t id)) owned;
    Ok (sync_result ())
  | Inspect_sync scope ->
    (match attached_session t scope with
     | None -> Error (effect_error "The overlay database is unavailable.")
     | Some session ->
       (match Database.inspect_sync session.database with
        | Error error -> Error (sync_read_error error)
        | Ok sync -> Ok (sync_result ~event:(Sync.Sync_inspected { scope; sync }) ())))
  | Apply_outbox_transition request ->
    (match attached_session t request.scope with
     | None -> Error (effect_error "The overlay database is unavailable.")
     | Some session ->
       (match
          Database.begin_outbox_transition
            session.database
            ~expected:request.expected
            request.transition
        with
        | Error error -> Error (outbox_transition_error error)
        | Ok (prepared, crypto) ->
          let encrypted =
            match crypto with
            | None -> Ok None
            | Some crypto -> Result.map Option.some (protect_request t request.key crypto)
          in
          (match encrypted with
           | Error error -> Error error
           | Ok encrypted ->
             (match
                Database.apply_outbox_transition session.database prepared ~encrypted
              with
              | Error error -> Error (outbox_transition_error error)
              | Ok commit ->
                (match Database.inspect_sync session.database with
                 | Error error -> Error (sync_read_error error)
                 | Ok sync ->
                   Ok
                     (sync_result
                        ~event:
                          (Sync.Outbox_transition_applied
                             { scope = request.scope; commit; sync })
                        ()))))))
  | Apply_authoritative_batch request ->
    (match attached_session t request.scope.graph with
     | None -> Error (effect_error "The overlay database is unavailable.")
     | Some session ->
       (match Database.inspect_sync session.database with
        | Error error -> Error (sync_read_error error)
        | Ok sync ->
          (match
             Database.begin_authoritative
               session.database
               ~expected:(Overlay.sync_view_token sync)
               request.input
           with
           | Error error -> Error (authoritative_transition_error error)
           | Ok (prepared, crypto) ->
             let decrypted =
               match crypto with
               | None -> Ok None
               | Some crypto ->
                 Result.map Option.some (unprotect_request t request.key crypto)
             in
             (match decrypted with
              | Error error -> Error error
              | Ok decrypted ->
                (match
                   Database.apply_authoritative session.database prepared ~decrypted
                 with
                 | Error error ->
                   Error (authoritative_transition_error error)
                 | Ok (Database.Authoritative_deferred defer) ->
                   Ok
                     (sync_result
                        ~event:
                          (Sync.Authoritative_batch_deferred
                             { scope = request.scope.graph; defer })
                        ())
                 | Ok (Authoritative_applied commit) ->
                   (match Database.inspect_sync session.database with
                    | Error _ ->
                      Error (effect_error "The overlay Sync view is unavailable.")
                    | Ok sync ->
                      Ok
                        (sync_result
                           ~event:
                             (Sync.Authoritative_batch_applied
                                { scope = request.scope.graph; commit; sync })
                           ())))))))
;;

let run_request t (type a) (request : a Core.runner_request)
  : (a, Core.effect_error) result
  =
  match request with
  | Core.Execute_request { database; request; response_budget_bytes } ->
    (match Hashtbl.find_opt t.databases (Core.database_handle_id database) with
     | None -> Error (effect_error "The overlay database is unavailable.")
     | Some session ->
       Ok
         (execute_database
            ~on_enrichment_error:(fun () ->
              report_current_graph t session.graph_scope "worker.readTagTitles")
            session
            ~response_budget_bytes:(Option.fold ~none:t.dependencies.config.response_budget_bytes
              ~some:(min t.dependencies.config.response_budget_bytes) response_budget_bytes)
            request))
  | Close_database database -> close_database_by_id t (Core.database_handle_id database)
  | Handle_sync_worker_effect worker_effect -> handle_sync_worker_effect t worker_effect
;;

let complete t ?writer (Core.Request (ticket, request)) =
  Fun.protect ~finally:(fun()->Option.iter(finish_writer t)writer)(fun()->
    match request with
    |Core.Execute_request _->let result=run_request t request in
      t.post(Core.Runner_completed(Core.Execute_request_completed(ticket,result)))
    |Close_database _->let result=run_request t request in
      t.post(Core.Runner_completed(Core.Close_database_completed(ticket,result)))
    |Handle_sync_worker_effect _->let result=run_request t request in
      t.post(Core.Runner_completed(Core.Sync_worker_effect_completed(ticket,result))))
;;
let worker_operation_scope t (Core.Request(_,request)) =
  match request with
  |Core.Execute_request{database;_}->Option.map(fun session->session.graph_scope)
      (Hashtbl.find_opt t.databases(Core.database_handle_id database))
  |Close_database _->None
  |Handle_sync_worker_effect worker_effect->
    (match worker_effect with
     |Sync.Inspect_mirror request|Attach_graph request->Some request.scope
     |Activate_snapshot request->Some(Sync.snapshot_activation_scope request)
     |Inspect_sync scope->Some scope
     |Apply_outbox_transition request->Some request.scope
     |Apply_authoritative_batch request->Some request.scope.graph
     |Detach_graph _|Reset_managed_account _|Delete_mirror _->None)
;;
let submit_worker t (Core.Request(ticket,request) as packed) =
  let fork ?writer ()=
    try t.dependencies.runtime.fork ~sw:t.sw(fun()->complete t ?writer packed)
    with error->Option.iter(finish_writer t)writer;raise error in
  match worker_operation_scope t packed with
  |None->fork()
  |Some scope->match reserve_writer t scope with
    |Ok writer->fork ~writer ()
    |Error message->let error=effect_error message in
      let result=match request with
        |Core.Execute_request _->Core.Execute_request_completed(ticket,Error error)
        |Close_database _->Core.Close_database_completed(ticket,Error error)
        |Handle_sync_worker_effect _->Core.Sync_worker_effect_completed(ticket,Error error) in
      t.post(Core.Runner_completed result)
;;

let run_upload t (context : Sync.asset_context) instruction =
  let current ticket = (not t.stopped) && t.upload_current ticket
    && not(Core.Writer_fence.fenced t.writer_fence context.scope) in
  let on_diagnostic ticket detail =
    if current ticket then queue_notice_diagnostic t context.scope
      (Upload_notice ticket.Upload.operation) ticket.id detail in
  let database ticket f =
    if not (current ticket)
    then Error Upload.Invalid_content
    else (
      match attached_session t ticket.Upload.scope with
      | None ->
        on_diagnostic ticket (failure_detail ~operation:"assetUpload" ~reason:"databaseClosed" ());
        Error Upload.Invalid_content
      | Some session -> f session.database)
  in
  let finish ticket result success =
    if current ticket
    then (
      if Result.is_ok result then clear_notice_diagnostic t context.scope (Upload_notice ticket.Upload.operation);
      t.post
        (Core.Upload_completed
           ( ticket
           , match result with
             | Ok () -> success
             | Error error -> Upload.Failed error )))
  in
  let changed () = t.post (Core.Sync_event Sync.Local_outbox_changed) in
  match instruction with
  | Upload.Cancel_operation ticket -> clear_notice_diagnostic ~ticket_id:ticket.id t context.scope (Upload_notice ticket.operation)
  | Release_staging intent ->
    let detail = ref None in
    let on_failure failure = detail := Some (asset_failure_detail ~operation:"assetRelease" failure) in
    let on_diagnostic value = detail := Some value in
    (match
       let can_release =
         if intent.Logseq_db_types.Asset_upload_intent.phase = Cancelled
         then Ok ()
         else (
           match
             asset_call
               t
               ~scope:context.scope
               (Sync.Check_asset_cache (intent.asset, intent.version))
           with
           | Ok (Sync.Asset_cached (Some handle)) ->
             asset_unit ~on_failure ~on_diagnostic t ~scope:context.scope (Sync.Release_asset_file handle)
           | _ ->
             asset_unit ~on_failure ~on_diagnostic
               t
               ~scope:context.scope
               (Sync.Publish_staged_asset
                  { asset = intent.asset
                  ; version = intent.version
                  ; file = intent.staged_file
                  }))
       in
       Result.bind can_release (fun () ->
         asset_unit ~on_failure ~on_diagnostic t ~scope:context.scope (Sync.Release_staged_file intent.staged_file))
     with
     | Ok () -> ()
     | Error source ->
       let detail = Option.value !detail ~default:(failure_detail ~source ~operation:"assetRelease" ~reason:"cleanupFailed" ()) in
       if Logseq_db_types.Failure_diagnostic.reason detail <> "cancelled" then
         publish_failure (report_current_graph t context.scope) detail;
       report_warning "journal: operation=releaseUploadStaging code=cleanupPending\n" )
  | Persist (ticket, intent, expected) ->
    if current ticket then finish ticket (save_upload t intent expected) Upload.Persisted
  | Inspect (ticket, intent) ->
    if current ticket
    then (
      let result = database ticket (fun db -> Upload_database.inspect ~on_diagnostic:(on_diagnostic ticket) db intent) in
      if current ticket
      then
        t.post
          (Core.Upload_completed
             ( ticket
             , match result with
               | Ok observation -> Upload.Inspected observation
               | Error error -> Upload.Failed error )))
  | Apply_local (ticket, intent) ->
    if current ticket
    then (
      let result = database ticket (fun db -> Upload_database.apply_local ~on_diagnostic:(on_diagnostic ticket) db intent) in
      (match result with
       | Ok () -> changed ()
       | Error _ -> ());
      finish ticket result Upload.Local_applied)
  | Apply_metadata (ticket, intent) ->
    if current ticket
    then (
      let result = database ticket (fun db -> Upload_database.apply_metadata ~on_diagnostic:(on_diagnostic ticket) db intent) in
      (match result with
       | Ok () -> changed ()
       | Error _ -> ());
      finish ticket result Upload.Metadata_applied)
  | Put (ticket, intent) ->
    if current ticket
    then (
      let detail = ref None in
      finish
        ticket
        (match
           asset_call
             ~on_diagnostic:(fun value -> detail := Some value)
             t
             ~scope:context.scope
             (Sync.Put_asset_file
                { asset = intent.asset
                ; version = intent.version
                ; file = intent.staged_file
                ; maximum_plaintext_bytes = 8 * 1024 * 1024
                })
         with
         | Ok Sync.Asset_unit -> Ok ()
         | Ok _ ->
           on_diagnostic ticket (failure_detail ~operation:"assetUpload" ~reason:"invalidContent" ());
           Error Upload.Invalid_content
         | Error failure ->
           if current ticket && failure <> Sync.Asset_cancelled then
             on_diagnostic ticket (Option.value !detail
               ~default:(asset_failure_detail ~operation:"assetUpload" failure));
           Error
             (match failure with
              | Sync.Asset_network -> Upload.Network
              | Asset_authentication | Asset_locked -> Authentication
              | Asset_missing_source | Asset_not_found -> Missing_source
              | Asset_size_rejected -> Size_rejected
              | Asset_revoked_access -> Revoked_access
              | Asset_checksum_mismatch
              | Asset_storage_full
              | Asset_cancelled
              | Asset_invalid_content _ -> Invalid_content))
        Upload.Put_succeeded)
  | Await_publication (ticket, intent) ->
    let rec await () =
      if current ticket
      then (
        match database ticket (fun db -> Upload_database.inspect ~on_diagnostic:(on_diagnostic ticket) db intent) with
        | Ok Upload.Publication_acknowledged ->
          finish ticket (Ok ()) Upload.Publication_acked
        | Ok (Local_present | Metadata_present) ->
          t.dependencies.runtime.sleep 0.5;
          await ()
        | Ok (Absent | Entity_cancelled) ->
          on_diagnostic ticket (failure_detail ~operation:"assetUpload" ~reason:"missingPrecondition" ());
          finish ticket (Error Upload.Invalid_content) Upload.Publication_acked
        | Error error -> finish ticket (Error error) Upload.Publication_acked)
    in
    await ()
;;

let submit_upload t (context : Sync.asset_context) instruction =
  match instruction with
  | Upload.Cancel_operation ticket ->
    clear_notice_diagnostic ~ticket_id:ticket.id t context.scope (Upload_notice ticket.operation);
    Option.iter
      (fun resolver -> ignore (Eio.Promise.try_resolve resolver () : bool))
      (Hashtbl.find_opt t.upload_operations ticket)
  | Release_staging _ ->
    t.dependencies.runtime.fork ~sw:t.sw (fun () -> run_upload t context instruction)
  | Persist (ticket, _, _)
  | Inspect (ticket, _)
  | Apply_local (ticket, _)
  | Put (ticket, _)
  | Apply_metadata (ticket, _)
  | Await_publication (ticket, _) ->
    if t.upload_current ticket && not (Hashtbl.mem t.upload_operations ticket)
    then (
      match reserve_writer t context.scope with
      |Error _->t.post(Core.Upload_completed(ticket,Upload.Failed Upload.Invalid_content))
      |Ok job->
        clear_notice_diagnostic t context.scope (Upload_notice ticket.operation);
        let cancelled, resolve = Eio.Promise.create () in
        Hashtbl.add t.upload_operations ticket resolve;
        (try t.dependencies.runtime.fork ~sw:t.sw (fun () ->
          Fun.protect
            ~finally:(fun () -> Hashtbl.remove t.upload_operations ticket;finish_writer t job)
            (fun () -> Eio.Fiber.first
               (fun () -> run_upload t context instruction)
               (fun () -> Eio.Promise.await cancelled)))
         with error->Hashtbl.remove t.upload_operations ticket;finish_writer t job;raise error))
;;

let transfer_failure = function
  | Sync.Asset_network -> Logseq_sync_pure_reducer.Asset_transfer.Network
  | Asset_not_found | Asset_missing_source -> Not_found
  | Asset_checksum_mismatch -> Checksum_mismatch
  | Asset_authentication | Asset_revoked_access -> Authentication
  | Asset_locked -> Locked
  | Asset_storage_full -> Storage_full
  | Asset_size_rejected -> Invalid_content "Asset size exceeds the limit"
  | Asset_cancelled -> Invalid_content "Asset operation was cancelled"
  | Asset_invalid_content message -> Invalid_content message
;;

let local_import t ~(scope : Sync.graph_scope) ~asset ~checksum ~current =
  with_staging_lock t (fun () ->
    let ( let* ) = Result.bind in
    let* () = reconcile_staging t scope ~current in
    match Hashtbl.find_opt t.local_imports (scope, asset, checksum) with
    | None -> Ok None
    | Some operation ->
      let* intent =
        with_upload_store t (fun db ->
          Logseq_db_storage.Asset_upload_store.read db ~operation)
      in
      Ok
        (Option.bind intent (fun (i : Logseq_db_types.Asset_upload_intent.t) ->
           if
             current ()
             && (not t.stopped)
             && i.origin = Uri.to_string scope.account.managed_sync_origin
             && i.account = scope.account.user_id
             && i.graph = scope.graph_id
             && i.asset = asset
             && i.version.checksum = checksum
             && i.phase <> Logseq_db_types.Asset_upload_intent.Cancelled
           then Some i
           else None)))
;;

let lookup_local_asset t ~scope ~asset ~checksum ~current ~diagnostic call =
  match local_import t ~scope ~asset ~checksum ~current with
  | Error source ->
    if current () then report_source_failure t scope "assetMetadata" "persistenceFailed" source;
    Error Sync.Asset_cancelled
  | Ok None -> Ok (Sync.Asset_cached None)
  | Ok (Some intent) ->
    (match call (Sync.Check_asset_cache (asset, intent.version)) with
     | Ok (Sync.Asset_cached (Some _) as value) -> Ok value
     | Error _ as error -> error
     | Ok _ ->
       (match call (Sync.Retain_staged_file intent.staged_file) with
        | Ok (Sync.Asset_retained (Some (lease, _))) ->
          let published =
            call
              (Sync.Publish_staged_asset
                 { asset; version = intent.version; file = intent.staged_file })
          in
          let published_diagnostic = !diagnostic in
          (match published with
           | Error Sync.Asset_storage_full -> Ok (Sync.Asset_cached (Some lease))
           | _ ->
             (match call (Sync.Release_asset_file lease) with
              | Error failure when current () -> report_asset_failure t scope "assetRelease" failure
              | Ok _ | Error _ -> ());
             diagnostic := published_diagnostic;
             (match published with
              | Ok Sync.Asset_unit ->
                call (Sync.Check_asset_cache (asset, intent.version))
              | Error (Sync.Asset_missing_source | Asset_checksum_mismatch) ->
                Ok (Sync.Asset_cached None)
              | Error _ as error -> error
              | Ok _ ->
                Error (Sync.Asset_invalid_content "Unexpected publication completion")))
        | Ok _ -> Ok (Sync.Asset_cached None)
        | Error _ as error -> error))
;;

let release_asset_file_result t ~scope ~handle ~report_failure =
  if t.stopped then Error "The Worker stopped before resource release." else
  let detail=ref None in
  match asset_call ~on_diagnostic:(fun value->detail:=Some value) t ~scope (Sync.Release_asset_file handle) with
  | Ok Sync.Asset_unit -> Ok()
  | Error failure ->
    if report_failure then report_asset_failure ?detail:!detail t scope "assetRelease" failure;
    Error(asset_failure_message failure)
  | Ok _ ->
    if report_failure then report_source_failure t scope "assetRelease" "invalidContent" "Unexpected asset completion";
    Error "Unexpected asset release completion"
;;
let release_asset_file_checked t ~scope ~handle=release_asset_file_result t ~scope ~handle ~report_failure:true

let unsettled_orphan_retains t=Core.Orphan_cleanup.count t.orphan_cleanup

let release_orphan_work t work =
  let resource=Core.Orphan_cleanup.resource work in
  let result=try Eio.Cancel.protect(fun()->
    release_asset_file_result t ~scope:resource.scope ~handle:resource.handle
      ~report_failure:(Core.Orphan_cleanup.first_attempt work))
    with _->Error "Attachment cleanup was interrupted." in
  t.orphan_cleanup<-Core.Orphan_cleanup.completed t.orphan_cleanup work result;
  if result=Ok() then Hashtbl.remove t.resource_cleanup_owners(resource.scope,resource.handle)
;;

let abandon_asset_file_internal ?cleanup_job t ~scope ~handle =
  Option.iter(fun job->Hashtbl.replace t.resource_cleanup_owners(scope,handle)job)cleanup_job;
  t.orphan_cleanup<-Core.Orphan_cleanup.track t.orphan_cleanup {scope;handle};
  if not t.orphan_cleanup_running && not t.stopped then (
    t.orphan_cleanup_running<-true;
    let next,work=Core.Orphan_cleanup.next t.orphan_cleanup in
    t.orphan_cleanup<-next;
    Option.iter(release_orphan_work t)work;
    if unsettled_orphan_retains t=0 then t.orphan_cleanup_running<-false else
      t.dependencies.runtime.fork ~sw:t.sw (fun()->
        Fun.protect ~finally:(fun()->t.orphan_cleanup_running<-false)(fun()->
          let rec retry ()=
            if not t.stopped then (
              let next,work=Core.Orphan_cleanup.next t.orphan_cleanup in
              t.orphan_cleanup<-next;
              match work with None->()|Some work->
                t.dependencies.runtime.sleep(Core.Orphan_cleanup.retry_delay work);
                if not t.stopped then (release_orphan_work t work;retry())) in
          retry())))
;;


let abandon_asset_file t ~scope ~handle=abandon_asset_file_internal t ~scope ~handle

let asset_cleanup_snapshot t ~scope =
  let jobs=Hashtbl.fold(fun _ job values->
    if job.cleanup_scope=scope then Rrbvec.push_back values job else values)
    t.asset_cleanup_jobs Rrbvec.empty in
  let jobs=Hashtbl.fold(fun(resource_scope,_) job values->
    if resource_scope=scope then Rrbvec.push_back values job else values)
    t.resource_cleanup_owners jobs in
  {snapshot_scope=scope;snapshot_jobs=jobs}
let await_asset_cleanup t snapshot =
  let rec join seen job=
    if Cleanup_ids.mem job.cleanup_id seen then seen else (
      Eio.Promise.await job.finished;
      Rrbvec.fold_left join(Cleanup_ids.add job.cleanup_id seen)job.children) in
  Eio.Fiber.first
    (fun()->
      let joined=Rrbvec.fold_left join Cleanup_ids.empty snapshot.snapshot_jobs in
      let pending=Hashtbl.fold(fun(scope,_) owner pending->
        pending || (scope=snapshot.snapshot_scope && Cleanup_ids.mem owner.cleanup_id joined))t.resource_cleanup_owners false in
      if t.stopped then Error "The Worker stopped before attachment settlement."
      else if pending then Error "Attachment cleanup has an unsettled physical release. Retry after storage recovers."
      else Ok())
    (fun()->Eio.Promise.await(fst t.asset_cleanup_stopped);
      Error "The Worker stopped before attachment settlement.")
;;
let asset_callback_barrier t =
  if t.next_asset_barrier=Int64.max_int then failwith "Asset callback barrier counter exhausted";
  t.next_asset_barrier<-Int64.succ t.next_asset_barrier;
  let token=t.next_asset_barrier in
  let promise,resolve=Eio.Promise.create() in
  Hashtbl.add t.asset_cleanup_barriers token resolve;
  t.post(Core.Asset_cleanup_barrier token);
  Fun.protect ~finally:(fun()->Hashtbl.remove t.asset_cleanup_barriers token)(fun()->
    Eio.Fiber.first
      (fun()->Eio.Promise.await promise)
      (fun()->Eio.Promise.await(fst t.asset_cleanup_stopped)))
;;
let await_sync_io t ~scope =
  if t.stopped then Error "The Worker stopped before Sync I/O settlement."
  else if t.next_asset_barrier=Int64.max_int then Error "I/O fence counter exhausted." else
  let promise,resolve=Eio.Promise.create() in
  t.next_asset_barrier<-Int64.succ t.next_asset_barrier;
  let id=t.next_asset_barrier in
  Hashtbl.add t.sync_io_waiters id(scope,resolve);
  Fun.protect ~finally:(fun()->Hashtbl.remove t.sync_io_waiters id)(fun()->
    t.post(Core.Sync_event(Sync.IO_fence_requested(id,scope)));
    Eio.Fiber.first
      (fun()->let result=Eio.Promise.await promise in
        if t.stopped then Error "The Worker stopped before Sync I/O settlement." else result)
      (fun()->Eio.Promise.await(fst t.asset_cleanup_stopped);
        Error "The Worker stopped before Sync I/O settlement."))
;;

let quiesce_writers t ~scope =
  let next,outcome=Core.Writer_fence.freeze t.writer_fence scope in
  t.writer_fence<-next;
  match outcome with
  |Error _->Error "Writer fence capacity is full."
  |Ok fence->
    let jobs=Hashtbl.fold(fun _ job jobs->
      if Core.Writer_fence.same_incarnation job.writer_scope scope
      then Rrbvec.push_back jobs job else jobs)t.writer_jobs Rrbvec.empty in
    Eio.Fiber.first
      (fun()->
        Rrbvec.iter(fun job->Eio.Promise.await job.writer_finished)jobs;
        (* Join the actual reducer callback outlet after each captured task has
           posted. Work emitted by those callbacks meets the permanent gate. *)
        asset_callback_barrier t;
        (* Parent cancellation only requests Sync cancellation. Its physical task
           and final callback remain owned by Sync until this actual I/O join. *)
        let children=asset_call t ~scope Sync.Await_asset_operations in
        asset_callback_barrier t;
        if t.stopped then Error "The Worker stopped before writer settlement."
        else match children with
          |Ok Sync.Asset_unit when Core.Writer_fence.drained t.writer_fence fence->Ok()
          |Ok _->Error "Graph writers remain unsettled."
          |Error _->Error "Scoped asset child I/O did not settle.")
      (fun()->Eio.Promise.await(fst t.asset_cleanup_stopped);
        Error "The Worker stopped before writer settlement.")
;;

let start_asset_cleanup_job ?parent ?(prepare=(fun _->())) t ~scope work =
  if t.next_asset_cleanup=Int64.max_int then failwith "Asset cleanup counter exhausted";
  t.next_asset_cleanup<-Int64.succ t.next_asset_cleanup;
  let serial=t.next_asset_cleanup in
  let finished,resolve=Eio.Promise.create() in
  let job={cleanup_id=serial;cleanup_scope=scope;finished;children=Rrbvec.empty} in
  Hashtbl.add t.asset_cleanup_jobs serial job;
  Option.iter(fun parent->parent.children<-Rrbvec.push_back parent.children job)parent;
  prepare job;
  t.dependencies.runtime.fork ~sw:t.sw(fun()->
    work job;
    ignore(Eio.Promise.try_resolve resolve():bool);
    Hashtbl.remove t.asset_cleanup_jobs serial)
;;
let asset_cleanup_parent t scope handle=
  Option.bind(Hashtbl.find_opt t.asset_result_sources(scope,handle))(fun ticket->
    Hashtbl.find_opt t.cancelled_asset_jobs ticket)
;;

let run_asset t (context : Sync.asset_context) instruction =
  let module Transfer = Logseq_sync_pure_reducer.Asset_transfer in
  let perform ticket action success =
    let scope =
      match ticket with
      | Transfer.Lookup ticket -> ticket.scope
      | Download ticket -> ticket.scope
    in
    let valid () = (not t.stopped) && scope = context.scope && t.asset_current ticket in
    if valid () && not (Hashtbl.mem t.asset_operations ticket)
    then (
      let asset = match ticket with Transfer.Lookup ticket -> ticket.asset | Download ticket -> ticket.asset in
      let ticket_id = match ticket with Transfer.Lookup ticket -> ticket.id | Download ticket -> ticket.id in
      clear_notice_diagnostic t context.scope (Download_notice asset);
      Hashtbl.add t.asset_operations ticket "";
      t.dependencies.runtime.fork ~sw:t.sw (fun () ->
        Fun.protect
          ~finally:(fun () -> Hashtbl.remove t.asset_operations ticket)
          (fun () ->
             let detail = ref None in
             let result =
               if not (valid ())
               then Error Sync.Asset_cancelled
               else
                 let call action =
                   detail := None;
                   asset_call ~on_diagnostic:(fun value -> detail := Some value)
                     ~started:(fun operation -> Hashtbl.replace t.asset_operations ticket operation)
                     t ~scope:context.scope action in
                 action detail call
             in
             (match result with
              | Ok(Sync.Asset_cached(Some handle)|Asset_downloaded handle)->
                Hashtbl.replace t.asset_result_sources(context.scope,handle)ticket
              | _->());
             if valid ()
             then (
               let asset = match ticket with Transfer.Lookup ticket -> ticket.asset | Download ticket -> ticket.asset in
               (match result with
                | Error Sync.Asset_cancelled | Ok _ -> clear_notice_diagnostic t context.scope (Download_notice asset)
                | Error failure -> queue_notice_diagnostic t context.scope (Download_notice asset) ticket_id
                  (Option.value !detail ~default:(asset_failure_detail ~operation:"assetDownload" failure)));
               t.post
                 (Core.Asset_completed
                    ( context.scope
                    , success
                        (match result with
                         | Ok value -> Ok value
                         | Error failure -> Error (transfer_failure failure)) )))
             else (
               match result with
               | Ok (Sync.Asset_cached (Some handle) | Asset_downloaded handle) ->
                 let parent=asset_cleanup_parent t context.scope handle in
                 Hashtbl.remove t.asset_result_sources(context.scope,handle);
                 start_asset_cleanup_job ?parent t ~scope:context.scope(fun job->
                   abandon_asset_file_internal ~cleanup_job:job t ~scope:context.scope ~handle)
               | Ok _ | Error _ -> ()))))
  in
  match instruction with
  | Transfer.Check_cache ticket ->
    let work = Transfer.Lookup ticket in
    perform
      work
      (fun diagnostic call ->
         let local checksum =
           lookup_local_asset
             t
             ~scope:context.scope
             ~asset:ticket.asset
             ~checksum
             ~current:(fun () -> t.asset_current work)
             ~diagnostic
             call
         in
         match ticket.source with
         | Transfer.Local_checksum checksum -> local checksum
         | Remote_version version -> call (Sync.Check_asset_cache (ticket.asset, version))
         | Local_and_remote { current_checksum; remote_version } ->
           (match local current_checksum with
            | Ok (Sync.Asset_cached None) ->
              call (Sync.Check_asset_cache (ticket.asset, remote_version))
            | result -> result))
      (fun result ->
         Transfer.Cache_checked
           ( ticket
           , Result.bind result (function
               | Sync.Asset_cached handle -> Ok handle
               | _ -> Error (Transfer.Invalid_content "Unexpected cache completion")) ))
  | Fetch ticket ->
    perform
      (Transfer.Download ticket)
      (fun _diagnostic call ->
         call
           (Sync.Fetch_asset
              { asset = ticket.asset
              ; version = ticket.version
              ; maximum_plaintext_bytes = 8 * 1024 * 1024
              }))
      (fun result ->
         Transfer.Downloaded
           ( ticket
           , Result.bind result (function
               | Sync.Asset_downloaded handle -> Ok handle
               | _ -> Error (Transfer.Invalid_content "Unexpected download completion"))
           ))
  | Cancel ticket ->
    let asset,id=match ticket with Transfer.Lookup ticket->ticket.asset,ticket.id|Download ticket->ticket.asset,ticket.id in
    clear_notice_diagnostic ~ticket_id:id t context.scope(Download_notice asset);
    start_asset_cleanup_job ~prepare:(fun job->Hashtbl.replace t.cancelled_asset_jobs ticket job)
      t ~scope:context.scope(fun job->
      Fun.protect ~finally:(fun()->match Hashtbl.find_opt t.cancelled_asset_jobs ticket with
        | Some active when active.cleanup_id=job.cleanup_id->Hashtbl.remove t.cancelled_asset_jobs ticket
        | _->())(fun()->
      Option.iter(fun operation->if operation<>"" then send_asset t ~scope:context.scope(Sync.Cancel_asset_operation operation))
        (Hashtbl.find_opt t.asset_operations ticket);
      let rec joined()=if not t.stopped && Hashtbl.mem t.asset_operations ticket then (t.dependencies.runtime.sleep 0.001;joined()) in
      joined();
      asset_callback_barrier t))
  | Release_handle handle ->
    let parent=asset_cleanup_parent t context.scope handle in
    Hashtbl.remove t.asset_result_sources(context.scope,handle);
    start_asset_cleanup_job ?parent t ~scope:context.scope(fun job->
      abandon_asset_file_internal ~cleanup_job:job t ~scope:context.scope ~handle)
  | Retry_after { id; seconds } ->
    t.dependencies.runtime.fork ~sw:t.sw (fun () ->
      match asset_call t ~scope:context.scope (Sync.Asset_retry_after seconds) with
      | Ok Sync.Asset_retry_elapsed when not t.stopped ->
        t.post (Core.Asset_completed (context.scope, Transfer.Retry_elapsed id))
      | Error Sync.Asset_cancelled -> ()
      | Ok _ | Error _ ->
        (match t.latest_snapshot with
         | Some snapshot when not t.stopped
             && snapshot.startup.account_generation=context.scope.account.account_generation
             && snapshot.startup.graph_generation=context.scope.graph_generation ->
           t.dependencies.publish (Core.Diagnostic "asset.retryTimer")
         | _ -> ()))
  | Notify _ | Backpressure _ | Capacity_available -> ()
;;

let submit t = function
  | Core.Sync_io_fence_reached(id,scope,result)->
    (match Hashtbl.find_opt t.sync_io_waiters id with
     |Some(expected,resolve) when expected=scope->ignore(Eio.Promise.try_resolve resolve result:bool)
     |_->())
  | Core.Deliver_protected_result output ->
    (match
       Hashtbl.find_opt
         t.protected_waiters
         output.Sync.protected_request.protected_operation
     with
     | Some waiter when waiter.protected_request = output.protected_request ->
       ignore (Eio.Promise.try_resolve waiter.protected_resolve output : bool)
     | Some _ | None -> ())
  | Core.Deliver_asset_result output ->
    (match Hashtbl.find_opt t.asset_waiters output.Sync.request.operation with
     | Some waiter when waiter.request = output.request && waiter.delivered = None ->
       waiter.delivered <- Some output;
       if not (Eio.Promise.try_resolve waiter.resolve output) then reclaim_waiter t waiter
     | Some waiter when waiter.request = output.request -> ()
     | Some _ | None -> reclaim_asset_output t output)
  | Core.Read_uploads ticket ->
    if (not t.stopped) && t.recovery_current ticket then (
      match reserve_writer t ticket.scope with
      |Error message->t.post(Core.Uploads_loaded(ticket,Error message))
      |Ok job->
        (try t.dependencies.runtime.fork ~sw:t.sw(fun()->
          Fun.protect ~finally:(fun()->finish_writer t job)(fun()->
            if not t.stopped && t.recovery_current ticket then (
              let current()=t.recovery_current ticket && not(Core.Writer_fence.fenced t.writer_fence ticket.scope) in
              let result=with_staging_lock t(fun()->
                Result.bind(reconcile_staging t ticket.scope ~current)(fun()->
                  with_upload_store t(fun db->Logseq_db_storage.Asset_upload_store.list db
                    ~origin:(Uri.to_string ticket.scope.account.managed_sync_origin)
                    ~account:ticket.scope.account.user_id ~graph:ticket.scope.graph_id
                    ~after:ticket.after ~limit:ticket.limit))) in
              if not t.stopped && t.recovery_current ticket then t.post(Core.Uploads_loaded(ticket,result)))))
         with error->finish_writer t job;raise error))
  | Core.Run_upload (context, instruction) ->
    if not t.stopped then submit_upload t context instruction
  | Core.Run_asset (context, instruction) ->
    if not t.stopped then run_asset t context instruction
  | Close_asset_scope scope ->
    t.notice_diagnostics <- List.filter (fun item -> item.scope<>scope) t.notice_diagnostics;
    send_asset t ~scope Sync.Close_asset_scope
  | Core.Asset_cleanup_barrier_reached token->
    Option.iter(fun resolve->
      Hashtbl.remove t.asset_cleanup_barriers token;
      ignore(Eio.Promise.try_resolve resolve():bool))
      (Hashtbl.find_opt t.asset_cleanup_barriers token)
  | Core.Run_worker (Core.Request (_, Core.Handle_sync_worker_effect (Sync.Delete_mirror deletion)) as request) ->
    if deletion_authorized t deletion then t.deletion_owner <- Some deletion;
    if not t.stopped then submit_worker t request
  | Core.Run_worker request ->
    if not t.stopped
    then submit_worker t request
  | Run_sync (Sync.Request (ticket, Sync.Delete_account_secrets account) as sync_effect)
    ->
    if not t.stopped
    then (
      match
        with_upload_store t (fun db ->
          Logseq_db_storage.Asset_upload_store.delete_account
            db
            ~origin:(Uri.to_string account.managed_sync_origin)
            ~account:account.user_id)
      with
      | Ok () -> t.dependencies.sync_runner.submit sync_effect
      | Error message ->
        t.post
          (Core.Sync_event
             (Sync.Runner_completed
                (Sync.Completion (ticket, Error (Sync.Effect_failed message))))))
  | Run_sync (Sync.Asset_io _ as sync_effect) ->
    t.dependencies.sync_runner.submit sync_effect
  | Run_sync sync_effect ->
    if not t.stopped then t.dependencies.sync_runner.submit sync_effect
  | Publish (Core.Sync_output (Sync.Session_state_changed (scope,state)) as output) ->
    if state.snapshot.selected_graph=Some scope.graph_id then Hashtbl.replace t.session_snapshots scope state.snapshot
    else Hashtbl.remove t.session_snapshots scope;
    if not t.stopped then t.dependencies.publish output
  | Publish (Core.Sync_output (Sync.State_changed state) as output) ->
    if not (Option.fold ~none:false ~some:(fun old -> old.Sync.catalog == state.snapshot.catalog) t.latest_snapshot)
    then t.authorized_graphs <- List.fold_left (fun ids (graph : Sync.graph) ->
      Authorized_graphs.add (Graph.Uuid.to_string graph.graph_id) ids) Authorized_graphs.empty state.snapshot.catalog;
    t.latest_snapshot <- Some state.snapshot;
    Hashtbl.filter_map_inplace (fun (scope:Sync.graph_scope) own ->
      if scope.account.account_generation=state.snapshot.startup.account_generation
        && List.mem scope.graph_id state.snapshot.resident_graphs then Some own else None) t.session_snapshots;
    t.notice_diagnostics <- List.filter (fun item -> current_graph_scope t item.scope) t.notice_diagnostics;
    if not (Option.fold ~none:false ~some:(deletion_authorized t) t.deletion_owner)
    then t.deletion_owner <- None;
    if not t.stopped then t.dependencies.publish output
  | Publish (Core.Asset_notice (scope, notice) as output) -> publish_asset_notice t scope notice output
  | Publish output -> if not t.stopped then t.dependencies.publish output
;;

let await_reply t ~id ~request ~post =
  let promise, resolve = Eio.Promise.create () in
  let key = Core.request_id_to_int64 id in
  Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () ->
    Hashtbl.replace t.waiters key { request; resolve });
  post ();
  let response = Eio.Promise.await promise in
  Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () -> Hashtbl.remove t.waiters key);
  response
;;

let submit t instruction =
  match instruction with
  | Core.Publish (Reply (id, response)) ->
    let key = Core.request_id_to_int64 id in
    Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () ->
      match Hashtbl.find_opt t.waiters key with
      | None -> ()
      | Some waiter -> Eio.Promise.resolve waiter.resolve response)
  | instruction -> submit t instruction
;;

let shutdown t =
  if not t.stopped
  then (
    t.post (Core.Sync_event Sync.Shutdown);
    t.stopped <- true;
    ignore(Eio.Promise.try_resolve(snd t.asset_cleanup_stopped)():bool);
    t.notice_diagnostics <- [];
    Hashtbl.iter
      (fun _ resolve -> ignore (Eio.Promise.try_resolve resolve () : bool))
      t.upload_operations;
    ignore (close_attached t);
    Hashtbl.iter (fun id _ -> ignore (close_database_by_id t id)) t.databases;
    t.dependencies.sync_runner.shutdown ();
    Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () ->
      Hashtbl.iter
        (fun _ (waiter : waiter) ->
           let response = failure waiter.request Closed_session "The Worker stopped." in
           Eio.Promise.resolve waiter.resolve response)
        t.waiters;
      Hashtbl.clear t.waiters))
;;

let retain_asset_file t ~scope ~handle =
  if t.stopped || Core.Writer_fence.fenced t.writer_fence scope
    || not(Core.Orphan_cleanup.acquisition_open t.orphan_cleanup) then None else
  let detail = ref None in
  match asset_call ~on_diagnostic:(fun value -> detail := Some value) t ~scope (Sync.Retain_asset_file handle) with
  | Ok (Sync.Asset_retained file) -> file
  | Error Sync.Asset_cancelled -> None
  | Error failure -> report_asset_failure ?detail:!detail t scope "assetPreview" failure; None
  | Ok _ -> report_source_failure t scope "assetPreview" "invalidContent" "Unexpected asset completion"; None
;;

let release_asset_file t ~scope ~handle =
  let detail = ref None in
  match asset_call ~on_diagnostic:(fun value -> detail := Some value) t ~scope (Sync.Release_asset_file handle) with
  | Ok Sync.Asset_unit | Error Sync.Asset_cancelled -> ()
  | Error failure -> report_asset_failure ?detail:!detail t scope "assetRelease" failure
  | Ok _ -> report_source_failure t scope "assetRelease" "invalidContent" "Unexpected asset completion"
;;

let prepare_import_unlocked
      ~on_diagnostic
      t
      ~(context : Sync.asset_context)
      (request : Logseq_db_types.Asset_import.t)
      ~current
  =
  let module I = Logseq_db_types.Asset_upload_intent in
  let module A = Logseq_db_types.Asset_descriptor in
  let ( let* ) = Result.bind in
  let source_error reason result = Result.map_error (fun source ->
    on_diagnostic (failure_detail ~source ~operation:"assetMetadata" ~reason ()); source) result in
  let prepare version size staged_file =
    I.prepare
      ~replace_reference:request.replace_reference
      ~operation_id:request.operation
      ~origin:(Uri.to_string context.scope.account.managed_sync_origin)
      ~account:context.scope.account.user_id
      ~graph:context.scope.graph_id
      ~asset:request.asset
      ~target:request.target
      ~local_mutation:request.local_mutation
      ~metadata_mutation:request.metadata_mutation
      ~title:request.title
      ~version
      ~size
      ~staged_file
  in
  let* version = source_error "invalidRequest" (A.version ~checksum:(String.make 64 '0') ~file_type:request.file_type) in
  let* _ = source_error "invalidRequest" (prepare version 0L "validation.bin") in
  if (not (current ())) || t.stopped
  then Error "The selected graph is no longer active"
  else if not(Core.Orphan_cleanup.acquisition_open t.orphan_cleanup)
  then Error "Attachment cleanup is pending. Retry after cleanup succeeds."
  else
    let* () = source_error "restoreFailed" (reconcile_staging t context.scope ~current) in
    let* existing =
      source_error "persistenceFailed" (with_upload_store t (fun db ->
        Logseq_db_storage.Asset_upload_store.read db ~operation:request.operation))
    in
    match existing with
    | Some intent
      when intent.origin = Uri.to_string context.scope.account.managed_sync_origin
           && intent.account = context.scope.account.user_id
           && intent.graph = context.scope.graph_id
           && intent.asset = request.asset
           && intent.target = request.target
           && intent.title = request.title
           && intent.version.file_type = request.file_type
           && intent.local_mutation = request.local_mutation
           && intent.replace_reference = request.replace_reference
           && intent.metadata_mutation = request.metadata_mutation -> Ok intent
    | Some _ -> source_error "identityConflict" (Error "This import identity is already in use")
    | None ->
      let detail = ref None in
      let* file, checksum, size =
        match
          asset_call
            ~on_diagnostic:(fun value -> detail := Some value)
            t
            ~scope:context.scope
            (Sync.Stage_asset_file
               { operation = request.operation
               ; file_type = request.file_type
               ; source_file = request.source_file
               })
        with
        | Ok (Sync.Asset_staged { file; checksum; size }) -> Ok (file, checksum, size)
        | Error failure ->
          if failure <> Sync.Asset_cancelled then
            on_diagnostic (Option.value !detail ~default:(asset_failure_detail ~operation:"assetMetadata" failure));
          Error (asset_failure_message failure)
        | Ok _ -> source_error "invalidContent" (Error "Unexpected staging completion")
      in
      let persistence_attempted = ref false in
      let result =
        let* version = source_error "invalidRequest" (A.version ~checksum ~file_type:request.file_type) in
        let* intent = source_error "invalidRequest" (prepare version size file) in
        if (not (current ())) || t.stopped
        then Error "The selected graph is no longer active"
        else (
          persistence_attempted := true;
          let* () =
            source_error "persistenceFailed" (Eio.Cancel.protect (fun () ->
              with_upload_store t (fun db ->
                Logseq_db_storage.Asset_upload_store.save db ~expected:None intent)))
          in
          Ok intent)
      in
      (match result with
       | Ok _ -> ()
       | Error _ when not !persistence_attempted ->
         Eio.Cancel.protect (fun () ->
           ignore (asset_unit
             ~on_failure:(fun failure -> if current () then report_asset_failure t context.scope "assetRelease" failure)
             t ~scope:context.scope (Sync.Release_staged_file file)))
       | Error _ -> ());
      result
;;

let prepare_import_unfenced t ~(context : Sync.asset_context) request ~current =
  with_staging_lock t (fun () ->
    let on_diagnostic detail = if current () then
      publish_failure (report_current_graph t context.scope) detail in
    Result.map
      (fun (intent : Logseq_db_types.Asset_upload_intent.t) ->
         Hashtbl.replace
           t.local_imports
           (context.scope, intent.asset, intent.version.checksum)
           intent.operation_id;
         if intent.phase <> Logseq_db_types.Asset_upload_intent.Cancelled && current ()
         then
           (let detail = ref None in
            match asset_call ~on_diagnostic:(fun value -> detail := Some value)
                t
                ~scope:context.Sync.scope
                (Sync.Publish_staged_asset
                   { asset = intent.asset
                   ; version = intent.version
                   ; file = intent.staged_file
                   }) with
            | Ok Sync.Asset_unit | Error Sync.Asset_cancelled -> ()
            | Error failure -> if current () then report_asset_failure ?detail:!detail t context.scope "assetPreview" failure
            | Ok _ -> if current () then report_source_failure t context.scope "assetPreview" "invalidContent" "Unexpected asset completion");
         intent)
      (prepare_import_unlocked ~on_diagnostic t ~context request ~current))
;;

let prepare_import t ~(context:Sync.asset_context) request ~current =
  with_writer t context.scope(fun()->prepare_import_unfenced t ~context request ~current)
;;

let retain_imported_file t ~(scope : Sync.graph_scope) ~operation =
  if t.stopped || Core.Writer_fence.fenced t.writer_fence scope
    || not(Core.Orphan_cleanup.acquisition_open t.orphan_cleanup)
  then None
  else (
    match
      with_upload_store t (fun db ->
        Logseq_db_storage.Asset_upload_store.read db ~operation)
    with
    | Ok (Some intent)
      when intent.origin = Uri.to_string scope.account.managed_sync_origin
           && intent.account = scope.account.user_id
           && intent.graph = scope.graph_id
           && intent.phase <> Logseq_db_types.Asset_upload_intent.Cancelled ->
      (let detail = ref None in
       match asset_call ~on_diagnostic:(fun value -> detail := Some value) t ~scope (Sync.Retain_staged_file intent.staged_file) with
       | Ok (Sync.Asset_retained file) -> file
       | Error Sync.Asset_cancelled -> None
       | Error failure -> report_asset_failure ?detail:!detail t scope "assetPreview" failure; None
       | Ok _ -> report_source_failure t scope "assetPreview" "invalidContent" "Unexpected asset completion"; None)
    | Ok _ -> None
    | Error source -> report_source_failure t scope "assetMetadata" "persistenceFailed" source; None)
;;
