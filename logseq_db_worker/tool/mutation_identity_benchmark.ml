open Logseq_db_types
open Mutation
module Engine = Logseq_db_worker.Engine
module F = Logseq_db_worker_test_support.Adapter_fixture

type measurement =
  { nanoseconds_per_operation : float
  ; allocated_bytes_per_operation : float
  }

type sample =
  { name : string
  ; mutation : Mutation.t
  ; identity_iterations : int
  ; admission_iterations : int
  }

let allocated_words (stats : Gc.stat) =
  stats.minor_words +. stats.major_words -. stats.promoted_words
;;

let measure ~iterations operation =
  Gc.full_major ();
  let before_gc = Gc.quick_stat () in
  let before_ns = Mtime_clock.elapsed_ns () in
  let sink = ref 0 in
  for _ = 1 to iterations do
    sink := !sink + operation ()
  done;
  Sys.opaque_identity !sink |> ignore;
  let elapsed_ns = Int64.sub (Mtime_clock.elapsed_ns ()) before_ns |> Int64.to_float in
  let allocated_words = allocated_words (Gc.quick_stat ()) -. allocated_words before_gc in
  { nanoseconds_per_operation = elapsed_ns /. Float.of_int iterations
  ; allocated_bytes_per_operation =
      allocated_words *. Float.of_int (Sys.word_size / 8) /. Float.of_int iterations
  }
;;

let uuid index =
  Printf.sprintf "65000000-0000-4000-8000-%012x" index
  |> Graph_types.Uuid.of_string
  |> Result.get_ok
;;

let capture ~basis ~root_count ~title_bytes =
  let roots =
    List.init root_count (fun index ->
      { uuid = uuid (index + 1)
      ; title = String.make title_bytes (Char.chr (Char.code 'a' + (index mod 26)))
      ; children = []
      })
  in
  Structural
    (Insert_blocks
       { roots
       ; position = Relative (Last_child (F.uuid "11111111-1111-4111-8111-111111111111"))
       ; context = { mutation_id = uuid 0xfff; expected_basis = basis }
       })
;;

let legacy_direct_identity mutation =
  mutation
  |> (fun value -> Marshal.to_string value [ Marshal.No_sharing ])
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
  |> String.length
;;

let legacy_managed_admission_identity mutation =
  let coordinator_fingerprint = Mutation.to_yojson mutation |> Yojson.Safe.to_string in
  let mutation_payload = Mutation.to_yojson mutation |> Yojson.Safe.to_string in
  String.length coordinator_fingerprint
  + String.length mutation_payload
  + legacy_direct_identity mutation
;;

let shared_identity mutation =
  let identity = Mutation.identify mutation in
  String.length (Mutation.identity_payload identity)
  + String.length (Mutation.identity_fingerprint identity)
;;

let print_measurement sample operation iterations measurement =
  Printf.printf
    "%s,%d,%s,%d,%.0f,%.0f,64\n"
    sample.name
    (Mutation.identify sample.mutation |> Mutation.identity_payload |> String.length)
    operation
    iterations
    measurement.nanoseconds_per_operation
    measurement.allocated_bytes_per_operation
;;

let modeled_before ~after ~legacy_identity ~shared_identity =
  { nanoseconds_per_operation =
      after.nanoseconds_per_operation
      -. shared_identity.nanoseconds_per_operation
      +. legacy_identity.nanoseconds_per_operation
  ; allocated_bytes_per_operation =
      after.allocated_bytes_per_operation
      -. shared_identity.allocated_bytes_per_operation
      +. legacy_identity.allocated_bytes_per_operation
  }
;;

let benchmark_sample engine sample =
  let legacy_direct =
    measure ~iterations:sample.identity_iterations (fun () ->
      legacy_direct_identity sample.mutation)
  in
  let legacy_managed =
    measure ~iterations:sample.identity_iterations (fun () ->
      legacy_managed_admission_identity sample.mutation)
  in
  let shared =
    measure ~iterations:sample.identity_iterations (fun () ->
      shared_identity sample.mutation)
  in
  let admission_after =
    measure ~iterations:sample.admission_iterations (fun () ->
      let identity = Mutation.identify sample.mutation in
      match Engine.prepare_managed_mutation engine ~identity sample.mutation with
      | Ok prepared -> Engine.prepared_mutation_payload prepared |> String.length
      | Error message -> failwith message)
  in
  let admission_before =
    modeled_before
      ~after:admission_after
      ~legacy_identity:legacy_managed
      ~shared_identity:shared
  in
  print_measurement sample "direct-before" sample.identity_iterations legacy_direct;
  print_measurement sample "identity-after" sample.identity_iterations shared;
  print_measurement
    sample
    "managed-identity-before"
    sample.identity_iterations
    legacy_managed;
  print_measurement
    sample
    "managed-admission-before-modeled"
    sample.admission_iterations
    admission_before;
  print_measurement
    sample
    "managed-admission-after"
    sample.admission_iterations
    admission_after
;;

let () =
  Printf.printf
    "sample,payload_bytes,operation,iterations,ns_per_operation,allocated_bytes_per_operation,fingerprint_bytes\n";
  F.with_synced_mirror (fun fixture ->
    let engine =
      Engine.open_ ~dependencies:F.dependencies fixture.config |> Result.get_ok
    in
    Fun.protect
      ~finally:(fun () -> Engine.close engine |> Result.get_ok)
      (fun () ->
         let basis = Engine.basis engine |> Option.get in
         let samples =
           [ { name = "capture-representative"
             ; mutation = capture ~basis ~root_count:1 ~title_bytes:1_024
             ; identity_iterations = 5_000
             ; admission_iterations = 500
             }
           ; { name = "capture-near-maximum-request"
             ; mutation = capture ~basis ~root_count:15 ~title_bytes:65_000
             ; identity_iterations = 40
             ; admission_iterations = 8
             }
           ]
         in
         List.iter (benchmark_sample engine) samples))
;;
