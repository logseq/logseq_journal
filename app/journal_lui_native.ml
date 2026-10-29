open Lui_protocol
open Lui_extension

let chrome_identifier = "journal-chrome"
let asset_import_identifier = "journal-asset-import"
let asset_settings_identifier = "journal-asset-settings"
let list_identifier = "journal-list"
let image_preview_identifier = "journal-image-preview"

let apple_profiles =
  [ { profile_os = MacOS; profile_host = SwiftUIHost }
  ; { profile_os = IOS; profile_host = SwiftUIHost }
  ]
;;

let payload_property = property "payload" StringScalar true None
let scroll_request_property = property "scroll_request" StringScalar false None

let event_schema =
  event
    "event"
    [ event_field "id" IntScalar true; event_field "payload" StringScalar true ]
;;

let registry =
  let registry = Lui_extension.registry () in
  Lui_navigation.register_into registry;
  (* Journal native views nest: chrome slots hold page content (including
     other chrome sections and lists), and list rows hold native LUI media and
     chrome section headers. Every component accepts all journal extensions
     as children; the schema must stay in sync with the fingerprint the
     Apple host computes in JournalExtensions.swift. *)
  let children =
    [ chrome_identifier
    ; asset_import_identifier
    ; asset_settings_identifier
    ; list_identifier
    ; image_preview_identifier
    ]
  in
  register_component
    registry
    (component chrome_identifier apple_profiles true children [ payload_property ] [ event_schema ]);
  register_component
    registry
    (component
       asset_import_identifier
       apple_profiles
       true
       children
       [ payload_property ]
       [ event_schema ]);
  register_component
    registry
    (component
       asset_settings_identifier
       apple_profiles
       true
       children
       [ payload_property ]
       [ event_schema ]);
  register_component
    registry
    (component
       list_identifier
       apple_profiles
       true
       children
       [ payload_property; scroll_request_property ]
       [ event_schema ]);
  register_component
    registry
    (component
       image_preview_identifier
       apple_profiles
       true
       children
       [ payload_property ]
       [ event_schema ]);
  freeze registry;
  registry
;;

type event =
  { identifier : string
  ; node : int
  ; event_id : int
  ; payload : string
  }

let decode_event = function
  | ExtensionEvent (node, identifier, name, values)
    when String.equal name "event"
         && (String.equal identifier chrome_identifier
             || String.equal identifier asset_import_identifier
             || String.equal identifier asset_settings_identifier
             || String.equal identifier list_identifier
             || String.equal identifier image_preview_identifier) ->
    (match String_map.find_opt "id" values, String_map.find_opt "payload" values with
     | Some (IntValue event_id), Some (StringValue payload) ->
       Some { identifier; node; event_id; payload }
     | _ -> None)
  | _ -> None
;;

let mount ?key ~payload ?payload_signal ~children ?on_event identifier context parent =
  let node = Lui_ui.extension context identifier in
  Option.iter (Lui_ui.key context node) key;
  Lui_ui.extension_property context node "payload" (StringValue payload);
  Option.iter (fun source ->
    let values=Signal.map (fun value->StringValue value) source in
    Signal.on_dispose context.Lui_ui.ui_scope (fun ()->Signal.dispose_signal values);
    Lui_ui.extension_property_signal context node "payload" values) payload_signal;
  Option.iter
    (fun handler ->
       Lui_ui.on_event context node (fun raw ->
         match decode_event raw with
         | Some event -> handler event
         | None -> ()))
    on_event;
  Lui_elements.attach context parent node;
  Lui_elements.mount_children context node children;
  node
;;

let list ?key ~payload ?(scroll_request = "null") ?scroll_request_signal ?on_event children : Lui_elements.t =
  fun context parent ->
  let node = mount ?key ~payload ~children ?on_event list_identifier context parent in
  (match scroll_request_signal with
   | None -> Lui_ui.extension_property context node "scroll_request" (StringValue scroll_request)
   | Some source ->
     let values = Signal.map (fun json -> StringValue json) source in
     Signal.on_dispose context.Lui_ui.ui_scope (fun () -> Signal.dispose_signal values);
     Lui_ui.extension_property_signal context node "scroll_request" values);
  node
;;

let image_preview ?key ~payload ?on_event children : Lui_elements.t =
  fun context parent ->
  mount ?key ~payload ~children ?on_event image_preview_identifier context parent
;;
