(** Per-version transfer policy. It never discovers graph assets. *)
module Asset = Logseq_db_types.Asset_descriptor

type priority =
  | Foreground
  | Background

type handle = string

type failure =
  | Network
  | Not_found
  | Checksum_mismatch
  | Authentication
  | Locked
  | Storage_full
  | Invalid_content of string

type availability =
  | Queued
  | Downloading
  | Ready of handle
  | Waiting_remote
  | Waiting_network
  | Waiting_unlock
  | Failed of
      { failure : failure
      ; attempts : int
      ; retry_scheduled : bool
      }

type lookup_source =
  | Local_checksum of string
  | Remote_version of Asset.version
  | Local_and_remote of
      { current_checksum : string
      ; remote_version : Asset.version
      }

type lookup_ticket =
  { id : int
  ; scope : Core.graph_scope
  ; asset : Logseq_db_types.Graph_types.Uuid.t
  ; source : lookup_source
  }

type fetch_ticket =
  { id : int
  ; scope : Core.graph_scope
  ; asset : Logseq_db_types.Graph_types.Uuid.t
  ; version : Asset.version
  }

type ticket =
  | Lookup of lookup_ticket
  | Download of fetch_ticket

type instruction =
  | Check_cache of lookup_ticket
  | Fetch of fetch_ticket
  | Cancel of ticket
  | Release_handle of handle
  | Retry_after of
      { id : int
      ; seconds : float
      }
  | Notify of
      { consumer : string
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; availability : availability
      }
  | Backpressure of string
  | Capacity_available

type event =
  | Replace of
      { consumer : string
      ; priority : priority
      ; assets : Asset.t list
      }
  | Release of string
  | Descriptor_changed of Asset.t
  | Cache_checked of lookup_ticket * (handle option, failure) result
  | Downloaded of fetch_ticket * (handle, failure) result
  | Retry of Logseq_db_types.Graph_types.Uuid.t
  | Retry_elapsed of int
  | Network_changed of bool
  | Unlock_changed of bool
  | Shutdown

module U = Logseq_db_types.Graph_types.Uuid
module Assets = Map.Make (U)
module Consumers = Map.Make (String)

type config =
  { active : int
  ; foreground_reserved : int
  ; pending : int
  ; retries : int
  }

type phase =
  | Pending
  | Checking of lookup_ticket
  | Fetching of fetch_ticket
  | Cached of handle
  | Rejected of failure * int option

type entry =
  { descriptor : Asset.t
  ; consumers : priority Consumers.t
  ; phase : phase
  ; checked : bool
  ; attempts : int
  }

type t =
  { config : config
  ; scope : Core.graph_scope
  ; online : bool
  ; unlocked : bool
  ; entries : entry Assets.t
  ; serial : int
  ; stopped : bool
  ; pressured : bool
  }

let config ~active ~foreground_reserved ~pending ~retries =
  if
    active < 1
    || foreground_reserved < 0
    || foreground_reserved >= active
    || pending < active
    || retries < 0
    || retries > 10
  then Error "Invalid asset transfer limits"
  else Ok { active; foreground_reserved; pending; retries }
;;

let create config ~scope ~online ~unlocked =
  { config
  ; scope
  ; online
  ; unlocked
  ; entries = Assets.empty
  ; serial = 0
  ; stopped = false
  ; pressured = false
  }
;;

let lookup_source (asset : Asset.t) =
  match asset.source, asset.current_checksum with
  | Managed None, Some checksum -> Some (Local_checksum checksum)
  | Managed (Some version), None -> Some (Remote_version version)
  | Managed (Some remote_version), Some current_checksum ->
    Some (Local_and_remote { current_checksum; remote_version })
  | Managed None, None | External _, _ -> None
;;

let remote_version (asset : Asset.t) =
  match asset.source with
  | Managed version -> version
  | External _ -> None
;;

