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

let pointer_detail x y modifiers button target_class : Lui_protocol.pointer_detail =
  { x; y; modifiers; button; target_class }
;;

let press_detail node x y modifiers button target_class =
  dispatch_lui (Lui_protocol.PressDetail (node, pointer_detail x y modifiers button target_class))
;;

let pointer_down node x y modifiers button target_class =
  dispatch_lui (Lui_protocol.PointerDown (node, pointer_detail x y modifiers button target_class))
;;

let pointer_up node x y modifiers button target_class =
  dispatch_lui (Lui_protocol.PointerUp (node, pointer_detail x y modifiers button target_class))
;;

let context_menu_press node x y modifiers button target_class =
  dispatch_lui (Lui_protocol.ContextMenuPress (node, pointer_detail x y modifiers button target_class))
;;

let pointer_enter node = dispatch_lui (Lui_protocol.PointerEnter node)
let pointer_leave node = dispatch_lui (Lui_protocol.PointerLeave node)

let text_changed node text = dispatch_lui (Lui_protocol.TextChanged (node, text))
let submit node = dispatch_lui (Lui_protocol.Submit node)
let dismiss node = dispatch_lui (Lui_protocol.Dismiss node)
let double_press node = dispatch_lui (Lui_protocol.DoublePress node)

let toggle_changed node checked =
  dispatch_lui (Lui_protocol.ToggleChanged (node, checked))
;;

let radio_changed node = dispatch_lui (Lui_protocol.Change node)
let slider_changed node value = dispatch_lui (Lui_protocol.ValueChanged (node, value))
let scroll_completed node token outcome =
  dispatch_lui (Lui_protocol.ScrollCompleted (node, token, outcome))
;;

let visible_range node first last =
  dispatch_lui (Lui_protocol.VisibleRange (node, first, last))
;;

let virtual_window node generation first last pins =
  dispatch_lui (Lui_protocol.VirtualWindow (node, generation, first, last, pins))
;;

let picked node payload = dispatch_lui (Lui_protocol.Picked (node, payload))
let extension_event node name payload = (hooks ()).extension_event node name payload
let pump () = (hooks ()).pump ()
let platform_event payload = (hooks ()).platform_event payload
let platform_response payload = (hooks ()).platform_response payload
let platform_failure payload = (hooks ()).platform_failure payload
let dispose () = (hooks ()).dispose ()
let root_node () = (hooks ()).root_node ()

type initialization_stage = Decode_startup | Start_worker | Initialize

(* Stable bounded codes shared with JournalRuntime; zero is an explicit unknown.
   No strings from producers or exceptions are retained by the exception. *)
exception Initialization_failure of initialization_stage * int

let initialization_cause = function
  | "startup payload is truncated" -> 1
  | "startup payload exceeds 1 MiB" -> 2
  | "invalid startup magic" -> 3
  | "startup configuration length is invalid" -> 4
  | "startup payload has trailing or missing bytes" -> 5
  | "startup configuration must be valid UTF-8 JSON" -> 6
  | "invalid startup configuration: application_support_directory must be a bounded canonical absolute path" -> 7
  | "invalid startup configuration: response_budget_bytes is outside the protocol bounds" -> 8
  | "invalid startup configuration: default_page_size is outside the protocol bounds" -> 9
  | "invalid startup configuration: sync base URL must be one HTTPS origin without credentials or fragments" -> 10
  | "worker.start.failure" -> 12
  | "worker.start.invalidArgument" -> 13
  | "worker.start.systemError" -> 14
  | "worker.start.permissionDenied" -> 15
  | "worker.start.missingFile" -> 16
  | "worker.start.noSpace" -> 17
  | "worker.start.busy" -> 18
  | "worker.start.io" -> 19
  | "worker.start.unixError" -> 20
  | "worker.start.outOfMemory" -> 21
  | "worker.start.stackOverflow" -> 22
  | "worker.start.endOfFile" -> 23
  | "worker.start.matchFailure" -> 24
  | "worker.start.assertFailure" -> 25
  | "worker.start.notFound" -> 26
  | "application.mount.failed" -> 27
  | "Worker Domain subsystem is stopped" | "Worker Domain has stopped" -> 28
  | "Worker Domain subsystem is terminal" -> 29
  | "Worker Domain session is already attached" -> 30
  | "Worker Domain did not start" -> 31
  | _ -> 0
