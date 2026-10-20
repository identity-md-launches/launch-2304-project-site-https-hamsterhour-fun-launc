# HamsterVault — HAMSTER launch 1

Foundry application contracts for Ethereum mainnet. This launch creates no token, pool, hook or distributor. It delivers an immutable vault and a noncustodial accounting companion. Launch 2 must send exactly **800,000,000 HAMSTER** of its **1,000,000,000 supply, 18 decimals**, to this vault before binding.

## Build and checks

```sh
forge build
FOUNDRY_FUZZ_SEED=0xb0cdfc1d6e3039509a6337ef438fb00d153ee5f84967805c1262ce653f8435ae forge test
forge fmt --check
```

Solidity **0.8.26**, Cancun, optimizer 1 run, via IR, `bytecode_hash = "none"`. All dependencies are ordinary files in the repository. No network, FFI, filesystem permissions, environment configuration or fork is needed by the tests. The compiler is installed by the launch/verifier, not included in this repository. `lib/forge-std` is pinned to v1.9.7.

Production ABIs are in [abi/HamsterVault.json](abi/HamsterVault.json) and [abi/HamsterBoost.json](abi/HamsterBoost.json). The files under `test/reference` are the existing v2 game source, used only for offline integration tests; they are not launch applications.

The final local run passed **52 tests**. Runtime sizes are 23,936 bytes for the vault and 13,538 for the companion. See [validation results](docs/VALIDATION.md) and the [local review](docs/REVIEW.md).

## Deployment parameters

Deploy these two applications in this order:

| Contract | Constructor arguments |
| --- | --- |
| `HamsterBoost` | none |
| `HamsterVault` | `team_ = $owner`, `boostEngine_ = $contract:HamsterBoost` |

`$owner` is **0x6cba4751742f6989fa224b2dc5d5d52fcef98a34**, the launch wallet specified by the assignment. The companion reference is resolved to the preceding deployment by the manifest service. It is immutable and must reference this repository's `HamsterBoost` bytecode.

| Dependency | Ethereum mainnet address |
| --- | --- |
| IMD | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Initial Hamster Hour v2 game | `0xe33ab493249a2df0d8c4a71ac54f46d1f7778367` |

The constructors make no external calls and do not require dependency code, so the factory can rehearse them on an empty chain. Neither contract grants authority to its deployer or `tx.origin`. The vault has no owner, upgrade, pause, arbitrary call, administrative withdrawal or token rescue path. The companion holds no tokens, has no administrator and stores each vault's boost accounting under that vault's calling address.

Deployment, the manifest, source verification and confirmed addresses belong to IdentityMD's launch service. This project contains no transaction broadcaster or `launch.json`. Do not deploy the abstract bases, interfaces, mocks, reference game, or test fixtures.

## After launch

1. TEAM calls the **v2 game** `scheduleStakingRecipient(vault)`, then, after its **12-hour** timelock, `executeStakingRecipient(vault)`. The recipient is one-shot in v2. Its existing backlog is credited to the vault.
2. Anyone can call `vault.pullGameRewards(game)`. This can happen before HAMSTER exists: with zero stake weight, IMD waits.
3. Launch 2 deploys HAMSTER and its hook separately, with `remainderTo = vault` and exactly 800M HAMSTER delivered here. TEAM calls `bindToken(token)`. It checks the exact supply, exact vault balance and 18 decimals and can succeed once.
4. The hook approves the vault to pull IMD and calls `depositRewards(amount)` for its 0.5% source, `depositDrip(amount)` for the 80% anti-snipe allocation, and `forwardJackpot(amount)` / `forwardOracle(amount)` for their respective allocations. The hook computes its tax shares; the vault accounts for the supplied amounts. These entry points accept donations from any caller.
5. Keepers/site operators finalize game windows, resolve new game ranges, advance reward checkpoints when needed, prepare boost days and flush forwarded funds. Every vault maintenance operation is public.
6. If canonical Squeek is launched on mainnet within the first year, TEAM verifies its canonical address and calls `activateBoost(collection)`. This schedules a one-shot commitment. Anyone can `executeBoost()` after 12 hours and **strictly before** the 365-day deadline. There is no guessed NFT address in the deployment.

Use the confirmed launch handoff for the vault and companion addresses. Do not send the 800M allocation to the companion.

