module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Asset = Logseq_db_types.Asset_descriptor

type ticket =
  { id : int
  ; scope : Service.asset_scope
  ; handle : string
  }

type presentation =
  | Hidden
  | Placeholder of string
  | File of string
  | External of string

type instruction =
  | Demand of
      { graph_generation : int
      ; consumer : string
      ; asset : Asset.t
      }
  | Release of
      { graph_generation : int
      ; consumer : string
      }
  | Acquire of ticket
  | Release_file of
      { scope : Service.asset_scope
      ; lease : string
      }
  | Retry of
      { graph_generation : int
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      }

type event =
  | Show of
      { graph_generation : int
      ; consumer : string
      ; asset : Asset.t
      }
  | Hide
  | Availability of
      { scope : Service.asset_scope
      ; consumer : string
      ; availability : Service.Asset.availability
      }
  | Acquired of ticket * (string * string) option
  | Retry_requested
  | Demand_backpressured
  | Demand_accepted
  | Capacity_available

type selection =
  { graph_generation : int
  ; consumer : string
  ; asset : Asset.t
  }

type lease =
  { ticket : ticket
  ; lease : string
  }

type t =
  { selection : selection option
  ; pending : ticket option
  ; available : (Service.asset_scope * string) option
  ; lease : lease option
  ; pressured : bool
  ; serial : int
  ; status : presentation
  }

let empty =
  { selection = None
  ; pending = None
  ; available = None
  ; lease = None
  ; pressured = false
  ; serial = 0
  ; status = Hidden
  }
;;

let presentation t = t.status
let descriptor t = Option.map (fun selected -> selected.asset) t.selection

let release_file t =
  match t.lease with
  | None -> []
  | Some item -> [ Release_file { scope = item.ticket.scope; lease = item.lease } ]
;;

let managed (a : Asset.t) =
  match a.source with
  | Managed _ -> true
  | External _ -> false
;;

let release t =
  match t.selection with
  | Some selected when managed selected.asset ->
    [ Release
        { graph_generation = selected.graph_generation; consumer = selected.consumer }
    ]
  | _ -> []
;;

let same_version (a : Asset.t) (b : Asset.t) =
  a.uuid = b.uuid && a.source = b.source && a.current_checksum = b.current_checksum
;;

let demand selected =
  Demand
    { graph_generation = selected.graph_generation
    ; consumer = selected.consumer
    ; asset = selected.asset
    }
;;

let initial_status asset =
  match asset.Asset.source with
  | External url -> External url
  | Managed None -> Placeholder "Waiting for upload"
  | Managed (Some _) -> Placeholder "Waiting for file"
;;

let status = function
  | Service.Asset.Queued -> Placeholder "Waiting for file"
  | Downloading -> Placeholder "Downloading"
  | Waiting_remote -> Placeholder "Waiting for upload"
  | Waiting_network -> Placeholder "Available when online"
  | Waiting_unlock -> Placeholder "Unlock graph to view file"
  | Ready _ -> Placeholder "Opening file"
  | Failed { failure; _ } ->
    Placeholder
      (match failure with
       | Network -> "Unable to download file"
       | Not_found -> "File is not available on the server"
       | Checksum_mismatch -> "File verification failed"
       | Authentication -> "Sign in to download file"
       | Locked -> "Unlock graph to view file"
       | Storage_full -> "Not enough cache space"
       | Invalid_content _ -> "Unable to read file")
;;

let step t = function
  | Demand_backpressured -> { t with pressured = true }, []
  | Demand_accepted -> { t with pressured = false }, []
  | Capacity_available ->
    (match t.selection with
     | Some selected when t.pressured && managed selected.asset ->
       { t with pressured = false }, [ demand selected ]
     | _ -> t, [])
  | Show { graph_generation; consumer; asset } ->
    let selected = { graph_generation; consumer; asset } in
    (match t.selection with
     | Some old
       when old.graph_generation = graph_generation
            && old.consumer = consumer
            && same_version old.asset asset -> { t with selection = Some selected }, []
     | _ ->
       let effects =
         release_file t @ release t @ if managed asset then [ demand selected ] else []
       in
       ( { t with
           selection = Some selected
         ; pending = None
         ; available = None
         ; lease = None
         ; pressured = false
         ; status = initial_status asset
         }
       , effects ))
  | Hide -> { empty with serial = t.serial }, release_file t @ release t
  | Availability { scope; consumer; availability } ->
    (match t.selection with
     | Some selected
       when selected.graph_generation = scope.graph_generation
            && selected.consumer = consumer
            && managed selected.asset ->
       (match availability with
        | Service.Asset.Ready handle ->
          if
            (match t.lease with
             | Some l -> l.ticket.scope = scope && l.ticket.handle = handle
             | None -> false)
            ||
            match t.pending with
            | Some p -> p.scope = scope && p.handle = handle
            | None -> false
          then t, []
          else (
            let ticket = { id = t.serial + 1; scope; handle } in
            ( { t with
                pending = Some ticket
              ; available = Some (scope, handle)
              ; lease = None
              ; serial = ticket.id
              ; status = Placeholder "Opening file"
              }
            , release_file t @ [ Acquire ticket ] ))
        | _ ->
          ( { t with
              pending = None
            ; available = None
            ; lease = None
            ; status = status availability
            }
          , release_file t ))
     | _ -> t, [])
  | Acquired (ticket, result) ->
    if t.pending = Some ticket
    then (
      match result with
      | Some (lease, path) ->
        { t with pending = None; lease = Some { ticket; lease }; status = File path }, []
      | None -> { t with pending = None; status = Placeholder "Unable to open file" }, [])
    else
      ( t
      , (match result, t.lease with
         | Some (lease, _), Some held when held.ticket = ticket && held.lease = lease ->
           []
         | Some (lease, _), _ -> [ Release_file { scope = ticket.scope; lease } ]
         | None, _ -> []) )
  | Retry_requested ->
    (match t.selection with
     | Some selected when managed selected.asset ->
       (match t.available with
        | Some (scope, handle) ->
          let ticket = { id = t.serial + 1; scope; handle } in
          ( { t with
              pending = Some ticket
            ; lease = None
            ; serial = ticket.id
            ; status = Placeholder "Opening file"
            }
          , release_file t @ [ Acquire ticket ] )
        | None ->
          ( { t with status = Placeholder "Waiting for file" }
          , [ Retry
                { graph_generation = selected.graph_generation
                ; asset = selected.asset.uuid
                }
            ] ))
     | _ -> t, [])
;;

let ticket_current t ticket = t.pending = Some ticket
