module Owners = Map.Make (String)
module Drafts = Map.Make (String)
module Path = Lui_navigation.Path

type destination =
  | Journals
  | Favorites

type route =
  | Timeline
  | Detail_loading
  | Detail
  | Missing_detail
  | Failed_detail of string

type detail_route = string

type view =
  | Timeline_view
  | Detail_loading_view of
      { block_id : string
      ; request_generation : int64
      ; session_number : int64
      ; draft_owner : string option
      }
  | Detail_view of
      { block_id : string
      ; request_generation : int64
      ; detail : Journal_detail.t
      }
  | Failed_detail_view of
      { block_id : string
      ; request_generation : int64
      ; message : string
      }
  | Missing_detail_view of
      { block_id : string
      ; request_generation : int64
      }

type detached =
  { block_id : string
  ; rank : int64
  ; composer : Journal_detail.retained_composer
  }

type t =
  { destination : destination
  ; path : detail_route Path.t
  ; owners : view Owners.t
  ; focus : string option
  ; next_session : int64
  ; next_retained : int64
  ; drafts : detached Drafts.t
  }

let create () =
  { destination = Journals
  ; path = Path.empty
  ; owners = Owners.empty
  ; focus = None
  ; next_session = 1L
  ; next_retained = 1L
  ; drafts = Drafts.empty
  }
;;

let destination t = t.destination

let select_destination t destination =
  if t.destination = destination then t else { t with destination }
;;

let path t = t.path

let active_entry_id t =
  match t.focus with
  | Some id -> Some id
  | None ->
    Option.map
      (fun (entry : detail_route Lui_navigation.entry) -> entry.id)
      (List.nth_opt (List.rev (Path.entries t.path)) 0)
;;

let at_entry t ~entry_id =
  if Owners.mem entry_id t.owners then Some { t with focus = Some entry_id } else None
;;

let current_view t =
  Option.bind (active_entry_id t) (fun id -> Owners.find_opt id t.owners)
  |> Option.value ~default:Timeline_view
;;

let view_route = function
  | Timeline_view -> Timeline
  | Detail_loading_view _ -> Detail_loading
  | Detail_view _ -> Detail
  | Missing_detail_view _ -> Missing_detail
  | Failed_detail_view { message; _ } -> Failed_detail message
;;

let route t = view_route (current_view t)

let view_block_id = function
  | Timeline_view -> None
  | Detail_loading_view { block_id; _ }
  | Detail_view { block_id; _ }
  | Failed_detail_view { block_id; _ }
  | Missing_detail_view { block_id; _ } -> Some block_id
;;

let view_generation = function
  | Timeline_view -> 0L
  | Detail_loading_view { request_generation; _ }
  | Detail_view { request_generation; _ }
  | Failed_detail_view { request_generation; _ }
  | Missing_detail_view { request_generation; _ } -> request_generation
;;

let detail_block_id t = view_block_id (current_view t)
let detail_request_generation t = view_generation (current_view t)

let detail t =
  match current_view t with
  | Detail_view { detail; _ } -> Some detail
  | _ -> None
;;

let track_detail_session t detail =
  let session =
    match Journal_detail.child_capture detail with
    | None -> Journal_detail.session_id detail
    | Some capture -> Journal_capture.session_id capture
  in
  let next_session =
    Int64.max
      t.next_session
      (Int64.succ (Journal_ids.Text_input.Session_id.to_int64 session))
  in
  if next_session = t.next_session then t else { t with next_session }
;;

let retain_owner t owner_id =
  match Owners.find_opt owner_id t.owners with
  | Some (Detail_view { block_id; detail; _ }) ->
    let t = track_detail_session t detail in
    (match Journal_detail.retain_composer detail with
     | None -> { t with drafts = Drafts.remove owner_id t.drafts }
     | Some composer ->
       { t with
         drafts =
           Drafts.add owner_id { block_id; composer; rank = t.next_retained } t.drafts
       ; next_retained = Int64.succ t.next_retained
       })
  | _ -> t
;;

let retain_live_composers t =
  List.fold_left
    (fun t (entry : detail_route Lui_navigation.entry) -> retain_owner t entry.id)
    t
    (Path.entries t.path)
;;

