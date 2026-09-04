let replace_all source needle replacement =
  if String.equal needle ""
  then source
  else (
    let buffer = Buffer.create (String.length source) in
    let rec loop offset =
      if offset >= String.length source
      then Buffer.contents buffer
      else if
        offset + String.length needle <= String.length source
        && String.sub source offset (String.length needle) = needle
      then (
        Buffer.add_string buffer replacement;
        loop (offset + String.length needle))
      else (
        Buffer.add_char buffer source.[offset];
        loop (offset + 1))
    in
    loop 0)
;;
