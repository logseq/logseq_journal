type error =
  | Invalid_dns_host
  | No_network_address
  | Setup_failed of string
  | Authentication_failed

type transient_failure = Connection_refused | Connection_timeout | Network_unreachable | Connection_reset

val transient_failure : exn -> transient_failure option

val initialize_rng : unit -> unit

val connect
  :  sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> host:string
  -> port:int
  -> (Tls_eio.t, error) result

val safe_setup_detail : string -> string option

(** Reports a finite DNS cause only if every address family fails. Native empty
    results without an exception have no invented cause; variants are unchanged. *)
val connect_diagnosed
  :  on_diagnostic:(string -> unit)
  -> sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> host:string
  -> port:int
  -> (Tls_eio.t, error) result

(** Presentation metadata only. Report a finite transient cause only after every
    failed address is known transient. Unknown, permission and TLS/security
    failures remain attention-worthy; transport results and retry policy do not change. *)
val connect_diagnosed_with_attention
  :  on_transient_failure:(transient_failure -> unit)
  -> on_diagnostic:(string -> unit)
  -> sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> host:string
  -> port:int
  -> (Tls_eio.t, error) result
