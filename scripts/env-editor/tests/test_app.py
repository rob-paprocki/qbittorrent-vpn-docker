"""env-editor app tests (Flask test client), one mode per run.

Run by run-tests.sh, which builds the fixture repo FIXTURE (a copy of
scripts/env-editor, .env.example, compose.yaml and native/versions.env,
plus configs/env-editor/credentials.json for admin:test-pass) and puts a
`docker` stub that logs its arguments to $DOCKER_LOG first on PATH:

    TS_MODE=docker|native DOCKER_LOG=... python3 -B test_app.py FIXTURE

What is checked:
  * Docker and native mode refuse a QBITTORRENT_PASSWORD FileBrowser cannot
    use ("admin", under 5 or over 72 bytes) on Preview and on Apply, before
    anything is written or restarted, and show the form again with what was
    submitted. Docker mode also refuses an empty or .env.example
    placeholder login and a password with $ (Compose would expand it, also
    one an installer wrote in single quotes); native mode lets those
    through (an unset login means "not set up yet" there).
  * Docker-mode Apply seeds qBittorrent and Jackett but writes nothing for
    FileBrowser, creates <CONFIG_PATH>/filebrowser when it is missing, and
    a new password still recreates FileBrowser. A password with quotes and
    backslashes reads back unchanged on the next save.
"""
from __future__ import annotations

import base64
import os
import shutil
import sys
import unittest
from pathlib import Path

FIXTURE = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(FIXTURE / "scripts" / "env-editor"))
import app as editor  # noqa: E402
import env_io  # noqa: E402

AUTH = {"Authorization": "Basic " + base64.b64encode(b"admin:test-pass").decode()}
DOCKER_LOG = Path(os.environ["DOCKER_LOG"])
EXAMPLE = env_io.parse_env(FIXTURE / ".env.example")
CONFIGS = FIXTURE / "configs"
QBIT_CONF = CONFIGS / "qbittorrent" / "qBittorrent" / "qBittorrent.conf"
JACKETT_CONF = CONFIGS / "jackett" / "Jackett" / "ServerConfig.json"
FB_SETTINGS = CONFIGS / "filebrowser" / "settings.yaml"

# Password values that FileBrowser Quantum cannot take, with the text the
# refusal must show.
BAD_PASSWORDS = [
    ("admin", 'cannot be "admin"'),
    ("abcd", "has 4 bytes"),
    ("éé", "has 4 bytes"),
    ("x" * 73, "has 73 bytes"),
    ("é" * 37, "has 74 bytes"),
]


def form(**change: str) -> dict[str, str]:
    """The form as the browser would post it: .env, else .env.example values."""
    current = editor._parse_env(editor.ENV_PATH)
    data = {}
    for f in env_io.FIELDS:
        value = current.get(f["name"], EXAMPLE.get(f["name"], ""))
        if f["type"] != "toggle" or value == "on":
            data[f["name"]] = value
    data.update(change)
    return data


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.client = editor.app.test_client()
        DOCKER_LOG.write_text("")
        for p in (editor.ENV_PATH, QBIT_CONF, JACKETT_CONF, FB_SETTINGS):
            if p.exists():
                p.unlink()

    def snapshot(self) -> dict[str, bytes]:
        return {str(p.relative_to(FIXTURE)): p.read_bytes()
                for p in sorted(FIXTURE.rglob("*"))
                if p.is_file() and "scripts" not in p.parts}

    def assert_refused(self, page, needle: str, before: dict[str, bytes]) -> None:
        html = page.get_data(as_text=True)
        self.assertEqual(page.status_code, 200)
        self.assertIn("<h1>Not saved</h1>", html)
        self.assertIn(needle.replace('"', "&#34;"), html)
        self.assertEqual(self.snapshot(), before, "a file changed")
        self.assertEqual(DOCKER_LOG.read_text(), "", "docker was called")

    def assert_form_kept(self, page, value: str) -> None:
        """The refused page is the form again, holding a submitted value."""
        html = page.get_data(as_text=True)
        self.assertIn('id="env-form"', html)
        self.assertIn(f'value="{value}"', html)

    def pending(self, values: dict[str, str]) -> None:
        """Put values in the session, as a Preview would, without the check."""
        with self.client.session_transaction() as s:
            s["pending"] = editor._collect_form(values)


