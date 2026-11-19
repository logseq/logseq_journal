module Dsl = Sync_dsl.Core
module Execute = Execute.Core
module Service = Logseq_sync_sync_service.Core
module Transport = Logseq_sync_transport.Core
module Http = Logseq_sync_transport.Http_client
module Crypto = Logseq_sync_crypto.Core
module Assets = Logseq_sync_assets.Core
module Worker = Logseq_sync_worker_owner.Core
module Database = Logseq_overlay_db.Database
module Types = Logseq_overlay_db.Types

let ( let* ) = Result.bind

type t =
  { identity : Dsl.identity
  ; worker : Worker.t
  ; service : Service.t
  ; database_owner : Execute.database_owner
  ; bound : Service.ingress option ref
  ; owns_database : bool
  }

let identity t = t.identity
let worker_owner t = t.worker
let database_owner t = t.database_owner

let ingress t =
  match !(t.bound) with
  | Some ingress -> Ok ingress
  | None -> Error (Dsl.Invalid_input "Sync ingress is not bound")
;;

let projection_changed t =
  let* ingress = ingress t in
  let* () = Worker.projection_changed t.worker ~identity:t.identity in
  ingress.outbox_committed ~owner:t.database_owner ~identity:t.identity
;;

let set_network t = Service.set_network t.service
let close_database_owner owner =
  let* database = Execute.database_if_open owner in
  match database with
  | None -> Ok ()
  | Some database -> Database.close database |> Result.map_error (function
      | Types.Close_failed message -> Dsl.Storage_failure ("Database close failed: " ^ message)
      | Fatal_close message -> Dsl.Storage_failure ("Database fatal close: " ^ message))
;;

let close t =
  Service.close t.service;
  if t.owns_database then
    match close_database_owner t.database_owner with
    | Ok () -> ()
    | Error error -> raise (Service.Close_failed { error = Some error; cause = None })
;;

let listen_error = function
  | Types.Listen_database_closed -> Dsl.Storage_failure "Sync database is closed"
  | Subscription_inactive -> Dsl.Storage_failure "Sync subscription is inactive"
  | Subscription_already_active -> Dsl.Storage_failure "Sync subscription is already active"
  | Listen_capacity_unavailable -> Dsl.Capacity_exceeded "Sync projection subscription"
  | Listen_fatal_state message -> Dsl.Storage_failure message
;;

let read_error = function
  | Types.Database_closed -> Dsl.Storage_failure "Database closed"
  | Snapshot_released -> Dsl.Storage_failure "Snapshot released"
  | Snapshot_generation_invalidated -> Dsl.Storage_failure "Snapshot generation invalidated"
  | Read_limit_exceeded -> Dsl.Capacity_exceeded "Graph identity read"
  | Stale_read_cursor -> Dsl.Storage_failure "Stale graph identity cursor"
  | Invalid_read_request message -> Dsl.Invalid_input message
  | Fatal_read_state message -> Dsl.Storage_failure message
;;

