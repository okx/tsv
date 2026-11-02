import tempfile
import unittest
from pathlib import Path

from tsv_xlayer_sdk.client import ExecutionClient


class LocalEnvironmentTests(unittest.TestCase):
    def load(self, contents):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'example.env'
            path.write_text(contents)
            return ExecutionClient.load_local_env(path)

    def test_quoted_value_with_inline_comment(self):
        self.assertEqual(self.load('XLAYER_PRIVATE_KEY="not-a-key" # public address\n'),
                         {'XLAYER_PRIVATE_KEY': 'not-a-key'})

    def test_export_and_single_quotes(self):
        self.assertEqual(self.load("export XLAYER_PRIVATE_KEY='not-a-key' # annotation\n"),
                         {'XLAYER_PRIVATE_KEY': 'not-a-key'})

    def test_quoted_hash_in_url_is_preserved(self):
        self.assertEqual(self.load('XLAYER_RPC_URL="https://example.invalid/#fragment"\n'),
                         {'XLAYER_RPC_URL': 'https://example.invalid/#fragment'})

    def test_shell_syntax_remains_literal(self):
        self.assertEqual(self.load("XLAYER_PRIVATE_KEY='$(must-not-execute)'\n"),
                         {'XLAYER_PRIVATE_KEY': '$(must-not-execute)'})

    def test_invalid_quoting_does_not_echo_value(self):
        with self.assertRaisesRegex(ValueError, '^invalid quoting in local environment variable XLAYER_PRIVATE_KEY$'):
            self.load('XLAYER_PRIVATE_KEY="invalid-example\n')

    def test_allowlist_and_empty_values(self):
        self.assertEqual(self.load('UNRELATED=ignored\nXLAYER_PRIVATE_KEY= # empty\n'),
                         {'XLAYER_PRIVATE_KEY': ''})

    def test_escaped_malformed_value_does_not_leak_embedded_key(self):
        # All-zero bytes are an invalid signing key, used solely as a redaction fixture.
        invalid_key = '0x' + '0' * 64
        configured = '"' + invalid_key + '" # annotation'
        escaped_error = configured.replace('"', '\\"')
        redacted = ExecutionClient._redact(escaped_error, {'XLAYER_PRIVATE_KEY': configured})
        self.assertNotIn(invalid_key, redacted)
        self.assertNotIn('0' * 64, redacted)


if __name__ == '__main__':
    unittest.main()
