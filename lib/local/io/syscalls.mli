(* A signal arriving mid-syscall makes it fail with EINTR rather than doing
   anything wrong, so every wrapper below just calls again; the daemon takes
   SIGCHLD and SIGWINCH often enough for this to matter.

   The rule is here and the calls are the platform's, which is what {!S} is
   for: it lists what a platform owes, in the names and argument order the
   caller already knows. *)

module type S = Syscalls_intf.S

module Make (Io : Io.S) (Sys : S with type 'a io := 'a Io.t) : sig
  include S with type 'a io := 'a Io.t and type fd = Sys.fd

  (** Call [f] again for as long as it fails with [EINTR]. *)
  val retry_eintr : (unit -> 'a Io.t) -> 'a Io.t
end
