#!/usr/bin/env bash
#############################################################################
# install.sh — one-time bootstrap for the infinite-opencode package.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/L42-AI/infcode-install/main/install.sh | bash
#   ./install.sh                                (from inside an existing checkout)
#
# The one-liner fetches THIS script from the public `infcode-install` repo;
# the script then clones the package itself (default INFCODE_REPO_URL, a
# private repo — git uses your stored credentials).
#
# Steps:
#   1. Clone the repo into INFCODE_HOME
#      (default ${XDG_DATA_HOME:-$HOME/.local/share}/infinite-opencode);
#      updates the existing checkout instead when already cloned.
#   2. Symlink bin/infcode into a PATH directory (default ~/.local/bin).
#   3. Add the bin directory to PATH when missing: appends a guarded,
#      idempotent block to ~/.zshrc / ~/.bashrc / ~/.profile.
#   4. Run `infcode init --no-project --no-dev` (opencode CLI + global sync).
#   5. Print next steps.
#
# Version pinning:
#   INFCODE_VERSION=<tag-or-branch>  pin the install to a specific tag or
#                                    branch (default: the latest release tag,
#                                    or the default branch when no tags exist).
#   A pinned install updates by RE-RUNNING the installer; `infcode update`
#   (git pull) only applies to branch checkouts.
#
# Environment overrides:
#   INFCODE_REPO_URL   repo URL to clone (default: placeholder from README)
#   INFCODE_VERSION    tag or branch to install (default: latest release tag)
#   INFCODE_HOME       install location (default: ~/.local/share/infinite-opencode)
#   INFCODE_BIN_DIR    symlink directory (default: ~/.local/bin)
#
# Idempotent: safe to re-run; real files are never overwritten.
# Pure bash 3.2+ (macOS default). No external deps beyond git.
#############################################################################

set -euo pipefail

DEFAULT_REPO_URL="https://github.com/L42-AI/infinite-opencode.git"
DEFAULT_HOME="${XDG_DATA_HOME:-${HOME:-}/.local/share}/infinite-opencode"
DEFAULT_BIN_DIR="${HOME:-}/.local/bin"
RC_MARKER_START="# >>> infinite-opencode >>>"
RC_MARKER_END="# <<< infinite-opencode <<<"

# --- logging ---------------------------------------------------------------
# Self-contained: lib/lib.sh may not exist yet when this script runs before
# the repo is cloned, so it cannot be sourced here. All logging goes to
# stderr: stdout is captured by command substitution (e.g. resolve_version).
info() { printf '%s\n' "[info] $*" >&2; }
warn() { printf '%s\n' "[warn] $*" >&2; }
error() { printf '%s\n' "[error] $*" >&2; }

# --- usage -----------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: install.sh [-h|--help]

Bootstrap the infinite-opencode package:
  1. Clone the repo into INFCODE_HOME (default ~/.local/share/infinite-opencode);
     update the existing checkout instead when already cloned.
  2. Symlink bin/infcode into a PATH directory (default ~/.local/bin).
  3. Add the bin directory to PATH when missing (~/.zshrc / ~/.bashrc / ~/.profile).
  4. Run `infcode init --no-project --no-dev` (opencode CLI + global config sync).
  5. Print next steps.

Environment overrides:
  INFCODE_REPO_URL   repo URL to clone
  INFCODE_VERSION    tag or branch to install (default: latest release tag)
  INFCODE_HOME       install location (default: ~/.local/share/infinite-opencode)
  INFCODE_BIN_DIR    symlink directory (default: ~/.local/bin)
EOF
}

# --- step 1: resolve the install location -----------------------------------

# True when this script runs from inside a checkout: install.sh lives at the
# repo root, so bin/infcode and .git must be its siblings. A .git file (not
# just a directory) is accepted so worktrees and submodules also match.
already_in_repo() {
    [ -f "$SCRIPT_DIR/bin/infcode" ] && [ -e "$SCRIPT_DIR/.git" ]
}

resolve_home() {
    if already_in_repo; then
        INFCODE_HOME="$SCRIPT_DIR"
        info "Running from inside the repo — using $INFCODE_HOME"
    elif [ -n "${INFCODE_HOME:-}" ]; then
        info "Using INFCODE_HOME=$INFCODE_HOME"
    else
        INFCODE_HOME="$DEFAULT_HOME"
        info "Using default install location $INFCODE_HOME"
    fi
    export INFCODE_HOME
}

# --- step 2: clone or update the repo ---------------------------------------

# Resolve the ref to install: INFCODE_VERSION wins; otherwise the latest
# release tag (semver-sorted); empty means "default branch".
resolve_version() {
    local repo_url="$1" tag
    if [ -n "${INFCODE_VERSION:-}" ]; then
        echo "$INFCODE_VERSION"
        return 0
    fi
    tag="$(git ls-remote --tags --refs "$repo_url" 2>/dev/null \
        | awk -F/ '{print $NF}' \
        | sort -V \
        | tail -n 1)"
    if [ -n "$tag" ]; then
        info "Latest release tag: $tag"
        echo "$tag"
    else
        info "No release tags found — installing the default branch"
        echo ""
    fi
}

