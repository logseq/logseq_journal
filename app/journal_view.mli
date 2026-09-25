(** Journal view shim over lui elements, mirroring the BonsaiSwiftUI view API
    used across the app layer. *)

type t

val mount : t -> Lui_elements.t

module Key : sig
  type t

  val string : string -> t
  val int : int -> t
  val int64 : int64 -> t
end

module Test_id : sig
  type t

  val string : string -> t
  val to_string : t -> string
end

module Event : sig
  module Payload : sig
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

  module Handler : sig
    type t

    val create : ?name:string -> (Payload.t -> unit) -> t
    val name : t -> string option

    module Private : sig
      val same : t -> t -> bool
      val invoke : t -> Payload.t -> unit
    end
  end

  type handler = Handler.t
end

module Style : sig
  module Color : sig
    type t

    val rgb : red:int -> green:int -> blue:int -> t
    val argb : alpha:int -> red:int -> green:int -> blue:int -> t
  end

  module Text_style : sig
    type foreground =
      | Primary
      | Secondary

    type font_weight =
      | Regular
      | Semi_bold

    type t

    val create : ?foreground:foreground -> ?font_weight:font_weight -> unit -> t
  end
end

module Layout : sig
  module Edge_insets : sig
    type t

    val all : float -> t
  end

  module Alignment : sig
    type t
  end

  module Horizontal_alignment : sig
    type t =
      | Leading
      | Center
      | Trailing
  end

  module Vertical_alignment : sig
    type t =
      | Top
      | Center
      | Bottom
  end

  module Frame_limit : sig
    type t =
      | Fixed of float
      | Fill
  end
end

module Semantics : sig
  module Role : sig
    type t =
      | Generic
      | Button
      | Link
      | Image
      | Header
      | Toggle
      | Static_text

    val equal : t -> t -> bool
    val to_string : t -> string
  end

  module Children : sig
    type t =
      | Combine
      | Contain
      | Ignore
  end

  module Action : sig
    type t

    val create : id:int64 -> label:string -> t
    val id : t -> int64
    val label : t -> string
    val equal : t -> t -> bool
  end

  type t

  val create
    :  ?label:string
    -> ?hint:string
    -> ?value:string
    -> ?role:Role.t
    -> ?selected:bool
    -> ?children:Children.t
    -> ?hidden:bool
    -> ?live_region:bool
    -> ?heading_level:int
    -> ?sort_priority:float
    -> ?identifier:string
    -> ?actions:Action.t list
    -> unit
    -> t

  module Private : sig
    val view : t -> t
  end
end

module Theme : sig
  type mode =
    | System
    | Light
    | Dark

  type t

  val create :
       mode:mode
    -> ?tokens:(string * Lui_ui.theme_token_value) list
    -> unit
    -> t
end

module Text_editing : sig
  module Range : sig
    type t

    val create : text:string -> start_utf16:int -> end_utf16:int -> t
    val start_utf16 : t -> int
    val end_utf16 : t -> int
    val equal : t -> t -> bool
  end

  module Value : sig
    type t

    val create : text:string -> selection:Range.t -> ?composing:Range.t -> unit -> t
    val text : t -> string
    val selection : t -> Range.t
    val composing : t -> Range.t option
    val equal : t -> t -> bool
  end

  module Utf16 : sig
    val length : string -> int
  end

  type update_mode =
    | Ack
    | Force_replace
    | Initiate
    | Resume

  module Keyboard : sig
    type t =
      | Default
      | Text
  end

  module Submit_label : sig
    type t =
      | Default
      | Go
      | Done
      | Return
      | Send
  end

  module Field_appearance : sig
    type t =
      | Rounded
      | Plain
  end
end

