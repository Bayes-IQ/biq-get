#!/usr/bin/env bash
# biq-get.sh — one-line biq setup for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/Bayes-IQ/biq-get/main/biq-get.sh | bash
#
# Installs what is missing (Homebrew tools, GitHub CLI, Claude Code, Codex),
# signs in through each tool's own browser flow, accepts your invitation to the
# private biq repository, installs or updates biq in ~/biq, and starts it.
# Run it again any time to update.
#
# It never runs sudo itself and never reads or prints tokens. The only profile
# edit is Homebrew's own PATH line in ~/.zprofile, offered when Homebrew is not
# yet on your PATH. Plan: plans/biq-get-bootstrap.md (bayesiq-workspace).
#
# Exit codes: 0 ok; 1 a step failed; 2 stopped before changing anything.

# Everything is inside main(), so bash has read the whole script before any
# command runs (stdin is the piped script under `curl … | bash`).
main() {
set -Eeuo pipefail

REPO="${BIQ_REPO:-Bayes-IQ/biq}"
DEST="${BIQ_GET_DEST:-$HOME/biq}"
TTY="${BIQ_GET_TTY:-/dev/tty}"
BREW_PREFIXES="${BIQ_GET_BREW_PREFIXES:-/opt/homebrew /usr/local}"
MANUAL="https://github.com/$REPO#readme"

say()  { printf '\033[1mbiq:\033[0m %s\n' "$1"; }
stop() { printf 'biq: %s\n' "$1" >&2; exit "${2:-2}"; }

# [Y/n] prompt. BIQ_GET_YES=1 answers yes without touching the terminal; with no
# readable terminal the answer is no (GET-3).
ask() {
  [[ "${BIQ_GET_YES:-}" == 1 ]] && return 0
  local answer
  printf 'biq: %s [Y/n] ' "$1" >&2
  { read -r answer < "$TTY"; } 2>/dev/null || { echo >&2; return 1; }
  case "$answer" in ""|[Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}
# Interactive children read the terminal; everything else gets /dev/null so it
# can never consume the rest of a piped script.
interactive() { "$@" < "$TTY"; }
quiet() { "$@" < /dev/null; }

# Bash-only version check (python may be the thing that is missing).
version_at_least() {  # "<version text>" major minor
  [[ "$1" =~ ([0-9]+)\.([0-9]+) ]] || return 1
  local ma="${BASH_REMATCH[1]}" mi="${BASH_REMATCH[2]}"
  (( ma > $2 || (ma == $2 && mi >= $3) ))
}

BREW_PROBED=""   # set to the prefix when brew was not on the inherited PATH
find_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  local prefix
  for prefix in $BREW_PREFIXES; do
    if [[ -x "$prefix/bin/brew" ]]; then eval "$("$prefix/bin/brew" shellenv)"; BREW_PROBED="$prefix"; return 0; fi
  done
  return 1
}

say "Setting up biq. This takes a few minutes; you'll be asked before anything is installed."

# 1. macOS only.
[[ "$(uname -s)" == Darwin ]] || stop "this installer is for macOS. See $MANUAL for other systems."

# 2. Homebrew.
if ! find_brew; then
  ask "Homebrew (the Mac package manager) is needed. Install it now? It will ask for your Mac password." \
    || stop "Homebrew is required. Install it from https://brew.sh, then run this again."
  interactive /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || stop "Homebrew did not install." 1
  find_brew || stop "Homebrew installed but was not found. Open a new terminal window and run this again." 1
fi
# Homebrew's own "Next steps": put brew on PATH for new terminals (GET-4). Only
# when brew was not already on the inherited PATH; never otherwise.
if [[ -n "$BREW_PROBED" ]]; then
  shellenv_line="eval \"\$($BREW_PROBED/bin/brew shellenv)\""
  if ! grep -qxF "$shellenv_line" "$HOME/.zprofile" 2>/dev/null; then
    if ask "Add Homebrew to your terminal (Homebrew's recommended setup, one line in ~/.zprofile)?"; then
      printf '\n%s\n' "$shellenv_line" >> "$HOME/.zprofile"
      say "Added Homebrew to ~/.zprofile."
    else
      say "Skipped. biq works in this window; for new windows run: echo '$shellenv_line' >> ~/.zprofile"
    fi
  fi
fi

# 3. Missing tools, one question.
formulas=() casks=()
version_at_least "$(quiet node --version 2>/dev/null || true)" 22 19 || formulas+=(node)
version_at_least "$(quiet python3 --version 2>&1 || true)" 3 10 || formulas+=(python)
command -v gh >/dev/null 2>&1 || formulas+=(gh)
command -v claude >/dev/null 2>&1 || casks+=(claude-code)
command -v codex >/dev/null 2>&1 || formulas+=(codex)
if (( ${#formulas[@]} + ${#casks[@]} > 0 )); then
  missing="${formulas[*]+${formulas[*]}}${casks[*]+ ${casks[*]}}"; missing="${missing# }"
  cmdline="brew install ${formulas[*]+${formulas[*]}}"; (( ${#casks[@]} )) && cmdline+="; brew install --cask ${casks[*]}"
  ask "biq needs: $missing. Install with Homebrew?" \
    || stop "biq needs: $missing. Install them with: $cmdline — then run this again."
  if (( ${#formulas[@]} )); then
    say "Installing ${formulas[*]}..."
    quiet brew install "${formulas[@]}" || stop "brew install ${formulas[*]} failed." 1
  fi
  if (( ${#casks[@]} )); then
    say "Installing ${casks[*]}..."
    quiet brew install --cask "${casks[@]}" || stop "brew install --cask ${casks[*]} failed." 1
  fi
fi

# 4. GitHub sign-in (browser).
if ! quiet gh auth status >/dev/null 2>&1; then
  say "Opening GitHub in your browser. Click Authorize to continue."
  interactive gh auth login --web --git-protocol https --hostname github.com || stop "GitHub sign-in did not finish." 1
fi

# 5. Accept the invitation to the private repository, if one is pending.
repo_lc="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
while IFS= read -r invite; do
  [[ -n "$invite" ]] || continue
  quiet gh api -X PATCH "user/repository_invitations/$invite" >/dev/null || stop "Could not accept the invitation to $REPO." 1
  say "Accepted your invitation to $REPO."
done < <(quiet gh api --paginate user/repository_invitations \
  --jq ".[] | select((.repository.full_name | ascii_downcase) == \"$repo_lc\") | .id" 2>/dev/null || true)
if ! quiet gh repo view "$REPO" >/dev/null 2>&1; then
  login="$(quiet gh api user --jq .login 2>/dev/null || echo 'your GitHub account')"
  stop "You don't have access to $REPO yet. Ask Jamey to add $login, then run this again." 1
fi

# 6. Get or update the code.
is_our_clone() {
  quiet git -C "$DEST" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local origin
  origin="$(quiet git -C "$DEST" remote get-url origin 2>/dev/null | tr '[:upper:]' '[:lower:]')" || return 1
  origin="${origin%/}"; origin="${origin%.git}"
  [[ "$origin" == "https://github.com/$repo_lc" || "$origin" == "git@github.com:$repo_lc" ]]
}
if [[ ! -e "$DEST" ]]; then
  say "Downloading biq into $DEST..."
  quiet gh repo clone "$REPO" "$DEST" -- --quiet || stop "Could not download $REPO." 1
elif is_our_clone; then
  say "Updating biq in $DEST..."
  quiet git -C "$DEST" pull --ff-only --quiet || stop "Could not update $DEST (local changes?)." 1
else
  origin="$(quiet git -C "$DEST" remote get-url origin 2>/dev/null || echo 'not a git checkout')"
  stop "$DEST already exists and is not biq ($origin). Move it aside, then run this again."
fi

# 7. Install, linking the biq command into Homebrew's bin (already on PATH).
say "Installing biq..."
quiet bash "$DEST/install.sh" --link-into "$(brew --prefix)/bin" || stop "biq's installer stopped; see the message above." 1

# 8. Sign in to Claude Code and Codex if needed (browser).
if command -v claude >/dev/null 2>&1 && ! quiet claude auth status >/dev/null 2>&1; then
  say "Opening Claude sign-in in your browser."
  interactive claude auth login || say "Claude sign-in did not finish; biq will remind you."
fi
if command -v codex >/dev/null 2>&1 && ! quiet codex login status >/dev/null 2>&1; then
  say "Opening Codex sign-in in your browser."
  interactive codex login || say "Codex sign-in did not finish; biq will remind you."
fi

say "All set. In any project folder, type: biq"
if { [[ -t 1 ]] || [[ "${BIQ_GET_FORCE_LAUNCH:-}" == 1 ]]; } && { : < "$TTY"; } 2>/dev/null; then
  say "Starting biq..."
  exec "$DEST/bin/biq" < "$TTY"
fi
}

main "$@"
