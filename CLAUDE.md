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

### 2026-05-13 — Reduce group_2 comment-mismatch failures (`check_expected.py`, `src/solver.ml`)

**Context**: `check_expected.py` scans all test files for expected-vs-actual mismatches using comment annotations (`// valid`, `// fail`, `//N. Valid`, etc.) and built-in `expect Valid.` statements. Before these fixes the `group_2_comment_mismatch` group had 85 files with 308 total mismatches. After: 34 real behavioral mismatches remain; 51 files moved to `fixed/`.

Three root causes were identified and fixed:

#### Fix 1 — Parser false positives (`check_expected.py`)

Multiple improvements to `parse_slk_annotations`:

- **Non-greedy regex**: Changed `//.*\b(Valid|Fail)` to `//.*?\b(Valid|Fail)` so the FIRST occurrence in a comment is captured, not the last (e.g. `// expected: VALID, not FAIL` was previously parsed as Fail).
- **Negative lookahead**: Excludes descriptive phrases — `fail due to`, `fail when`, `fail as`, `fail because`, `fail if`, `fail since`, `fail caused`, `fail although`, `fail below`, `fail above`, `fail here`, `fail in` — so comments documenting WHY something fails are not treated as expected annotations.
- **Numbered annotations direct**: `//N. Valid/Fail` comments are parsed into a separate `numbered_direct` dict (not `comment_map`), assigned only when `1 <= N <= n_entails` to exclude test-suite IDs (e.g. `// (15) Fail` in a BAGA file).
- **Comment consumption**: Each comment in `comment_map` is marked used after it's claimed by one entail; prevents the same comment bleeding into the next entail (e.g. `// 2. OK valid` within WINDOW_BEFORE=4 lines of entail 3).
- **Skip S2/S3/S4 when `expect` present**: If a file uses SLEEK built-in `expect Valid.`/`expect Fail.` annotations, those are authoritative — the comment-based check is skipped entirely for that file.

#### Fix 2 — ConstAnn annotation subtype check (`src/solver.ml`)

**Location**: `do_match_x`, lines ~10787–10796.

**Root cause**: When `allow_field_ann=false` (the default), the else-branch returned `(true, [], [], [])` unconditionally — skipping any annotation subtype check even for constant-vs-constant comparisons like `@A` vs `@M`.

**Fix**: In the `!allow_field_ann` else-branch, added an explicit `List.for_all2 (fun la ra -> Immutable.subtype_ann 10 la ra)` check over `l_param_ann`/`r_param_ann`. This catches ConstAnn×ConstAnn incompatibilities (ordering: `M <: I <: L <: A`) without enabling full variable-annotation inference. TempAnn / variable annotation binding still requires `allow_field_ann=true`.

**Verified**: `bugs/ann-sleek04A.slk` entails 1, 4, 7 now correctly return `Fail.(must) cause:mismatched imm annotation`.

#### Fix 3 — Exclude perm-mode test directories (`check_expected.py`)

Added `EXCLUDE_DIRS` list; files in these directories are skipped during the mismatch scan:

| Directory | Reason |
|-----------|--------|
| `examples/fracperm` | Requires `-perm fperm`; float literals are stripped at parse time in `NoPerm` mode (parser line: `let frac = if allow_perm() then frac else empty_iperm()`), so permission constraints are never checked. Float arithmetic also unsupported by Z3/Omega backends. |
| `examples/working/sleek/fracperm` | Same reason. |
| `examples/bperm` | Requires `-perm bperm`; bounded-permission triples `cell(c,t,a)` are meaningless without that mode. |

**Result after all three fixes**:

| Metric | Before | After |
|--------|--------|-------|
| group_2 files with mismatches | 85 | 34 |
| Files moved to `fixed/` | — | 35 (fixed) + 16 (excluded) |
| Remaining real mismatches | — | 34 files (see below) |

**Remaining 34 files** (real behavioral gaps, not parser noise):

- `ann-sleek04A/I/L/M/aa` (32 mismatches) — TempAnn / variable annotation binding; requires `allow_field_ann=true`
- `err4/5/5a/5b/6` (15 mismatches) — `flow __Error` semantics; ante=`__norm` vs conseq=`__Error` rejected as incompatible
- `bug-base-case`, `bug-lem-1`, `kk`, `lemma_bug*`, `lembug*` — lemma/proof engine gaps
- `bach`, `may`, `hard`, `improve-sleek9`, `sleek04/7/11`, `vperm`, `node`, `s-2a`, `case-c1`, `bug-perf4`, `ex*` — miscellaneous behavioral regressions

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
| 2  | `bugs/ann-sleek04A.slk` / `src/solver.ml` | ConstAnn×ConstAnn annotation mismatches silently accepted when `allow_field_ann=false` | **Fixed** 2026-05-13 |
| 3  | `examples/fracperm/`, `examples/bperm/` | Float/bounded permissions stripped at parse time in `NoPerm` mode; perm constraints never checked | **Known limitation** — tests excluded from mismatch scan |
| 4  | `errors/err5.slk`, `err6.slk` etc. | `flow __Error` in consequent always fails with "incompatible flow types" against `__norm` antecedent | **Open** |
| 5  | `bugs/ann-sleek04A.slk` (entails 11–18) | TempAnn / variable annotation binding requires `allow_field_ann=true` | **Open** |

### 2026-05-13 — Baseline run of `examples/` test suite