@unittest.skipIf(editor.NATIVE, "Docker mode only")
class DockerMode(Base):
    def test_refuses_placeholders_and_empty(self) -> None:
        cases = [
            ({}, "QBITTORRENT_USER is still the .env.example placeholder"),
            ({"QBITTORRENT_USER": "rob"}, "QBITTORRENT_PASSWORD is still the .env.example placeholder"),
            ({"QBITTORRENT_PASSWORD": "Good-pass-1"}, "QBITTORRENT_USER is still the .env.example placeholder"),
            ({"QBITTORRENT_USER": "rob", "QBITTORRENT_PASSWORD": ""}, "QBITTORRENT_PASSWORD is empty"),
            ({"QBITTORRENT_USER": "", "QBITTORRENT_PASSWORD": "Good-pass-1"}, "QBITTORRENT_USER is empty"),
        ]
        key = "Typed-WireGuard-Key-0123456789abcdefghijklm="
        for change, needle in cases:
            with self.subTest(change=change):
                values = form(WIREGUARD_PRIVATE_KEY=key, **change)
                before = self.snapshot()
                page = self.client.post("/preview", data=values, headers=AUTH)
                self.assert_refused(page, needle, before)
                self.assertIn("cannot be used by the stack", page.get_data(as_text=True))
                self.assert_form_kept(page, key)
                self.pending(values)
                page = self.client.post("/apply", headers=AUTH)
                self.assert_refused(page, needle, before)
                self.assert_form_kept(page, key)

    def test_refuses_a_password_with_dollar(self) -> None:
        for pw in ("admin$xyz", "ab$cdefgh", "Good-pass-1$"):
            with self.subTest(pw=pw):
                values = form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD=pw)
                before = self.snapshot()
                self.assert_refused(self.client.post("/preview", data=values, headers=AUTH),
                                    'cannot contain "$"', before)
                self.pending(values)
                self.assert_refused(self.client.post("/apply", headers=AUTH),
                                    'cannot contain "$"', before)

    def test_single_quoted_dollar_in_env_is_not_rewritten(self) -> None:
        # The Unraid and Synology installers write such a password in
        # single quotes, which Compose reads literally. Saving it again in
        # double quotes would let Compose expand $cd1234: refused instead.
        editor.ENV_PATH.write_text(
            editor.ENV_EXAMPLE.read_text()
            .replace(f"QBITTORRENT_USER={EXAMPLE['QBITTORRENT_USER']}", "QBITTORRENT_USER=rob")
            .replace(f"QBITTORRENT_PASSWORD={EXAMPLE['QBITTORRENT_PASSWORD']}",
                     "QBITTORRENT_PASSWORD='Ab$cd1234'"))
        before = self.snapshot()
        self.assert_refused(self.client.post("/preview", data=form(SERVER_COUNTRIES="Switzerland"),
                                             headers=AUTH), 'cannot contain "$"', before)

    def test_refuses_passwords_filebrowser_cannot_use(self) -> None:
        for pw, needle in BAD_PASSWORDS:
            with self.subTest(pw=pw):
                values = form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD=pw)
                before = self.snapshot()
                self.assert_refused(self.client.post("/preview", data=values, headers=AUTH),
                                    needle, before)
                # Apply checks again before it writes anything.
                self.pending(values)
                self.assert_refused(self.client.post("/apply", headers=AUTH), needle, before)

    def test_refused_after_a_good_save_keeps_everything(self) -> None:
        self.apply(form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD="Good-pass-1"))
        DOCKER_LOG.write_text("")
        before = self.snapshot()
        values = form(QBITTORRENT_PASSWORD="y" * 80)
        self.assert_refused(self.client.post("/preview", data=values, headers=AUTH),
                            "has 80 bytes", before)
        self.pending(values)
        self.assert_refused(self.client.post("/apply", headers=AUTH), "has 80 bytes", before)

    def apply(self, values: dict[str, str]):
        preview = self.client.post("/preview", data=values, headers=AUTH)
        self.assertEqual(preview.status_code, 200)
        self.assertIn("Review changes", preview.get_data(as_text=True))
        page = self.client.post("/apply", headers=AUTH)
        self.assertEqual(page.status_code, 200)
        self.assertIn("<h1>Applied</h1>", page.get_data(as_text=True))
        return preview.get_data(as_text=True), page.get_data(as_text=True)

    def test_apply_seeds_no_filebrowser_config(self) -> None:
        for pw in ("x" * 72, "é" * 36, "abcde", 'pa ss"w\\ord #1'):
            with self.subTest(pw=pw):
                DOCKER_LOG.write_text("")
                plan, applied = self.apply(form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD=pw))
                self.assertNotIn("bcrypt", plan + applied)
                self.assertIn("Seeded qBittorrent.conf", applied)
                self.assertFalse(FB_SETTINGS.exists(), "settings.yaml was written")
                self.assertTrue(JACKETT_CONF.is_file())
                self.assertIn("Username=rob", QBIT_CONF.read_text())
                self.assertEqual(env_io.parse_env_literal(editor.ENV_PATH)["QBITTORRENT_PASSWORD"], pw)
                calls = DOCKER_LOG.read_text().splitlines()
                self.assertEqual(len(calls), 1, calls)
                self.assertIn(" up -d ", calls[0])
                self.assertIn(" filebrowser", calls[0])

    def test_quotes_and_backslashes_survive_a_later_save(self) -> None:
        for pw in ('pa"ss\\w1', '"\\"\\' + "x" * 66):   # the second is 70 bytes
            with self.subTest(pw=pw):
                self.apply(form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD=pw))
                line = [l for l in editor.ENV_PATH.read_text().splitlines()
                        if l.startswith("QBITTORRENT_PASSWORD=")]
                for port in ("8091", "8092"):
                    # The form shows .env's values; only a port changes.
                    plan, _ = self.apply(form(QBIT_WEBUI_PORT=port))
                    self.assertNotIn("QBITTORRENT_PASSWORD", plan)
                    self.assertEqual([l for l in editor.ENV_PATH.read_text().splitlines()
                                      if l.startswith("QBITTORRENT_PASSWORD=")], line)
                    self.assertEqual(env_io.parse_env_literal(editor.ENV_PATH)["QBITTORRENT_PASSWORD"], pw)

    def test_apply_creates_the_filebrowser_folder(self) -> None:
        # Docker would create a missing bind-mount source as root, where
        # FileBrowser (uid 1000) cannot write its database.
        alt = FIXTURE / "altcfg"
        self.addCleanup(shutil.rmtree, alt, True)
        engines = alt / "qbittorrent" / "qBittorrent" / "nova3" / "engines"
        engines.mkdir(parents=True)
        (engines / "jackett.py").write_text("# stub\n")   # nothing is downloaded
        _, applied = self.apply(form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD="Good-pass-1",
                                     CONFIG_PATH=str(alt)))
        fb = alt / "filebrowser"
        self.assertTrue(fb.is_dir())
        self.assertEqual(fb.stat().st_mode & 0o7777, 0o2775)
        self.assertIn(f"Created {fb}", applied)
        # One that exists is left as it is.
        fb.chmod(0o750)
        _, applied = self.apply(form(SERVER_COUNTRIES="Switzerland"))
        self.assertEqual(fb.stat().st_mode & 0o7777, 0o750)
        self.assertNotIn("Created", applied)

    def test_password_change_recreates_filebrowser(self) -> None:
        self.apply(form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD="Good-pass-1"))
        DOCKER_LOG.write_text("")
        plan, applied = self.apply(form(QBITTORRENT_PASSWORD="Good-pass-2"))
        self.assertIn("FileBrowser is not seeded", plan)
        self.assertNotIn("Re-seed FileBrowser", plan)
        self.assertEqual(DOCKER_LOG.read_text().split(" up -d ", 1)[1].split(),
                         ["filebrowser", "gluetun", "qbittorrent"])
        self.assertFalse(FB_SETTINGS.exists())

    def test_an_old_settings_yaml_is_left_alone(self) -> None:
        FB_SETTINGS.parent.mkdir(parents=True, exist_ok=True)
        FB_SETTINGS.write_text("old\n")
        self.apply(form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD="Good-pass-1"))
        self.assertEqual(FB_SETTINGS.read_text(), "old\n")


