type progress =
  { received_bytes : int
  ; total_bytes : int option
  ; datom_count : int option
  }

type baseline = { server_t : int }

type content_encoding =
  [ `Gzip
  | `Identity
  ]

type snapshot_metadata =
  { key : string
  ; url : Uri.t
  ; content_encoding : content_encoding option
  }

val maximum_gzip_layers : int
val decode_baseline : string -> (baseline, string) result
val decode_snapshot_metadata : string -> (snapshot_metadata, string) result
val artifact_row_count : (string * string) list -> (int, string) result

val peel_gzip_layers
  :  maximum_bytes:int
  -> source:string
  -> destination:string
  -> temporary_paths:string list
  -> (unit, string) result

val cleanup : string list -> unit
