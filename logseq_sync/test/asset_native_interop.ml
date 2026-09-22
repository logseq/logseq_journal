(* Run through tool/test_asset_interop.py with the production Apple crypto library. *)
module C = Logseq_sync_effect_runner.Asset_codec
module T = Transit_native.Transit.Json

external native_crypto
  :  bool
  -> string
  -> string
  -> string
  -> (string, string) result
  = "logseq_journal_crypto_binary_call"

let crypto : C.crypto =
  { encrypt =
      (fun ~key ~plaintext ->
        Result.map
          (fun bytes ->
             String.sub bytes 0 12, String.sub bytes 12 (String.length bytes - 12))
          (native_crypto true key "" plaintext))
  ; decrypt = (fun ~key ~iv ~ciphertext -> native_crypto false key iv ciphertext)
  }
;;

let read path = In_channel.with_open_bin path In_channel.input_all
let write path value = Out_channel.with_open_bin path (fun ch -> output_string ch value)

let get = function
  | Ok x -> x
  | Error e -> failwith e
;;

let reject label result = if Result.is_ok result then failwith ("Accepted " ^ label)

let () =
  let directory = Sys.argv.(1) in
  let path name = Filename.concat directory name in
  let key = read (path "key.bin") in
  reject
    "plaintext above the native attachment limit"
    (crypto.encrypt ~key ~plaintext:(String.make ((8 * 1024 * 1024) + 1) 'x'));
  reject "invalid key length" (crypto.encrypt ~key:"short" ~plaintext:"");
  reject
    "invalid nonce length"
    (crypto.decrypt ~key ~iv:"short" ~ciphertext:(String.make 16 'x'));
  reject
    "truncated tag"
    (crypto.decrypt ~key ~iv:(String.make 12 'x') ~ciphertext:"short");
  List.iter
    (fun size ->
       let name suffix = path (string_of_int size ^ suffix) in
       let plaintext = read (name ".bin") in
       let upstream = read (name ".upstream.transit") in
       let checksum = C.checksum plaintext in
       let decode ?(key = key) ?(checksum = checksum) wire =
         C.decode
           ~maximum_plaintext_bytes:size
           ~crypto
           ~key:(Some key)
           ~expected_checksum:checksum
           wire
       in
       if get (decode upstream) <> plaintext then failwith "Upstream bytes changed";
       reject "wrong key" (decode ~key:(String.make 32 '\255') upstream);
       reject "wrong checksum" (decode ~checksum:(String.make 64 '0') upstream);
       let corrupt =
         match T.of_string upstream with
         | Transit_core.Json.Array [ Binary iv; Binary ciphertext ] ->
           let bytes = Bytes.of_string ciphertext in
           Bytes.set bytes 0 (Char.chr (Char.code (Bytes.get bytes 0) lxor 1));
           T.to_string
             (Transit_core.Json.Array [ Binary iv; Binary (Bytes.to_string bytes) ])
         | _ -> failwith "Unexpected upstream envelope"
       in
       reject "corrupt ciphertext" (decode corrupt);
       let outgoing =
         get (C.encode ~maximum_plaintext_bytes:size ~crypto ~key:(Some key) plaintext)
       in
       write (name ".journal.transit") outgoing;
       Printf.printf "Native decode and authenticated rejection: %d bytes\n%!" size)
    [ 0; 1; 256; 4097; 131057; 8388608 ]
;;
