type lifecycle =
  | Running
  | Closing
  | Closed

type t =
  { lifecycle : lifecycle
  ; close_called : bool
  }

type close_error =
  | Reentrant
  | Already_called

let initial = { lifecycle = Running; close_called = false }
let lifecycle state = state.lifecycle

let request_close ~inside_callback state =
  if inside_callback
  then Error Reentrant
  else if state.close_called
  then Error Already_called
  else
    Ok
      { lifecycle =
          (match state.lifecycle with
           | Running | Closing -> Closing
           | Closed -> Closed)
      ; close_called = true
      }
;;

let begin_cleanup state = { state with lifecycle = Closing }
let complete state = { state with lifecycle = Closed }
