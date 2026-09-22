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


class AnchorErrorsTest(unittest.TestCase):
    """The constants ledger cites code by anchor; a moved or renamed constant
    must fail the gate instead of leaving a citation pointing at nothing."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        root = Path(self.scratch.name)
        (root / "src" / "server" / "c2s").mkdir(parents=True)
        (root / "src" / "server" / "c2s" / "inv_te.zig").write_text(
            "const sign_echo_range: f32 = 192;\n", encoding="utf-8"
        )
        (root / "src" / "server" / "c2s" / "inv.zig").write_text("\n", encoding="utf-8")
        patch = mock.patch.object(provenance_scan, "ROOT", str(root))
        patch.start()
        self.addCleanup(patch.stop)
        files = mock.patch.object(
            provenance_scan, "src_files",
            lambda: ["src/server/c2s/inv_te.zig", "src/server/c2s/inv.zig"],
        )
        files.start()
        self.addCleanup(files.stop)

    def test_symbol_at_its_anchor_passes(self):
        self.assertEqual(
            provenance_scan.anchor_errors("`server/c2s/inv_te.zig` `sign_echo_range`"), []
        )

    def test_symbol_moved_out_of_the_anchored_file_fails(self):
        errors = provenance_scan.anchor_errors("`server/c2s/inv.zig` `sign_echo_range`")
        self.assertEqual(len(errors), 1)
        self.assertIn("sign_echo_range not found in src/server/c2s/inv.zig", errors[0])

    def test_short_anchor_path_resolves_by_unique_suffix(self):
        self.assertEqual(
            provenance_scan.anchor_errors("`c2s/inv_te.zig` `sign_echo_range`"), []
        )

    def test_anchor_file_that_does_not_exist_fails(self):
        errors = provenance_scan.anchor_errors("`server/c2s/gone.zig` `sign_echo_range`")
        self.assertEqual(len(errors), 1)
        self.assertIn("anchor file server/c2s/gone.zig missing", errors[0])


class ConstRowTest(unittest.TestCase):
    def test_anchor_cell_with_several_backticked_spans_parses(self):
        row = (
            "| `ecs/rules.zig` `Power.trigger_pulse_s` (mirrored to `ecs/electric.zig` "
            "`trigger_pulse_s` at init) | 0.5 | R | Trigger pulse width |"
        )
        match = provenance_scan.CONST_ROW.match(row)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(2).strip(), "0.5")
        self.assertEqual(match.group(3), "R")


if __name__ == "__main__":
    unittest.main()
