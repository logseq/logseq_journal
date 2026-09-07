module Order = Outliner_order

let require condition message = if not condition then failwith message

let rejects f =
  match f () with
  | _ -> failwith "invalid input was accepted"
  | exception Invalid_argument _ -> ()
;;

let check_interval lower upper keys =
  let previous = ref lower in
  List.iter
    (fun key ->
       Order.validate key;
       require
         (Option.fold ~none:true ~some:(fun bound -> bound < key) !previous)
         "key did not increase";
       require
         (Option.fold ~none:true ~some:(fun bound -> key < bound) upper)
         "key exceeded upper bound";
       previous := Some key)
    keys
;;

let () =
  let rows = ref 0 in
  let input = open_in Sys.argv.(1) in
  (try
     while true do
       let line = input_line input in
       match String.split_on_char '\t' line with
       | [ lower; upper; count; expected ] ->
         let bound = function
           | "-" -> None
           | value -> Some value
         in
         let lower, upper, count = bound lower, bound upper, int_of_string count in
         let expected =
           if expected = "-" then [] else String.split_on_char ',' expected
         in
         let actual = Order.generate_n ~lower ~upper count in
         require
           (actual = expected)
           ("reference mismatch: " ^ line ^ " actual=" ^ String.concat "," actual);
         if count = 1
         then
           require
             ([ Order.generate ~lower ~upper ] = expected)
             "single-key reference mismatch";
         check_interval lower upper actual;
         incr rows
       | _ -> failwith "invalid reference fixture"
     done
   with
   | End_of_file -> close_in input);
  let minimum = "A" ^ String.make 26 '0' in
  List.iter
    (fun key ->
       rejects (fun () -> Order.validate key);
       rejects (fun () -> Order.generate ~lower:(Some key) ~upper:None);
       rejects (fun () -> Order.generate_n ~lower:None ~upper:(Some key) 0))
    [ ""; "0"; "a"; "b0"; "a00"; "a0V0"; "a!"; "a0/"; "a0:"; "a0{"; "a0é"; minimum ];
  List.iter Order.validate [ "a0"; "b00"; "Zz"; "a0V"; minimum ^ "V" ];
  List.iter
    (fun (lower, upper) ->
       rejects (fun () -> Order.generate ~lower:(Some lower) ~upper:(Some upper));
       rejects (fun () -> Order.generate_n ~lower:(Some lower) ~upper:(Some upper) 0))
    [ "a0", "a0"; "a1", "a0" ];
  rejects (fun () -> Order.generate_n ~lower:None ~upper:None (-1));
  let upper = "A" ^ String.make 25 '0' ^ "1" in
  require
    (Order.generate ~lower:None ~upper:(Some upper) = minimum ^ "V")
    "reserved minimum key regression";
  let keys = Order.generate_n ~lower:None ~upper:(Some upper) 5 in
  check_interval None (Some upper) keys;
  let upper = "a0" ^ String.make 4096 '0' ^ "1" in
  check_interval
    (Some "a0")
    (Some upper)
    [ Order.generate ~lower:(Some "a0") ~upper:(Some upper) ];
  let keys = Order.generate_n ~lower:None ~upper:None 10000 in
  require (List.length keys = 10000) "large batch cardinality";
  check_interval None None keys;
  Printf.printf
    "%d pinned-reference cases plus validation, reserved-minimum, long-interval, and \
     large-batch checks passed.\n"
    !rows
;;
