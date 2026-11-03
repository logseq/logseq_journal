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

let test_external_urls () =
  List.iter
    (fun (url, allowed) ->
       let asset =
         A.create
           ~uuid:(uuid 3)
           ~source:(External url)
           ~current_checksum:None
           ~size:None
           ~dimensions:None
         |> Result.get_ok
       in
       let state, effects = P.step P.empty (show asset) in
       check (effects = []) "external URLs never create managed demands";
       check
         (P.presentation state = External url = allowed)
         ("external URL allowlist: " ^ url))
    [ "https://example.com/file.png", true
    ; "HTTP://example.com/file.png", true
    ; "https://example.com/日记.png", true
    ; "https://例子.测试/日记", true
    ; "https://example.com/\255", false
    ; "https://[::1]:443/file", true
    ; "http://example.com:65536/file", false
    ; "hTtPs://example.com/%E6%97%A5%E8%AE%B0?q=one%20two", true
    ; "logseq://fixture", false
    ; "file:///tmp/fixture", false
    ; "javascript:alert(1)", false
    ; "data:text/plain,fixture", false
    ; "//example.com/file", false
    ; "https://", false
    ; "https:/example.com/file", false
    ; "https://exa mple.com/file", false
    ; "https://example.com/line\nnext", false
    ; "https://[broken/file", false
    ; "https://example.com:bad/file", false
    ; "https://example.com/%ZZ", false
    ; "", false
    ]
;;

