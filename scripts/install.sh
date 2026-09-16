#!/usr/bin/env bash
#
# Supercharge AI public installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/iotserver24/supercharge-releases/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/iotserver24/supercharge-releases/main/scripts/install.sh | bash -s 1.0.5
#   SUPERCHARGE_VERSION=1.0.5 bash scripts/install.sh
#
# Windows (Git Bash / MSYS2): same curl | bash flow.
# Native Windows: use install.ps1 instead.

set -euo pipefail

TARGET="${1:-${SUPERCHARGE_VERSION:-}}"
REPO="${SUPERCHARGE_GITHUB_REPO:-iotserver24/supercharge-releases}"
BIN_DIR="${SUPERCHARGE_BIN_DIR:-$HOME/.local/bin}"
CONFIG_HOME="${SUPERCHARGE_HOME:-$HOME/.supercharge}"
DOWNLOAD_DIR="${SUPERCHARGE_DOWNLOAD_DIR:-$CONFIG_HOME/downloads}"

use_color=0
if [ -z "${NO_COLOR:-}" ] && { [ -t 2 ] || [ -n "${FORCE_COLOR:-}" ]; }; then
  use_color=1
fi

if [ "$use_color" = 1 ]; then
  c_reset=$'\033[0m'
  c_bold=$'\033[1m'
  c_dim=$'\033[2m'
  c_cyan=$'\033[36m'
  c_green=$'\033[32m'
  c_yellow=$'\033[33m'
  c_red=$'\033[31m'
else
  c_reset="" c_bold="" c_dim="" c_cyan="" c_green="" c_yellow="" c_red=""
fi

say() { printf '%s\n' "$*" >&2; }

banner() {
  say ""
  say "${c_bold}${c_cyan}  Supercharge AI installer${c_reset}"
  say "${c_dim}  ────────────────────────${c_reset}"
}

step() {
  local n="$1" label="$2" detail="${3:-}"
  if [ -n "$detail" ]; then
    say "  ${c_cyan}${n}/4${c_reset}  ${c_bold}${label}${c_reset}  ${c_dim}${detail}${c_reset}"
  else
    say "  ${c_cyan}${n}/4${c_reset}  ${c_bold}${label}${c_reset}"
  fi
}

ok() { say "       ${c_green}✓${c_reset} ${1}"; }
warn() { say "       ${c_yellow}!${c_reset} ${1}"; }
die() {
  say "       ${c_red}✗${c_reset} ${1}"
  shift
  for line in "$@"; do
    say "         ${c_dim}${line}${c_reset}"
  done
  exit 1
}

if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  banner
  die "Invalid version format: $TARGET" "Expected X.Y.Z or vX.Y.Z"
fi
TARGET="${TARGET#v}"

downloader=""
if command -v curl >/dev/null 2>&1; then
  downloader="curl"
elif command -v wget >/dev/null 2>&1; then
  downloader="wget"
else
  banner
  die "Either curl or wget is required."
fi

# Manual retries work with older curl (including macOS), without --retry-all-errors.
# Always restart the staged file: resuming across redirects/releases can mix bytes.
DOWNLOAD_ERROR=""
http_download_error() {
  case "$1" in
    404) DOWNLOAD_ERROR="HTTP 404: release asset not found (or repository is private). Check the version and platform." ;;
    401) DOWNLOAD_ERROR="HTTP 401: authentication required; this release is not publicly accessible." ;;
    403) DOWNLOAD_ERROR="HTTP 403: access denied by GitHub or a proxy (possibly rate limited). Check access and any rate-limit response above." ;;
    429) DOWNLOAD_ERROR="HTTP 429: rate limited. Wait before trying again." ;;
    *) DOWNLOAD_ERROR="HTTP $1: server rejected the download." ;;
  esac
}

retryable_http_status() {
  case "$1" in 408|429|500|502|503|504) return 0 ;; *) return 1 ;; esac
}

