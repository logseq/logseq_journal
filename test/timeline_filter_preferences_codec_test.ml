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
      ["Custom", custom; "Fortnight", preset; "Quarter", months; "All time", Filter.any_time] in
  let record = Result.get_ok (Filter.preferences ~definitions ~selected_name:(Some "Quarter")) in
  let restored = Result.get_ok (Preferences.decode (Preferences.encode record)) in
  assert (Filter.definitions restored = definitions);
  assert (Filter.selected_name restored = Some "Quarter");
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
  assert (Filter.applied (Filter.restore restored) = criteria months);
  List.iter (fun (today, first) ->
    assert (Journal_filter_date.resolve_days (criteria months) ~today = Some (first, today)))
    [20240531, 20240229; 20230531, 20230228; 20250115, 20241015; 20241231, 20240930];
  assert (Preferences.decode {|{"version":1,"tags":[],"statuses":[],"time":"past-7-days"}|}
          = Ok Filter.empty_preferences);
  List.iter (fun value -> assert (Result.is_error (Preferences.decode value)))
    [ "broken"; String.make (64 * 1024 + 1) ' '
    ; {|{"version":2,"definitions":[],"selected":"unknown"}|}
    ; {|{"version":2,"definitions":[{"name":"X","tags":["not-a-uuid"],"statuses":[],"time":"any"}],"selected":null}|}
    ; {|{"version":2,"definitions":[{"name":"X","tags":[],"statuses":[],"time":[0,"weeks"]}],"selected":null}|} ]
;;
