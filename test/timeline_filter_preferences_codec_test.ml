open Filter_modules
module Filter = Timeline_filter
module Preferences = Timeline_filter_preferences

let () =
  let tag = Result.get_ok (Filter.Uuid.of_string "00000000-0000-4000-8000-000000000001") in
  let status = Result.get_ok (Filter.Uuid.of_string "00000000-0000-4000-8000-000000000002") in
  let custom = Result.get_ok (Filter.custom ~count:7 ~unit_:Days) in
  let preset = Filter.preset Filter.Past_7_days in
  let criteria time = Filter.criteria ~tags:[tag] ~statuses:[status] ~time in
  List.iter (fun time ->
    let value = criteria time in
    let restored = Preferences.decode (Preferences.encode value) |> Option.get |> Filter.restore in
    assert (Filter.applied restored = value);
    assert (Filter.sheet restored = None)) [custom; preset; Filter.any_time];
  assert (Preferences.encode (criteria custom) <> Preferences.encode (criteria preset));
  List.iter (fun value -> assert (Preferences.decode value = None))
    [ "broken"; {|{"version":2,"tags":[],"statuses":[],"time":"any"}|}
    ; {|{"version":1,"tags":["bad"],"statuses":[],"time":"any"}|}
    ; {|{"version":1,"tags":[],"statuses":[],"time":[0,"weeks"]}|} ];
  assert (Preferences.unwrap_startup "LDB1\000\255" = ([], "LDB1\000\255"));
  assert (Preferences.unwrap_startup "JTF1{\"graph\":\"criteria\"}\nLDB1\000\255"
          = (["graph", `String "criteria"], "LDB1\000\255"));
  assert (Preferences.unwrap_startup "JTF1invalid-json\nLDB1" = ([], "LDB1"))
;;
