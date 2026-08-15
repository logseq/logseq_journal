type classification =
  | Success
  | Local_error
  | Execute_error
  | Open_error
  | Fatal_error

let exit_code = function
  | Success -> 0
  | Local_error -> 2
  | Execute_error -> 3
  | Open_error -> 4
  | Fatal_error -> 5
;;

let classify_response = function
  | Logseq_db_worker.Protocol.Succeeded _ -> Success
  | Failed { phase = Execute; _ } -> Execute_error
  | Failed { phase = Open; _ } -> Open_error
;;

let response_line response =
  response |> Logseq_db_worker.Protocol.response_to_yojson |> Yojson.Safe.to_string
;;