;;

let initialization_failure stage source =
  Initialization_failure (stage, initialization_cause source)
;;

let initialization_exception = function
  | Initialization_failure _ as error -> error
  | error ->
    let cause = match error with
      | Failure message when message = "application.mount.failed" -> 27
      | Failure _ -> 12
      | Invalid_argument _ -> 13
      | Sys_error _ -> 14
      | Unix.Unix_error ((Unix.EACCES | Unix.EPERM), _, _) -> 15
      | Unix.Unix_error (Unix.ENOENT, _, _) -> 16
      | Unix.Unix_error (Unix.ENOSPC, _, _) -> 17
      | Unix.Unix_error ((Unix.EBUSY | Unix.EAGAIN), _, _) -> 18
      | Unix.Unix_error (Unix.EIO, _, _) -> 19
      | Unix.Unix_error _ -> 20
      | Out_of_memory -> 21
      | Stack_overflow -> 22
      | End_of_file -> 23
      | Match_failure _ -> 24
      | Assert_failure _ -> 25
      | Not_found -> 26
      | _ -> 0
    in Initialization_failure (Initialize, cause)
;;

let classify_exception = function
  | Initialization_failure (stage, cause) ->
    (match stage with Decode_startup -> 500 | Start_worker -> 600 | Initialize -> 700) + cause
  | Failure message when message = "application.decodeStartup.failed" -> 5
  | Failure message when message = "application.startWorker.failed" -> 6
  | Failure message when message = "application.mount.failed" -> 7
  | _ -> 2
;;

let register hooks =
  current := Some hooks;
  Callback.register "journal_ocaml_classify_exception" classify_exception;
  Callback.register "lui_ocaml_init" initialize;
  Callback.register "lui_ocaml_appear" appear;
  Callback.register "lui_ocaml_press" press;
  Callback.register "lui_ocaml_long_press" long_press;
  Callback.register "lui_ocaml_press_detail" press_detail;
  Callback.register "lui_ocaml_pointer_down" pointer_down;
  Callback.register "lui_ocaml_pointer_up" pointer_up;
  Callback.register "lui_ocaml_pointer_enter" pointer_enter;
  Callback.register "lui_ocaml_pointer_leave" pointer_leave;
  Callback.register "lui_ocaml_context_menu_press" context_menu_press;
  Callback.register "lui_ocaml_text_changed" text_changed;
  Callback.register "lui_ocaml_submit" submit;
  Callback.register "lui_ocaml_dismiss" dismiss;
  Callback.register "lui_ocaml_double_press" double_press;
  Callback.register "lui_ocaml_toggle_changed" toggle_changed;
  Callback.register "lui_ocaml_radio_changed" radio_changed;
  Callback.register "lui_ocaml_slider_changed" slider_changed;
  Callback.register "lui_ocaml_scroll_completed" scroll_completed;
  Callback.register "lui_ocaml_visible_range" visible_range;
  Callback.register "lui_ocaml_virtual_window" virtual_window;
  Callback.register "lui_ocaml_picked" picked;
  Callback.register "lui_ocaml_dispose" dispose;
  Callback.register "lui_ocaml_root_node" root_node;
  Callback.register "journal_ocaml_extension_event" extension_event;
  Callback.register "journal_ocaml_pump" pump;
  Callback.register "journal_ocaml_platform_event" platform_event;
  Callback.register "journal_ocaml_platform_response" platform_response;
  Callback.register "journal_ocaml_platform_failure" platform_failure
;;

