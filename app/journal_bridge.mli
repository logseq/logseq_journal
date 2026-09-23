(** OCaml-side entries exposed to the native host through
    [journal_lui_bridge.c]. [register] installs every [Callback] named value
    the C stub resolves. Each entry that produces UI patches returns the
    latest JSON patch batch, exactly like [lui_ocaml_bridge.c]'s emit_patch
    protocol. *)

type hooks =
  { init : int -> int -> string -> string
    (* [platform_code -> host_code -> payload -> patch json]. Builds the app
        with the lui backend for the given host profile, decodes the startup
        payload into the service config, starts it, and returns the initial
        patch batch. *)
  ; (* Dispatches a standard lui UI event; returns the patch batch produced
        by the dispatch + flush. *)
    dispatch : Lui_protocol.event -> string
  ; (* [node -> name -> values_json -> patch json]. Forwards an extension
        event from a registered journal native component. *)
    extension_event : int -> string -> string -> string
  ; (* Drains the cross-thread work queue ([Journal_pump]) and flushes;
        returns the patch batch. *)
    pump : unit -> string
  ; (* Host -> OCaml: an LJP2 platform envelope pushed by the host
        (lifecycle, network, termination). Binary-safe string. *)
    platform_event : string -> unit
  ; (* Host -> OCaml: an LJP2 response envelope completing an earlier
        platform request. Binary-safe string. *)
    platform_response : string -> unit
  ; (* Host -> OCaml: the platform could not answer a request (decode or
        service failure). Carries the original request envelope; the pending
        continuation resolves with an error, matching the old bridge's
        request-failure path. *)
    platform_failure : string -> unit
  ; (* Tears the app down; returns the final patch batch. *)
    dispose : unit -> string
  ; root_node : unit -> int
  }

val register : hooks -> unit

(* OCaml -> host trampolines implemented by the C stub; the host installs
    the underlying function pointers at startup. *)

(* Invokes the host wakeup callback so it schedules [journal_ocaml_pump] on
    the app thread. *)
external wakeup : unit -> unit = "journal_ml_wakeup"

(* Forwards one LJP2 request envelope to the host platform bridge (the host
    answers asynchronously through [platform_response]). *)
external platform_request : string -> unit = "journal_ml_platform_request"
