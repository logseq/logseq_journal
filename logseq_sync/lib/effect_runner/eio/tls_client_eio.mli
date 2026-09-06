type error =
  | Invalid_dns_host
  | No_network_address
  | Setup_failed of string

val initialize_rng : unit -> unit

val connect
  :  sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> host:string
  -> port:int
  -> (Tls_eio.t, error) result
