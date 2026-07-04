# shellcheck shell=bash
# aic module loader.
# Sources every aic library module. Used by bin/aic and by the test harness.
# core.sh must load first (it defines globals + colors used by the rest);
# the remaining modules only define functions, so their order does not matter.

__aic_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for __aic_mod in core codex-process codex codex-import claude model usage ui schedule lifecycle transfer; do
  # shellcheck source=/dev/null
  source "$__aic_lib_dir/$__aic_mod.sh"
done
unset __aic_lib_dir __aic_mod
