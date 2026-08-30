type progress =
  { received_bytes : int
  ; total_bytes : int option
  ; datom_count : int option
  }

val artifact_row_count : (string * string) list -> (int, string) result

val peel_gzip_layers
  :  decompress_gzip:(string -> string -> int -> int)
  -> maximum_bytes:int
  -> source:string
  -> destination:string
  -> temporary_paths:string list
  -> (unit, string) result

val cleanup : string list -> unit
