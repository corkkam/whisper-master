import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from schema import normalize_case


class TestNormalize(unittest.TestCase):
    def test_legacy_string_input_is_wrapped(self):
        raw = {"id": "a", "category": "numbers", "input": "hello world",
               "must_contain": ["hello"], "must_not_contain": [], "note": "n"}
        c = normalize_case(raw)
        self.assertEqual(c["input"], {"text": "hello world"})
        self.assertEqual(c["targets"], ["light", "polish"])  # default
        self.assertIsNone(c["reference"])
        self.assertIsNone(c["asr_reference"])

    def test_new_schema_passthrough(self):
        raw = {"id": "b", "category": "grammar", "input": {"text": "x"},
               "targets": ["polish"], "reference": "X."}
        c = normalize_case(raw)
        self.assertEqual(c["input"], {"text": "x"})
        self.assertEqual(c["targets"], ["polish"])
        self.assertEqual(c["reference"], "X.")

    def test_audio_case_requires_asr_reference(self):
        raw = {"id": "c", "category": "realistic", "input": {"audio": "f.m4a"}}
        with self.assertRaises(ValueError):
            normalize_case(raw)


if __name__ == "__main__":
    unittest.main()
