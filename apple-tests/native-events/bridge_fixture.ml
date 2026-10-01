(* ABI ownership is in the host adapter, not the pure application reducer.
   These public hooks observe exactly what crossed the production C boundary. *)
open Lui_protocol

let patch node text =
  Gc.full_major ();
  Lui_wire.encode_batch
    { generation = 1; ops = [ SetProp (node, TextValue, StringValue text) ] }
;;

let dispatch = function
  | Appear node -> patch node "appear"
  | Press node -> patch node "press"
  | LongPress node -> patch node "longPress"
  | TextChanged (_, "raise") -> failwith "native event fixture rejection"
  | TextChanged (node, text) -> patch node ("textChanged:" ^ text)
  | Submit node -> patch node "submit"
  | Dismiss node -> patch node "dismiss"
  | DoublePress node -> patch node "doublePress"
  | ToggleChanged (node, checked) -> patch node ("toggleChanged:" ^ string_of_bool checked)
  | Change node -> patch node "change"
  | ValueChanged (node, value) -> patch node ("valueChanged:" ^ string_of_float value)
  | ScrollCompleted (node, token, outcome) ->
    patch node (Printf.sprintf "scrollCompleted:%d:%s" token outcome)
  | VisibleRange (node, first, last) ->
    patch node (Printf.sprintf "visibleRange:%d:%d" first last)
  | Picked (node, payload) -> patch node ("picked:" ^ payload)
  | ExtensionEvent _ -> failwith "extension bypassed its host hook"
;;

let () =
  Journal_bridge.register
    { init = (fun _ _ _ -> "")
    ; dispatch
    ; extension_event =
        (fun node name payload -> patch node ("extension:" ^ name ^ ":" ^ payload))
    ; pump = (fun () -> "")
    ; platform_event = (fun _ -> ())
    ; platform_response = (fun _ -> ())
    ; platform_failure = (fun _ -> ())
    ; dispose = (fun () -> "")
    ; root_node = (fun () -> 0)
    }
;;