## Mining and game migrations

The initial registry includes every v2 window from index zero, including windows finalized before vault deployment. V2 genesis is Unix **1791847200**; its hourly windows start at 20 minutes past the hour.

TEAM's only powers are binding the token once, scheduling a successor game, and committing the canonical boost collection once. `scheduleGame(candidate)` publishes a **48-hour** commitment with no effect on mining, rewards or forwarding. Anyone can `executeGame()` after it matures. Scheduling another candidate replaces the pending commitment and restarts the delay.

At execution time `T`:

- The old game's admitted windows are permanently restricted to `windowStart(k) < T`.
- The successor admits only windows with `windowStart(k) >= T`. Its earlier backlog, including imported history, is excluded.
- `resolveGame(successor)` waits until the previous game's **last counted window is finalized**, and until the successor's excluded prefix is finalized. It then fixes the successor's local origin and the previous range's global endpoint.
- Successor claims wait for that resolution. The old game and its claims/reward pulls remain registered forever. A further switch cannot execute until the current game's origin is resolved.

This separates global cumulative loss even when both games have overlapping unresolved backlogs. It never resets a halving. Forwarded IMD uses the current game immediately after execution, including while loss-range resolution is pending.

A compatible successor must preserve the v2 ABI and semantics in [Interfaces.sol](src/interfaces/Interfaces.sol): fixed contiguous **hourly** windows, a chosen genesis, sequential finalization, immutable finalized cumulative history, IMD pull balances, `withdraw`, `depositJackpot`, `fundOracleReserve` and `finalize`. Different hourly offsets are supported. Scheduling probes every required read and checks the write-function selectors in direct runtime bytecode. This catches incompatible interfaces; it does not prove honest economics or support arbitrary proxy dispatchers. TEAM is responsible for reviewing each game's loss calculation, immutable history and custody before scheduling it. A Squeekchain/mainnet migration should expose this same adapter surface.

For global cumulative eligible loss `x` in IMD wei, let `H = 18,750e18`, `h = floor(x/H)`, and `R_h = floor(750,000,000e18 / 2^h)`:

```text
F(x) = 750,000,000e18 - R_h
       + floor((R_h - R_(h+1)) * (x mod H) / H)
```

This starts at 20,000 HAMSTER per IMD, halves every H, and saturates at 750M at sub-wei precision. A window's raw budget is `F(globalAfter) - F(globalBefore)`. An account receives `floor(windowBudget * lossOf(k, account) / totalEligibleLoss(k))`.

For windows starting in the first **14 days after a switch**, the sum of raw budgets for that game's eligible windows on each UTC day is calculated. If it exceeds **2M HAMSTER**, every such window is scaled by `2M / sum`, rounded down. Claims wait until that UTC day has ended and all its relevant windows have finalized. A 23:20 window may finish after midnight. Scaling uses finalized history, never claim order. Withheld amounts do not restart or shift the curve.

`claimMined(game, windows, beneficiary)` is permissionless, accepts **1–32** indices and cannot redirect the beneficiary. Duplicate claims or duplicate indices revert atomically. It creates one 7-day grant for the batch's total positive entitlement. A zero-entitlement claim records the claim without creating a zero grant.

Each first window claim reserves its whole scaled budget. `windowAccounting` reports its budget, paid amount, claimed loss and provable rounding dust. `fractionalDust` uses that window's total loss as denominator; `knownMiningDust` totals whole wei proven to be rounding residue. **Budget minus paid** remains reserved for unclaimed entitlements and dust forever. In real v2, cross-market netting can make sum(account losses) substantially lower than the pool-level denominator; the integration test covers this. There is no expiry or dust sweep.

## Vesting, stake and IMD

Every mined or boosted grant is nontransferable and vests linearly over **7 days from its claim**, by the second. All unwithdrawn grant principal, both unvested and vested, participates in staking after the same **24-hour warm-up** as deposited HAMSTER.

`stake(amount)` creates a deposit lot. `requestUnstake(lotId, amount)` immediately stops that amount's weight and creates a **24-hour** release request. It can also cancel warming deposit principal. It cannot unstake a vesting grant. `withdrawUnstaked(account, requests)` and `withdrawVested(account, grantIds)` accept up to 32 IDs, pay only the named account and can be relayed by anyone. Withdrawing vested principal removes exactly its remaining stake weight, including during warm-up.

