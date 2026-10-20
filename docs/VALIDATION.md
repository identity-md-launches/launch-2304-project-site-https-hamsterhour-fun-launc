# Local validation — 2026-10-20

These are local results, not an independent attestation or security audit.

| Check | Result |
| --- | --- |
| `forge build --sizes` | Passed |
| `forge test -vv` with the assignment's fuzz seed | 60 passed, 0 failed, 0 skipped, across 6 suites |
| Fuzz cases | 4 fuzz properties, 256 runs each |
| `forge fmt --check` | Passed |
| Application runtime opcode scan | No DELEGATECALL, CALLCODE or SELFDESTRUCT under the protected scan |
| Application bytecode library links | No unresolved library references |
| ABI export | Both JSON files generated from the final compiler artifacts |

Compiler: Solidity 0.8.26. Local runner: Foundry 1.8.3. Configuration: Cancun, via IR, optimizer 1 run, metadata bytecode hash disabled.

Fuzz seed:

```text
0xb0cdfc1d6e3039509a6337ef438fb00d153ee5f84967805c1262ce653f8435ae
```

| Application | Runtime bytes | Initcode bytes | EIP-170 runtime margin |
| --- | ---: | ---: | ---: |
| HamsterBoost | 17,925 | 17,951 | 6,651 |
| HamsterVault | 24,421 | 25,464 | 155 |

The deployment tests instantiate the vault with no dependency code and verify its explicit TEAM argument. The integration suite runs the actual v2 game source with local fixture attestations. The 502-day boost exhaustion test advances EVM timestamps and completes in seconds; it does not wait on the clock. No tests read or set environment variables, fetch network data, or require access to wallet keys.

Foundry's heuristic lint warnings include the intentional timestamp checks, bounded external-read loops, exact-balance requirements and assembly-initialized arithmetic variables. The reentrancy warnings on token/game calls are covered by the shared vault guard and rollback tests. Slither and Mythril were not run. Deployment, explorer verification and the network's independent review remain launch-service responsibilities.
