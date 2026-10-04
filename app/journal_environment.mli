(** Product preferences pushed by the native host through the application
    platform channel. Native layout and accessibility retain their host owners;
    this wire does not report geometry, keyboard occlusion, or device metrics. *)

type brightness =
  | Light
  | Dark

type snapshot =
  { brightness : brightness
  ; platform : string
  ; accessible_navigation : bool
  ; high_contrast : bool
  }

val equal : snapshot -> snapshot -> bool

(** A neutral default used before the host delivers the first snapshot. *)
val fallback : snapshot

val decode_json : Yojson.Basic.t -> (snapshot, string) result
val encode_json : snapshot -> Yojson.Basic.t
