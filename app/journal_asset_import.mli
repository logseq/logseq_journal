type source =
  | Files
  | Photos
  | Camera

val source_to_string : source -> string
val source_of_string : string -> source option

(** Picker arm request: [source] selects the picker, [staged] makes the host
    copy the pick into a temp file so it survives until a later import. *)
type request =
  { id : int
  ; source : source
  ; staged : bool
  }

(** In-place import request (detail page): file picker, no staging copy. *)
val file_request : id:int -> request

(** Staged request for deferred import (composer): the host copies the pick
    into a temp file and reports it for the pending-attachment strip. *)
val staged_request : id:int -> source:source -> request

(** A picked asset kept for a later attach-on-save import. *)
type staged

val staged_token : staged -> string
val staged_path : staged -> string
val staged_title : staged -> string
val staged_type : staged -> string

(** Completion prop value for a staged request: once the first staged pick is
    held journal-side the picker's retained copy can be released. *)
val staged_completion : request -> staged list -> (string * string option) option

(** Build the worker import for a staged pick targeting [target]. *)
val to_import
  :  staged
  -> target:Logseq_db_types.Graph_types.Uuid.t
  -> Logseq_db_types.Asset_import.t

val decode
  :  target:Logseq_db_types.Graph_types.Uuid.t
  -> replace_reference:Logseq_db_types.Graph_types.Uuid.t option
  -> string
  -> (Logseq_db_types.Asset_import.t, string) result

type event =
  | Picked of staged * int option (** the pick and the request id that armed it *)
  | Removed of string
  | Dismissed
  | Unavailable of string

val decode_event : string -> (event, string) result

(** Best-effort removal of a staged temp copy created for this pick; a no-op
    for paths outside the staged temp-file naming contract. *)
val discard_staged_file : staged -> unit

val is_dismissal : string -> bool

(** Import-error alert dismissal, reported on the same channel as picks. *)
val is_error_dismissal : string -> bool

val view
  :  key:Journal_view.Key.t
  -> enabled:bool
  -> completion:(string * string option) option
  -> replacement:string option
  -> request:request
  -> pending:staged list
  -> on_select:(string -> unit)
  -> Journal_view.View.Body.t
  -> Journal_view.View.t
