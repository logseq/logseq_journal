type account
type graph
type connection

type account_scope =
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; account_generation : int
  ; presentation_generation : int
  ; permit_id : int64
  }

type graph_scope =
  { account : account_scope
  ; graph_id : string
  ; graph_generation : int
  }

type connection_scope =
  { graph : graph_scope
  ; connection_generation : int
  ; lifecycle_generation : int64
  }

type account_scope_view =
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; account_generation : int
  ; presentation_generation : int
  ; permit_id : int64
  }

type graph_scope_view =
  { account : account_scope_view
  ; graph_id : string
  ; graph_generation : int
  }

type connection_scope_view =
  { graph : graph_scope_view
  ; connection_generation : int
  ; lifecycle_generation : int64
  }

let bounded_text ~maximum value =
  String.length value > 0
  && String.length value <= maximum
  && String.is_valid_utf_8 value
  && not (String.contains value '\000')
;;

let canonical_uuid value =
  let hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  String.length value = 36
  && List.for_all (fun index -> value.[index] = '-') [ 8; 13; 18; 23 ]
  && String.to_seqi value
     |> Seq.for_all (fun (index, character) ->
       List.mem index [ 8; 13; 18; 23 ] || hex character)
;;

let valid_origin origin =
  let encoded = Uri.to_string origin in
  bounded_text ~maximum:2_048 encoded
  && Uri.scheme origin = Some "https"
  && Option.fold ~none:false ~some:(bounded_text ~maximum:255) (Uri.host origin)
;;

let account_scope
      ~managed_sync_origin
      ~user_id
      ~account_generation
      ~presentation_generation
      ~permit_id
  =
  if
    valid_origin managed_sync_origin
    && bounded_text ~maximum:512 user_id
    && account_generation >= 0
    && presentation_generation >= 0
    && Int64.compare permit_id 0L >= 0
  then
    Some
      ({ managed_sync_origin
       ; user_id
       ; account_generation
       ; presentation_generation
       ; permit_id
       }
       : account_scope)
  else None
;;

let graph_scope account ~graph_id ~graph_generation =
  if canonical_uuid graph_id && graph_generation >= 0
  then Some ({ account; graph_id; graph_generation } : graph_scope)
  else None
;;

let connection_scope graph ~connection_generation ~lifecycle_generation =
  if connection_generation >= 0 && Int64.compare lifecycle_generation 0L >= 0
  then Some ({ graph; connection_generation; lifecycle_generation } : connection_scope)
  else None
;;

let account_scope_view (scope : account_scope) =
  { managed_sync_origin = scope.managed_sync_origin
  ; user_id = scope.user_id
  ; account_generation = scope.account_generation
  ; presentation_generation = scope.presentation_generation
  ; permit_id = scope.permit_id
  }
;;

let graph_scope_view (scope : graph_scope) =
  { account = account_scope_view scope.account
  ; graph_id = scope.graph_id
  ; graph_generation = scope.graph_generation
  }
;;

let connection_scope_view (scope : connection_scope) =
  { graph = graph_scope_view scope.graph
  ; connection_generation = scope.connection_generation
  ; lifecycle_generation = scope.lifecycle_generation
  }
;;

let account_scope_of_graph (scope : graph_scope) = scope.account
let graph_scope_of_connection (scope : connection_scope) = scope.graph

type restoring
type presented

type _ witness =
  | Restoring :
      { scope : graph_scope
      ; restore_id : int64
      }
      -> restoring witness
  | Presented :
      { scope : graph_scope
      ; restore_id : int64
      }
      -> presented witness

let next_id = ref 0L

let fresh_id () =
  let value = !next_id in
  next_id := Int64.succ value;
  value
;;

let begin_restore scope = Restoring { scope; restore_id = fresh_id () }

let witness_graph_scope : type phase. phase witness -> graph_scope = function
  | Restoring witness -> witness.scope
  | Presented witness -> witness.scope
;;

type timeline_ack =
  { account_generation : int
  ; graph_generation : int
  ; presentation_generation : int
  }

let acknowledge_timeline (Restoring witness) ack =
  let scope = witness.scope in
  if
    scope.account.account_generation = ack.account_generation
    && scope.graph_generation = ack.graph_generation
    && scope.account.presentation_generation = ack.presentation_generation
  then Some (Presented { scope = witness.scope; restore_id = witness.restore_id })
  else None
;;

type mirror
type wrapped_graph_key
type local_private_key
type graph_open

type 'kind local_request =
  { scope : graph_scope
  ; restore_id : int64
  ; request_id : int64
  }

