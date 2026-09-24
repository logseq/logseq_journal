[@@@ocaml.warning "-69"]

(* Journal view shim over lui elements.

   This module preserves the shape of the previous BonsaiSwiftUI view API
   (V.*, Ui.Event.*, Ui.Key, Ui.Test_id, Ui.Style, Ui.Text_editing,
   Ui.Native_widget, Ui.View.Native_list, ...) on top of Lui_elements so the
   application layer ports mechanically.  Elements carry their optional key
   and test_id so [For_testing] can recover them like the old widget
   identity did. *)

type label_content =
  { title : string
  ; icon : string option
  }

type t =
  { key : string option
  ; test_id : string option
  ; mount : Lui_elements.t
  ; label_content : label_content option
  ; menu_item_mount : Lui_elements.t option
  }

module Key = struct
  type t = string

  let string s = s
  let int i = string_of_int i
  let int64 i = Int64.to_string i
end

module Test_id = struct
  type t = string

  let string s = s
  let to_string s = s
end

let element ?key ?test_id ?menu_item_mount mount =
  { key; test_id; mount; label_content = None; menu_item_mount }
;;

let mount t = t.mount
let int_of_float_nan v = int_of_float (Float.round v)

(* lui icon properties accept built-in names or [app:<slug>] custom names; the
   journal vocabulary is SF Symbol names, registered with the host backend under
   their [app:]-slugged form (see JournalIcons.swift). *)
let journal_icon_name name =
  "app:" ^ String.map (fun c -> if c = '.' then '-' else c) name
;;

