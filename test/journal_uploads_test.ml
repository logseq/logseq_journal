module P = Journal_uploads
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module U = Logseq_db_worker_pure_reducer.Asset_upload

let uuid n =
  P.Uuid.of_string (Printf.sprintf "81000000-0000-4000-8000-%012d" n) |> Result.get_ok
;;

let scope : S.asset_scope =
  { account =
      { managed_sync_origin = Uri.of_string "https://sync.example"
      ; user_id = "user"
      ; account_generation = 1
      ; presentation_generation = 1
      ; lifecycle_generation = 1L
      }
  ; graph_id = uuid 1
  ; graph_generation = 1
  }
;;

let notice n status =
  S.Upload_status
    { operation = uuid n
    ; asset = uuid (n + 100)
    ; target = uuid 2
    ; title = "Image"
    ; status
    }
;;

let () =
  let t = P.sync P.empty (Some (1, uuid 1)) in
  let t = P.notice t scope (notice 3 U.Sending) in
  assert (List.length (P.rows t) = 1);
  assert (List.hd (P.rows t)).busy;
  assert (P.retry t (uuid 3) = None);
  let t = P.notice t scope (notice 3 (Failed_upload Network)) in
  assert (List.hd (P.rows t)).retry;
  assert (
    match P.retry t (uuid 3) with
    | Some (S.Asset_command { graph_generation = 1; command = Retry_upload operation }) ->
      operation = uuid 3
    | _ -> false);
  let t = P.notice t scope (notice 3 U.Publishing) in
  assert ((List.hd (P.rows t)).message = "Publishing attachment metadata");
  let t = P.notice t scope (notice 3 U.Uploaded) in
  assert ((not (List.hd (P.rows t)).busy) && P.retry t (uuid 3) = None);
  let foreign = P.notice t { scope with graph_id = uuid 9 } (notice 4 U.Sending) in
  assert (P.rows foreign = P.rows t);
  let cleared = P.sync t (Some (2, uuid 1)) in
  assert (P.rows cleared = [] && P.retry cleared (uuid 3) = None);
  assert (P.rows (P.notice cleared scope (notice 3 U.Sending)) = []);
  let full =
    List.fold_left
      (fun t n -> P.notice t scope (notice n U.Sending))
      t
      (List.init 32 (fun n -> n + 10))
  in
  assert (List.length (P.rows full) = 32);
  assert (List.for_all (fun (r : P.row) -> r.busy) (P.rows full));
  List.iter
    (fun failure ->
       let t = P.notice t scope (notice 3 (Failed_upload failure)) in
       assert (not (List.hd (P.rows t)).retry))
    [ U.Missing_source; Size_rejected; Invalid_content ]
;;
