"""Exercise gitlink publication exclusively through local bare Git and a fake GitHub CLI."""

import fcntl
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from typing import TypedDict
from typing import cast

ROOT = Path(__file__).resolve().parents[1]
PUBLISHER = ROOT / "bin" / "polygon-publish-gitlink.sh"
BRANCH = "automation/polygon-gitlink"
MARKER = "Snapper-Automation: polygon-gitlink-v1"
PR_MARKER = "<!-- snapper-polygon-gitlink:v1 -->"
GH_REPOSITORY = "github.com/offline/snapper"
GH_DECOY = "github.com/offline/decoy"
ORIGIN_URL = "git@github.com:offline/snapper.git"


class GhState(TypedDict):
    """Persist only synthetic pull-request state for the offline CLI."""

    open: bool
    number: int
    managed: bool
    cross_repository: bool
    fail_operation: str
    merge_immediately: bool


GH_SCRIPT = r'''#!/usr/bin/env python3
"""Implement only the GitHub operations required by the publisher, using local fixtures."""

import json
import os
import subprocess
import sys
from pathlib import Path


def git(repository: str, *args: str) -> str:
    """Execute the actual Git binary only against a selected local bare repository."""
    return subprocess.check_output(
        [os.environ["MOCK_REAL_GIT"], "--git-dir", repository, *args],
        text=True,
    ).strip()


def repository_binding(args: list[str]) -> str:
    """Model an explicit selector or the conflicting configured GitHub default."""
    if "--repo" in args:
        return args[args.index("--repo") + 1]
    default = subprocess.check_output(
        [os.environ["MOCK_REAL_GIT"], "config", "--get", "remote.shadow.gh-resolved"],
        text=True,
    ).strip()
    if default != "base":
        raise ValueError("Synthetic configured default is unavailable")
    raw = subprocess.check_output(
        [os.environ["MOCK_REAL_GIT"], "config", "--get", "remote.shadow.url"],
        text=True,
    ).strip()
    return raw.removeprefix("git@").replace(":", "/", 1).removesuffix(".git")


def main() -> int:
    """Model pending or immediate merge while refusing approval and bypass flags."""
    args = sys.argv[1:]
    calls = Path(os.environ["MOCK_GH_CALLS"])
    with calls.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(args) + "\n")
    if "--admin" in args or "--approve" in args or args[:2] == ["pr", "review"]:
        return 90
    if len(args) < 2 or args[0] != "pr":
        return 91
    if os.environ.get("GH_REPO") or os.environ.get("GH_HOST"):
        return 94
    repository = repository_binding(args)
    with Path(os.environ["MOCK_GH_BINDINGS"]).open("a", encoding="utf-8") as stream:
        stream.write(json.dumps({"repository": repository, "operation": args[1]}) + "\n")
    if repository == "github.com/offline/snapper":
        origin = os.environ["MOCK_GH_ORIGIN"]
        path = Path(os.environ["MOCK_GH_STATE"])
    elif repository == "github.com/offline/decoy":
        origin = os.environ["MOCK_GH_DECOY_ORIGIN"]
        path = Path(os.environ["MOCK_GH_DECOY_STATE"])
    else:
        return 95
    state = json.loads(path.read_text())
    operation = args[1]
    if state["fail_operation"] == operation:
        return 7
    branch = "refs/heads/automation/polygon-gitlink"
    if operation == "list":
        if state["open"]:
            head = git(origin, "rev-parse", branch)
            print(
                f'{state["number"]}\t{head}\t'
                f'{str(state["managed"]).lower()}\t'
                f'{str(state["cross_repository"]).lower()}'
            )
        return 0
    if operation == "create":
        if state["open"] or "--body-file" not in args:
            return 8
        body = Path(args[args.index("--body-file") + 1]).read_text()
        if "<!-- snapper-polygon-gitlink:v1 -->" not in body:
            return 9
        git(origin, "rev-parse", branch)
        state["open"] = True
        state["managed"] = True
        state["cross_repository"] = False
        path.write_text(json.dumps(state))
        print("https://example.invalid/offline/snapper/pull/1")
        return 0
    if operation == "close":
        if not state["open"]:
            return 10
        state["open"] = False
        path.write_text(json.dumps(state))
        print("Closed synthetic pull request")
        return 0
    if operation == "merge":
        required = {"--merge", "--match-head-commit"}
        if not required.issubset(args) or not state["open"]:
            return 11
        head = git(origin, "rev-parse", branch)
        expected = args[args.index("--match-head-commit") + 1]
        if expected != head or state["fail_operation"] == "match_head":
            return 12
        if state["fail_operation"] == "auto_clean" and "--auto" in args:
            return 13
        if state["merge_immediately"] or state["fail_operation"] == "auto_clean":
            base = git(origin, "rev-parse", "refs/heads/master")
            tree = git(origin, "rev-parse", f"{head}^{{tree}}")
            merged = git(
                origin, "commit-tree", tree, "-p", base, "-p", head,
                "-m", "Synthetic policy-approved merge",
            )
            git(origin, "update-ref", "refs/heads/master", merged, base)
            state["open"] = False
            path.write_text(json.dumps(state))
        return 0
    return 92


if __name__ == "__main__":
    raise SystemExit(main())
'''


