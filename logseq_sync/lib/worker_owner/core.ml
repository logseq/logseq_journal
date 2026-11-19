module Dsl = Sync_dsl.Core
module Execute = Execute.Core
module Intent = Logseq_db_types.Asset_upload_intent
module Input = Logseq_db_types.Asset_import
module Store = Logseq_db_storage.Asset_upload_store
module Assets = Logseq_sync_assets.Core
module Cache = Logseq_sync_assets.Cache
module Uuid = Logseq_db_types.Graph_types.Uuid
module Database = Logseq_overlay_db.Database

let ( let* ) = Result.bind

type store =
  { connection : Sqlite3.db
  ; mutex : Eio.Mutex.t
  }

let store connection = { connection; mutex = Eio.Mutex.create () }

type binding =
  { owner : Execute.database_owner
  ; network : Execute.worker_network
  ; cleanup_seconds : float
  }

type t =
  { namespace : string
  ; assets : Assets.t
  ; store : store
  ; notify :
      owner:Execute.database_owner -> identity:Dsl.identity -> (unit, Dsl.error) result
  ; mutable binding : binding option
  ; scopes : (Uuid.t, scope) Hashtbl.t
  ; mutable leases : int
  ; changed : Eio.Condition.t
  ; sync_changed : Eio.Condition.t
  ; mutable sync_revision : int64
  ; mutable fenced : bool
  ; join_with_timeout :
      float -> (unit -> (unit, Dsl.error) result) -> (unit, Dsl.error) result
  }

and scope =
  { owner : t
  ; operation : Uuid.t
  ; mutable active : bool
  ; mutable cancelled : bool
  ; cancel_context : Eio.Cancel.t
  }

type imported_file =
  { owner : t
  ; handle : Cache.handle
  ; path : string
  ; mutable released : bool
  }

exception Scope_cancelled

let create ~clock ~namespace ~assets ~store ~notify_outbox_changed =
  let join_with_timeout seconds callback =
    Eio.Fiber.first callback (fun () ->
      Eio.Time.Mono.sleep clock seconds;
      Error
        (Dsl.Cleanup_failure
           { primary = None
           ; failures =
               Rrbvec.singleton
                 (Dsl.Storage_failure
                    "Worker scopes or consumer leases have not physically joined")
           }))
  in
  { namespace
  ; assets
  ; store
  ; notify = notify_outbox_changed
  ; binding = None
  ; scopes = Hashtbl.create 8
  ; leases = 0
  ; changed = Eio.Condition.create ()
  ; sync_changed = Eio.Condition.create ()
  ; sync_revision = 0L
  ; fenced = false
  ; join_with_timeout
  }
;;

let identity t = Assets.identity t.assets

let same_owner t requested =
  if requested = identity t then Ok () else Error (Dsl.Identity_mismatch "Worker owner")
;;

let binding t =
  match t.binding with
  | Some binding -> Ok binding
  | None -> Error Dsl.Stale_context
;;

let current scope =
  if scope.cancelled
  then Error Dsl.Cancelled
  else if (not scope.active) || scope.owner.fenced
  then Error Dsl.Stale_context
  else (
    match Hashtbl.find_opt scope.owner.scopes scope.operation with
    | Some registered when registered == scope -> Ok ()
    | Some _ | None -> Error Dsl.Stale_context)
;;

let with_store t callback =
  Eio.Mutex.use_rw ~protect:true t.store.mutex (fun () ->
    try callback t.store.connection with
    | Sqlite3.Error message | Sqlite3.SqliteError message ->
      Error (Dsl.Storage_failure message))
;;

let storage result = Result.map_error (fun message -> Dsl.Storage_failure message) result

let uncertain result =
  Result.map_error
    (fun message ->
       Dsl.Outcome_unknown ("Import store commit response is unknown: " ^ message))
    result
;;

let input_owner t =
  let owner = identity t in
  let* graph =
    Uuid.of_string owner.graph
    |> Result.map_error (fun message -> Dsl.Invalid_input message)
  in
  let namespace = t.namespace in
  Ok Store.Inputs.{ namespace; origin = owner.origin; account = owner.account; graph }
