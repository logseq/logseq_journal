(* Headless acceptance probe for journal-list disclosure expansion and
   context-menu row actions, built on Lui_app + the journal extension mounts.
   Dropped into a generated host as app/application.ml (see
   tool/test_swiftui_outline.py). Row actions surface through the extension
   "event" channel: the host emits {"type":"row_event","payload":<string>}
   and {"type":"expanded","key":..,"expanded":..}; expansion and row presses
   drive the reducer below. *)

open Lui_protocol
open Lui_elements

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

(* Exercise the production generated Native_list codec and its public handlers. *)
let outline_list ~expanded send : Lui_elements.t =
  let module Ui = Journal_view in
  let module V = Ui.View in
  let module N = V.Native_list in
  let label value = V.of_lui (text ~value []) in
  let row id title =
    let action = V.Context_menu.action ~key:(Ui.Key.string "delete")
      ~role:Destructive ~title:"Delete"
      ~on_press:(Ui.Event.Handler.create (fun _ -> ignore (send (Observe ("delete:" ^ id))))) ()
    in
    N.row ~key:(Ui.Key.string id) ~separator:Hidden
      ~context_menu:(V.Context_menu.create ~actions:[action] ()) (label title)
  in
  let parent = N.disclosure_row ~key:(Ui.Key.string "parent") ~separator:Hidden
    ~expanded ~on_expanded_changed:(Ui.Event.Handler.create (function
      | Ui.Event.Payload.Bool value -> ignore (send (Expand value))
      | _ -> ())) ~label:(label "Parent row")
    [row "child" "Child row"; row "branch" "Unloaded branch row"]
  in
  N.vertical ~key:(Ui.Key.string "outline") ~style:Plain
    [N.section ~key:(Ui.Key.string "rows") ~separator:Hidden
      [parent; row "sibling" "Sibling row"]]
  |> Ui.mount
;;

let view _context model_source send =
  let model = sample model_source in
  column
    ~gap:16
    [ text ~value:("Observed: " ^ model.observed) []
    ; outline_list ~expanded:model.expanded send
    ]
;;

(* --- headless host bridge ------------------------------------------------ *)
(* Shape mirrors app/native_embed.ml: the generated host calls
   Journal_bridge.register with these hooks. *)

let latest_patch = ref ""
let current_app : (model, action) Lui_app.reducer_app option ref = ref None

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
      (backend (Lui_native_bridge.profile platform_code host_code))
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
  ; platform_failure = (fun _ -> ())
  ; dispose
  ; root_node
  }
;;

let () = Journal_bridge.register native_hooks