let () =
  let failed = ref 0 in
  let run name test =
    try
      test ();
      Printf.printf "PASS %s\n%!" name
    with
    | exn ->
      incr failed;
      Printf.printf "FAIL %s: %s\n%!" name (Printexc.to_string exn)
  in
  run "pending same-UUID metadata refreshes demand" (fun () ->
    let local checksum = A.create ~uuid:(uuid 1) ~source:(Managed None)
      ~current_checksum:(Some (String.make 64 checksum)) ~size:None ~dimensions:None
      |> Result.get_ok in
    let pending, _ = P.step P.empty (show (local 'a')) in
    let _, unchanged = P.step pending (show (local 'a')) in
    check (unchanged = []) "unchanged pending descriptor is inert";
    let _, effects = P.step pending (show (asset 'a')) in
    check (List.exists (function P.Demand _ -> true | _ -> false) effects)
      "published version refreshes pending demand";
    let _, effects = P.step pending (show (local 'b')) in
    check (List.exists (function P.Demand _ -> true | _ -> false) effects)
      "changed current checksum refreshes pending demand");
  run "typed local readiness shows Loading until acquisition" (fun () ->
    let waiting, _ = P.step P.empty (show (asset 'a')) in
    let pending, effects = ready waiting "local" in
    check
      (P.presentation pending = Placeholder "Loading")
      "Ready opens locally as Loading";
    check (List.length effects = 1) "local readiness only acquires a file";
    let ticket = acquire effects in
    let duplicate, effects = ready pending "local" in
    check
      (effects = [] && P.presentation duplicate = Placeholder "Loading")
      "duplicate Ready preserves acquisition";
    let visible, effects =
      P.step duplicate (Acquired (ticket, Some ("lease", "/cache/local")))
    in
    check
      (effects = [] && P.presentation visible = File "/cache/local")
      "local completion publishes retained file");
  run "typed download transitions into local Loading" (fun () ->
    let waiting, _ = P.step P.empty (show (asset 'a')) in
    let downloading, effects =
      P.step
        waiting
        (Availability { scope; consumer = "visible"; availability = Downloading })
    in
    check
      (effects = [] && P.presentation downloading = Placeholder "Downloading")
      "only typed Downloading says Downloading";
    let pending, effects = ready downloading "downloaded-local" in
    check
      (P.presentation pending = Placeholder "Loading")
      "remote completion starts local Loading";
    let visible, effects =
      P.step pending (Acquired (acquire effects, Some ("lease", "/cache/downloaded")))
    in
    check
      (effects = [] && P.presentation visible = File "/cache/downloaded")
      "remote then local completion publishes file");
  run "queued and unavailable states never masquerade as downloads" (fun () ->
    let waiting, _ = P.step P.empty (show (asset 'a')) in
    List.iter
      (fun (availability, label) ->
         let state, effects =
           P.step waiting (Availability { scope; consumer = "visible"; availability })
         in
         check
           (effects = [] && P.presentation state = Placeholder label)
           "typed wait retains its specific label")
      [ S.Asset.Queued, "Waiting for file"
      ; Waiting_remote, "Waiting for upload"
      ; Waiting_network, "Available when online"
      ; Waiting_unlock, "Unlock graph to view file"
      ]);
  run "local acquisition failure has no user retry" (fun () ->
    let waiting, _ = P.step P.empty (show (asset 'a')) in
    let pending, effects = ready waiting "local" in
    let old = acquire effects in
    let failed, effects = P.step pending (Acquired (old, None)) in
    check (effects=[] && P.presentation failed=Failed "Unable to open file") "local error remains visible";
    let same,effects=P.step failed Retry_requested in
    check(same=failed && effects=[]) "local file failure must not expose a retry operation");
  run "non-network availability failures have no user retry" (fun () ->
    List.iter(fun failure ->
      let waiting,_=P.step P.empty (show(asset 'a')) in
      let failed,_=P.step waiting(Availability{scope;consumer="visible";
        availability=Failed{failure;attempts=1;retry_scheduled=false}}) in
      let same,effects=P.step failed Retry_requested in
      check(same=failed && effects=[]) "non-network failure admitted manual retry")
      [S.Asset.Not_found;Checksum_mismatch;Authentication;Locked;Storage_full;Invalid_content "Synthetic"]);
  run "loading cannot Retry" (fun () ->
    let loading, _ = P.step P.empty (show (asset 'a')) in
    let _, effects = P.step loading Retry_requested in
    check (effects = []) "loading ignores Retry instead of starting another download");
  run "same UUID content version retires successful File" (fun () ->
    let loading, _ = P.step P.empty (show (asset 'a')) in
    let pending, effects = ready loading "cached" in
    let visible, _ =
      P.step pending (Acquired (acquire effects, Some ("held", "/cache/held")))
    in
    let updated, effects = P.step visible (show (asset 'b')) in
    check(List.length(releases effects)=1) "version replacement retires the old renderer lease once";
    check(List.exists(function P.Demand{asset=descriptor;_}->descriptor=asset 'b'|_->false)effects)
      "version replacement demands the new content";
    check(match P.presentation updated with Placeholder _->true|_->false)
      "old rendered bytes cannot represent the new descriptor");
  run "preview pins retain their selected version" (fun () ->
    let loading,_=P.step P.empty(show(asset 'a')) in
    let pending,effects=ready loading "cached-a" in
    let visible,_=P.step pending(Acquired(acquire effects,Some("held-a","/cache/a"))) in
    let pinned,_=P.step visible(Pin_preview "preview-one") in
    let pinned,_=P.step pinned(Pin_preview "preview-two") in
    let replaced,effects=P.step pinned(show(asset 'b')) in
    check(releases effects=[]) "changing row content must retain the open previews' original file";
    let loading,effects=ready replaced "cached-b" in
    let current,_=P.step loading(Acquired(acquire effects,Some("held-b","/cache/b"))) in
    let current,_=P.step current(Pin_preview "preview-one") in
    let current,effects=P.step current(Unpin_preview "preview-one") in
    check(effects=[]) "another preview still holds the original version";
    let current,effects=P.step current(Unpin_preview "preview-two") in
    check(releases effects=[P.Release_file{scope;lease="held-a"}]) "last old preview releases only its original file";
    check(P.presentation current=File "/cache/b") "closing an old preview leaves the new row file";
    let _,effects=P.step current Hide in
    check(releases effects=[P.Release_file{scope;lease="held-b"}]) "last current row releases the new version");
  run "failed Retry is one explicit attempt" (fun () ->
    let loading, _ = P.step P.empty (show (asset 'a')) in
    let failed, _ =
      P.step
        loading
        (Availability
           { scope
           ; consumer = "visible"
           ; availability =
               Failed { failure = Network; attempts = 1; retry_scheduled = false }
           })
    in
    let retrying, effects = P.step failed Retry_requested in
    check (List.length effects = 1) "failed Retry starts one attempt";
    let _, duplicate = P.step retrying Retry_requested in
    check (duplicate = []) "repeated Retry while loading starts no additional attempt");
  run "successful File ignores late statuses and Retry" (fun () ->
    let loading, _ = P.step P.empty (show (asset 'a')) in
    let pending, effects = ready loading "cached" in
    let visible, _ =
      P.step pending (Acquired (acquire effects, Some ("held", "/cache/held")))
    in
    List.iter
      (fun availability ->
         let stable, effects =
           P.step visible (Availability { scope; consumer = "visible"; availability })
         in
         check
           (effects = [] && P.presentation stable = File "/cache/held")
           "successful File is stable across transfer notifications")
      [ S.Asset.Queued
      ; Downloading
      ; Ready "other"
      ; Failed { failure = Network; attempts = 1; retry_scheduled = false }
      ];
    let _, effects = P.step visible Retry_requested in
    check (effects = []) "successful File cannot Retry");
  run "offscreen releases then local acquisition is allowed" (fun () ->
    let loading, _ = P.step P.empty (show (asset 'a')) in
    let pending, effects = ready loading "cached" in
    let visible, _ =
      P.step pending (Acquired (acquire effects, Some ("held", "/cache/held")))
    in
    let hidden, effects = P.step visible Hide in
    check (List.length (releases effects) = 1) "Hide releases exactly one lease";
    let shown, _ = P.step hidden (show (asset 'b')) in
    let _, effects = ready shown "cached" in
    check (List.length effects = 1) "reappearance can acquire the local file once");
  check (!failed = 0) (Printf.sprintf "%d media retry cases failed" !failed)