;;

let checked_input t bytes =
  let* owner = input_owner t in
  let* input =
    Input.Pure_intent.restore ~namespace:owner.namespace bytes
    |> Result.map_error (fun _ -> Dsl.Invalid_input "Invalid original import input")
  in
  Ok (owner, input)
;;

let matches_owner t (intent : Intent.t) =
  let owner = identity t in
  intent.origin = owner.origin
  && intent.account = owner.account
  && Uuid.to_string intent.graph = owner.graph
;;

let proof scope (intent : Intent.t) =
  let* () = current scope in
  if intent.operation_id <> scope.operation || not (matches_owner scope.owner intent)
  then Error (Dsl.Identity_mismatch "Import operation")
  else
    let* owner = input_owner scope.owner in
    with_store scope.owner (fun db ->
      let* row = storage (Store.Inputs.read db ~owner ~operation:scope.operation) in
      match row with
      | Some row ->
        (match row.prepared with
         | Some prepared ->
           let* restored =
             Intent.restore prepared ~phase:intent.phase ~revision:intent.revision
             |> Result.map_error (fun message -> Dsl.Invalid_input message)
           in
           if restored = intent
           then Ok prepared
           else Error (Dsl.Identity_mismatch "Original Prepared import proof")
         | None -> Error (Dsl.Storage_failure "Original Prepared import proof is missing"))
      | None -> Error (Dsl.Identity_mismatch "Unreserved import operation"))
;;

let durable_intent scope intent =
  let* _ = proof scope intent in
  with_store scope.owner (fun db ->
    let* stored = storage (Store.read db ~operation:scope.operation) in
    match stored with
    | Some stored when stored = intent -> Ok ()
    | Some _ -> Error (Dsl.Invalid_input "Import checkpoint revision is stale")
    | None -> Error (Dsl.Storage_failure "Original import checkpoint is missing"))
;;

let with_database scope callback =
  let* () = current scope in
  let* bound = binding scope.owner in
  let* database = Execute.database bound.owner in
  let* () = current scope in
  callback database
;;

let database_changed t ~owner ~identity:requested =
  let* () = same_owner t requested in
  let* bound = binding t in
  if bound.owner != owner
  then Error (Dsl.Identity_mismatch "Worker database owner")
  else (
    t.sync_revision <- Int64.succ t.sync_revision;
    Eio.Condition.broadcast t.sync_changed;
    Ok ())
;;

let projection_changed t ~identity:requested =
  let* bound = binding t in
  database_changed t ~owner:bound.owner ~identity:requested
;;

let notify (scope : scope) =
  let* bound = binding scope.owner in
  scope.owner.notify ~owner:bound.owner ~identity:(identity scope.owner)
;;

let bind_runtime t ~identity:requested ~database_owner ~limits ~cleanup_seconds ~network =
  let* () = same_owner t requested in
  if
    limits <> Assets.limits t.assets
    || (not (Float.is_finite cleanup_seconds))
    || cleanup_seconds <= 0.
  then Error (Dsl.Invalid_input "Worker owner configuration mismatch")
  else (
    match t.binding with
    | Some _ -> Error (Dsl.Invalid_input "Worker owner is already bound")
    | None when t.fenced -> Error Dsl.Stale_context
    | None ->
      t.binding <- Some { owner = database_owner; network; cleanup_seconds };
      Ok ())
;;

let with_scope t ~identity:requested ~operation callback =
  let* () = same_owner t requested in
  let* _ = binding t in
  if t.fenced
  then Error Dsl.Stale_context
  else if Hashtbl.mem t.scopes operation
  then Error (Dsl.Capacity_exceeded "Import operation already has a live scope")
  else if Hashtbl.length t.scopes >= (Assets.limits t.assets).maximum_tasks
  then Error (Dsl.Capacity_exceeded "Worker scopes")
  else (
    try
      Eio.Cancel.sub (fun cancel_context ->
        let scope =
          { owner = t; operation; active = true; cancelled = false; cancel_context }
        in
        Hashtbl.add t.scopes operation scope;
        Fun.protect
          ~finally:(fun () ->
            scope.active <- false;
            Hashtbl.remove t.scopes operation;
            Eio.Condition.broadcast t.changed)
          (fun () -> callback scope))
    with
    | Eio.Cancel.Cancelled Scope_cancelled -> Error Dsl.Cancelled)
