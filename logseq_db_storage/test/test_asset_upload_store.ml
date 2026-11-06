module S = Logseq_db_storage.Asset_upload_store
module I = Logseq_db_types.Asset_upload_intent
module A = Logseq_db_types.Asset_descriptor
module U = Logseq_db_types.Graph_types.Uuid

let get = function
  | Ok x -> x
  | Error e -> failwith e
;;

let uuid n = get (U.of_string (Printf.sprintf "00000000-0000-4000-8000-%012d" n))

let intent ?(origin = "https://sync.example") ?(graph = uuid 1) ?(account = "user") n =
  get
    (I.prepare
       ~replace_reference:(Some (uuid 99))
       ~operation_id:(uuid n)
       ~origin
       ~account
       ~graph
       ~asset:(uuid (n + 100))
       ~version:(get (A.version ~checksum:(String.make 64 'a') ~file_type:"png"))
       ~title:"Fixture image"
       ~size:4L
       ~staged_file:("staged-" ^ string_of_int n)
       ~target:(uuid 4)
       ~local_mutation:(uuid (n + 200))
       ~metadata_mutation:(uuid (n + 300)))
;;

let fixture test =
  let path = Filename.temp_file "asset-upload" ".sqlite" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> test path)
;;

let with_db path f =
  let db = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () ->
       get (S.initialize_database db);
       f db)
;;

let restart () =
  fixture (fun path ->
    let original = intent 2 in
    with_db path (fun db -> get (S.save db ~expected:None original));
    with_db path (fun db ->
      Alcotest.(check bool)
        "checkpoint survives reopening"
        true
        (get (S.read db ~operation:original.operation_id) = Some original)))
;;

let atomic_revision () =
  fixture (fun path ->
    with_db path (fun db ->
      let initial = intent 2 in
      get (S.save db ~expected:None initial);
      get (S.save db ~expected:None initial);
      let local = get (I.advance initial Local_committed) in
      get (S.save db ~expected:(Some 0) local);
      Alcotest.(check bool)
        "stale checkpoint rejected"
        true
        (Result.is_error (S.save db ~expected:None initial));
      let cancelled = get (I.advance initial Cancelled) in
      Alcotest.(check bool)
        "CAS rejects conflicting checkpoint"
        true
        (Result.is_error (S.save db ~expected:(Some 0) cancelled));
      Alcotest.(check bool)
        "current phase retained"
        true
        (get (S.read db ~operation:initial.operation_id) = Some local)))
;;

let paging () =
  fixture (fun path ->
    with_db path (fun db ->
      List.iter
        (fun i -> get (S.save db ~expected:None i))
        [ intent 2; intent 3; intent ~account:"other" 4 ];
      let page after =
        get
          (S.list
             db
             ~origin:"https://sync.example"
             ~account:"user"
             ~graph:(uuid 1)
             ~after
             ~limit:1)
      in
      let first = page None in
      Alcotest.(check int) "bounded first page" 1 (List.length first);
      let second = page (Some (List.hd first).operation_id) in
      Alcotest.(check int) "bounded second page" 1 (List.length second);
      Alcotest.(check int)
        "account scoped end"
        0
        (List.length (page (Some (List.hd second).operation_id)))))
;;

let scoped_cleanup () =
  fixture (fun path ->
    let a = intent 2
    and b = intent ~graph:(uuid 8) 3
    and c = intent ~account:"other" 4
    and d = intent ~origin:"https://other.example" 5 in
    with_db path (fun db ->
      List.iter (fun i -> get (S.save db ~expected:None i)) [ a; b; c; d ];
      let captured = get (S.capture_graph db ~namespace:(String.make 64 'a') ~origin:a.origin ~account:a.account ~graph:a.graph) in
      get (S.delete_captured_graph db captured);
      get (S.delete_captured_graph db captured);
      Alcotest.(check bool)
        "selected graph removed"
        true
        (get (S.read db ~operation:a.operation_id) = None);
      List.iter
        (fun i ->
           Alcotest.(check bool)
             "other scope retained"
             true
             (get (S.read db ~operation:i.I.operation_id) = Some i))
        [ b; c; d ];
      get (S.delete_account db ~origin:b.origin ~account:b.account ~input_namespaces:Seq.empty));
    with_db path (fun db ->
      Alcotest.(check bool)
        "account cleanup survives restart"
        true
        (get (S.read db ~operation:b.operation_id) = None);
      List.iter
        (fun i ->
           Alcotest.(check bool)
             "other owner survives restart"
             true
             (get (S.read db ~operation:i.I.operation_id) = Some i))
        [ c; d ]))
