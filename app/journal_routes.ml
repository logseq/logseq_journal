type destination =
  | Journals
  | Favorites

type anchor =
  { block_id : string option
  ; first_index : int
  }

type route =
  | Timeline
  | Detail_loading
  | Detail
  | Missing_detail

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
  | Missing_detail_view of
      { block_id : string
      ; request_generation : int64
      }

type t =
  { destination : destination
  ; view : view
  ; anchor : anchor
  }

let create ~anchor = { destination = Journals; view = Timeline_view; anchor }
let destination t = t.destination
let select_destination t destination = { t with destination }

let route t =
  match t.view with
  | Timeline_view -> Timeline
  | Detail_loading_view _ -> Detail_loading
  | Detail_view _ -> Detail
  | Missing_detail_view _ -> Missing_detail
;;

let anchor_to_restore t = Some t.anchor
let set_anchor t anchor = { t with anchor }

let open_detail t ~block_id ~request_generation =
  { t with
    view =
      Detail_loading_view
        { block_id; request_generation; session_number = Int64.succ request_generation }
  }
;;

let detail_block_id t =
  match t.view with
  | Detail_loading_view { block_id; _ }
  | Detail_view { block_id; _ }
  | Missing_detail_view { block_id; _ } -> Some block_id
  | Timeline_view -> None
;;

let detail_request_generation t =
  match t.view with
  | Detail_loading_view { request_generation; _ }
  | Detail_view { request_generation; _ }
  | Missing_detail_view { request_generation; _ } -> request_generation
  | Timeline_view -> 0L
;;

let apply_detail_response t ~request_generation detail =
  match t.view with
  | Detail_loading_view loading
    when Int64.equal request_generation loading.request_generation ->
    { t with
      view =
        Detail_view
          { block_id = loading.block_id
          ; request_generation
          ; detail = Journal_detail.create ~session_number:loading.session_number detail
          }
    }
  | Timeline_view | Detail_loading_view _ | Detail_view _ | Missing_detail_view _ -> t
;;

let apply_missing_detail t ~request_generation =
  match t.view with
  | Detail_loading_view loading
    when Int64.equal request_generation loading.request_generation ->
    { t with
      view = Missing_detail_view { block_id = loading.block_id; request_generation }
    }
  | Timeline_view | Detail_loading_view _ | Detail_view _ | Missing_detail_view _ -> t
;;

let detail t =
  match t.view with
  | Detail_view { detail; _ } -> Some detail
  | Timeline_view | Detail_loading_view _ | Missing_detail_view _ -> None
;;

let update_detail t detail =
  match t.view with
  | Detail_view view -> { t with view = Detail_view { view with detail } }
  | Timeline_view | Detail_loading_view _ | Missing_detail_view _ -> t
;;

let back t =
  match t.view with
  | Timeline_view -> t
  | Detail_loading_view _ | Missing_detail_view _ -> { t with view = Timeline_view }
  | Detail_view view ->
    (match Journal_detail.request_back view.detail with
     | `Close -> { t with view = Timeline_view }
     | `State detail -> { t with view = Detail_view { view with detail } })
;;

let keep_editing t =
  match t.view with
  | Detail_view view ->
    { t with
      view = Detail_view { view with detail = Journal_detail.keep_editing view.detail }
    }
  | Timeline_view | Detail_loading_view _ | Missing_detail_view _ -> t
;;

let discard t =
  match t.view with
  | Detail_view view ->
    { t with
      view = Detail_view { view with detail = Journal_detail.discard_edit view.detail }
    }
  | Timeline_view | Detail_loading_view _ | Missing_detail_view _ -> t
;;

let background t = t
let graph_unavailable _t = create ~anchor:{ block_id = None; first_index = 0 }

let runtime_replaced t =
  match t.view with
  | Detail_view view ->
    { t with
      view =
        Detail_loading_view
          { block_id = view.block_id
          ; request_generation = Int64.succ view.request_generation
          ; session_number =
              Int64.succ
                (Bonsai_flutter_spec.Id.Text_input.Session_id.to_int64
                   (Journal_detail.session_id view.detail))
          }
    }
  | Timeline_view | Detail_loading_view _ | Missing_detail_view _ -> t
;;

module Favorites = struct
  module P = Logseq_db_worker.Protocol
  module G = Logseq_db_types.Graph_types

  type event =
    | Select of bool
    | Invalidate
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
    ; cursor : G.Cursor.t option
    ; pending : Journal_graph_request.favorites_request option
    ; error : string option
    ; anchor : anchor
    ; last_exclusive : int
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
    ; cursor = None
    ; pending = None
    ; error = None
    ; anchor = { block_id = None; first_index = 0 }
    ; last_exclusive = 20
    ; staging = None
    ; refresh_count = 0
    }
  ;;

  let revision t = t.revision
  let items t = t.items
  let loading t = Option.is_some t.pending
  let error t = t.error
  let initialized t = t.initialized
  let anchor t = t.anchor
  let has_more t = Option.is_some t.cursor

  let window t =
    let first = max 0 (t.anchor.first_index - 12) in
    ( first
    , t.items
      |> List.to_seq
      |> Seq.drop first
      |> Seq.take (min 128 (max 64 (t.last_exclusive - first + 12)))
      |> List.of_seq )
  ;;

  let key (item : P.v2_favorite_item) = G.Uuid.to_string item.membership_uuid

  let reconcile_anchor t items =
    let surviving id = List.exists (fun item -> key item = id) items in
    let id =
      match t.anchor.block_id with
      | Some id when surviving id -> Some id
      | _ ->
        let after =
          t.items |> List.to_seq |> Seq.drop t.anchor.first_index |> List.of_seq
        in
        let before =
          t.items
          |> List.to_seq
          |> Seq.take t.anchor.first_index
          |> List.of_seq
          |> List.rev
        in
        List.find_opt (fun item -> surviving (key item)) (after @ before)
        |> Option.map key
    in
    let index =
      match id with
      | Some id ->
        List.find_index (fun item -> key item = id) items |> Option.value ~default:0
      | None -> min t.anchor.first_index (max 0 (List.length items - 1))
    in
    { first_index = index; block_id = Option.map key (List.nth_opt items index) }
  ;;

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
    if t.active && t.pending = None && t.error = None && (t.dirty || not t.initialized)
    then refresh t
    else t, []
  ;;

  let step t = function
    | Select active -> start_if_needed { t with active }
    | Invalidate -> start_if_needed { t with dirty = true }
    | Retry -> if t.pending = None then refresh t else t, []
    | Visible { first_index; last_exclusive } ->
      let first_index = max 0 (min first_index (max 0 (List.length t.items - 1))) in
      let anchor =
        { first_index; block_id = Option.map key (List.nth_opt t.items first_index) }
      in
      let t = { t with anchor; last_exclusive = max first_index last_exclusive } in
      if
        t.active
        && t.pending = None
        && t.error = None
        && last_exclusive + 12 >= List.length t.items
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
        let anchor = reconcile_anchor t staged in
        let t =
          { t with
            items = staged
          ; staging = None
          ; initialized = true
          ; anchor
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
