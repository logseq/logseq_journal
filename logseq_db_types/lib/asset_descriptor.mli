(** Graph metadata only; cache residency is not part of this value. *)
type version = private
  { checksum : string
  ; file_type : string
  }

type source =
  | Managed of version option
  | External of string

type t = private
  { uuid : Graph_types.Uuid.t
  ; source : source
  ; current_checksum : string option
  ; size : int64 option
  ; dimensions : (int * int) option
  }

val version : checksum:string -> file_type:string -> (version, string) result

val create
  :  uuid:Graph_types.Uuid.t
  -> source:source
  -> current_checksum:string option
  -> size:int64 option
  -> dimensions:(int * int) option
  -> (t, string) result

val equal_version : version -> version -> bool
val to_yojson : t -> Yojson.Safe.t

(** Decode UUIDs with [Graph_types.Uuid.of_yojson] and validate metadata through
    [version] and [create], including checksum, file type, size and dimensions. *)
val of_yojson : Yojson.Safe.t -> (t, string) result
