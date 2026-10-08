(** Journal-specific lui extension components.

   Replaces the [Ui.Native_widget.Extension] registrations that previously
   carried kinds 2103, 2104 and 2106 over the bonsai_swiftui
   native-widget channel, plus the native collection.
   Each component ships its properties as one [payload] string field holding
   the same JSON object the Swift [Properties] structs already decode, and
   reports events through one ["event"] extension event with [id] (int) and
   [payload] (JSON string) fields, matching the old
   [BonsaiNativeEvent(id, payload)] contract. *)

(** Lui extension identifiers (slugs). *)
val chrome_identifier : string

val asset_import_identifier : string
val asset_settings_identifier : string
val list_identifier : string

(** Extension schemas shared with the Apple iOS/macOS hosts. *)
val registry : Lui_extension.extension_registry

(** A journal extension event decoded from the lui event stream. *)
type event =
  { identifier : string
  ; node : int
  ; event_id : int
  ; payload : string
  }

(** Low-level mount helper shared by the element constructors and the
    [Journal_view.Native_widget] shim.  [payload] is the JSON-encoded
    properties object (the same JSON the previous [~encode_props] produced);
    [on_event] receives decoded journal extension events. *)
val mount
  :  ?key:string
  -> payload:string
  -> children:Lui_elements.t list
  -> ?on_event:(event -> unit)
  -> string
  -> Lui_elements.t

(** Native virtualized collection (grouped sections, scroll positioning,
    visible-range paging, context actions). Section and row structure rides in
    [payload]; each row's content element mounts as an extension child in the
    order described by the payload's content indexes. *)
val list
  :  ?key:string
  -> payload:string
  -> ?on_event:(event -> unit)
  -> Lui_elements.t list
  -> Lui_elements.t

(** Native QuickLook image group, using display order and a selected index. *)
val image_preview
  :  ?key:string
  -> payload:string
  -> ?on_event:(event -> unit)
  -> Lui_elements.t list
  -> Lui_elements.t
