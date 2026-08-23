# Supercharge AI — public releases

Public download channel for the **Supercharge AI** terminal CLI (`supercharge` / `sc`).

Source code lives in a private repo; this repository only hosts release binaries and install scripts so anyone can install without repo access.

## Install

### macOS / Linux

Latest stable:

```bash
curl -fsSL https://raw.githubusercontent.com/iotserver24/supercharge-releases/main/scripts/install.sh | bash
```

Specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/iotserver24/supercharge-releases/main/scripts/install.sh | bash -s 1.0.5
```

### Windows (PowerShell)

Latest stable:

```powershell
irm https://raw.githubusercontent.com/iotserver24/supercharge-releases/main/scripts/install.ps1 | iex
```

Specific version:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/iotserver24/supercharge-releases/main/scripts/install.ps1))) -Version 1.0.5
```

Git Bash / MSYS2 on Windows can also use the bash installer above.

## Supported platforms

| OS | Architectures |
|----|----------------|
| Linux | x86_64, aarch64 |
| macOS | x86_64 (Intel), aarch64 (Apple Silicon) |
| Windows | x86_64, aarch64 |

Release assets are named:

- `supercharge-linux-x86_64`
- `supercharge-macos-aarch64`
- `supercharge-windows-x86_64.exe`
- `sc-<platform>` (same binary, alternate name)

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SUPERCHARGE_VERSION` | latest | Pin install version (`1.0.5`) |
| `SUPERCHARGE_GITHUB_REPO` | `iotserver24/supercharge-releases` | Alternate release repo |
| `SUPERCHARGE_BIN_DIR` | `~/.local/bin` | Install location |
| `SUPERCHARGE_HOME` | `~/.supercharge` | Config directory |

## After install

```bash
supercharge    # interactive TUI
sc             # same binary
supercharge --single "Explain this repo"
```

Config is stored under `~/.supercharge/`.

## Releases

Binaries are published from GitHub Actions when a `v*` tag is pushed to the main Supercharge repo. Each release includes:

- Cross-platform CLI binaries
- `install.sh` / `install.ps1`
- `SHA256SUMS` checksums
- Linux daemon binary (`superagent-server-linux-x86_64`) for self-hosted / E2B sandboxes

See [Releases](https://github.com/iotserver24/supercharge-releases/releases) for downloads.
