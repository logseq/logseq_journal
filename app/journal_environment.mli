(** Host environment snapshot, replacing [Journal_environment]. The
    native host pushes snapshots through the application platform channel;
    the model stores the latest one. *)

type edge_insets =
  { left : float
  ; top : float
  ; right : float
  ; bottom : float
  }

type brightness =
  | Light
  | Dark

type orientation =
  | Portrait
  | Landscape

type snapshot =
  { viewport_width : float
  ; viewport_height : float
  ; device_pixel_ratio : float
  ; text_scale : float
  ; brightness : brightness
  ; platform : string
  ; locale : string
  ; safe_area : edge_insets
  ; keyboard_insets : edge_insets
  ; accessible_navigation : bool
  ; bold_text : bool
  ; invert_colors : bool
  ; disable_animations : bool
  ; reduced_motion : bool
  ; high_contrast : bool
  ; orientation : orientation
  ; pointer_kinds : int
  }

val equal : snapshot -> snapshot -> bool

(** A neutral default used before the host delivers the first snapshot. *)
val fallback : snapshot

val decode_json : Yojson.Basic.t -> (snapshot, string) result
val encode_json : snapshot -> Yojson.Basic.t