let local_request (Restoring witness) =
  { scope = witness.scope; restore_id = witness.restore_id; request_id = fresh_id () }
;;

let request_mirror witness = local_request witness
let request_wrapped_graph_key witness = local_request witness
let request_local_private_key witness = local_request witness
let request_graph_open witness = local_request witness
let local_request_graph_scope request = request.scope

type recovery_reason =
  | Mirror_unavailable
  | Wrapped_graph_key_unavailable
  | Local_private_key_unavailable
  | Local_graph_open_failed of string

type 'kind failure_receipt =
  { scope : graph_scope
  ; restore_id : int64
  ; request_id : int64
  ; reason : recovery_reason
  ; mutable recovered : bool
  }

let failure_receipt (type kind) (request : kind local_request) reason : kind failure_receipt =
  { scope = request.scope
  ; restore_id = request.restore_id
  ; request_id = request.request_id
  ; reason
  ; recovered = false
  }
;;

module Local_completion = struct
  let mirror_failed (request : mirror local_request) ~diagnostic:_ =
    failure_receipt request Mirror_unavailable
  ;;

  let wrapped_graph_key_failed
        (request : wrapped_graph_key local_request)
        ~diagnostic:_
    =
    failure_receipt request Wrapped_graph_key_unavailable
  ;;

  let local_private_key_failed
        (request : local_private_key local_request)
        ~diagnostic:_
    =
    failure_receipt request Local_private_key_unavailable
  ;;

  let graph_open_failed (request : graph_open local_request) ~diagnostic =
    failure_receipt request (Local_graph_open_failed diagnostic)
  ;;
end

type online_recovery =
  { scope : graph_scope
  ; reason : recovery_reason
  ; mutable consumed : bool
  }

type account_online_recovery =
  { account_scope : account_scope
  ; mutable account_consumed : bool
  }

let recover (Restoring witness) receipt =
  ignore receipt.request_id;
  if
    (not receipt.recovered)
    && witness.restore_id = receipt.restore_id
    && witness.scope = receipt.scope
  then (
    receipt.recovered <- true;
    Some { scope = witness.scope; reason = receipt.reason; consumed = false })
  else None
;;

let recovery_reason recovery = recovery.reason
let begin_account_recovery account_scope = { account_scope; account_consumed = false }

type _ network_permit =
  | Account_permit : account_scope -> account network_permit
  | Graph_permit : graph_scope -> graph network_permit
  | Connection_permit : connection_scope -> connection network_permit

let permit_reconciliation (Presented witness) = Graph_permit witness.scope

let permit_recovery recovery =
  if recovery.consumed
  then Error `Already_consumed
  else (
    recovery.consumed <- true;
    Ok (Graph_permit recovery.scope))
;;

let permit_account_recovery recovery =
  if recovery.account_consumed
  then Error `Already_consumed
  else (
    recovery.account_consumed <- true;
    Ok (Account_permit recovery.account_scope))
;;

let account_permit : type level. level network_permit -> account network_permit = function
  | Account_permit scope -> Account_permit scope
  | Graph_permit scope -> Account_permit scope.account
  | Connection_permit scope -> Account_permit scope.graph.account
;;

let connection_permit (Graph_permit permitted) (connection : connection_scope) =
  if permitted = connection.graph then Some (Connection_permit connection) else None
;;

let permit_account_scope : type level. level network_permit -> account_scope = function
  | Account_permit scope -> scope
  | Graph_permit scope -> scope.account
  | Connection_permit scope -> scope.graph.account
;;

let permit_graph_scope (Graph_permit scope) = scope
let permit_connection_scope (Connection_permit scope) = scope

let account_scope_matches
      (scope : account_scope)
      ~account_generation
      ~presentation_generation
  =
  scope.account_generation = account_generation
  && scope.presentation_generation = presentation_generation
;;

let graph_scope_matches
      (scope : graph_scope)
      ~account_generation
      ~graph_generation
      ~presentation_generation
  =
  account_scope_matches scope.account ~account_generation ~presentation_generation
  && scope.graph_generation = graph_generation
;;

let connection_scope_matches
      (scope : connection_scope)
      ~account_generation
      ~graph_generation
      ~connection_generation
      ~presentation_generation
      ~lifecycle_generation
  =
  graph_scope_matches
    scope.graph
    ~account_generation
    ~graph_generation
    ~presentation_generation
  && scope.connection_generation = connection_generation
  && Int64.equal scope.lifecycle_generation lifecycle_generation
;;