type retained_drafts =
  { composers : detached Drafts.t
  ; next_editor_session : int64
  ; next_rank : int64
  }

let retained_attachments retained =
  Drafts.fold
    (fun _ draft items ->
       List.rev_append (Journal_detail.retained_attachments draft.composer) items)
    retained.composers
    []
;;

let pending_attachments t =
  let items =
    Drafts.fold
      (fun _ draft items ->
         List.rev_append (Journal_detail.retained_attachments draft.composer) items)
      t.drafts
      []
  in
  Owners.fold
    (fun _ view items ->
       match view with
       | Detail_view { detail; _ } ->
         Option.fold
           ~none:items
           ~some:(fun capture ->
             List.rev_append (Journal_capture.pending_attachments capture) items)
           (Journal_detail.child_capture detail)
       | _ -> items)
    t.owners
    items
;;

let child_attachment_imports t ~child ~parent =
  let found =
    Drafts.fold
      (fun _ draft found ->
         match found with
         | Some _ -> found
         | None ->
           Journal_detail.retained_attachment_imports draft.composer ~child ~parent)
      t.drafts
      None
  in
  Owners.fold
    (fun _ view found ->
       match found, view with
       | None, Detail_view { detail; _ } ->
         Journal_detail.child_attachment_imports detail ~child ~parent
       | _ -> found)
    t.owners
    found
;;

let retain_drafts ~interrupted t =
  let t = retain_live_composers t in
  { composers =
      (if interrupted
       then
         Drafts.map
           (fun draft ->
              { draft with
                composer = Journal_detail.interrupt_retained_composer draft.composer
              })
           t.drafts
       else t.drafts)
  ; next_editor_session = t.next_session
  ; next_rank = t.next_retained
  }
;;

let restore_drafts t retained =
  { t with
    drafts = retained.composers
  ; next_session = Int64.max t.next_session retained.next_editor_session
  ; next_retained = Int64.max t.next_retained retained.next_rank
  }
;;

let latest_detached t block_id =
  Drafts.fold
    (fun id (draft : detached) found ->
       if draft.block_id <> block_id
       then found
       else (
         match found with
         | Some (_, old) when old.rank >= draft.rank -> found
         | _ -> Some (id, draft)))
    t.drafts
    None
;;

let open_detail t ~block_id ~request_generation =
  let t =
    Owners.fold
      (fun _ view t ->
         match view with
         | Detail_view { detail; _ } -> track_detail_session t detail
         | _ -> t)
      t.owners
      t
  in
  let has_live =
    Owners.exists (fun _ view -> view_block_id view = Some block_id) t.owners
  in
  let draft_owner =
    if has_live then None else Option.map fst (latest_detached t block_id)
  in
  let path = Path.push block_id t.path in
  let owner_id = (List.hd (List.rev (Path.entries path))).id in
  let session_number = Int64.max t.next_session (Int64.succ request_generation) in
  { t with
    path
  ; focus = None
  ; next_session = Int64.succ session_number
  ; owners =
      Owners.add
        owner_id
        (Detail_loading_view { block_id; request_generation; session_number; draft_owner })
        t.owners
  }
;;

let open_favorite
      t
      ~request_generation
      (item : Logseq_db_worker.Protocol.v2_favorite_item)
  =
  match item.target with
  | V2_favorite_page _ -> t, None
  | V2_favorite_block { uuid; _ } ->
    let block_id = Logseq_db_types.Graph_types.Uuid.to_string uuid in
    ( open_detail t ~block_id ~request_generation
    , Some
        (Journal_graph_request.Load_detail
           { block_id; after = None; limit = 64; request_generation }) )
;;

let update_detail_at t ~entry_id detail =
  match Owners.find_opt entry_id t.owners with
  | Some (Detail_view owner) when owner.detail == detail -> t
  | Some (Detail_view owner) ->
    let t = track_detail_session t detail in
    { t with owners = Owners.add entry_id (Detail_view { owner with detail }) t.owners }
  | _ -> t
;;

let update_detail t detail =
  match active_entry_id t with
  | None -> t
  | Some entry_id -> update_detail_at t ~entry_id detail
;;

