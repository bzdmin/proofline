# Package discrepancies — official examples vs published packages

**Date:** 2026-09-01
**Category:** MEASURED BEHAVIOUR (not an official requirement, not our design choice)

Three places where following the official `attestcoin-protocol-examples` verbatim does not
work against the published npm packages. Recorded rather than silently patched, because a
team copying the tutorial hits all three before writing a line of their own logic.

---

## 1. `EvmV1Decoder` import path does not exist

**Official example says** — `contracts/sol/ASCLoanManager.sol`:

```solidity
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
```

**Published package contains** — `@gluwa/usc-contracts@` (installed 2026-09-01):

```
node_modules/@gluwa/usc-contracts/contracts/write-ability/common/EvmV1Decoder.sol
```

There is no `contracts/decoding/` directory in the package.

**Result of following the example:** compilation fails, source file not found.

**ProofLine uses:**

```solidity
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/write-ability/common/EvmV1Decoder.sol";
```

Worth noting the decoder lives under `write-ability/` despite being used here purely for
**readability**. Nothing in ProofLine depends on writability, which is still in audit.

---

## 2. Solidity version in the examples is below what the package requires

**Official example says** — every contract in `contracts/sol/`:

```solidity
pragma solidity ^0.8.23;
```

**Published package requires** — `EvmV1Decoder.sol`:

```solidity
pragma solidity ^0.8.28;
```

**Result of following the example:**

```
Error: Encountered invalid solc version in EvmV1Decoder.sol:
No solc version exists that matches the version requirement: ^0.8.28
```

**ProofLine uses:** `solc = "0.8.28"` in `foundry.toml`. Our own contracts keep `^0.8.23`,
which the 0.8.28 compiler satisfies.

---

## 3. `verifyAndEmit` needs `via_ir`

**Measured:** compiling a contract that calls `verifyAndEmit` with the full seven-argument
proof signature plus local variables fails on the default pipeline:

```
Compiler error: Stack too deep. Try compiling with `--via-ir`
```

Not a bug in the protocol — a consequence of the argument count. Recorded because it is a
non-obvious build requirement for any ASC.

**ProofLine uses:** `via_ir = true` with `optimizer = true` in `foundry.toml`.

---

## Toolchain actually used

| | |
|---|---|
| foundry | `v1.2.3` (pinned by the examples repo README) |
| solc | `0.8.28` |
| `@gluwa/usc-sdk` | `0.18.0` |
| `@gluwa/usc-contracts` | installed 2026-09-01 |
| ethers | `6.x` (SDK peer dependency) |

## Precompiles observed

| Address | Role |
|---|---|
| `0x0000000000000000000000000000000000000FD2` | `INativeQueryVerifier` — `verifyAndEmit`, `calculateTxIndex` |
| `0x0000000000000000000000000000000000000fd3` | ChainInfo — attested height queries |

`eth_getCode` at `0x…0FD2` on CC3 returns `0x`. Expected: precompiles are native, not
deployed bytecode. Absence of code is not absence of the precompile.
