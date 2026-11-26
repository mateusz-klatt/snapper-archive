"""Exercise the weekly candle sweep with offline Snapper and mail stubs."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SWEEP = Path(__file__).resolve().parents[1] / "bin" / "retention-weekly-candles.sh"


def _write_stub(path: Path, script: str) -> None:
    """Create an executable shell stub inside the test workspace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\n{script}", encoding="utf-8")
    path.chmod(0o755)


class WeeklyCandleSweepTest(unittest.TestCase):
    """Verify that the failing interval and the alert failure remain distinct."""

    def test_aborts_after_first_failed_interval_even_if_mail_fails(self) -> None:
        """Report the failed timeframe and stop with Snapper's original status."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "archive"
            app = root / "app"
            stubs = root / "bin"
            env_file = root / "snapper.env"
            calls = root / "snapper-calls"
            mail_args = root / "mail-args"
            mail_body = root / "mail-body"
            env_file.write_text("DB_URL=postgresql://test@source.invalid/snapper\n", encoding="utf-8")
            _write_stub(stubs / "df", "printf 'Avail\\n  100G\\n'\n")
            _write_stub(
                app / ".venv" / "bin" / "snapper",
                'printf \'%s\\n\' "$*" >>"$MOCK_SNAPPER_CALLS"\n'
                'case "$6" in\n'
                "  1m) exit 0 ;;\n"
                "  5m) exit 17 ;;\n"
                "  *) exit 99 ;;\n"
                "esac\n",
            )
            _write_stub(
                stubs / "mail",
                'printf \'%s\\n\' "$@" >"$MOCK_MAIL_ARGS"\n'
                'cat >"$MOCK_MAIL_BODY"\n'
                "exit 1\n",
            )
            env = {
                "PATH": f"{stubs}{os.pathsep}{os.defpath}",
                "HOME": str(root),
                "LC_ALL": "C",
                "SNAPPER_ARCHIVE_ROOT": str(archive),
                "SNAPPER_APP_ROOT": str(app),
                "SNAPPER_ENV_FILE": str(env_file),
                "SNAPPER_DB_HOST_FROM": "source.invalid",
                "SNAPPER_DB_HOST_TO": "target.invalid",
                "SNAPPER_ALERT_EMAIL": "offline@example.invalid",
                "FROM": "2023-01-01",
                "TO": "2026-11-19",
                "MOCK_SNAPPER_CALLS": str(calls),
                "MOCK_MAIL_ARGS": str(mail_args),
                "MOCK_MAIL_BODY": str(mail_body),
            }

            result = subprocess.run(
                ["bash", str(SWEEP)],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 17, result.stderr)
            self.assertEqual(
                calls.read_text(encoding="utf-8").splitlines(),
                [
                    f"archive --table candles-audit --closed-only --timeframe {timeframe} "
                    f"--from 2023-01-01 --to 2026-11-19 --output-dir {archive} --purge"
                    for timeframe in ("1m", "5m")
                ],
            )
            subject = "Snapper candles-sweep FAILED (exit 17)"
            self.assertEqual(
                mail_args.read_text(encoding="utf-8").splitlines(),
                ["-s", subject, "offline@example.invalid"],
            )
            (logfile,) = (archive / "logs").glob("candles-sweep-*.log")
            log = logfile.read_text(encoding="utf-8").splitlines()
            alert = mail_body.read_text(encoding="utf-8").splitlines()
            abort = "ABORT: timeframe=5m rc=17 range=2023-01-01..2026-11-19"
            completed = "OK: timeframe=1m rc=0 range=2023-01-01..2026-11-19"
            self.assertIn(abort, alert)
            self.assertIn(completed, alert)
            self.assertIn(abort, log)
            self.assertIn(completed, log)
            self.assertIn(f"ALERT-UNDELIVERED (mail rc=1) subject: {subject}", log)
