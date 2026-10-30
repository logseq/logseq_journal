(* Public native failure codec; these bytes contain no request body. *)
let () =
  let failure=Bytes.make 24 '\000' in
  Bytes.blit_string "LJF1" 0 failure 0 4;
  Bytes.set_uint16_le failure 4 6;
  Bytes.set_uint16_le failure 6 6;
  Bytes.set_int64_le failure 8 7L;
  Bytes.set_int64_le failure 16 9L;
  assert(Journal_bridge.decode_platform_failure(Bytes.to_string failure)=Some(6,"native.platform.serviceFailed",Some(7L,9L)));
  assert(Journal_bridge.decode_platform_failure(String.sub(Bytes.to_string failure)0 23)=None);
  Bytes.set_uint16_le failure 6 99;
  assert(Journal_bridge.decode_platform_failure(Bytes.to_string failure)=None);
  Bytes.set_uint16_le failure 6 1;
  assert(Journal_bridge.decode_platform_failure(Bytes.to_string failure)=Some(6,"native.platform.cancelled",Some(7L,9L)));
  Bytes.set_int64_le failure 8 (-1L);
  assert(Journal_bridge.decode_platform_failure(Bytes.to_string failure)=None);
  let legacy=Bytes.make 32 '\000' in
  Bytes.blit_string "LJP2" 0 legacy 0 4;Bytes.set_uint16_le legacy 4 2;Bytes.set_uint16_le legacy 6 6;
  assert(Journal_bridge.decode_platform_failure(Bytes.to_string legacy)=Some(6,"native.platform.serviceFailed",None));
  Bytes.set_uint16_le legacy 4 3;assert(Journal_bridge.decode_platform_failure(Bytes.to_string legacy)=None);
  assert(Journal_bridge.native_diagnostic "diagnostic.nativePropsDecode.keyNotFound"=
    Some("decodeNativeProps","native.decodeNativeProps.keyNotFound · A required native field is missing."));
  assert(Journal_bridge.native_diagnostic "diagnostic.nativeScrollDecode.SECRET /private/token"=
    Some("decodeNativeScroll","native.decodeNativeScroll.unknown · The native operation could not finish. Retry the operation."));
  assert(Journal_bridge.native_diagnostic "SECRET /private/token"=None)
;;

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

let pointer_patch kind node (detail : pointer_detail) =
  patch node (Printf.sprintf "%s:%g:%g:%d:%d:%s" kind detail.x detail.y
    detail.modifiers detail.button detail.target_class)
;;

let dispatch = function
  | Appear node -> patch node "appear"
  | Press node -> patch node "press"
  | LongPress node -> patch node "longPress"
  | TextChanged (_, "raise") -> failwith "native event fixture rejection"
  | TextChanged (_, "raise-startup") -> failwith "application.decodeStartup.failed"
  | TextChanged (_, "raise-worker") -> failwith "application.startWorker.failed"
  | TextChanged (_, "raise-mount") -> failwith "application.mount.failed"
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
  | VirtualWindow (node, generation, first, last, pins) ->
    patch node (Printf.sprintf "virtualWindow:%d:%d:%d:%s" generation first last
      (String.concat "," (List.map string_of_int pins)))
  | Picked (node, payload) -> patch node ("picked:" ^ payload)
  | PressModifiers (node, modifiers) -> patch node ("pressModifiers:" ^ string_of_int modifiers)
  | PressDetail (node, detail) -> pointer_patch "pressDetail" node detail
  | PointerDown (node, detail) -> pointer_patch "pointerDown" node detail
  | PointerUp (node, detail) -> pointer_patch "pointerUp" node detail
  | PointerEnter node -> patch node "pointerEnter"
  | PointerLeave node -> patch node "pointerLeave"
  | ContextMenuPress (node, detail) -> pointer_patch "contextMenuPress" node detail
  | Load node -> patch node "load"
  | NavigatePrevious _ | NavigateNext _ | NavigationKey _ | ScrollEdges _
  | PointerMove _ | PointerCancel _ | ToggleChangedDetail _ ->
    failwith "event is not emitted by the Apple host"
  | ExtensionEvent _ -> failwith "extension bypassed its host hook"
;;

let receive_platform bytes =
  if bytes = "raise" then failwith "SENSITIVE platform fixture text";
  pending_platform := Some bytes
;;

let () =
  Journal_bridge.register
    { init = (fun _ _ _ -> start_worker (); patch 42 "init")
    ; dispatch
    ; extension_event =
        (fun node name payload -> patch node ("extension:" ^ name ^ ":" ^ payload))
    ; pump = (fun () ->
        if !pending_platform = Some "pump-raise" then (
          pending_platform := None;
          failwith "SENSITIVE pump fixture text");
        let text = Option.fold ~none:"pump" ~some:(fun bytes ->
          let buffer = Buffer.create (String.length bytes * 2) in
          String.iter (fun byte -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte))) bytes;
          "platform:" ^ Buffer.contents buffer) !pending_platform in
        pending_platform := None;
        patch 42 text)
    ; platform_event = receive_platform
    ; platform_response = receive_platform
    ; platform_failure = receive_platform
    ; dispose = (fun () -> stop_worker (); patch 42 "dispose")
    ; root_node = (fun () -> 42)
    }
;;