let map_details t ~f =
  Owners.fold
    (fun entry_id view t ->
       match view with
       | Detail_view { detail; _ } -> update_detail_at t ~entry_id (f detail)
       | _ -> t)
    t.owners
    t
;;

let apply_detail_response t ~request_generation projection =
  Owners.fold
    (fun entry_id view t ->
       match view with
       | Detail_loading_view loading
         when loading.request_generation = request_generation
              && loading.block_id
                 = Journal_model.id projection.Journal_graph_projection.root ->
         let detail =
           Journal_detail.create ~session_number:loading.session_number projection
         in
         let draft =
           Option.bind loading.draft_owner (fun id -> Drafts.find_opt id t.drafts)
         in
         let detail =
           match draft with
           | None -> detail
           | Some draft -> Journal_detail.restore_composer detail draft.composer
         in
         let t = track_detail_session t detail in
         { t with
           drafts =
             (match loading.draft_owner with
              | None -> t.drafts
              | Some id -> Drafts.remove id t.drafts)
         ; owners =
             Owners.add
               entry_id
               (Detail_view { block_id = loading.block_id; request_generation; detail })
               t.owners
         }
       | Detail_view { detail; _ } ->
         let next, _ =
           Journal_detail.step detail (Loaded (request_generation, projection))
         in
         update_detail_at t ~entry_id next
       | _ -> t)
    t.owners
    t
;;

let apply_detail_failure
      ?block_id
      ?(stale_cursor = false)
      t
      ~request_generation
      ~missing
      ~message
  =
  Owners.fold
    (fun entry_id view t ->
       match view with
       | Detail_loading_view loading
         when loading.request_generation = request_generation
              && (block_id = None || block_id = Some loading.block_id) ->
         let view =
           if missing
           then Missing_detail_view { block_id = loading.block_id; request_generation }
           else
             Failed_detail_view
               { block_id = loading.block_id; request_generation; message }
         in
         { t with owners = Owners.add entry_id view t.owners }
       | Detail_view { detail; _ } ->
         let next, _ =
           Journal_detail.step
             detail
             (Load_failed (request_generation, stale_cursor, message))
         in
         if next = detail then t else update_detail_at t ~entry_id next
       | _ -> t)
    t.owners
    t
;;

let apply_missing_detail t ~request_generation =
  apply_detail_failure t ~request_generation ~missing:true ~message:"Block unavailable"
;;

let apply_child_created t ~child ~parent =
  let drafts =
    Drafts.filter_map
      (fun _ draft ->
         Option.map
           (fun composer -> { draft with composer })
           (Journal_detail.complete_retained_composer draft.composer ~child ~parent))
      t.drafts
  in
  let t = if drafts = t.drafts then t else { t with drafts } in
  map_details t ~f:(fun detail ->
    Journal_detail.apply_child_created detail ~child ~parent)
;;

let apply_child_failure t ~block_id ~message =
  let drafts =
    Drafts.map
      (fun draft ->
         let composer =
           Journal_detail.fail_retained_composer draft.composer ~block_id ~message
         in
         if composer == draft.composer then draft else { draft with composer })
      t.drafts
  in
  let t = if drafts = t.drafts then t else { t with drafts } in
  map_details t ~f:(fun detail ->
    fst (Journal_detail.step detail (Append_failed (block_id, message))))
;;

let accept_path t path =
  let original = Path.entries t.path
  and next = Path.entries path in
  let rec prefix before after =
    match before, after with
    | _, [] -> true
    | ( (a : detail_route Lui_navigation.entry) :: rest
      , (b : detail_route Lui_navigation.entry) :: tail )
      when a.id = b.id -> prefix rest tail
    | _ -> false
  in
  if not (prefix original next)
  then t
  else if List.length original = List.length next
  then t
  else (
    let kept =
      List.fold_left
        (fun kept (entry : detail_route Lui_navigation.entry) ->
           Owners.add entry.id Timeline_view kept)
        Owners.empty
        next
    in
    let t =
      List.fold_left
        (fun t (entry : detail_route Lui_navigation.entry) ->
           if Owners.mem entry.id kept
           then t
           else (
             let t = retain_owner t entry.id in
             { t with owners = Owners.remove entry.id t.owners }))
        t
        original
    in
    { t with path; focus = None })
;;

