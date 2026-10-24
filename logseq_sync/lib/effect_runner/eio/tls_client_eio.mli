type error =
  | Invalid_dns_host
  | No_network_address
  | Setup_failed of string
  | Authentication_failed

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
