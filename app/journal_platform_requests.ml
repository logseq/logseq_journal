type response = (bytes, string) result
type scope = Logseq_db_worker_lui.Logseq_db_worker_lui_service.startup_scope

type t =
  { pending : (int, response -> unit) Hashtbl.t
  ; emit : bytes -> unit
  ; enqueue : (unit -> unit) -> unit
  ; is_running : unit -> bool
  ; current_scope : unit -> scope
  ; send_response : int -> response -> unit
  ; decode_failure : string -> unit
  }

let response_tag = function
  | 6 -> 7
  | 8 -> 9
  | 10 -> 11
  | 13 -> 14
  | 20 -> 21
  | 22 -> 23
  | 25 -> 26
  | 28 -> 29
  | 30 -> 31
  | 32 -> 33
  | tag -> tag
;;

let create ~emit ~enqueue ~is_running ~current_scope ~send_response ~decode_failure =
  { pending = Hashtbl.create 8
  ; emit
  ; enqueue
  ; is_running
  ; current_scope
  ; send_response
  ; decode_failure
  }
;;

let emit owner ?on_result packet =
  (match on_result, Bytes.length packet >= 8 with
   | Some callback, true ->
     let tag = Bytes.get_uint16_le packet 6 in
     Hashtbl.replace owner.pending (response_tag tag) callback
   | Some _, false | None, _ -> ());
  owner.emit packet
;;

let resolve owner ~response_tag result =
  match Hashtbl.find_opt owner.pending response_tag with
  | None -> false
  | Some callback ->
    Hashtbl.remove owner.pending response_tag;
    callback result;
    true
;;

let fail owner ~request_tag ~reason ~supplied_scope =
  let scope = owner.current_scope () in
  let matches_scope = match supplied_scope with
    | None -> true
    | Some (account,presentation) ->
      account = Int64.of_int scope.account_generation
      && presentation = Int64.of_int scope.presentation_generation in
  let response_tag = response_tag request_tag in
  let continuation = Hashtbl.find_opt owner.pending response_tag in
  if matches_scope then owner.enqueue (fun () ->
    if owner.is_running () && owner.current_scope () = scope then
      if request_tag = 0 then owner.decode_failure reason
      else match continuation, Hashtbl.find_opt owner.pending response_tag with
        | Some expected, Some current when expected == current ->
          owner.send_response response_tag (Error reason)
        | _ -> ())
;;
