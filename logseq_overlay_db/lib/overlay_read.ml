module Graph = Logseq_db_types.Graph_types

let bounded_members ~maximum facts =
  if maximum <= 0
  then [], 0
  else (
    let heap = Array.make maximum None in
    let size = ref 0 in
    let total = ref 0 in
    let swap left right =
      let value = heap.(left) in
      heap.(left) <- heap.(right);
      heap.(right) <- value
    in
    let rec rise index =
      if index > 0
      then (
        let parent = (index - 1) / 2 in
        if
          Outliner_order.compare_member
            (Option.get heap.(parent))
            (Option.get heap.(index))
          < 0
        then (
          swap parent index;
          rise parent))
    in
    let rec sink index =
      let left = (index * 2) + 1 in
      if left < !size
      then (
        let right = left + 1 in
        let largest =
          if
            right < !size
            && Outliner_order.compare_member
                 (Option.get heap.(left))
                 (Option.get heap.(right))
               < 0
          then right
          else left
        in
        if
          Outliner_order.compare_member
            (Option.get heap.(index))
            (Option.get heap.(largest))
          < 0
        then (
          swap index largest;
          sink largest))
    in
    Seq.iter
      (fun fact ->
         incr total;
         if !size < maximum
         then (
           heap.(!size) <- Some fact;
           rise !size;
           incr size)
         else if Outliner_order.compare_member fact (Option.get heap.(0)) < 0
         then (
           heap.(0) <- Some fact;
           sink 0))
      facts;
    Array.to_list (Array.sub heap 0 !size)
    |> List.map Option.get
    |> List.sort Outliner_order.compare_member
    |> fun values -> values, !total)
;;
