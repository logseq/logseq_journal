open Lui_protocol
open Lui_extension

let chrome_identifier = "journal-chrome"
let asset_import_identifier = "journal-asset-import"
let media_identifier = "journal-media"
let asset_settings_identifier = "journal-asset-settings"
let list_identifier = "journal-list"

let apple_profiles =
  [ { profile_os = MacOS; profile_host = SwiftUIHost }
  ; { profile_os = IOS; profile_host = SwiftUIHost }
  ]
;;

let all_host_profiles =
  apple_profiles
  @ [ { profile_os = MacOS; profile_host = FlutterHost }
    ; { profile_os = IOS; profile_host = FlutterHost }
    ; { profile_os = AndroidOS; profile_host = FlutterHost }
    ]
;;

let payload_property = property "payload" StringScalar true None

let event_schema =
  event
    "event"
    [ event_field "id" IntScalar true; event_field "payload" StringScalar true ]
;;

let registry =
  let registry = Lui_extension.registry () in
  (* Journal native views nest: chrome slots hold page content (including
     other chrome sections, lists, and media), and list rows hold media and
     chrome section headers. Every component accepts all journal extensions
     as children; the schema must stay in sync with the fingerprint the
     Apple host computes in JournalExtensions.swift. *)
  let children =
    [ chrome_identifier
    ; asset_import_identifier
    ; media_identifier
    ; asset_settings_identifier
    ; list_identifier
    ]
  in
  register_component
    registry
    (component chrome_identifier apple_profiles true children [ payload_property ] []);
  register_component
    registry
    (component
       asset_import_identifier
       all_host_profiles
       false
       children
       [ payload_property ]
       [ event_schema ]);
  register_component
    registry
    (component
       media_identifier
       all_host_profiles
       false
       children
       [ payload_property ]
       [ event_schema ]);
  register_component
    registry
    (component
       asset_settings_identifier
       all_host_profiles
       true
       children
       [ payload_property ]
       [ event_schema ]);
  register_component
    registry
    (component
       list_identifier
       all_host_profiles
       false
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
             || String.equal identifier media_identifier
             || String.equal identifier asset_settings_identifier
             || String.equal identifier list_identifier) ->
    (match String_map.find_opt "id" values, String_map.find_opt "payload" values with
     | Some (IntValue event_id), Some (StringValue payload) ->
       Some { identifier; node; event_id; payload }
     | _ -> None)
  | _ -> None
;;

let mount ?key ~payload ~children ?on_event identifier context parent =
  let node = Lui_ui.extension context identifier in
  Option.iter (Lui_ui.key context node) key;
  Lui_ui.extension_property context node "payload" (StringValue payload);
  Option.iter
    (fun handler ->
       Lui_ui.on_event context node (fun raw ->
         match decode_event raw with
         | Some event -> handler event
         | None -> ()))
    on_event;
  (match parent with
   | Some parent -> Lui_ui.append context parent node
   | None -> ());
  List.iter (fun child -> ignore (child context (Some node))) children;
  node
;;

let chrome ?key ~payload ?on_event children : Lui_elements.t =
  fun context parent ->
  mount ?key ~payload ~children ?on_event chrome_identifier context parent
;;

let asset_import ?key ~payload ?on_event () : Lui_elements.t =
  fun context parent ->
  mount ?key ~payload ~children:[] ?on_event asset_import_identifier context parent
;;

let media ?key ~payload ?on_event children : Lui_elements.t =
  fun context parent ->
  mount ?key ~payload ~children ?on_event media_identifier context parent
;;

let asset_settings ?key ~payload ?on_event children : Lui_elements.t =
  fun context parent ->
  mount ?key ~payload ~children ?on_event asset_settings_identifier context parent
;;

let list ?key ~payload ?on_event children : Lui_elements.t =
  fun context parent ->
  mount ?key ~payload ~children ?on_event list_identifier context parent
;;
