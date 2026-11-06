type t = int
let create day =
  let year=day/10000 and month=day/100 mod 100 and date=day mod 100 in
  let leap=year mod 400=0 || (year mod 4=0 && year mod 100<>0)in
  let maximum=match month with 2->if leap then 29 else 28|4|6|9|11->30|_->31 in
  if year<1 || year>9999 || month<1 || month>12 || date<1 || date>maximum
  then Error "Invalid journal day" else Ok day
let value day=day
