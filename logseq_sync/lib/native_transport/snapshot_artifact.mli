val artifact_row_count : (string * string) list -> (int, string) result

val peel_gzip_layers
  :  decompress_gzip:(string -> string -> int -> int)
  -> maximum_bytes:int
  -> source:string
  -> destination:string
  -> temporary_paths:string list
  -> (unit, string) result
