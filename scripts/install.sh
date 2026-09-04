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

download_file() {
  local url="$1" output="$2"
  if [ "$downloader" = "curl" ]; then
    curl -fL --progress-bar -o "$output" "$url"
  else
    wget --progress=bar:force -O "$output" "$url"
  fi
}

download_string() {
  local url="$1"
  if [ "$downloader" = "curl" ]; then
    curl -fsSL "$url" 2>/dev/null || true
  else
    wget -q -O - "$url" 2>/dev/null || true
  fi
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

mkdir -p "$DOWNLOAD_DIR" "$BIN_DIR" "$CONFIG_HOME"
binary_path="${DOWNLOAD_DIR}/supercharge-${TARGET}-${platform}${ext}"
binary_tmp="${binary_path}.tmp.$$"

step 2 "Download" "${asset}"
if ! download_file "${base_url}/${asset}" "$binary_tmp"; then
  rm -f "$binary_tmp"
  die "Download failed" "${base_url}/${asset}" "This platform may not be published yet: https://github.com/${REPO}/releases/tag/${tag}"
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
  ln -sfn supercharge "$BIN_DIR/sc"
fi
ok "${BIN_DIR}/supercharge${ext}"
ok "${BIN_DIR}/sc${ext}"

step 4 "PATH"
path_ok=0
case ":${PATH}:" in
  *":${BIN_DIR}:"*) path_ok=1 ;;
esac
if [ "$path_ok" = 1 ]; then
  ok "already on PATH"
else
  warn "not on PATH in this shell"
  say "         ${c_dim}export PATH=\"${BIN_DIR}:\$PATH\"${c_reset}"
  if [ "$os" = "windows" ]; then
    say "         ${c_dim}Add %USERPROFILE%\\.local\\bin for cmd.exe / PowerShell.${c_reset}"
  fi
fi

say ""
say "  ${c_green}${c_bold}Installed Supercharge AI ${TARGET}${c_reset}"
say "  ${c_dim}Config: ${CONFIG_HOME}${c_reset}"
say ""
say "  Start:"
say "    ${c_bold}supercharge${c_reset}"
say "    ${c_bold}sc${c_reset}"
say ""