let back t = accept_path t (Path.pop t.path)
let pop_to_root t = accept_path t (Path.pop_to_root t.path)

let retry_detail_at t ~entry_id ~request_generation =
  match Owners.find_opt entry_id t.owners with
  | None | Some Timeline_view -> t, None
  | Some view ->
    let block_id = Option.get (view_block_id view) in
    let t = retain_owner t entry_id in
    let session_number = Int64.max t.next_session (Int64.succ request_generation) in
    let draft_owner =
      if Drafts.mem entry_id t.drafts
      then Some entry_id
      else (
        match view with
        | Detail_loading_view loading -> loading.draft_owner
        | _ -> None)
    in
    ( { t with
        owners =
          Owners.add
            entry_id
            (Detail_loading_view
               { block_id; request_generation; session_number; draft_owner })
            t.owners
      ; next_session = Int64.succ session_number
      ; focus = None
      }
    , Some
        (Journal_graph_request.Load_detail
           { block_id; after = None; limit = 64; request_generation }) )
;;

let retry_detail t ~request_generation =
  match active_entry_id t with
  | None -> t, None
  | Some entry_id -> retry_detail_at t ~entry_id ~request_generation
;;

let background t = t
let graph_unavailable t = restore_drafts (create ()) (retain_drafts ~interrupted:true t)

let runtime_replaced t =
  let generation =
    Owners.fold (fun _ view n -> Int64.max n (view_generation view)) t.owners 0L
  in
  let t, _ =
    List.fold_left
      (fun (t, generation) (entry : detail_route Lui_navigation.entry) ->
         let generation = Int64.succ generation in
         let next, _ =
           retry_detail_at t ~entry_id:entry.id ~request_generation:generation
         in
         next, generation)
      (t, generation)
      (Path.entries t.path)
  in
  t
;;

type staged_delete = (string * int64 * view * Journal_detail.staged_delete) list

let stage_delete t ~block_id =
  (* A missing root no longer carries its composer. Preserve it before changing
     phase, in path order, so pop/Undo cannot lose an independent pending draft. *)
  let t =
    List.fold_left
      (fun t (entry : detail_route Lui_navigation.entry) ->
         match Owners.find_opt entry.id t.owners with
         | Some (Detail_view owner)
           when Journal_model.id (Journal_detail.root owner.detail) = block_id ->
           retain_owner t entry.id
         | _ -> t)
      t
      (Path.entries t.path)
  in
  let t, staged =
    Owners.fold
      (fun entry_id view (t, staged) ->
         match view with
         | Detail_view owner ->
           (match Journal_detail.stage_delete owner.detail ~block_id with
            | None -> t, staged
            | Some (hidden, undo) ->
              let next =
                if Journal_model.id (Journal_detail.root owner.detail) = block_id
                then
                  Missing_detail_view
                    { block_id = owner.block_id
                    ; request_generation = owner.request_generation
                    }
                else Detail_view { owner with detail = hidden }
              in
              ( { t with owners = Owners.add entry_id next t.owners }
              , (entry_id, owner.request_generation, view, undo) :: staged ))
         | _ -> t, staged)
      t.owners
      (t, [])
  in
  t, if staged = [] then None else Some staged
;;

let undo_delete t staged =
  List.fold_left
    (fun t (entry_id, generation, before, undo) ->
       match Owners.find_opt entry_id t.owners with
       | Some (Detail_view { detail; _ }) as current
         when Option.fold
                ~none:false
                ~some:(fun view -> view_generation view = generation)
                current ->
         update_detail_at t ~entry_id (Journal_detail.undo_delete detail undo)
       | Some (Missing_detail_view owner) when owner.request_generation = generation ->
         { t with
           owners = Owners.add entry_id before t.owners
         ; drafts = Drafts.remove entry_id t.drafts
         }
       | _ -> t)
    t
    staged
;;

