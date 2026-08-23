type purpose =
  | Catalog_discovery
  | Snapshot_bootstrap
  | E2ee_key_access
  | Http_pull
  | Transaction_submission
  | Websocket_connect

type challenge =
  { challenge_id : string
  ; purpose : purpose
  ; user_id : string
  ; account_generation : int
  ; graph_generation : int option
  ; connection_generation : int option
  }

type error =
  | Unknown_challenge
  | User_mismatch
  | Account_generation_mismatch
  | Graph_generation_mismatch
  | Connection_generation_mismatch
  | Invalid_token

type t =
  { next_id : unit -> string
  ; mutable pending : challenge list
  }

let create ~next_id () = { next_id; pending = [] }

let issue t ~purpose ~user_id ~account_generation ~graph_generation ~connection_generation
  =
  let challenge =
    { challenge_id = t.next_id ()
    ; purpose
    ; user_id
    ; account_generation
    ; graph_generation
    ; connection_generation
    }
  in
  t.pending <- challenge :: t.pending;
  challenge
;;

let provide
      t
      ~challenge_id
      ~user_id
      ~account_generation
      ~graph_generation
      ~connection_generation
      ~token
  =
  match
    List.find_opt
      (fun challenge -> String.equal challenge.challenge_id challenge_id)
      t.pending
  with
  | None -> Error Unknown_challenge
  | Some challenge when not (String.equal challenge.user_id user_id) ->
    Error User_mismatch
  | Some challenge when challenge.account_generation <> account_generation ->
    Error Account_generation_mismatch
  | Some challenge when challenge.graph_generation <> graph_generation ->
    Error Graph_generation_mismatch
  | Some challenge when challenge.connection_generation <> connection_generation ->
    Error Connection_generation_mismatch
  | Some _ when String.length token = 0 || String.length token > 1024 * 1024 ->
    Error Invalid_token
  | Some _ when (not (String.is_valid_utf_8 token)) || String.contains token '\000' ->
    Error Invalid_token
  | Some challenge ->
    t.pending
    <- List.filter
         (fun pending -> not (String.equal pending.challenge_id challenge_id))
         t.pending;
    Ok (challenge, token)
;;

let fail t ~challenge_id =
  match
    List.find_opt
      (fun challenge -> String.equal challenge.challenge_id challenge_id)
      t.pending
  with
  | None -> Error Unknown_challenge
  | Some challenge ->
    t.pending
    <- List.filter
         (fun pending -> not (String.equal pending.challenge_id challenge_id))
         t.pending;
    Ok challenge
;;

let cancel_all t = t.pending <- []
let pending_count t = List.length t.pending
let diagnostics t = Printf.sprintf "pending-id-token-challenges=%d" (pending_count t)
