module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Uuid = Logseq_db_types.Graph_types.Uuid
module U = Logseq_db_worker_pure_reducer.Asset_upload

type entry =
  { operation : Uuid.t
  ; title : string
  ; status : U.status
  }

type t =
  { context : (int * Uuid.t) option
  ; scope : Service.asset_scope option
  ; entries : entry list
  }

type row =
  { id : string
  ; title : string
  ; message : string
  ; busy : bool
  ; retry : bool
  }

let empty = { context = None; scope = None; entries = [] }
let sync t context = if t.context = context then t else { empty with context }

let terminal = function
  | U.Uploaded | Cancelled -> true
  | _ -> false
;;

let rec take n = function
  | _ when n = 0 -> []
  | [] -> []
  | x :: xs -> x :: take (n - 1) xs
;;

let notice t (scope : Service.asset_scope) = function
  | Service.Upload_status { operation; title; status; _ }
    when t.context = Some (scope.graph_generation, scope.graph_id)
         && (t.scope = None || t.scope = Some scope) ->
    let entries =
      { operation; title; status }
      :: List.filter (fun e -> e.operation <> operation) t.entries
    in
    let active, finished = List.partition (fun e -> not (terminal e.status)) entries in
    { t with scope = Some scope; entries = take 32 (active @ finished) }
  | _ -> t
;;

let describe = function
  | U.Preparing -> "Saving attachment", true, false
  | Waiting -> "Waiting for connection or graph unlock", false, false
  | Sending -> "Uploading attachment", true, false
  | Publishing -> "Publishing attachment metadata", true, false
  | Cancelling -> "Cancelling upload", true, false
  | Uploaded -> "Uploaded", false, false
  | Cancelled -> "Cancelled", false, false
  | Failed_upload failure ->
    (match failure with
     | Network -> "Upload interrupted", false, true
     | Authentication -> "Sign in or unlock the graph to upload", false, true
     | Persistence_failed _ -> "Could not save upload progress", false, true
     | Revoked_access -> "Upload access denied", false, true
     | Missing_source -> "Source file unavailable; attach the file again", false, false
     | Size_rejected -> "File too large to upload", false, false
     | Invalid_content -> "File cannot be uploaded; attach the file again", false, false)
;;

let rows t =
  List.map
    (fun e ->
       let message, busy, retry = describe e.status in
       { id = Uuid.to_string e.operation; title = e.title; message; busy; retry })
    t.entries
;;

let retry t operation =
  Option.bind t.scope (fun scope ->
    Option.bind
      (List.find_opt (fun e -> e.operation = operation) t.entries)
      (fun e ->
         let _, _, retryable = describe e.status in
         if retryable
         then
           Some
             (Service.Asset_command
                { graph_generation = scope.graph_generation
                ; command = Retry_upload operation
                })
         else None))
;;
