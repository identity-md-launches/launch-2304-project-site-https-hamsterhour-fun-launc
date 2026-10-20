# Local implementation review

This is a record of the implementation review performed with the tests, not an independent audit.

## Custody and authority

Only `HamsterVault` holds assets. HAMSTER outflows are previously created grants or a caller's own staked principal after its release delay. IMD outflows are previously accrued rewards or separately accounted jackpot/oracle deposits sent to the registered current game. There is no admin outflow, arbitrary target call, delegatecall or rescue path.

TEAM is an explicit immutable constructor argument. Binding and boost activation are one-shot. Game scheduling is public and has a 48-hour minimum delay; replacing a pending game restarts that delay. The original game's excluded suffix cannot be reinstated by registering it again.

The immutable `HamsterBoost` companion keeps boost state keyed by `msg.sender`. A direct caller has no way to mutate the vault's namespace. It never holds or transfers the allocated HAMSTER. It also supplies read-only game compatibility and budget calculations to keep both applications below EIP-170.

Every external mutation of the vault has the same reentrancy guard. Asset calls check optional return data and exact balance changes. Forwarding allowances are limited to one call's amount and cleared afterwards. A successful game call that does not actually pull IMD also reverts.

## Accounting and ordering

Mining uses finalized global loss intervals and integral differences rather than subtracting an amount from a first-come pool. A successor origin is fixed only after both relevant prefixes are final. Window budgets are reserved before granting shares. Daily caps use the entire finalized day and advance the curve only by what they pay, so capped emission is deferred rather than forfeited. Overcommitment and cumulative/share inconsistencies revert.

Boost reservations advance in day order, separately from claims. A bounded first pass snapshots eligible NFT counts; a second pass fixes capped demands and reserves the daily budget. Enumeration visits each unique registered NFT once, so transferring and re-registering one token cannot inflate daily work with its registration history. Multiple NFTs share the wallet's 50% bonus. Later ownership invalidation cannot increase another claimant's amount. The 502-day fixture exercises the complete 50M reserve, its partially funded last day and exhaustion without requiring a long wall-clock wait.

Reward checkpoints split intervals at every automatic warm-up and stream ending. The global denominator changes at the event time, even when processing happens later. Account lots use the index at their actual activation, so a delayed account checkpoint neither loses its historical earnings nor gets pre-warm-up rewards. Removing weight first accounts for accrued rewards. Zero weight pauses the shared reward clock.

Linear streams preserve each deposit's end and fixed amount. Drip uses an anchor rather than repeatedly applying rounded decay to the previous checkpoint's remainder. Account fractional reward wei persist across claims; index dust is tracked. Conservation tests assert physical custody against liabilities after combinations of claims, vesting, staking, unstaking, streaming, decay and forwarding.

## Limits and external trust

- Direct compatible games must provide honest immutable sequential loss history. Interface validation cannot establish that semantic property; the TEAM game-selection power is a substantive trust assumption.
- Canonical NFT identity is attested by TEAM's timelocked selection. `ownerOf` checks cannot discover a transfer away and back between observations. This is explicitly documented, and observed invalidation is permanent.
- The dormant boost sweep scales the curve beyond the finalized global loss at the sweep so it converges to 800M; the base curve, halving points and all previously finalized windows are unchanged.
- With many queued events, users need several permissionless checkpoint transactions. Boost preparation may need several calls per day and older unresolved game history can delay it. Base mining does not depend on boost preparation.
- Unsolicited asset donations and rounding/voided entitlements have no administrative recovery path.
- Tests use actual v2 source with locally signed fixture attestations; they do not claim to verify a live mainnet attestation or canonical NFT deployment.

The independent launch review should validate the two manifest entries and their constructor linkage, verify TEAM's real address, review the chosen successor/collection when scheduled, and check that launch-2 token transfers preserve the vault's exact-transfer assumptions.