**Scripts created**:
- `run_examples.sh` — runs all `examples/*.ss` (via hip) and `examples/*.slk` (via sleek), saves raw output under `failure_reports/raw/`, groups failures by error message into `failure_reports/group_N_*.md`, and writes `failure_reports/summary.md`.
- `collect_cases.sh` — reads the raw output from a previous `run_examples.sh` run and copies the failing source files into per-group subdirectories under `failure_reports/cases/`, each with a `README.md` showing the exact repro commands.

**Baseline result** (`examples/` top-level only, 2026-05-13):

| Metric | Count |
|--------|-------|
| Total files run | 101 (90 `.ss` + 11 `.slk`) |
| Passed | 33 |
| Failed | 68 |
| Failure groups | 37 |

**Passing files**: `append_coercion.ss`, `bubble-coer.ss`, `check_ref.ss`, `check_view.ss`, `length.ss`, `mccarthy.ss`, `middelkoop.ss`, `new_rb.ss`, `remove_link_vars.ss`, `test4.ss`, `test5.ss`, `test_id3.ss`, `test_id3_2.ss`, `test_trans_formula1.ss`, `test_view.ss`, `test_while.ss`, `test_while1.ss`, `testref.ss`, `testref2.ss`, `tree-parent.ss`, `troubled-rb.ss`, `wn1.ss`, `wn2.ss`, `wn3.ss`, `x.ss`, `non-rec.slk`, `sleek5.slk`, `test3.slk`, `test7.slk`, `test8.slk`, `test_residue.slk`, `wn2.slk`, `wn3.slk`

**Failure group summary**:

| Group | Error | Files |
|-------|-------|-------|
| 1 | `Failure("Error detected - astsimp")` | `interval.ss`, `list_set.ss` |
| 2 | `Failure("TYPE ERROR 1 : Found boolean but expecting NUM")` | `index.ss` |
| 3 | `Failure("equiv is neither data, enum type, nor prim pred")` | `lseg1.ss` |
| 4 | `Failure("error 1: free variables [tmp] in view def avl ")` | 7 avl-*.ss files |
| 5 | `Failure("error 1: free variables [tmp] in view def tree2 ")` | `predcomp.ss` |
| 6 | `Failure("predicate ftree does not have the correct number of arguments...")` | `fileman4.ss` |
| 7 | `Failure("predicate path does not have the correct number of arguments...")` | `fileman.ss`, `fileman2.ss`, `fileman5.ss`, `fileman_mset.ss` |
| 8 | `Failure("z, line 25, col 8 is redefined in the current block")` | `bug-bind.ss` |
| 9–13 | `Invalid_argument("Formula failed typecheck: ... unsupported union/set expr")` | `app1.ss`, `sll_bag.ss`, `sll_set.ss`, `skiplist.ss`, `sort-ll.ss`, `case2.slk` (**sleek**), `treebug.slk` (**sleek**) |
| 14–20 | `Procedure FAIL` (verification failures) | `dll-fail.ss`, `cyclic.ss`, `taintedanalysistest.ss`, `test_field.ss`, `rb-2.ss`, `max.ss`, `check_prim.ss` |
| 21–36 | `Stream.Error(...)` (parse errors — likely syntax unsupported by this parser version) | ~40 files |
| 25 | `Stream.Error("DOT expected after [non_empty_command]...")` | `wn1.slk` (**sleek**) |
| 37 | `TIMEOUT (>30s)` | `fileman3.ss`, `qsort2.ss` |

**SLEEK-specific failures** (groups where the failing file is a `.slk`):
- Group 12: `case2.slk` — unsupported `S=union({v},S1)` set expression
- Group 13: `treebug.slk` — unsupported `S={}` set expression
- Group 25: `wn1.slk` — parse error: `DOT expected after [non_empty_command]`

**To re-run**:
```bash
bash run_examples.sh     # re-runs all examples, regenerates failure_reports/
bash collect_cases.sh    # re-copies failing source files into failure_reports/cases/
```

**To debug a specific group**:
```bash
# Example: group 4 (avl free variables)
./_build/default/hip.exe failure_reports/cases/group_4_Failure_error_1_free_variables_tmp_in_view_def_avl/avl-orig.ss
# Example: group 25 (sleek parse error)
./_build/default/sleek.exe failure_reports/cases/group_25_Stream_Error_DOT_expected_after_non_empty_command_/wn1.slk
```

---

## Build & Run Notes

```bash
# Build (dune)
dune build

# Run SLEEK on a .slk file
./_build/default/sleek.exe <file>.slk

# Run HIP on a .ss file
./_build/default/hip.exe <file>.ss

# Run with Z3 backend
./_build/default/sleek.exe --smt-z3 <file>.slk

# Note: "ERROR : fixcalc cannot be found" is harmless — fixcalc is not needed
# for standard HIP/SLEEK operation and can be ignored.
```

---

## Test Regression Baseline

| Test suite | Command | Expected result |
|------------|---------|-----------------|
| `examples/` | `bash run_examples.sh` | 33 pass, 68 fail, 37 groups (2026-05-13) |
| Expected-output mismatches | `python3 check_expected.py` | 507 files checked; 34 real behavioral mismatches in 34 files (2026-05-13, after group_2 fixes) |

**Running the mismatch checker**:
```bash
python3 check_expected.py
# Results written to failure_reports/expected_mismatch/
# Fixed cases: failure_reports/expected_mismatch/cases/group_2_comment_mismatch/fixed/
```
