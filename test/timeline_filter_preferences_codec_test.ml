module Filter = Journal_timeline_filter.Timeline_filter
module Preferences = Timeline_filter_preferences

let () =
  let tag = Result.get_ok (Filter.Uuid.of_string "00000000-0000-4000-8000-000000000001") in
  let status = Result.get_ok (Filter.Uuid.of_string "00000000-0000-4000-8000-000000000002") in
  let criteria time = Filter.criteria ~tags:[tag] ~statuses:[status] ~time in
  let custom = Result.get_ok (Filter.custom ~count:14 ~unit_:Days) in
  let preset = Filter.preset Filter.Past_14_days in
  let months = Filter.preset Filter.Past_3_months in
  let definitions = List.map (fun (name, time) -> name, criteria time)
      ["Custom", custom; "Fortnight", preset; "Quarter", months] in
  let legacy = {|{ "version":2,"definitions":[{"name":"Old","tags":["00000000-0000-4000-8000-000000000001"],"statuses":["00000000-0000-4000-8000-000000000002"],"time":"any"}],"selected":"Old" }|} in
  let migrated = Result.get_ok (Preferences.decode legacy) in
  assert (Filter.selected_name migrated = Some "Old");
  assert (Filter.definitions migrated = ["Old", criteria months]);
  let legacy_key = "legacy-graph" in
  let persist request =
    match String.split_on_char '\n' request with
    | [_; key; expected; replacement] ->
      assert (key = legacy_key);
      let escaped = String.concat "\\\"" (String.split_on_char '"' legacy) in
      assert (expected = "\"" ^ escaped ^ "\"");
      assert (Result.get_ok (Preferences.decode replacement) = migrated);
      true
    | _ -> assert false
  in
  assert (Option.is_some (Preferences.commit ~persist [legacy_key, `String legacy] ~key:legacy_key migrated));
  let record = Result.get_ok (Filter.preferences ~definitions ~selected_name:(Some "Quarter")) in
  let restored = Result.get_ok (Preferences.decode (Preferences.encode record)) in
  assert (Filter.definitions restored = definitions);
  assert (Filter.selected_name restored = Some "Quarter");
  let key = "10000000-0000-4000-8000-000000000002" in
  let other_entries = ["another graph", `String (Preferences.encode record)] in
  let entries = (key, `String (Preferences.encode record)) :: other_entries in
  let commit ~accepted = Preferences.commit ~persist:(fun _ -> accepted) entries ~key Filter.empty_preferences in
  assert (commit ~accepted:false = None);
  assert (commit ~accepted:true = Some other_entries);
  let config = "\000\255" in
  let frame snapshot = "JTF1" ^ snapshot ^ "\n" ^ config in
  let graph = "10000000-0000-4000-8000-000000000001" in
  let snapshot = Printf.sprintf {|{"%s":"{\"version\":1}"}|} graph in
  let entries, decoded_config = Preferences.unwrap_startup (frame snapshot) in
  assert (decoded_config = config);
  assert (List.assoc_opt graph entries = Some (`String {|{"version":1}|}));
  let entries, decoded_config = Preferences.unwrap_startup
      (frame (String.make (25 * 1024 * 1024) ' ')) in
  assert (decoded_config = config && List.mem_assoc "overflow" entries);
  let never_persist _ = failwith "An unreadable startup store must not authorize writes" in
  assert (Preferences.commit ~persist:never_persist entries ~key record = None);
  let entries, decoded_config = Preferences.unwrap_startup (frame "[]") in
  assert (decoded_config = config && List.mem_assoc "overflow" entries);
  assert (Preferences.commit ~persist:never_persist entries ~key record = None);
  assert (Filter.applied (Filter.restore restored) = criteria months);
  List.iter (fun (today, first) ->
    assert (Journal_filter_date.resolve_days (criteria months) ~today = Some (first, today)))
    [20240531, 20240229; 20230531, 20230228; 20250115, 20241015; 20241231, 20240930];
  assert (Preferences.decode {|{"version":1,"tags":[],"statuses":[],"time":"past-7-days"}|}
          = Ok Filter.empty_preferences);
  let persisted = {|{"version":2,"definitions":[{"name":"First week","tags":[],"statuses":[],"time":[1,"weeks"]}],"selected":"First week"}|} in
  let applied = Filter.applied (Filter.restore (Result.get_ok (Preferences.decode persisted))) in
  assert (Journal_filter_date.resolve_days applied ~today:10107 = Some (10101, 10107));
  (match Journal_filter_date.resolve_days applied ~today:10106 with
   | exception Invalid_argument _ -> ()
   | _ -> assert false);
  List.iter (fun value -> assert (Result.is_error (Preferences.decode value)))
    [ "broken"; String.make (64 * 1024 + 1) ' '
    ; {|{"version":2.0,"definitions":[],"selected":null}|}
    ; {|{"version":1e0}|}
    ; {|{"version":2,"definitions":[{"name":"Float","tags":[],"statuses":[],"time":[7.0,"days"]}],"selected":null}|}
    ; {|{"version":2,"definitions":[{"name":"Float","tags":[],"statuses":[],"time":[7e0,"weeks"]}],"selected":"Float"}|}
    ; {|{"version":2,"definitions":[],"selected":"unknown"}|}
    ; {|{"version":2,"definitions":[{"name":"X","tags":["not-a-uuid"],"statuses":[],"time":"any"}],"selected":null}|}
    ; {|{"version":2,"definitions":[{"name":"X","tags":[],"statuses":[],"time":[0,"weeks"]}],"selected":null}|} ]
;;
