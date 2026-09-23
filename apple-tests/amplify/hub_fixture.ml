(* Headless fixture for the Amplify hub-callback acceptance test: a static
   view driven by a Lui_app reducer app, replacing the previous Bonsai
   computation. Dropped into a generated host as app/application.ml (see
   tool/test_swiftui_amplify.py). *)

open Lui_protocol
open Lui_elements

type model = unit
type action = Nop

let reducer () Nop = ()

let view _context _model _send =
  column
    ~gap:16
    ~padding:16
    [ text ~value:"Native Hub callback acceptance" [] ]
;;

(* --- headless host bridge ------------------------------------------------ *)

let latest_patch = ref ""

let current_app : (model, action) Lui_app.reducer_app option ref = ref None

let operating_system = function
  | 1 -> MacOS
  | 2 -> IOS
  | 3 -> AndroidOS
  | 4 -> LinuxOS
  | 5 -> WindowsOS
  | _ -> GenericOS
;;

let host_kind = function
  | 1 -> WebHost
  | 2 -> SwiftUIHost
  | 3 -> FlutterHost
  | _ -> GenericHost
;;

let backend profile =
  { backend_profile = profile
  ; apply_batch =
      (fun batch ->
         latest_patch := Lui_wire.encode_batch batch;
         true)
  }
;;

let app () =
  match !current_app with
  | Some value -> value
  | None -> invalid_arg "Hub acceptance fixture is not started"
;;

let init platform_code host_code _payload =
  latest_patch := "";
  let value =
    Lui_app.create
      (backend
         (profile (operating_system platform_code) (host_kind host_code)))
      () reducer view
  in
  current_app := Some value;
  ignore (Lui_app.start value);
  ignore (Lui_app.flush value);
  !latest_patch
;;

let dispatch event =
  latest_patch := "";
  ignore (Lui_app.dispatch_event (app ()) event);
  ignore (Lui_app.flush (app ()));
  !latest_patch
;;

let extension_event _node _name _payload = ""

let pump () =
  latest_patch := "";
  ignore (Lui_app.flush (app ()));
  !latest_patch
;;

let dispose () =
  latest_patch := "";
  Option.iter (fun value -> ignore (Lui_app.dispose value)) !current_app;
  current_app := None;
  !latest_patch
;;

let root_node () = Lui_app.root_node (app ())

let native_hooks : Journal_bridge.hooks =
  { init
  ; dispatch
  ; extension_event
  ; pump
  ; platform_event = (fun _ -> ())
  ; platform_response = (fun _ -> ())
  ; dispose
  ; root_node
  }
;;

let () = Journal_bridge.register native_hooks
