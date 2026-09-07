type allocation =
  { timestamp_ms : int64
  ; payload_high : int
  ; payload_low : int64
  }

type t = allocation option

type error =
  | Timestamp_out_of_range
  | Invalid_random_length of int
  | Payload_exhausted

let empty = None
let maximum_timestamp = 0xffffffffffffL
let maximum_payload_low = 0x3fffffffffffffffL

let fresh timestamp_ms random_bytes =
  let byte index = Char.code (Bytes.get random_bytes index) in
  let payload_high = ((byte 6 land 0x0f) lsl 8) lor byte 7 in
  let payload_low = ref 0L in
  for index = 8 to 15 do
    payload_low := Int64.(logor (shift_left !payload_low 8) (of_int (byte index)))
  done;
  { timestamp_ms
  ; payload_high
  ; payload_low = Int64.logand !payload_low maximum_payload_low
  }
;;

let increment last =
  if last.payload_low <> maximum_payload_low
  then Ok { last with payload_low = Int64.succ last.payload_low }
  else if last.payload_high < 0x0fff
  then Ok { last with payload_high = last.payload_high + 1; payload_low = 0L }
  else Error Payload_exhausted
;;

let uuid allocation =
  Printf.sprintf
    "%08Lx-%04Lx-8%03x-%04Lx-%012Lx"
    (Int64.shift_right_logical allocation.timestamp_ms 16)
    (Int64.logand allocation.timestamp_ms 0xffffL)
    allocation.payload_high
    Int64.(logor 0x8000L (shift_right_logical allocation.payload_low 48))
    (Int64.logand allocation.payload_low 0xffffffffffffL)
  |> Graph_types.Uuid.of_string
  |> Result.get_ok
;;

let next state ~timestamp_ms ~random_bytes =
  if timestamp_ms < 0L || timestamp_ms > maximum_timestamp
  then Error Timestamp_out_of_range
  else if Bytes.length random_bytes <> 16
  then Error (Invalid_random_length (Bytes.length random_bytes))
  else (
    let allocation =
      match state with
      | None -> Ok (fresh timestamp_ms random_bytes)
      | Some last when timestamp_ms > last.timestamp_ms ->
        Ok (fresh timestamp_ms random_bytes)
      | Some last -> increment last
    in
    Result.map (fun allocation -> Some allocation, uuid allocation) allocation)
;;