Warm-ups mature at their scheduled times even if nobody sends a transaction then. Adding a stake or grant never resets another lot's warm-up. Unallocated mining/boost reserves and unstake queues never count as weight.

Rewards use a global index and individual fractional remainders:

| Source | Distribution |
| --- | --- |
| `depositRewards(amount)` | Each deposit streams independently over 7 active days |
| `pullGameRewards(game)` | Every registered-game pull, including backlog, streams over 30 active days |
| `depositDrip(amount)` | Continuous exponential release with rate constant 0.01 per active day |

An **active second** is a second with nonzero eligible weight. With zero weight, every source's clock stops. Funds neither disappear nor accrue as an instant payout to the first staker. Streams resume prospectively at warm-up maturity. Top-ups add a new stream rather than extending prior streams.

The drip's remainder is `principal * exp(-activeSeconds / 8,640,000)`, evaluated at integer seconds with 27-digit fixed-point exponentiation; approximately **0.995016625%** releases in the first active day. The interpretation is the continuous rate `dR/dt = -0.01 R/day`, not a daily step of exactly 1%. Evaluation is anchored at deposits, so extra checkpoints do not compound rounding or accelerate release.

Every weight change checkpoints both global and account rewards. `claimRewards(account)` pays only that account. Index division rounds down; per-account fractional wei are retained, and aggregate index dust is reported as `dustScaled`. Dust remains backed and has no rescue path.

`checkpoint(maxEvents)` and `checkpointAccount(account, maxLots)` process up to **128** entries per call. Normal actions perform this work automatically. After very many unattended activations or stream endings, an action or preview can revert `CheckpointRequired`; call the maintenance methods repeatedly until they return true, then retry. Progress from maintenance calls persists. This keeps work bounded without making any user iterate over other accounts.

## Forwarding

`forwardJackpot(amount)` and `forwardOracle(amount)` pull IMD from their caller into distinct balances. Anyone can call `flushJackpot(amount)` or `flushOracle(amount)` for all or part of the appropriate balance. The destination is the current game at flush time; the hook address and its vault calls never change.

The vault approves only the requested flush amount, calls the specified game method, resets approval to zero and verifies the exact spend. Failed calls revert the entire flush. Forwarded balances, reward streams and reward liabilities cannot spend one another's accounting buckets.

## Squeek boost

Boost is dormant until the 12-hour activation has executed. Ethereum chain ID 1 and ERC-721 interface support are checked at schedule and execution. **TEAM's collection choice is the canonicality attestation**: ERC-721 has no universal onchain test for "canonical Squeek".

Owners call `registerNFT(tokenId)` without transferring the NFT. A registration applies only to windows starting at least **24 hours later**. A wallet may register multiple NFTs. Its **+50% of base entitlement** is split equally between its eligible NFTs per window; additional NFTs increase cap capacity, not the percentage. Each registration is capped at **10,000 HAMSTER per NFT per UTC day**, and all games together are capped at **100,000 per UTC day**. These are daily caps, not lifetime caps.

After a UTC day closes and the relevant game history is final, `prepareBoostDay(maxRegistrations)` prepares the next day chronologically. Each call processes at most **8 NFTs**, with one current registration per NFT. Repeated transfers do not grow a token's daily enumeration cost:

1. Snapshot valid registrations and each wallet/window's eligible NFT count.
2. Compute the fixed daily NFT demands, applying each NFT's 10k cap.
3. Reserve `min(totalDemand, 100k, uncommittedBoostBucket)` and scale each registration's entitlement by that reserved budget over total demand.

No claim can front-run the global cap or the 50M bucket. The final funded day scales deterministically if only part of its demand fits. Rounding, later invalidation and unclaimed amounts remain reserved, without being awarded to a later claimant.

`claimBoost(day, registration)` is independent of `claimMined`, so NFT-day preparation never blocks base mining. It uses the immutable base entitlement regardless of whether that base has already been claimed, pays the registered wallet through a new 7-day grant, and can be relayed by anyone.

Ownership is checked at registration, eligibility snapshot and claim. Anyone can invalidate a registration when ownership no longer matches; a new owner must register again and wait 24 hours. An observed and invalidated registration stays void even if the NFT returns. **An away-and-back transfer between observations cannot be detected using `ownerOf` alone.** The vault does not custody NFTs, inspect offchain transfer logs, or assume an unprovided NFT transfer hook. A transfer after payment cannot claw back an already created grant.

