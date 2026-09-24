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

let on_list_event send (event : Journal_lui_native.event) =
  match
    try Yojson.Basic.from_string event.payload with
    | _ -> `Null
  with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String "expanded") ->
       (match List.assoc_opt "key" fields, List.assoc_opt "expanded" fields with
        | Some (`String _), Some (`Bool value) -> ignore (send (Expand value))
        | _ -> ())
     | Some (`String "row_event") ->
       (match List.assoc_opt "payload" fields with
        | Some (`String inner) ->
          (match
             try Yojson.Basic.from_string inner with
             | _ -> `Null
           with
           | `Assoc inner_fields ->
             (match
                List.assoc_opt "row" inner_fields, List.assoc_opt "key" inner_fields
              with
              | Some (`String row), Some (`String key) ->
                ignore (send (Observe (key ^ ":" ^ row)))
              | _ -> ())
           | _ -> ())
        | _ -> ())
     | _ -> ())
  | _ -> ()
;;

(* The payload mirrors Journal_view.Native_list's build output: sections and
   row descriptors in JSON, content elements mounted as extension children in
   the order the payload's content_index fields reference. *)
let outline_list ~expanded send : Lui_elements.t =
  let contents = ref [] in
  let push element =
    contents := element :: !contents;
    List.length !contents - 1
  in
  let context_menu_json =
    ( "context_menu"
    , `Assoc
        [ ( "actions"
          , `List
              [ `Assoc
                  [ "key", `String "delete"
                  ; "enabled", `Bool true
                  ; "role", `String "destructive"
                  ; "symbol", `Null
                  ; "title", `String "Delete"
                  ]
              ] )
        ] )
  in
  let row ~id ~label =
    `Assoc
      [ "type", `String "row"
      ; "key", `String id
      ; "content_index", `Int (push (text ~value:label []))
      ; "separator", `String "hidden"
      ; context_menu_json
      ]
  in
  let disclosure ~id ~expanded children =
    `Assoc
      [ "type", `String "disclosure"
      ; "key", `String id
      ; "content_index", `Int (push (text ~value:"Parent row" []))
      ; "separator", `String "hidden"
      ; "expanded", `Bool expanded
      ; "children", `List children
      ]
  in
  let payload =
    Yojson.Basic.to_string
      (`Assoc
          [ "style", `String "plain"
          ; ( "sections"
            , `List
                [ `Assoc
                    [ "key", `String "rows"
                    ; "separator", `String "hidden"
                    ; "header_index", `Null
                    ; "footer_index", `Null
                    ; ( "rows"
                      , `List
                          [ disclosure
                              ~id:"parent"
                              ~expanded
                              [ row ~id:"child" ~label:"Child row"
                              ; row ~id:"branch" ~label:"Unloaded branch row"
                              ]
                          ; row ~id:"sibling" ~label:"Sibling row"
                          ] )
                    ]
                ] )
          ; "scroll_request", `Null
          ; "track_visible_range", `Bool false
          ; "track_scroll_completion", `Bool false
          ])
  in
  Journal_lui_native.list
    ~key:"outline"
    ~payload
    ~children:(List.rev !contents)
    ~on_event:(on_list_event send)
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
