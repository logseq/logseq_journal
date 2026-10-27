type observation =
  | Unavailable
  | Loading
  | Available of Logseq_db_worker.Protocol.v2_admission_inspection

type result =
  | Inspected of Logseq_db_worker.Protocol.v2_admission_inspection
  | Inspection_unavailable

type directive =
  | No_request
  | Request of Journal_graph_request.admission_request

type t =
  { open_ : bool
  ; graph_generation : int option
  ; in_flight : Journal_graph_request.admission_request option
  ; pending : bool
  ; observation : observation
  ; next_request_generation : int64
  }

let closed =
  { open_ = false
  ; graph_generation = None
  ; in_flight = None
  ; pending = false
  ; observation = Unavailable
  ; next_request_generation = 1L
  }
;;

let request state graph_generation observation =
  let request : Journal_graph_request.admission_request =
    { graph_generation; request_generation = state.next_request_generation }
  in
  ( { open_ = true
    ; graph_generation = Some graph_generation
    ; in_flight = Some request
    ; pending = false
    ; observation
    ; next_request_generation = Int64.succ state.next_request_generation
    }
  , Request request )
;;

let unavailable state ~open_ graph_generation =
  { state with
    open_
  ; graph_generation = Some graph_generation
  ; in_flight = None
  ; pending = false
  ; observation = Unavailable
  }
;;

let open_ state ~graph_generation ~graph_open =
  if graph_open
  then request state graph_generation Loading
  else unavailable state ~open_:true graph_generation, No_request
;;

let trigger state ~graph_generation ~graph_open =
  if not state.open_
  then state, No_request
  else if not graph_open
  then unavailable state ~open_:true graph_generation, No_request
  else if state.graph_generation <> Some graph_generation
  then request state graph_generation Loading
  else if Option.is_some state.in_flight
  then { state with pending = true }, No_request
  else (
    let observation =
      match state.observation with
      | Available _ as available -> available
      | Unavailable | Loading -> Loading
    in
    request state graph_generation observation)
;;

let complete state ~request:completed ~result =
  if (not state.open_) || state.in_flight <> Some completed
  then state, No_request
  else (
    let observation =
      match result with
      | Inspected inspection -> Available inspection
      | Inspection_unavailable -> Unavailable
    in
    if state.pending
    then request state completed.graph_generation observation
    else { state with in_flight = None; observation }, No_request)
;;

let close state =
  { closed with next_request_generation = state.next_request_generation }
;;

let observation state = state.observation