If execution never activates boost within **365 days of vault deployment**, anyone can call `sweepDormantBoost()` once, including if a scheduled activation was abandoned. This moves 50M from the boost reserve to the mining reserve. It does **not** rewrite historical claims, restart halvings, or add an unspecified emission term: the requested curve still converges to **750M**, while the mining allocation becomes **800M**. The extra reserve therefore remains locked under this immutable curve. This distinction preserves both the fixed mining formula and the requested bucket transfer.

## Site reads

| Need | Read |
| --- | --- |
| Base claim by game/window/account | `vault.claimable(game, k, account)` |
| Budget, finalization-dependent daily scaling | `vault.windowBudget(game, k)` |
| Claimed flag and reserved dust | `mined`, `windowAccounting`, `knownMiningDust` |
| Global rate and halving | `currentMiningState()`, `rateAndHalving(globalLoss)`, `emissionCurve(loss)` |
| Grants and withdrawable vesting | `positionCounts(account)`, `grants(account,id)`, `vested(account,id)` minus withdrawn |
| Stake and warm-up | `stakedBalance`, `grantBalance`, `lots(account,id)`, `activations(lot.activation)` |
| Unstake requests | `positionCounts`, `unstakeQueue(account,id)` |
| Pending IMD | `pendingIMD(account)` |
| Streams/drip | `rewardState()`, `storedRewardState()`, `streamCounts()`, `hookStreams`, `gameStreams` |
| Stream amounts remaining | deposited × RAY minus corresponding `rewardState` released value |
| Drip remaining | `rewardState.dripPrincipal - rewardState.dripReleased` |
| Allocation balances | `bucketsLeft()`, `miningAllocation`, `miningCommitted`, `miningGranted` |
| Games and public switch | `gameCount`, `gameList`, `games`, `currentGame`, `pendingGame`, `pendingGameReadyAt` |
| Forwarding balances | `jackpotPending`, `oraclePending` |
| Boost settings/day progress | `boostEngine.status(vault)`, `days_(vault, day)` |
| NFTs and daily bonus | companion `registrationCount`, `registrations`, `registeredTokenCount`, `registeredTokens`, `walletRegistrationCount`, `walletRegistrations`, `claimable`, `demand`, `eligibleCount`, `dayRegistration` |

Views of unfinalized, excluded, unresolved or capped-current-day windows revert with explicit errors instead of presenting a provisional claim as final. Arrays have public index getters and count views for pagination. Subscribe to both contracts' events; companion events include the vault namespace.

## Accounting and review assumptions

- IMD and bound HAMSTER must be non-rebasing ERC-20s with exact transfers. Optional boolean return values are supported; false returns, transfer fees and callbacks attempting reentrancy revert. IMD amounts are in its existing 18-decimal units. The hook's trading tax must exempt or otherwise preserve exact vault transfers.
- `hamsterLiability()` accounts for ungranted reserves, outstanding grants, deposited stakes and unstake queues. `imdLiability()` includes unspent rewards plus separate forwarding balances. Both equal the physical balances in the tests. Unsolicited token donations are excess, do not become stake/rewards, and cannot be rescued.
- Registered games are trusted to report honest immutable loss history and to implement the declared IMD recipient behavior. Checks and timelocks cannot prove these semantic properties.
- Mainnet timestamp boundaries are by block timestamp, with the ordinary small validator discretion. No randomness or price oracle is used by the vault.
- The review in this repository is a local implementation review, not an independent security audit. The launch network's independent review should examine game selection, canonical collection choice, the documented sweep interpretation, companion linkage and launch-2 transfer compatibility before release.

Test coverage includes retroactivity, halving crossings and saturation, overlapping switch backlogs, deterministic caps and claim permutations, conservation, full boost-bucket exhaustion, vesting stake, automatic warm-ups, cancellation/unstake delays, zero-weight pauses, concurrent streams, anchored drip, actual-v2 integration, forwarding across switches, bind failures, boost ownership invalidation and multi-NFT allocation, timelocks, the 365-day sweep, bounded maintenance, token failure/reentrancy, empty-chain construction, runtime size and the protected opcode policy.