@unittest.skipUnless(editor.NATIVE, "native mode only")
class NativeMode(Base):
    def setUp(self) -> None:
        super().setUp()
        self.checked: list[dict[str, str]] = []
        self.native_answer: str | None = None

        def fake_check(submitted: dict[str, str]) -> str | None:
            self.checked.append(submitted)
            return self.native_answer
        editor._native_check = fake_check  # render.py needs a real native install

    def test_unset_login_is_not_refused(self) -> None:
        for change in ({}, {"QBITTORRENT_USER": "rob"}, {"QBITTORRENT_PASSWORD": ""}):
            with self.subTest(change=change):
                self.checked.clear()
                page = self.client.post("/preview", data=form(**change), headers=AUTH)
                self.assertIn("Review changes", page.get_data(as_text=True))
                self.assertEqual(len(self.checked), 1, "render.py was not asked")

    def test_dollar_is_fine_natively(self) -> None:
        # render.py reads .env literally: no Compose interpolation natively.
        page = self.client.post("/preview", data=form(QBITTORRENT_USER="rob",
                                                      QBITTORRENT_PASSWORD="Good$pass1"), headers=AUTH)
        self.assertIn("Review changes", page.get_data(as_text=True))

    def test_refuses_passwords_filebrowser_cannot_use(self) -> None:
        for pw, needle in BAD_PASSWORDS:
            with self.subTest(pw=pw):
                self.checked.clear()
                values = form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD=pw)
                before = self.snapshot()
                page = self.client.post("/preview", data=values, headers=AUTH)
                self.assert_refused(page, needle, before)
                self.assertIn("cannot be used by the native install", page.get_data(as_text=True))
                self.assert_form_kept(page, "rob")
                self.pending(values)
                # Refused before native/install.sh (absent here) would run.
                self.assert_refused(self.client.post("/apply", headers=AUTH), needle, before)
                self.assertEqual(self.checked, [])

    def test_render_py_refusal_still_shown(self) -> None:
        self.native_answer = "FILEBROWSER_PORT=80: below 1024"
        values = form(QBITTORRENT_USER="rob", QBITTORRENT_PASSWORD="Good-pass-1")
        before = self.snapshot()
        self.assert_refused(self.client.post("/preview", data=values, headers=AUTH),
                            "FILEBROWSER_PORT=80: below 1024", before)
        self.pending(values)
        self.assert_refused(self.client.post("/apply", headers=AUTH),
                            "FILEBROWSER_PORT=80: below 1024", before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
