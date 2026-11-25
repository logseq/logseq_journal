(** {1 TLDR}
    Describes graph asset metadata. A version identifies bytes by checksum and
    file type; a scheduled download can also carry a size estimate. *)
type version = private
  { checksum : string
  ; file_type : string
  ; download_size_hint : int64 option
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

(** {1 Minimal usage example}
    Construct a managed version with [version ~checksum ~file_type], then pass
    [Managed (Some version)] and the optional graph size to [create]. The fetch
    scheduler attaches that size only to the version sent with the download. *)

(** {1 Construction and validation} *)

val version : checksum:string -> file_type:string -> (version, string) result

val create
  :  uuid:Graph_types.Uuid.t
  -> source:source
  -> current_checksum:string option
  -> size:int64 option
  -> dimensions:(int * int) option
  -> (t, string) result

(** Attach request metadata to a scheduled fetch, not to the graph version.
    The hint does not participate in version identity. *)
val with_download_size_hint : version -> int64 option -> version

val equal_version : version -> version -> bool
val to_yojson : t -> Yojson.Safe.t

(** Decode UUIDs with [Graph_types.Uuid.of_yojson] and validate metadata through
    [version] and [create], including checksum, file type, size and dimensions. *)
val of_yojson : Yojson.Safe.t -> (t, string) result
