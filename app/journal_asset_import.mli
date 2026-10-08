type source =
  | Files
  | Photos
  | Camera

(** Picker arm request: [source] selects the picker, [staged] makes the host
    copy the pick into a temp file so it survives until a later import. *)
type request =
  { id : int
  ; source : source
  ; staged : bool
  ; max_selections : int option
  }

(** In-place import request (detail page): file picker, no staging copy. *)
val file_request : id:int -> request

(** Staged request for deferred import (composer): the host copies the pick
    into a temp file and reports it for the pending-attachment strip. *)
val staged_request : ?max_selections:int -> id:int -> source:source -> unit -> request

(** A picked asset kept for a later attach-on-save import. *)
type staged

val staged_token : staged -> string
val staged_path : staged -> string
val staged_title : staged -> string
val staged_type : staged -> string
val staged_source_identity : staged -> string option

(** Build the worker import for a staged pick targeting [target]. *)
val to_import
  :  staged
  -> target:Logseq_db_types.Graph_types.Uuid.t
  -> Logseq_db_types.Asset_import.t

val decode
  :  target:Logseq_db_types.Graph_types.Uuid.t
  -> string
  -> (Logseq_db_types.Asset_import.t, string) result

type event =
  | Picked of staged * int option (** the pick and the request id that armed it *)
  | Picked_batch of staged list * int option * string option
  | Removed of string
  | Dismissed
  | Picker_dismissed of int option
  | Unavailable of string

val decode_event : string -> (event, string) result

(** Best-effort removal of a staged temp copy created for this pick; a no-op
    for paths outside the staged temp-file naming contract. *)
val discard_staged_file : staged -> unit

val is_dismissal : string -> bool

val view
  :  key:Journal_view.Key.t
  -> enabled:bool
  -> completion:(string * string option) option
  -> request:request
  -> pending:staged list
  -> on_select:(string -> unit)
  -> Journal_view.View.Body.t
  -> Journal_view.View.t