# wget's --https-only does not protect non-recursive redirects. Follow redirects
# ourselves so every requested URL is HTTPS, with certificate verification on.
wget_download_attempt() {
  local url="$1" output="$2" headers="${2}.wget-log" redirects=0 rc status location line origin
  WGET_STATUS=""
  while :; do
    case "$url" in
      https://*) ;;
      *) DOWNLOAD_ERROR="Refusing a non-HTTPS wget redirect."; return 1 ;;
    esac
    rm -f "$output"
    if wget --check-certificate --progress=bar:force --server-response --max-redirect=0 --tries=1 \
      --connect-timeout=30 --dns-timeout=30 --read-timeout=120 -O "$output" "$url" 2>"$headers"; then
      rc=0
    else
      rc=$?
    fi
    # Include native diagnostics, but keep status parsing independent of locale.
    while IFS= read -r line; do say "$line"; done < "$headers"
    status="$(awk '$1 ~ /^HTTP\// { code=$2 } END { print code }' "$headers")"
    location="$(awk 'tolower($1) == "location:" { value=$2 } END { sub(/\r$/, "", value); print value }' "$headers")"
    rm -f "$headers"
    WGET_STATUS="$status"
    case "$status" in
      301|302|303|307|308)
        if [ -z "$location" ] || [ "$redirects" -ge 10 ]; then
          DOWNLOAD_ERROR="wget exit $rc: missing redirect location or too many redirects."
          return 1
        fi
        case "$location" in
          https://*) url="$location" ;;
          //*) url="https:$location" ;;
          /*) origin="${url#https://}"; url="https://${origin%%/*}$location" ;;
          *) DOWNLOAD_ERROR="wget: refusing non-HTTPS or unsupported relative redirect."; return 1 ;;
        esac
        redirects=$((redirects + 1))
        ;;
      *) return "$rc" ;;
    esac
  done
}

download_file() {
  local url="$1" output="$2" attempt rc status mode retry_kind curl_error=""
  local -a protocol_args
  DOWNLOAD_ERROR=""
  if [ "$downloader" = curl ]; then
    for mode in default http1; do
      protocol_args=()
      [ "$mode" = default ] || protocol_args=(--http1.1)
      attempt=1
      while :; do
        rm -f "$output"
        if status="$(curl -q -fL --progress-bar --proto '=https' --proto-redir '=https' \
          --connect-timeout 30 --max-time 1800 --write-out '%{http_code}' \
          ${protocol_args[@]+"${protocol_args[@]}"} -o "$output" "$url")"; then
          return 0
        else
          rc=$?
        fi
        retry_kind=""
        if [ "$rc" = 22 ]; then
          http_download_error "$status"
          if retryable_http_status "$status"; then retry_kind=http; fi
        else
          case "$rc" in
            5|6|7|16|18|28|35|52|55|56|92|95)
              DOWNLOAD_ERROR="Network/TLS/protocol download failure (curl exit $rc; HTTP ${status:-000})."
              retry_kind=network ;;
            51|60|77|83|90|91)
              DOWNLOAD_ERROR="TLS certificate verification failed (curl exit $rc). Check the system CA certificates, clock, and HTTPS proxy; verification was not disabled." ;;
            23|26) DOWNLOAD_ERROR="Local file read/write failure (curl exit $rc). Check disk space and permissions." ;;
            *) DOWNLOAD_ERROR="Download failed (curl exit $rc; HTTP ${status:-000}); see curl diagnostics above." ;;
          esac
        fi
        # Keep the client exit code even for HTTP errors.
        if [ "$rc" = 22 ]; then DOWNLOAD_ERROR="$DOWNLOAD_ERROR (curl exit $rc)"; fi
        warn "$DOWNLOAD_ERROR"
        [ -n "$retry_kind" ] || return 1
        [ "$attempt" -lt 3 ] || break
        warn "Retrying download in $attempt seconds (attempt $((attempt + 1))/3, curl $mode)."
        sleep "$attempt"
        attempt=$((attempt + 1))
      done
      # Changing HTTP clients/protocols will not fix an HTTP rejection.
      [ "$retry_kind" = network ] || return 1
      if [ "$mode" = default ]; then
        warn "Retrying with curl HTTP/1.1 after repeated transport failures."
      fi
    done
    curl_error="$DOWNLOAD_ERROR"
    command -v wget >/dev/null 2>&1 || return 1
    warn "curl transport attempts exhausted; trying wget over verified HTTPS."
  fi

  attempt=1
  while :; do
    rm -f "$output"
    DOWNLOAD_ERROR=""
    if wget_download_attempt "$url" "$output"; then return 0; else rc=$?; fi
    retry_kind=""
    if [ -z "$DOWNLOAD_ERROR" ]; then
      if [[ "$WGET_STATUS" = [45][0-9][0-9] ]]; then
        http_download_error "$WGET_STATUS"
        if retryable_http_status "$WGET_STATUS"; then retry_kind=http; fi
      else
        case "$rc" in
          4) DOWNLOAD_ERROR="Network download failure."; retry_kind=network ;;
          5) DOWNLOAD_ERROR="TLS certificate verification failed; verification was not disabled." ;;
          3) DOWNLOAD_ERROR="Local file read/write failure. Check disk space and permissions." ;;
          *) DOWNLOAD_ERROR="Download failed; see wget diagnostics above." ;;
        esac
      fi
    fi
    DOWNLOAD_ERROR="${curl_error:+$curl_error }$DOWNLOAD_ERROR (wget exit $rc)"
    warn "$DOWNLOAD_ERROR"
    [ -n "$retry_kind" ] && [ "$attempt" -lt 3 ] || return 1
    warn "Retrying download in $attempt seconds (attempt $((attempt + 1))/3, wget)."
    sleep "$attempt"
    attempt=$((attempt + 1))
  done
}

download_string() {
  local url="$1"
  if [ "$downloader" = "curl" ]; then
    curl -fsSL "$url" 2>/dev/null || true
  else
    wget -q -O - "$url" 2>/dev/null || true
  fi
}

# Quote literal paths, not shell expressions. fish has different single-quote
# escaping rules; neither form evaluates $, backticks, or command substitutions.
quote_path() {
  local value="$1" char
  # Avoid quote-sensitive pattern substitutions: Bash 3.2 parses them differently.
  printf '%s' "'"
  while [ -n "$value" ]; do
    char="${value:0:1}"
    value="${value:1}"
    case "$char" in
      "'")
        if [ "${2:-}" = fish ]; then
          printf '%s' "\\'"
        else
          printf '%s' "'\\''"
        fi
        ;;
      '\')
        if [ "${2:-}" = fish ]; then
          printf '%s' '\\'
        else
          printf '%s' "$char"
        fi
        ;;
      *) printf '%s' "$char" ;;
    esac
  done
  printf '%s' "'"
}

path_block() {
  local quoted
  quoted="$(quote_path "$BIN_DIR" "$shell_name")"
  printf '%s\n' '# >>> Supercharge AI PATH >>>'
  if [ "$shell_name" = fish ]; then
    printf 'if not contains -- %s $PATH\n    set -gx PATH %s $PATH\nend\n' "$quoted" "$quoted"
  else
    printf 'case ":${PATH-}:" in\n  *:%s:*) ;;\n  *) export PATH=%s"${PATH:+:$PATH}" ;;\nesac\n' "$quoted" "$quoted"
  fi
  printf '%s\n' '# <<< Supercharge AI PATH <<<'
}

# Replace only our marked block, keeping all other content. Refuse malformed
# markers and symlinks rather than risking damage to hand-managed dotfiles.
update_shell_config() {
  local rc="$1" parent tmp block backup
  parent="${rc%/*}"
  if [[ "$rc" != /* ]] || [ -L "$rc" ] ||
    { [ -e "$rc" ] && { [ ! -f "$rc" ] || [ ! -O "$rc" ] || [ ! -w "$rc" ]; }; }; then
    warn "Cannot safely update $rc; add PATH manually."
    return 1
  fi
  if ! mkdir -p "$parent" || [ ! -O "$parent" ] || [ ! -w "$parent" ]; then
    warn "Cannot write shell config directory $parent; add PATH manually."
    return 1
  fi
  tmp="$(mktemp "$rc.supercharge.tmp.XXXXXX")" || { warn "Cannot prepare $rc"; return 1; }
  block="$(mktemp "$rc.supercharge.block.XXXXXX")" || { rm -f "$tmp"; warn "Cannot prepare $rc"; return 1; }
  if ! path_block > "$block"; then
    rm -f "$tmp" "$block"
    warn "Cannot prepare PATH block for $rc"
    return 1
  fi
  if [ -e "$rc" ]; then
    # Preserve the existing permissions when atomically replacing the file.
    if ! cp -p "$rc" "$tmp" || ! awk '
      NR == FNR { block = block $0 "\n"; next }
      $0 == "# >>> Supercharge AI PATH >>>" {
        if (inside) { bad = 1; exit }
        inside = 1
        if (!found++) printf "%s", block
        next
      }
      $0 == "# <<< Supercharge AI PATH <<<" {
        if (!inside) { bad = 1; exit }
        inside = 0; next
      }
      !inside { print }
      END {
        if (inside || bad) exit 1
        if (!found) printf "\n%s", block
      }
    ' "$block" "$rc" > "$tmp"; then
      rm -f "$tmp" "$block"
      warn "Cannot update $rc (check permissions or malformed Supercharge PATH markers)."
      return 1
    fi
    if cmp -s "$rc" "$tmp"; then
      rm -f "$tmp" "$block"
      ok "PATH already configured in $rc"
      return 0
    fi
    backup="$(mktemp "$rc.supercharge.bak.XXXXXX")" || {
      rm -f "$tmp" "$block"; warn "Cannot back up $rc; left unchanged."; return 1;
    }
    if ! cp -p "$rc" "$backup"; then
      rm -f "$tmp" "$block" "$backup"
      warn "Cannot back up $rc; left unchanged."
      return 1
    fi
    ok "Backup: $backup"
  elif ! cp "$block" "$tmp"; then
    rm -f "$tmp" "$block"
    warn "Cannot prepare $rc"
    return 1
  fi
  rm -f "$block"
  if ! mv -f "$tmp" "$rc"; then
    rm -f "$tmp"
    warn "Cannot save $rc; add PATH manually."
    return 1
  fi
  ok "PATH configured in $rc"
}

configure_shell_path() {
  local login_file config_dir result=0
  case "$shell_name" in
    bash)
      update_shell_config "$HOME/.bashrc" || result=1
      # Bash reads only the first existing login file. Do not create a new
      # higher-priority file that hides the user's current login setup.
      login_file="$HOME/.bash_profile"
      for login_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [ -e "$login_file" ] || [ -L "$login_file" ]; then break; fi
      done
      if [ ! -e "$login_file" ] && [ ! -L "$login_file" ]; then login_file="$HOME/.bash_profile"; fi
      update_shell_config "$login_file" || result=1
      ;;
    zsh)
      config_dir="${ZDOTDIR:-$HOME}"
      update_shell_config "$config_dir/.zshrc" || result=1
      update_shell_config "$config_dir/.zprofile" || result=1
      ;;
    fish)
      config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
      update_shell_config "$config_dir/fish/config.fish" || result=1
      ;;
    *)
      warn "Unsupported or unknown shell (${SHELL:-unset}); add $BIN_DIR to PATH manually."
      return 1
      ;;
  esac
  return "$result"
}

# A child installer cannot change its parent's PATH. Existing PATH directories
# under HOME can make commands available immediately, without touching system
# directories or shadowing an unrelated command anywhere on PATH.
link_on_current_path() {
  local name="$1" resolved entry physical home_physical remaining
  resolved="$(type -P "$name" || true)"
  if [ -n "$resolved" ]; then
    if [ "$resolved" -ef "$BIN_DIR/$name" ]; then return 0; fi
    warn "Keeping existing command $resolved; use the absolute Supercharge path."
    return 1
  fi
  home_physical="$(cd "$HOME" && pwd -P)" || return 1
  [ "$home_physical" != / ] || return 1
  remaining="${PATH:-}"
  while :; do
    entry="${remaining%%:*}"
    if [[ "$entry" = /* ]] && [ -d "$entry" ] && [ -O "$entry" ] && [ -w "$entry" ]; then
      physical="$(cd "$entry" && pwd -P)" || physical=""
      case "$physical" in
        "$home_physical"/*)
          if [ ! -e "$entry/$name" ] && [ ! -L "$entry/$name" ] &&
            ln -s "$BIN_DIR/$name" "$entry/$name" 2>/dev/null; then
            ok "Linked $entry/$name (already on PATH)"
            return 0
          fi
          ;;
      esac
    fi
    [[ "$remaining" = *:* ]] || break
    remaining="${remaining#*:}"
  done
  return 1
}

banner

case "$(uname -s)" in
  Darwin) os="macos" ;;
  Linux) os="linux" ;;
  MINGW* | MSYS* | CYGWIN*) os="windows" ;;
  *) die "Unsupported OS: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64 | amd64 | AMD64) arch="x86_64" ;;
  arm64 | aarch64 | ARM64) arch="aarch64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

if [ "$os" = "macos" ] && [ "$arch" = "x86_64" ]; then
  sysctl_bin="$(command -v sysctl || echo /usr/sbin/sysctl)"
  if [ "$("$sysctl_bin" -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
    warn "Apple Silicon detected (Rosetta shell); installing native arm64 build."
    arch="aarch64"
  fi
fi

platform="${os}-${arch}"
ext=""
[ "$os" = "windows" ] && ext=".exe"

step 1 "Version"
if [ -z "$TARGET" ]; then
  TARGET="$(download_string "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\?\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$TARGET" ]; then
    warn "GitHub API unavailable; falling back to release asset."
    TARGET="$(download_string "https://github.com/${REPO}/releases/latest/download/version" | tr -d '[:space:]')"
  fi
fi

if [ -z "$TARGET" ]; then
  die "Failed to resolve latest version from ${REPO}"
fi
ok "${TARGET}  (${platform})"

tag="v${TARGET#v}"
asset="supercharge-${platform}${ext}"
base_url="https://github.com/${REPO}/releases/download/${tag}"

# PATH entries cannot represent colons or newlines. Resolve relative install
# directories once so startup files never depend on a future working directory.
case "$BIN_DIR" in
  *:* | *$'\n'* | *$'\r'*) die "SUPERCHARGE_BIN_DIR must not contain colons or newlines." ;;
esac
mkdir -p "$DOWNLOAD_DIR" "$BIN_DIR" "$CONFIG_HOME"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
case "$BIN_DIR" in
  *:* | *$'\n'* | *$'\r'*) die "Resolved SUPERCHARGE_BIN_DIR must not contain colons or newlines." ;;
esac
binary_path="${DOWNLOAD_DIR}/supercharge-${TARGET}-${platform}${ext}"
binary_tmp="${binary_path}.tmp.$$"

step 2 "Download" "${asset}"
if ! download_file "${base_url}/${asset}" "$binary_tmp"; then
  rm -f "$binary_tmp"
  die "Download failed" "${base_url}/${asset}" "$DOWNLOAD_ERROR"
fi
ok "saved"

step 3 "Install" "${BIN_DIR}"
if [ "$os" != "windows" ]; then
  chmod +x "$binary_tmp"
  if ! "$binary_tmp" --version >/dev/null 2>&1; then
    rm -f "$binary_tmp"
    die "Downloaded binary failed to run."
  fi
fi

mv -f "$binary_tmp" "$binary_path"

if [ "$os" = "windows" ]; then
  cp -f "$binary_path" "$BIN_DIR/supercharge.exe"
  cp -f "$binary_path" "$BIN_DIR/sc.exe"
else
  install -m 0755 "$binary_path" "$BIN_DIR/supercharge"
  if [ ! -e "$BIN_DIR/sc" ] && [ ! -L "$BIN_DIR/sc" ]; then
    ln -s supercharge "$BIN_DIR/sc"
  elif [ ! "$BIN_DIR/sc" -ef "$BIN_DIR/supercharge" ]; then
    warn "Keeping unrelated $BIN_DIR/sc; use supercharge instead."
  fi
fi
ok "${BIN_DIR}/supercharge${ext}"

step 4 "PATH"
# SHELL identifies the user's shell even when the installer is piped to bash.
shell_name="${SHELL:-}"
shell_name="${shell_name##*/}"
shell_name="${shell_name%.exe}"
if [ "${SUPERCHARGE_NO_MODIFY_PATH:-0}" = 1 ]; then
  ok "Automatic PATH setup disabled (SUPERCHARGE_NO_MODIFY_PATH=1)"
