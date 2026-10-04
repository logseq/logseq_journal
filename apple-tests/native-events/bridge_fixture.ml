(* ABI ownership is in the host adapter, not the pure application reducer.
   These public hooks observe exactly what crossed the production C boundary. *)
open Lui_protocol

let pending_platform = ref None
let allocating = Atomic.make false
let worker = ref None

let start_worker () =
  Atomic.set allocating true;
  worker := Some (Domain.spawn (fun () ->
    while Atomic.get allocating do
      ignore (Sys.opaque_identity (Array.make 1024 "worker allocation"));
      Gc.minor ()
    done))
;;

let stop_worker () =
  Atomic.set allocating false;
  Option.iter Domain.join !worker;
  worker := None
;;

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
    { init = (fun _ _ _ -> start_worker (); patch 42 "init")
    ; dispatch
    ; extension_event =
        (fun node name payload -> patch node ("extension:" ^ name ^ ":" ^ payload))
    ; pump = (fun () ->
        let text = Option.fold ~none:"pump" ~some:(fun bytes ->
          let buffer = Buffer.create (String.length bytes * 2) in
          String.iter (fun byte -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte))) bytes;
          "platform:" ^ Buffer.contents buffer) !pending_platform in
        pending_platform := None;
        patch 42 text)
    ; platform_event = (fun bytes -> pending_platform := Some bytes)
    ; platform_response = (fun bytes -> pending_platform := Some bytes)
    ; platform_failure = (fun bytes -> pending_platform := Some bytes)
    ; dispose = (fun () -> stop_worker (); patch 42 "dispose")
    ; root_node = (fun () -> 42)
    }
;;