let status t entry =
  match entry.phase with
  | Cached handle -> Ready handle
  | Fetching _ -> Downloading
  | Checking _ -> Queued
  | Rejected (Locked, _) -> Waiting_unlock
  | Rejected (failure, retry) ->
    Failed { failure; attempts = entry.attempts; retry_scheduled = Option.is_some retry }
  | Pending ->
    if (not entry.checked) && Option.is_some (lookup_source entry.descriptor)
    then Queued
    else (
      match entry.descriptor.source with
      | Managed None -> Waiting_remote
      | External _ -> Waiting_remote
      | Managed (Some _) ->
        if not entry.checked
        then Queued
        else if not t.online
        then Waiting_network
        else if not t.unlocked
        then Waiting_unlock
        else Queued)
;;

let availability t ~consumer =
  Assets.fold
    (fun uuid entry acc ->
       if Consumers.mem consumer entry.consumers
       then (uuid, status t entry) :: acc
       else acc)
    t.entries
    []
  |> List.rev
;;

let pending_count t =
  Assets.fold
    (fun _ entry n ->
       match entry.phase with
       | Cached _ -> n
       | _ -> n + 1)
    t.entries
    0
;;

let cleanup entry =
  match entry.phase with
  | Checking ticket -> [ Cancel (Lookup ticket) ]
  | Fetching ticket -> [ Cancel (Download ticket) ]
  | Cached handle -> [ Release_handle handle ]
  | Pending | Rejected _ -> []
;;

let foreground entry =
  Consumers.exists (fun _ priority -> priority = Foreground) entry.consumers
;;

let background_pending t =
  Assets.fold
    (fun _ entry n ->
       match entry.phase with
       | Cached _ -> n
       | Pending | Checking _ | Fetching _ | Rejected _ ->
         n + if foreground entry then 0 else 1)
    t.entries
    0
;;

let active entry =
  match entry.phase with
  | Checking _ | Fetching _ -> true
  | _ -> false
;;

let fresh_lookup t asset source =
  let id = t.serial + 1 in
  { t with serial = id }, ({ id; scope = t.scope; asset; source } : lookup_ticket)
;;

let fresh_fetch t asset version =
  let id = t.serial + 1 in
  { t with serial = id }, ({ id; scope = t.scope; asset; version } : fetch_ticket)
;;

let pump t =
  let count, background =
    Assets.fold
      (fun _ e (n, b) ->
         if active e then n + 1, b + if foreground e then 0 else 1 else n, b)
      t.entries
      (0, 0)
  in
  let candidates =
    Assets.bindings t.entries
    |> List.filter (fun (_, e) ->
      e.phase = Pending
      &&
      if e.checked
      then Option.is_some (remote_version e.descriptor) && t.online && t.unlocked
      else Option.is_some (lookup_source e.descriptor))
    |> List.stable_sort (fun (_, a) (_, b) -> Bool.compare (foreground b) (foreground a))
  in
  let t, _, _, effects =
    List.fold_left
      (fun (t, count, background, effects) (uuid, entry) ->
         let fg = foreground entry in
         if
           count >= t.config.active
           || ((not fg) && background >= t.config.active - t.config.foreground_reserved)
         then t, count, background, effects
         else (
           let work =
             if entry.checked
             then
               Option.map
                 (fun version ->
                    let t, ticket = fresh_fetch t uuid version in
                    t, Fetching ticket, Fetch ticket)
                 (remote_version entry.descriptor)
             else
               Option.map
                 (fun source ->
                    let t, ticket = fresh_lookup t uuid source in
                    t, Checking ticket, Check_cache ticket)
                 (lookup_source entry.descriptor)
           in
           match work with
           | None -> t, count, background, effects
           | Some (t, phase, instruction) ->
             ( { t with entries = Assets.add uuid { entry with phase } t.entries }
             , count + 1
             , (background + if fg then 0 else 1)
             , instruction :: effects )))
      (t, count, background, [])
      candidates
  in
  t, List.rev effects
;;

let same_version a b =
  match a.Asset.source, b.Asset.source with
  | Managed a_source, Managed b_source ->
    a_source = b_source && a.current_checksum = b.current_checksum
  | External a, External b -> a = b
  | _ -> false
;;

