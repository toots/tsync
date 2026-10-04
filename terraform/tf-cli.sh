# Sourced, not run: the one rule that picks the provisioning CLI
# (docs/spec/11-infrastructure.md §13).

tf_cli() {
  if [ -n "${TSYNC_TF:-}" ]; then
    command -v "$TSYNC_TF" >/dev/null 2>&1 || return 1
    printf '%s\n' "$TSYNC_TF"
    return 0
  fi
  local candidate
  for candidate in tofu terraform; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
