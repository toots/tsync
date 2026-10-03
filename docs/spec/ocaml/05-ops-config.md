# 05 — Domain config and whole-domain operations — OCaml implementation notes

Companion to the language-neutral spec [../05-ops-config.md](../05-ops-config.md). See [README.md](README.md) for how these notes are organised. Stores: [06-backends.md](06-backends.md). Collection: [algorithms/gc.md](algorithms/gc.md). Memory of the whole-domain walks: [memory.md](memory.md).

## Map

**Config (§2).**

| Spec | Code |
|---|---|
| Parser and validation (§2.1) | `lib/config/config.ml`: `Config.of_string`, `of_json`; `check_keys` at every level; `parse_domain`, `parse_backend`, `parse_frontend`, `parse_link`, `link_of`; every error is `Config.Invalid` with the JSON path |
| Declared field types | `Tsync_core.Field_spec.field` and `Field_spec.value`; `spec_value` and `fields_of` read a driver's or frontend's fields; `Field_spec.http_url`, `secret_length`, `absolute_path`, `absolute_or_home` are the shared rules |
| Known backend and frontend types | `Tsync_store.Driver.find`, `Tsync_config.Frontend.find`: registries filled by the libraries `lib/catalog` links |
| Domain and backend names | `Domain_name.of_string ~local_store`; the name rules and the case-insensitive uniqueness checks in `parse_backend`, `parse_domain`, `of_json` |
| Role validation, read order | `parse_domain`; backends sorted by `Composite.read_rank` |
| Frontend rules | `parse_domain`: each type once, at most one with `Frontend.presenting` |
| Sizes, booleans | `Config.parse_size`, `Config.bool_of_string_opt` |
| Uplink (§2.1, 06 §7) | `Config.link`, `link_settings`, `uplink_settings` |
| Masking | `Config.masked_fields`: a field without a spec is `Secret` |
| Locations, file mode | `Paths.config_file`, `Paths.read_config` (a file readable by group or other is refused, or made private when interactive) |
| Writing a config | `Config_wizard.edit` on the raw JSON, `Config_wizard.prepare` (the parser's own validation), then `Fs.durable_replace ~perm:0o600` in `bin/setup_cmds.ml` |
| Domain resolution (§2.2) | `Config.resolve ?name ?default`, `Paths.default_domain` |

**Domain Context (§3).**

| Spec | Code |
|---|---|
| The built domain | `Tsync_domain.Domain.t` (`config`, `domain`, `composite`, `members`, `cache_root`, `data_dir`, `poke`), from `Domain.build ?owner ?poke` |
| One store client per backend, its admission and probe (§3.2) | `create_store` in `domain.ml`: `Uplink.link`, `Driver.create`, `Uplink.attach` with `Domain.probe` |
| Composite and deferred logs | `Composite.create ~owner ~poke ~knowledge`; `Composite.start` is called by the engine, which only the owner instantiates |
| The view handed to the remote layer | `Tsync_remote.Context.S`, a module type; `Domain.context` packs one |
| The owner's view | `Engine_ctx.S`, built in `Domain.engine`, which applies `Engine.Make` once |
| `reading_from`, `reading_at_most` (§3.1) | `?reading_from` and `?reading_at_most` of `Domain.context` |
| `capacity` | `Domain.capacity` |
| Key names | `Tsync_core.Key` (`Key.cursor`, `Key.journal`, `Key.shares`, …), not fields of the context |

**Operations (§4).**

| Spec | Code |
|---|---|
| Where an operation runs (§4.1) | `Tsync_owner.Jobs.t` and `Jobs.run`, called by the owner's `handler.ml`, one job at a time; `Protocol.refused_while_paused` |
| Narration | `Tsync_core.Narrate.t`, an argument of every operation |
| Cancellation | `?cancelled:(unit -> bool)`, `Tsync_core.Cancel` |
| Announcing (§4.2) | `Bulk.batches` in `lib/sync/bulk.ml` (`entry_ops`, `entry_age`, `Dqueue.Records.create_held`), `Bulk.folder`, `Bulk.publish` |
| Import (§4.3) | `Import_plan.plan` (pure walk), `Engine.S.import` (`lib/sync/import.ml`), `Bulk.upload_file` |
| Export (§4.4) | `Export.Make(Context).export`, `Export.sweep_records`; built in `bin/store_cmds.ml`, in the command's own process |
| Rsync (§4.5) | `Rsync_plan.decide`, `unchanged`, `differing`, `disposes` (pure); `Engine.S.rsync` (`lib/sync/rsync.ml`) |
| Mirror (§4.6) | `Store_mirror.Make(Context).mirror`, `Store_mirror.scope` |
| Resync (§4.7) | `Engine.S.resync`, `rebuild`, `apply_pass` |
| Trash and retention (§4.8) | `Tree.trashed`, `Tree.restore`, `Engine.S.restore_from_trash`; `Retention.Make(Context).expire`, `purge`; decisions in `Gc_plan.trash`, `versions`, `journal`, `share` |
| Collection (§4.9) | `Collector.run`, `dry_run`, `status`; `Gc_plan.start`; `Gc_record`; `Chunk_spaces.with_run_lock`; `Composite.outstanding`, `retry_outstanding` |
| Integrity (§4.10) | `Integrity.Make(Context).report`, `repair_tree`, `verify`, `repair_chunks` |
| Share (§4.11) | `Share.Make(Context).create`, `revoke`, `clear_cache`, called from `handler.ml` |

## Departures

- **A type this build lacks is refused when the config is parsed**, as "unknown or not compiled into this build", with the built types listed. The parser knows only what registered; the spec refuses a known but unbuilt type when it is used.
- **Every job is refused while the domain is paused**, dry runs and reports included (`Job _` in `Protocol.refused_while_paused`).
- **`Collector.Busy` carries no holder.**
- **Import, rsync, export and integrity hold their whole plan before working** (`Import_plan.plan.entries`, `entries` in `rsync.ml`, `files` in `export.ml`): a list, not a spill (finding 85).
- **A check on a field's text runs only for string and path values** (`fields_of`).

## Learnings

- **Unknown keys cannot pass because the known set is data.** `check_keys` takes the common keys plus the `Field_spec.field` names of the registered driver or frontend, so a new field is declared once, in its driver, and the parser, the wizard and the masking all read that declaration.
- **A field's `default` is the wizard's.** The parser leaves an absent field out of `fields`; each driver applies its own default in `create`. An empty string is an absent string field, and `null` an absent value.
- **The registries are the build** (pitfall B-11.1). `Driver.names ()` and `Frontend.names ()` are what `tsync build-info` prints and what the error for an unknown type lists; the optional frontends and TLS implementations enter through the `select` stubs of `lib/catalog/dune`.
- **The wizard edits JSON, not `Config.t`.** A key it does not ask about survives a round trip, and `prepare` validates with `Config.of_json`, so the wizard cannot write what the parser refuses.
- **The context is a first-class module over two functor families.** `Retention`, `Integrity`, `Store_mirror`, `Share` and `Export` are `Make (Context.S)`; import and rsync are layers of the engine's functor chain (`Outbound.Make`, `Bulk.Make`, `Import.Make`, `Rsync.Make` over `Engine_ctx.S`), since they publish through the owner's WAL and mirror. Each `Make` application has its own module-level state, so the engine is applied once per domain and kept by the owner.
- **`reading_from` is a record update of the composite's store**: it replaces `get_opt`, `get_range`, `head_opt`, `list_prefix`, `watch`, `get_many`, `list_many` and `health` with the member's. A read field added to `Store.t` is not redirected until it is listed there.
- **Decisions are pure modules, effects apply them.** `Import_plan`, `Rsync_plan` and `Gc_plan` take facts and answer variants; `tests/sync/import_plan_test`, `rsync_plan_test` and `tests/gc/plan_test` cover their tables without a store.
- **A batch's record exists, held, before its first put** (`Dqueue.Records.create_held`), and is rewritten to the ops that ran before the hold ends; a rescan never adopts the full record in between. A batch's items run one after another, and it closes after `entry_ops` items or `entry_age` seconds.
- **`Bulk.upload_file` stats the open descriptor before and after reading**, and a file that changed is LOCAL, never published as a mix.
- **Export claims a chunk only after its fsync** (`Fs.fsync`, then `Fs.append_durable` of the index), and holds a `flock` on the record for the run; `sweep_records` removes only records it can lock.
- **Export and mirror pull work with `Rt.each ~width`**: a fixed number of workers take the next item under a mutex, so live fibers are bounded by the width and not by the item count.
- **The dry run's referenced set is a `Chunk_set`**, packed, not a table of strings (finding 82).
- **Each owner job ends with `Usage.release`** (`handler.ml`): a large walk's heap goes back to the system ([memory.md](memory.md) §M.4).
- **Tests.** `tests/config` (`config_test`, `wizard_test`), `tests/sync` (`import_test`, `export_test`, `rsync_test`), `tests/gc` (`collector_test`, `resume_test`, `queued_test`, `retention_test`, `integrity_test`, `verify_test`, `mirror_test`, `share_test`), `tests/owner/jobs_test`.
