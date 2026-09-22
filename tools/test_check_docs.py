"""Unit tests for the check_docs research-path gate."""

from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import check_docs


class ResearchPathTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        root = Path(self.scratch.name) / "zdtd-server"
        research = Path(self.scratch.name) / "7dtd-engine-research"
        (research / "docs" / "network").mkdir(parents=True)
        (research / "docs" / "network" / "protocol.md").write_text("", encoding="utf-8")
        root.mkdir()
        self.root = root
        self.research = research
        self.page = root / "docs" / "page.md"

    def check(self, text: str) -> list[str]:
        failures: list[str] = []
        with mock.patch.object(check_docs, "ROOT", self.root), mock.patch.object(
            check_docs, "RESEARCH_ROOT", self.research
        ):
            check_docs.check_research_paths(text, self.page, failures)
        return failures

    def test_existing_path_passes(self):
        text = "see `../7dtd-engine-research/docs/network/protocol.md` for the wire"
        self.assertEqual([], self.check(text))

    def test_trailing_sentence_punctuation_is_trimmed(self):
        text = "see ../7dtd-engine-research/docs/network/protocol.md."
        self.assertEqual([], self.check(text))

    def test_missing_path_fails(self):
        text = "see `../7dtd-engine-research/docs/network/gone.md`"
        failures = self.check(text)
        self.assertEqual(1, len(failures))
        self.assertIn("gone.md does not exist", failures[0])

    def test_absent_research_sibling_skips(self):
        failures: list[str] = []
        with mock.patch.object(check_docs, "ROOT", self.root), mock.patch.object(
            check_docs, "RESEARCH_ROOT", self.research / "not-checked-out"
        ):
            checked = check_docs.check_research_paths(
                "../7dtd-engine-research/docs/network/gone.md", self.page, failures
            )
        self.assertEqual(0, checked)
        self.assertEqual([], failures)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