let update_descriptor t descriptor =
  match Assets.find_opt descriptor.Asset.uuid t.entries with
  | None -> t, []
  | Some { phase = Cached _; _ } -> t, []
  | Some entry when same_version entry.descriptor descriptor ->
    ( { t with entries = Assets.add descriptor.uuid { entry with descriptor } t.entries }
    , [] )
  | Some entry ->
    let effects = cleanup entry in
    let entries =
      match descriptor.source with
      | External _ -> Assets.remove descriptor.uuid t.entries
      | Managed _ ->
        Assets.add
          descriptor.uuid
          { entry with descriptor; phase = Pending; checked = false; attempts = 0 }
          t.entries
    in
    { t with entries }, effects
;;

let release t consumer =
  let entries, effects =
    Assets.fold
      (fun uuid entry (entries, effects) ->
         let consumers = Consumers.remove consumer entry.consumers in
         if Consumers.is_empty consumers
         then entries, cleanup entry @ effects
         else Assets.add uuid { entry with consumers } entries, effects)
      t.entries
      (Assets.empty, [])
  in
  { t with entries }, effects
;;

let replace t consumer priority descriptors =
  let candidate, effects = release t consumer in
  (* Reuse existing versions before cleanup so replacing an unchanged demand does
     not cancel an active operation or release a renderer's retained handle. *)
  let candidate, effects =
    List.fold_left
      (fun (candidate, effects) descriptor ->
         match descriptor.Asset.source with
         | External _ -> candidate, effects
         | Managed _ ->
           let entry =
             match Assets.find_opt descriptor.uuid candidate.entries with
             | Some entry -> entry
             | None ->
               (match Assets.find_opt descriptor.uuid t.entries with
                | Some entry -> { entry with consumers = Consumers.empty }
                | None ->
                  { descriptor
                  ; consumers = Consumers.empty
                  ; phase = Pending
                  ; checked = false
                  ; attempts = 0
                  })
           in
           let old_cleanup = cleanup entry in
           let effects =
             List.filter
               (fun instruction -> not (List.mem instruction old_cleanup))
               effects
           in
           let entry =
             { entry with consumers = Consumers.add consumer priority entry.consumers }
           in
           let candidate =
             { candidate with
               entries = Assets.add descriptor.uuid entry candidate.entries
             }
           in
           let candidate, updated = update_descriptor candidate descriptor in
           candidate, effects @ updated)
      (candidate, effects)
      descriptors
  in
  if
    pending_count candidate > t.config.pending
    || background_pending candidate > t.config.pending - t.config.foreground_reserved
  then { t with pressured = true }, [ Backpressure consumer ]
  else candidate, effects
;;

let ticket_asset = function
  | Lookup t -> t.asset
  | Download t -> t.asset
;;

let ticket_scope = function
  | Lookup t -> t.scope
  | Download t -> t.scope
;;

let valid_ticket t ticket expected = ticket_scope ticket = t.scope && ticket = expected

let stale_handle t handle =
  if Assets.exists (fun _ entry -> entry.phase = Cached handle) t.entries
  then []
  else [ Release_handle handle ]
;;

let fail t entry failure =
  let attempts = entry.attempts + 1 in
  let retryable =
    match failure with
    | Network | Not_found | Checksum_mismatch | Authentication -> true
    | Locked | Storage_full | Invalid_content _ -> false
  in
  if retryable && attempts <= t.config.retries
  then (
    let id = t.serial + 1 in
    ( { t with serial = id }
    , { entry with attempts; phase = Rejected (failure, Some id) }
    , [ Retry_after { id; seconds = min 60. (2. ** float_of_int (attempts - 1)) } ] ))
  else t, { entry with attempts; phase = Rejected (failure, None) }, []
;;

let completed t ticket result =
  let asset = ticket_asset ticket in
  let matching =
    match Assets.find_opt asset t.entries with
    | Some ({ phase = Checking expected; _ } as entry)
      when valid_ticket t ticket (Lookup expected) -> Some entry
    | Some ({ phase = Fetching expected; _ } as entry)
      when valid_ticket t ticket (Download expected) -> Some entry
    | _ -> None
  in
  match matching with
  | None ->
    ( t
    , (match result with
       | Ok (Some handle) -> stale_handle t handle
       | Ok None | Error _ -> []) )
  | Some entry ->
    let t, entry, effects =
      match result with
      | Ok (Some handle) -> t, { entry with phase = Cached handle; attempts = 0 }, []
      | Ok None -> t, { entry with phase = Pending; checked = true }, []
      | Error failure -> fail t entry failure
    in
    { t with entries = Assets.add asset entry t.entries }, effects
;;

let resume_entry entry =
  match entry.phase with
  | Rejected _ -> { entry with phase = Pending }
  | Pending | Checking _ | Fetching _ | Cached _ -> entry
;;

let raw_step t = function
  | Replace { consumer; priority; assets } ->
    if t.stopped then t, [] else replace t consumer priority assets
  | Release consumer -> release t consumer
  | Descriptor_changed descriptor -> update_descriptor t descriptor
  | Cache_checked (ticket, result) -> completed t (Lookup ticket) result
  | Downloaded (ticket, result) ->
    completed t (Download ticket) (Result.map Option.some result)
  | Retry uuid ->
    (match Assets.find_opt uuid t.entries with
     | Some ({ phase = Rejected _; _ } as entry) ->
       ( { t with
           entries =
             Assets.add
               uuid
               { entry with phase = Pending; checked = false; attempts = 0 }
               t.entries
         }
       , [] )
     | None | Some _ -> t, [])
  | Retry_elapsed id ->
    ( { t with
        entries =
          Assets.map
            (fun entry ->
               match entry.phase with
               | Rejected (_, Some current) when current = id -> resume_entry entry
               | _ -> entry)
            t.entries
      }
    , [] )
  | Network_changed online ->
    let entries, effects =
      Assets.fold
        (fun uuid entry (entries, effects) ->
           let entry, effects =
             match entry.phase with
             | Fetching ticket when not online ->
               { entry with phase = Pending }, Cancel (Download ticket) :: effects
             | _ -> entry, effects
           in
           Assets.add uuid entry entries, effects)
        t.entries
        (Assets.empty, [])
    in
    { t with online; entries }, effects
  | Unlock_changed unlocked ->
    let entries, effects =
      Assets.fold
        (fun uuid entry (entries, effects) ->
           let entry, effects =
             match entry.phase with
             | Fetching ticket when not unlocked ->
               { entry with phase = Pending }, Cancel (Download ticket) :: effects
             | Rejected (Locked, _) when unlocked -> resume_entry entry, effects
             | _ -> entry, effects
           in
           Assets.add uuid entry entries, effects)
        t.entries
        (Assets.empty, [])
    in
    { t with unlocked; entries }, effects
  | Shutdown ->
    ( { t with stopped = true; entries = Assets.empty }
    , Assets.fold (fun _ entry effects -> cleanup entry @ effects) t.entries [] )
;;

let notifications before after =
  Assets.fold
    (fun uuid entry effects ->
       Consumers.fold
         (fun consumer _ effects ->
            let availability = status after entry in
            let unchanged =
              match Assets.find_opt uuid before.entries with
              | Some old ->
                Consumers.mem consumer old.consumers && status before old = availability
              | None -> false
            in
            if unchanged
            then effects
            else Notify { consumer; asset = uuid; availability } :: effects)
         entry.consumers
         effects)
    after.entries
    []
  |> List.rev
;;

let step t event =
  let next, effects = raw_step t event in
  let next, scheduled = if next.stopped then next, [] else pump next in
  let next, capacity =
    if
      t.pressured
      && (pending_count next < pending_count t
          || background_pending next < background_pending t)
    then { next with pressured = false }, [ Capacity_available ]
    else next, []
  in
  next, effects @ scheduled @ notifications t next @ capacity
;;

let ticket_current t ticket =
  (not t.stopped) && ticket_scope ticket = t.scope
  && match Assets.find_opt (ticket_asset ticket) t.entries with
     | Some { phase = Checking expected; _ } -> ticket = Lookup expected
     | Some { phase = Fetching expected; _ } -> ticket = Download expected
     | _ -> false
;;
