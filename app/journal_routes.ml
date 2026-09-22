module Drafts = Map.Make (String)

type destination =
  | Journals
  | Favorites

type route =
  | Timeline
  | Detail_loading
  | Detail
  | Missing_detail
  | Failed_detail of string

type view =
  | Timeline_view
  | Detail_loading_view of
      { block_id : string
      ; request_generation : int64
      ; session_number : int64
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

type t =
  { destination : destination
  ; view : view
  ; next_session : int64
  ; drafts : Journal_detail.retained_composer Drafts.t
  }

let create () =
  { destination = Journals
  ; view = Timeline_view
  ; next_session = 1L
  ; drafts = Drafts.empty
  }
;;

let destination t = t.destination
let select_destination t destination = { t with destination }

let route t =
  match t.view with
  | Timeline_view -> Timeline
  | Detail_loading_view _ -> Detail_loading
  | Detail_view _ -> Detail
  | Missing_detail_view _ -> Missing_detail
  | Failed_detail_view { message; _ } -> Failed_detail message
;;

let track_detail_session t detail =
  let session =
    match Journal_detail.child_capture detail with
    | None -> Journal_detail.session_id detail
    | Some capture -> Journal_capture.session_id capture
  in
  { t with
    next_session =
      Int64.max
        t.next_session
        (Int64.succ (Bonsai_swiftui_spec.Id.Text_input.Session_id.to_int64 session))
  }
;;

let retain_active_composer t =
  match t.view with
  | Detail_view { block_id; detail; _ } ->
    let t = track_detail_session t detail in
    { t with
      drafts =
        (match Journal_detail.retain_composer detail with
         | None -> Drafts.remove block_id t.drafts
         | Some draft -> Drafts.add block_id draft t.drafts)
    }
  | Timeline_view | Detail_loading_view _ | Failed_detail_view _ | Missing_detail_view _
    -> t
;;

type retained_drafts =
  { composers : Journal_detail.retained_composer Drafts.t
  ; next_editor_session : int64
  }

let retain_drafts ~interrupted t =
  let t = retain_active_composer t in
  { composers =
      (if interrupted
       then Drafts.map Journal_detail.interrupt_retained_composer t.drafts
       else t.drafts)
  ; next_editor_session = t.next_session
  }
;;

let restore_drafts t retained =
  { t with
    drafts = retained.composers
  ; next_session = Int64.max t.next_session retained.next_editor_session
  }
;;

let open_detail t ~block_id ~request_generation =
  let t = retain_active_composer t in
  let session_number = Int64.max t.next_session (Int64.succ request_generation) in
  { t with
    next_session = Int64.succ session_number
  ; view = Detail_loading_view { block_id; request_generation; session_number }
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
    let t = open_detail t ~block_id ~request_generation in
    ( t
    , Some
        (Journal_graph_request.Load_detail
           { block_id; after = None; limit = 64; request_generation }) )
;;

let detail_block_id t =
  match t.view with
  | Detail_loading_view { block_id; _ }
  | Detail_view { block_id; _ }
  | Failed_detail_view { block_id; _ }
  | Missing_detail_view { block_id; _ } -> Some block_id
  | Timeline_view -> None
;;

let detail_request_generation t =
  match t.view with
  | Detail_loading_view { request_generation; _ }
  | Detail_view { request_generation; _ }
  | Failed_detail_view { request_generation; _ }
  | Missing_detail_view { request_generation; _ } -> request_generation
  | Timeline_view -> 0L
;;

let apply_detail_response t ~request_generation detail =
  match t.view with
  | Detail_loading_view loading
    when Int64.equal request_generation loading.request_generation
         && String.equal
              loading.block_id
              (Journal_model.id detail.Journal_graph_projection.root) ->
    let detail = Journal_detail.create ~session_number:loading.session_number detail in
    let detail =
      match Drafts.find_opt loading.block_id t.drafts with
      | None -> detail
      | Some draft -> Journal_detail.restore_composer detail draft
    in
    { t with
      drafts = Drafts.remove loading.block_id t.drafts
    ; view = Detail_view { block_id = loading.block_id; request_generation; detail }
    }
  | Timeline_view
  | Detail_loading_view _
  | Detail_view _
  | Failed_detail_view _
  | Missing_detail_view _ -> t
;;

let apply_missing_detail t ~request_generation =
  match t.view with
  | Detail_loading_view loading
    when Int64.equal request_generation loading.request_generation ->
    { t with
      view = Missing_detail_view { block_id = loading.block_id; request_generation }
    }
  | Timeline_view
  | Detail_loading_view _
  | Detail_view _
  | Failed_detail_view _
  | Missing_detail_view _ -> t
;;

let apply_detail_failure t ~request_generation ~missing ~message =
  if missing
  then apply_missing_detail t ~request_generation
  else (
    match t.view with
    | Detail_loading_view loading when loading.request_generation = request_generation ->
      { t with
        view =
          Failed_detail_view { block_id = loading.block_id; request_generation; message }
      }
    | _ -> t)
;;

let detail t =
  match t.view with
  | Detail_view { detail; _ } -> Some detail
  | Timeline_view | Detail_loading_view _ | Failed_detail_view _ | Missing_detail_view _
    -> None
;;

let update_detail t detail =
  match t.view with
  | Detail_view view ->
    let t = track_detail_session t detail in
    { t with view = Detail_view { view with detail } }
  | Timeline_view | Detail_loading_view _ | Failed_detail_view _ | Missing_detail_view _
    -> t
;;

let apply_child_created t ~child ~parent =
  let parent_id = Journal_model.id parent in
  let drafts =
    Drafts.update
      parent_id
      (fun draft ->
         Option.bind draft (fun draft ->
           Journal_detail.complete_retained_composer draft ~child ~parent))
      t.drafts
  in
  let t = { t with drafts } in
  match detail t with
  | None -> t
  | Some owner ->
    update_detail t (Journal_detail.apply_child_created owner ~child ~parent)
;;

let apply_child_failure t ~block_id ~message =
  let t =
    { t with
      drafts =
        Drafts.map
          (fun draft -> Journal_detail.fail_retained_composer draft ~block_id ~message)
          t.drafts
    }
  in
  match detail t with
  | None -> t
  | Some owner ->
    let owner, _ = Journal_detail.step owner (Append_failed (block_id, message)) in
    update_detail t owner
;;

let back t =
  let t = retain_active_composer t in
  match t.view with
  | Timeline_view -> t
  | Detail_loading_view _ | Failed_detail_view _ | Missing_detail_view _ ->
    { t with view = Timeline_view }
  | Detail_view _ -> { t with view = Timeline_view }
;;

let background t = t
let graph_unavailable t = restore_drafts (create ()) (retain_drafts ~interrupted:true t)

let runtime_replaced t =
  let t = retain_active_composer t in
  match t.view with
  | Detail_view view ->
    { t with
      view =
        Detail_loading_view
          { block_id = view.block_id
          ; request_generation = Int64.succ view.request_generation
          ; session_number =
              Int64.succ
                (Bonsai_swiftui_spec.Id.Text_input.Session_id.to_int64
                   (Journal_detail.session_id view.detail))
          }
    }
  | Timeline_view | Detail_loading_view _ | Failed_detail_view _ | Missing_detail_view _
    -> t
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