GIT_SCRIPT = r'''#!/usr/bin/env python3
"""Enforce no-force pushes and optionally inject a concurrent local branch advance."""

import json
import os
import subprocess
import sys
from pathlib import Path


def main() -> None:
    """Forward Git with unchanged arguments after a deterministic race injection."""
    args = sys.argv[1:]
    if "fetch" in args or "push" in args:
        with Path(os.environ["MOCK_GIT_ACTIONS"]).open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(args) + "\n")
    if "push" in args:
        forbidden = any(
            value in {"--force", "-f"}
            or value.startswith("--force-with-lease")
            or value.startswith("+")
            for value in args
        )
        if forbidden:
            Path(os.environ["MOCK_FORBIDDEN_PUSH"]).write_text("forbidden force push")
            raise SystemExit(93)
        race = os.environ.get("MOCK_GIT_RACE_COMMIT")
        done = Path(os.environ["MOCK_GIT_RACE_DONE"])
        target = any(value.endswith(":refs/heads/automation/polygon-gitlink") for value in args)
        if race and target and not done.exists():
            subprocess.run(
                [os.environ["MOCK_REAL_GIT"], "--git-dir", os.environ["MOCK_GH_ORIGIN"],
                 "update-ref", "refs/heads/automation/polygon-gitlink", race],
                check=True,
            )
            done.write_text("concurrent update injected")
    os.execv(os.environ["MOCK_REAL_GIT"], [os.environ["MOCK_REAL_GIT"], *args])


if __name__ == "__main__":
    main()
'''


