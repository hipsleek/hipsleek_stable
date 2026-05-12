# HIP/SLEEK Stabilisation Log

This file records all changes made to the `hipsleek_stable` codebase during the stabilisation effort. The goal is to get the old system into a known-good state while a new system is being rebuilt in parallel.

## Project Overview

- **HIP**: program verifier for heap-manipulating programs (`.ss` files)
- **SLEEK**: standalone entailment checker (`.slk` files)
- **Solvers**: Omega, Z3 (via SMT2), Mona, Redlog
- **Key source directory**: `src/`
- **Test suites**: `tut/`, `examples/`, `baga/`, `norm/`, `validate/`, `errors/`, `bugs/`
- **Representative test files created for the new system**:
  - `representative_pure_logic.slk` — pure arithmetic/relational examples
  - `representative_sep_logic.slk` — separation logic examples

---

## Change Log

Changes are listed newest-first. Each entry records: what changed, why, and what the expected effect is.

---

### 2026-05-12 — Fix implicit bind for ref field-access arguments (`src/astsimp.ml`)

**File changed**: `src/astsimp.ml`

**Root cause**: When a `ref` parameter was passed a field-access expression like `x.next`, the `I.Member` translator emitted a `C.Bind` with `read_only=true` (no write-back). After the callee returned, the updated value was only in a fresh existential variable disconnected from the node cell `x::node<_,q>`, so predicate folding to `x::ls<null>` failed.

**Fix**: In the `CallNRecv` handler, added a new `else if` branch (after the inliner check, before the SCall builder) that detects any ref parameter receiving an `I.Member{base=I.Var, fields=[f]}` argument. For each such argument, it rewrites the call as an explicit `I.Bind` wrapping the `I.CallNRecv`, replacing the `I.Member` arg with a fresh `I.Var`. The `I.Bind` handler then generates a `C.Bind` with `read_only=false`, enabling the write-back that re-establishes the node-field connection after the call.

**Verified**: `errors/ll_all2a.ss` — both `append` (previously failing) and `append3` (was already passing) now report `SUCCESS`.

**Analogous fix already present**: `append3` used an explicit `bind x to (_,s) in { ... }` which went through the `I.Bind` handler directly with `read_only=false`. The new code makes the implicit case match that behaviour.

---

## Known Issues / Areas of Instability

Document bugs, regressions, or flaky behaviour found during stabilisation here.

| ID | File / Area | Symptom | Status |
|----|-------------|---------|--------|
| 1  | `errors/ll_all2a.ss` / `src/astsimp.ml` | `append(x.next,y)` with ref field-access arg failed: disconnected existentials prevented predicate fold | **Fixed** 2026-05-12 |

---

## Build & Run Notes

```bash
# Build
make

# Run SLEEK on a .slk file
./sleek <file>.slk

# Run HIP on a .ss file
./hip <file>.ss

# Run with Z3 backend
./sleek --smt-z3 <file>.slk
```

---

## Test Regression Baseline

Before making changes, record expected pass/fail counts here so regressions are detectable.

| Test suite | Command | Expected result |
|------------|---------|-----------------|
|            |         |                 |
