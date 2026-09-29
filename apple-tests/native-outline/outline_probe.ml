(* Headless acceptance probe for native disclosure expansion and
   context-menu/swipe row actions, built on Lui_app + the production
   [Journal_view.Native_list] builder (lui list elements).  Dropped into a
   generated host as app/application.ml (see tool/test_swiftui_outline.py).
   Row actions surface through the lui press channel as [Unit] payloads;
   disclosure toggles arrive as [Bool] payloads through
   [on_expanded_changed] and drive the reducer below. *)

open Lui_protocol
open Lui_elements
module Ui = Journal_view
module V = Ui.View

type model =
  { observed : string
  ; expanded : bool
  }

type action =
  | Observe of string
  | Expand of bool

let initial = { observed = "No action"; expanded = true }

let reducer model = function
  | Observe value -> { model with observed = value }
  | Expand value -> { model with expanded = value }
;;

let key value = Ui.Key.string value
let test_id value = Ui.Test_id.string value

(* [Observed] keeps the old contract shape: {"action":"delete","row":<id>}. *)
let delete_handler send row_id =
  Ui.Event.Handler.create ~name:("delete-" ^ row_id) (fun _ ->
    ignore
      (send (Observe (Printf.sprintf "{\"action\":\"delete\",\"row\":\"%s\"}" row_id))))
;;

let row_actions send row_id =
  let swipe_actions =
    V.Swipe_actions.create
      ~allows_full_swipe:false
      ~actions:
        [ V.Swipe_actions.action
            ~key:(key ("delete:" ^ row_id))
            ~side:End
            ~title:"Delete"
            ~role:Destructive
            ~background:Journal_visual_tokens.delete_action_background
            ~on_press:(delete_handler send row_id)
            ()
        ]
      ()
  in
  let context_menu =
    V.Context_menu.create
      ~actions:
        [ V.Context_menu.action
            ~key:(key "delete")
            ~role:Destructive
            ~title:"Delete"
            ~on_press:(delete_handler send row_id)
            ()
        ]
      ()
  in
  swipe_actions, context_menu
;;

let outline_list ~expanded send : V.t =
  let leaf id =
    let swipe_actions, context_menu = row_actions send id in
    V.Native_list.row
      ~key:(key id)
      ~separator:Hidden
      ~swipe_actions
      ~context_menu
      (V.text id)
  in
  let swipe_actions, context_menu = row_actions send "parent" in
  V.Native_list.vertical
    ~key:(key "outline")
    ~style:Plain
    [ V.Native_list.section
        ~key:(key "rows")
        ~separator:Hidden
        [ V.Native_list.disclosure_row
            ~key:(key "parent")
            ~separator:Hidden
            ~swipe_actions
            ~context_menu
            ~expanded
            ~on_expanded_changed:
              (Ui.Event.Handler.create ~name:"expand-parent" (function
                 | Ui.Event.Payload.Bool value -> ignore (send (Expand value))
                 | _ -> ()))
            ~label:(V.text "Parent row")
            [ leaf "child"; leaf "branch" ]
        ; leaf "sibling"
        ]
    ]
;;

let view _context model_source send =
  let model = sample model_source in
  column
    ~gap:16
    [ text ~value:("Observed: " ^ model.observed) []
    ; Ui.mount (outline_list ~expanded:model.expanded send)
    ]
;;

(* --- headless host bridge ------------------------------------------------ *)
(* Shape mirrors app/native_embed.ml: the generated host calls
   Journal_bridge.register with these hooks. *)

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
  | None -> invalid_arg "Outline probe is not started"
;;

let init platform_code host_code _payload =
  latest_patch := "";
  let value =
    Lui_app.create
      (backend (profile (operating_system platform_code) (host_kind host_code)))
      initial
      reducer
      view
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
