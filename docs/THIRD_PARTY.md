# Third-party sources

- `lib/forge-std`: Foundry forge-std **v1.9.7**, obtained from the [official tagged archive](https://github.com/foundry-rs/forge-std/tree/v1.9.7). Ordinary source files only, with its `LICENSE-MIT` and `LICENSE-APACHE`. No submodule or network dependency.
- `test/reference/HamsterHour.sol`, `OracleAttestation.sol`, and `interfaces/IIntake.sol`: unmodified Solidity sources from [Hamster Hour v2, commit 49f53ca0f278fe4edf6431f68a51468552372af7](https://github.com/identity-md-launches/launch-2260-build-hamster-hour-v2/tree/49f53ca0f278fe4edf6431f68a51468552372af7/src). Each source declares SPDX MIT. This code is a test dependency, not an application to deploy in this launch.
- `src/libraries/VaultMath.sol`: the full-precision `mulDiv` algorithm is adapted from [OpenZeppelin Contracts Math.sol](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.1.0/contracts/utils/math/Math.sol), MIT, which credits Remco Bloemen and Uniswap FullMath. All functions are internal; the application bytecode has no library link placeholders. The associated OpenZeppelin MIT license is in `docs/OpenZeppelin-LICENSE`.

The security/address material in the task's read-only inputs was used as review background. No additional protocol addresses were imported from its tables.