let start_native_assembled ~sw ~clock ~network ~authenticator ~(config : Service.config) ~deadlines
    ~liveness ~cleanup_seconds ~root ~make_owner ~owns_database ~upload_store
    ~namespace ~encrypted ~token ~on_change ~on_error =
  let identity = config.identity and limits = config.limits in
  let* () =
    if namespace = "" || String.length namespace > 1024
    then Error (Dsl.Invalid_input "Sync import namespace")
    else if Filename.is_relative root
    then Error (Dsl.Invalid_input "Sync storage root must be absolute")
    else Ok () in
  let validate_database database =
    let* snapshot = Database.current_snapshot database |> Result.map_error read_error in
    let graph = Fun.protect ~finally:(fun () -> Database.release_snapshot snapshot)
      (fun () -> Database.graph_info snapshot) in
    let* graph = graph |> Result.map_error read_error in
    if Logseq_db_types.Graph_types.Uuid.to_string graph.graph_uuid <> identity.graph
    then Error (Dsl.Identity_mismatch "Sync graph database") else Ok () in
  let staging_directory = Filename.concat root "sync-staging" in
  let* () =
    try
      (try Unix.mkdir staging_directory 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      if (Unix.lstat staging_directory).st_kind = Unix.S_DIR then Ok ()
      else Error (Dsl.Storage_failure "Sync staging path is not a directory")
    with Unix.Unix_error (error, operation, _) ->
      Error (Dsl.Storage_failure (operation ^ ": " ^ Unix.error_message error)) in
  let* transport = Transport.create_native
    ~verify_snapshot:Database.inspect_snapshot_storage ~sw ~clock ~network ~authenticator
    ~identity ~limits ~deadlines ~cleanup_seconds ~liveness
    ~staging_directory ~encrypted ~token in
  let* database_owner = make_owner transport in
  let* database = Execute.database_if_open database_owner in
  let* () = match database with None -> Ok () | Some database -> validate_database database in
  let crypto = Crypto.create ~identity ~limits ~encrypted ~backend:Crypto.apple_backend in
  let bound = ref None and subscription = ref None and retired = ref false in
  let acquired = ref false in
  let gate = ref Dsl.Closed and active_assets = ref 0 in
  let effect_binding : Execute.effect_scope Eio.Fiber.key = Eio.Fiber.create_key () in
  let worker_epoch : int64 Eio.Fiber.key = Eio.Fiber.create_key () in
  let check requested =
    if requested <> identity then Error (Dsl.Identity_mismatch "Sync coordinator identity")
    else if !retired then Error Dsl.Stale_context else Ok () in
  let authority () =
    let* () = check identity in
    match !gate with
    | Dsl.Closed -> Error Dsl.Network_closed
    | Open { authorization_epoch } -> Ok authorization_epoch in
  let http = Http.create ~token ~backend:(Http.native_backend ~sw ~clock ~network
    ~authenticator ~deadlines) in
  let http_scope epoch : Http.scope =
    let current () =
      let* actual = authority () in
      if actual <> epoch then Error Dsl.Stale_context
      else match Eio.Fiber.get effect_binding with
        | Some scope -> Execute.check_current scope
        | None -> (match Eio.Fiber.get worker_epoch with
          | Some admitted when admitted = epoch -> check identity
          | Some _ -> Error Dsl.Stale_context
          | None -> Error (Dsl.Invalid_input "Asset HTTP has no admitted operation")) in
    { check_current = current
    ; admit_network = (fun () ->
        let* () = current () in
        match Eio.Fiber.get effect_binding with
        | Some scope -> Execute.admit_network scope
        | None -> current ()) } in
  let network : Assets.network =
    { get = (fun ~identity:requested ~asset ~version ~maximum_wire_bytes ->
        let* () = check requested in
        let* epoch = authority () in
        Http.get_asset http ~scope:(http_scope epoch) ~epoch ~identity:requested
          ~asset:asset.Logseq_db_types.Asset_descriptor.uuid ~version ~maximum_wire_bytes)
    ; put = (fun ~identity:requested ~asset ~version ~wire ->
        let* () = check requested in
        let* epoch = authority () in
        Http.put_asset http ~scope:(http_scope epoch) ~epoch ~identity:requested
          ~asset ~version ~wire) } in
  let* assets = Assets.create ~root:(Filename.concat root "logseq-db-worker/assets") ~identity ~limits ~crypto
    ~key:(Assets.native_key ~identity ~crypto) ~network in
  let notify ~owner ~identity =
    match !bound with
    | None -> Error (Dsl.Storage_failure "Sync postcommit ingress is not installed")
    | Some ingress -> ingress.Service.outbox_committed ~owner ~identity in
  let worker = Worker.create ~clock ~namespace ~assets ~store:upload_store
    ~notify_outbox_changed:notify in
  let module Raw_worker = (val Worker.worker_owner worker : Execute.WORKER_OWNER) in
  let module Bound_worker = struct
    include Raw_worker

    let bind_runtime ~identity ~database_owner ~limits ~cleanup_seconds
        ~(network : Execute.worker_network) =
      Raw_worker.bind_runtime ~identity ~database_owner ~limits ~cleanup_seconds
        ~network:{ with_admission = (fun callback ->
          network.with_admission (fun () ->
            let* epoch = authority () in
            Eio.Fiber.with_binding worker_epoch epoch callback)) }
  end in
  let activate_subscription listener =
    let notify_change _ =
      match Worker.database_changed worker ~owner:database_owner ~identity with
      | Error error -> on_error error
      | Ok () -> (match notify ~owner:database_owner ~identity with
        | Ok () -> () | Error error -> on_error error) in
    Database.activate_subscription listener ~notify:notify_change
      |> Result.map_error listen_error in
  let subscribe database =
    if !retired || Option.is_some !subscription then Ok ()
    else
      let* () = validate_database database in
      let* listener, snapshot = Database.listen database |> Result.map_error listen_error in
      Database.release_snapshot snapshot;
      subscription := Some listener;
      match !bound with None -> Ok () | Some _ -> activate_subscription listener in
  let inspect requested =
    if requested <> identity then Error (Dsl.Identity_mismatch "Sync observation identity")
    else
      let* database = Execute.database_if_open database_owner in
      match database with
      | None -> Ok None
      | Some database ->
        let* () = subscribe database in
        Database.inspect_sync database |> Result.map Option.some
          |> Result.map_error (fun error -> Dsl.Sync_read_failure error) in
  let release_subscription () =
    Option.iter Database.unlisten !subscription;
    subscription := None in
  let acquire requested =
    let* () = check requested in
    if !acquired
    then Error (Dsl.Identity_mismatch "Sync coordinator already acquired")
    else
      let* database = Execute.database_if_open database_owner in
      let* () = match database with None -> Ok () | Some database -> subscribe database in
      acquired := true;
      Ok () in
  let with_asset scope callback =
    incr active_assets;
    Fun.protect ~finally:(fun () -> decr active_assets)
      (fun () -> Eio.Fiber.with_binding effect_binding scope callback) in
  let caps : Execute.capabilities =
    { validate_identity = (fun requested ->
        if requested = identity then Ok ()
        else Error (Dsl.Identity_mismatch "Sync coordinator identity"))
    ; validate_limits = (fun supplied ->
        if supplied = limits then Ok () else Error (Dsl.Invalid_input "Sync coordinator limits"))
    ; websocket_liveness = liveness; network_deadlines = deadlines; cleanup_seconds
    ; acquire
    ; fence_network = (fun requested ->
        gate := Dsl.Closed;
        Transport.fence transport ~identity:requested)
    ; close_network = (fun requested -> Transport.close_network transport ~identity:requested)
    ; authorize_network = (fun requested ~epoch ->
        let* () = check requested in
        let* () = Transport.authorize transport ~identity:requested ~epoch in
        gate := Dsl.Open { authorization_epoch = epoch };
        Ok ())
    ; validate_resource = Assets.validate_resource assets
    ; restore = (fun ~scope requested ->
        let* () = Execute.check_current scope in
        let* view = inspect requested in
        Ok { Dsl.keys = Crypto.status crypto
           ; checkpoint = Option.map Types.sync_view_checkpoint view
           ; recovery_pending = Option.fold ~none:false
               ~some:(fun view -> Types.sync_view_submissions view <> []) view })
    ; worker_owner = (module Bound_worker)
    ; dispatch =
        { database = (fun ~owner:_ ~scope:_ ~identity:_ _ ->
            Error (Dsl.Unexpected_failure "Database instructions belong to Execute"))
        ; transport = (fun ~scope ~identity operation -> Transport.dispatch transport ~scope ~identity operation)
        ; crypto = (fun ~scope ~identity operation -> Worker.crypto_dispatch worker ~scope ~identity operation)
        ; assets = (fun ~scope ~identity operation ->
            with_asset scope (fun () -> Worker.assets_dispatch worker ~scope ~identity operation)) }
    ; observe = (fun requested ->
        let* view = inspect requested in
        Ok { Dsl.identity; keys = Crypto.status crypto; network = !gate
           ; checkpoint = Option.map Types.sync_view_checkpoint view
           ; pending_submissions = Option.fold ~none:0
               ~some:(fun view -> List.length (Types.sync_view_submissions view)) view
           ; pending_assets = !active_assets; cleanup_pending = 0; last_failure = None })
    ; fence = (fun requested ->
        let* () = if requested = identity then Ok ()
          else Error (Dsl.Identity_mismatch "Sync fence identity") in
        gate := Dsl.Closed;
        retired := true;
        Assets.fence assets;
        Worker.fence worker ~identity:requested)
    ; retire = (fun requested ->
        let* () = Worker.await_quiescent worker ~identity:requested in
        let* () = Assets.close assets in
        Crypto.retire crypto;
        release_subscription ();
        Ok ())
    ; release_file = (fun requested file -> Assets.release_file assets ~identity:requested file)
    ; release_lease = (fun requested lease -> Assets.release_lease assets ~identity:requested lease)
    ; release_snapshot = (fun requested snapshot -> Transport.release_snapshot transport ~identity:requested snapshot)
    } in
  let caps = Transport.capabilities transport caps in
  let caps = { caps with
    authorize_network = (fun requested ~epoch ->
      let* () = caps.authorize_network requested ~epoch in
      gate := Dsl.Open { authorization_epoch = epoch };
      Ok ())
    ; fence_network = (fun requested ->
        gate := Dsl.Closed;
        caps.fence_network requested) } in
  let bind_ingress ingress =
    bound := Some ingress;
    match !subscription with
    | None -> ()
    | Some listener ->
      (match activate_subscription listener with
       | Ok () -> ()
       | Error error -> on_error error;
           failwith (Dsl.error_message error)) in
  match Service.start ~sw ~config
    ~dependencies:{ clock; database_owner; capabilities = caps; bind_ingress } ~on_change with
  | Ok service -> Ok { identity; worker; service; database_owner; bound; owns_database }
  | Error error when !acquired -> Error error
  | Error primary ->
    let cleanup = List.filter_map (function Ok () -> None | Error error -> Some error)
      [Transport.close_network transport ~identity; Assets.close assets] in
    Crypto.retire crypto;
    match cleanup with
    | [] -> Error primary
    | failures -> Error (Dsl.Cleanup_failure { primary = Some primary; failures = Rrbvec.of_list failures })
;;

let start_native ~sw ~clock ~network ~authenticator ~config ~deadlines
    ~liveness ~cleanup_seconds ~root ~database_owner ~upload_store
    ~namespace ~encrypted ~token ~on_change ~on_error =
  start_native_assembled ~sw ~clock ~network ~authenticator ~config ~deadlines
    ~liveness ~cleanup_seconds ~root ~make_owner:(fun _ -> Ok database_owner)
    ~owns_database:false ~upload_store ~namespace ~encrypted ~token ~on_change ~on_error
;;

let start_owned_native ~sw ~clock ~network ~authenticator ~(config : Service.config) ~deadlines
    ~liveness ~cleanup_seconds ~root ~dependencies ~graph_name ~upload_store
    ~namespace ~encrypted ~token ~on_change ~on_error =
  let* graph_id = Logseq_db_types.Graph_types.Uuid.of_string config.identity.graph
    |> Result.map_error (fun message -> Dsl.Invalid_input ("Graph identity: " ^ message)) in
  let* inspection = Database.inspect_mirror ~application_support_directory:root ~graph_id
    |> Result.map_error (function
      | Types.Invalid_application_support_directory -> Dsl.Invalid_input "Application support directory"
      | Mirror_location_unavailable message -> Dsl.Storage_failure ("Mirror location unavailable: " ^ message)
      | Mirror_inspection_failed message -> Dsl.Storage_failure ("Mirror inspection failed: " ^ message)) in
  let make_owner transport =
    match Database.mirror_presence inspection with
    | Types.Absent _ -> Execute.activation_owner ~sw ~dependencies ~inspection ~graph_name
        ~snapshot_source:(Transport.snapshot_source transport)
    | Available _ ->
      Database.open_ ~sw dependencies inspection ~graph_name
      |> Result.map Execute.database_owner
      |> Result.map_error (function
        | Types.Mirror_absent -> Dsl.Storage_failure "Mirror disappeared before open"
        | Invalid_graph_name -> Dsl.Invalid_input "Graph name"
        | Ownership_conflict -> Dsl.Storage_failure "Graph ownership conflict"
        | Attachment_stale -> Dsl.Stale_context
        | Restore_failed message -> Dsl.Storage_failure ("Graph restore failed: " ^ message)
        | Corrupt_authoritative_store message -> Dsl.Storage_failure ("Corrupt authoritative store: " ^ message)
        | Corrupt_outbox message -> Dsl.Storage_failure ("Corrupt outbox: " ^ message)
        | Corrupt_mutation_receipt message -> Dsl.Storage_failure ("Corrupt mutation receipt: " ^ message)
        | Open_resource_failed message -> Dsl.Storage_failure ("Graph open failed: " ^ message)) in
  start_native_assembled ~sw ~clock ~network ~authenticator ~config ~deadlines
    ~liveness ~cleanup_seconds ~root ~make_owner ~owns_database:true
    ~upload_store ~namespace ~encrypted ~token ~on_change ~on_error
;;
