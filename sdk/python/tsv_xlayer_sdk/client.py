"""Safe execution layer for the XLayer TSV Foundry scripts."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Mapping


_LOCAL_ENV_KEYS = frozenset({"XLAYER_PRIVATE_KEY", "XLAYER_RPC_URL"})


class Target(Enum):
    INSPECT_ASSETS = ("InspectAssets.s.sol:InspectAssets", False)
    INSPECT_POOL = ("InspectTSV.s.sol:InspectTSV", False)
    REGISTER_QUOTES = ("RegisterQuoteTokens.s.sol:RegisterQuoteTokens", True)
    CREATE_STOCK_ADAPTERS = ("CreateStockAdapters.s.sol:CreateStockAdapters", True)
    VERIFY_STOCK_ADAPTERS = ("VerifyStockAdapters.s.sol:VerifyStockAdapters", True)
    REGISTER_STOCKS = ("RegisterStocks.s.sol:RegisterStocks", True)
    INITIALIZE_POOLS = ("InitializeTSVPools.s.sol:InitializeTSVPools", True)
    TRADE = ("TradeTSV.s.sol:TradeTSV", True)
    REGISTRY_OPERATION = ("RegistryOperations.s.sol:RegistryOperations", True)
    LEDGER_OPERATION = ("VolumeLedgerOperations.s.sol:VolumeLedgerOperations", True)
    DEPLOY_LEGAL_ADAPTER = ("DeployLegalShareAdapter.s.sol:DeployLegalShareAdapter", True)
    ISSUE_OPERATOR_SBT = ("IssueOperatorSbt.s.sol:IssueOperatorSbt", True)
    ADD_LIQUIDITY = ("AddLiquidityTSV.s.sol:AddLiquidityTSV", True)
    DEX_ROUTER_TRADE = ("TradeDexRouterTSV.s.sol:TradeDexRouterTSV", True)

    def __init__(self, script: str, writes: bool) -> None:
        self.script = script
        self.writes = writes


_SENSITIVE_OVERRIDE = re.compile(r"(PRIVATE_KEY|MNEMONIC|PASSWORD|SECRET|AUTH_SIGNER|RPC_URL)$", re.I)


@dataclass(frozen=True)
class Operation:
    target: Target
    label: str
    inputs: Mapping[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not isinstance(self.target, Target):
            raise TypeError("target must be a supported Target enum")
        if not self.label.strip():
            raise ValueError("label must not be empty")
        copied = {str(key): str(value) for key, value in self.inputs.items()}
        for key in copied:
            if _SENSITIVE_OVERRIDE.search(key):
                raise ValueError(f"credentials must come from the process environment, not operation input: {key}")
        object.__setattr__(self, "inputs", copied)


@dataclass(frozen=True)
class ExecutionResult:
    returncode: int
    stdout: str
    stderr: str

    @property
    def succeeded(self) -> bool:
        return self.returncode == 0


@dataclass(frozen=True)
class Simulation:
    operation: Operation
    result: ExecutionResult
    fingerprint: str


class ExecutionClient:
    """Runs allowlisted scripts; writes require simulation and explicit broadcast confirmation."""

    def __init__(
        self,
        root: Path | None = None,
        deployment_file: Path | None = None,
        local_env_file: Path | None = None,
    ) -> None:
        self.root = root or Path(__file__).resolve().parents[3]
        self.deployment_file = deployment_file or self.root / "script/xlayer/deployment.json"
        self.local_env_file = local_env_file or self.root / "script/xlayer/.env.xlayer"

    @staticmethod
    def load_public_env(path: Path) -> dict[str, str]:
        deployment = json.loads(path.read_text(encoding="utf-8"))
        if deployment.get("chainId") != 196:
            raise ValueError(f"deployment config must target X Layer Mainnet (chainId 196): {path}")
        values = {str(key): str(value) for key, value in deployment.get("environment", {}).items()}
        values["XLAYER_RPC_URL"] = str(deployment["rpcUrl"])
        values["XLAYER_CHAIN_ID"] = str(deployment["chainId"])
        return values

    @staticmethod
    def load_local_env(path: Path) -> dict[str, str]:
        if not path.is_file():
            return {}
        values: dict[str, str] = {}
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            if line.startswith("export "):
                line = line[len("export "):].lstrip()
            key, value = line.split("=", 1)
            key = key.strip()
            if key not in _LOCAL_ENV_KEYS:
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                value = value[1:-1]
            values[key] = value
        return values

    def _environment(self, operation: Operation) -> dict[str, str]:
        if not self.deployment_file.is_file():
            raise FileNotFoundError(f"deployment config not found: {self.deployment_file}")
        env = self.load_public_env(self.deployment_file)
        env.update(self.load_local_env(self.local_env_file))
        env.update(os.environ)
        env.update(operation.inputs)
        rpc_url = env.get("XLAYER_RPC_URL", "").strip()
        if not rpc_url:
            raise ValueError("XLAYER_RPC_URL is missing from deployment config or local environment")
        if operation.target.writes and not env.get("XLAYER_PRIVATE_KEY", "").strip():
            raise ValueError(f"write operations require XLAYER_PRIVATE_KEY in {self.local_env_file} or the process environment")
        if operation.target is Target.DEX_ROUTER_TRADE:
            side = env.get("TSV_DEX_SIDE", "")
            if side not in {"BUY_STOCK", "SELL_STOCK"}:
                raise ValueError("TSV_DEX_SIDE must be BUY_STOCK or SELL_STOCK")
        # Keep the endpoint in the child environment for scripts that read it, too.
        env["ETH_RPC_URL"] = rpc_url
        return env

    def _fingerprint(self, operation: Operation, env: Mapping[str, str]) -> str:
        names = {"XLAYER_RPC_URL", "XLAYER_PRIVATE_KEY", "TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY", "ETH_RPC_URL"}
        names.update(key for key in env if key.startswith("TSV_"))
        payload = {
            "target": operation.target.name,
            "label": operation.label,
            "inputs": dict(sorted(operation.inputs.items())),
            "runtime": {key: env.get(key, "") for key in sorted(names)},
            "deployment": hashlib.sha256(self.deployment_file.read_bytes()).hexdigest(),
        }
        return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()

    @staticmethod
    def _redact(text: str, env: Mapping[str, str]) -> str:
        secrets = {
            env.get("XLAYER_RPC_URL", ""),
            env.get("XLAYER_PRIVATE_KEY", ""),
            env.get("TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY", ""),
        }
        for value in list(secrets):
            if value:
                text = text.replace(value, "[REDACTED]")
                without_prefix = value[2:] if value.lower().startswith("0x") else value
                if len(without_prefix) >= 32:
                    text = text.replace(without_prefix, "[REDACTED]")
        return text

    def _run(self, operation: Operation, env: dict[str, str], broadcast: bool) -> ExecutionResult:
        forge = shutil.which("forge")
        if forge is None:
            raise FileNotFoundError("forge not found on PATH; install Foundry first")
        command = [forge, "script", f"script/xlayer/{operation.target.script}", "--rpc-url", env["XLAYER_RPC_URL"]]
        if broadcast:
            command.append("--broadcast")
        completed = subprocess.run(
            command,
            cwd=self.root,
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        return ExecutionResult(
            completed.returncode,
            self._redact(completed.stdout, env),
            self._redact(completed.stderr, env),
        )

    def simulate(self, operation: Operation) -> Simulation:
        env = self._environment(operation)
        result = self._run(operation, env, broadcast=False)
        return Simulation(operation, result, self._fingerprint(operation, env))

    def broadcast(self, simulation: Simulation, confirmation: str) -> ExecutionResult:
        if not simulation.operation.target.writes:
            raise ValueError("read-only operations cannot be broadcast")
        if not simulation.result.succeeded:
            raise ValueError("the operation must simulate successfully before broadcast")
        if confirmation != "BROADCAST":
            raise ValueError("broadcast requires the exact confirmation word BROADCAST")
        env = self._environment(simulation.operation)
        if self._fingerprint(simulation.operation, env) != simulation.fingerprint:
            raise ValueError("operation inputs or signing environment changed after simulation; simulate again")
        return self._run(simulation.operation, env, broadcast=True)
