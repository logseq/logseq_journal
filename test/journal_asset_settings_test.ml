let () =
  let module S = Journal_asset_settings in
  let days payload =
    match S.decode payload with
    | Some (Days settings) ->
      Journal_asset_policy.recent_interval settings ~today:20260919
    | _ -> failwith "valid preference rejected"
  in
  assert (days "days:0" = None);
  assert (days "days:7" = Some (20260913, 20260919));
  assert (S.decode "dismissed" = Some Dismissed);
  assert (S.decode "retry:bad" = None);
  assert (
    match S.decode "retry:81000000-0000-4000-8000-000000000003" with
    | Some (Retry_upload _) -> true
    | _ -> false);
  List.iter
    (fun payload -> assert (S.decode payload = None))
    [ "days:-1"; "days:3661"; "days:no"; "days:"; "bogus" ]
;;
