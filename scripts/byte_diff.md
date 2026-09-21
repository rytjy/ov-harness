# Provenance diff: is the *deployed* code the *audited* code?

Reviews cover a **commit**; production runs a **deployment**. They drift — and the difference is
usually invisible unless you look for it. Prove it in 4 steps.

```bash
# 1. who implements the proxy?
cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc   # EIP-1967 impl slot
# beacon proxies: 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50
# 2. version marker (if the codebase has one)
cast call <proxy|impl> "version()(uint256)" --rpc-url <RPC>
# 3. fetch verified source for the *implementation* and diff against repo tags
curl -s "https://sourcify.dev/server/v2/contract/<chainId>/<impl>?fields=sources,compilation"
# then: for each tag/branch: diff -u <fetched.sol> <repo>/<path>.sol
# 4. if the deployed code matches a tag NEWER than the last published review → you are on the delta
```

Notes
- If the impl isn't on Sourcify, use **selector fingerprints**: `cast sig "f(uint256)"` then `cast code <impl> | grep <selector>`.
  A function that exists in tag A but was removed in tag B is a free version marker.
- Repos can be **ahead of** OR **behind** production — check every contract, never assume.
- `version()` alone is weaker than a byte-level diff; combine both.
