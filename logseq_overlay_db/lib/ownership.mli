type t

type error =
  | Already_owned
  | Unavailable of string

val acquire : graph_directory:string -> (t, error) result
val release : t -> (unit, string) result
