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
  { view : view
  ; anchor : anchor
  }

let create ~anchor = { view = Timeline_view; anchor }

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
let graph_unavailable t = { t with view = Timeline_view }

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
