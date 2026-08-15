module T = Logseq_db_worker_test_support.Test_support
module Order = Logseq_db_worker__Outliner_order

let check lower upper expected () =
  match Order.between ~lower ~upper with
  | Ok actual -> T.require (String.equal actual expected) "expected %s, got %s" expected actual
  | Error _ -> T.fail "fractional key generation failed"

let pinned =
  [ None, None, "a0"
  ; None, Some "a0", "Zz"
  ; None, Some "Zz", "Zy"
  ; Some "a0", None, "a1"
  ; Some "a1", None, "a2"
  ; Some "a0", Some "a1", "a0V"
  ; Some "a1", Some "a2", "a1V"
  ; Some "a0V", Some "a1", "a0l"
  ; Some "Zz", Some "a0", "ZzV"
  ; Some "Zz", Some "a1", "a0"
  ; None, Some "Y00", "Xzzz"
  ; Some "bzz", None, "c000"
  ; Some "a0", Some "a0V", "a0G"
  ; Some "a0", Some "a0G", "a08"
  ; Some "b125", Some "b129", "b127"
  ; Some "a0", Some "a1V", "a1"
  ; Some "Zz", Some "a01", "a0"
  ; None, Some "a0V", "a0"
  ; None, Some "b999", "b99"
  ]

let () =
  T.run
    "order"
    (List.mapi
       (fun index (lower, upper, expected) ->
          T.case ("pinned exact fractional key " ^ string_of_int index) (check lower upper expected))
       pinned
     @ [ T.case "generated keys are valid" (fun () ->
           List.iter
             (fun (_, _, key) -> T.require (Order.is_valid key) "invalid generated key %s" key)
             pinned)
       ; T.case "long repeated insertion remains ordered" (fun () ->
           let rec loop lower count =
             if count = 0
             then ()
             else
               match Order.between ~lower:(Some lower) ~upper:(Some "a1") with
               | Error _ -> T.fail "repeated insertion failed"
               | Ok key ->
                   T.require (String.compare lower key < 0) "new key did not advance";
                   T.require (String.compare key "a1" < 0) "new key crossed upper bound";
                   loop key (count - 1)
           in
           loop "a0" 1_000)
       ; T.case "batch sequence preserves stable string ordering" (fun () ->
           match Order.sequence_between ~lower:(Some "a0") ~upper:(Some "a1") 100 with
           | Error _ -> T.fail "batch generation failed"
           | Ok keys ->
               T.require (List.length keys = 100) "wrong key count";
               T.require (List.sort_uniq String.compare keys = keys) "keys not strictly ordered")
       ; T.case "invalid existing key is rejected" (fun () ->
           match Order.between ~lower:(Some "a00") ~upper:None with
           | Error (Order.Invalid_key _) -> ()
           | _ -> T.fail "invalid key accepted")
       ])
