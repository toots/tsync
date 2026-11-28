# Local names — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/local-names.md](../../algorithms/local-names.md). Not normative.

## Code map

| Spec concept | Code |
|---|---|
| Canonical form, detection, the per-op effect (§3–§5) | `lib/checkout/local_names.ml`: `place` (demotes), `promote`, `remove`; the only code that chooses a mirror slot |
| Recorded names (§3.1) | `Local_names.recorded`, `name_of` (falls back to the listed spelling only for an entry with no record) |
| Lookup (§6) | `Local_names.find`; `Mirror.locate` / `path` resolve a key through it; `Mirror.file` repeats a read that found a moved or renamed entry |
| Slot identity, refused names | `Local_names.same` (`st_dev`, `st_ino`), `refused` (`ENAMETOOLONG`, `EINVAL`, `EILSEQ` as `EUNKNOWNERR`) |
| Demoted flag (§4) | `Local_names.flag`, `set_flag`; removed by `promote` when `demoted` finds none |
| Renames (§5) | `Mirror.move_folder` rewrites the markers, then `place` with the folder as `from`; the self case in `Local_names.settle` |
| The staged tree (§3.2) | `Staged.manifest_path` (every component at `Names.handle`), `Staged.make_dir`, `move_dir`, `migrate_layout` (called by `Engine.recover` before `Staged.fold`) |
| Conformance (01 §16) | `tests/unit/local_names_test`: every ordering over `{a, A, á NFC, á NFD}`, files and folders, plus each review regression and concurrent readers |

## Notes

- `Mirror.names` names a plain entry by its listed spelling, to avoid decoding every manifest. That is its recorded name on every disk tsync writes to except HFS+, which lists NFD; `Mirror.list` reads the record.
- `Fs.temp_in` names the directory a new mirror folder is built in, so a crash leaves a temporary that the start-up sweep removes.
