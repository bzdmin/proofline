# A third application, added ten days later

`CreditFile` was deployed on 2026-09-01. On 2026-09-11 a fresh address with no role in any
ProofLine contract deployed a new application against it and asked for one decision about the
same borrower. Nothing in `CreditFile` changed to allow it.

| | |
|---|---|
| Application | [`NetTermsDesk` `0x307C0Ecf...`](https://creditcoin-testnet.blockscout.com/address/0x307C0Ecf5d9034DA890579Ac22dD851343b9AB5A?tab=contract), source verified |
| Deployed by | [`0xbD7Ac5a9...`](https://creditcoin-testnet.blockscout.com/address/0xbD7Ac5a96a4538b89aDd873b5BA3550AdEeA050a), created for this and holding no role anywhere |
| Deploy | [`0xd4404fb6...`](https://creditcoin-testnet.blockscout.com/tx/0xd4404fb63e238c15ceab489c96036b47f46e187e167219cd36471c1a8fb541b8) |
| Decision | [`0xde9b8fe9...`](https://creditcoin-testnet.blockscout.com/tx/0xde9b8fe94ee22c3b38372d592dfcb644d31c857420e5904c5be39ed566d6a519): net 60 days, 128,296 gas |
| `CreditFile` code hash | `0xcd5a79db...` before and after |
| `CreditFile` events | 11 before, 11 after |

## What the application is

`NetTermsDesk` (`src/examples/NetTermsDesk.sol`) sets supplier payment terms: how many days a
business may take to pay for inventory, decided from its verified sales history.

- **It imports nothing from ProofLine.** It declares the return shape of the public
  `getCreditFile()` itself, from the ABI, as any third party would.
- **Its policy is its own.** It ignores ProofLine's tiers and rates and reads the raw file,
  including a verified-volume rule ProofLine's underwriting does not have: net 60 needs five
  settlements, three counterparties and 40,000 of verified volume. A file ProofLine rates
  TRUSTED can still get net 30 here (`test_ownPolicy_volumeGateHoldsBackNet60`).
- **Anyone may ask.** `decide()` has no access control. It reads, decides, and records.

For this borrower it read 5 settlements, 3 counterparties and 46,000 of verified volume, and
decided net 60.

## What was needed from ProofLine

Nothing. No allowlist entry, no permission, no redeploy, no configuration change. The deploying
address was funded with test CTC by the ProofLine deployer, because that is the only CTC this
project holds; that transfer ([`0x77326180...`](https://creditcoin-testnet.blockscout.com/tx/0x77326180e2c01bc28589c62071ab4e61d72c76f83be09978d6218dd4e3158efb))
carries no permission, since `CreditFile` has no list of approved readers.

## Reproduce

```bash
forge test --match-contract NetTermsDeskTest   # 6 tests, against the real CreditFile
node script/third-app.mjs                      # deploys a new desk from a new address
```

The script reads `CreditFile`'s code hash and event count before and after, and stops if either
moved. Raw record: [`third-app.json`](third-app.json).