let platform_reasons =
  [ 1, "cancelled", "The native request was cancelled."
  ; 2, "requestDecode", "The native request format could not be read."
  ; 3, "responseEncode", "The native response could not be encoded."
  ; 4, "clipboardUnavailable", "The clipboard could not accept the copied text."
  ; 5, "serviceUnavailable", "The native service is currently unavailable. Retry the operation."
  ; 6, "serviceFailed", "The native service could not complete the request. Retry the operation."
  ; 7, "authenticationRequired", "Sign in again to complete the request."
  ; 8, "invalidBinding", "The saved account connection could not be read."
  ; 9, "network", "The native account request could not connect. Check your connection and retry."
  ; 10, "secureStorage", "Secure account storage is unavailable. Unlock your device and retry."
  ; 11, "invalidPacket", "The native service returned an invalid response."
  ]
;;

let platform_failure_message code =
  match List.find_opt (fun (_,reason,_)->code="native.platform."^reason) platform_reasons with
  | Some (_,_,message) -> code ^ " · " ^ message
  | None -> "native.platform.unknown · The native request could not finish. Retry the operation."
;;

let decode_platform_failure payload =
  let bytes=Bytes.of_string payload in
  let size=Bytes.length bytes in
  let known tag=List.mem tag [6;8;10;13;20;22;28;30;32] in
  if size=24 && String.sub payload 0 4="LJF1" then (
    let tag=Bytes.get_uint16_le bytes 4 and reason=Bytes.get_uint16_le bytes 6 in
    let account=Bytes.get_int64_le bytes 8 and presentation=Bytes.get_int64_le bytes 16 in
    match List.find_opt (fun (value,_,_)->value=reason) platform_reasons with
    | Some (_,name,_) when (known tag || (tag=0 && reason=2)) && account>=0L && presentation>=0L
        && account<=Int64.of_int max_int && presentation<=Int64.of_int max_int ->
      Some(tag,"native.platform."^name,Some(account,presentation))
    | _ -> None)
  else if size>=32 && size<=32+262144 && String.sub payload 0 4="LJP2"
      && Bytes.get_uint16_le bytes 4=2
      && String.sub payload 8 16=String.make 16 '\000'
      && String.sub payload 28 4=String.make 4 '\000'
      && Int32.equal (Bytes.get_int32_le bytes 24) (Int32.of_int(size-32)) then (
    let tag=Bytes.get_uint16_le bytes 6 in
    if known tag then Some(tag,"native.platform.serviceFailed",None) else None)
  else None
;;

let native_diagnostic source =
  let families=
    ["diagnostic.nativePropsDecode","decodeNativeProps";
     "diagnostic.nativeScrollDecode","decodeNativeScroll";
     "diagnostic.nativeEventDelivery","deliverNativeEvent";
     "diagnostic.nativeEventEncode","encodeNativeEvent"] in
  match List.find_opt (fun (prefix,_)->source=prefix || String.starts_with ~prefix:(prefix^".") source) families with
  | None -> None
  | Some(prefix,operation) ->
    let suffix=if source=prefix then "unknown" else String.sub source (String.length prefix+1) (String.length source-String.length prefix-1) in
    let reason,message = match suffix with
      | "missingPayload" -> suffix,"The required native payload is missing."
      | "typeMismatch" -> suffix,"A native field has an unexpected type."
      | "keyNotFound" -> suffix,"A required native field is missing."
      | "valueNotFound" -> suffix,"A required native value is missing."
      | "dataCorrupted" -> suffix,"The native payload format is invalid."
      | "invalidPayload" -> suffix,"The native payload is unsupported."
      | "backendUnsupportedProperty" -> suffix,"The native backend rejected an unsupported property."
      | "backendUnknownNode" -> suffix,"The native backend could not find the destination node."
      | "backendUnknownExtension" -> suffix,"The native extension is not registered."
      | "backendFingerprintMismatch" -> suffix,"The native extension schema does not match."
      | "backendInvalidHierarchy" -> suffix,"The native node hierarchy is invalid."
      | "backendInvalidEvent" -> suffix,"The native event schema is invalid."
      | "backendRegistryInvalid" -> suffix,"The native extension registry is invalid."
      | "backendInvalidBatch" -> suffix,"The native backend rejected the event batch."
      | _ -> "unknown","The native operation could not finish. Retry the operation."
    in Some(operation,"native."^operation^"."^reason^" · "^message)
;;
