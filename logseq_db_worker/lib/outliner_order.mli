type error =
  | Invalid_key of string
  | No_space

val is_valid : string -> bool
val between : lower:string option -> upper:string option -> (string, error) result
val sequence_between : lower:string option -> upper:string option -> int -> (string list, error) result