;;

let crypto (scope : scope) operation =
  Logseq_sync_crypto.Core.run
    (Assets.crypto scope.owner.assets)
    ~check_current:(fun () -> current scope)
    ~identity:(identity scope.owner)
    operation
;;

let prepare_import scope (request : Input.t) ~current:request_current =
  let current scope =
    let* () = current scope in
    if request_current () then Ok () else Error Dsl.Stale_context
  in
  let* () = current scope in
  if scope.operation <> request.operation
  then Error (Dsl.Identity_mismatch "Import scope operation")
  else
    let* owner = input_owner scope.owner in
    let* input =
      Input.Pure_intent.create ~namespace:owner.namespace request
      |> Result.map_error (fun _ -> Dsl.Invalid_input "Invalid complete import input")
    in
    let* reserved =
      with_store scope.owner (fun db ->
        let* () = current scope in
        uncertain (Store.Inputs.reserve db ~owner ~input))
    in
    let* () = current scope in
    let* existing =
      with_store scope.owner (fun db ->
        storage (Store.read db ~operation:request.operation))
    in
    let* () = current scope in
    match existing, reserved.prepared with
    | Some intent, Some _ ->
      let* _ = proof scope intent in
      Ok intent
    | None, Some _ | Some _, None ->
      Error
        (Dsl.Storage_failure
           "Checkpoint and original Prepared proof disagree; staging is retained")
    | None, None ->
      let* staged =
        Assets.stage scope.owner.assets ~check_current:(fun () -> current scope) request
      in
      let prepare () =
        let* () = current scope in
        let* version =
          Logseq_db_types.Asset_descriptor.version
            ~checksum:staged.checksum
            ~file_type:request.file_type
          |> Result.map_error (fun message -> Dsl.Invalid_input message)
        in
        let* intent =
          Intent.prepare
            ~operation_id:request.operation
            ~origin:owner.origin
            ~account:owner.account
            ~graph:owner.graph
            ~asset:request.asset
            ~version
            ~title:request.title
            ~size:staged.size
            ~staged_file:staged.file
            ~replace_reference:request.replace_reference
            ~target:request.target
            ~local_mutation:request.local_mutation
            ~metadata_mutation:request.metadata_mutation
          |> Result.map_error (fun message -> Dsl.Invalid_input message)
        in
        Ok intent
      in
      let discard error =
        match Cache.release_staged (Assets.cache scope.owner.assets) ~file:staged.file with
        | Ok () -> Error error
        | Error cleanup -> Error (Dsl.Cleanup_failure
            { primary = Some error
            ; failures = Rrbvec.singleton (Assets.cache_error cleanup) })
      in
      (match prepare () with
       | Error error -> discard error
       | Ok intent ->
         let admitted = ref false in
         match with_store scope.owner (fun db ->
           let* () = current scope in
           admitted := true;
           uncertain (Store.Inputs.commit_prepared db ~owner ~input intent)) with
         | Ok _ -> Ok intent
         | Error error when not !admitted -> discard error
         | Error error -> Error error)
;;

let publish_import_preview scope intent =
  let* () = durable_intent scope intent in
  Assets.publish_preview
    scope.owner.assets
    ~check_current:(fun () -> current scope)
    intent
;;

let persist_import scope intent ~expected =
  let* _ = proof scope intent in
  with_store scope.owner (fun db ->
    let* () = current scope in
    uncertain (Store.save db ~expected intent))
;;