;;

let generated_checkpoint_validation () =
  fixture (fun path ->
    with_db path (fun db ->
      let original = intent 2 in
      get (S.save db ~expected:None original);
      let payload = ref "" in
      Sqlite3.Rc.check
        (Sqlite3.exec db "SELECT payload FROM asset_upload_intents" ~cb:(fun row _ ->
           payload := Option.get row.(0)));
      let replace before after source =
        let n = String.length before in
        let rec find i =
          if i + n > String.length source
          then source
          else if String.sub source i n = before
          then
            String.sub source 0 i
            ^ after
            ^ String.sub source (i + n) (String.length source - i - n)
          else find (i + 1)
        in
        find 0
      in
      let write payload =
        let stmt = Sqlite3.prepare db "UPDATE asset_upload_intents SET payload=?" in
        Fun.protect
          ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
          (fun () ->
             Sqlite3.Rc.check (Sqlite3.bind_text stmt 1 payload);
             Sqlite3.Rc.check (Sqlite3.step stmt))
      in
      let reject label expected payload =
        write payload;
        match S.read db ~operation:original.operation_id with
        | Error message -> Alcotest.(check string) label expected message
        | Ok _ -> Alcotest.fail "invalid checkpoint was accepted"
      in
      reject "invalid JSON excludes sensitive input" "Upload checkpoint JSON is invalid"
        "SENSITIVE-fixture-body";
      reject "unsupported version" "Unsupported upload checkpoint format"
        (replace "\"format_version\":1" "\"format_version\":2" !payload);
      Alcotest.(check bool) "generated phase variant" true (String.contains !payload '[');
      reject
        "old checkpoint phase rejected"
        "Upload checkpoint shape is invalid"
        (replace "[\"Prepared\"]" "\"prepared\"" !payload);
      reject
        "invalid UUID rejected"
        (Logseq_db_types.Failure_diagnostic.create ~operation:"restoreUploads"
           ~reason:"invalidContent" ~source:"invalid UUID" ()
         |> Logseq_db_types.Failure_diagnostic.encode)
        (replace (U.to_string original.graph) "not-a-uuid" !payload);
      reject "negative asset size rejected" "Upload checkpoint intent is invalid" (replace "\"size\":4" "\"size\":-1" !payload);
      reject
        "revision invariant rejected"
        "Upload checkpoint phase is invalid"
        (replace "\"revision\":0" "\"revision\":-1" !payload);
      Alcotest.(check bool) "oversized encoded checkpoint rejected" true
        (Result.is_error (S.save db ~expected:None
           (intent ~origin:(String.make 8193 'x') 3)));
      write !payload;
      Alcotest.(check bool)
        "valid generated checkpoint recovers"
        true
        (get (S.read db ~operation:original.operation_id) = Some original)))
;;

let exact_retirement_preserves_new_and_changed_operations () =
  fixture (fun path ->
    let first = intent 2 and second = intent 3 and replacement = intent 8 in
    let captured = with_db path (fun db ->
      get (S.save db ~expected:None first); get (S.save db ~expected:None second);
      get (S.capture_graph db ~namespace:(String.make 64 'a') ~origin:first.origin ~account:first.account ~graph:first.graph)) in
    let captured = S.captured_graph_to_yojson captured |> S.captured_graph_of_yojson |> get in
    with_db path (fun db ->
      get (S.save db ~expected:None replacement);
      let changed = get (I.advance second Local_committed) in
      get (S.save db ~expected:(Some second.revision) changed);
      Alcotest.(check bool) "changed captured checkpoint defers cleanup" true
        (Result.is_error (S.delete_captured_graph db captured));
      Alcotest.(check bool) "failed cleanup retains every captured row" true
        (get (S.read db ~operation:first.operation_id) = Some first);
      Alcotest.(check bool) "new operation survives failed old cleanup" true
        (get (S.read db ~operation:replacement.operation_id) = Some replacement)))
;;

