"""Deployment selection must be explicit and templates must never become live targets."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tsv_xlayer_sdk import ExecutionClient

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("configuration_operator", ROOT / "script/xlayer/operate.py")
operate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operate)


class DeploymentConfigurationTests(unittest.TestCase):
    def test_sdk_does_not_fall_back_to_a_live_default_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "script/xlayer/deployment.json"
            legacy.parent.mkdir(parents=True)
            legacy.write_text(json.dumps({"chainId": 196, "rpcUrl": "https://example.invalid", "environment": {}}))
            with self.assertRaisesRegex(ValueError, "explicitly provided"):
                ExecutionClient(root=root)

    def test_cli_requires_config_before_prompting_or_executing(self):
        with patch.object(operate, "ask") as ask, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                operate.main([])
        self.assertEqual(result.exception.code, 2)
        ask.assert_not_called()

    def test_repository_template_is_not_an_execution_config(self):
        template = ROOT / "script/xlayer/deployment.example.json"
        with self.assertRaisesRegex(ValueError, "placeholder"):
            ExecutionClient.load_public_env(template)
        with patch.object(operate, "ask") as ask, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(operate.main(["--deployment", str(template)]), 2)
        ask.assert_not_called()

    def test_reviewed_configuration_uses_only_the_explicit_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "chosen.json"
            target.write_text(json.dumps({"chainId": 196, "rpcUrl": "https://example.invalid", "environment": {"TSV_ROUTER": "0x0000000000000000000000000000000000000001"}}))
            client = ExecutionClient(deployment_file=target)
            self.assertEqual(client.deployment_file, target)
            self.assertEqual(client.load_public_env(target)["TSV_ROUTER"], "0x0000000000000000000000000000000000000001")

    def test_missing_rpc_and_unexpected_chain_fail_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "chosen.json"
            for body, error in [([], "must be an object"),
                                ({"chainId": 196, "environment": {}}, "rpcUrl"),
                                ({"chainId": 1, "rpcUrl": "https://example.invalid"}, "chainId")]:
                target.write_text(json.dumps(body))
                with self.subTest(body=body), self.assertRaisesRegex(ValueError, error):
                    ExecutionClient.load_public_env(target)