let inspect_import scope intent =
  let* () = durable_intent scope intent in
  let* observation =
    with_database scope (fun database -> Import_database.inspect database intent)
  in
  Ok
    (match observation with
     | Import_database.U.Import_absent -> `Import_absent
     | Local_present -> `Local_present
     | Metadata_present -> `Metadata_present
     | Publication_acknowledged -> `Publication_acknowledged
     | Entity_cancelled -> `Entity_cancelled)
;;

let apply_local_import scope intent =
  let* () = durable_intent scope intent in
  with_database scope (fun database ->
    Eio.Cancel.protect (fun () ->
      let* () = current scope in
      let* () = Import_database.apply_local database intent in
      notify scope))
;;

let put_import scope intent =
  let* () = durable_intent scope intent in
  let* bound = binding scope.owner in
  Assets.put_staged
    scope.owner.assets
    ~check_current:(fun () -> current scope)
    ~network:bound.network
    intent
;;

let apply_import_metadata scope intent =
  let* () = durable_intent scope intent in
  with_database scope (fun database ->
    Eio.Cancel.protect (fun () ->
      let* () = current scope in
      let* () = Import_database.apply_metadata database intent in
      notify scope))
;;

let await_import_publication scope intent =
  let* () = durable_intent scope intent in
  with_database scope (fun database ->
    let* subscription, predecessor =
      Database.listen database
      |> Result.map_error (fun _ ->
        Dsl.Storage_failure "Import publication subscription failed")
    in
    Database.release_snapshot predecessor;
    Fun.protect
      ~finally:(fun () -> Database.unlisten subscription)
      (fun () ->
         let changed = scope.owner.sync_changed in
         let* () =
           Database.activate_subscription subscription ~notify:(fun _ ->
             scope.owner.sync_revision <- Int64.succ scope.owner.sync_revision;
             Eio.Condition.broadcast changed)
           |> Result.map_error (fun _ ->
             Dsl.Storage_failure "Import publication subscription activation failed")
         in
         let rec wait () =
           let before = scope.owner.sync_revision in
           let* observation = inspect_import scope intent in
           match observation with
           | `Publication_acknowledged -> Ok ()
           | `Import_absent | `Entity_cancelled ->
             Error (Dsl.Invalid_input "Original import mutation was not published")
           | `Local_present | `Metadata_present ->
             let* () = current scope in
             if before = scope.owner.sync_revision
             then Eio.Condition.await_no_mutex changed;
             wait ()
         in
         wait ()))
;;

let cancel_import scope intent =
  let* () = durable_intent scope intent in
  match intent.Intent.phase with
  | Complete | Cancelled -> Ok ()
  | Prepared | Local_committed | Uploading | Remote_stored | Metadata_pending ->
    let* cancelled =
      Intent.advance intent Cancelled
      |> Result.map_error (fun message -> Dsl.Invalid_input message)
    in
    persist_import scope cancelled ~expected:(Some intent.revision)
;;

