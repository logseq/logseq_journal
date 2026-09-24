module P = Journal_media
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module A = Logseq_db_types.Asset_descriptor

let check x message = if not x then failwith message

let uuid n =
  Logseq_db_types.Graph_types.Uuid.of_string
    (Printf.sprintf "88000000-0000-4000-8000-%012d" n)
  |> Result.get_ok
;;

let version c = A.version ~checksum:(String.make 64 c) ~file_type:"png" |> Result.get_ok

let asset c =
  A.create
    ~uuid:(uuid 1)
    ~source:(Managed (Some (version c)))
    ~current_checksum:None
    ~size:None
    ~dimensions:(Some (200, 100))
  |> Result.get_ok
;;

let scope : S.asset_scope =
  { account =
      { managed_sync_origin = Uri.of_string "https://sync.example"
      ; user_id = "user"
      ; account_generation = 1
      ; presentation_generation = 1
      ; lifecycle_generation = 1L
      }
  ; graph_id = uuid 2
  ; graph_generation = 1
  }
;;

let show a = P.Show { graph_generation = 1; consumer = "visible"; asset = a }

let ready state handle =
  P.step
    state
    (Availability { scope; consumer = "visible"; availability = S.Asset.Ready handle })
;;

let acquire effects =
  List.find_map
    (function
      | P.Acquire t -> Some t
      | _ -> None)
    effects
  |> Option.get
;;

let releases effects =
  List.filter
    (function
      | P.Release_file _ -> true
      | _ -> false)
    effects
;;

let () =
  let state, effects = P.step P.empty (show (asset 'a')) in
  check
    (List.exists
       (function
         | P.Demand _ -> true
         | _ -> false)
       effects)
    "visible media must request foreground demand";
  let _, effects = P.step state Capacity_available in
  check (effects = []) "capacity does not resend an accepted demand";
  let pressured, _ = P.step state Demand_backpressured in
  let admitted, effects = P.step pressured Capacity_available in
  check
    (List.exists
       (function
         | P.Demand _ -> true
         | _ -> false)
       effects)
    "capacity resumes only a pressured demand";
  let _, effects = P.step admitted Capacity_available in
  check (effects = []) "capacity retry waits for acknowledgement";
  let pending, effects = ready state "cache-a" in
  let ticket = acquire effects in
  check
    (match P.presentation pending with
     | Placeholder _ -> true
     | _ -> false)
    "cache handle is not a rendered path";
  let duplicate, effects = ready pending "cache-a" in
  check (effects = []) "duplicate readiness does not acquire twice";
  let visible, _ =
    P.step duplicate (Acquired (ticket, Some ("lease-a", "/cache/a.png")))
  in
  check (P.presentation visible = File "/cache/a.png") "retained file is displayed";
  let duplicate, effects =
    P.step visible (Acquired (ticket, Some ("lease-a", "/cache/a.png")))
  in
  check
    (effects = [] && P.presentation duplicate = File "/cache/a.png")
    "duplicate completion cannot release the displayed lease";
  let _, effects = P.step visible Hide in
  check (List.length (releases effects) = 1) "hidden media releases its lease";
  let hidden, _ = P.step pending Hide in
  let hidden, effects =
    P.step hidden (Acquired (ticket, Some ("late", "/cache/a.png")))
  in
  check
    (P.presentation hidden = Hidden && List.length (releases effects) = 1)
    "late acquisition is released without display";
  let replacement, effects = P.step visible (show (asset 'b')) in
  check (List.length (releases effects) = 1) "version replacement releases old file";
  check
    (match P.presentation replacement with
     | Placeholder _ -> true
     | _ -> false)
    "new version never displays old bytes";
  let unchanged, effects =
    P.step
      replacement
      (Availability
         { scope = { scope with graph_generation = 2 }
         ; consumer = "visible"
         ; availability = Ready "wrong"
         })
  in
  check
    (effects = [] && P.presentation unchanged = P.presentation replacement)
    "foreign scope does not acquire";
  let external_asset =
    A.create
      ~uuid:(uuid 3)
      ~source:(External "https://example.com/file.png")
      ~current_checksum:None
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  let external_state, effects = P.step P.empty (show external_asset) in
  check
    (effects = []
     && P.presentation external_state = External "https://example.com/file.png")
    "external media has no managed demand";
  let missing, _ = P.step pending (Acquired (ticket, None)) in
  let _, effects = P.step missing Retry_requested in
  check
    (List.exists
       (function
         | P.Acquire _ -> true
         | _ -> false)
       effects)
    "failed lease acquisition is retried independently of an already ready transfer"
;;
