"""Offline regressions for current agy credentials and hidden login."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


class CurrentAuthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.root = self.home / ".agy-profiles"
        self.root.mkdir()
        self.fake = self.home / "agy"
        self.fake.write_text("#!/bin/sh\n" + r'''
case "$*" in
  *"-p /usage"*)
    printf 'Gemini Models\tWeekly Limit Remaining\t80%%\t-\nGemini Models\tFive Hour Limit Remaining\t90%%\t-\nClaude and GPT models\tWeekly Limit Remaining\t60%%\t-\nClaude and GPT models\tFive Hour Limit Remaining\t70%%\t-\n' ;;
  *) printf '%s\n' "$@" ;;
esac
''')
        self.fake.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), AGY_PROFILES_DIR=str(self.root),
                        AGY_REAL=str(self.fake), AGY_AUTO_REPAIR="0")
        for key in ("AGY_PROFILE", "AGY_PROFILE_ACTIVE", "AGY_GEMINI_DIR"):
            self.env.pop(key, None)

    def token(self, name="work", legacy=False):
        directory = self.root / name / "antigravity-cli"
        directory.mkdir(parents=True, exist_ok=True)
        obj = {"token": {"access_token": "fixture-access", "refresh_token": "fixture-refresh"},
               "auth_method": "consumer", "id_token_email": "work@example.com"}
        if legacy:
            claim = base64.urlsafe_b64encode(json.dumps({"email": "work@example.com"}).encode()).decode().rstrip("=")
            obj = {"access_token": "fixture-access", "id_token": "e30." + claim + ".sig"}
        path = directory / "antigravity-oauth-token"
        path.write_text(json.dumps(obj))
        return path

    def run_cli(self, *args):
        return subprocess.run(["bash", str(SCRIPTS / "agy-p.sh"), *args], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def test_current_token_restores_profile_and_quota(self):
        self.token()
        result = self.run_cli("usage", "--tsv", "--max-age", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("work\twork@example.com\t80\t90\t60\t70", result.stdout)
        result = self.run_cli("pick")
        self.assertEqual(result.stdout.strip(), "work", result.stderr)

    def test_default_and_run_use_current_profile(self):
        self.token()
        result = self.run_cli("default", "work")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_cli("work", "--version")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--gemini_dir=" + str(self.root / "work"), result.stdout)

    def test_legacy_token_still_works(self):
        self.token(legacy=True)
        self.assertEqual(self.run_cli("email", "work").stdout.strip(), "work@example.com")

    def test_export_import_preserves_current_token(self):
        original = self.token()
        archive = self.home / "account.tgz"
        result = self.run_cli("export", "work", str(archive))
        self.assertEqual(result.returncode, 0, result.stderr)
        original.rename(original.with_suffix(".saved"))
        result = self.run_cli("import", str(archive), "restored")
        self.assertEqual(result.returncode, 0, result.stderr)
        imported = self.root / "restored/antigravity-cli/antigravity-oauth-token"
        self.assertEqual(imported.read_bytes(), original.with_suffix(".saved").read_bytes())
        self.assertEqual(imported.stat().st_mode & 0o777, 0o600)
        result = self.run_cli("import", str(archive), "duplicate")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "duplicate").exists())

    def test_malformed_tokens_do_not_count_as_logged_in(self):
        token = self.token()
        for obj in ({"id_token_email": "work@example.com"}, {"token": [], "id_token_email": "work@example.com"}, []):
            token.write_text(json.dumps(obj))
            result = self.run_cli("email", "work")
            self.assertEqual(result.stdout.strip(), "")
            self.assertNotIn("Traceback", result.stderr)

    def test_current_onboarding_state_is_not_overwritten(self):
        token = self.token()
        state = token.parent / "jetski_state.pbtxt"
        body = 'installation_uuid: "profile-id"\npost_onboarding: {\n completed_steps: POST_ONBOARDING_STEP_TYPE_USAGE_MODE\n}\n'
        state.write_text(body)
        main = self.home / ".gemini/antigravity-cli"
        main.mkdir(parents=True)
        (main / "jetski_state.pbtxt").write_text('installation_uuid: "main-id"\npost_onboarding: {}\n')
        self.assertEqual(self.run_cli("work", "--version").returncode, 0)
        self.assertEqual(state.read_text(), body)

    def test_hidden_login_answers_terminal_queries_and_reads_current_token(self):
        fake = self.home / "fake-login"
        fake.write_text("#!" + sys.executable + "\n" + r'''
import json, os, select, sys, termios, time, tty
from pathlib import Path
tty.setraw(0)
def receive(marker):
    data = b''
    end = time.monotonic() + 3
    while marker not in data and time.monotonic() < end:
        if select.select([0], [], [], .1)[0]: data += os.read(0, 4096)
    if marker not in data: sys.exit(8)
os.write(1, b'\x1b[')
time.sleep(.05)
os.write(1, b'>c\x1b[>q')
receive(b'\x1b\\')
os.write(1, b'Select login method:\r\n > 1. Google OAuth\r\n')
receive(b'\r')
os.write(1, b'\x1b]8;;https://accounts.google.com/o/oauth2/v2/auth?state=fixture&prompt=consent\x1b\\Click here\x1b]8;;\x1b\\\r\n')
receive(b'fixture-code')
d = Path(next(a.split('=', 1)[1] for a in sys.argv if a.startswith('--gemini_dir='))) / 'antigravity-cli'
d.mkdir(parents=True, exist_ok=True)
(d / 'antigravity-oauth-token').write_text(json.dumps({'token': {'access_token': 'fake'}, 'id_token_email': 'work@example.com'}))
time.sleep(10)
''')
        fake.chmod(0o700)
        fifo = self.home / "code"
        os.mkfifo(fifo)
        fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, fd)
        os.write(fd, b"fixture-code\n")
        proc = subprocess.Popen([sys.executable, str(SCRIPTS / "login.py"), "--agy", str(fake),
                                 "--gemini-dir", str(self.home / "login"), "--fifo", str(fifo),
                                 "--timeout", "3"], env=self.env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            out, err = proc.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            proc.terminate()
            out, err = proc.communicate(timeout=12)
            self.fail("hidden login did not complete: " + err)
        self.assertEqual(proc.returncode, 0, err)
        self.assertIn("prompt=select_account%20consent", out)
        self.assertIn("OK work@example.com", out)
        self.assertNotIn("fixture-code", out + err)


if __name__ == "__main__":
    unittest.main()
