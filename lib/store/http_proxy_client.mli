(** The [http-proxy] driver: a store served by another tsync machine (spec
    backends/http-proxy.md). *)

(** Its config fields (§1). *)
val fields : Tsync_core.Field_spec.field list
