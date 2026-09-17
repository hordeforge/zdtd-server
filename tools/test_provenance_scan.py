import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import provenance_scan


class ResearchCitationsTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name) / "clone"
        self.research_docs = Path(self.scratch.name) / "research" / "docs"
        (self.root / "docs" / "subsystems").mkdir(parents=True)
        (self.root / "src" / "wire").mkdir(parents=True)
        (self.research_docs / "network").mkdir(parents=True)
        (self.research_docs / "network" / "protocol.md").write_text("", encoding="utf-8")

    def scan(self):
        return provenance_scan.research_citation_errors(self.root, self.research_docs)

    def test_nested_citations_resolve_against_corpus_not_citing_directory(self):
        (self.root / "docs" / "subsystems" / "wire.md").write_text(
            "`../7dtd-engine-research/docs/network/protocol.md §3`\n"
            "[protocol](../../../7dtd-engine-research/docs/network/protocol.md#wire)\n",
            encoding="utf-8",
        )
        self.assertEqual(self.scan(), [])

    def test_missing_nested_doc_is_reported_with_line_number(self):
        (self.root / "docs" / "PROVENANCE.md").write_text(
            "# Sources\n../7dtd-engine-research/docs/network/missing.md\n",
            encoding="utf-8",
        )
        self.assertEqual(self.scan(), [
            "docs/PROVENANCE.md:2 -> 7dtd-engine-research/docs/network/missing.md"
        ])

    def test_source_citations_are_checked(self):
        (self.root / "src" / "wire" / "stock.zig").write_text(
            "//! RE: ../../7dtd-engine-research/docs/network/missing.md\n",
            encoding="utf-8",
        )
        self.assertEqual(self.scan(), [
            "src/wire/stock.zig:1 -> 7dtd-engine-research/docs/network/missing.md"
        ])

    def test_flat_paths_and_uppercase_underscores_are_checked(self):
        (self.root / "docs" / "PROVENANCE.md").write_text(
            "../7dtd-engine-research/docs/Stock_Pin.md\n",
            encoding="utf-8",
        )
        self.assertEqual(len(self.scan()), 1)
        (self.research_docs / "Stock_Pin.md").write_text("", encoding="utf-8")
        self.assertEqual(self.scan(), [])

    def test_same_basename_in_wrong_directory_does_not_resolve(self):
        (self.root / "docs" / "PROVENANCE.md").write_text(
            "../7dtd-engine-research/docs/world/protocol.md\n",
            encoding="utf-8",
        )
        self.assertEqual(len(self.scan()), 1)

    def test_scan_does_not_depend_on_working_directory(self):
        (self.root / "docs" / "PROVENANCE.md").write_text(
            "../7dtd-engine-research/docs/missing.md\n",
            encoding="utf-8",
        )
        previous = Path.cwd()
        try:
            os.chdir(self.scratch.name)
            self.assertEqual(len(self.scan()), 1)
        finally:
            os.chdir(previous)

    def test_missing_explicit_corpus_fails(self):
        with mock.patch.object(sys, "argv", [
            "provenance_scan.py", "--research-root", str(self.root / "absent")
        ]), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            provenance_scan.main()
        self.assertEqual(raised.exception.code, 2)

    def test_templates_and_local_docs_are_not_research_citations(self):
        (self.root / "docs" / "PROVENANCE.md").write_text(
            "`../7dtd-engine-research/docs/<doc>.md` and [local](missing.md)\n",
            encoding="utf-8",
        )
        self.assertEqual(self.scan(), [])


if __name__ == "__main__":
    unittest.main()
