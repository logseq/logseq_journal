type t =
  { canonical_title : string
  ; content_refs : int list
  ; inline_tags : int list
  }

type error =
  | Missing_reference of string
  | Ambiguous_reference of string
  | Invalid_reference of string

val derive : db:Datascript.db -> self:int -> title:string -> (t, error) result