module View : sig
  type nonrec t = t

  module For_testing : sig
    val key : t -> string option
    val test_id : t -> string option
  end

  module Button_role : sig
    type t =
      | Normal
      | Destructive
      | Cancel
  end

  module Button_style : sig
    type t =
      | Automatic
      | Plain
      | Bordered
      | Prominent
      | Button
  end

  module Progress_style : sig
    type t =
      | Linear
      | Circular
  end

  val with_test_id : Test_id.t -> t -> t
  val empty : ?key:Key.t -> unit -> t

  val text
    :  ?key:Key.t
    -> ?style:Style.Text_style.t
    -> ?text_align:'a
    -> ?line_limit:int
    -> ?truncation:'b
    -> string
    -> t

  val symbol
    :  ?key:Key.t
    -> ?size:float
    -> ?color:Style.Color.t
    -> ?rendering:'a
    -> name:string
    -> unit
    -> t

  val label : ?key:Key.t -> title:t -> icon:t -> unit -> t
  val divider : ?key:Key.t -> unit -> t
  val progress : ?key:Key.t -> ?value:float -> ?style:Progress_style.t -> unit -> t
  val spacer : ?key:Key.t -> ?min_length:float -> unit -> t
  val loading : ?key:Key.t -> ?centered:bool -> message:string -> unit -> t

  val feedback_banner
    :  ?key:Key.t
    -> ?kind:[ `error | `info ]
    -> message:string
    -> unit
    -> t

  val row
    :  ?key:Key.t
    -> ?spacing:float
    -> ?alignment:Layout.Vertical_alignment.t
    -> t list
    -> t

  val column
    :  ?key:Key.t
    -> ?spacing:float
    -> ?alignment:Layout.Horizontal_alignment.t
    -> t list
    -> t

  val stack : ?key:Key.t -> ?alignment:Layout.Alignment.t -> t list -> t

  val frame
    :  ?key:Key.t
    -> ?width:float
    -> ?height:float
    -> ?min_width:float
    -> ?ideal_width:float
    -> ?max_width:Layout.Frame_limit.t
    -> ?min_height:float
    -> ?ideal_height:float
    -> ?max_height:Layout.Frame_limit.t
    -> ?alignment:Layout.Alignment.t
    -> t
    -> t

  val padding : ?key:Key.t -> insets:Layout.Edge_insets.t -> t -> t
  val semantics : ?key:Key.t -> properties:Semantics.t -> t -> t
  val help : ?key:Key.t -> message:string -> t -> t
  val text_selection : ?key:Key.t -> enabled:bool -> t -> t
  val opacity : ?key:Key.t -> float -> t -> t
  val ignores_safe_area : ?regions:'a -> ?edges:'b list -> t -> t
  val safe_area_padding : ?key:Key.t -> insets:Layout.Edge_insets.t -> t -> t
  val theme : ?key:Key.t -> data:Theme.t -> t -> t
  val background : ?key:Key.t -> ?corner_radius:float -> color:Style.Color.t -> t -> t
  val clip : ?key:Key.t -> ?corner_radius:float -> ?antialiased:bool -> t -> t
  val layout_priority : ?key:Key.t -> float -> t -> t
  val offset : ?key:Key.t -> ?x:float -> ?y:float -> t -> t
  val animated_opacity : ?key:Key.t -> ?duration:float -> float -> t -> t

  val button
    :  ?key:Key.t
    -> ?enabled:bool
    -> ?role:Button_role.t
    -> ?style:Button_style.t
    -> ?autofocus:bool
    -> on_press:Event.handler
    -> child:t
    -> unit
    -> t

  val toggle
    :  ?key:Key.t
    -> ?style:Button_style.t
    -> ?enabled:bool
    -> value:bool
    -> on_changed:Event.handler
    -> label:t
    -> unit
    -> t

  val text_editor
    :  ?key:Key.t
    -> ?autofocus:bool
    -> ?enabled:bool
    -> ?read_only:bool
    -> ?submit_on_return:bool
    -> ?max_utf8_bytes:int
    -> session_id:Journal_ids.Text_input.Session_id.t
    -> document_revision:Journal_ids.Text_input.Document_revision.t
    -> accepted_local_revision:Journal_ids.Text_input.Local_revision.t
    -> update_mode:Text_editing.update_mode
    -> value:Text_editing.Value.t
    -> on_edit:Event.handler
    -> on_submit:Event.handler
    -> on_focus_changed:Event.handler
    -> ?on_limit_reached:Event.handler
    -> unit
    -> t

  val secure_field
    :  ?key:Key.t
    -> label:string
    -> ?prompt:string
    -> ?keyboard:Text_editing.Keyboard.t
    -> ?submit_label:Text_editing.Submit_label.t
    -> ?appearance:Text_editing.Field_appearance.t
    -> ?autofocus:bool
    -> ?enabled:bool
    -> ?read_only:bool
    -> ?submit_on_return:bool
    -> ?max_utf8_bytes:int
    -> session_id:Journal_ids.Text_input.Session_id.t
    -> document_revision:Journal_ids.Text_input.Document_revision.t
    -> accepted_local_revision:Journal_ids.Text_input.Local_revision.t
    -> update_mode:Text_editing.update_mode
    -> value:Text_editing.Value.t
    -> on_edit:Event.handler
    -> on_submit:Event.handler
    -> on_focus_changed:Event.handler
    -> ?on_limit_reached:Event.handler
    -> unit
    -> t

  val labeled_content : ?key:Key.t -> label:t -> value:t -> unit -> t

  val content_unavailable
    :  ?key:Key.t
    -> label:t
    -> ?description:t
    -> ?actions:t
    -> unit
    -> t

  val overlay : ?key:Key.t -> ?alignment:Layout.Alignment.t -> overlay:t -> t -> t

  module Keyed : sig
    type widget = t

    type nonrec t =
      { key : string
      ; view : widget
      }

    val create : key:string -> widget -> t
  end

  module Section : sig
    val create : ?key:Key.t -> ?header_text:string -> ?footer:t -> Keyed.t list -> t
  end

  module Form : sig
    val vertical : ?key:Key.t -> Keyed.t list -> t
  end

  module Toolbar : sig
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

    type child
    type item

    val child : key:Key.t -> t -> child
    val item : key:Key.t -> ?placement:placement -> t -> item
    val group : key:Key.t -> ?placement:placement -> child list -> item
    val spacer : key:Key.t -> ?placement:placement -> spacing -> item
    val create : ?key:Key.t -> items:item list -> t -> t
  end

  module Body : sig
    type nonrec t = t
    type widget = t

    val with_size : width:float -> height:float -> t -> widget
    val static : widget -> t
    val with_test_id : Test_id.t -> t -> t
    val padding : insets:Layout.Edge_insets.t -> t -> t
    val background : ?corner_radius:float -> color:Style.Color.t -> t -> t
    val semantics : properties:Semantics.t -> t -> t
    val ignores_safe_area : ?regions:'a -> ?edges:'b list -> t -> t
    val safe_area_padding : insets:Layout.Edge_insets.t -> t -> t
    val theme : data:Theme.t -> t -> t
    val toolbar : ?key:Key.t -> items:Toolbar.item list -> t -> t

    module Vertical : sig
      type child

      val fixed : widget -> child
      val fill : ?weight:float -> widget -> child
      val create : ?key:Key.t -> child list -> t
    end

    module Horizontal : sig
      type child

      val fixed : widget -> child
      val fill : ?weight:float -> widget -> child
      val create : ?key:Key.t -> child list -> t
    end

    val overlay : ?key:Key.t -> ?alignment:Layout.Alignment.t -> overlay:widget -> t -> t

    module Private : sig
      val to_widget : t -> widget
    end
  end

  module Viewport : sig
    module Vertical : sig
      type nonrec t = t

      val with_test_id : Test_id.t -> t -> t
      val padding : insets:Layout.Edge_insets.t -> t -> t
      val background : ?corner_radius:float -> color:Style.Color.t -> t -> t
      val semantics : properties:Semantics.t -> t -> t
      val ignores_safe_area : ?regions:'a -> ?edges:'b list -> t -> t
      val safe_area_padding : insets:Layout.Edge_insets.t -> t -> t
      val theme : data:Theme.t -> t -> t
      val overlay : ?key:Key.t -> ?alignment:Layout.Alignment.t -> overlay:t -> t -> t
      val with_height : height:float -> t -> t
    end

    module Horizontal : sig
      type nonrec t = t

      val with_test_id : Test_id.t -> t -> t
      val with_width : width:float -> t -> t
    end
  end

  module Scroll : sig
    type anchor =
      | Start
      | End

    val vertical
      :  ?key:Key.t
      -> ?on_scroll:Event.handler
      -> ?shows_indicators:bool
      -> ?fill_viewport:bool
      -> ?initial_anchor:anchor
      -> t
      -> t
  end

  module Swipe_actions : sig
    type side =
      | Start
      | End

    type action
    type nonrec t

    val action
      :  key:Key.t
      -> ?enabled:bool
      -> ?role:Button_role.t
      -> ?symbol:string
      -> side:side
      -> title:string
      -> background:Style.Color.t
      -> on_press:Event.handler
      -> unit
      -> action

    val create
      :  ?enabled:bool
      -> ?allows_full_swipe:bool
      -> actions:action list
      -> unit
      -> t
  end

  module Context_menu : sig
    type nonrec view = t

    type role =
      | Normal
      | Destructive

    type action
    type nonrec t

    val action
      :  key:Key.t
      -> ?enabled:bool
      -> ?role:role
      -> ?symbol:string
      -> title:string
      -> on_press:Event.handler
      -> unit
      -> action

    val create : ?enabled:bool -> actions:action list -> unit -> t
    val attach : ?key:Key.t -> t -> view -> view
  end

  module Confirmation : sig
    type action
    type request

    val action
      :  key:string
      -> title:string
      -> ?enabled:bool
      -> ?role:Button_role.t
      -> unit
      -> action

    val request : token:int64 -> title:string -> ?message:string -> action list -> request

    val alert
      :  ?key:Key.t
      -> request:request option
      -> on_response:Event.handler
      -> t
      -> t

    val dialog
      :  ?key:Key.t
      -> request:request option
      -> on_response:Event.handler
      -> t
      -> t
  end

  module Native_list : sig
    type anchor =
      | Top
      | Center
      | Bottom

    type target
    type scroll_request
    type outcome = Event.Payload.native_list_outcome
    type completion = Event.Payload.native_list_completion

    val target : section:Key.t -> row_path:Key.t list -> target

    val scroll_request
      :  token:int64
      -> target:target
      -> ?anchor:anchor
      -> ?animated:bool
      -> unit
      -> scroll_request

    val completion_of_payload : Event.Payload.t -> completion option

    type style =
      | Plain
      | Inset
      | Inset_grouped

    type separator =
      | Automatic
      | Hidden
      | Visible

    type row
    type section

    val row
      :  key:Key.t
      -> ?test_id:Test_id.t
      -> ?separator:separator
      -> ?swipe_actions:Swipe_actions.t
      -> ?context_menu:Context_menu.t
      -> t
      -> row

    val disclosure_row
      :  key:Key.t
      -> ?test_id:Test_id.t
      -> ?separator:separator
      -> ?swipe_actions:Swipe_actions.t
      -> ?context_menu:Context_menu.t
      -> expanded:bool
      -> on_expanded_changed:Event.handler
      -> label:t
      -> row list
      -> row

    val section
      :  key:Key.t
      -> ?header:t
      -> ?footer:t
      -> ?separator:separator
      -> row list
      -> section

    val vertical
      :  ?key:Key.t
      -> style:style
      -> ?scroll_request:scroll_request
      -> ?on_scroll_completed:Event.handler
      -> ?on_visible_range:Event.handler
      -> ?on_row_event:Event.handler
      -> section list
      -> t
  end

  module Navigation_link : sig
    val create
      :  ?key:Key.t
      -> activation_id:string
      -> ?enabled:bool
      -> on_activate:Event.handler
      -> label:t
      -> unit
      -> t
  end

  module Navigation_stack : sig
    type destination

    val destination : page_key:string -> title:string -> can_pop:bool -> t -> destination

    val create
      :  ?key:Key.t
      -> title:string
      -> on_path_change:Event.handler
      -> path:destination list
      -> t
      -> t
  end

  module Sheet : sig
    type sizing =
      | Automatic
      | Form
      | Fitted

    type detent =
      | Medium
      | Large

    val create
      :  ?key:Key.t
      -> presented:bool
      -> on_presented_changed:Event.handler
      -> ?interactive_dismiss:bool
      -> ?sizing:sizing
      -> ?detents:detent list
      -> ?title:string
      -> content:t
      -> t
      -> t
  end

  module Picker : sig
    type choice

    type style =
      | Automatic
      | Menu
      | Segmented
      | Inline

    val option : id:int64 -> ?enabled:bool -> ?label:t -> unit -> choice

    val create
      :  ?key:Key.t
      -> ?label:string
      -> ?style:style
      -> ?enabled:bool
      -> selected_id:int64 option
      -> on_select:Event.handler
      -> choice list
      -> unit
      -> t
  end

  module Menu : sig
    type entry

    val action
      :  id:int64
      -> title:string
      -> ?icon:string
      -> ?enabled:bool
      -> ?role:Button_role.t
      -> unit
      -> entry

    val choice
      :  id:int64
      -> title:string
      -> ?icon:string
      -> selected:bool
      -> ?enabled:bool
      -> unit
      -> entry

    val divider : id:int64 -> entry
    val section : id:int64 -> ?title:string -> ?icon:string -> entry list -> entry

    val submenu
      :  id:int64
      -> title:string
      -> ?icon:string
      -> ?enabled:bool
      -> entry list
      -> entry

    val create
      :  ?key:Key.t
      -> ?enabled:bool
      -> on_select:Event.handler
      -> title:string
      -> ?icon:string
      -> ?label:string
      -> entry list
      -> t
  end
end

module Native_widget : sig
  module Capability : sig
    type t =
      | Stateful
      | Resource
      | Semantics
      | Semantics_canvas
      | Virtualized

    val bit : t -> int64
    val bits : t list -> int64
  end

  module Extension : sig
    type ('props, 'event) t

    val create
      :  kind_id:Journal_ids.Native_widget.Kind_id.t
      -> version:int
      -> capabilities:Capability.t list
      -> encode_props:('props -> bytes)
      -> decode_event:
           (event_id:Journal_ids.Native_widget.Event_id.t
            -> bytes
            -> ('event, string) result)
      -> unit
      -> ('props, 'event) t
  end

  val event_handler
    :  ?name:string
    -> ('props, 'event) Extension.t
    -> ('event -> unit)
    -> Event.handler

  val widget
    :  ('props, 'event) Extension.t
    -> ?key:Key.t
    -> props:'props
    -> on_event:('event -> unit)
    -> ?children:View.t list
    -> unit
    -> View.t

  val widget_with_handler
    :  ('props, 'event) Extension.t
    -> ?key:Key.t
    -> props:'props
    -> on_event:Event.handler
    -> ?children:View.t list
    -> unit
    -> View.t
end