ensure_repo() {
    local repo_url="${INFCODE_REPO_URL:-$DEFAULT_REPO_URL}"
    local version

    if [ -d "$INFCODE_HOME/.git" ]; then
        info "Repo already cloned — updating existing checkout"
        if [ "$(git -C "$INFCODE_HOME" rev-parse --abbrev-ref HEAD)" = "HEAD" ]; then
            info "  Pinned checkout (detached HEAD) — re-run the installer to update (INFCODE_VERSION moves the pin)."
        elif git -C "$INFCODE_HOME" pull --ff-only; then
            info "  pull: OK"
        else
            warn "  git pull failed (dirty tree or network?) — continuing with the existing checkout"
        fi
        return 0
    fi

    if [ -e "$INFCODE_HOME" ]; then
        error "Install location exists but is not a git repo: $INFCODE_HOME"
        error "Move it away or set INFCODE_HOME to a different location."
        return 1
    fi

    version="$(resolve_version "$repo_url")"
    if [ -n "$version" ]; then
        info "Cloning $repo_url (tag/branch: $version) into $INFCODE_HOME"
        if ! git clone --branch "$version" "$repo_url" "$INFCODE_HOME"; then
            error "Clone failed — check INFCODE_REPO_URL / INFCODE_VERSION (ref must exist)."
            return 1
        fi
    else
        info "Cloning $repo_url into $INFCODE_HOME"
        if ! git clone "$repo_url" "$INFCODE_HOME"; then
            error "Clone failed — check INFCODE_REPO_URL (the default is a placeholder)."
            return 1
        fi
    fi
    return 0
}

# --- step 3: symlink bin/infcode into a PATH directory ----------------------

link_infcode() {
    local bin_dir="${INFCODE_BIN_DIR:-$DEFAULT_BIN_DIR}"
    local target="$bin_dir/infcode"
    local source="$INFCODE_HOME/bin/infcode"

    if [ ! -f "$source" ]; then
        error "bin/infcode not found in $INFCODE_HOME — is this the right repo?"
        return 1
    fi
    if [ ! -x "$source" ]; then
        error "bin/infcode is not executable: $source"
        error "Fix it with: chmod +x $source"
        return 1
    fi

    if [ -L "$target" ]; then
        if [ "$(readlink "$target")" = "$source" ]; then
            info "Symlink already in place: $target -> $source"
            return 0
        fi
        warn "Replacing existing symlink $target (it pointed elsewhere)"
        rm -f "$target"
    elif [ -e "$target" ]; then
        error "Refusing to overwrite a real file: $target"
        error "Remove it, or set INFCODE_BIN_DIR to a different directory."
        return 1
    fi

    if [ ! -d "$bin_dir" ]; then
        info "Creating $bin_dir"
        if ! mkdir -p "$bin_dir"; then
            error "Cannot create $bin_dir — set INFCODE_BIN_DIR to a writable directory."
            return 1
        fi
    fi

    if ! ln -s "$source" "$target"; then
        error "Cannot create symlink $target (permission denied?)"
        error "Try: ln -s $source $target"
        return 1
    fi
    info "Linked $target -> $source"
    return 0
}

# --- step 4: add the bin directory to PATH when missing ----------------------

detect_rc() {
    case "${SHELL##*/}" in
        zsh)  printf '%s\n' "$HOME/.zshrc" ;;
        bash) printf '%s\n' "$HOME/.bashrc" ;;
        *)    printf '%s\n' "$HOME/.profile" ;;
    esac
}

ensure_path() {
    local bin_dir="${INFCODE_BIN_DIR:-$DEFAULT_BIN_DIR}"

    case ":$PATH:" in
        *":$bin_dir:"*) info "$bin_dir already on PATH"; return 0 ;;
    esac

    local rc
    rc="$(detect_rc)"
    if grep -qF "$RC_MARKER_START" "$rc" 2>/dev/null; then
        info "PATH already configured in $rc"
        return 0
    fi

    {
        printf '\n%s  (managed by install.sh — safe to remove)\n' "$RC_MARKER_START"
        printf 'export PATH="%s:$PATH"\n' "$bin_dir"
        printf '%s\n' "$RC_MARKER_END"
    } >> "$rc"
    info "Added $bin_dir to PATH in $rc"
    warn "Restart your shell, or run: source $rc"
    return 0
}

# --- step 5: bootstrap the global setup --------------------------------------

bootstrap() {
    info "Running infcode init --no-project --no-dev (opencode CLI + global config sync)"
    if ! "$INFCODE_HOME/bin/infcode" init --no-project --no-dev; then
        error "infcode init --no-project --no-dev failed — see output above."
        return 1
    fi
    return 0
}

# --- step 6: next steps ------------------------------------------------------

print_next_steps() {
    local link_path="$1"
    cat <<EOF

Installation complete.

Next steps:
  infcode init my-project    create a new project (uv init + OAC + dev-env)
  cd my-project && infcode run
  infcode validate           re-check the installed setup
  infcode help               show all commands
  infcode uninstall          remove the install (--purge removes data too)

The infcode CLI is linked at: $link_path
EOF
}

# --- entry point --------------------------------------------------------------

main() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    case "${1:-}" in
        -h|--help) usage; return 0 ;;
        "") ;;
        *)
            error "Unknown argument: $1"
            usage >&2
            return 1
            ;;
    esac

    info "infinite-opencode bootstrap"
    resolve_home || return 1
    ensure_repo || return 1
    link_infcode || return 1
    ensure_path || return 1
    bootstrap || return 1
    print_next_steps "${INFCODE_BIN_DIR:-$DEFAULT_BIN_DIR}/infcode"
    return 0
}

main "$@"