else
  if configure_shell_path; then
    ok "Persistent PATH setup complete; open a new terminal to load it."
  else
    warn "Persistent PATH setup incomplete; see the warnings above."
  fi
  if [ "$os" != windows ]; then
    link_on_current_path supercharge || true
    if [ "$BIN_DIR/sc" -ef "$BIN_DIR/supercharge" ]; then link_on_current_path sc || true; fi
  fi
fi

resolved="$(type -P "supercharge${ext}" || true)"
if [ -n "$resolved" ] && [ "$resolved" -ef "$BIN_DIR/supercharge${ext}" ]; then
  ok "supercharge is available on the inherited PATH (shell aliases or cached commands may need clearing)."
else
  warn "This installer cannot change the current parent shell's PATH."
  case "$shell_name" in
    bash | zsh)
      say "         Run in your current shell:"
      say "         export PATH=$(quote_path "$BIN_DIR")\"\${PATH:+:\$PATH}\""
      ;;
    fish)
      say "         Run in your current shell:"
      say "         set -gx PATH $(quote_path "$BIN_DIR" fish) \$PATH"
      ;;
    *) say "         Add $BIN_DIR to PATH using your shell's syntax." ;;
  esac
fi
if [ "$os" = windows ]; then
  say "         For cmd.exe / PowerShell PATH setup, use install.ps1 instead."
fi

say ""
say "  ${c_green}${c_bold}Installed Supercharge AI ${TARGET}${c_reset}"
say "  ${c_dim}Config: ${CONFIG_HOME}${c_reset}"
say ""
say "  Start now (works without changing PATH):"
say "    ${c_bold}$(quote_path "$BIN_DIR/supercharge${ext}" "$shell_name")${c_reset}"
say "  Once PATH is loaded: supercharge (or sc, if no other command uses that name)."
say ""