module Favorites = struct
  module P = Logseq_db_worker.Protocol
  module G = Logseq_db_types.Graph_types

  type event =
    | Select of bool
    | Invalidate
    | Hide_target of string
    | Reveal_target of string
    | Retry
    | Visible of
        { first_index : int
        ; last_exclusive : int
        }
    | Loaded of Journal_graph_request.favorites_request * P.v2_favorites_result
    | Failed of Journal_graph_request.favorites_request * bool * string

  type t =
    { graph_generation : int
    ; next_request : int64
    ; revision : int
    ; active : bool
    ; dirty : bool
    ; initialized : bool
    ; items : P.v2_favorite_item list
    ; hidden_targets : string list
    ; cursor : G.Cursor.t option
    ; pending : Journal_graph_request.favorites_request option
    ; error : string option
    ; staging : P.v2_favorite_item list option
    ; refresh_count : int
    }

  let create ~graph_generation =
    { graph_generation
    ; next_request = 1L
    ; revision = 0
    ; active = false
    ; dirty = true
    ; initialized = false
    ; items = []
    ; hidden_targets = []
    ; cursor = None
    ; pending = None
    ; error = None
    ; staging = None
    ; refresh_count = 0
    }
  ;;

  let revision t = t.revision

  let visible_items t =
    List.filter
      (fun (item : P.v2_favorite_item) ->
         match item.target with
         | V2_favorite_page _ -> true
         | V2_favorite_block { uuid; _ } ->
           not (List.mem (G.Uuid.to_string uuid) t.hidden_targets))
      t.items
  ;;

  let items = visible_items
  let loading t = Option.is_some t.pending
  let error t = t.error
  let initialized t = t.initialized
  let has_more t = Option.is_some t.cursor

  let request t cursor =
    let request : Journal_graph_request.favorites_request =
      { graph_generation = t.graph_generation
      ; request_generation = t.next_request
      ; limit = 50
      ; cursor
      }
    in
    ( { t with
        pending = Some request
      ; next_request = Int64.succ t.next_request
      ; error = None
      }
    , [ request ] )
  ;;

  let refresh t =
    request
      { t with dirty = false; staging = Some []; refresh_count = List.length t.items }
      None
  ;;

  let current t (request : Journal_graph_request.favorites_request) =
    request.graph_generation = t.graph_generation && t.pending = Some request
  ;;

  let start_if_needed t =
    if (not t.active) || t.pending <> None || t.error <> None
    then t, []
    else if t.dirty || not t.initialized
    then refresh t
    else if t.cursor <> None && visible_items t = []
    then request t t.cursor
    else t, []
  ;;

  let step t = function
    | Select active -> start_if_needed { t with active }
    | Invalidate -> start_if_needed { t with dirty = true }
    | Hide_target id ->
      if List.mem id t.hidden_targets
      then t, []
      else (
        let next =
          { t with hidden_targets = id :: t.hidden_targets; revision = t.revision + 1 }
        in
        start_if_needed next)
    | Reveal_target id ->
      if not (List.mem id t.hidden_targets)
      then t, []
      else
        ( { t with
            hidden_targets = List.filter (( <> ) id) t.hidden_targets
          ; revision = t.revision + 1
          }
        , [] )
    | Retry -> if t.pending = None then refresh t else t, []
    | Visible { first_index = _; last_exclusive } ->
      let visible = visible_items t in
      if
        t.active
        && t.pending = None
        && t.error = None
        && last_exclusive + 12 >= List.length visible
      then (
        match t.cursor with
        | None -> t, []
        | Some _ -> request t t.cursor)
      else t, []
    | Loaded (completed, result) when current t completed ->
      let pending = None in
      let staged = Option.value t.staging ~default:t.items @ result.items in
      let needs_continuation =
        match t.staging with
        | Some _ -> List.length staged < max 1 t.refresh_count
        | None -> result.items = []
      in
      let t = { t with pending; cursor = result.next_cursor } in
      if needs_continuation && result.next_cursor <> None
      then request { t with staging = Some staged } result.next_cursor
      else (
        let t =
          { t with
            items = staged
          ; staging = None
          ; initialized = true
          ; error = None
          ; revision = t.revision + 1
          }
        in
        start_if_needed t)
    | Failed (completed, true, _) when current t completed ->
      let t = { t with pending = None; staging = None; dirty = true; cursor = None } in
      if t.active then refresh t else t, []
    | Failed (completed, false, message) when current t completed ->
      { t with pending = None; staging = None; error = Some message; dirty = true }, []
    | Loaded _ | Failed _ -> t, []
  ;;
end
