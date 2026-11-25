module Filter = Journal_timeline_filter.Timeline_filter

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
  let prefs = get (Filter.preferences ~definitions:["Work", saved] ~selected_name:(Some "Work")) in
  let restored = Filter.restore prefs in
  let submit state command = (get (Filter.submit state command)).next in
  assert (Filter.sheet restored = None);
  let reset = Filter.edit (Filter.open_sheet restored) Reset in
  assert (Filter.draft_tags (draft reset) = []);
  assert (Filter.active_count (Filter.applied reset) = 2);
  assert (Filter.applied (Filter.cancel reset) = saved);
  assert (Filter.applied (submit reset Apply) = Filter.all);
  let draft_state = Filter.open_sheet restored in
  let invalid = Filter.edit draft_state (Set_time (Custom { count_text = "0"; unit_ = Weeks })) in
  assert (Filter.submit invalid Apply = Error (Invalid_time Invalid_count));
  assert (Filter.custom ~count:max_int ~unit_:Weeks = Error Invalid_count);
  let custom = Filter.edit invalid (Set_time (Custom { count_text = "2"; unit_ = Weeks })) in
  let applied = submit (Filter.open_sheet custom) Apply in
  assert (Filter.sheet applied = None);
  assert (Filter.active_count (Filter.applied applied) = 3);
  assert (Filter.time_choice (Filter.time (Filter.applied applied)) = `Custom (2, Weeks));
  let toggled = Filter.edit (Filter.open_sheet applied) (Toggle_status status) in
  assert (Filter.draft_statuses (draft toggled) = []);
  assert (Filter.applied (Filter.cancel toggled) = Filter.applied applied);
  assert (Filter.entry (Filter.restore Filter.empty_preferences) = Configure_directly);
  assert (Filter.entry restored = Native_menu { names = ["Work"]; active_name = Some "Work" });
  assert (Filter.submit draft_state (Save_as " ") = Error (Invalid_preferences Empty_name));
  assert (Filter.submit draft_state (Save_as " Work ") = Error (Invalid_preferences Duplicate_name));
  let saved = get (Filter.submit custom (Save_as " Custom ")) in
  let prefs = Option.get saved.replacement in
  assert (Filter.selected_name prefs = Some "Custom");
  assert (Filter.applied (Filter.restore prefs) = Filter.applied saved.next);
  let applied = get (Filter.submit (Filter.open_sheet saved.next) Apply) in
  assert (Filter.selected_name (Option.get applied.replacement) = None);
  assert (Filter.definitions (Option.get applied.replacement) = Filter.definitions prefs);
  let full = get (Filter.preferences ~definitions:(List.init 5 (fun index -> string_of_int index, Filter.all)) ~selected_name:None) in
  let draft = Filter.open_sheet (Filter.restore full) in
  assert (Filter.submit draft (Save_as "sixth") = Error (Invalid_preferences Too_many_filters));
  assert ((get (Filter.submit draft Apply)).replacement = None);
  let delete state name = get (Filter.submit state (Delete name)) in
  let active = Filter.open_sheet saved.next in
  assert (Filter.submit saved.next (Delete "Custom") = Error No_open_sheet);
  assert (Filter.submit active (Delete " Custom ") = Error Unknown_name);
  let deleted = delete active "Custom" in
  let persisted = Option.get deleted.replacement in
  assert (List.map fst (Filter.definitions persisted) = ["Work"]);
  assert (Filter.selected_name persisted = None);
  assert (Filter.applied (Filter.restore persisted) = Filter.all);
  assert (Filter.applied deleted.next = Filter.all);
  assert (Filter.applied (submit deleted.next Apply) = Filter.all);
  let edited = Filter.edit active (Set_time (Custom { count_text = "0"; unit_ = Weeks })) in
  assert (Filter.sheet (delete edited "Custom").next = Filter.sheet edited);
  let inactive = delete active "Work" in
  assert (Filter.sheet inactive.next = Filter.sheet active);
  assert (Filter.applied inactive.next = Filter.applied active);
  let persisted = Option.get inactive.replacement in
  assert (Filter.selected_name persisted = Some "Custom");
  assert (Filter.applied (Filter.restore persisted) = Filter.applied active);
  let anonymous = Filter.open_sheet (submit active Apply) in
  let deleted = delete anonymous "Work" in
  assert (Filter.applied deleted.next = Filter.applied anonymous);
  assert (Filter.sheet deleted.next = Filter.sheet anonymous);
  assert (Filter.selected_name (Option.get deleted.replacement) = None);
  let freed = delete draft "2" in
  let refilled = get (Filter.submit freed.next (Save_as "sixth")) in
  assert (List.map fst (Filter.definitions (Option.get refilled.replacement)) = ["0"; "1"; "3"; "4"; "sixth"]);
  List.iter (fun (toggle, selected) ->
    let ids = List.init 101 (fun index ->
      get (Filter.Uuid.of_string (Printf.sprintf "00000000-0000-4000-8000-%012d" index))) in
    let over = List.fold_left (fun state id -> Filter.edit state (toggle id)) draft ids in
    assert (Filter.submit over Apply = Error (Invalid_preferences Too_many_selections));
    assert (Filter.submit over (Save_as "Another") = Error (Invalid_preferences Too_many_selections));
    let reduced = Filter.edit over (toggle (List.hd ids)) in
    assert (List.length (selected (Filter.applied (submit reduced Apply))) = 100))
    [(fun id -> Filter.Toggle_tag id), Filter.tags; (fun id -> Filter.Toggle_status id), Filter.statuses]
;;