;;

let () =
  test_external_urls ();
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
  let _, effects = P.step visible Hide in
  check (List.length (releases effects) = 1) "hidden media releases its lease";
  let hidden, _ = P.step pending Hide in
  let hidden, effects =
    P.step hidden (Acquired (ticket, Some ("late", "/cache/a.png")))
  in
  check
    (P.presentation hidden = Hidden && List.length (releases effects) = 1)
    "late acquisition is released without display";
  let replacement, _ = P.step visible (show (asset 'b')) in
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
  check (effects=[])
    "failed local lease acquisition cannot be retried by the user"
;;

(* Generate actual preview actions and exactly-once asynchronous completions.
   Shrinking removes actions and regenerates their legal prerequisites. *)
let test_preview_pin_traces () =
  let run actions =
    let state=ref P.empty and jobs=ref [] and pins=Hashtbl.create 2
    and allocated=Hashtbl.create 32 and released=Hashtbl.create 32 and serial=ref 0 in
    let apply event=
      let next,effects=P.step !state event in state:=next;
      List.iter(function
        |P.Acquire ticket->jobs:= !jobs@[ticket]
        |Release_file{lease;_}->
          check(Hashtbl.mem allocated lease) "release must name a real acquired lease";
          check(not(Hashtbl.mem released lease)) "a lease is released at most once";
          Hashtbl.add released lease ()
        |Demand _|Release _|Retry _->())effects;
      let held path=check(not(Hashtbl.mem released path)) "a rendered version still has its lease" in
      (match P.presentation !state with File path->held path|_->());
      Hashtbl.iter(fun _ path->held path)pins in
    let complete choice success=match !jobs with
      |[]->()
      |_->let index=choice mod List.length !jobs in
        let ticket=List.nth !jobs index in
        jobs:=List.filteri(fun i _->i<>index)!jobs;
        incr serial;
        let lease=Printf.sprintf "lease-%d" !serial in
        if success then Hashtbl.add allocated lease ();
        apply(Acquired(ticket,if success then Some(lease,lease) else None)) in
    List.iter(fun choice->match choice mod 7 with
      |0->apply(show(asset 'a'))
      |1->apply(show(asset 'b'))
      |2->(match P.presentation !state,P.descriptor !state with
          |(Placeholder _|Failed _),Some{source=Managed(Some version);_}->
            apply(Availability{scope;consumer="visible";availability=Ready("cache:"^version.checksum)})
          |_->())
      |3->complete(choice/7)(choice mod 3<>0)
      |4->(match P.presentation !state with
          |File path->let owner=string_of_int(choice mod 2) in
            if not(Hashtbl.mem pins owner)then Hashtbl.add pins owner path;
            apply(Pin_preview owner)
          |_->())
      |5->let owner=string_of_int(choice mod 2) in
        if Hashtbl.mem pins owner then (Hashtbl.remove pins owner;apply(Unpin_preview owner))
      |_->Hashtbl.clear pins;apply Hide)actions;
    Hashtbl.clear pins;apply Hide;
    while !jobs<>[] do complete 0 true done;
    Hashtbl.iter(fun lease _->check(Hashtbl.mem released lease) "retired previews and late completions settle all leases")allocated in
  let fails actions=try run actions;false with Failure _->true in
  let rec shrink actions=
    let rec remove prefix=function []->actions|_::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      |action::rest->remove(action::prefix)rest in remove [] actions in
  for seed=0 to 99 do
    let random=Random.State.make[|0xF11E;seed|] in
    let actions=List.init 80(fun _->Random.State.int random 140) in
    if fails actions then failwith(Printf.sprintf "preview lease seed=%d minimized=%s" seed
      (String.concat ";"(List.map string_of_int(shrink actions))))
  done
;;
let ()=test_preview_pin_traces();print_endline "Pure media: 100 preview lease/version traces with shrinking passed"
