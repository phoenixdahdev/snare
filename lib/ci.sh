# shellcheck shell=bash
# ci.sh — drop a ready-to-commit scan workflow into someone's repo. Closes #15.
#
# GitHub.com has no server-side pre-receive hooks (Enterprise only), so a push
# cannot be rejected outright. A required status check is the practical
# equivalent: the merge button stays disabled until the scan passes.
#
# The generated workflow runs a scanner inside the caller's job, alongside
# whatever secrets that job holds. So every reference it writes is pinned: the
# reusable workflow definition and the scanner revision both name one immutable
# commit, and both come from this fork rather than another account.

SNARE_CI_REPO="phoenixdahdev/snare"

# The exact commit the generated workflow pins to. Resolved from the fork's own
# default branch so the SHA is guaranteed to exist on GitHub. Override with
# SNARE_CI_PIN when scaffolding from a checkout whose HEAD has not been pushed.
_ci_pin(){
  if [ -n "${SNARE_CI_PIN:-}" ]; then printf '%s' "$SNARE_CI_PIN"; return 0; fi
  local sha
  sha="$(GIT_TERMINAL_PROMPT=0 git ls-remote "https://github.com/$SNARE_CI_REPO.git" HEAD 2>/dev/null | cut -f1)"
  [ -n "$sha" ] || sha="$(git -C "$SNARE_ROOT" rev-parse HEAD 2>/dev/null)"
  [ -n "$sha" ] || die "cannot determine a commit to pin to — set SNARE_CI_PIN to the full commit SHA"
  printf '%s' "$sha"
}

cmd_ci(){
  # Default to status, like guard/shield/hook/baseline. Defaulting to install
  # meant a bare `snare ci` tried to write a workflow and failed outside a repo.
  local sub="${1:-status}"; shift || true
  case "$sub" in
    install) _ci_install "$@" ;;
    status)  _ci_status "$@" ;;
    print)   _ci_render ;;
    *) echo "usage: snare ci [install|status|print] [path]" ;;
  esac
}

_ci_render(){
  # `uses:` and `snare-ref` must name the same commit: the first decides which
  # workflow definition runs, the second which scanner it fetches.
  local pin; pin="$(_ci_pin)"
  sed -e "s|__REPO__|$SNARE_CI_REPO|g" -e "s|__PIN__|$pin|g" <<'YAML'
# Added by `snare ci install`.
# Blocks a merge until this repository passes a malware scan.
#
# Pinned on purpose. This workflow runs scanner code inside this repository's
# job, so the reusable workflow and the scanner revision both name one commit.
# Bump both SHAs together, and only to code you have reviewed, to update it.
#
# One manual step remains, because a workflow cannot grant itself authority:
#   Settings > Branches > add a rule for your default branch
#   > Require status checks to pass > select "snare scan / scan"
# Until you do that, this reports but does not block.
name: snare

on:
  push:
    branches: [main, master]
  pull_request:

jobs:
  snare:
    uses: __REPO__/.github/workflows/scan.yml@__PIN__
    with:
      # true scans every commit, not just the tip. Slower, catches a payload
      # that was committed and later removed.
      full-history: false
      snare-ref: __PIN__
YAML
}

_ci_install(){
  local dir="${1:-$PWD}" force=0
  [ "${1:-}" = "--force" ] && { force=1; dir="${2:-$PWD}"; }
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $dir"

  local wf="$dir/.github/workflows/snare.yml"
  if [ -f "$wf" ] && [ "$force" = 0 ]; then
    ylw "  already present: $wf"
    dim "  overwrite with: snare ci install --force"
    return 0
  fi
  # Render into a variable before touching the file: a failed render must not
  # leave a truncated, unusable workflow behind.
  local rendered; rendered="$(_ci_render)" || die "could not render the scan workflow"
  [ -n "$rendered" ] || die "refusing to write an empty scan workflow"
  mkdir -p "$dir/.github/workflows"
  printf '%s\n' "$rendered" > "$wf"
  grn "  wrote $wf"
  echo
  echo "  Next:"
  dim "    git add .github/workflows/snare.yml"
  dim "    git commit -m 'ci: scan for committed malware on every PR'"
  dim "    git push"
  echo
  ylw "  Then make it blocking — this is the step that actually stops a merge:"
  dim "    Settings > Branches > branch protection rule for your default branch"
  dim "    > Require status checks to pass  >  select \"snare / snare\""
  echo
  dim "  Until that box is ticked the scan reports but does not block."
}

_ci_status(){
  local dir="${1:-$PWD}"
  local wf="$dir/.github/workflows/snare.yml"
  if [ -f "$wf" ]; then grn "  workflow: installed ($wf)"; else
    ylw "  workflow: not installed (snare ci install)"; return 0; fi

  # If gh is available and this is a GitHub remote, report whether the check
  # is actually required — an installed workflow that is not required blocks
  # nothing, and that gap is easy to miss.
  command -v gh >/dev/null 2>&1 || { dim "  (install gh to check branch protection)"; return 0; }
  local slug; slug="$(git -C "$dir" config --get remote.origin.url 2>/dev/null \
    | sed -E 's#.*github\.com[:/]([^/]+/[^/]+?)(\.git)?$#\1#')"
  [ -z "$slug" ] && return 0
  local br; br="$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null)"
  [ -z "$br" ] && return 0
  local checks; checks="$(gh api "repos/$slug/branches/$br/protection/required_status_checks" \
    --jq '.contexts[]?' 2>/dev/null)"
  if echo "$checks" | grep -qi snare; then
    grn "  branch protection: snare check is REQUIRED on $br"
  else
    ylw "  branch protection: snare is NOT a required check on $br"
    dim "  the workflow runs but nothing is blocked — tick it in Settings > Branches"
  fi
}