(* [Lui_elements] icon parameters are typed: journal symbols travel as
   [`app]-registered icons, which [icon_value] writes back as the same
   app:slug [journal_icon_name] produces. *)
let journal_icon name : Lui_elements.icon =
  `app (String.map (fun c -> if c = '.' then '-' else c) name)
;;

(* While a navigation bar or bottom bar mounts its items, labels collapse to
   their icon — matching the icon-only affordances the system chrome showed. *)
let icon_only = ref false

(* [set_leaf_label] records each bar-mounted control that actually collapsed
   its label to an icon; only those get the uniform 40pt control cell — a
   text button like "Close" keeps its natural width, and a grouped row of
   controls sizes its leaves rather than the row itself. *)
let icon_only_collapsed_nodes : int list ref = ref []

(* Leaf controls carry their label/icon as properties; each kind only accepts
   a subset of them, so apply what the node kind supports. *)
let set_leaf_label context node { title; icon } =
  let kind = Lui_ui.node_kind context node in
  let supported property = Lui_protocol.property_supported kind property in
  if not (!icon_only && Option.is_some icon)
  then (if supported Lui_protocol.TextValue then Lui_ui.text_property context node title)
  else (
    icon_only_collapsed_nodes := node :: !icon_only_collapsed_nodes;
    (* Icon-only controls keep their name on the accessibility channel; the
       schema rejects icon-only buttons with no accessible name. *)
    if supported Lui_protocol.AccessibilityLabel
    then Lui_ui.accessibility_label context node (if title = "" then " " else title);
    (* Bar glyphs render chromeless inside the capsule; the default variant
       now maps to a bordered accent button which would double-frame the
       pill. *)
    if supported Lui_protocol.VariantValue
    then Lui_ui.string_property context node Lui_protocol.VariantValue "ghost";
    if supported Lui_protocol.ForegroundValue
    then Lui_ui.foreground context node "foreground");
  Option.iter
    (fun name ->
       if supported Lui_protocol.InlineIconName
       then
         Lui_ui.string_property
           context
           node
           Lui_protocol.InlineIconName
           (journal_icon_name name))
    icon
;;

(* Element mounts that don't register a standard runtime node (placeholder
   elements, extension nodes) can't carry standard properties. *)
let node_is_standard context node =
  node <> 0
  && Option.is_none (Lui_runtime.extension_identifier context.Lui_ui.ui_application node)
;;

let modify f t =
  { t with
    mount =
      (fun context parent ->
        let node = t.mount context parent in
        if node_is_standard context node then f context node;
        node)
  }
;;

(* Leaf labels go through [set_leaf_label]'s kind-conditional property
   writes; mounted as an in-place hook under the control's own node so it
   also works for abstract element types like [radio_el]. *)
let leaf_label (content : label_content option) : Lui_elements.t =
  Lui_elements.dynamic (fun context node ->
    Option.iter (set_leaf_label context node) content)
;;

module Event = struct
  module Payload = struct
    type text_selection =
      { start_utf16 : int
      ; end_utf16 : int
      }

    type text_edit =
      { session_id : Journal_ids.Text_input.Session_id.t
      ; local_revision : Journal_ids.Text_input.Local_revision.t
      ; base_document_revision : Journal_ids.Text_input.Document_revision.t
      ; text : string
      ; selection : text_selection
      ; composing : text_selection option
      }

    type scroll =
      { pixels : float
      ; delta : float
      }

    type visible_range =
      { first_index : int64
      ; last_exclusive : int64
      }

    type native_event =
      { kind_id : Journal_ids.Native_widget.Kind_id.t
      ; version : int
      ; event_id : int
      ; payload : bytes
      }

    type confirmation_result =
      | Action of string
      | Dismissed

    type confirmation_response =
      { token : int64
      ; result : confirmation_result
      }

    type native_list_outcome =
      | Succeeded
      | Missing_target
      | Cancelled
      | Superseded
      | Positioning_failed

    type native_list_completion =
      { token : int64
      ; outcome : native_list_outcome
      }

    type t =
      | Confirmation_response of confirmation_response
      | Unit
      | Bool of bool
      | Text of string
      | Text_edit of text_edit
      | Int of int
      | Int64 of int64
      | Int64_bool of
          { id : int64
          ; value : bool
          }
      | Int64_pair of
          { first : int64
          ; second : int64
          }
      | Float of float
      | Scroll of scroll
      | Visible_range of visible_range
      | Navigation_path_changed of Journal_ids.Navigation.Page_key.t list
      | Native_event of native_event
      | Native_list_completion of native_list_completion
      | Event of Lui_protocol.event
  end

  module Handler = struct
    type t =
      { name : string option
      ; invoke : Payload.t -> unit
      }

    let create ?name invoke = { name; invoke }
    let name t = t.name

    module Private = struct
      let same left right = left == right
      let invoke t payload = t.invoke payload
    end
  end

  type handler = Handler.t
end

module Style = struct
  module Color = struct
    type t = string

    let clamp_component value =
      if value < 0 then 0 else if value > 255 then 255 else value
    ;;

    let rgb ~red ~green ~blue =
      Printf.sprintf
        "#%02x%02x%02x"
        (clamp_component red)
        (clamp_component green)
        (clamp_component blue)
    ;;

    let argb ~alpha ~red ~green ~blue =
      if alpha <= 0 then "transparent" else rgb ~red ~green ~blue
    ;;
  end

  module Text_style = struct
    type foreground =
      | Primary
      | Secondary

    type font_weight =
      | Regular
      | Semi_bold

    type t =
      { foreground : foreground option
      ; font_weight : font_weight option
      }

    let create ?foreground ?font_weight () = { foreground; font_weight }
  end
end

module Layout = struct
  module Edge_insets = struct
    type t = float

    let all v = v
  end

  module Alignment = struct
    type t = string
  end

  module Horizontal_alignment = struct
    type t =
      | Leading
      | Center
      | Trailing

    let to_lui : t -> Lui_elements.cross_alignment = function
      | Leading -> `start
      | Center -> `center
      | Trailing -> `end_
    ;;
  end

  module Vertical_alignment = struct
    type t =
      | Top
      | Center
      | Bottom

    let to_lui : t -> Lui_elements.cross_alignment = function
      | Top -> `start
      | Center -> `center
      | Bottom -> `end_
    ;;
  end

  module Frame_limit = struct
    type t =
      | Fixed of float
      | Fill
  end
end

module Semantics = struct
  module Role = struct
    type t =
      | Generic
      | Button
      | Link
      | Image
      | Header
      | Toggle
      | Static_text

    let equal (left : t) right = left = right

    let to_string = function
      | Generic -> "generic"
      | Button -> "button"
      | Link -> "link"
      | Image -> "image"
      | Header -> "header"
      | Toggle -> "toggle"
      | Static_text -> "static_text"
    ;;
  end

  module Children = struct
    type t =
      | Combine
      | Contain
      | Ignore
  end

  module Action = struct
    type t =
      { id : int64
      ; label : string
      }

    let create ~id ~label = { id; label }
    let id t = t.id
    let label t = t.label
    let equal left right = Int64.equal left.id right.id
  end

  type t =
    { label : string option
    ; selected : bool option
    ; live_region : bool
    ; role : Role.t option
    ; children : Children.t option
    ; actions : Action.t list option
    }

  let create
        ?label
        ?hint:_
        ?value:_
        ?role
        ?selected
        ?children
        ?hidden:_
        ?(live_region = false)
        ?heading_level:_
        ?sort_priority:_
        ?identifier:_
        ?actions
        ()
    =
    { label; selected; live_region; role; children; actions }
  ;;

  module Private = struct
    let view t =
      { label = t.label
      ; selected = t.selected
      ; live_region = t.live_region
      ; role = t.role
      ; children = t.children
      ; actions = t.actions
      }
    ;;
  end
end

module Theme = struct
  type mode =
    | System
    | Light
    | Dark

  type t = mode

  let create ~mode () = mode
end

module Text_editing = struct
  module Range = struct
    type t =
      { start_utf16 : int
      ; end_utf16 : int
      }

    let create ~text:_ ~start_utf16 ~end_utf16 = { start_utf16; end_utf16 }
    let start_utf16 t = t.start_utf16
    let end_utf16 t = t.end_utf16

    let equal left right =
      left.start_utf16 = right.start_utf16 && left.end_utf16 = right.end_utf16
    ;;
  end

  module Value = struct
    type t =
      { text : string
      ; selection : Range.t
      ; composing : Range.t option
      }

    let create ~text ~selection ?composing () = { text; selection; composing }
    let text t = t.text
    let selection t = t.selection
    let composing t = t.composing

    let equal left right =
      String.equal left.text right.text
      && Range.equal left.selection right.selection
      && Option.equal Range.equal left.composing right.composing
    ;;
  end

  module Utf16 = struct
    let length s =
      let count = ref 0 in
      let i = ref 0 in
      let n = String.length s in
      while !i < n do
        let byte = Char.code (String.unsafe_get s !i) in
        let advance, units =
          if byte < 0x80
          then 1, 1
          else if byte land 0xE0 = 0xC0
          then 2, 1
          else if byte land 0xF0 = 0xE0
          then 3, 1
          else if byte land 0xF8 = 0xF0
          then 4, 2
          else 1, 1
        in
        i := !i + advance;
        count := !count + units
      done;
      !count
    ;;
  end

  type update_mode =
    | Ack
    | Force_replace
    | Initiate
    | Resume

  module Keyboard = struct
    type t =
      | Default
      | Text
  end

  module Submit_label = struct
    type t =
      | Default
      | Go
      | Done
      | Return
      | Send
  end

  module Field_appearance = struct
    type t =
      | Rounded
      | Plain
  end
end

let invoke handler payload = Event.Handler.Private.invoke handler payload

(* The enclosing navigation stack publishes its pop affordance here so a
   toolbar mounted inside the current page can render the model-level back
   button, title and actions in the bar it emulates. *)
type nav_bar =
  { nav_on_change : Event.Handler.t
  ; nav_remaining : Journal_ids.Navigation.Page_key.t list
  ; nav_can_pop : bool
  ; nav_title : string
  }

let nav_bar = ref None

module View = struct
  type nonrec t = t
  type element_ = t

  module For_testing = struct
    let key t = t.key
    let test_id t = t.test_id
  end

  module Button_role = struct
    type t =
      | Normal
      | Destructive
      | Cancel

    let variant = function
      | Destructive -> "destructive"
      | Cancel -> "secondary"
      | Normal -> "default"
    ;;

    (* Element variants are typed; [Normal] writes nothing, matching the
       mount sites that only override the variant for a non-Normal role. *)
    let lui_variant : t -> Lui_elements.variant option = function
      | Destructive -> Some `destructive
      | Cancel -> Some `secondary
      | Normal -> None
    ;;
  end

  module Button_style = struct
    type t =
      | Automatic
      | Plain
      | Bordered
      | Prominent
      | Button

    let lui_variant : t -> Lui_elements.variant = function
      | Plain -> `ghost
      | Bordered -> `outline
      | Prominent -> `primary
      | Button | Automatic -> `default
    ;;
  end

  module Progress_style = struct
    type t =
      | Linear
      | Circular
  end

  let with_test_id test_id t =
    let mount context parent =
      let node = t.mount context parent in
      (* Extension nodes carry only extension properties; standard props like
         the accessibility identifier don't apply to them. *)
      if node_is_standard context node
      then Lui_ui.accessibility_identifier context node (Test_id.to_string test_id);
      node
    in
    { t with test_id = Some (Test_id.to_string test_id); mount }
  ;;

  let empty ?key:_ () = element (fun _context _parent -> 0)

  let text
        ?key
        ?(style : Style.Text_style.t option)
        ?text_align:_
        ?line_limit:_
        ?truncation:_
        value
    =
    { (element
         ?key
         (Lui_elements.text
            ~value
            ?foreground:
              (match style with
               | Some { Style.Text_style.foreground = Some Style.Text_style.Secondary; _ }
                 -> Some "secondary"
               | _ -> None)
            ?style_class:
              (match style with
               | Some
                   { Style.Text_style.font_weight = Some Style.Text_style.Semi_bold; _ }
                 -> Some "semibold"
               | _ -> None)
            []))
      with
      label_content = Some { title = value; icon = None }
    }
  ;;

  let symbol ?key ?size ?color ?rendering:_ ~name () =
    { (element
         ?key
         (Lui_elements.icon
            ~name:(journal_icon name)
            ?point_size:(Option.map int_of_float_nan size)
            ?foreground:color
            []))
      with
      label_content = Some { title = ""; icon = Some name }
    }
  ;;

  let label ?key ~title ~icon () =
    { (element ?key (Lui_elements.row [ icon.mount; title.mount ])) with
      label_content =
        Some
          { title =
              (match title.label_content with
               | Some content -> content.title
               | None -> "")
          ; icon =
              (match icon.label_content with
               | Some content -> content.icon
               | None -> None)
          }
    }
  ;;

  let divider ?key () = element ?key (Lui_elements.separator ~orientation:`horizontal [])

  let progress ?key ?value ?(style = Progress_style.Linear) () =
    element
      ?key
      (match style, value with
       | Progress_style.Circular, _ -> Lui_elements.spinner []
       | Linear, Some value -> Lui_elements.progress ~value []
       | Linear, None -> Lui_elements.spinner [])
  ;;

  let spacer ?key ?min_length:_ () = element ?key (Lui_elements.spacer [])

  let row ?key ?(spacing = 16.) ?(alignment = Layout.Vertical_alignment.Center) children =
    element
      ?key
      (Lui_elements.row
         ~gap:(int_of_float_nan spacing)
         ~cross:(Layout.Vertical_alignment.to_lui alignment)
         (List.map (fun child -> child.mount) children))
  ;;

  let column
        ?key
        ?(spacing = 16.)
        ?(alignment = Layout.Horizontal_alignment.Center)
        children
    =
    element
      ?key
      (Lui_elements.column
         ~gap:(int_of_float_nan spacing)
         ~cross:(Layout.Horizontal_alignment.to_lui alignment)
         (List.map (fun child -> child.mount) children))
  ;;

  let stack ?key ?alignment:_ children =
    element ?key (Lui_elements.stack (List.map (fun child -> child.mount) children))
  ;;

  let apply_frame_limit context node _min_prop max_prop limit =
    match limit with
    | Layout.Frame_limit.Fill -> Lui_ui.grow context node 1.0
    | Fixed value -> Lui_ui.int_property context node max_prop (int_of_float_nan value)
  ;;

  let frame
        ?key:frame_key
        ?width
        ?height
        ?min_width
        ?ideal_width:_
        ?max_width
        ?min_height
        ?ideal_height:_
        ?max_height
        ?alignment:_
        t
    =
    modify
      (fun context node ->
         Option.iter (fun v -> Lui_ui.width context node (int_of_float_nan v)) width;
         Option.iter (fun v -> Lui_ui.height context node (int_of_float_nan v)) height;
         Option.iter
           (fun v -> Lui_ui.min_width context node (int_of_float_nan v))
           min_width;
         Option.iter
           (fun v -> Lui_ui.min_height context node (int_of_float_nan v))
           min_height;
         Option.iter
           (fun limit ->
              apply_frame_limit
                context
                node
                Lui_protocol.MinWidth
                Lui_protocol.MaxWidth
                limit)
           max_width;
         Option.iter
           (fun limit ->
              apply_frame_limit
                context
                node
                Lui_protocol.MinHeight
                Lui_protocol.MaxHeight
                limit)
           max_height)
      t
    |> fun result ->
    match frame_key with
    | Some key -> { result with key = Some key }
    | None -> result
  ;;

  let padding ?key:_ ~insets t =
    modify (fun context node -> Lui_ui.padding context node (int_of_float_nan insets)) t
  ;;

  let semantics ?key:_ ~properties t =
    modify
      (fun context node ->
         Option.iter
           (fun label ->
              if
                Lui_protocol.property_supported
                  (Lui_ui.node_kind context node)
                  Lui_protocol.AccessibilityLabel
              then Lui_ui.accessibility_label context node label)
           properties.Semantics.label)
      t
  ;;

  let help ?key:_ ~message:_ t = t
  let text_selection ?key:_ ~enabled:_ t = t
  let opacity ?key:_ value t = modify (fun _ _ -> ignore value) t
  let ignores_safe_area ?regions:_ ?edges:_ t = t
  let safe_area_padding ?key:_ ~insets:_ t = t
  let theme ?key:_ ~data:_ t = t

  let background ?key:_ ?corner_radius ~color t =
    modify
      (fun context node ->
         Lui_ui.background context node color;
         Option.iter
           (fun radius -> Lui_ui.corner_radius context node (int_of_float_nan radius))
           corner_radius)
      t
  ;;

  let clip ?key:_ ?corner_radius:_ ?antialiased:_ t = t
  let layout_priority ?key:_ _ t = t
  let offset ?key:_ ?x:_ ?y:_ t = t
  let animated_opacity ?key:_ ?duration:_ value t = opacity value t

  let button
        ?key
        ?(enabled = true)
        ?(role = Button_role.Normal)
        ?style
        ?(autofocus = false)
        ~on_press
        ~child
        ()
    =
    let variant =
      match Button_role.lui_variant role with
      | Some _ as variant -> variant
      | None -> Option.map Button_style.lui_variant style
    in
    { (element
         ?key
         (Lui_elements.button
            ~disabled:(not enabled)
            ?variant
            ~autofocus
            ~on_press:(fun _ -> invoke on_press Event.Payload.Unit)
            (* lui controls are leaf nodes: their label/icon travel as
               properties, not child elements. *)
            [ leaf_label child.label_content ]))
      with
      menu_item_mount =
        Some
          (Lui_elements.menu_item
             ~disabled:(not enabled)
             ?text:
               (Option.map
                  (fun (label : label_content) ->
                     if String.length label.title = 0 then " " else label.title)
                  child.label_content)
             ?icon:
               (match child.label_content with
                | Some { icon = Some name; _ } -> Some (journal_icon name)
                | _ -> None)
             ?variant:(Button_role.lui_variant role)
             ~on_press:(fun _ -> invoke on_press Event.Payload.Unit)
             [])
    }
  ;;

  let toggle ?key ?style:_ ?(enabled = true) ~value ~on_changed ~label () =
    element
      ?key
      (Lui_elements.toggle
         ~checked:value
         ~disabled:(not enabled)
         ~on_toggle:(fun event ->
           match event with
           | Lui_protocol.ToggleChanged (_, selected) ->
             invoke on_changed (Event.Payload.Bool selected)
           | _ -> ())
         [ leaf_label label.label_content ])
  ;;

  let text_editor
        ?key
        ?(autofocus = false)
        ?(enabled = true)
        ?(read_only = false)
        ?(submit_on_return = true)
        ?max_utf8_bytes:_
        ~session_id
        ~document_revision
        ~accepted_local_revision
        ~update_mode:_
        ~value
        ~on_edit
        ~on_submit
        ~on_focus_changed:_
        ?on_limit_reached:_
        ()
    =
    element ?key (fun context parent ->
      let local_revision = ref accepted_local_revision in
      Lui_elements.textarea
        ~text:(Text_editing.Value.text value)
        ~disabled:(not (enabled && not read_only))
        ~autofocus
        ~submit_on_enter:submit_on_return
        ~on_input:(fun event ->
          match event with
          | Lui_protocol.TextChanged (_, text) ->
            local_revision := Journal_ids.Text_input.Local_revision.succ !local_revision;
            invoke
              on_edit
              (Event.Payload.Text_edit
                 { session_id
                 ; local_revision = !local_revision
                 ; base_document_revision = document_revision
                 ; text
                 ; selection = { start_utf16 = 0; end_utf16 = 0 }
                 ; composing = None
                 })
          | _ -> ())
        ~on_submit:(fun _ -> invoke on_submit Event.Payload.Unit)
        []
        context
        parent)
  ;;

  let secure_field
        ?key
        ~label:_
        ?(prompt = "")
        ?keyboard:_
        ?submit_label:_
        ?appearance:_
        ?(autofocus = false)
        ?(enabled = true)
        ?read_only:_
        ?submit_on_return:_
        ?max_utf8_bytes:_
        ~session_id
        ~document_revision
        ~accepted_local_revision
        ~update_mode:_
        ~value
        ~on_edit
        ~on_submit
        ~on_focus_changed:_
        ?on_limit_reached:_
        ()
    =
    element ?key (fun context parent ->
      let local_revision = ref accepted_local_revision in
      Lui_elements.secure_field
        ~text:(Text_editing.Value.text value)
        ~placeholder:prompt
        ~disabled:(not enabled)
        ~autofocus
        ~on_input:(fun event ->
          match event with
          | Lui_protocol.TextChanged (_, text) ->
            local_revision := Journal_ids.Text_input.Local_revision.succ !local_revision;
            invoke
              on_edit
              (Event.Payload.Text_edit
                 { session_id
                 ; local_revision = !local_revision
                 ; base_document_revision = document_revision
                 ; text
                 ; selection = { start_utf16 = 0; end_utf16 = 0 }
                 ; composing = None
                 })
          | _ -> ())
        ~on_submit:(fun _ -> invoke on_submit Event.Payload.Unit)
        []
        context
        parent)
  ;;

  let labeled_content ?key ~label ~value () =
    element ?key (Lui_elements.row [ label.mount; Lui_elements.spacer []; value.mount ])
  ;;

  let content_unavailable ?key ~label ?description ?actions () =
    element
      ?key
      (* Grow so the column fills the page: without it the column shrinks to
         its content and the centered children end up leading-aligned. *)
      (Lui_elements.column
         ~grow:1.0
         ((Lui_elements.spacer []
           :: (* The label is already a full-width row: center its own content
                rather than nesting it (a wrapper would split the free space
                with the label's own trailing spacer and leave the text
                off-center). *)
              (modify (fun context node -> Lui_ui.main context node "center") label).mount
           :: Option.fold
                ~none:[]
                ~some:(fun description ->
                  [ (modify
                       (fun context node ->
                          Lui_ui.string_property
                            context
                            node
                            Lui_protocol.TextAlignment
                            "center")
                       description)
                      .mount
                  ])
                description)
          (* Center content via per-child mechanics. A cross=center column
               keeps its natural width and lands leading under the stretch
               parent's topLeading frame, so horizontal centering instead
               goes through a main=center row: the row expands to the
               offered width and packs its child between leading/trailing
               spacers. Text needs no wrapper — a set text-alignment already
               stretches it to full width. *)
          @ Option.fold
              ~none:[]
              ~some:(fun actions ->
                [ Lui_elements.row ~gap:0 ~main:`center ~cross:`center [ actions.mount ] ])
              actions
          @ [ Lui_elements.spacer [] ]))
  ;;

  let overlay ?key:_ ?alignment:_ ~overlay t =
    element ?key:t.key (Lui_elements.stack [ t.mount; overlay.mount ])
  ;;

  module Keyed = struct
    type widget = t

    type nonrec t =
      { key : string
      ; view : t
      }

    let create ~key view = { key; view }
  end

  module Section = struct
    let create ?key ?header_text ?footer entries =
      element ?key (fun context parent ->
        (* Sections mount inside a `list`: a `heading` child becomes the
           native section header, following children the rows. Entries go in
           one column so they render as a single grouped card — panel/card
           kinds would overlay every child in a ZStack. *)
        (match header_text, parent with
         | Some title, Some parent ->
           ignore (Lui_elements.heading ~level:4 ~value:title [] context (Some parent))
         | _ -> ());
        let card =
          Lui_elements.column
            ~gap:12
            (List.map (fun (entry : Keyed.t) -> entry.view.mount) entries)
            context
            parent
        in
        Option.iter (fun footer -> ignore (footer.mount context parent)) footer;
        card)
    ;;
  end

  module Form = struct
    let vertical ?key entries =
      element
        ?key
        (Lui_elements.list (List.map (fun (entry : Keyed.t) -> entry.view.mount) entries))
    ;;
  end

  module Toolbar = struct
    type placement =
      | Automatic
      | Principal
      | Navigation
      | Primary_action
      | Secondary_action
      | Status
      | Confirmation_action
      | Cancellation_action
      | Destructive_action
      | Bottom_bar

    type spacing =
      | Fixed
      | Flexible

    type child = t

    type item =
      { item_key : string
      ; placement : placement option
      ; content : child
      ; spacing : spacing option
      ; is_group : bool
      }

    let child ~key:_ view = view

    let item ~key ?placement content =
      { item_key = key; placement; content; spacing = None; is_group = false }
    ;;

    let group ~key ?placement children =
      { item_key = key
      ; placement
      ; content =
          element ~key (fun context parent ->
            (* Groups mount their children flat into the enclosing bar: the
               toolbar capsule already is the group, and a wrapper
               button-group/row is either not a legal toolbar child or would
               stretch the capsule to full width. *)
            match parent with
            | Some parent ->
              Lui_elements.mount_children
                context
                parent
                (List.map (fun child -> child.mount) children);
              0
            | None -> 0)
      ; spacing = None
      ; is_group = true
      }
    ;;

    let spacer ~key ?placement spacing =
      { item_key = key
      ; placement
      ; content = element (Lui_elements.spacer [])
      ; spacing = Some spacing
      ; is_group = false
      }
    ;;

    (* System-chrome emulation: on iOS the previous renderer put toolbar items
       into real navigation/bottom bars — leading back affordance, centered
       principal title, and trailing icon-only actions grouped in a capsule.
       lui has no chrome node, so the shim reproduces that layout inline. *)
    let mount_icon_only (item : item) : Lui_elements.t =
      fun context parent ->
      let previous = !icon_only
      and previous_nodes = !icon_only_collapsed_nodes in
      icon_only := true;
      icon_only_collapsed_nodes := [];
      Fun.protect
        ~finally:(fun () ->
          icon_only := previous;
          icon_only_collapsed_nodes := previous_nodes)
        (fun () ->
           let mounted = item.content.mount context parent in
           if mounted <> 0
           then (
             Lui_ui.key context mounted item.item_key;
             (* Uniform 40pt control cell so capsule widths are predictable —
                 applied to each leaf control that collapsed to its icon. *)
             List.iter
               (fun node ->
                  if node_is_standard context node then Lui_ui.width context node 40)
               !icon_only_collapsed_nodes);
           mounted)
    ;;

    let nav_button ~icon ~label ~on_press : Lui_elements.t =
      (* Icon-only button: the schema rejects empty text + icon without an
         accessibility label. *)
      Lui_elements.button
        ~text:""
        ~label
        ~icon:(journal_icon icon)
        ~variant:`ghost
        ~foreground:"foreground"
        ~on_press:(fun _ -> on_press ())
        []
    ;;

    let flexible_space : Lui_elements.t = Lui_elements.spacer ~grow:1.0 []

    let mount_items items =
      element (fun context parent ->
        (* Items hoist into the platform chrome by placement: each
           `placement` toolbar emits its children as system ToolbarItems
           (the navigation bar's leading/principal/trailing areas on iOS,
           the window toolbar on macOS) — groups fuse into one capsule.
           Hosts without chrome hoisting render the toolbar's inline row
           content instead, so this row keeps the emulated arrangement. *)
        let emit_bar placement children : Lui_elements.t =
          fun context parent ->
          let toolbar =
            Lui_elements.toolbar
              ~label:"navigation"
              ~toolbar_gap:16
              children
              context
              parent
          in
          Lui_ui.placement context toolbar placement;
          toolbar
        in
        let of_placement p =
          List.filter (fun (item : item) -> item.placement = Some p) items
        in
        let navigation = of_placement Navigation
        and cancellation = of_placement Cancellation_action
        and principal = of_placement Principal in
        let nav_can_pop =
          match !nav_bar with
          | Some { nav_can_pop = true; _ } -> true
          | _ -> false
        in
        Lui_elements.row
          ~gap:8
          ~cross:`center
          ~padding_horizontal:10
          ~padding_vertical:4
          ((if nav_can_pop || navigation <> []
            then
              [ emit_bar
                  "navigation"
                  ((match !nav_bar with
                    | Some { nav_can_pop = true; nav_on_change; nav_remaining; _ } ->
                      [ nav_button ~icon:"chevron.left" ~label:"Back" ~on_press:(fun () ->
                          invoke
                            nav_on_change
                            (Event.Payload.Navigation_path_changed nav_remaining))
                      ]
                    | _ -> [])
                   @ List.map mount_icon_only navigation)
              ]
            else [])
           @ (if cancellation <> []
              then
                [ emit_bar "cancellation-action" (List.map mount_icon_only cancellation) ]
              else [])
           @ [ flexible_space ]
           @ (match principal, !nav_bar with
              | [], Some { nav_title = title; _ } when title <> "" ->
                [ emit_bar
                    "principal"
                    [ Lui_elements.text ~value:title ~style_class:"semibold" [] ]
                ]
              | [], _ -> []
              | _ :: _, _ ->
                [ emit_bar
                    "principal"
                    (List.map
                       (fun (item : item) (context : Lui_ui.ui_context) parent ->
                          let mounted = item.content.mount context parent in
                          if mounted <> 0
                          then (
                            Lui_ui.key context mounted item.item_key;
                            if node_is_standard context mounted
                            then Lui_ui.style_class context mounted "semibold");
                          mounted)
                       principal)
                ])
           @ [ flexible_space ]
           @ List.concat_map
               (fun (placement, items) ->
                  if items <> []
                  then [ emit_bar placement (List.map mount_icon_only items) ]
                  else [])
               [ "primary-action", of_placement Primary_action
               ; "automatic", List.filter (fun (i : item) -> i.placement = None) items
               ; "status", of_placement Status
               ; "confirmation-action", of_placement Confirmation_action
               ; "destructive-action", of_placement Destructive_action
               ; "secondary-action", of_placement Secondary_action
               ])
          context
          parent)
    ;;

    let mount_bottom_bar items =
      element (fun context parent ->
        (* A `placement "bottom"` toolbar maps to the platform bottom bar on
           iOS — the system renders each group as a floating glass capsule,
           spacers flex between them, and scroll content insets around the
           bar. Groups need a button-group child so the bar renders one
           capsule per group instead of one capsule per button. *)
        let toolbar =
          Lui_elements.toolbar
            ~label:"actions"
            ~toolbar_gap:16
            (List.map
               (fun (item : item) ->
                  match item.spacing with
                  | Some _ -> Lui_elements.spacer []
                  | None ->
                    if item.is_group
                    then Lui_elements.button_group [ mount_icon_only item ]
                    else mount_icon_only item)
               items)
            context
            parent
        in
        Lui_ui.placement context toolbar "bottom";
        toolbar)
    ;;

    let create ?key ~items t =
      element ?key (fun context parent ->
        let top, bottom =
          List.partition (fun (item : item) -> item.placement <> Some Bottom_bar) items
        in
        Lui_elements.column
          ~grow:1.0
          ((if
              top <> []
              || Option.fold ~none:false ~some:(fun bar -> bar.nav_can_pop) !nav_bar
            then [ (mount_items top).mount ]
            else [])
           @ [ (fun context parent ->
                 let body = t.mount context parent in
                 if node_is_standard context body then Lui_ui.grow context body 1.0;
                 body)
             ]
           @ if bottom <> [] then [ (mount_bottom_bar bottom).mount ] else [])
          context
          parent)
    ;;
  end

  let parent_overlay = overlay

  module Body = struct
    type nonrec t = t
    type widget = t

    let with_size ~width ~height t = frame ~width ~height t
    let static t = t
    let with_test_id id t = with_test_id id t
    let padding ~insets t = padding ~insets t
    let background ?corner_radius ~color t = background ?corner_radius ~color t
    let semantics ~properties t = semantics ~properties t
    let ignores_safe_area ?regions ?edges t = ignores_safe_area ?regions ?edges t
    let safe_area_padding ~insets t = safe_area_padding ~insets t
    let theme ~data t = theme ~data t
    let toolbar ?key:_ ~items t = Toolbar.create ~items t
    let overlay ?key ?alignment ~overlay t = parent_overlay ?key ?alignment ~overlay t

    module Vertical = struct
      type child = t

      let fixed t = t

      let fill ?(weight = 1.) t =
        modify (fun context node -> Lui_ui.grow context node weight) t
      ;;

      let create ?key children = column ?key children
    end

    module Horizontal = struct
      type child = t

      let fixed t = t

      let fill ?(weight = 1.) t =
        modify (fun context node -> Lui_ui.grow context node weight) t
      ;;

      let create ?key children = row ?key children
    end

    module Private = struct
      let to_widget t = t
    end
  end

  module Viewport = struct
    module Vertical = struct
      type nonrec t = t

      let with_test_id id t = with_test_id id t
      let padding ~insets t = padding ~insets t
      let background ?corner_radius ~color t = background ?corner_radius ~color t
      let semantics ~properties t = semantics ~properties t
      let ignores_safe_area ?regions ?edges t = ignores_safe_area ?regions ?edges t
      let safe_area_padding ~insets t = safe_area_padding ~insets t
      let theme ~data t = theme ~data t
      let overlay ?key ?alignment ~overlay t = parent_overlay ?key ?alignment ~overlay t
      let with_height ~height t = frame ~height t
    end

    module Horizontal = struct
      type nonrec t = t

      let with_test_id id t = with_test_id id t
      let with_width ~width t = frame ~width t
    end
  end

  module Scroll = struct
    type anchor =
      | Start
      | End

    let vertical
          ?key
          ?on_scroll:_
          ?shows_indicators:_
          ?fill_viewport:_
          ?initial_anchor:_
          t
      =
      element ?key (Lui_elements.scroll [ t.mount ])
    ;;
  end

  module Swipe_actions = struct
    type side =
      | Start
      | End

    type action =
      { key : string
      ; enabled : bool
      ; role : Button_role.t
      ; symbol : string option
      ; side : side
      ; title : string
      ; background : Style.Color.t
      ; on_press : Event.handler
      }

    type nonrec t = action list

    let action
          ~key
          ?(enabled = true)
          ?(role = Button_role.Normal)
          ?symbol
          ~side
          ~title
          ~background
          ~on_press
          ()
      =
      { key; enabled; role; symbol; side; title; background; on_press }
    ;;

    let create ?enabled:_ ?allows_full_swipe:_ ~actions () = actions
  end

  module Context_menu = struct
    type nonrec view = t

    type role =
      | Normal
      | Destructive

    type action =
      { key : string
      ; enabled : bool
      ; role : role
      ; symbol : string option
      ; title : string
      ; on_press : Event.handler
      }

    type nonrec t = action list

    let action ~key ?(enabled = true) ?(role = Normal) ?symbol ~title ~on_press () =
      { key; enabled; role; symbol; title; on_press }
    ;;

    let create ?enabled:_ ~actions () = actions

    let attach ?key:_ actions (view : element_) =
      element ?key:view.key (fun context parent ->
        let node = view.mount context parent in
        ignore
          (Lui_elements.context_menu
             (List.map
                (fun (action : action) ->
                   Lui_elements.menu_item
                     ~text:action.title
                     ?icon:(Option.map journal_icon action.symbol)
                     ?variant:
                       (match action.role with
                        | Normal -> None
                        | Destructive -> Some `destructive)
                     ~disabled:(not action.enabled)
                     ~on_press:(fun _ -> invoke action.on_press Event.Payload.Unit)
                     [])
                actions)
             context
             (Some node));
        node)
    ;;
  end

  module Confirmation = struct
    type action =
      { key : string
      ; title : string
      ; enabled : bool
      ; role : Button_role.t
      }

    type request =
      { token : int64
      ; title : string
      ; message : string option
      ; actions : action list
      }

    let action ~key ~title ?(enabled = true) ?(role = Button_role.Normal) () =
      { key; title; enabled; role }
    ;;

    let request ~token ~title ?message actions = { token; title; message; actions }

    let alert ?key:_ ~request ~on_response (view : element_) =
      element ?key:view.key (fun context parent ->
        match request with
        | None -> view.mount context parent
        | Some request ->
          let node =
            match parent with
            | Some parent -> parent
            | None -> view.mount context None
          in
          ignore (view.mount context (Some node));
          ignore
            (Lui_elements.dialog
               ~text:request.title
               ?description:request.message
               ~on_dismiss:(fun _ ->
                 invoke
                   on_response
                   (Event.Payload.Confirmation_response
                      { token = request.token; result = Dismissed }))
               (List.map
                  (fun (action : action) ->
                     Lui_elements.button
                       ~text:action.title
                       ~disabled:(not action.enabled)
                       ?variant:(Button_role.lui_variant action.role)
                       ~on_press:(fun _ ->
                         invoke
                           on_response
                           (Event.Payload.Confirmation_response
                              { token = request.token; result = Action action.key }))
                       [])
                  request.actions)
               context
               (Some node));
          node)
    ;;

    let dialog ?key ~request ~on_response view = alert ?key ~request ~on_response view
  end

  module Native_list = struct
    type anchor =
      | Top
      | Center
      | Bottom

    type target =
      { section : string
      ; row_path : string list
      }

    type scroll_request =
      { token : int64
      ; target : target
      ; anchor : anchor option
      ; animated : bool option
      }

    type outcome = Event.Payload.native_list_outcome
    type completion = Event.Payload.native_list_completion

    let target ~section ~row_path = { section; row_path }

    let scroll_request ~token ~target ?anchor ?animated () =
      { token; target; anchor; animated }
    ;;

    let completion_of_payload = function
      | Event.Payload.Native_list_completion completion -> Some completion
      | _ -> None
    ;;

    type style =
      | Plain
      | Inset
      | Inset_grouped

    let style_name = function
      | Plain -> "plain"
      | Inset -> "inset"
      | Inset_grouped -> "inset_grouped"
    ;;

    type separator =
      | Automatic
      | Hidden
      | Visible

    let separator_name = function
      | Automatic -> "automatic"
      | Hidden -> "hidden"
      | Visible -> "visible"
    ;;

    type row_kind =
      | Row
      | Disclosure of
          { expanded : bool
          ; children : row list
          }

    and row =
      { key : string
      ; test_id : string option
      ; separator : separator
      ; swipe_actions : Swipe_actions.t option
      ; context_menu : Context_menu.t option
      ; kind : row_kind
      ; content : t
      ; on_expanded_changed : Event.handler option
      }

    type section =
      { section_key : string
      ; header : t option
      ; footer : t option
      ; separator : separator
      ; rows : row list
      }

    let row ~key ?test_id ?(separator = Automatic) ?swipe_actions ?context_menu content =
      { key
      ; test_id
      ; separator
      ; swipe_actions
      ; context_menu
      ; kind = Row
      ; content
      ; on_expanded_changed = None
      }
    ;;

    let disclosure_row
          ~key
          ?test_id
          ?(separator = Automatic)
          ?swipe_actions
          ?context_menu
          ~expanded
          ~on_expanded_changed
          ~label
          children
      =
      { key
      ; test_id
      ; separator
      ; swipe_actions
      ; context_menu
      ; kind = Disclosure { expanded; children }
      ; content = label
      ; on_expanded_changed = Some on_expanded_changed
      }
    ;;

    let section ~key ?header ?footer ?(separator = Automatic) rows =
      { section_key = key; header; footer; separator; rows }
    ;;

    let swipe_json (actions : Swipe_actions.t) =
      `Assoc
        [ ( "actions"
          , `List
              (List.map
                 (fun (a : Swipe_actions.action) ->
                    `Assoc
                      [ "key", `String a.key
                      ; "enabled", `Bool a.enabled
                      ; "role", `String (Button_role.variant a.role)
                      ; ( "symbol"
                        , match a.symbol with
                          | Some s -> `String s
                          | None -> `Null )
                      ; ( "side"
                        , `String
                            (match a.side with
                             | Start -> "start"
                             | End -> "end") )
                      ; "title", `String a.title
                      ; "background", `String a.background
                      ])
                 actions) )
        ]
    ;;

    let context_menu_json (actions : Context_menu.t) =
      `Assoc
        [ ( "actions"
          , `List
              (List.map
                 (fun (a : Context_menu.action) ->
                    `Assoc
                      [ "key", `String a.key
                      ; "enabled", `Bool a.enabled
                      ; ( "role"
                        , `String
                            (match a.role with
                             | Normal -> "normal"
                             | Destructive -> "destructive") )
                      ; ( "symbol"
                        , match a.symbol with
                          | Some s -> `String s
                          | None -> `Null )
                      ; "title", `String a.title
                      ])
                 actions) )
        ]
    ;;

    (* Content elements (headers, rows, footers, disclosure labels) mount as
     extension children in a deterministic order; the payload lists their
     index so the host binds each child node to its list position. *)
    let build sections ~style ~scroll_request ~track_visible ~track_scroll =
      let contents = ref [] in
      let push element =
        contents := !contents @ [ element ];
        List.length !contents - 1
      in
      let rec row_json (row : row) =
        let content_index = push row.content in
        let base =
          [ "key", `String row.key
          ; "content_index", `Int content_index
          ; "separator", `String (separator_name row.separator)
          ]
        in
        let base =
          match row.test_id with
          | Some id -> ("test_id", `String id) :: base
          | None -> base
        in
        let base =
          match row.swipe_actions with
          | Some actions -> ("swipe", swipe_json actions) :: base
          | None -> base
        in
        let base =
          match row.context_menu with
          | Some menu -> ("context_menu", context_menu_json menu) :: base
          | None -> base
        in
        match row.kind with
        | Row -> `Assoc (("type", `String "row") :: base)
        | Disclosure { expanded; children } ->
          `Assoc
            (("type", `String "disclosure")
             :: ("expanded", `Bool expanded)
             :: ("children", `List (List.map row_json children))
             :: base)
      in
      let section_json (section : section) =
        `Assoc
          [ "key", `String section.section_key
          ; "separator", `String (separator_name section.separator)
          ; ( "header_index"
            , match section.header with
              | Some header -> `Int (push header)
              | None -> `Null )
          ; ( "footer_index"
            , match section.footer with
              | Some footer -> `Int (push footer)
              | None -> `Null )
          ; "rows", `List (List.map row_json section.rows)
          ]
      in
      let payload =
        `Assoc
          [ "style", `String (style_name style)
          ; "sections", `List (List.map section_json sections)
          ; ( "scroll_request"
            , match scroll_request with
              | None -> `Null
              | Some request ->
                `Assoc
                  [ "token", `String (Int64.to_string request.token)
                  ; ( "target"
                    , `Assoc
                        [ "section", `String request.target.section
                        ; ( "row_path"
                          , `List
                              (List.map (fun key -> `String key) request.target.row_path)
                          )
                        ] )
                  ; ( "anchor"
                    , match request.anchor with
                      | Some Top -> `String "top"
                      | Some Center -> `String "center"
                      | Some Bottom -> `String "bottom"
                      | None -> `Null )
                  ; ( "animated"
                    , match request.animated with
                      | Some value -> `Bool value
                      | None -> `Null )
                  ] )
          ; "track_visible_range", `Bool track_visible
          ; "track_scroll_completion", `Bool track_scroll
          ]
      in
      Yojson.Basic.to_string payload, List.rev !contents |> List.rev
    ;;

    let decode_outcome = function
      | `String "succeeded" -> Event.Payload.Succeeded
      | `String "missing_target" -> Missing_target
      | `String "cancelled" -> Cancelled
      | `String "superseded" -> Superseded
      | `String "positioning_failed" -> Positioning_failed
      | _ -> Positioning_failed
    ;;

    let vertical
          ?key
          ~style
          ?scroll_request
          ?on_scroll_completed
          ?on_visible_range
          ?(on_row_event : Event.handler option)
          sections
      =
      let payload, contents =
        build
          sections
          ~style
          ~scroll_request
          ~track_visible:(Option.is_some on_visible_range)
          ~track_scroll:(Option.is_some on_scroll_completed)
      in
      (* Expansion state arrives as {"type":"expanded","key":..,"expanded":bool};
       the owning row's handler receives Bool like the old disclosure callback. *)
      let expanded_handlers =
        let rec collect acc (row : row) =
          match row.kind with
          | Row -> acc
          | Disclosure { children; _ } ->
            List.fold_left collect ((row.key, row.on_expanded_changed) :: acc) children
        in
        List.fold_left
          (fun acc section -> List.fold_left collect acc section.rows)
          []
          sections
      in
      let on_event (event : Journal_lui_native.event) =
        match
          try Yojson.Basic.from_string event.payload with
          | _ -> `Null
        with
        | `Assoc fields ->
          (match List.assoc_opt "type" fields with
           | Some (`String "visible_range") ->
             Option.iter
               (fun handler ->
                  let get_int64 name =
                    match List.assoc_opt name fields with
                    | Some (`Int v) -> Int64.of_int v
                    | Some (`String s) -> Int64.of_string s
                    | _ -> 0L
                  in
                  invoke
                    handler
                    (Event.Payload.Visible_range
                       { first_index = get_int64 "first"
                       ; last_exclusive = get_int64 "last"
                       }))
               on_visible_range
           | Some (`String "scroll_completed") ->
             Option.iter
               (fun handler ->
                  let token =
                    match List.assoc_opt "token" fields with
                    | Some (`Int v) -> Int64.of_int v
                    | Some (`String s) -> Int64.of_string s
                    | _ -> 0L
                  in
                  let outcome =
                    match List.assoc_opt "outcome" fields with
                    | Some json -> decode_outcome json
                    | None -> Event.Payload.Positioning_failed
                  in
                  invoke handler (Event.Payload.Native_list_completion { token; outcome }))
               on_scroll_completed
           | Some (`String "expanded") ->
             (match List.assoc_opt "key" fields, List.assoc_opt "expanded" fields with
              | Some (`String key), Some (`Bool expanded) ->
                List.iter
                  (fun (row_key, handler) ->
                     if String.equal row_key key
                     then
                       Option.iter
                         (fun handler -> invoke handler (Event.Payload.Bool expanded))
                         handler)
                  expanded_handlers
              | _ -> ())
           | Some (`String "row_event") ->
             Option.iter
               (fun handler ->
                  match List.assoc_opt "payload" fields with
                  | Some (`String payload) ->
                    invoke
                      handler
                      (Event.Payload.Native_event
                         { kind_id = Journal_ids.Native_widget.Kind_id.of_int 0
                         ; version = 0
                         ; event_id = event.event_id
                         ; payload = Bytes.of_string payload
                         })
                  | _ -> ())
               on_row_event
           | _ -> ())
        | _ -> ()
      in
      element ?key (fun context parent ->
        Journal_lui_native.mount
          ?key
          ~payload
          ~children:(List.map (fun element -> element.mount) contents)
          ~on_event
          Journal_lui_native.list_identifier
          context
          parent)
    ;;
  end

  module Navigation_link = struct
    let create ?key ~activation_id:_ ?(enabled = true) ~on_activate ~label () =
      element
        ?key
        (Lui_elements.list_item
           ~disabled:(not enabled)
           ?on_press:
             (if enabled
              then Some (fun _ -> invoke on_activate Event.Payload.Unit)
              else None)
             (* NavigationLink draws a trailing disclosure accessory; LUI list
              items have none, so carry the chevron as an inline trailing
              icon. *)
           ~icon:(journal_icon "chevron.right")
           ~icon_placement:`trailing
           (* A list-item must carry text or children; mount the label as the
              item content so composite labels render too. *)
           [ label.mount ])
    ;;
  end

  module Navigation_stack = struct
    type destination =
      { page_key : string
      ; title : string
      ; can_pop : bool
      ; content : t
      }

    let destination ~page_key ~title ~can_pop content =
      { page_key; title; can_pop; content }
    ;;

    (* The lui widget set has no navigation-stack node.  The router stays in the
       model: the topmost destination renders, and the pop affordance
       [Toolbar.mount_items] renders from [nav_bar].  [title] maps to the
       system navigation title, which the chrome hides — an empty title
       renders no bar content. *)
    let create ?key ~title ~on_path_change ~path root =
      element ?key (fun context parent ->
        let top =
          match List.rev path with
          | [] -> None
          | top :: _ -> Some top
        in
        let keys = List.map (fun (d : destination) -> d.page_key) path in
        let remaining =
          match List.rev keys with
          | [] -> []
          | _ :: rest -> List.rev rest
        in
        let previous = !nav_bar in
        nav_bar
        := Some
             { nav_on_change = on_path_change
             ; nav_remaining =
                 List.map Journal_ids.Navigation.Page_key.of_string remaining
             ; nav_can_pop =
                 (match top with
                  | Some destination -> destination.can_pop
                  | None -> false)
             ; nav_title =
                 (match top with
                  | Some destination -> destination.title
                  | None -> title)
             };
        Fun.protect
          ~finally:(fun () -> nav_bar := previous)
          (fun () ->
             (* Fill the hosting column so the emulated bar rows pin to the top
             instead of the whole page centering vertically. *)
             Lui_elements.column
               ~grow:1.0
               [ (fun context parent ->
                   let mounted =
                     match top with
                     | None -> root.mount context parent
                     | Some destination -> destination.content.mount context parent
                   in
                   (* Extension nodes live outside the standard prop store —
                    set_prop on one raises; they expand through their own
                    SwiftUI views. *)
                   if node_is_standard context mounted
                   then Lui_ui.grow context mounted 1.0;
                   mounted)
               ]
               context
               parent))
    ;;
  end

  module Sheet = struct
    type sizing =
      | Automatic
      | Form
      | Fitted

    type detent =
      | Medium
      | Large

    let create
          ?key
          ~presented
          ~on_presented_changed
          ?(interactive_dismiss = true)
          ?sizing:_
          ?detents:_
          ?(title = "")
          ~content
          base
      =
      element ?key (fun context parent ->
        Lui_elements.column
          ~grow:1.0
          (base.mount
           ::
           (if presented
            then
              [ Lui_elements.sheet
                  ~text:(if String.equal title "" then "Sheet" else title)
                  ?on_dismiss:
                    (if interactive_dismiss
                     then
                       Some
                         (fun _ -> invoke on_presented_changed (Event.Payload.Bool false))
                     else None)
                  [ content.mount ]
              ]
            else []))
          context
          parent)
    ;;
  end

  module Picker = struct
    type style =
      | Automatic
      | Menu
      | Segmented
      | Inline

    type choice =
      { id : int64
      ; enabled : bool
      ; label : t
      }

    let option ~id ?(enabled = true) ?(label = empty ()) () = { id; enabled; label }

    let create
          ?key
          ?label:_
          ?(style = Automatic)
          ?(enabled = true)
          ~selected_id
          ~on_select
          choices
          ()
      =
      element ?key (fun context parent ->
        let choice_radio (choice : choice) : Lui_elements.radio_el =
          Lui_elements.radio
            ~key:(Int64.to_string choice.id)
            ~disabled:(not choice.enabled)
            ?checked:
              (match selected_id with
               | Some selected when selected = choice.id -> Some true
               | _ -> None)
            ~on_press:(fun _ -> invoke on_select (Event.Payload.Int64 choice.id))
            ~on_toggle:(fun event ->
              match event with
              | Lui_protocol.ToggleChanged (_, true) ->
                invoke on_select (Event.Payload.Int64 choice.id)
              | _ -> ())
            ?accessibility_identifier:choice.label.test_id
            [ leaf_label choice.label.label_content ]
        in
        let node =
          (match style with
           | Segmented ->
             (* [toggle_group] accepts only plain elements, so its [radio]
                items mount through an in-place hook on the raw path. *)
             Lui_elements.toggle_group
               [ Lui_elements.dynamic (fun context group ->
                   List.iter
                     (fun (choice : choice) ->
                        let item = Lui_ui.radio context in
                        Lui_ui.key context item (Int64.to_string choice.id);
                        if not choice.enabled then Lui_ui.disabled context item true;
                        (match selected_id with
                         | Some selected when selected = choice.id ->
                           Lui_ui.bool_property context item Lui_protocol.Checked true
                         | _ -> ());
                        Lui_ui.on_event context item (fun event ->
                          match event with
                          | Lui_protocol.Press _ | ToggleChanged (_, true) ->
                            invoke on_select (Event.Payload.Int64 choice.id)
                          | _ -> ());
                        Option.iter
                          (set_leaf_label context item)
                          choice.label.label_content;
                        Option.iter
                          (Lui_ui.accessibility_identifier context item)
                          choice.label.test_id;
                        Lui_ui.append context group item)
                     choices)
               ]
           | Automatic | Menu | Inline ->
             Lui_elements.radio_group (List.map choice_radio choices))
            context
            parent
        in
        if not enabled then Lui_ui.disabled context node true;
        node)
    ;;
  end

  module Menu = struct
    type label =
      { title : string
      ; icon : string option
      }

    type entry =
      | Action of
          { id : int64
          ; label : label
          ; enabled : bool
          ; role : Button_role.t
          }
      | Choice of
          { id : int64
          ; label : label
          ; selected : bool
          ; enabled : bool
          }
      | Divider of int64
      | Section of
          { id : int64
          ; label : label option
          ; entries : entry list
          }
      | Submenu of
          { id : int64
          ; label : label
          ; enabled : bool
          ; entries : entry list
          }

    let action ~id ~title ?icon ?(enabled = true) ?(role = Button_role.Normal) () =
      Action { id; label = { title; icon }; enabled; role }
    ;;

    let choice ~id ~title ?icon ~selected ?(enabled = true) () =
      Choice { id; label = { title; icon }; selected; enabled }
    ;;

    let divider ~id = Divider id

    let section ~id ?title ?icon entries =
      Section { id; label = Option.map (fun title -> { title; icon }) title; entries }
    ;;

    let submenu ~id ~title ?icon ?(enabled = true) entries =
      Submenu { id; label = { title; icon }; enabled; entries }
    ;;

    (* lui menus are declarative: a [menu_item] holding one [dropdown_menu]
       child renders as a native popup menu, and menu rows carry their label
       and icon as properties (menu items accept only menu children). *)
    let menu_item ?key ~title ~icon ~enabled ~role ~selected ?on_press () : Lui_elements.t
      =
      (* menu-item requires non-empty text; a blank space keeps icon-only
         triggers visually identical without violating the schema. *)
      Lui_elements.menu_item
        ?key
        ~text:(if String.length title = 0 then " " else title)
        ?icon:(Option.map journal_icon icon)
        ~disabled:(not enabled)
        ?variant:(Button_role.lui_variant role)
        ?selected
        ?on_press:(Option.map (fun press _ -> press ()) on_press)
        []
    ;;

    let create ?key ?(enabled = true) ~on_select ~title ?icon entries =
      let rec entry_elements (entry : entry) : Lui_elements.t list =
        match entry with
        | Divider id ->
          [ Lui_elements.separator ~key:(Int64.to_string id) ~orientation:`horizontal [] ]
        | Action { id; label; enabled; role } ->
          [ menu_item
              ~key:(Int64.to_string id)
              ~title:label.title
              ~icon:label.icon
              ~enabled
              ~role
              ~selected:None
              ~on_press:(fun () -> invoke on_select (Event.Payload.Int64 id))
              ()
          ]
        | Choice { id; label; selected; enabled } ->
          [ menu_item
              ~key:(Int64.to_string id)
              ~title:label.title
              ~icon:label.icon
              ~enabled
              ~role:Button_role.Normal
              ~selected:(Some selected)
              ~on_press:(fun () -> invoke on_select (Event.Payload.Int64 id))
              ()
          ]
        | Section { label; entries; _ } ->
          (match label with
           | Some label ->
             [ menu_item
                 ~title:label.title
                 ~icon:label.icon
                 ~enabled:false
                 ~role:Button_role.Normal
                 ~selected:None
                 ()
             ]
           | None -> [])
          @ List.concat_map entry_elements entries
        | Submenu { id; label; enabled; entries } ->
          [ Lui_elements.submenu
              ~key:(Int64.to_string id)
              ~text:(if String.length label.title = 0 then " " else label.title)
              ?icon:(Option.map journal_icon label.icon)
              ~disabled:(not enabled)
              (List.concat_map entry_elements entries)
          ]
      in
      element
        ?key
        (Lui_elements.menu_item
           ~text:(if String.length title = 0 then " " else title)
           ?icon:(Option.map journal_icon icon)
           ~disabled:(not enabled)
             (* Icon-only trigger: keep the menu label from stretching to fill
              the available width inside bar capsules, and use the smaller
              menu-item icon size the system bar showed. *)
           ?width:(if String.length title = 0 then Some 20 else None)
           ?size:(if String.length title = 0 then Some `sm else None)
           [ Lui_elements.dropdown_menu (List.concat_map entry_elements entries) ])
    ;;
  end
end

module Native_widget = struct
  module Capability = struct
    type t =
      | Stateful
      | Resource
      | Semantics
      | Semantics_canvas
      | Virtualized

    let bit = function
      | Stateful -> 0L
      | Resource -> 1L
      | Semantics -> 2L
      | Semantics_canvas -> 3L
      | Virtualized -> 4L
    ;;

    let bits capabilities =
      List.fold_left
        (fun acc capability ->
           Int64.logor acc (Int64.shift_left 1L (Int64.to_int (bit capability))))
        0L
        capabilities
    ;;
  end

  module Extension = struct
    type ('props, 'event) t =
      { identifier : string
      ; kind_id : Journal_ids.Native_widget.Kind_id.t
      ; version : int
      ; encode_props : 'props -> bytes
      ; decode_event :
          event_id:Journal_ids.Native_widget.Event_id.t
          -> bytes
          -> ('event, string) result
      }

    let identifier_of_kind_id kind_id =
      match Journal_ids.Native_widget.Kind_id.to_int kind_id with
      | 2103 -> Journal_lui_native.chrome_identifier
      | 2104 -> Journal_lui_native.asset_import_identifier
      | 2105 -> Journal_lui_native.media_identifier
      | 2106 -> Journal_lui_native.asset_settings_identifier
      | other -> invalid_arg ("unregistered journal extension kind " ^ string_of_int other)
    ;;

    let create ~kind_id ~version ~capabilities:_ ~encode_props ~decode_event () =
      { identifier = identifier_of_kind_id kind_id
      ; kind_id
      ; version
      ; encode_props
      ; decode_event
      }
    ;;
  end

  let decode extension event =
    extension.Extension.decode_event
      ~event_id:
        (Journal_ids.Native_widget.Event_id.of_int event.Journal_lui_native.event_id)
      (Bytes.of_string event.Journal_lui_native.payload)
  ;;

  let event_handler ?name:_ extension callback =
    Event.Handler.create (fun payload ->
      match payload with
      | Event.Payload.Native_event { event_id; payload; _ } ->
        (match
           extension.Extension.decode_event
             ~event_id:(Journal_ids.Native_widget.Event_id.of_int event_id)
             payload
         with
         | Ok event -> callback event
         | Error _ -> ())
      | _ -> ())
  ;;

  let mount extension ?key ~props ~on_event ~children context parent =
    let payload = Bytes.to_string (extension.Extension.encode_props props) in
    (* journal-chrome slots 1..3 (account / error / progress) are the floating
       chrome affordances the old host rendered as icon-only circles. Mount
       them under the icon-only collapse; slot 0 is page content and stays
       uncollapsed. *)
    let chrome_slots =
      extension.Extension.identifier = Journal_lui_native.chrome_identifier
    in
    let children =
      List.mapi
        (fun index element ->
           if chrome_slots && index > 0
           then (
             fun context parent ->
               let previous = !icon_only
               and previous_nodes = !icon_only_collapsed_nodes in
               icon_only := true;
               icon_only_collapsed_nodes := [];
               Fun.protect
                 ~finally:(fun () ->
                   icon_only := previous;
                   icon_only_collapsed_nodes := previous_nodes)
                 (fun () ->
                    let mounted = element.mount context parent in
                    List.iter
                      (fun node ->
                         if node_is_standard context node
                         then Lui_ui.width context node 40)
                      !icon_only_collapsed_nodes;
                    mounted))
           else element.mount)
        children
    in
    Journal_lui_native.mount
      ?key
      ~payload
      ~children
      ~on_event:(fun event ->
        match decode extension event with
        | Ok decoded -> on_event decoded
        | Error _ -> ())
      extension.Extension.identifier
      context
      parent
  ;;

  let widget extension ?key ~props ~on_event ?(children = []) () =
    element ?key (mount extension ~props ~on_event ~children)
  ;;

  let widget_with_handler extension ?key ~props ~on_event ?(children = []) () =
    element ?key (fun context parent ->
      let payload = Bytes.to_string (extension.Extension.encode_props props) in
      Journal_lui_native.mount
        ?key
        ~payload
        ~children:(List.map (fun element -> element.mount) children)
        ~on_event:(fun event ->
          Event.Handler.Private.invoke
            on_event
            (Event.Payload.Native_event
               { kind_id = extension.Extension.kind_id
               ; version = extension.Extension.version
               ; event_id = event.Journal_lui_native.event_id
               ; payload = Bytes.of_string event.Journal_lui_native.payload
               }))
        extension.Extension.identifier
        context
        parent)
  ;;
end
