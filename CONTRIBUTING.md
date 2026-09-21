# Contributing

- Add a new instance by copying `instances/overnight`, then follow `TEMPLATE_GUIDE.md`. Keep the 3-field rule: target addresses, chain + pinned block, handler actions + invariants.
- Every instance must build and run with a single documented command, and its README must carry the verbatim test output it claims.
- Invariants must be identities, monotonicities or bounds — never "expected" states that can fail for legitimate reasons (e.g. `totalAssets > 0` on a legitimately empty vault).
- Never use derived tokens (`vm.deal` on shares / aTokens / debt receipts). Fund through the protocol's own entry points.
- Read-only forks only: no broadcasts, no keys, no testnets.
- Cite public provenance (chain id, address, block, explorer / Sourcify link). Do not include internal notes, scoring, or third-party private information.
- Report issues about the harness code; this repository is an engineering tool, not an audit report, and does not publish vulnerability assessments.
