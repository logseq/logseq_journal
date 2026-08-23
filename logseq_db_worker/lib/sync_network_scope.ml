type operation_id = int

type operation =
  { id : operation_id
  ; account_generation : int
  ; graph_generation : int option
  ; cancel : unit -> unit
  }

type t =
  { mutable next_id : int
  ; mutable operations : operation list
  }

let create () = { next_id = 0; operations = [] }

let register t ~account_generation ~graph_generation ~cancel =
  t.next_id <- t.next_id + 1;
  let operation = { id = t.next_id; account_generation; graph_generation; cancel } in
  t.operations <- operation :: t.operations;
  operation.id
;;

let complete t operation_id =
  t.operations <- List.filter (fun operation -> operation.id <> operation_id) t.operations
;;

let cancel_where t predicate =
  let cancelled, retained = List.partition predicate t.operations in
  t.operations <- retained;
  List.iter (fun operation -> operation.cancel ()) cancelled
;;

let cancel_obsolete t ~account_generation ~graph_generation =
  cancel_where t (fun operation ->
    operation.account_generation <> account_generation
    ||
    match operation.graph_generation with
    | None -> false
    | Some generation -> generation <> graph_generation)
;;

let cancel_graph t ~account_generation ~graph_generation =
  cancel_where t (fun operation ->
    operation.account_generation = account_generation
    && operation.graph_generation = Some graph_generation)
;;

let cancel_all t = cancel_where t (fun _ -> true)
let active_count t = List.length t.operations
