type hooks =
  { init : int -> int -> string -> string
  ; dispatch : Lui_protocol.event -> string
  ; extension_event : int -> string -> string -> string
  ; pump : unit -> string
  ; platform_event : string -> unit
  ; platform_response : string -> unit
  ; platform_failure : string -> unit
  ; dispose : unit -> string
  ; root_node : unit -> int
  }

external wakeup : unit -> unit = "journal_ml_wakeup"
external platform_request : string -> unit = "journal_ml_platform_request"

let current : hooks option ref = ref None

let hooks () =
  match !current with
  | Some hooks -> hooks
  | None -> invalid_arg "Journal_bridge.register was not called"
;;

let initialize platform_code host_code payload =
  (hooks ()).init platform_code host_code payload
;;

let dispatch_lui event = (hooks ()).dispatch event
let appear node = dispatch_lui (Lui_protocol.Appear node)
let press node = dispatch_lui (Lui_protocol.Press node)
let long_press node = dispatch_lui (Lui_protocol.LongPress node)
let text_changed node text = dispatch_lui (Lui_protocol.TextChanged (node, text))
let submit node = dispatch_lui (Lui_protocol.Submit node)
let dismiss node = dispatch_lui (Lui_protocol.Dismiss node)
let double_press node = dispatch_lui (Lui_protocol.DoublePress node)

let toggle_changed node checked =
  dispatch_lui (Lui_protocol.ToggleChanged (node, checked))
;;

let radio_changed node = dispatch_lui (Lui_protocol.Change node)
let slider_changed node value = dispatch_lui (Lui_protocol.ValueChanged (node, value))
let extension_event node name payload = (hooks ()).extension_event node name payload
let pump () = (hooks ()).pump ()
let platform_event payload = (hooks ()).platform_event payload
let platform_response payload = (hooks ()).platform_response payload
let platform_failure payload = (hooks ()).platform_failure payload
let dispose () = (hooks ()).dispose ()
let root_node () = (hooks ()).root_node ()

let register hooks =
  current := Some hooks;
  Callback.register "lui_ocaml_init" initialize;
  Callback.register "lui_ocaml_appear" appear;
  Callback.register "lui_ocaml_press" press;
  Callback.register "lui_ocaml_long_press" long_press;
  Callback.register "lui_ocaml_text_changed" text_changed;
  Callback.register "lui_ocaml_submit" submit;
  Callback.register "lui_ocaml_dismiss" dismiss;
  Callback.register "lui_ocaml_double_press" double_press;
  Callback.register "lui_ocaml_toggle_changed" toggle_changed;
  Callback.register "lui_ocaml_radio_changed" radio_changed;
  Callback.register "lui_ocaml_slider_changed" slider_changed;
  Callback.register "lui_ocaml_dispose" dispose;
  Callback.register "lui_ocaml_root_node" root_node;
  Callback.register "journal_ocaml_extension_event" extension_event;
  Callback.register "journal_ocaml_pump" pump;
  Callback.register "journal_ocaml_platform_event" platform_event;
  Callback.register "journal_ocaml_platform_response" platform_response;
  Callback.register "journal_ocaml_platform_failure" platform_failure
;;