let release_import_staging scope intent =
  let* () = durable_intent scope intent in
  let* () =
    match intent.Intent.phase with
    | Cancelled -> Ok ()
    | Complete ->
      let* observed = inspect_import scope intent in
      if observed = `Publication_acknowledged
      then
        Assets.publish_preview
          scope.owner.assets
          ~check_current:(fun () -> current scope)
          intent
      else Error (Dsl.Invalid_input "Terminal import has no publication proof")
    | Prepared | Local_committed | Uploading | Remote_stored | Metadata_pending ->
      Error (Dsl.Invalid_input "Import staging is not terminal")
  in
  Cache.release_staged_if_unused
    (Assets.cache scope.owner.assets)
    ~file:intent.staged_file
  |> Result.map_error Assets.cache_error
;;

let input_wire (row : Store.Inputs.record) : Input.Recovery.item =
  { sequence = row.sequence
  ; input = Input.Pure_intent.encode row.input
  ; prepared = row.evidence
  ; acknowledged = row.acknowledged
  }
;;

let recover_import_inputs scope ~after ~maximum_items ~maximum_bytes =
  let* () = current scope in
  if
    maximum_items <= 0
    || maximum_items
       > min Input.Recovery.maximum_items (Assets.limits scope.owner.assets).maximum_items
    || maximum_bytes <= 0
    || maximum_bytes
       > min Input.Recovery.maximum_bytes (Assets.limits scope.owner.assets).maximum_bytes
  then Error (Dsl.Invalid_input "Import recovery bounds")
  else
    let* owner = input_owner scope.owner in
    with_store scope.owner (fun db ->
      let* page =
        storage (Store.Inputs.pending db ~owner ~after ~maximum_items ~maximum_bytes)
      in
      Ok Input.Recovery.{ items = List.map input_wire page.items; next = page.next })
;;

let confirm_import_input scope bytes =
  let* () = current scope in
  let* owner, input = checked_input scope.owner bytes in
  with_store scope.owner (fun db ->
    let* row =
      storage (Store.Inputs.read db ~owner ~operation:(Input.Pure_intent.operation input))
    in
    match row with
    | None -> Ok None
    | Some row when Input.Pure_intent.encode row.input = bytes ->
      Ok (Some (input_wire row))
    | Some _ -> Error (Dsl.Identity_mismatch "Original complete import input"))
;;

let acknowledge_import_input scope ~input:bytes ~prepared =
  let* () = current scope in
  let* owner, input = checked_input scope.owner bytes in
  with_store scope.owner (fun db ->
    let* () = current scope in
    uncertain (Store.Inputs.acknowledge db ~owner ~input ~evidence:prepared))
;;

let cancel scope =
  if not scope.active
  then Error Dsl.Stale_context
  else (
    scope.cancelled <- true;
    Eio.Cancel.cancel scope.cancel_context Scope_cancelled;
    Ok ())
;;

let retain_imported_file scope intent =
  let* () = durable_intent scope intent in
  let t = scope.owner in
  if t.leases >= (Assets.limits t.assets).maximum_resources
  then Error (Dsl.Capacity_exceeded "Imported file leases")
  else (
    match Cache.retain_staged (Assets.cache t.assets) ~file:intent.Intent.staged_file with
    | None -> Ok None
    | Some handle ->
      (match Cache.path (Assets.cache t.assets) handle with
       | Some path ->
         t.leases <- t.leases + 1;
         Ok (Some { owner = t; handle; path; released = false })
       | None ->
         let* () =
           Cache.release_checked (Assets.cache t.assets) handle
           |> Result.map_error Assets.cache_error
         in
         Error (Dsl.Storage_failure "Retained import staging disappeared")))
;;

let imported_file_path file = file.path

let release_imported_file file =
  if file.released
  then Ok ()
  else
    let* () =
      Cache.release_checked (Assets.cache file.owner.assets) file.handle
      |> Result.map_error Assets.cache_error
    in
    file.released <- true;
    file.owner.leases <- file.owner.leases - 1;
    Eio.Condition.broadcast file.owner.changed;
    Ok ()
;;

let fence t ~identity:requested =
  let* () = same_owner t requested in
  t.fenced <- true;
  Assets.fence t.assets;
  Hashtbl.iter
    (fun _ scope ->
       scope.cancelled <- true;
       Eio.Cancel.cancel scope.cancel_context Scope_cancelled)
    t.scopes;
  Ok ()
;;

let await_io t ~identity:requested =
  let* () = same_owner t requested in
  if not t.fenced then Error (Dsl.Invalid_input "Fence Worker before joining")
  else
    let* bound = binding t in
    let rec wait () =
      if Hashtbl.length t.scopes = 0 then Ok ()
      else (Eio.Condition.await_no_mutex t.changed; wait ())
    in
    t.join_with_timeout bound.cleanup_seconds wait
;;

let await_quiescent t ~identity:requested =
  let* () = same_owner t requested in
  if not t.fenced
  then Error (Dsl.Invalid_input "Fence Worker before joining")
  else (
    let rec wait () =
      if Hashtbl.length t.scopes = 0 && t.leases = 0
      then Ok ()
      else (
        Eio.Condition.await_no_mutex t.changed;
        wait ())
    in
    let* bound = binding t in
    t.join_with_timeout bound.cleanup_seconds wait)
;;

let original_import t (asset : Dsl.asset) =
  match asset.source, asset.current_checksum with
  | Logseq_db_types.Asset_descriptor.External _, _ | Managed _, None -> Ok None
  | Managed _, Some checksum ->
    let* owner = input_owner t in
    with_store t (fun db ->
      storage
        (Store.find_original
           db
           ~origin:owner.origin
           ~account:owner.account
           ~graph:owner.graph
           ~asset:asset.uuid
           ~checksum))
;;

let upload_asset t asset =
  let* original = original_import t asset in
  match original with
  | None -> Error (Dsl.Storage_failure "No original durable import for asset upload")
  | Some intent ->
    with_scope t ~identity:(identity t) ~operation:intent.operation_id (fun scope ->
      let step intent phase action =
        let* () = action intent in
        let* next =
          Intent.advance intent phase
          |> Result.map_error (fun message -> Dsl.Invalid_input message)
        in
        let* () = persist_import scope next ~expected:(Some intent.revision) in
        Ok next
      in
      let rec resume intent =
        match intent.Intent.phase with
        | Prepared ->
          let* next = step intent Local_committed (apply_local_import scope) in
          resume next
        | Local_committed ->
          let* next = step intent Uploading (fun _ -> Ok ()) in
          resume next
        | Uploading ->
          let* next = step intent Remote_stored (put_import scope) in
          resume next
        | Remote_stored ->
          let* next = step intent Metadata_pending (apply_import_metadata scope) in
          resume next
        | Metadata_pending ->
          let* next = step intent Complete (await_import_publication scope) in
          resume next
        | Complete ->
          let* () = await_import_publication scope intent in
          Ok ()
        | Cancelled -> Error Dsl.Cancelled
      in
      resume intent)
;;

let run_assets : type value. t -> identity:Dsl.identity -> operation:Uuid.t -> value Dsl.assets -> (value, Dsl.error) result =
  fun t ~identity ~operation action ->
  match action with
  | Dsl.Release_file file -> Assets.release_file t.assets ~identity file
  | Release_lease lease -> Assets.release_lease t.assets ~identity lease
  | _ ->
    with_scope t ~identity ~operation (fun scope ->
      let* bound = binding t in
      let run () = Assets.run t.assets
        ~check_current:(fun () -> current scope)
        ~admit_network:(fun () -> current scope)
        ~original:(original_import t) ~upload:(upload_asset t) ~identity action in
      match action with
      | Dsl.Download _ | Upload _ -> bound.network.with_admission run
      | _ -> run ())
;;

let asset_file_path t file = Assets.file_path t.assets file

let assets_dispatch t ~scope ~identity operation =
  Assets.dispatch
    t.assets
    ~original:(original_import t)
    ~upload:(upload_asset t)
    ~scope
    ~identity
    operation
;;

let crypto_dispatch t ~scope ~identity operation =
  Logseq_sync_crypto.Core.dispatch (Assets.crypto t.assets) ~scope ~identity operation
;;

let worker_owner t =
  (module struct
    type nonrec scope = scope
    type nonrec imported_file = imported_file

    let bind_runtime = bind_runtime t

    let with_scope ~identity ~operation callback =
      with_scope t ~identity ~operation callback
    ;;

    let crypto = crypto
    let prepare_import = prepare_import
    let publish_import_preview = publish_import_preview
    let persist_import = persist_import
    let inspect_import = inspect_import
    let apply_local_import = apply_local_import
    let put_import = put_import
    let apply_import_metadata = apply_import_metadata
    let await_import_publication = await_import_publication
    let cancel_import = cancel_import
    let release_import_staging = release_import_staging
    let recover_import_inputs = recover_import_inputs
    let confirm_import_input = confirm_import_input
    let acknowledge_import_input = acknowledge_import_input
    let cancel = cancel
    let retain_imported_file = retain_imported_file
    let imported_file_path = imported_file_path
    let release_imported_file = release_imported_file
    let fence = fence t
    let await_quiescent = await_quiescent t
  end : Execute.WORKER_OWNER)
;;
