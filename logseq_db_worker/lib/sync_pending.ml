type state =
  | Queued
  | Submitted
  | Accepted of int
  | Blocked of string

type entry =
  { mutation_id : Graph_types.Uuid.t
  ; request : Protocol.request
  ; tx : string
  ; outliner_op : string
  ; state : state
  }

type t =
  { path : string
  ; mutable entries : entry list
  }

let maximum_file_bytes = 8 * 1024 * 1024
let maximum_entries = 4096
let path t = t.path
let entries t = t.entries

let exact_fields expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  List.sort String.compare expected = actual
;;

let state_to_json = function
  | Queued -> `Assoc [ "type", `String "queued" ]
  | Submitted -> `Assoc [ "type", `String "submitted" ]
  | Accepted t -> `Assoc [ "type", `String "accepted"; "serverT", `Int t ]
  | Blocked message -> `Assoc [ "type", `String "blocked"; "message", `String message ]
;;

let state_of_json = function
  | `Assoc ([ ("type", `String "queued") ] as fields) when exact_fields [ "type" ] fields
    -> Ok Queued
  | `Assoc ([ ("type", `String "submitted") ] as fields)
    when exact_fields [ "type" ] fields -> Ok Submitted
  | `Assoc fields when exact_fields [ "serverT"; "type" ] fields ->
    (match List.assoc_opt "type" fields, List.assoc_opt "serverT" fields with
     | Some (`String "accepted"), Some (`Int value) when value >= 0 -> Ok (Accepted value)
     | _ -> Error "invalid accepted pending state")
  | `Assoc fields when exact_fields [ "message"; "type" ] fields ->
    (match List.assoc_opt "type" fields, List.assoc_opt "message" fields with
     | Some (`String "blocked"), Some (`String message)
       when String.length message > 0 && String.length message <= 4096 ->
       Ok (Blocked message)
     | _ -> Error "invalid blocked pending state")
  | _ -> Error "invalid pending state"
;;

let entry_to_json entry =
  `Assoc
    [ "mutationId", `String (Graph_types.Uuid.to_string entry.mutation_id)
    ; "outlinerOp", `String entry.outliner_op
    ; "request", Protocol.request_to_yojson entry.request
    ; "state", state_to_json entry.state
    ; "tx", `String entry.tx
    ]
;;

let entry_of_json = function
  | `Assoc fields
    when exact_fields [ "mutationId"; "outlinerOp"; "request"; "state"; "tx" ] fields ->
    (match
       ( List.assoc_opt "mutationId" fields
       , List.assoc_opt "outlinerOp" fields
       , List.assoc_opt "request" fields
       , List.assoc_opt "state" fields
       , List.assoc_opt "tx" fields )
     with
     | ( Some (`String mutation_id)
       , Some (`String outliner_op)
       , Some request
       , Some state
       , Some (`String tx) )
       when String.length outliner_op > 0
            && String.length outliner_op <= 128
            && String.length tx > 0
            && String.length tx <= Protocol.maximum_request_bytes ->
       Result.bind (Graph_types.Uuid.of_string mutation_id) (fun mutation_id ->
         Result.bind
           (Protocol.request_of_yojson request
            |> Result.map_error (fun _ -> "invalid pending mutation request"))
           (fun request ->
              match request.Protocol.command with
              | Protocol.Mutate mutation
                when Graph_types.Uuid.equal
                       (Protocol.mutation_context mutation).mutation_id
                       mutation_id ->
                Result.map
                  (fun state -> { mutation_id; request; tx; outliner_op; state })
                  (state_of_json state)
              | Read _ | Sync_receive _ | Mutate _ ->
                Error "pending request is not its stable mutation"))
     | _ -> Error "invalid pending entry")
  | _ -> Error "invalid pending entry"
;;

let decode source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc fields when exact_fields [ "entries"; "version" ] fields ->
      (match List.assoc_opt "version" fields, List.assoc_opt "entries" fields with
       | Some (`Int 1), Some (`List values) when List.length values <= maximum_entries ->
         let rec loop entries = function
           | [] -> Ok (List.rev entries)
           | value :: rest ->
             Result.bind (entry_of_json value) (fun entry -> loop (entry :: entries) rest)
         in
         Result.bind (loop [] values) (fun entries ->
           let ids = List.map (fun entry -> entry.mutation_id) entries in
           if List.length ids = List.length (List.sort_uniq Graph_types.Uuid.compare ids)
           then Ok entries
           else Error "pending entries contain duplicate mutation IDs")
       | _ -> Error "invalid pending envelope")
    | _ -> Error "invalid pending envelope"
  with
  | _ -> Error "pending intent data is corrupt"
;;

let encode entries =
  Yojson.Safe.to_string
    (`Assoc [ "entries", `List (List.map entry_to_json entries); "version", `Int 1 ])
;;

let save path entries =
  let source = encode entries in
  if String.length source > maximum_file_bytes
  then Error "pending intent data exceeds its durable bound"
  else (
    let temporary = path ^ ".tmp" in
    try
      let channel =
        open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600 temporary
      in
      Fun.protect
        ~finally:(fun () -> close_out_noerr channel)
        (fun () ->
           output_string channel source;
           flush channel;
           Unix.fsync (Unix.descr_of_out_channel channel));
      Unix.rename temporary path;
      let directory = Unix.openfile (Filename.dirname path) [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close directory)
        (fun () -> Unix.fsync directory);
      Ok ()
    with
    | _ ->
      (try Sys.remove temporary with
       | _ -> ());
      Error "pending intent data could not be persisted")
;;

let open_ ~graph_dir =
  let path = Filename.concat graph_dir "pending-intents-v1.json" in
  if not (Sys.file_exists path)
  then Ok { path; entries = [] }
  else (
    try
      let stat = Unix.lstat path in
      if
        stat.st_kind <> Unix.S_REG
        || stat.st_nlink <> 1
        || stat.st_size > maximum_file_bytes
      then Error "pending intent path is unsafe"
      else (
        let channel = open_in_bin path in
        let source =
          Fun.protect
            ~finally:(fun () -> close_in_noerr channel)
            (fun () -> really_input_string channel stat.st_size)
        in
        Result.map (fun entries -> { path; entries }) (decode source))
    with
    | _ -> Error "pending intent data could not be read")
;;

let replace t entries =
  if List.length entries > maximum_entries
  then Error "too many pending intents"
  else (
    match save t.path entries with
    | Error _ as error -> error
    | Ok () ->
      t.entries <- entries;
      Ok ())
;;

let append t entry =
  if
    List.exists
      (fun current -> Graph_types.Uuid.equal current.mutation_id entry.mutation_id)
      t.entries
  then Error "pending mutation ID already exists"
  else replace t (t.entries @ [ entry ])
;;
