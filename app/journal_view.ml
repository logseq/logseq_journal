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
  then (
    if supported Lui_protocol.TextValue
    then Lui_ui.text_property context node title)
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
    then
      Lui_ui.string_property context node Lui_protocol.VariantValue "ghost";
    if supported Lui_protocol.ForegroundValue
    then Lui_ui.foreground context node "secondary");
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

    let to_lui = function
      | Leading -> "start"
      | Center -> "center"
      | Trailing -> "end"
    ;;
  end

  module Vertical_alignment = struct
    type t =
      | Top
      | Center
      | Bottom

    let to_lui = function
      | Top -> "start"
      | Center -> "center"
      | Bottom -> "end"
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
  end

  module Button_style = struct
    type t =
      | Automatic
      | Plain
      | Bordered
      | Prominent
      | Button

    let variant = function
      | Plain -> "ghost"
      | Bordered -> "outline"
      | Prominent -> "primary"
      | Button -> "default"
      | Automatic -> "default"
    ;;
  end

  module Progress_style = struct
    type t =
      | Linear
      | Circular
  end

  let is_press = function
    | Lui_protocol.Press _ -> true
    | _ -> false
  ;;

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
    { (element ?key (fun context parent ->
         let node = Lui_ui.text context value in
         Option.iter
           (fun (style : Style.Text_style.t) ->
              (match style.foreground with
               | Some Style.Text_style.Secondary ->
                 Lui_ui.foreground context node "secondary"
               | Some Primary | None -> ());
              match style.font_weight with
              | Some Style.Text_style.Semi_bold ->
                Lui_ui.style_class context node "semibold"
              | Some Regular | None -> ())
           style;
         (match parent with
          | Some parent -> Lui_ui.append context parent node
          | None -> ());
         node))
      with
      label_content = Some { title = value; icon = None }
    }
  ;;

  let symbol ?key ?size ?color ?rendering:_ ~name () =
    { (element ?key (fun context parent ->
         let node = Lui_ui.icon context (journal_icon_name name) in
         Option.iter
           (fun size -> Lui_ui.size context node (string_of_int (int_of_float_nan size)))
           size;
         Option.iter (fun color -> Lui_ui.foreground context node color) color;
         (match parent with
          | Some parent -> Lui_ui.append context parent node
          | None -> ());
         node))
      with
      label_content = Some { title = ""; icon = Some name }
    }
  ;;

  let label ?key ~title ~icon () =
    { (element ?key (fun context parent ->
         let node = Lui_ui.row context in
         (match parent with
          | Some parent -> Lui_ui.append context parent node
          | None -> ());
         ignore (icon.mount context (Some node));
         ignore (title.mount context (Some node));
         node))
      with
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

  let divider ?key () =
    element ?key (fun context parent ->
      let node = Lui_ui.separator context "horizontal" in
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      node)
  ;;

  let progress ?key ?value ?(style = Progress_style.Linear) () =
    element ?key (fun context parent ->
      let node =
        match style, value with
        | Progress_style.Circular, _ -> Lui_ui.spinner context
        | Linear, Some value -> Lui_ui.progress_literal context value
        | Linear, None -> Lui_ui.spinner context
      in
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      node)
  ;;

  let spacer ?key ?min_length:_ () =
    element ?key (fun context parent ->
      let node = Lui_ui.spacer context in
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      node)
  ;;

  let row ?key ?(spacing = 16.) ?(alignment = Layout.Vertical_alignment.Center) children =
    element ?key (fun context parent ->
      let node = Lui_ui.row context in
      Lui_ui.gap context node (int_of_float_nan spacing);
      Lui_ui.cross context node (Layout.Vertical_alignment.to_lui alignment);
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      List.iter (fun child -> ignore (child.mount context (Some node))) children;
      node)
  ;;

  let column
        ?key
        ?(spacing = 16.)
        ?(alignment = Layout.Horizontal_alignment.Center)
        children
    =
    element ?key (fun context parent ->
      let node = Lui_ui.column context in
      Lui_ui.gap context node (int_of_float_nan spacing);
      Lui_ui.cross context node (Layout.Horizontal_alignment.to_lui alignment);
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      List.iter (fun child -> ignore (child.mount context (Some node))) children;
      node)
  ;;

  let stack ?key ?alignment:_ children =
    element ?key (fun context parent ->
      let node = Lui_ui.stack context in
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      List.iter (fun child -> ignore (child.mount context (Some node))) children;
      node)
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
    element ?key (fun context parent ->
      let node = Lui_ui.button context in
      if not enabled then Lui_ui.disabled context node true;
      Option.iter
        (fun style ->
           Lui_ui.string_property
             context
             node
             Lui_protocol.VariantValue
             (Button_style.variant style))
        style;
      (match role with
       | Button_role.Normal -> ()
       | role ->
         Lui_ui.string_property
           context
           node
           Lui_protocol.VariantValue
           (Button_role.variant role));
      (* lui controls are leaf nodes: their label/icon travel as properties,
         not child elements. *)
      Option.iter (set_leaf_label context node) child.label_content;
      if autofocus then Lui_ui.bool_property context node Lui_protocol.Autofocus true;
      Lui_ui.on_event context node (fun event ->
        if is_press event then invoke on_press Event.Payload.Unit);
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      node)
    |> fun element_ ->
    { element_ with
      menu_item_mount =
        Some
          (fun context parent ->
             let node = Lui_ui.menu_item context in
             if not enabled then Lui_ui.disabled context node true;
             Option.iter
               (fun (label : label_content) ->
                  Lui_ui.text_property
                    context
                    node
                    (if String.length label.title = 0 then " " else label.title);
                  Option.iter
                    (fun name ->
                       Lui_ui.string_property
                         context
                         node
                         Lui_protocol.InlineIconName
                         (journal_icon_name name))
                    label.icon)
               child.label_content;
             (match role with
              | Button_role.Normal -> ()
              | role ->
                Lui_ui.string_property
                  context
                  node
                  Lui_protocol.VariantValue
                  (Button_role.variant role));
             Lui_ui.bool_property context node Lui_protocol.PressEnabled true;
             Lui_ui.on_event context node (fun event ->
               if is_press event then invoke on_press Event.Payload.Unit);
             (match parent with
              | Some parent -> Lui_ui.append context parent node
              | None -> ());
             node)
    }
  ;;

  let toggle ?key ?style:_ ?(enabled = true) ~value ~on_changed ~label () =
    element ?key (fun context parent ->
      let node = Lui_ui.toggle context in
      if not enabled then Lui_ui.disabled context node true;
      Lui_ui.bool_property context node Lui_protocol.Checked value;
      Option.iter (set_leaf_label context node) label.label_content;
      Lui_ui.on_event context node (fun event ->
        match event with
        | Lui_protocol.ToggleChanged (_, selected) ->
          invoke on_changed (Event.Payload.Bool selected)
        | _ -> ());
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      node)
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
      let node = Lui_ui.textarea context in
      Lui_ui.text_property context node (Text_editing.Value.text value);
      if not (enabled && not read_only) then Lui_ui.disabled context node true;
      if autofocus then Lui_ui.bool_property context node Lui_protocol.Autofocus true;
      Lui_ui.bool_property context node Lui_protocol.SubmitOnEnter submit_on_return;
      let local_revision = ref accepted_local_revision in
      Lui_ui.on_event context node (fun event ->
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
        | Lui_protocol.Submit _ -> invoke on_submit Event.Payload.Unit
        | _ -> ());
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      node)
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
      let node = Lui_ui.secure_field context in
      Lui_ui.text_property context node (Text_editing.Value.text value);
      Lui_ui.placeholder context node prompt;
      if not enabled then Lui_ui.disabled context node true;
      if autofocus then Lui_ui.bool_property context node Lui_protocol.Autofocus true;
      let local_revision = ref accepted_local_revision in
      Lui_ui.on_event context node (fun event ->
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
        | Lui_protocol.Submit _ -> invoke on_submit Event.Payload.Unit
        | _ -> ());
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      node)
  ;;

  let labeled_content ?key ~label ~value () =
    element ?key (fun context parent ->
      let node = Lui_ui.row context in
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      ignore (label.mount context (Some node));
      let spacer = Lui_ui.spacer context in
      Lui_ui.append context node spacer;
      ignore (value.mount context (Some node));
      node)
  ;;

  let content_unavailable ?key ~label ?description ?actions () =
    element ?key (fun context parent ->
      let node = Lui_ui.column context in
      (* Grow so the column fills the page: without it the column shrinks to
         its content and the centered children end up leading-aligned. *)
      Lui_ui.grow context node 1.0;
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      let spacer () =
        let spacer = Lui_ui.spacer context in
        Lui_ui.append context node spacer
      in
      spacer ();
      (* Center content via per-child mechanics. A cross=center column keeps
         its natural width and lands leading under the stretch parent's
         topLeading frame, so horizontal centering instead goes through a
         main=center row: the row expands to the offered width and packs its
         child between leading/trailing spacers. Text needs no wrapper — a
         set text-alignment already stretches it to full width. *)
      let center_horizontally t =
        element (fun context parent ->
          let row = Lui_ui.row context in
          Lui_ui.gap context row 0;
          Lui_ui.cross context row "center";
          Lui_ui.main context row "center";
          (match parent with
           | Some parent -> Lui_ui.append context parent row
           | None -> ());
          ignore (t.mount context (Some row));
          row)
      in
      (* The label is already a full-width row: center its own content rather
         than nesting it (a wrapper would split the free space with the
         label's own trailing spacer and leave the text off-center). *)
      ignore
        ((modify (fun context node -> Lui_ui.main context node "center") label)
           .mount
           context
           (Some node));
      Option.iter
        (fun description ->
           ignore
             ((modify
                 (fun context node ->
                    Lui_ui.string_property
                      context
                      node
                      Lui_protocol.TextAlignment
                      "center")
                 description)
                .mount
                context
                (Some node)))
        description;
      Option.iter
        (fun actions ->
           ignore ((center_horizontally actions).mount context (Some node)))
        actions;
      spacer ();
      node)
  ;;

  let overlay ?key:_ ?alignment:_ ~overlay t =
    element ?key:t.key (fun context parent ->
      let node = Lui_ui.stack context in
      (match parent with
       | Some parent -> Lui_ui.append context parent node
       | None -> ());
      ignore (t.mount context (Some node));
      ignore (overlay.mount context (Some node));
      node)
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
        let card = Lui_ui.column context in
        Lui_ui.gap context card 12;
        (match header_text, parent with
         | Some title, Some parent ->
           let heading = Lui_ui.heading context 4 title in
           Lui_ui.append context parent heading
         | _ -> ());
        (match parent with
         | Some parent -> Lui_ui.append context parent card
         | None -> ());
        List.iter
          (fun (entry : Keyed.t) -> ignore (entry.view.mount context (Some card)))
          entries;
        Option.iter (fun footer -> ignore (footer.mount context parent)) footer;
        card)
    ;;
  end

  module Form = struct
    let vertical ?key entries =
      element ?key (fun context parent ->
        let node = Lui_ui.list context in
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
        List.iter
          (fun (entry : Keyed.t) -> ignore (entry.view.mount context (Some node)))
          entries;
        node)
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
            (match parent with
             | Some parent ->
               List.fold_left
                 (fun _ child -> child.mount context (Some parent))
                 0
                 children
             | None -> 0))
      ; spacing = None
      ; is_group = true
      }
    ;;

    let spacer ~key ?placement spacing =
      { item_key = key
      ; placement
      ; content =
          element (fun context parent ->
            let node = Lui_ui.spacer context in
            (match parent with
             | Some parent -> Lui_ui.append context parent node
             | None -> ());
            node)
      ; spacing = Some spacing
      ; is_group = false
      }
    ;;

    (* System-chrome emulation: on iOS the previous renderer put toolbar items
       into real navigation/bottom bars — leading back affordance, centered
       principal title, and trailing icon-only actions grouped in a capsule.
       lui has no chrome node, so the shim reproduces that layout inline. *)
    let mount_icon_only parent context (item : item) =
      let previous = !icon_only and previous_nodes = !icon_only_collapsed_nodes in
      icon_only := true;
      icon_only_collapsed_nodes := [];
      Fun.protect
        ~finally:(fun () ->
          icon_only := previous;
          icon_only_collapsed_nodes := previous_nodes)
        (fun () ->
          let mounted = item.content.mount context (Some parent) in
          if mounted <> 0
          then (
            Lui_ui.key context mounted item.item_key;
            (* Uniform 40pt control cell so capsule widths are predictable —
               applied to each leaf control that collapsed to its icon. *)
            List.iter
              (fun node ->
                 if node_is_standard context node
                 then Lui_ui.width context node 40)
              !icon_only_collapsed_nodes);
          mounted)
    ;;

    let capsule ?(toolbar_label = "") context parent mount_children =
      (* A row child of an HStack keeps its intrinsic width unless it grows,
         so the pill hugs its controls without a pinned width. When the
         capsule holds only controls, children mount inside a [toolbar]
         node — the schema semantic for a control bar — wrapped by a box
         carrying the pill chrome: a toolbar accepts only
         label/gap/orientation/style-class, and a row would auto-append a
         trailing spacer and stretch to full width. *)
      let node =
        if toolbar_label = "" then Lui_ui.row context else Lui_ui.box context
      in
      Lui_ui.gap context node 16;
      (* Hug content height; the default stretch cross would soak the
         parent column's split share (see Navigation_stack back row). *)
      Lui_ui.cross context node "center";
      Lui_ui.padding_horizontal context node 14;
      Lui_ui.padding_vertical context node 9;
      Lui_ui.background context node "secondary";
      Lui_ui.corner_radius context node 20;
      Lui_ui.append context parent node;
      (match toolbar_label with
       | "" -> mount_children node
       | label ->
         let toolbar = Lui_ui.toolbar context in
         Lui_ui.accessibility_label context toolbar label;
         Lui_ui.gap context toolbar 16;
         Lui_ui.append context node toolbar;
         mount_children toolbar);
      node
    ;;

    let circle_button context parent ~icon ~on_press =
      let node = Lui_ui.button context in
      Lui_ui.text_property context node "";
      (* Icon-only button: the schema rejects empty text + icon without an
         accessibility label. *)
      Lui_ui.accessibility_label context node "Back";
      Lui_ui.string_property
        context
        node
        Lui_protocol.InlineIconName
        (journal_icon_name icon);
      Lui_ui.string_property context node Lui_protocol.VariantValue "ghost";
      Lui_ui.foreground context node "secondary";
      Lui_ui.background context node "secondary";
      Lui_ui.corner_radius context node 20;
      Lui_ui.width context node 40;
      Lui_ui.height context node 40;
      Lui_ui.on_event context node (fun event -> if is_press event then on_press ());
      Lui_ui.append context parent node;
      node
    ;;

    let flexible_space context parent =
      let node = Lui_ui.spacer context in
      Lui_ui.grow context node 1.0;
      Lui_ui.append context parent node;
      node
    ;;

    let mount_items items =
      element (fun context parent ->
        let node = Lui_ui.row context in
        Lui_ui.gap context node 8;
        Lui_ui.cross context node "center";
        Lui_ui.padding_horizontal context node 10;
        Lui_ui.padding_vertical context node 4;
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
        let leading =
          List.filter
            (fun (item : item) ->
               match item.placement with
               | Some (Navigation | Cancellation_action) -> true
               | _ -> false)
            items
        and principal =
          List.filter
            (fun (item : item) -> item.placement = Some Principal)
            items
        and secondary =
          List.filter
            (fun (item : item) -> item.placement = Some Secondary_action)
            items
        in
        let trailing =
          List.filter
            (fun (item : item) ->
               match item.placement with
               | Some
                   ( Navigation | Cancellation_action | Principal
                   | Secondary_action | Bottom_bar )
               | None -> false
               | Some _ -> true)
            items
        in
        (match !nav_bar with
         | Some { nav_can_pop = true; nav_on_change; nav_remaining; _ } ->
           ignore
             (circle_button
                context
                node
                ~icon:"chevron.left"
                ~on_press:(fun () ->
                  invoke nav_on_change
                    (Event.Payload.Navigation_path_changed nav_remaining)))
         | _ -> ());
        List.iter
          (fun item -> ignore (mount_icon_only node context item))
          leading;
        ignore (flexible_space context node);
        (match principal with
         | [] ->
           (match !nav_bar with
            | Some { nav_title = title; _ } when title <> "" ->
              let title_node = Lui_ui.text context title in
              Lui_ui.style_class context title_node "semibold";
              Lui_ui.append context node title_node
            | _ -> ())
         | _ ->
           List.iter
             (fun item ->
                let mounted = item.content.mount context (Some node) in
                if mounted <> 0
                then (
                  Lui_ui.key context mounted item.item_key;
                  if node_is_standard context mounted
                  then Lui_ui.style_class context mounted "semibold"))
             principal);
        ignore (flexible_space context node);
        if trailing <> [] || secondary <> []
        then
          ignore
            (capsule context node (fun row ->
               List.iter
                 (fun item -> ignore (mount_icon_only row context item))
                 trailing;
               if secondary <> []
               then (
                 (* Secondary actions collapse into the "more" overflow the
                    system bar showed. *)
                 let trigger = Lui_ui.menu_item context in
                 Lui_ui.text_property context trigger " ";
                 (* accessibility-label is not in the menu-item schema; the
                     whitespace text is what the validator accepts. *)
                 Lui_ui.string_property
                   context
                   trigger
                   Lui_protocol.InlineIconName
                   (journal_icon_name "ellipsis");
                 (* The menu label grows to fill available space; cap it so
                    the trigger stays icon-sized inside the capsule. *)
                 Lui_ui.width context trigger 40;
                 Lui_ui.string_property
                   context
                   trigger
                   Lui_protocol.SizeValue
                   "sm";
                 Lui_ui.append context row trigger;
                 let menu = Lui_ui.dropdown_menu context in
                 Lui_ui.append context trigger menu;
                 List.iter
                   (fun (item : item) ->
                      match item.content.menu_item_mount with
                      | Some mount -> ignore (mount context (Some menu))
                      | None -> ignore (mount_icon_only row context item))
                   secondary)));
        node)
    ;;

    let mount_bottom_bar items =
      element (fun context parent ->
        let node = Lui_ui.row context in
        Lui_ui.gap context node 10;
        Lui_ui.cross context node "center";
        Lui_ui.padding_horizontal context node 12;
        Lui_ui.padding_vertical context node 8;
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
        List.iter
          (fun (item : item) ->
             match item.spacing with
             | Some Flexible -> ignore (flexible_space context node)
             | Some Fixed ->
               let fixed = Lui_ui.spacer context in
               Lui_ui.width context fixed 16;
               Lui_ui.append context node fixed
             | _ ->
               ignore
                 (capsule ~toolbar_label:item.item_key context node (fun row ->
                    ignore (mount_icon_only row context item))))
          items;
        node)
    ;;

    let create ?key ~items t =
      element ?key (fun context parent ->
        let node = Lui_ui.column context in
        Lui_ui.grow context node 1.0;
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
        let top, bottom =
          List.partition
            (fun (item : item) -> item.placement <> Some Bottom_bar)
            items
        in
        if top <> [] || Option.fold ~none:false ~some:(fun bar -> bar.nav_can_pop) !nav_bar
        then ignore ((mount_items top).mount context (Some node));
        let body = t.mount context (Some node) in
        if node_is_standard context body then Lui_ui.grow context body 1.0;
        if bottom <> []
        then ignore ((mount_bottom_bar bottom).mount context (Some node));
        node)
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
      element ?key (fun context parent ->
        let node = Lui_ui.scroll context in
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
        ignore (t.mount context (Some node));
        node)
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
        let menu = Lui_ui.context_menu context in
        Lui_ui.append context node menu;
        List.iter
          (fun (action : action) ->
             let item = Lui_ui.menu_item context in
             Lui_ui.text_property context item action.title;
             Option.iter
               (fun symbol ->
                  Lui_ui.string_property
                    context
                    item
                    Lui_protocol.InlineIconName
                    (journal_icon_name symbol))
               action.symbol;
             (match action.role with
              | Normal -> ()
              | Destructive ->
                Lui_ui.string_property
                  context
                  item
                  Lui_protocol.VariantValue
                  "destructive");
             if not action.enabled then Lui_ui.disabled context item true;
             Lui_ui.bool_property context item Lui_protocol.PressEnabled true;
             Lui_ui.on_event context item (fun event ->
               if is_press event then invoke action.on_press Event.Payload.Unit);
             Lui_ui.append context menu item)
          actions;
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
          let dialog = Lui_ui.dialog context in
          Lui_ui.text_property context dialog request.title;
          Option.iter
            (fun message ->
               Lui_ui.string_property context dialog Lui_protocol.DescriptionValue message)
            request.message;
          Lui_ui.append context node dialog;
          List.iter
            (fun (action : action) ->
               let item = Lui_ui.button context in
               Lui_ui.text_property context item action.title;
               if not action.enabled then Lui_ui.disabled context item true;
               (match action.role with
                | Button_role.Normal -> ()
                | role ->
                  Lui_ui.string_property
                    context
                    item
                    Lui_protocol.VariantValue
                    (Button_role.variant role));
               Lui_ui.on_event context item (fun event ->
                 match event with
                 | Lui_protocol.Press _ ->
                   invoke
                     on_response
                     (Event.Payload.Confirmation_response
                        { token = request.token; result = Action action.key })
                 | _ -> ());
               Lui_ui.append context dialog item)
            request.actions;
          Lui_ui.on_event context dialog (fun event ->
            match event with
            | Lui_protocol.Dismiss _ ->
              invoke
                on_response
                (Event.Payload.Confirmation_response
                   { token = request.token; result = Dismissed })
            | _ -> ());
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
      element ?key (fun context parent ->
        let node = Lui_ui.list_item context in
        if not enabled then Lui_ui.disabled context node true;
        Lui_ui.bool_property context node Lui_protocol.PressEnabled enabled;
        (* NavigationLink draws a trailing disclosure accessory; LUI list items
           have none, so carry the chevron as an inline trailing icon. *)
        Lui_ui.string_property
          context
          node
          Lui_protocol.InlineIconName
          (journal_icon_name "chevron.right");
        Lui_ui.string_property context node Lui_protocol.IconPlacementValue "trailing";
        (* A list-item must carry text or children; mount the label as the
           item content so composite labels render too. *)
        ignore (label.mount context (Some node));
        Lui_ui.on_event context node (fun event ->
          if is_press event then invoke on_activate Event.Payload.Unit);
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
        node)
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
        let node = Lui_ui.column context in
        (* Fill the hosting column so the emulated bar rows pin to the top
           instead of the whole page centering vertically. *)
        Lui_ui.grow context node 1.0;
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
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
        nav_bar :=
          Some
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
        Fun.protect ~finally:(fun () -> nav_bar := previous) (fun () ->
          let mounted =
            match top with
            | None -> root.mount context (Some node)
            | Some destination -> destination.content.mount context (Some node)
          in
          (* Extension nodes live outside the standard prop store — set_prop
             on one raises; they expand through their own SwiftUI views. *)
          if node_is_standard context mounted then Lui_ui.grow context mounted 1.0);
        node)
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
        let node = Lui_ui.column context in
        Lui_ui.grow context node 1.0;
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
        ignore (base.mount context (Some node));
        if presented
        then (
          let sheet = Lui_ui.sheet context in
          Lui_ui.text_property
            context
            sheet
            (if String.equal title "" then "Sheet" else title);
          Lui_ui.append context node sheet;
          if interactive_dismiss
          then
            Lui_ui.on_event context sheet (fun event ->
              match event with
              | Lui_protocol.Dismiss _ ->
                invoke on_presented_changed (Event.Payload.Bool false)
              | _ -> ());
          ignore (content.mount context (Some sheet)));
        node)
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
        let node =
          match style with
          | Segmented -> Lui_ui.toggle_group context
          | Automatic | Menu | Inline -> Lui_ui.radio_group context
        in
        if not enabled then Lui_ui.disabled context node true;
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
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
             Option.iter (set_leaf_label context item) choice.label.label_content;
             Option.iter
               (Lui_ui.accessibility_identifier context item)
               choice.label.test_id;
             Lui_ui.append context node item)
          choices;
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
    let menu_item context ?key_opt ~title ~icon ~enabled ~role ~selected ?on_press () =
      let node = Lui_ui.menu_item context in
      Option.iter (Lui_ui.key context node) key_opt;
      (* menu-item requires non-empty text; a blank space keeps icon-only
         triggers visually identical without violating the schema. *)
      let title = if String.length title = 0 then " " else title in
      Lui_ui.string_property context node Lui_protocol.TextValue title;
      Option.iter
        (fun name ->
           Lui_ui.string_property
             context
             node
             Lui_protocol.InlineIconName
             (journal_icon_name name))
        icon;
      if not enabled then Lui_ui.disabled context node true;
      (match role with
       | Button_role.Normal -> ()
       | role ->
         Lui_ui.string_property
           context
           node
           Lui_protocol.VariantValue
           (Button_role.variant role));
      Option.iter (Lui_ui.bool_property context node Lui_protocol.Selected) selected;
      Option.iter
        (fun payload ->
           Lui_ui.bool_property context node Lui_protocol.PressEnabled true;
           Lui_ui.on_event context node (fun event -> if is_press event then payload ()))
        on_press;
      node
    ;;

    let create ?key ?(enabled = true) ~on_select ~title ?icon entries =
      element ?key (fun context parent ->
        let node =
          menu_item
            context
            ~title
            ~icon
            ~enabled
            ~role:Button_role.Normal
            ~selected:None
            ()
        in
        if String.length title = 0
        then (
          (* Icon-only trigger: keep the menu label from stretching to fill
             the available width inside bar capsules, and use the smaller
             menu-item icon size the system bar showed. *)
          Lui_ui.width context node 20;
          Lui_ui.string_property context node Lui_protocol.SizeValue "sm");
        (match parent with
         | Some parent -> Lui_ui.append context parent node
         | None -> ());
        let menu = Lui_ui.dropdown_menu context in
        Lui_ui.append context node menu;
        let rec mount_entry parent (entry : entry) =
          match entry with
          | Divider id ->
            let separator = Lui_ui.separator context "horizontal" in
            Lui_ui.key context separator (Int64.to_string id);
            Lui_ui.append context parent separator
          | Action { id; label; enabled; role } ->
            let item =
              menu_item
                context
                ~key_opt:(Int64.to_string id)
                ~title:label.title
                ~icon:label.icon
                ~enabled
                ~role
                ~selected:None
                ~on_press:(fun () -> invoke on_select (Event.Payload.Int64 id))
                ()
            in
            Lui_ui.append context parent item
          | Choice { id; label; selected; enabled } ->
            let item =
              menu_item
                context
                ~key_opt:(Int64.to_string id)
                ~title:label.title
                ~icon:label.icon
                ~enabled
                ~role:Button_role.Normal
                ~selected:(Some selected)
                ~on_press:(fun () -> invoke on_select (Event.Payload.Int64 id))
                ()
            in
            Lui_ui.append context parent item
          | Section { label; entries; _ } ->
            Option.iter
              (fun label ->
                 let heading =
                   menu_item
                     context
                     ~title:label.title
                     ~icon:label.icon
                     ~enabled:false
                     ~role:Button_role.Normal
                     ~selected:None
                     ()
                 in
                 Lui_ui.append context parent heading)
              label;
            List.iter (mount_entry parent) entries
          | Submenu { id; label; enabled; entries } ->
            let item =
              menu_item
                context
                ~key_opt:(Int64.to_string id)
                ~title:label.title
                ~icon:label.icon
                ~enabled
                ~role:Button_role.Normal
                ~selected:None
                ()
            in
            Lui_ui.append context parent item;
            let submenu = Lui_ui.dropdown_menu context in
            Lui_ui.append context item submenu;
            List.iter (mount_entry submenu) entries
        in
        List.iter (mount_entry menu) entries;
        node)
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
    Journal_lui_native.mount
      ?key
      ~payload
      ~children:(List.map (fun element -> element.mount) children)
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
