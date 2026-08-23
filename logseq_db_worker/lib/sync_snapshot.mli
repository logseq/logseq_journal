type row =
  { addr : int
  ; content : string
  ; addresses : string option
  }

type parser
type import
type completed_import = { row_count : int }

val create_parser : max_frame_bytes:int -> parser
val feed : parser -> string -> (row list, string) result
val finish : parser -> (unit, string) result
val create_import : expected_rows:int -> import
val accept_rows : import -> row list -> (unit, string) result
val finish_import : import -> (completed_import, string) result
