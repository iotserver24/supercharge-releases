#!/usr/bin/env python3
"""Offline installer regression tests. All shell state lives in temporary homes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().with_name("install.sh")
BASH = shutil.which("bash")
ZSH = shutil.which("zsh")
FISH = shutil.which("fish")
BEGIN = "# >>> Supercharge AI PATH >>>"
END = "# <<< Supercharge AI PATH <<<"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="supercharge-install-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.mock = self.root / "mock"
        self.mock.mkdir()
        self.bin = self.home / ".local/bin"
        self.env = {
            "HOME": str(self.home), "SHELL": "/bin/bash",
            "PATH": str(self.mock) + os.pathsep + os.defpath,
            "NO_COLOR": "1", "TMPDIR": str(self.root),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "MOCK_PLATFORM": "Linux", "MOCK_ARCH": "x86_64",
        }
        self.write(self.mock / "uname", '#!/bin/sh\ncase "$1" in -s) printf "%s\\n" "$MOCK_PLATFORM";; -m) printf "%s\\n" "$MOCK_ARCH";; esac\n', True)
        # No network access: every curl request must be an expected asset request.
        self.write(self.mock / "curl", '''#!/bin/sh
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    https://github.com/*/releases/download/v1.2.3/supercharge-*) shift ;;
    -fL|--progress-bar) shift ;;
    *) printf 'Unexpected mock curl argument: %s\\n' "$1" >&2; exit 90 ;;
  esac
done
[ -n "$output" ] || exit 91
printf '%s\\n' '#!/bin/sh' '[ "$1" = --version ] || exit 92' 'printf "supercharge 1.2.3\\n"' > "$output"
''', True)

    def write(self, path, content, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        if executable:
            path.chmod(0o755)

    def run_install(self, **overrides):
        self.env.update({k: str(v) for k, v in overrides.items()})
        self.bin = Path(self.env.get("SUPERCHARGE_BIN_DIR", self.home / ".local/bin"))
        if not self.bin.is_absolute():
            self.bin = self.home / self.bin
        result = subprocess.run([BASH, "-s", "1.2.3"], input=INSTALLER.read_text(),
                                cwd=self.home, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(subprocess.check_output([str(self.bin / "supercharge"), "--version"], text=True).strip(), "supercharge 1.2.3")
        return result.stderr

    def shell_path(self, shell, configs, path=None):
        env = dict(self.env)
        env["PATH"] = path or os.defpath
        # Pass paths as argv, never interpolate them as executable shell text.
        if shell == FISH:
            code = 'for config in $argv; source "$config"; source "$config"; end; printf "%s\\n" $PATH'
        else:
            code = 'for config in "$@"; do . "$config"; . "$config"; done; printf "%s" "$PATH"'
        result = subprocess.run([shell, "-c", code, *([] if shell == FISH else ["test"]), *map(str, configs)],
                                env=env, cwd=self.home, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = result.stdout.splitlines() if shell == FISH else result.stdout.split(":")
        self.assertEqual(entries.count(str(self.bin)), 1, entries)
        return entries

    def test_bash_pipe_install_and_idempotence(self):
        rc = self.home / ".bashrc"
        original = "# keep this\nexport KEEP_ME=yes\n"
        self.write(rc, original)
        rc.chmod(0o640)
        output = self.run_install()
        self.assertIn("Persistent PATH setup complete", output)
        self.assertIn("cannot change the current parent shell", output)
        self.assertIn(str(self.bin / "supercharge"), output)
        backups = list(self.home.glob(".bashrc.supercharge.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), original)
        self.assertEqual(rc.stat().st_mode & 0o777, 0o640)
        content = rc.read_text()
        self.run_install()
        self.assertEqual(rc.read_text(), content)
        self.assertEqual(len(list(self.home.glob(".bashrc.supercharge.bak.*"))), 1)
        login = self.home / ".bash_profile"
        self.assertNotIn(".bashrc", login.read_text())
        self.shell_path(BASH, [rc, login])

    def test_active_bash_login_file(self):
        for name in (".bash_login", ".profile"):
            self.write(self.home / name, "# existing\n")
        self.run_install()
        self.assertFalse((self.home / ".bash_profile").exists())
        self.assertIn(BEGIN, (self.home / ".bash_login").read_text())
        self.assertNotIn(BEGIN, (self.home / ".profile").read_text())

    def test_bash_profile_fallback(self):
        self.write(self.home / ".profile", "# POSIX login\n")
        self.run_install()
        self.assertFalse((self.home / ".bash_profile").exists())
        self.shell_path(BASH, [self.home / ".profile"])

    def test_duplicate_managed_blocks_and_custom_path_change(self):
        self.run_install()
        rc = self.home / ".bashrc"
        self.write(rc, rc.read_text() + "# between\n" + rc.read_text() + "# after\n")
        self.run_install(SUPERCHARGE_BIN_DIR=self.home / "new bin")
        self.assertEqual(rc.read_text().count(BEGIN), 1)
        self.assertIn("# between\n", rc.read_text())
        self.assertIn("# after\n", rc.read_text())
        self.assertNotIn(str(self.home / ".local/bin"), rc.read_text())
        self.shell_path(BASH, [rc])

    def test_existing_path_still_persists(self):
        self.env["PATH"] = str(self.bin) + ":" + self.env["PATH"]
        output = self.run_install()
        self.assertIn("available on the inherited PATH", output)
        self.assertIn(BEGIN, (self.home / ".bashrc").read_text())
        self.shell_path(BASH, [self.home / ".bashrc"], self.env["PATH"])

    def test_literal_special_paths_and_fallback(self):
        special = self.home / "bin ' $HOME `touch INJECTED` $(touch INJECTED) \\ [*]"
        output = self.run_install(SUPERCHARGE_BIN_DIR=special)
        self.shell_path(BASH, [self.home / ".bashrc"])
        command = next(line.strip() for line in output.splitlines() if line.strip().startswith("export PATH="))
        result = subprocess.run([BASH, "-c", command + '; supercharge --version'], env=self.env, cwd=self.home, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / "INJECTED").exists())

    def test_relative_install_directory_becomes_absolute(self):
        self.run_install(SUPERCHARGE_BIN_DIR="relative bin")
        self.shell_path(BASH, [self.home / ".bashrc"])

    def test_immediate_user_path_links(self):
        userbin = self.home / "existing bin"
        userbin.mkdir()
        self.env["PATH"] = str(userbin) + ":" + self.env["PATH"]
        self.run_install()
        for name in ("supercharge", "sc"):
            self.assertTrue((userbin / name).is_symlink())
            self.assertEqual((userbin / name).resolve(), (self.bin / name).resolve())
            result = subprocess.run([BASH, "-c", name + " --version"], env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.run_install()

    def test_unrelated_commands_are_not_shadowed(self):
        early = self.home / "early"
        later = self.home / "later"
        early.mkdir()
        for name in ("supercharge", "sc"):
            self.write(later / name, "#!/bin/sh\nexit 0\n", True)
        self.env["PATH"] = str(early) + ":" + str(later) + ":" + self.env["PATH"]
        output = self.run_install()
        self.assertIn("Keeping existing command", output)
        self.assertFalse((early / "supercharge").exists())
        self.assertFalse((early / "sc").exists())
        self.assertEqual((later / "sc").read_text(), "#!/bin/sh\nexit 0\n")

    def test_unrelated_dangling_links_and_nonexecutables_are_preserved(self):
        userbin = self.home / "existing"
        userbin.mkdir()
        (userbin / "supercharge").symlink_to("missing-unrelated")
        self.write(userbin / "sc", "not executable\n")
        self.env["PATH"] = str(userbin) + ":" + self.env["PATH"]
        self.run_install()
        self.assertEqual(os.readlink(userbin / "supercharge"), "missing-unrelated")
        self.assertEqual((userbin / "sc").read_text(), "not executable\n")

    def test_install_alias_collision_is_preserved(self):
        self.write(self.bin / "sc", "unrelated\n")
        output = self.run_install()
        self.assertIn("Keeping unrelated", output)
        self.assertEqual((self.bin / "sc").read_text(), "unrelated\n")

    def test_outside_home_and_symlink_escape_are_not_link_targets(self):
        outside = self.root / "outside"
        outside.mkdir()
        escape = self.home / "escape"
        escape.symlink_to(outside, target_is_directory=True)
        self.env["PATH"] = str(escape) + ":" + str(outside) + ":" + self.env["PATH"]
        self.run_install()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.mock / "supercharge").exists())

    @unittest.skipUnless(ZSH, "zsh not installed")
    def test_zsh_respects_zdotdir_and_quotes(self):
        zdot = self.home / "zsh config"
        self.run_install(SHELL=ZSH, ZDOTDIR=zdot, SUPERCHARGE_BIN_DIR=self.home / "bin ' $ ` \\ *")
        self.assertFalse((self.home / ".bashrc").exists())
        self.shell_path(ZSH, [zdot / ".zprofile", zdot / ".zshrc"])
        before = (zdot / ".zshrc").read_text()
        self.run_install()
        self.assertEqual((zdot / ".zshrc").read_text(), before)

    @unittest.skipUnless(FISH, "fish not installed")
    def test_fish_respects_xdg_config_and_quotes(self):
        config = self.home / "fish config"
        self.run_install(SHELL=FISH, XDG_CONFIG_HOME=config, SUPERCHARGE_BIN_DIR=self.home / "bin ' $HOME ` \\ [*]")
        rc = config / "fish/config.fish"
        self.assertFalse((self.home / ".bashrc").exists())
        self.shell_path(FISH, [rc])
        before = rc.read_text()
        self.run_install()
        self.assertEqual(rc.read_text(), before)

    def test_opt_out_changes_neither_configs_nor_path_dirs(self):
        rc = self.home / ".bashrc"
        self.write(rc, "# unchanged\n")
        userbin = self.home / "existing"
        userbin.mkdir()
        self.env["PATH"] = str(userbin) + ":" + self.env["PATH"]
        output = self.run_install(SUPERCHARGE_NO_MODIFY_PATH=1)
        self.assertIn("Automatic PATH setup disabled", output)
        self.assertEqual(rc.read_text(), "# unchanged\n")
        self.assertEqual(list(userbin.iterdir()), [])
        self.assertFalse((self.home / ".bash_profile").exists())

    def test_unknown_shell_warns_without_success(self):
        output = self.run_install(SHELL="/bin/tcsh")
        self.assertIn("Unsupported or unknown shell", output)
        self.assertNotIn("Persistent PATH setup complete;", output)
        self.assertFalse((self.home / ".bashrc").exists())

    def test_empty_shell_warns(self):
        output = self.run_install(SHELL="")
        self.assertIn("Unsupported or unknown shell", output)

    def test_symlink_config_is_not_replaced(self):
        target = self.home / "managed-elsewhere"
        self.write(target, "# unchanged\n")
        (self.home / ".bashrc").symlink_to(target)
        output = self.run_install()
        self.assertIn("Persistent PATH setup incomplete", output)
        self.assertTrue((self.home / ".bashrc").is_symlink())
        self.assertEqual(target.read_text(), "# unchanged\n")

    @unittest.skipIf(os.geteuid() == 0, "root bypasses file write permissions")
    def test_unwritable_config_warns(self):
        rc = self.home / ".bashrc"
        self.write(rc, "# unchanged\n")
        rc.chmod(0o400)
        output = self.run_install()
        self.assertIn("Cannot safely update", output)
        self.assertIn("Persistent PATH setup incomplete", output)
        self.assertEqual(rc.read_text(), "# unchanged\n")

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory write permissions")
    def test_unwritable_config_directory_warns(self):
        config = self.home / "read-only-config"
        config.mkdir()
        config.chmod(0o500)
        self.addCleanup(config.chmod, 0o700)
        output = self.run_install(SHELL="/bin/fish", XDG_CONFIG_HOME=config)
        self.assertIn("Cannot write shell config directory", output)
        self.assertNotIn("Persistent PATH setup complete;", output)
        self.assertFalse((config / "fish/config.fish").exists())

    def test_backup_failure_leaves_original_untouched(self):
        rc = self.home / ".bashrc"
        self.write(rc, "# preserve without final newline")
        real_cp = shutil.which("cp")
        self.env["REAL_CP"] = real_cp
        self.write(self.mock / "cp", '''#!/bin/sh
for arg in "$@"; do
  case "$arg" in *.supercharge.bak.*) exit 1 ;; esac
done
exec "$REAL_CP" "$@"
''', True)
        output = self.run_install()
        self.assertIn("Cannot back up", output)
        self.assertEqual(rc.read_text(), "# preserve without final newline")
        self.assertEqual(list(self.home.glob(".bashrc.supercharge.*")), [])

    def test_no_final_newline_and_empty_config(self):
        rc = self.home / ".bashrc"
        login = self.home / ".bash_profile"
        self.write(rc, "# preserve without final newline")
        self.write(login, "")
        self.run_install()
        self.assertTrue(rc.read_text().startswith("# preserve without final newline\n"))
        self.shell_path(BASH, [rc, login])
        self.assertEqual(next(self.home.glob(".bashrc.supercharge.bak.*")).read_text(), "# preserve without final newline")
        self.assertEqual(next(self.home.glob(".bash_profile.supercharge.bak.*")).read_text(), "")

    def test_malformed_managed_block_is_not_changed(self):
        rc = self.home / ".bashrc"
        original = "# before\n" + BEGIN + "\n# missing end\n"
        self.write(rc, original)
        output = self.run_install()
        self.assertIn("malformed Supercharge PATH markers", output)
        self.assertEqual(rc.read_text(), original)
        self.assertEqual(list(self.home.glob("*.supercharge.tmp.*")), [])

    def test_path_separators_rejected_before_download(self):
        for bad in ("colon:bin", "newline\nbin", "return\rbin"):
            env = dict(self.env, SUPERCHARGE_BIN_DIR=str(self.home / bad))
            result = subprocess.run([BASH, str(INSTALLER), "1.2.3"], env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not contain colons or newlines", result.stderr)

    def test_platform_detection_same_bash_command(self):
        for platform, arch, asset in (
            ("Linux", "aarch64", "linux-aarch64"),
            ("Darwin", "arm64", "macos-aarch64"),
            ("MINGW64_NT", "x86_64", "windows-x86_64.exe"),
        ):
            with self.subTest(platform=platform):
                # Windows mock is a shell script with .exe extension.
                env = dict(self.env, MOCK_PLATFORM=platform, MOCK_ARCH=arch, SUPERCHARGE_NO_MODIFY_PATH="1")
                result = subprocess.run([BASH, str(INSTALLER), "1.2.3"], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("supercharge-" + asset, result.stderr)
                if platform == "MINGW64_NT":
                    self.assertTrue((self.bin / "supercharge.exe").exists())
                    self.assertIn("use install.ps1 instead", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
