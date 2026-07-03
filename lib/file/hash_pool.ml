(* Shared Domainslib pool (via lwt_domain) for parallel chunk hashing. The pool
   is created on first use and lives for the process lifetime.
   ponytail: no teardown — a daemon-lifetime pool; add teardown_pool only if
   pools are ever created per-request. *)
let pool =
  lazy
    (let n = max 1 (Domain.recommended_domain_count () - 1) in
     Lwt_domain.setup_pool n)

let detach f x = Lwt_domain.detach (Lazy.force pool) f x
