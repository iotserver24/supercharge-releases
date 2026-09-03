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

if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid version format: $TARGET (expected X.Y.Z or vX.Y.Z)" >&2
  exit 1
fi
TARGET="${TARGET#v}"

downloader=""
if command -v curl >/dev/null 2>&1; then
  downloader="curl"
elif command -v wget >/dev/null 2>&1; then
  downloader="wget"
else
  echo "Either curl or wget is required." >&2
  exit 1
fi

download_file() {
  local url="$1" output="$2"
  echo "Downloading ${url}..." >&2
  if [ "$downloader" = "curl" ]; then
    # --progress-bar works in piped/CI terminals; -f still fails on HTTP errors.
    curl -fL --progress-bar -o "$output" "$url"
  else
    wget --progress=bar:force -O "$output" "$url"
  fi
}

# Tolerate HTTP errors (e.g. GitHub API 403 rate limits) so callers can fall back.
download_string() {
  local url="$1"
  if [ "$downloader" = "curl" ]; then
    curl -fsSL "$url" 2>/dev/null || true
  else
    wget -q -O - "$url" 2>/dev/null || true
  fi
}

case "$(uname -s)" in
  Darwin) os="macos" ;;
  Linux) os="linux" ;;
  MINGW* | MSYS* | CYGWIN*) os="windows" ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64 | amd64 | AMD64) arch="x86_64" ;;
  arm64 | aarch64 | ARM64) arch="aarch64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [ "$os" = "macos" ] && [ "$arch" = "x86_64" ]; then
  sysctl_bin="$(command -v sysctl || echo /usr/sbin/sysctl)"
  if [ "$("$sysctl_bin" -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
    echo "Apple Silicon detected (Rosetta shell); installing native arm64 build." >&2
    arch="aarch64"
  fi
fi

platform="${os}-${arch}"
ext=""
[ "$os" = "windows" ] && ext=".exe"

if [ -z "$TARGET" ]; then
  echo "Fetching latest release from ${REPO}..." >&2
  TARGET="$(download_string "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\?\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$TARGET" ]; then
    echo "GitHub API unavailable (rate limited or down); falling back to release asset." >&2
    TARGET="$(download_string "https://github.com/${REPO}/releases/latest/download/version" | tr -d '[:space:]')"
  fi
fi

if [ -z "$TARGET" ]; then
  echo "Failed to resolve latest version from ${REPO}" >&2
  exit 1
fi

tag="v${TARGET#v}"
asset="supercharge-${platform}${ext}"
base_url="https://github.com/${REPO}/releases/download/${tag}"

mkdir -p "$DOWNLOAD_DIR" "$BIN_DIR" "$CONFIG_HOME"
binary_path="${DOWNLOAD_DIR}/supercharge-${TARGET}-${platform}${ext}"
binary_tmp="${binary_path}.tmp.$$"

echo "Installing Supercharge ${TARGET} (${platform}) from ${REPO}..." >&2
if ! download_file "${base_url}/${asset}" "$binary_tmp"; then
  rm -f "$binary_tmp"
  echo "Error: download failed for ${base_url}/${asset}" >&2
  echo "This platform may not be published yet. Check https://github.com/${REPO}/releases/tag/${tag}" >&2
  exit 1
fi

if [ "$os" != "windows" ]; then
  chmod +x "$binary_tmp"
  if ! "$binary_tmp" --version >/dev/null 2>&1; then
    echo "Error: downloaded binary failed to run." >&2
    rm -f "$binary_tmp"
    exit 1
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

cat >&2 <<EOF
Installed Supercharge AI ${TARGET}:
  ${BIN_DIR}/supercharge${ext}
  ${BIN_DIR}/sc${ext}

Configuration home:
  ${CONFIG_HOME}

Add to PATH if needed:
  export PATH="${BIN_DIR}:\$PATH"

Start the interactive coding TUI:
  supercharge
  sc
EOF

if [ "$os" = "windows" ]; then
  echo "Add %USERPROFILE%\\.local\\bin to PATH for cmd.exe / PowerShell." >&2
fi
