"""Exercise Polygon's daily failure reporting with offline command stubs."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[1] / "bin"


class PolygonDailyTest(unittest.TestCase):
    """Capture the cron result, log and alert without reaching real services."""

    def run_daily(self, load_status: int) -> tuple[int, str, list[str], str]:
        """Run the actual daily script with a synthetic app and captured mail."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "bin"
            app = root / "app"
            cli = app / ".venv" / "bin" / "snapper"
            commands = root / "commands"
            calls = root / "calls"
            mail = root / "mail"
            scripts.mkdir()
            commands.mkdir()
            cli.parent.mkdir(parents=True)
            (app / "data" / "polygon" / "cache").mkdir(parents=True)
            for name in ("polygon-daily.sh", "_alert.sh"):
                shutil.copy2(BIN / name, scripts / name)

            stubs = {
                cli: """#!/bin/bash
printf '%s\n' "$1" >>"$TEST_CALLS"
case "$1" in
  polygon-load-csv) exit "$TEST_LOAD_STATUS" ;;
  polygon-backfill-aggregates|polygon-backfill-grouped|daily-partitions|backfill-synthesized-candles) exit 0 ;;
  *) exit 90 ;;
esac
""",
                scripts / "polygon-publish-gitlink.sh": """#!/bin/bash
printf '%s\n' gitlink >>"$TEST_CALLS"
""",
                commands / "git": """#!/bin/bash
case "$*" in
  '-C '*'/data/polygon log -1 --format=%ct') date -u +%s ;;
  'add -A'|'diff --cached --quiet') exit 0 ;;
  *) exit 91 ;;
esac
""",
                commands / "mail": """#!/bin/bash
printf '%s\n' "$2" >"$TEST_MAIL"
cat >>"$TEST_MAIL"
""",
            }
            for path, body in stubs.items():
                path.write_text(body, encoding="utf-8")
                path.chmod(0o755)

            env_file = root / ".env"
            env_file.write_text("DB_URL=offline-fixture\n", encoding="utf-8")
            env = {
                "HOME": str(root),
                "PATH": f"{commands}{os.pathsep}{os.defpath}",
                "SNAPPER_ARCHIVE_ROOT": str(root),
                "SNAPPER_APP_ROOT": str(app),
                "SNAPPER_GITLINK_REMOTES": "offline",
                "SNAPPER_ENV_FILE": str(env_file),
                "SNAPPER_DB_HOST_FROM": "offline",
                "SNAPPER_DB_HOST_TO": "stub",
                "SNAPPER_ALERT_EMAIL": "alerts@example.invalid",
                "GROUPED_MARKETS": "crypto",
                "MIN_FREE_GB": "0",
                "TEST_LOAD_STATUS": str(load_status),
                "TEST_CALLS": str(calls),
                "TEST_MAIL": str(mail),
            }
            result = subprocess.run(
                ["bash", str(scripts / "polygon-daily.sh")],
                env=env,
                capture_output=True,
                check=False,
                text=True,
                timeout=20,
            )
            log = next((root / "logs").glob("polygon-*.log")).read_text(encoding="utf-8")
            alert = mail.read_text(encoding="utf-8") if mail.exists() else ""
            return result.returncode, log, calls.read_text(encoding="utf-8").splitlines(), alert

    def test_successful_load_finishes_without_notification(self) -> None:
        status, log, calls, alert = self.run_daily(0)
        self.assertEqual(status, 0, log)
        self.assertEqual(calls[-3:], ["polygon-load-csv", "backfill-synthesized-candles", "gitlink"])
        self.assertIn("load rc=0", log)
        self.assertEqual(alert, "")

    def test_failed_load_preserves_later_phases_and_reports_exit_code(self) -> None:
        status, log, calls, alert = self.run_daily(23)
        self.assertEqual(calls[-3:], ["polygon-load-csv", "backfill-synthesized-candles", "gitlink"])
        self.assertEqual(status, 1, log)
        self.assertIn("load rc=23", log)
        self.assertIn("Snapper polygon-daily FAILED (exit 1)", alert)
        self.assertIn("WARN: polygon-load-csv failed (rc=23)", alert)