class PublisherTests(unittest.TestCase):
    """Use disposable repositories; no test can address the production repositories."""

    def setUp(self) -> None:
        """Create independent application, child, canonical and mirror repositories."""
        self.temporary = tempfile.TemporaryDirectory(prefix="polygon-publish-offline-")
        self.base = Path(self.temporary.name)
        self.app = self.base / "app"
        self.child = self.app / "data" / "polygon"
        self.origin = self.base / "canonical.git"
        self.decoy_origin = self.base / "decoy.git"
        self.mirror = self.base / "mirror.git"
        self.child_origin = self.base / "child.git"
        self.archive = self.base / "archive"
        self.bin = self.base / "bin"
        self.home = self.base / "home"
        self.state_path = self.base / "gh-state.json"
        self.decoy_state_path = self.base / "gh-decoy-state.json"
        self.calls_path = self.base / "gh-calls.jsonl"
        self.bindings_path = self.base / "gh-bindings.jsonl"
        self.git_actions = self.base / "git-actions.jsonl"
        self.counter = self.archive / ".polygon-gitlink-fails"
        self.forbidden_push = self.base / "forbidden-push"
        self.race_done = self.base / "race-done"
        self.invocation_number = 0
        located_git = shutil.which("git")
        if located_git is None:
            self.skipTest("Git is unavailable")
        self.real_git = located_git
        for directory in [self.child, self.archive, self.bin, self.home]:
            directory.mkdir(parents=True, exist_ok=True)
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "LC_ALL": "C",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Offline fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Offline fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+00:00",
            "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+00:00",
            "GH_CONFIG_DIR": str(self.home / "gh"),
            "GH_HOST": "example.invalid",
            "GH_REPO": "unrelated/ambient-fixture",
            "GH_PROMPT_DISABLED": "1",
            "SNAPPER_APP_ROOT": str(self.app),
            "SNAPPER_ARCHIVE_ROOT": str(self.archive),
            "SNAPPER_GITLINK_REMOTES": "origin mirror",
            "MOCK_REAL_GIT": self.real_git,
            "MOCK_GH_ORIGIN": str(self.origin),
            "MOCK_GH_DECOY_ORIGIN": str(self.decoy_origin),
            "MOCK_GH_STATE": str(self.state_path),
            "MOCK_GH_DECOY_STATE": str(self.decoy_state_path),
            "MOCK_GH_CALLS": str(self.calls_path),
            "MOCK_GH_BINDINGS": str(self.bindings_path),
            "MOCK_GIT_ACTIONS": str(self.git_actions),
            "MOCK_FORBIDDEN_PUSH": str(self.forbidden_push),
            "MOCK_GIT_RACE_DONE": str(self.race_done),
        }
        for path, source in [
            (self.bin / "gh", GH_SCRIPT),
            (self.bin / "git", GIT_SCRIPT),
        ]:
            path.write_text(source)
            path.chmod(0o755)
        self.create_repositories()

    def create_repositories(self) -> None:
        """Seed local repositories and conflicting raw GitHub identities for the CLI."""
        self.write_state()
        self.decoy_state_path.write_text(self.state_path.read_text())
        for repository in [
            self.origin,
            self.decoy_origin,
            self.mirror,
            self.child_origin,
        ]:
            self.git(
                self.base,
                "init",
                "--quiet",
                "--bare",
                "--initial-branch=master",
                str(repository),
            )
        self.git(self.child, "init", "--quiet", "--initial-branch=master")
        (self.child / "README.md").write_text("Synthetic data fixture\n")
        self.git(self.child, "add", "README.md")
        self.git(self.child, "commit", "--quiet", "-m", "Initial child fixture")
        self.initial_child = self.rev(self.child, "HEAD")
        self.git(self.child, "remote", "add", "origin", str(self.child_origin))
        self.git(self.child, "push", "--quiet", "origin", "master")
        self.git(self.app, "init", "--quiet", "--initial-branch=master")
        (self.app / "README.md").write_text("Canonical application fixture\n")
        (self.app / "staged.txt").write_text("Initial staged fixture\n")
        (self.app / ".gitmodules").write_text(
            '[submodule "data/polygon"]\n\tpath = data/polygon\n'
            f"\turl = {self.child_origin}\n"
        )
        self.git(self.app, "add", "README.md", "staged.txt", ".gitmodules")
        self.git(
            self.app,
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{self.initial_child},data/polygon",
        )
        self.git(self.app, "commit", "--quiet", "-m", "Initial application fixture")
        self.initial_master = self.rev(self.app, "HEAD")
        self.git(self.app, "remote", "add", "origin", ORIGIN_URL)
        self.git(
            self.app, "config", "--add", f"url.{self.origin}.insteadOf", ORIGIN_URL
        )
        self.git(
            self.app, "remote", "add", "shadow", "git@github.com:offline/decoy.git"
        )
        self.git(self.app, "config", "remote.shadow.gh-resolved", "base")
        self.git(self.app, "remote", "add", "mirror", str(self.mirror))
        self.git(self.app, "push", "--quiet", "origin", "master")
        self.git(self.app, "push", "--quiet", "mirror", "master")
        self.target = self.advance_child()

    def tearDown(self) -> None:
        """Fail any force-push attempt, then remove only this test's temporary files."""
        try:
            self.assertFalse(
                self.forbidden_push.exists(), "Publisher attempted a force push"
            )
            self.assert_canonical_gh_calls()
        finally:
            self.temporary.cleanup()

    def git(self, repository: Path, *args: str, input_text: str | None = None) -> str:
        """Execute Git only through the verified system binary and fixture environment."""
        result = subprocess.run(
            [self.real_git, "-C", str(repository), *args],
            env=self.env,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        if result.returncode:
            self.fail(f"Fixture Git failed: {args}: {result.stderr}")
        return result.stdout.strip()

    def rev(self, repository: Path, ref: str) -> str:
        """Read an exact fixture object identifier."""
        return self.git(repository, "rev-parse", ref)

    def branch_exists(self) -> bool:
        """Inspect only the canonical bare repository's automation reference."""
        result = subprocess.run(
            [
                self.real_git,
                "--git-dir",
                str(self.origin),
                "show-ref",
                "--verify",
                f"refs/heads/{BRANCH}",
            ],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        return result.returncode == 0

    def write_state(self, **updates: bool | int | str) -> None:
        """Update the mock's bounded synthetic API state."""
        state: dict[str, object]
        if self.state_path.exists():
            state = cast(dict[str, object], json.loads(self.state_path.read_text()))
        else:
            state = {
                "open": False,
                "number": 1,
                "managed": True,
                "cross_repository": False,
                "fail_operation": "",
                "merge_immediately": False,
            }
        state.update(updates)
        self.state_path.write_text(json.dumps(state))

    def state(self) -> GhState:
        """Read only the fake GitHub state."""
        return cast(GhState, json.loads(self.state_path.read_text()))

    def calls(self, operation: str) -> list[list[str]]:
        """Return recorded invocations of one fake GitHub operation."""
        if not self.calls_path.exists():
            return []
        values = [
            cast(list[str], json.loads(line))
            for line in self.calls_path.read_text().splitlines()
        ]
        return [value for value in values if value[:2] == ["pr", operation]]

    def assert_canonical_gh_calls(self) -> None:
        """Require every publisher API call to explicitly select canonical host and repo."""
        for operation in ["list", "create", "merge", "close"]:
            for call in self.calls(operation):
                self.assertEqual(call.count("--repo"), 1, call)
                self.assertEqual(call[call.index("--repo") + 1], GH_REPOSITORY, call)
        if self.bindings_path.exists():
            for line in self.bindings_path.read_text().splitlines():
                binding = cast(dict[str, str], json.loads(line))
                self.assertEqual(binding["repository"], GH_REPOSITORY)

    def replace_origin(self, url: str) -> None:
        """Set a raw origin identity while keeping all transport on local fixture paths."""
        self.git(self.app, "remote", "set-url", "origin", url)
        self.git(self.app, "config", "--add", f"url.{self.origin}.insteadOf", url)

    def advance_child(self, *, publish: bool = True) -> str:
        """Create a synthetic child snapshot, optionally leaving it unpublished."""
        path = self.child / "snapshot.txt"
        previous = path.read_text() if path.exists() else ""
        path.write_text(previous + "Synthetic snapshot\n")
        self.git(self.child, "add", "snapshot.txt")
        self.git(
            self.child, "commit", "--quiet", "-m", "Advance synthetic child snapshot"
        )
        if publish:
            self.git(self.child, "push", "--quiet", "origin", "master")
        return self.rev(self.child, "HEAD")

    def tree_commit(
        self,
        parent: str,
        *,
        child: str | None = None,
        readme: str | None = None,
        managed: bool = True,
    ) -> str:
        """Build isolated fixture commits without changing the application checkout."""
        index = self.base / "fixture-index"
        env = dict(self.env, GIT_INDEX_FILE=str(index))
        subprocess.run(
            [self.real_git, "-C", str(self.app), "read-tree", parent],
            env=env,
            capture_output=True,
            check=True,
            timeout=20,
        )
        if child is not None:
            subprocess.run(
                [
                    self.real_git,
                    "-C",
                    str(self.app),
                    "update-index",
                    "--cacheinfo",
                    f"160000,{child},data/polygon",
                ],
                env=env,
                capture_output=True,
                check=True,
                timeout=20,
            )
        if readme is not None:
            blob = self.git(self.app, "hash-object", "-w", "--stdin", input_text=readme)
            subprocess.run(
                [
                    self.real_git,
                    "-C",
                    str(self.app),
                    "update-index",
                    "--cacheinfo",
                    f"100644,{blob},README.md",
                ],
                env=env,
                capture_output=True,
                check=True,
                timeout=20,
            )
        tree = subprocess.check_output(
            [self.real_git, "-C", str(self.app), "write-tree"],
            env=env,
            text=True,
            timeout=20,
        ).strip()
        index.unlink()
        message = "Synthetic fixture update"
        if managed:
            message += f"\n\n{MARKER}"
        return self.git(self.app, "commit-tree", tree, "-p", parent, "-m", message)

    def publish_canonical(
        self, *, child: str | None = None, readme: str | None = None
    ) -> str:
        """Advance canonical master by an ordinary fixture fast-forward."""
        parent = self.rev(self.origin, "master")
        commit = self.tree_commit(parent, child=child, readme=readme, managed=False)
        self.git(self.app, "push", "--quiet", "origin", f"{commit}:refs/heads/master")
        return commit

    def invoke(self) -> subprocess.CompletedProcess[str]:
        """Run only the publisher with temporary roots, mock APIs and file-only Git."""
        self.assertTrue(
            PUBLISHER.is_file(), "Publisher implementation is not available"
        )
        self.invocation_number += 1
        env = dict(self.env)
        date = f"2000-01-01T00:00:{self.invocation_number:02d}+00:00"
        env.update(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        return subprocess.run(
            ["bash", str(PUBLISHER)],
            cwd=self.app,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def invoke_daily(self) -> subprocess.CompletedProcess[str]:
        """Exercise the real wrapper with copied scripts and a harmless synthetic CLI."""
        script_directory = self.base / "daily-bin"
        script_directory.mkdir()
        daily = script_directory / "polygon-daily.sh"
        shutil.copy2(ROOT / "bin" / "polygon-daily.sh", daily)
        shutil.copy2(PUBLISHER, script_directory / "polygon-publish-gitlink.sh")
        (script_directory / "_alert.sh").write_text(
            "snapper_alert_on_failure() { :; }\n"
        )
        cli = self.app / ".venv" / "bin" / "snapper"
        cli.parent.mkdir(parents=True)
        cli.write_text("#!/bin/sh\nexit 0\n")
        cli.chmod(0o755)
        environment = self.base / "dummy.env"
        environment.write_text("DB_URL=postgresql+asyncpg://fixture.invalid/offline\n")
        env = dict(self.env)
        env.update(
            SNAPPER_ENV_FILE=str(environment),
            SNAPPER_DB_HOST_FROM="fixture.invalid",
            SNAPPER_DB_HOST_TO="fixture.invalid",
            SKIP_FETCH="1",
            SKIP_LOAD="1",
            MIN_FREE_GB="0",
            GROUPED_DAYS="1",
        )
        return subprocess.run(
            ["bash", str(daily)],
            cwd=self.app,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def assert_success(self, result: subprocess.CompletedProcess[str]) -> None:
        """Require successful scheduling/current publication and safe cleanup."""
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.counter.exists())
        self.assertEqual(
            self.git(
                self.app,
                "for-each-ref",
                "--format=%(refname)",
                "refs/snapper-polygon-publish/",
            ),
            "",
        )
        self.assertEqual(
            self.git(
                self.child,
                "for-each-ref",
                "--format=%(refname)",
                "refs/snapper-polygon-publish/",
            ),
            "",
        )

    def assert_first_failure(self, result: subprocess.CompletedProcess[str]) -> None:
        """Require a nonzero first failure and the existing counter's increment."""
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.counter.read_text().strip(), "1")
        self.assertIn("gitlink: FAILED", result.stdout + result.stderr)

    def test_new_pr_is_pending_and_mirrors_only_approved_master(self) -> None:
        """A new snapshot creates one managed PR without publishing it as master."""
        result = self.invoke()
        self.assert_success(result)
        self.assertIn("PENDING", result.stdout)
        self.assertEqual(self.rev(self.origin, "master"), self.initial_master)
        self.assertEqual(self.rev(self.mirror, "master"), self.initial_master)
        head = self.rev(self.origin, BRANCH)
        self.assertEqual(self.rev(self.app, f"{head}:data/polygon"), self.target)
        self.assertEqual(len(self.calls("create")), 1)
        self.assertTrue(self.state()["open"])
        self.assertIn("--auto", self.calls("merge")[0])
        self.assertIn("--match-head-commit", self.calls("merge")[0])

    def test_explicit_repository_ignores_configured_and_ambient_defaults(self) -> None:
        """Conflicting CLI defaults cannot redirect creation, merge or stale closure."""
        self.assertEqual(
            self.git(self.app, "config", "--get", "remote.shadow.gh-resolved"),
            "base",
        )
        self.assertEqual(self.env["GH_HOST"], "example.invalid")
        self.assertEqual(self.env["GH_REPO"], "unrelated/ambient-fixture")
        self.assert_success(self.invoke())
        self.publish_canonical(child=self.target)
        self.assert_success(self.invoke())
        for operation in ["list", "create", "merge", "close"]:
            self.assertTrue(self.calls(operation), operation)
        self.assert_canonical_gh_calls()
        decoy = cast(GhState, json.loads(self.decoy_state_path.read_text()))
        self.assertFalse(decoy["open"])
        self.assertFalse((self.decoy_origin / "refs" / "heads" / "master").exists())

    def test_mock_without_repo_binds_the_conflicting_default_to_decoy(self) -> None:
        """The CLI double must reproduce the wrong-repository behavior it guards."""
        state = cast(dict[str, object], json.loads(self.decoy_state_path.read_text()))
        state["fail_operation"] = "list"
        self.decoy_state_path.write_text(json.dumps(state))
        bindings = self.base / "probe-bindings.jsonl"
        env = dict(self.env)
        env.pop("GH_REPO")
        env.pop("GH_HOST")
        env.update(
            MOCK_GH_CALLS=str(self.base / "probe-calls.jsonl"),
            MOCK_GH_BINDINGS=str(bindings),
        )
        result = subprocess.run(
            [str(self.bin / "gh"), "pr", "list"],
            cwd=self.app,
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        binding = cast(dict[str, str], json.loads(bindings.read_text()))
        self.assertEqual(binding["repository"], GH_DECOY)
        self.assertFalse(self.state()["open"])

    def test_ssh_origins_bind_raw_identity_before_local_url_rewriting(self) -> None:
        """Both normal SSH URL forms select GitHub despite their local transport rewrite."""
        for url in [
            "ssh://git@github.com/offline/snapper.git",
            "ssh://git@github.com:22/offline/snapper.git",
        ]:
            with self.subTest(url=url):
                self.replace_origin(url)
                self.assertEqual(
                    self.git(self.app, "config", "--get-all", "remote.origin.url"),
                    url,
                )
                self.assertEqual(
                    self.git(self.app, "remote", "get-url", "origin"),
                    str(self.origin),
                )
                self.assert_success(self.invoke())
                self.assert_canonical_gh_calls()

    def test_https_origin_secrets_and_query_never_reach_output_or_gh(self) -> None:
        """Synthetic userinfo, query and fragment are excluded from every API selector."""
        sentinels = ["SYNTHETIC_USER", "SYNTHETIC_PASSWORD", "SYNTHETIC_QUERY"]
        for host in ["github.com", "github.com:443"]:
            with self.subTest(host=host):
                url = (
                    f"https://{sentinels[0]}:{sentinels[1]}@{host}"
                    f"/offline/snapper.git?token={sentinels[2]}#SYNTHETIC_FRAGMENT"
                )
                self.replace_origin(url)
                self.assertEqual(
                    self.git(self.app, "config", "--get-all", "remote.origin.url"),
                    url,
                )
                result = self.invoke()
                self.assert_success(result)
                observed = result.stdout + result.stderr + self.calls_path.read_text()
                for sentinel in [*sentinels, "SYNTHETIC_FRAGMENT"]:
                    self.assertNotIn(sentinel, observed)
                self.assert_canonical_gh_calls()

    def test_unsupported_origins_fail_before_any_fetch_or_api_action(self) -> None:
        """Unsupported identity formats fail even when a local rewrite could fetch them."""
        for url in [
            str(self.origin),
            "git@gitlab.com:offline/snapper.git",
            "ssh://git@github.com:2222/offline/snapper.git",
            "https://github.com.evil.invalid/offline/snapper.git",
            "https://github.com@evil.invalid/offline/snapper.git",
            "https://github.com/offline/snapper/extra.git",
        ]:
            with self.subTest(url=url):
                self.counter.unlink(missing_ok=True)
                self.replace_origin(url)
                self.assert_first_failure(self.invoke())
                self.assertFalse(self.git_actions.exists())
                self.assertFalse(self.calls_path.exists())
                self.assertFalse(self.branch_exists())

    def test_multiple_origins_fail_before_any_fetch_or_api_action(self) -> None:
        """An ambiguous canonical origin cannot silently select one configured URL."""
        self.git(
            self.app,
            "config",
            "--add",
            "remote.origin.url",
            "https://github.com/offline/decoy.git",
        )
        self.assert_first_failure(self.invoke())
        self.assertFalse(self.git_actions.exists())
        self.assertFalse(self.calls_path.exists())
        self.assertFalse(self.branch_exists())

    def test_pending_age_survives_an_update_and_reminds_after_a_day(self) -> None:
        """An old accepted PR keeps its first queue time without becoming a failure."""
        self.assert_success(self.invoke())
        pending = self.archive / ".polygon-gitlink-pending"
        first_seen = int(time.time()) - 90000
        pending.write_text(f"1 {first_seen}\n")
        self.advance_child()
        result = self.invoke()
        self.assert_success(result)
        self.assertEqual(pending.read_text().split(), ["1", str(first_seen)])
        self.assertIn("at least a day", result.stdout)
        self.assertTrue(self.state()["open"])

    def test_pending_retry_reuses_pr_and_exact_branch_head(self) -> None:
        """Retrying unchanged pending data does not manufacture another commit or PR."""
        self.assert_success(self.invoke())
        head = self.rev(self.origin, BRANCH)
        self.assert_success(self.invoke())
        self.assertEqual(self.rev(self.origin, BRANCH), head)
        self.assertEqual(len(self.calls("create")), 1)

    def test_pending_update_fastforwards_existing_branch(self) -> None:
        """A newer published snapshot appends history to the existing automation branch."""
        self.assert_success(self.invoke())
        previous = self.rev(self.origin, BRANCH)
        target = self.advance_child()
        self.assert_success(self.invoke())
        head = self.rev(self.origin, BRANCH)
        self.git(self.app, "merge-base", "--is-ancestor", previous, head)
        self.assertEqual(self.rev(self.app, f"{head}:data/polygon"), target)
        self.assertEqual(len(self.calls("create")), 1)

    def test_pending_update_preserves_new_canonical_files(self) -> None:
        """A moved canonical master becomes the desired tree even for unchanged data."""
        self.assert_success(self.invoke())
        previous = self.rev(self.origin, BRANCH)
        canonical = self.publish_canonical(readme="Reviewed canonical advance\n")
        self.assert_success(self.invoke())
        head = self.rev(self.origin, BRANCH)
        self.git(self.app, "merge-base", "--is-ancestor", canonical, head)
        self.git(self.app, "merge-base", "--is-ancestor", previous, head)
        self.assertEqual(
            self.git(self.app, "show", f"{head}:README.md"),
            "Reviewed canonical advance",
        )
        self.assertEqual(self.rev(self.app, f"{head}:data/polygon"), self.target)
        self.assertEqual(self.rev(self.mirror, "master"), canonical)

    def test_unpublished_child_is_refused_before_publication(self) -> None:
        """A local-only child commit never becomes an advertised parent gitlink."""
        self.advance_child(publish=False)
        self.assert_first_failure(self.invoke())
        self.assertFalse(self.branch_exists())
        self.assertFalse(self.calls("create"))
        self.assertEqual(self.rev(self.origin, "master"), self.initial_master)

    def test_non_gitlink_automation_change_is_refused(self) -> None:
        """A marked automation commit that edits another file still requires review."""
        self.assert_success(self.invoke())
        previous = self.rev(self.origin, BRANCH)
        changed = self.tree_commit(previous, readme="Unmanaged branch edit\n")
        self.git(
            self.app, "push", "--quiet", "origin", f"{changed}:refs/heads/{BRANCH}"
        )
        self.assert_first_failure(self.invoke())
        self.assertEqual(self.rev(self.origin, BRANCH), changed)
        self.assertEqual(len(self.calls("merge")), 1)

    def test_markerless_automation_history_is_refused(self) -> None:
        """A gitlink-only commit without automation provenance is not overwritten."""
        self.assert_success(self.invoke())
        previous = self.rev(self.origin, BRANCH)
        target = self.advance_child()
        changed = self.tree_commit(previous, child=target, managed=False)
        self.git(
            self.app, "push", "--quiet", "origin", f"{changed}:refs/heads/{BRANCH}"
        )
        self.assert_first_failure(self.invoke())
        self.assertEqual(self.rev(self.origin, BRANCH), changed)

    def test_unmanaged_pr_is_not_modified(self) -> None:
        """A missing managed-body marker prevents reuse or closure of the PR."""
        self.assert_success(self.invoke())
        self.write_state(managed=False)
        self.assert_first_failure(self.invoke())
        self.assertTrue(self.state()["open"])
        self.assertFalse(self.calls("close"))

    def test_cross_repository_pr_is_not_modified(self) -> None:
        """A fork PR with the same branch name is never treated as managed automation."""
        self.assert_success(self.invoke())
        self.write_state(cross_repository=True)
        self.assert_first_failure(self.invoke())
        self.assertTrue(self.state()["open"])

    def test_branch_push_rejection_reports_first_failure(self) -> None:
        """A server-side rejection increments the counter and cannot become a PR."""
        hook = self.origin / "hooks" / "pre-receive"
        hook.write_text(
            "#!/bin/sh\nwhile read old new ref; do\n"
            '  if [ "$ref" = "refs/heads/automation/polygon-gitlink" ]; then exit 1; fi\n'
            "done\nexit 0\n"
        )
        hook.chmod(0o755)
        self.assert_first_failure(self.invoke())
        self.assertFalse(self.branch_exists())
        self.assertFalse(self.calls("create"))

    def test_api_list_failure_reports_first_failure(self) -> None:
        """A failed API read is not interpreted as an empty PR list."""
        self.write_state(fail_operation="list")
        self.assert_first_failure(self.invoke())
        self.assertFalse(self.calls("create"))

    def test_api_create_failure_can_retry_without_another_commit(self) -> None:
        """A pushed branch survives a creation failure and is reused on retry."""
        self.write_state(fail_operation="create")
        self.assert_first_failure(self.invoke())
        previous = self.rev(self.origin, BRANCH)
        self.write_state(fail_operation="")
        self.assert_success(self.invoke())
        self.assertEqual(self.rev(self.origin, BRANCH), previous)
        self.assertTrue(self.state()["open"])

    def test_api_merge_failure_reports_first_failure(self) -> None:
        """A rejected auto-merge request is a publication failure on its first run."""
        self.write_state(fail_operation="merge")
        self.assert_first_failure(self.invoke())
        self.assertTrue(self.state()["open"])
        self.assertEqual(self.rev(self.origin, "master"), self.initial_master)

    def test_match_head_rejection_is_not_bypassed(self) -> None:
        """The publisher refuses when GitHub cannot match the reviewed head."""
        self.write_state(fail_operation="match_head")
        self.assert_first_failure(self.invoke())
        self.assertEqual(self.rev(self.origin, "master"), self.initial_master)
        calls = self.calls("merge")
        self.assertEqual(len(calls), 2)
        head = self.rev(self.origin, BRANCH)
        for call in calls:
            self.assertIn("--merge", call)
            self.assertIn("--match-head-commit", call)
            self.assertEqual(call[call.index("--match-head-commit") + 1], head)
        self.assertIn("--auto", calls[0])
        self.assertNotIn("--auto", calls[1])

    def test_stale_pr_closes_when_canonical_already_has_new_target(self) -> None:
        """An old pending PR is closed before it could restore an older data pin."""
        self.assert_success(self.invoke())
        previous = self.rev(self.origin, BRANCH)
        target = self.advance_child()
        canonical = self.publish_canonical(child=target)
        result = self.invoke()
        self.assert_success(result)
        self.assertIn("CLOSED", result.stdout)
        self.assertFalse((self.archive / ".polygon-gitlink-pending").exists())
        self.assertFalse(self.state()["open"])
        self.assertEqual(self.rev(self.origin, BRANCH), previous)
        self.assertEqual(self.rev(self.mirror, "master"), canonical)
        self.assertEqual(len(self.calls("merge")), 1)

    def test_stale_pr_close_failure_reports_first_failure(self) -> None:
        """A failed close cannot be reported as a safe completed current state."""
        self.assert_success(self.invoke())
        self.publish_canonical(child=self.target)
        self.write_state(fail_operation="close")
        self.assert_first_failure(self.invoke())
        self.assertTrue(self.state()["open"])

    def test_immediate_merge_mirrors_actual_approved_merge_commit(self) -> None:
        """An already-mergeable PR can merge immediately and its actual result is mirrored."""
        self.write_state(merge_immediately=True)
        result = self.invoke()
        self.assert_success(result)
        self.assertIn("MERGED", result.stdout)
        approved = self.rev(self.origin, "master")
        candidate = self.rev(self.origin, BRANCH)
        self.assertNotEqual(approved, candidate)
        self.assertEqual(self.rev(self.app, f"{approved}:data/polygon"), self.target)
        self.assertEqual(self.rev(self.mirror, "master"), approved)
        self.assertFalse(self.state()["open"])

    def test_mirror_divergence_is_preserved_and_fails_on_first_run(self) -> None:
        """A diverged mirror cannot be force-reset or supplied with a pending candidate."""
        divergent = self.tree_commit(
            self.initial_master, readme="Independent mirror history\n", managed=False
        )
        self.git(
            self.app, "push", "--quiet", "mirror", f"{divergent}:refs/heads/master"
        )
        self.assert_first_failure(self.invoke())
        self.assertEqual(self.rev(self.mirror, "master"), divergent)
        self.assertEqual(self.rev(self.origin, "master"), self.initial_master)

    def test_clean_auto_merge_rejection_falls_back_with_same_head_fence(self) -> None:
        """An already-clean PR falls back to an ordinary merge with the identical fence."""
        self.write_state(fail_operation="auto_clean")
        result = self.invoke()
        self.assert_success(result)
        self.assertIn("MERGED", result.stdout)
        calls = self.calls("merge")
        self.assertEqual(len(calls), 2)
        self.assertIn("--auto", calls[0])
        self.assertNotIn("--auto", calls[1])
        candidate = self.rev(self.origin, BRANCH)
        for call in calls:
            self.assertIn("--merge", call)
            self.assertEqual(call[call.index("--match-head-commit") + 1], candidate)
        approved = self.rev(self.origin, "master")
        self.assertNotEqual(approved, candidate)
        self.assertEqual(self.rev(self.mirror, "master"), approved)
        self.assertEqual(self.rev(self.app, f"{approved}:data/polygon"), self.target)
        self.assertFalse(self.state()["open"])

    def test_concurrent_branch_advance_is_not_overwritten(self) -> None:
        """A normal push fails safely if another actor advances the branch after fetch."""
        self.assert_success(self.invoke())
        previous = self.rev(self.origin, BRANCH)
        self.advance_child()
        raced = self.tree_commit(previous, managed=False)
        self.git(
            self.app, "push", "--quiet", "origin", f"{raced}:refs/heads/race-object"
        )
        self.env["MOCK_GIT_RACE_COMMIT"] = raced
        self.assert_first_failure(self.invoke())
        self.assertTrue(self.race_done.exists())
        self.assertEqual(self.rev(self.origin, BRANCH), raced)
        self.assertEqual(self.rev(self.origin, "master"), self.initial_master)

    def test_daily_wrapper_fails_on_first_publication_error(self) -> None:
        """The actual daily wrapper returns nonzero for its first publication error."""
        self.write_state(fail_operation="merge")
        result = self.invoke_daily()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.counter.read_text().strip(), "1")
        self.assertEqual(self.rev(self.origin, "master"), self.initial_master)
        log = next((self.archive / "logs").glob("polygon-????-??.log"))
        self.assertIn("gitlink: FAILED", log.read_text())

    def test_daily_wrapper_fails_on_first_mirror_divergence(self) -> None:
        """The daily wrapper retains a diverged mirror and reports its first failure."""
        divergent = self.tree_commit(
            self.initial_master, readme="Mirror divergence\n", managed=False
        )
        self.git(
            self.app, "push", "--quiet", "mirror", f"{divergent}:refs/heads/master"
        )
        result = self.invoke_daily()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.counter.read_text().strip(), "1")
        self.assertEqual(self.rev(self.mirror, "master"), divergent)
        log = next((self.archive / "logs").glob("polygon-????-??.log"))
        self.assertIn("gitlink: FAILED", log.read_text())

    def test_flock_operational_error_is_a_first_failure(self) -> None:
        """A broken lock utility cannot be mistaken for a healthy concurrent skip."""
        flock = self.bin / "flock"
        flock.write_text("#!/bin/sh\nexit 69\n")
        flock.chmod(0o755)
        self.assert_first_failure(self.invoke())
        self.assertFalse(self.calls_path.exists())
        self.assertFalse(self.branch_exists())

    def test_held_lock_is_a_healthy_skip_and_preserves_failure_history(self) -> None:
        """A genuine held lock skips without creating a PR or resetting old failures."""
        self.counter.write_text("2\n")
        with (self.archive / ".polygon-gitlink.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SKIP", result.stdout)
        self.assertEqual(self.counter.read_text(), "2\n")
        self.assertFalse(self.calls_path.exists())
        self.assertFalse(self.branch_exists())

    def test_shared_head_index_and_working_files_are_untouched(self) -> None:
        """Publication leaves both staged and unstaged interactive work byte-identical."""
        (self.app / "staged.txt").write_text("User staged change\n")
        self.git(self.app, "add", "staged.txt")
        (self.app / "README.md").write_text("User unstaged change\n")
        (self.app / "untracked.bin").write_bytes(b"synthetic user file\x00")
        head = self.rev(self.app, "HEAD")
        symbolic_head = self.git(self.app, "symbolic-ref", "HEAD")
        index = (self.app / ".git" / "index").read_bytes()
        child = self.rev(self.child, "HEAD")
        self.assert_success(self.invoke())
        self.assertEqual((self.app / ".git" / "index").read_bytes(), index)
        self.assertEqual(self.rev(self.app, "HEAD"), head)
        self.assertEqual(self.git(self.app, "symbolic-ref", "HEAD"), symbolic_head)
        self.assertEqual(self.rev(self.child, "HEAD"), child)
        self.assertEqual((self.app / "staged.txt").read_text(), "User staged change\n")
        self.assertEqual((self.app / "README.md").read_text(), "User unstaged change\n")
        self.assertEqual(
            (self.app / "untracked.bin").read_bytes(), b"synthetic user file\x00"
        )


if __name__ == "__main__":
    unittest.main()
