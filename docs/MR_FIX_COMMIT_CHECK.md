# DRAFT — not published

# Is the claimed fix actually in the reviewed revision?

**A repeatable check for remediation reports — and why "8 of 14" is the interesting number.**

> 中文版：`MR_FIX_COMMIT_CHECK.zh.md`

---

## TL;DR

Remediation reports usually claim *"Fixed in commit `<sha>`"*. Before trusting that in a
mitigation review (or before treating a finding as closed), you can check — mechanically,
in about two minutes per report:

1. **Extract** the claimed fix commits from the remediation document.
2. **Compare** each one against the revision under review:
   `GET /repos/{owner}/{repo}/compare/{fix_sha}...{reviewed_sha}`
   → `status: ahead` **and** `behind_by: 0` ⇒ the fix **is an ancestor of** the reviewed revision ⇒ present.
3. **Disambiguate** the ones that don't resolve:
   `GET /repos/{owner}/{repo}/commits/{fix_sha}`
   → `200` = exists but not reachable from the reviewed revision's lineage;
   `422/404` = not in that repository at all.

The point isn't the 8 that check out. **It's the 6 that don't** — and, crucially, telling
*"the fix isn't there"* apart from *"my extraction is broken"*.

> **Script (steps 1–3, one command):**
> `check_fix_commits.sh <owner/repo> <reviewed_sha> <remediation.pdf|txt>`
> prints the triage table below. `--dry` extracts the SHAs without hitting the API.

---

## Why this matters

A mitigation review asks one question: *did the fix actually close the finding?*
Everyone reads the diff. Very few check the *plumbing* first:

- Is the claimed fix commit **even part of the code I'm reviewing**?
- If it isn't — is that because the project fixed it elsewhere (another repo, another
  branch), or because the fix never landed in this revision?

If the commit isn't in the reviewed revision, then *no amount of diff-reading tells you
whether that finding is closed.* That's a gap worth closing **before** you spend your
review budget on the parts that are genuinely present.

---

## Step 1 — Extract the claimed fix commits

Remediation PDFs are usually generated from text, not scanned, so `pdftotext` returns the
**text layer** — the SHAs are what the authors typed, not OCR guesses. Good.

```bash
pdftotext -q remediation.pdf remediation.txt
grep -oE '\b[0-9a-f]{40}\b' remediation.txt | sort -u
```

Keep the association (finding ID ↔ SHA). A short table is enough.

## Step 2 — Is the fix an ancestor of the reviewed revision?

GitHub's compare endpoint answers this directly and cheaply:

```bash
PIN=<reviewed_sha>
curl -s "https://api.github.com/repos/$OWNER/$REPO/compare/$FIX...$PIN" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("status"),d.get("ahead_by"),d.get("behind_by"))'
```

| `status` | `behind_by` | Meaning |
|---|---|---|
| `ahead` | `0` | ✅ reviewed revision **contains** the fix (`ahead_by` = commits between them) |
| `identical` | `0` | ✅ same commit |
| `behind` | `>0` | 🔴 reviewed revision predates the fix ⇒ **not included** |
| `diverged` | — | ⚠️ histories diverged ⇒ manual look |
| `404` | — | ⚠️ no common ancestry via that route ⇒ go to step 3 |

> A straight-line history makes this trivial. Note that `compare/A...B` **404s** when the
> two commits share no ancestry *reachable through that path* — which is why step 3 exists.

## Step 3 — Distinguish "not fixed" from "you can't tell"

For every SHA that didn't resolve:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  "https://api.github.com/repos/$OWNER/$REPO/commits/$FIX"
```

- `200` ⇒ the commit **exists** in that repository, it's just not on the reviewed
  revision's ancestry (rebased, squashed, or on a branch that never merged).
- `422` / `404` ⇒ **not in that repository**. Which leaves three possibilities, and you
  must not silently collapse them:
  1. the fix lives in **another repository** (cross-chain / multi-repo projects are common),
  2. the commit is in a **private** repository (or the repo was made private later),
  3. the SHA in the document is simply wrong.

**Check the org's public repo list before concluding anything.** A project with several
components usually has a public repo for one of them and private ones for the rest.

---

## Step 4 — Don't fool yourself: extraction noise vs. real SHAs

Before you write "the fix is missing", rule out that *your* extraction mangled the hash.

- `pdftotext` reads the **text layer**. If the document is a scan, you get nothing — and
  then you're OCR-ing hex, which corrupts characters (`…0e3c` → `…0e3cv`). Prefer
  documents with a text layer; verify with `pdftotext … -` and eyeball for garbage.
- **Strong check:** does the *same* SHA string appear in **two independently produced
  documents** (e.g. two different auditors' remediation reports)? Independent authors
  don't typo the same random 40-hex string. That's a real commit reference.
- Weak check: a SHA that "looks like hex". Every corrupted string can look like hex.

---

## Worked example (public data)

> **Project details are deliberately omitted — only the *shape* of the result is reported.**
> Nothing below identifies a specific project, and the counts are illustrative of a pattern,
> not a disclosure about one team.

Take a project whose remediation reports for earlier audits are publicly available. Running
the steps above on **14 claimed fix commits**:

- **8** → `status: ahead`, `behind_by: 0` ⇒ present in the reviewed revision. ✅
- **6** → not resolvable in that repository.
  - Two of those six appear in **two independently produced remediation documents** ⇒ not
    extraction noise.
  - None of the organisation's public repositories resolve them ⇒ most likely another
    (possibly private) repository, or a rebased branch.

Neutral framing matters here: **this is not a vulnerability claim.** It is a statement about
what is and isn't verifiable from the reviewed revision. The 6 may be perfectly fixed —
somewhere you can't see.

## What this method does **not** prove

Being explicit, because the failure mode of this check is over-claiming:

- **Presence ≠ correctness.** An ancestor commit means the fix *landed*; it says nothing
  about whether it actually closes the finding. That still requires reading the diff and —
  where possible — **reproducing the original behaviour** to show it no longer occurs.
- **Rebases destroy the signal.** A squashed mainline makes original SHAs unresolvable even
  though the change is present.
- **Private repos are invisible.** A `404`/`422` is a *flag for manual review*, never a
  conclusion of "unfixed".
- **`ahead_by` is not a quality measure** — it's just the commit distance.

So the honest output of this check is a triage:

| Result | What you may say |
|---|---|
| present (`ahead`, `behind_by=0`) | "the fix is in the reviewed revision — now verify it works" |
| resolvable but not an ancestor | "the fix exists but isn't in this revision — ask why" |
| unresolvable | "**unverifiable from here** — ask which repo/branch" |

---

## Takeaway

Mitigation review is mostly about **verifying claims**, and the cheapest claim to verify is
*"the fix commit is in this revision"* — yet it's usually taken on faith.

Two minutes of plumbing turns a report into a triage list, and turns "I read the diff" into
"I checked which of these fixes are even here".

---

*Method note. All examples use publicly available data. No vulnerability claims are made.
Corrections welcome.*
