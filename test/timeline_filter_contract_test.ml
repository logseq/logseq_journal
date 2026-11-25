module Filter = Timeline_filter

let uuid suffix =
  match Filter.Uuid.of_string ("00000000-0000-4000-8000-00000000000" ^ suffix) with
  | Ok uuid -> uuid
  | Error message -> failwith message
;;

let get = function Ok value -> value | Error _ -> failwith "expected valid filter"
let draft state = Option.get (Filter.sheet state)

let () =
  let tag = uuid "1" and status = uuid "2" in
  let saved = Filter.criteria ~tags:[ tag; tag ] ~statuses:[ status ] ~time:Filter.any_time in
  assert (Filter.tags saved = [ tag ]);
  assert (Filter.active_count saved = 2);
  let restored = Filter.restore saved in
  assert (Filter.sheet restored = None);
  let reset = Filter.edit (Filter.open_sheet restored) Reset in
  assert (Filter.draft_tags (draft reset) = []);
  assert (Filter.active_count (Filter.applied reset) = 2);
  assert (Filter.applied (Filter.cancel reset) = saved);
  assert (Filter.applied (get (Filter.apply reset)) = Filter.all);
  let draft_state = Filter.open_sheet restored in
  let invalid = Filter.edit draft_state (Set_time (Custom { count_text = "0"; unit_ = Weeks })) in
  assert (Filter.apply invalid = Error Invalid_count);
  assert (Filter.custom ~count:max_int ~unit_:Weeks = Error Invalid_count);
  let custom = Filter.edit invalid (Set_time (Custom { count_text = "2"; unit_ = Weeks })) in
  let applied = get (Filter.apply (Filter.open_sheet custom)) in
  assert (Filter.sheet applied = None);
  assert (Filter.active_count (Filter.applied applied) = 3);
  assert (Filter.time_choice (Filter.time (Filter.applied applied)) = `Custom (2, Weeks));
  let toggled = Filter.edit (Filter.open_sheet applied) (Toggle_status status) in
  assert (Filter.draft_statuses (draft toggled) = []);
  assert (Filter.applied (Filter.cancel toggled) = Filter.applied applied)
;;
