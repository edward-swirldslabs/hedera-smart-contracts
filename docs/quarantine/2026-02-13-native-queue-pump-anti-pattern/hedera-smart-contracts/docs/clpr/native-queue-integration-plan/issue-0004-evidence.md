# ISSUE-0004 Evidence

Date: 2026-02-12

## Address collision check

Observed existing system-contract/precompile addresses from consensus-node smart-contract service:

- `0x167` (HTS)
- `0x168` (Exchange rate)
- `0x169` (PRNG)
- `0x16A` (HAS)
- `0x16B` (HSS)
- `0x16C` (HTS alt)
- `0x16D` (hooks; reserved/special handling)

`0x16E` selected as next free slot for CLPR queue system contract.

## Selector verification

Commands used:

```bash
cast sig "enqueueMessage((address,(address,bytes32,(uint256,string),bytes),bytes32,(bool,(uint256,string),bytes),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes)))"
cast sig "enqueueMessageResponse((uint64,(bytes),(bytes),(uint8,(uint256,string),(uint256,string),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes))))"
```

Results:

- `enqueueMessage` => `0x8cfaaa60`
- `enqueueMessageResponse` => `0xb26aa82b`

Selectors matched `ethers.Interface` computed selectors from:

- `artifacts/contracts/solidity/clpr/interfaces/IClprQueue.sol/IClprQueue.json`
