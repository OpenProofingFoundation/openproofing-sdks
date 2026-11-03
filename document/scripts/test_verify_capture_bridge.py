#!/usr/bin/env python3
"""Tests for the shipped-file scan in scripts/verify_capture_bridge.py.

Run: python3 -m unittest scripts/test_verify_capture_bridge.py
Each fixture binary is a real Mach-O dylib compiled here, so the scan reads it exactly as it
reads a shipped framework binary.
"""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts/verify_capture_bridge.py"
OPENCV_PATH = "/Users/runner/work/opencv-mobile/opencv-mobile/opencv-mobile-4.12.0/modules/core/src/alloc.cpp"


def dylib(directory, framework, text):
    """Compile <framework>.framework/<framework> carrying one C string."""
    out = Path(directory) / (framework + ".framework") / framework
    out.parent.mkdir(parents=True)
    source = Path(directory) / (framework + ".c")
    source.write_text('__attribute__((used)) const char *fixture = ' + json.dumps(text) + ';\n')
    subprocess.run(["xcrun", "clang", "-dynamiclib", "-install_name",
                    "@rpath/" + framework + ".framework/" + framework, "-o", str(out), str(source)], check=True)
    source.unlink()
    return out


def scan(path):
    return subprocess.run(["python3", str(VERIFIER), "--scan", str(path)], capture_output=True, text=True)


class ShippedFileScanTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def assertPasses(self, path):
        result = scan(path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assertFails(self, path, expected):
        result = scan(path)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(expected, result.stderr)

    def test_clean_binary_passes(self):
        self.assertPasses(dylib(self.root, "DocumentOpenCVBridge", "document geometry"))

    def test_allowlisted_upstream_path_passes_inside_its_component(self):
        self.assertPasses(dylib(self.root, "DocumentOpenCVBridge", OPENCV_PATH))

    def test_allowlisted_upstream_path_fails_inside_another_binary(self):
        self.assertFails(dylib(self.root, "IdentityCaptureRuntime", OPENCV_PATH), OPENCV_PATH)

    def test_other_host_path_fails_inside_the_component(self):
        path = "/Users/runner/work/other/src/main.cpp"
        self.assertFails(dylib(self.root, "DocumentOpenCVBridge", path), path)

    def test_internal_name_in_binary_fails(self):
        self.assertFails(dylib(self.root, "IdentityCaptureRuntime", "_TtC20PersonaIdentityReader6Reader"), "Persona")

    def test_internal_name_in_text_fails(self):
        for term in ["BlinkID", "Persona", "MicroBilt", "SHF", "a demo build", "Claude"]:
            with self.subTest(term=term):
                text = self.root / term.replace(" ", "-") / "README.md"
                text.parent.mkdir()
                text.write_text("The package uses " + term + ".\n")
                self.assertFails(text, "internal name")

    def test_retired_supplier_is_rejected_in_docs_and_runtime_symbols(self):
        text = self.root / 'README.md'
        text.write_text('Regula DocumentReader uses an adopter-supplied licence.\n')
        self.assertFails(text, 'prohibited')
        self.assertFails(dylib(self.root, 'IdentityCaptureRuntime', '_TtC20RegulaDocumentReader6Reader'), 'prohibited')

    def test_retired_supplier_family_casing_is_rejected(self):
        for term in ['REGULACOMMON','regulacommon','rEgUlA','Documentreader','DOCUMENTREADERCORE']:
            with self.subTest(term=term):
                text=self.root/'README.md';text.write_text(term)
                self.assertFails(text,'prohibited')

    def test_public_supplier_name_does_not_exempt_private_paths(self):
        text = self.root / 'README.md'
        text.write_text('Regula resource: /Users/private-owner/licence\n')
        self.assertFails(text, 'prohibited')

    def test_kenshiki_product_names_pass(self):
        text = self.root / "README.md"
        text.write_text("Pulse identity platform. KenshikiSensors board.\n")
        self.assertPasses(text)
        self.assertPasses(dylib(self.root, "IdentityCaptureRuntime", "_TtC17PulseFaceMatching7Matcher"))

    def test_ordinary_words_containing_a_term_pass(self):
        text = self.root / "README.md"
        text.write_text("Personal number. Regular expression. Bayer demosaicing.\n")
        self.assertPasses(text)
        self.assertPasses(dylib(self.root, "DocumentOpenCVBridge", "void cv::demosaicing(InputArray)"))
        header = self.root / "lhash.h"
        header.write_text("typedef unsigned long (*OPENSSL_LH_HASHFUNC) (const void *);\n")
        self.assertPasses(header)

    def test_capitalised_internal_name_fails_at_a_word_boundary(self):
        text = self.root / "README.md"
        text.write_text("Tested on SHF-device.\n")
        self.assertFails(text, "internal name 'SHF'")

    def test_exact_line_exemption_does_not_cover_a_longer_path(self):
        self.assertPasses(dylib(self.root, "DocumentOpenCVBridge", "/tmp/"))
        self.assertFails(dylib(self.root, "IdentityCaptureRuntime", "/tmp/"), "internal name '/tmp'")


if __name__ == "__main__":
    unittest.main()
