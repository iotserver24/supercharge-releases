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
| `SUPERCHARGE_NO_MODIFY_PATH` | `0` | Set to `1` to skip automatic shell config edits and extra PATH symlinks (bash installer) |

## After install

```bash
supercharge    # interactive TUI
sc             # same binary
supercharge --single "Explain this repo"
```

Config is stored under `~/.supercharge/`. The bash installer automatically adds the install directory to your shell startup files without sudo:

- **bash:** `~/.bashrc` and the first existing login file (`~/.bash_profile`, `~/.bash_login`, or `~/.profile`); creates `~/.bash_profile` if none exists.
- **zsh:** `.zshrc` and `.zprofile` in `$ZDOTDIR`, or your home directory.
- **fish:** `$XDG_CONFIG_HOME/fish/config.fish`, defaulting to `~/.config/fish/config.fish`.

Setup uses an idempotent managed block, honors `SUPERCHARGE_BIN_DIR`, and backs up existing files before changing them (`<file>.supercharge.bak.*`). Symlinked, unwritable, or malformed startup files are left alone with a warning. Custom install paths may contain spaces and shell special characters, but not colons or newlines.

When safe, the installer also links the commands into an existing user-owned writable PATH directory inside your home directory. It does not overwrite or shadow an existing unrelated PATH command. Otherwise, **open a new terminal** or run the shell-specific PATH command printed at the end. A piped installer cannot change its parent shell's PATH; the printed absolute executable path works immediately. Shell aliases and cached commands may need clearing separately.

For CI or manually managed shell configuration, disable these PATH changes on the installer side of the pipe:

```bash
curl -fsSL https://raw.githubusercontent.com/iotserver24/supercharge-releases/main/scripts/install.sh | SUPERCHARGE_NO_MODIFY_PATH=1 bash
```

The native Windows installer (`install.ps1`) adds `~\.local\bin` to your user PATH (current PowerShell session included). The bash installer configures the selected Unix-style shell only. Installation does not log in or change credentials.

## Releases

**Builds run on this public repo** (unlimited GitHub Actions minutes). The private source repo only triggers the build — it does not compile binaries itself.

### One-time setup (repo owner)

Add a GitHub PAT with `repo` read access to the private source:

| Secret | Repository | Purpose |
|--------|------------|---------|
| `SUPERCHARGE_SOURCE_TOKEN` | `iotserver24/supercharge-releases` | Clone private source to build |
| `SUPERCHARGE_RELEASES_TOKEN` | `iotserver24/supercharge` | Trigger public release from private tags |

### Publish a release

**From the private source repo** — push a tag:

```bash
git tag v1.0.5
git push origin v1.0.5
```

**Or run manually** on this public repo: Actions → *Build and publish release* → set `tag` and `source_ref` (e.g. `v1.0.5`).

Each release includes:

- Cross-platform CLI binaries (Linux, macOS, Windows)
- `install.sh` / `install.ps1`
- `SHA256SUMS` checksums
- Linux daemon binary (`superagent-server-linux-x86_64`) for self-hosted / E2B sandboxes

See [Releases](https://github.com/iotserver24/supercharge-releases/releases) for downloads.
