"""Offline tests: real git histories, fake GitHub/Apple boundary data."""

import base64
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error

SPEC = importlib.util.spec_from_file_location(
    "testflight_notes", Path(__file__).resolve().parents[1] / "testflight_notes.py"
)
notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notes)
REPO = "AndreasSko/meh.md"


def body(text):
    return f"## Release notes\n\n{notes.START}\n{text}\n{notes.END}\n"


def pr(number, sha, text="- Better note editing.", **overrides):
    result = {"number": number, "merge_commit_sha": sha, "body": body(text),
              "merged_at": "2026-09-23T10:00:00Z",
              "base": {"ref": "main", "repo": {"full_name": REPO}}}
    result.update(overrides)
    return result


class MemoryState:
    def __init__(self):
        self.files = {}
        self.writes = []

    def read(self, path):
        return copy.deepcopy(self.files.get(path))

    def write(self, files):
        self.writes.append(copy.deepcopy(files))
        self.files.update(copy.deepcopy(files))


class ParseTests(unittest.TestCase):
    def test_only_marked_text_is_published(self):
        self.assertEqual(notes.extract_notes("Private implementation\n" + body("- Fixed sync.")
                                             + "## Testing\nUnit tests"), "- Fixed sync.")

    def test_none_is_explicit_opt_out(self):
        self.assertIsNone(notes.extract_notes(body("None")))

    def test_line_endings_and_whitespace(self):
        self.assertEqual(notes.extract_notes(body("  - Fixed sync.  \n\nTest offline.  ")
                                             .replace("\n", "\r\n")),
                         "- Fixed sync.\n\nTest offline.")

    def test_invalid_sections(self):
        samples = [None, "", body(""), body("None\n- A fix."), body("none"),
                   body("TODO: describe user-visible changes."), body("TBD"),
                   body("PLACEHOLDER"), body("..."), body("<!-- hidden -->"),
                   body("```\ncode\n```"), body("~~~\ncode\n~~~"),
                   body("Some\x00thing"), body("x") + body("y"),
                   notes.END + "\n" + notes.START, "```markdown\n" + body("x") + "```"]
        for sample in samples:
            with self.subTest(sample=sample), self.assertRaises(notes.NotesError):
                notes.extract_notes(sample)

    def test_preceding_closed_code_block_is_allowed(self):
        self.assertEqual(notes.extract_notes("```\nexample\n```\n" + body("Fine.")), "Fine.")

    def test_length_limit(self):
        self.assertEqual(notes.extract_notes(body("x" * 4000)), "x" * 4000)
        with self.assertRaises(notes.NotesError):
            notes.extract_notes(body("x" * 4001))

    def test_emoji_length_is_conservative(self):
        notes.check_length("😀" * 2000)
        with self.assertRaises(notes.NotesError):
            notes.check_length("😀" * 2001)

    def test_shell_text_is_data(self):
        text = '- Keep $(touch /tmp/never) and `commands` literal.\n::error::text'
        self.assertEqual(notes.extract_notes(body(text)), text)

    def test_template_requires_an_author_decision(self):
        template = Path(__file__).resolve().parents[2] / ".github/pull_request_template.md"
        with self.assertRaises(notes.NotesError):
            notes.extract_notes(template.read_text())


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.previous = os.getcwd()
        os.chdir(self.directory.name)
        notes.git("init", "-b", "main")
        notes.git("config", "user.name", "Test")
        notes.git("config", "user.email", "test@example.invalid")
        self.base = self.commit("baseline")
        self.api = Mock(repository=REPO)
        self.associations = {}
        self.api.pages.side_effect = lambda path: self.associations.get(path.split("/")[2], [])
        self.state = MemoryState()
        self.bootstrap = {platform: {"sha": self.base} for platform in notes.PLATFORMS}

    def tearDown(self):
        os.chdir(self.previous)
        self.directory.cleanup()

    def commit(self, message):
        notes.git("commit", "--allow-empty", "-m", message)
        return notes.git("rev-parse", "HEAD")

    def change(self, number, text="- A fix."):
        sha = self.commit(str(number))
        self.associations[sha] = [pr(number, sha, text)]
        return sha

    def prepare(self, sha, run="1", platform="IOS", state=None):
        return notes.prepare(self.api, state or self.state, platform, sha, run, self.bootstrap)

    def test_multiple_skipped_prs_are_collected_in_history_order(self):
        self.change(1, "- First change.")
        head = self.change(2, "- Second change.")
        text, prs = notes.collect_notes(self.api, self.base, head)
        self.assertEqual(text, "- First change.\n\n- Second change.")
        self.assertEqual([item["number"] for item in prs], [1, 2])

    def test_real_merge_only_queries_mainline_commits(self):
        notes.git("checkout", "-b", "feature")
        self.commit("implementation 1")
        self.commit("implementation 2")
        notes.git("checkout", "main")
        notes.git("merge", "--no-ff", "feature", "-m", "Merge PR")
        head = notes.git("rev-parse", "HEAD")
        self.associations[head] = [pr(1, head)]
        text, prs = notes.collect_notes(self.api, self.base, head)
        self.assertEqual(len(prs), 1)
        self.api.pages.assert_called_once_with(f"/commits/{head}/pulls")

    def test_rebased_pr_is_deduplicated(self):
        first = self.commit("rebase 1")
        head = self.commit("rebase 2")
        self.associations[first] = self.associations[head] = [pr(1, head)]
        _, prs = notes.collect_notes(self.api, self.base, head)
        self.assertEqual(len(prs), 1)

    def test_unmerged_wrong_base_and_future_prs_are_excluded(self):
        head = self.change(1)
        self.associations[head] += [pr(2, head, merged_at=None),
                                   pr(3, head, base={"ref": "feature"}),
                                   pr(4, "f" * 40)]
        _, prs = notes.collect_notes(self.api, self.base, head)
        self.assertEqual([item["number"] for item in prs], [1])

    def test_other_repository_is_excluded(self):
        head = self.commit("wrong repo")
        self.associations[head] = [pr(1, head, base={"ref": "main", "repo": {"full_name": "other/repo"}})]
        with self.assertRaises(notes.NotesError):
            notes.collect_notes(self.api, self.base, head)

    def test_missing_notes_fail_before_snapshot(self):
        head = self.change(1)
        self.associations[head][0]["body"] = "No section"
        with self.assertRaisesRegex(notes.NotesError, "PR #1"):
            self.prepare(head)
        self.assertEqual(self.state.files, {})

    def test_direct_commit_fails_instead_of_hiding_changes(self):
        with self.assertRaisesRegex(notes.NotesError, "no merged main PR"):
            self.prepare(self.commit("direct push"))

    def test_aggregate_length_is_checked(self):
        self.change(1, "x" * 2100)
        head = self.change(2, "y" * 2100)
        with self.assertRaises(notes.NotesError):
            self.prepare(head)
        self.assertEqual(self.state.files, {})

    def test_none_entries_omit_the_word_none(self):
        self.change(1, "None")
        head = self.change(2, "- A fix.")
        text, _ = notes.collect_notes(self.api, self.base, head)
        self.assertEqual(text, "- A fix.")

    def test_all_none_has_honest_fallback(self):
        head = self.change(1, "None")
        self.assertEqual(self.prepare(head)["notes"], notes.FALLBACK)

    def test_explicit_bootstrap_excludes_older_changes(self):
        self.assertEqual(self.prepare(self.base)["notes"], notes.FALLBACK)
        self.api.pages.assert_not_called()

    def test_prepare_does_not_advance_success(self):
        head = self.change(1)
        snapshot = self.prepare(head)
        self.assertIn("runs/1.json", self.state.files)
        self.assertNotIn("latest.json", self.state.files)
        self.assertIsNone(snapshot["publication"])

    def test_retry_reuses_exact_snapshot_after_pr_edit(self):
        head = self.change(1, "- Original.")
        original = self.prepare(head)
        self.associations[head][0]["body"] = body("- Edited.")
        self.api.pages.reset_mock()
        self.assertEqual(self.prepare(head), original)
        self.api.pages.assert_not_called()
        self.assertEqual(len(self.state.writes), 1)

    def test_failed_publication_carries_notes_to_next_run(self):
        self.prepare(self.change(1, "- First."))
        head = self.change(2, "- Second.")
        snapshot = self.prepare(head, "2")
        self.assertEqual(snapshot["baseline"], self.base)
        self.assertEqual(len(snapshot["pull_requests"]), 2)

    def test_success_advances_baseline_atomically(self):
        first = self.change(1)
        snapshot = self.prepare(first)
        result = notes.confirm(self.state, snapshot, {"build_id": "apple-build"})
        self.assertEqual(set(self.state.writes[-1]), {"runs/1.json", "latest.json"})
        self.assertEqual(result["publication"]["build_id"], "apple-build")
        head = self.change(2)
        following = self.prepare(head, "2")
        self.assertEqual(following["baseline"], first)
        self.assertEqual([item["number"] for item in following["pull_requests"]], [2])

    def test_already_published_run_skips_reupload(self):
        head = self.change(1)
        notes.confirm(self.state, self.prepare(head), {"build_id": "apple-build"})
        self.api.pages.reset_mock()
        self.assertIsNotNone(self.prepare(head)["publication"])
        self.api.pages.assert_not_called()

    def test_platforms_have_independent_success_baselines(self):
        first = self.change(1)
        notes.confirm(self.state, self.prepare(first), {"build_id": "ios-build"})
        mac = MemoryState()
        head = self.change(2)
        ios_snapshot = self.prepare(head, "2")
        mac_snapshot = self.prepare(head, "2", "MAC_OS", mac)
        self.assertEqual(ios_snapshot["baseline"], first)
        self.assertEqual(mac_snapshot["baseline"], self.base)
        self.assertEqual(len(mac_snapshot["pull_requests"]), 2)

    def test_stale_unpublished_retry_is_rejected(self):
        first = self.change(1)
        self.prepare(first)
        head = self.change(2)
        notes.confirm(self.state, self.prepare(head, "2"), {"build_id": "newer"})
        with self.assertRaises(notes.NotesError):
            self.prepare(first)

    def test_old_published_run_can_skip_without_rewinding(self):
        first = self.change(1)
        notes.confirm(self.state, self.prepare(first), {"build_id": "first"})
        head = self.change(2)
        notes.confirm(self.state, self.prepare(head, "2"), {"build_id": "second"})
        self.assertIsNotNone(self.prepare(first)["publication"])
        self.assertEqual(self.state.files["latest.json"]["sha"], head)

    def test_snapshot_identity_mismatch_is_rejected(self):
        head = self.change(1)
        self.prepare(head)
        self.state.files["runs/1.json"]["repository"] = "wrong/repo"
        with self.assertRaises(notes.NotesError):
            self.prepare(head)

    def test_changed_snapshot_cannot_be_confirmed(self):
        head = self.change(1)
        snapshot = self.prepare(head)
        snapshot["notes"] = "Not what was uploaded"
        with self.assertRaises(notes.NotesError):
            notes.confirm(self.state, snapshot, {"build_id": "x"})
        self.assertNotIn("latest.json", self.state.files)

    def test_non_ancestor_or_invalid_sha_is_rejected(self):
        head = self.change(1)
        for base, target in [(head, self.base), ("--help", head), ("f" * 40, head)]:
            with self.subTest(base=base), self.assertRaises(notes.NotesError):
                notes.require_ancestor(base, target)