let exact_retirement_survives_restart_and_replacement () =
  fixture (fun path ->
    let old = intent 2 and fresh = intent 8 in
    let captured = with_db path (fun db ->
      get (S.save db ~expected:None old);
      get (S.capture_graph db ~namespace:(String.make 64 'a') ~origin:old.origin ~account:old.account ~graph:old.graph)) in
    with_db path (fun db ->
      get (S.save db ~expected:None fresh);
      get (S.delete_captured_graph db captured));
    with_db path (fun db ->
      get (S.delete_captured_graph db captured);
      Alcotest.(check bool) "old captured row absent" true (get (S.read db ~operation:old.operation_id) = None);
      Alcotest.(check bool) "new same-graph row retained after replay" true
        (get (S.read db ~operation:fresh.operation_id) = Some fresh)))
;;

let retirement_capture_decode_causes () =
  let check expected input = match S.captured_graph_of_yojson input with
    | Error message -> Alcotest.(check string) "finite retirement cause" expected message
    | Ok _ -> Alcotest.fail "invalid capture was accepted" in
  check "Retirement capture shape is invalid" (`String "SENSITIVE-fixture-body");
  check "Unsupported retirement capture format" (`Assoc ["version", `Int 99]);
  check "Retirement capture graph identity is invalid"
    (`Assoc ["version", `Int 1; "origin", `String "synthetic";
      "account", `String "synthetic"; "graph", `String "SENSITIVE-invalid-uuid"])
;;

(* The upload store is the real state owner. A reducer cannot establish
   additive SQLite migration, durable bytes, or a genuinely read-only reopen. *)
let input_schema_additive_and_readonly_reopen () =
  let module M=Logseq_db_storage.Mutation_effect_store in
  let namespace=String.make 64 'a' in
  fixture(fun path->
    let old=intent 820 in
    with_db path(fun db->
      get(S.save db ~expected:None old);
      get(S.initialize_database db);
      let stmt=Sqlite3.prepare db "SELECT count(*) FROM sqlite_master WHERE name IN ('overlay_intents_v1','overlay_intents_pending_v1')" in
      Fun.protect ~finally:(fun()->ignore(Sqlite3.finalize stmt))(fun()->
        Alcotest.(check bool) "schema inspect succeeds" true(Sqlite3.step stmt=Sqlite3.Rc.ROW);
        Alcotest.(check int) "input reservation table and recovery index exist" 2(Sqlite3.column_int stmt 0));
      let row=M.prepare db ~namespace ~mutation_id:(uuid 821) ~payload:"canonical complete source bytes" |> Result.get_ok in
      Alcotest.(check bool) "reservation is unknown before real Prepared" true(row.evidence=None);
      get(S.initialize_database db);
      Alcotest.(check bool) "migration preserves old upload checkpoint" true(S.read db ~operation:old.operation_id=Ok(Some old)));
    let db=Sqlite3.db_open ~mode:`READONLY path in
    Fun.protect ~finally:(fun()->ignore(Sqlite3.db_close db))(fun()->
      let page=M.pending db ~namespace ~after:None ~limit:1 |> Result.get_ok in
      Alcotest.(check bool) "unknown input survives genuinely readonly restart" true
        (match page.items with [row]->row.payload="canonical complete source bytes" && row.evidence=None && not row.acknowledged|_->false);
      Alcotest.(check bool) "unknown reservation cannot be acknowledged away" true
        (Result.is_error(M.acknowledge db ~namespace ~mutation_id:(uuid 821) ~evidence:"invented"))))
;;

let input_owner ?(namespace=String.make 64 'a') ?(account="user") () :S.Inputs.owner =
  {namespace;origin="https://sync.example";account;graph=uuid 1}
;;

let source_input ?(source_file="/isolated-picker/source.png") ?(namespace=String.make 64 'a') prepared =
  let source:Logseq_db_types.Asset_import.t={operation=prepared.I.operation_id;asset=prepared.asset;
    target=prepared.target;replace_reference=prepared.replace_reference;local_mutation=prepared.local_mutation;
    metadata_mutation=prepared.metadata_mutation;source_file;title=prepared.title;file_type=prepared.version.file_type} in
  Logseq_db_types.Asset_import.Pure_intent.create ~namespace source |> Result.get_ok
;;

(* Account retirement is owned by this SQLite store; a pure reducer cannot
   reproduce which durable input rows survive deleting an account. *)
let account_cleanup_retires_complete_inputs () =
  let module R = S.Inputs in
  fixture (fun path ->
    let a = intent 900 and b = intent ~graph:(uuid 8) 901
    and c = intent ~account:"other" 902
    and d = intent ~origin:"https://other.example" 903
    and pending = intent ~graph:(uuid 9) 904
    and foreign_pending = intent ~account:"other" ~graph:(uuid 10) 905 in
    let owner namespace (prepared : I.t) : R.owner =
      {namespace=String.make 64 namespace;origin=prepared.origin;
       account=prepared.account;graph=prepared.graph} in
    let entries = List.map (fun (namespace, prepared) ->
      let owner = owner namespace prepared in
      owner, source_input ~namespace:owner.namespace prepared, prepared)
      ['a',a; 'b',b; 'c',c; 'd',d; 'e',pending; 'f',foreign_pending] in
    with_db path (fun db ->
      List.iter (fun (owner, input, prepared) ->
        ignore (get (R.reserve db ~owner ~input));
        if prepared.I.operation_id <> pending.operation_id
           && prepared.operation_id <> foreign_pending.operation_id then
          ignore (get (R.commit_prepared db ~owner ~input prepared))) entries;
      let owner, input, _ = List.nth entries 1 in
      let proof = get (R.read db ~owner ~operation:b.operation_id)
        |> Option.get |> fun row -> Option.get row.evidence in
      get (R.acknowledge db ~owner ~input ~evidence:proof);
      get (S.delete_account db ~origin:a.origin ~account:a.account
        ~input_namespaces:(List.to_seq [String.make 64 'a';String.make 64 'b';String.make 64 'e']));
      List.iter (fun (owner, _, prepared) ->
        let removed = prepared.I.origin=a.origin && prepared.account=a.account in
        Alcotest.(check bool) "account input retirement is exact" removed
          (get (R.read db ~owner ~operation:prepared.operation_id)=None);
        Alcotest.(check bool) "checkpoint follows the same account retirement" removed
          (get (S.read db ~operation:prepared.operation_id)=None))
        (List.filter (fun (_,_,prepared)->prepared.I.operation_id<>pending.operation_id
          && prepared.operation_id<>foreign_pending.operation_id) entries);
      let owner,_,_ = List.nth entries 4 in
      Alcotest.(check bool) "unprepared source retires with its account" true
        (get (R.read db ~owner ~operation:pending.operation_id)=None);
      get (S.delete_account db ~origin:a.origin ~account:a.account
        ~input_namespaces:(List.to_seq [String.make 64 'a';String.make 64 'b';String.make 64 'e'])));
    with_db path (fun db ->
      List.iter (fun (owner,_,prepared) ->
        let removed = prepared.I.origin=a.origin && prepared.account=a.account in
        Alcotest.(check bool) "account input cleanup survives restart" removed
          (get (R.read db ~owner ~operation:prepared.operation_id)=None)) entries))
;;

let account_cleanup_rolls_back_on_checkpoint_failure () =
  let module R = S.Inputs in
  fixture (fun path -> with_db path (fun db ->
    let prepared = intent 906 in
    let owner = input_owner () in
    let input = source_input prepared in
    ignore (get (R.reserve db ~owner ~input));
    ignore (get (R.commit_prepared db ~owner ~input prepared));
    Alcotest.(check bool) "invalid namespace cannot partially retire inputs" true
      (Result.is_error (S.delete_account db ~origin:prepared.origin ~account:prepared.account
        ~input_namespaces:(List.to_seq [owner.namespace; "invalid"])));
    Alcotest.(check bool) "namespace validation rolls back earlier input deletes" true
      (Option.is_some (get (R.read db ~owner ~operation:prepared.operation_id)));
    Sqlite3.Rc.check (Sqlite3.exec db
      "CREATE TRIGGER deny_checkpoint_delete BEFORE DELETE ON asset_upload_intents BEGIN SELECT RAISE(FAIL,'synthetic delete failure'); END");
    Alcotest.(check bool) "account cleanup reports SQLite failure" true
      (Result.is_error (S.delete_account db ~origin:prepared.origin ~account:prepared.account
        ~input_namespaces:(Seq.return owner.namespace)));
    Alcotest.(check bool) "failed account cleanup preserves checkpoint" true
      (S.read db ~operation:prepared.operation_id=Ok (Some prepared));
    Alcotest.(check bool) "failed account cleanup preserves input and proof" true
      (Option.is_some (get (R.read db ~owner ~operation:prepared.operation_id)))))
;;

let input_reservation_restart_conflict_and_unknown_ack () =
  let module R=S.Inputs in
  let module P=Logseq_db_types.Asset_import.Pure_intent in
  fixture(fun path->
    let prepared=intent 850 in let input=source_input prepared in
    let sequence=with_db path(fun db->
      let saved=get(R.reserve db ~owner:(input_owner()) ~input) in
      Alcotest.(check bool) "reservation never invents Prepared" true(saved.prepared=None && saved.evidence=None);
      let same=get(R.reserve db ~owner:(input_owner()) ~input) in
      Alcotest.(check int64) "same full input idempotent" saved.sequence same.sequence;
      Alcotest.(check bool) "same operation different source is a conflict" true
        (Result.is_error(R.reserve db ~owner:(input_owner()) ~input:(source_input ~source_file:"/isolated-picker/another.png" prepared)));
      Alcotest.(check bool) "unknown input cannot ACK" true
        (Result.is_error(R.acknowledge db ~owner:(input_owner()) ~input ~evidence:"invented")); saved.sequence) in
    let db=Sqlite3.db_open ~mode:`READONLY path in
    Fun.protect ~finally:(fun()->ignore(Sqlite3.db_close db))(fun()->
      let saved=get(R.read db ~owner:(input_owner ~namespace:(P.namespace input)()) ~operation:(P.operation input)) |> Option.get in
      Alcotest.(check int64) "restart retains original sequence" sequence saved.sequence;
      Alcotest.(check string) "restart retains every canonical source byte" (P.encode input)(P.encode saved.input);
      Alcotest.(check bool) "readonly recovery stays unknown without running staging" true(saved.prepared=None);
      let page=get(R.pending db ~owner:(input_owner ~namespace:(P.namespace input)()) ~after:None ~maximum_items:1 ~maximum_bytes:32768) in
      Alcotest.(check bool) "one complete readonly pending row" true(List.length page.items=1 && page.next=None)))
;;

let input_prepared_atomic_commit_and_ack () =
  let module R=S.Inputs in
  fixture(fun path->with_db path(fun db->
    let prepared=intent 860 in let input=source_input prepared in
    ignore(get(R.reserve db ~owner:(input_owner()) ~input));
    Alcotest.(check bool) "foreign owner cannot prove adoption of this namespace input" true
      (Result.is_error(R.commit_prepared db ~owner:(input_owner()) ~input (intent ~account:"foreign-user" 860)));
    Sqlite3.Rc.check(Sqlite3.exec db "CREATE TRIGGER deny_input_evidence BEFORE UPDATE OF evidence ON overlay_intents_v1 BEGIN SELECT RAISE(FAIL,'synthetic evidence failure'); END");
    Alcotest.(check bool) "checkpoint and evidence failure is reported" true
      (Result.is_error(R.commit_prepared db ~owner:(input_owner()) ~input prepared));
    Alcotest.(check bool) "no checkpoint survives failed proof transaction" true(S.read db ~operation:prepared.operation_id=Ok None);
    let row=get(R.read db ~owner:(input_owner()) ~operation:prepared.operation_id) |> Option.get in
    Alcotest.(check bool) "reservation still unknown after rollback" true(row.prepared=None && row.evidence=None);
    Sqlite3.Rc.check(Sqlite3.exec db "DROP TRIGGER deny_input_evidence");
    let row=get(R.commit_prepared db ~owner:(input_owner()) ~input prepared) in
    let proof=Option.get row.evidence in
    Alcotest.(check bool) "actual original Prepared evidence returned" true(row.prepared=Some prepared);
    let advanced=get(I.advance prepared Local_committed) in
    get(S.save db ~expected:(Some 0) advanced);
    let same=get(R.commit_prepared db ~owner:(input_owner()) ~input prepared) in
    Alcotest.(check bool) "duplicate original proof does not downgrade upload phase" true
      (same.evidence=Some proof && S.read db ~operation:prepared.operation_id=Ok(Some advanced));
    Alcotest.(check bool) "forged proof cannot ACK" true(Result.is_error(R.acknowledge db ~owner:(input_owner()) ~input ~evidence:(proof^" ")));
    get(R.acknowledge db ~owner:(input_owner()) ~input ~evidence:proof);
    get(R.acknowledge db ~owner:(input_owner()) ~input ~evidence:proof);
    let row=get(R.read db ~owner:(input_owner()) ~operation:prepared.operation_id) |> Option.get in
    Alcotest.(check bool) "ACK retains immutable source and original proof" true(row.acknowledged && row.evidence=Some proof && row.prepared=Some prepared);
    let page=get(R.pending db ~owner:(input_owner()) ~after:None ~maximum_items:1 ~maximum_bytes:32768) in
    Alcotest.(check bool) "ACK hides row only from pending enumeration" true(page.items=[] && page.next=None)))
;;

let input_recovery_bounds_and_legacy_conflict () =
  let module R=S.Inputs in
  fixture(fun path->with_db path(fun db->
    let namespace=String.make 64 'a' in
    let prepared=intent 870 in
    ignore(get(R.reserve db ~owner:(input_owner()) ~input:(source_input prepared)));
    ignore(get(R.reserve db ~owner:(input_owner()) ~input:(source_input(intent 871))));
    ignore(get(R.reserve db ~owner:(input_owner ~namespace:(String.make 64 'b')()) ~input:(source_input ~namespace:(String.make 64 'b')(intent 872))));
    let page=get(R.pending db ~owner:(input_owner ~namespace ()) ~after:None ~maximum_items:1 ~maximum_bytes:32768) in
    Alcotest.(check bool) "partial page has exact continuation" true(List.length page.items=1 && page.next<>None);
    let bounded=get(R.pending db ~owner:(input_owner ~namespace ()) ~after:None ~maximum_items:2 ~maximum_bytes:(R.encoded_bytes(List.hd page.items)+Logseq_db_types.Asset_import.Recovery.maximum_page_overhead+1)) in
    Alcotest.(check bool) "encoded byte boundary preserves explicit continuation" true
      (List.length bounded.items=1 && bounded.next=page.next);
    let next=get(R.pending db ~owner:(input_owner ~namespace ()) ~after:page.next ~maximum_items:1 ~maximum_bytes:32768) in
    Alcotest.(check bool) "second page reaches scoped end" true(List.length next.items=1 && next.next=None);
    Alcotest.(check bool) "unfit byte budget cannot claim empty complete" true
      (Result.is_error(R.pending db ~owner:(input_owner ~namespace ()) ~after:None ~maximum_items:2 ~maximum_bytes:32));
    let legacy=intent 873 in get(S.save db ~expected:None legacy);
    Alcotest.(check bool) "old checkpoint cannot invent complete original source bytes" true
      (Result.is_error(R.reserve db ~owner:(input_owner()) ~input:(source_input legacy)));
    let module M=Logseq_db_storage.Mutation_effect_store in
    ignore(M.prepare db ~namespace ~mutation_id:(uuid 874) ~payload:"corrupt full input" |> Result.get_ok);
    Alcotest.(check bool) "corrupt source row is an error, not empty recovery" true
      (Result.is_error(R.pending db ~owner:(input_owner ~namespace ()) ~after:next.next ~maximum_items:8 ~maximum_bytes:32768))))
;;

let input_reads_do_not_initialize_schema () =
  let module R=S.Inputs in
  fixture(fun path->
    let db=Sqlite3.db_open path in
    Fun.protect ~finally:(fun()->ignore(Sqlite3.db_close db))(fun()->
      let namespace=String.make 64 'a' in
      Alcotest.(check bool) "missing input store is known absence" true(R.read db ~owner:(input_owner ~namespace ()) ~operation:(uuid 880)=Ok None);
      let page=get(R.pending db ~owner:(input_owner ~namespace ()) ~after:None ~maximum_items:1 ~maximum_bytes:32768) in
      Alcotest.(check bool) "fresh readonly page is complete empty" true(page.items=[] && page.next=None);
      let stmt=Sqlite3.prepare db "SELECT count(*) FROM sqlite_master WHERE name='overlay_intents_v1'" in
      Fun.protect ~finally:(fun()->ignore(Sqlite3.finalize stmt))(fun()->
        Alcotest.(check bool) "schema query succeeds" true(Sqlite3.step stmt=Sqlite3.Rc.ROW);
        Alcotest.(check int) "read did not run DDL" 0(Sqlite3.column_int stmt 0)));
    let db=Sqlite3.db_open path in
    Fun.protect ~finally:(fun()->ignore(Sqlite3.db_close db))(fun()->
      Sqlite3.Rc.check(Sqlite3.exec db "CREATE TABLE overlay_intents_v1(unrelated INTEGER)");
      Alcotest.(check bool) "malformed existing input store is not absence" true
        (Result.is_error(R.read db ~owner:(input_owner()) ~operation:(uuid 880)))))
;;

let input_retirement_exact_snapshot_and_changed_ack () =
  let module R=S.Inputs in
  let namespace=String.make 64 'a' in
  fixture(fun path->with_db path(fun db->
    let prepared=intent 890 in let input=source_input prepared in
    ignore(get(R.reserve db ~owner:(input_owner()) ~input));
    let row=get(R.commit_prepared db ~owner:(input_owner()) ~input prepared) in
    let capture=get(S.capture_graph db ~namespace ~origin:prepared.origin ~account:prepared.account ~graph:prepared.graph) in
    let capture=get(S.captured_graph_of_yojson(S.captured_graph_to_yojson capture)) in
    Alcotest.(check bool) "source capture cannot be retargeted to a foreign namespace" false
      (S.captured_graph_matches capture ~namespace:(String.make 64 'b') ~origin:prepared.origin ~account:prepared.account ~graph:prepared.graph);
    get(R.acknowledge db ~owner:(input_owner()) ~input ~evidence:(Option.get row.evidence));
    Alcotest.(check bool) "changed ACK protects all original rows from stale deletion" true(Result.is_error(S.delete_captured_graph db capture));
    Alcotest.(check bool) "stale deletion rolls back checkpoint removal" true(S.read db ~operation:prepared.operation_id=Ok(Some prepared));
    let capture=get(S.capture_graph db ~namespace ~origin:prepared.origin ~account:prepared.account ~graph:prepared.graph) in
    let later=source_input(intent 891) in ignore(get(R.reserve db ~owner:(input_owner()) ~input:later));
    let foreign=source_input ~namespace:(String.make 64 'b')(intent ~account:"other" 892) in ignore(get(R.reserve db ~owner:(input_owner ~namespace:(String.make 64 'b') ~account:"other"()) ~input:foreign));
    get(S.delete_captured_graph db capture);get(S.delete_captured_graph db capture);
    Alcotest.(check bool) "only exact captured input retired" true(R.read db ~owner:(input_owner ~namespace ()) ~operation:prepared.operation_id=Ok None);
    Alcotest.(check bool) "new input survives old exact deletion" true(Option.is_some(get(R.read db ~owner:(input_owner ~namespace ()) ~operation:(uuid 891))));
    Alcotest.(check bool) "foreign namespace survives exact deletion" true
      (Option.is_some(get(R.read db ~owner:(input_owner ~namespace:(String.make 64 'b')()) ~operation:(uuid 892))))))
;;

let input_persisted_foreign_evidence_is_not_adoption () =
  let module R=S.Inputs in
  let foreign=intent ~account:"foreign-user" 885 in
  let foreign_input=source_input ~namespace:(String.make 64 'b') foreign in
  let foreign_proof=fixture(fun path->with_db path(fun db->
    let owner=input_owner ~namespace:(String.make 64 'b') ~account:"foreign-user"() in
    ignore(get(R.reserve db ~owner ~input:foreign_input));
    let row=get(R.commit_prepared db ~owner ~input:foreign_input foreign) in Option.get row.evidence)) in
  fixture(fun path->with_db path(fun db->
    let prepared=intent 885 in let input=source_input prepared in let owner=input_owner() in
    ignore(get(R.reserve db ~owner ~input));
    let stmt=Sqlite3.prepare db "UPDATE overlay_intents_v1 SET evidence=? WHERE namespace=?" in
    Fun.protect ~finally:(fun()->ignore(Sqlite3.finalize stmt))(fun()->
      Sqlite3.Rc.check(Sqlite3.bind_values stmt[TEXT foreign_proof;TEXT owner.namespace]);
      Sqlite3.Rc.check(Sqlite3.step stmt));
    Alcotest.(check bool) "foreign persisted proof cannot be read as this owner adoption" true
      (Result.is_error(R.read db ~owner ~operation:prepared.operation_id));
    Alcotest.(check bool) "foreign persisted proof cannot enter pending recovery" true
      (Result.is_error(R.pending db ~owner ~after:None ~maximum_items:1 ~maximum_bytes:32768));
    Alcotest.(check bool) "foreign persisted proof cannot ACK unknown source" true
      (Result.is_error(R.acknowledge db ~owner ~input ~evidence:foreign_proof));
    Alcotest.(check bool) "foreign persisted proof cannot be frozen for destructive retirement" true
      (Result.is_error(S.capture_graph db ~namespace:owner.namespace ~origin:owner.origin ~account:owner.account ~graph:owner.graph))))
;;

let legacy_capture_never_captures_new_input_rows () =
  let module R=S.Inputs in
  fixture(fun path->with_db path(fun db->
    let prepared=intent 886 in get(S.save db ~expected:None prepared);
    let owner=input_owner() in
    let current=get(S.capture_graph db ~namespace:owner.namespace ~origin:owner.origin ~account:owner.account ~graph:owner.graph) in
    let old_json=match S.captured_graph_to_yojson current with `Assoc fields->
      `Assoc(("version",`Int 1)::List.filter(fun(key,_)->not(List.mem key["version";"inputs";"namespace"]))fields)
      |_->assert false in
    let old=get(S.captured_graph_of_yojson old_json) in
    let fresh=source_input(intent 887) in ignore(get(R.reserve db ~owner ~input:fresh));
    get(S.delete_captured_graph db old);
    Alcotest.(check bool) "legacy manifest retires only original checkpoint" true(S.read db ~operation:prepared.operation_id=Ok None);
    Alcotest.(check bool) "legacy manifest cannot erase later source input" true
      (Option.is_some(get(R.read db ~owner ~operation:(uuid 887))))))
;;

(* The pure checkpoint codec owns generated JSON field validation, not a reducer. *)
let checkpoint_field_error_survives () =
  let module D = Logseq_db_types.Failure_diagnostic in
  let payload = I.Pure_codec.encode (intent 991) in
  let before = "\"title\":\"Fixture image\"" in
  let rec replace offset =
    if offset + String.length before > String.length payload then Alcotest.fail "title fixture missing"
    else if String.sub payload offset (String.length before) = before then
      String.sub payload 0 offset ^ "\"title\":[\"SECRET-invalid-title\"]"
      ^ String.sub payload (offset + String.length before)
          (String.length payload - offset - String.length before)
    else replace (offset + 1) in
  match I.Pure_codec.decode (replace 0) with
  | Ok _ -> Alcotest.fail "invalid title was accepted"
  | Error source ->
    let diagnostic = D.of_source ~operation:"restoreUploads" ~reason:"invalidContent" source in
    Alcotest.(check string) "concrete failing field" "upload-checkpoint-field-title" (D.source_class diagnostic);
    Alcotest.(check bool) "raw field value excluded" false (String.contains (D.encode diagnostic) 'S')
;;

let () =
  Alcotest.run
    "asset upload storage"
    [ ( "SQLite"
      , List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          [ "checkpoint field cause", checkpoint_field_error_survives
          ; "account cleanup rollback", account_cleanup_rolls_back_on_checkpoint_failure
          ; "account cleanup retires complete inputs", account_cleanup_retires_complete_inputs
          ; "foreign persisted input evidence rejected", input_persisted_foreign_evidence_is_not_adoption
          ; "legacy manifest preserves new source records", legacy_capture_never_captures_new_input_rows
          ; "input exact retirement and changed ACK", input_retirement_exact_snapshot_and_changed_ack
          ; "input read never initializes schema", input_reads_do_not_initialize_schema
          ; "input reservation restart conflict and unknown ACK", input_reservation_restart_conflict_and_unknown_ack
          ; "input Prepared atomic transaction and ACK", input_prepared_atomic_commit_and_ack
          ; "input recovery bounds and legacy conflict", input_recovery_bounds_and_legacy_conflict
          ; "additive input schema and readonly reopen", input_schema_additive_and_readonly_reopen
          ; "retirement capture decode causes", retirement_capture_decode_causes
          ; "retirement preserves changed operations", exact_retirement_preserves_new_and_changed_operations
          ; "retirement restart and replacement isolation", exact_retirement_survives_restart_and_replacement
          ; "generated checkpoint validation", generated_checkpoint_validation
          ; "scoped cleanup", scoped_cleanup
          ; "restart", restart
          ; "atomic revision", atomic_revision
          ; "bounded recovery", paging
          ] )
    ]
;;
