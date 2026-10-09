type t = int64

let zero = 0L
let of_int64 value = if value < 0L then Error `Negative_cursor else Ok value
let to_int64 value = value
let equal = Int64.equal
let compare = Int64.compare