class APITests(unittest.TestCase):
    def test_pagination_includes_second_page(self):
        api = notes.GitHub(REPO, "not-a-real-token")
        api.request = Mock(side_effect=[list(range(100)), [100]])
        self.assertEqual(list(api.pages("/commits/sha/pulls")), list(range(101)))
        self.assertIn("page=2", api.request.call_args.args[1])

    def test_auth_and_request_body_are_not_shell_interpolated(self):
        api = notes.GitHub(REPO, "not-a-real-token")
        with patch.object(notes.urllib.request, "urlopen") as opener:
            opener.return_value.__enter__.return_value = io.BytesIO(b'{"ok": true}')
            self.assertEqual(api.request("POST", "/git/trees", {"content": "$(false)"}), {"ok": True})
            request = opener.call_args.args[0]
            self.assertEqual(json.loads(request.data), {"content": "$(false)"})

    def test_http_failure_is_not_treated_as_empty_notes(self):
        api = notes.GitHub(REPO, "not-a-real-token")
        for code in (403, 429, 500):
            error = urllib.error.HTTPError("test", code, "failure", {}, None)
            with self.subTest(code=code), patch.object(notes.urllib.request, "urlopen", side_effect=error):
                with self.assertRaises(notes.NotesError):
                    api.request("GET", "/git/ref/heads/state", missing=True)

    def test_only_explicit_404_is_missing(self):
        api = notes.GitHub(REPO, "not-a-real-token")
        error = urllib.error.HTTPError("test", 404, "missing", {}, None)
        with patch.object(notes.urllib.request, "urlopen", side_effect=error):
            self.assertIsNone(api.request("GET", "/git/ref/heads/state", missing=True))
            with self.assertRaises(notes.NotesError):
                api.request("GET", "/commits/sha/pulls")

    def test_state_is_read_from_exact_commit(self):
        api = Mock()
        api.request.side_effect = [{"object": {"sha": "a" * 40}}, {
            "encoding": "base64", "content": base64.b64encode(b'{"notes":"hi"}').decode()}]
        state = notes.State(api, "IOS")
        self.assertEqual(state.read("runs/1.json"), {"notes": "hi"})
        self.assertTrue(api.request.call_args.args[1].endswith("?ref=" + "a" * 40))

    def test_initial_state_branch_is_orphan_and_platform_specific(self):
        api = Mock()
        api.request.side_effect = [None, {"sha": "tree"}, {"sha": "commit"}, {}]
        state = notes.State(api, "MAC_OS")
        state.write({"runs/1.json": {"notes": "hi"}})
        self.assertEqual(api.request.call_args_list[2].args[2]["parents"], [])
        self.assertEqual(api.request.call_args.args[2]["ref"], "refs/heads/testflight-state/MAC_OS")

    def test_existing_branch_update_is_never_forced(self):
        api = Mock()
        api.request.side_effect = [{"object": {"sha": "old"}}, {"tree": {"sha": "oldtree"}},
                                   {"sha": "newtree"}, {"sha": "new"}, {}]
        state = notes.State(api, "IOS")
        state.write({"runs/1.json": {}, "latest.json": {}})
        self.assertFalse(api.request.call_args.args[2]["force"])
        self.assertEqual(api.request.call_args_list[3].args[2]["parents"], ["old"])
        tree = api.request.call_args_list[2].args[2]
        self.assertEqual(tree["base_tree"], "oldtree")
        self.assertEqual(len(tree["tree"]), 2)

    def test_rejected_ref_write_is_not_reported_as_success(self):
        api = Mock()
        api.request.side_effect = [None, {"sha": "tree"}, {"sha": "commit"}, notes.NotesError("conflict")]
        state = notes.State(api, "IOS")
        with self.assertRaises(notes.NotesError):
            state.write({"runs/1.json": {}})
        self.assertIsNone(state.head)

    def test_output_is_plain_text_and_json(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            notes.write_snapshot(target, {"notes": "- Test sync.\n\nTry offline."})
            self.assertEqual((target / "notes.txt").read_text(), "- Test sync.\n\nTry offline.")
            self.assertEqual(json.loads((target / "manifest.json").read_text())["notes"],
                             (target / "notes.txt").read_text())


    def test_cli_validates_event_file_without_interpolation(self):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / "event.json"
            event.write_text(json.dumps({"pull_request": {"body": body("- Fixed sync.")}}))
            result = subprocess.run(["python3", str(Path(notes.__file__)), "validate",
                                     "--event", str(event)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            event.write_text(json.dumps({"pull_request": {"body": "missing"}}))
            result = subprocess.run(["python3", str(Path(notes.__file__)), "validate",
                                     "--event", str(event)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_summary_escapes_pr_html(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            notes.write_snapshot(target, {"notes": "<script>unsafe</script>",
                                         "platform": "IOS", "publication": None,
                                         "sha": "a" * 40, "baseline": "b" * 40})
            summary = target / "summary.md"
            env = dict(os.environ, GITHUB_STEP_SUMMARY=str(summary))
            subprocess.run(["python3", str(Path(notes.__file__)), "summary",
                            "--directory", str(target)], env=env, check=True)
            text = summary.read_text()
            self.assertNotIn("<script>", text)
            self.assertIn("&lt;script&gt;", text)
            self.assertIn("not confirmed", text)


if __name__ == "__main__":
    unittest.main()
