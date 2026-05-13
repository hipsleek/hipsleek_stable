#!/usr/bin/env python3
"""
Check HIP/SLEEK examples for mismatches between expected output (from
comments) and actual tool output.

Annotation styles handled:
  [S1] SLEEK built-in:  `expect Valid.` / `expect Fail.` lines
       → look for `Validate N: FAIL` in output
  [S2] Dot-sequence header on first comment line:
       `// Valid.Fail.Valid.Valid.Fail`  (no spaces between tokens)
  [S3] Individual comment before/after a checkentail:
       `// Valid.`  or  `// Fail`  within 3 lines of the statement
  [S4] Numbered annotation before a checkentail:
       `//N. Valid.`  `//N. Fail.(must)`  `//N. Entail(M)=Valid.`

HIP .ss annotation handled:
  [H1] Per-procedure expected result embedded in a comment line:
       `// Procedure foo SUCCESS`  or  `// Procedure foo FAIL`

"may" vs "must" distinction is IGNORED: any Fail variant counts as Fail.

Outputs:
  failure_reports/expected_mismatch/summary.md
  failure_reports/expected_mismatch/group_<N>_<category>.md
  failure_reports/expected_mismatch/raw/<basename>.txt
"""

import re
import subprocess
import os
import sys
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────────────────────

ROOT        = Path(__file__).parent
HIP         = ROOT / "_build/default/hip.exe"
SLEEK       = ROOT / "_build/default/sleek.exe"
OUTDIR      = ROOT / "failure_reports" / "expected_mismatch"
RAWDIR      = OUTDIR / "raw"
TIMEOUT     = 45  # seconds

SCAN_DIRS   = ["examples", "errors", "validate", "baga", "bugs", "norm", "tut"]

# Directories to skip. These tests require non-default flags (e.g. -perm fperm)
# that are not currently supported end-to-end, so their expected annotations
# reflect a different execution mode and cannot be compared against default output.
EXCLUDE_DIRS = [
    "examples/fracperm",              # requires -perm fperm; float arithmetic unsupported in default mode
    "examples/working/sleek/fracperm", # same reason
    "examples/bperm",                 # requires -perm bperm; default mode does not support bounded perms
]

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def run(cmd, timeout=TIMEOUT):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).replace("ERROR : fixcalc cannot be found!!\n", "")
    except subprocess.TimeoutExpired:
        return "TIMED_OUT"

def normalise(s: str) -> str:
    """Normalise expected/actual to 'Valid' or 'Fail', ignoring may/must."""
    s = s.strip().lower()
    if "valid" in s:
        return "Valid"
    if "fail" in s:
        return "Fail"
    return ""

# ─────────────────────────────────────────────────────────────────────────────
# Parse actual SLEEK output → list of (entail_num, result) where result is
# 'Valid' or 'Fail'. Also collect Validate failures and parse errors.
# ─────────────────────────────────────────────────────────────────────────────

RE_ENTAIL  = re.compile(r"^Entail\s*\(?(\d+)\)?(?:\.\d+)?:\s*(Valid|Fail)", re.MULTILINE | re.IGNORECASE)
RE_VALIDATE = re.compile(r"^Validate\s+(\d+):\s*(OK|FAIL)", re.MULTILINE | re.IGNORECASE)
RE_UNEXPECTED = re.compile(r"Unexpected List:\s*\[([^\]]+)\]")

def parse_sleek_output(output: str):
    entails = {}
    for m in RE_ENTAIL.finditer(output):
        n, result = int(m.group(1)), m.group(2).capitalize()
        entails[n] = normalise(result)
    validate_fails = []
    for m in RE_VALIDATE.finditer(output):
        if m.group(2).upper() == "FAIL":
            validate_fails.append(int(m.group(1)))
    unexpected = []
    m = RE_UNEXPECTED.search(output)
    if m:
        unexpected = [x.strip() for x in m.group(1).split(",")]
    return entails, validate_fails, unexpected

# ─────────────────────────────────────────────────────────────────────────────
# Parse actual HIP output → dict of procedure_name → 'Success'/'Fail'
# ─────────────────────────────────────────────────────────────────────────────

RE_PROC = re.compile(r"^Procedure\s+(\S+)\s+(SUCCESS|FAIL)", re.MULTILINE | re.IGNORECASE)

def parse_hip_output(output: str):
    procs = {}
    for m in RE_PROC.finditer(output):
        procs[m.group(1)] = normalise(m.group(2))
    return procs

# ─────────────────────────────────────────────────────────────────────────────
# Detect annotation style in a .slk file
# Returns dict: {entail_num: expected_str}  (or None if no annotations found)
# Also returns bool: has_expect (SLEEK built-in style)
# ─────────────────────────────────────────────────────────────────────────────

RE_EXPECT   = re.compile(r"^\s*expect\s+(Valid|Fail)", re.IGNORECASE)
RE_DOT_SEQ  = re.compile(r"//\s*((?:Valid|Fail)\.(?:(?:Valid|Fail)\.?)*)", re.IGNORECASE)
# Matches: Valid. or Fail. tokens in a dot-sequence
RE_DOT_TOK  = re.compile(r"(Valid|Fail)\.?", re.IGNORECASE)

# Numbered annotation: //N. Valid. or //N. Fail. or //N. Entail(M)=Valid.
# These are extracted with their explicit entail number.
RE_NUMBERED   = re.compile(r"//\s*\(?(\d+)\)?[\.:]?\s*(?:Entail\s*\(\d+\)\s*=\s*)?(Valid|Fail)\b", re.IGNORECASE)

# Comment lines with Valid/Fail — used only when NO explicit number is present.
# Use non-greedy .*? to match the FIRST occurrence of Valid/Fail in the comment.
# Exclude descriptive uses: "fail due to", "fail when", "fail as", "fail because",
# "fail if", "fail caused", "fail since".
RE_COMMENT_VF = re.compile(
    r"//.*?\b(Valid|Fail)\b(?!\s*(?:due|when|as|because|if|since|caused|although|below|above|here|in\b))",
    re.IGNORECASE
)

def strip_block_comments(lines):
    """Return list of (orig_lineno, stripped_line) with block comments removed."""
    result = []
    in_block = False
    for i, line in enumerate(lines):
        if in_block:
            end = line.find("*/")
            if end >= 0:
                in_block = False
                result.append((i, line[end+2:]))
            else:
                result.append((i, ""))
        else:
            start = line.find("/*")
            if start >= 0:
                end = line.find("*/", start+2)
                if end >= 0:
                    result.append((i, line[:start] + line[end+2:]))
                else:
                    in_block = True
                    result.append((i, line[:start]))
            else:
                result.append((i, line))
    return result

def parse_slk_annotations(filepath):
    """
    Returns (has_expect, entail_expected) where:
      has_expect      : True if file uses SLEEK built-in `expect` statements
      entail_expected : dict {entail_num: 'Valid'/'Fail'} from comments
    """
    raw_lines = open(filepath, encoding="utf-8", errors="replace").readlines()
    lines = strip_block_comments(raw_lines)

    has_expect = any(RE_EXPECT.match(l) for _, l in lines)

    # S2: dot-sequence on the first 5 non-blank comment lines
    dot_seq = None
    for _, line in lines[:10]:
        line = line.strip()
        if not line:
            continue
        m = RE_DOT_SEQ.match(line)
        if m:
            tokens = RE_DOT_TOK.findall(m.group(1))
            if len(tokens) >= 2:
                dot_seq = [normalise(t) for t in tokens]
            break
        if not line.startswith("//"):
            break  # dot sequence only at very top

    # Collect checkentail positions and comment lines
    # Each checkentail counts as an entail (1-indexed)
    entail_line_indices = []  # list of line indices where checkentail appears
    comment_map = {}          # line_index -> normalised expected (unnumbered only)
    numbered_direct = {}      # entail_num -> normalised expected (from //N. annotations)

    for idx, (_, line) in enumerate(lines):
        stripped = line.strip()
        if re.match(r"checkentail\b", stripped, re.IGNORECASE):
            entail_line_indices.append(idx)

        # S4: numbered annotation — assign directly to the stated entail number.
        # Do NOT also add to comment_map so it doesn't bleed to adjacent entails.
        mn = RE_NUMBERED.search(stripped)
        if mn:
            n = int(mn.group(1))
            numbered_direct[n] = normalise(mn.group(2))
            continue  # skip generic RE_COMMENT_VF for this line

        # S3: unnumbered comment with Valid/Fail
        m = RE_COMMENT_VF.search(stripped)
        if m:
            comment_map[idx] = normalise(m.group(1))

    # S2: if dot-sequence, map tokens to entail numbers
    entail_expected = {}
    if dot_seq:
        for i, expected in enumerate(dot_seq):
            entail_expected[i+1] = expected

    # S3: associate unnumbered comments with nearest checkentail using a window.
    # Comments that appear AFTER a checkentail use a tight window (≤1 line) to
    # avoid a comment meant for the next entail being claimed by the previous one.
    # Each comment is consumed once: after it is assigned to an entail it cannot
    # bleed into the next entail (e.g. "// 2. OK valid" must not also annotate
    # entail 3 just because it falls within the WINDOW_BEFORE distance).
    WINDOW_BEFORE = 4   # lines before checkentail
    WINDOW_AFTER  = 1   # lines after checkentail (tight: inline or one-liner residue)
    used_comments: set = set()
    for entail_num, ei in enumerate(entail_line_indices, start=1):
        if entail_num in entail_expected:
            continue  # already from dot-sequence
        best_dist = max(WINDOW_BEFORE, WINDOW_AFTER) + 1
        best_ci   = None
        best_val  = None
        for ci, expected in comment_map.items():
            if ci in used_comments:
                continue  # already consumed by a closer entail
            dist = abs(ci - ei)
            limit = WINDOW_BEFORE if ci <= ei else WINDOW_AFTER
            if dist <= limit and dist < best_dist:
                best_dist = dist
                best_ci   = ci
                best_val  = expected
        if best_val:
            entail_expected[entail_num] = best_val
            used_comments.add(best_ci)

    # S4: direct numbered annotations override proximity-based ones.
    # Only accept entail numbers within the file's actual checkentail count;
    # larger numbers are likely test-suite IDs or historical notes (e.g. "// (15) Fail"
    # in a file with only 1 checkentail refers to BAGA test #15, not entail #15).
    n_entails = len(entail_line_indices)
    for n, v in numbered_direct.items():
        if 1 <= n <= n_entails:
            entail_expected[n] = v

    return has_expect, entail_expected

# ─────────────────────────────────────────────────────────────────────────────
# Parse HIP .ss annotations → dict {proc_name: 'Valid'/'Fail'}
# ─────────────────────────────────────────────────────────────────────────────

RE_PROC_COMMENT = re.compile(
    r"//.*\bProcedure\s+(\S+)\s+(SUCCESS|FAIL)\b", re.IGNORECASE
)

def parse_ss_annotations(filepath):
    """
    Returns dict {proc_name: expected} from comment annotations.
    Looks for: `// Procedure foo SUCCESS` or `// Procedure foo FAIL`
    """
    expected = {}
    for line in open(filepath, encoding="utf-8", errors="replace"):
        m = RE_PROC_COMMENT.search(line)
        if m:
            expected[m.group(1)] = normalise(m.group(2))
    return expected

# ─────────────────────────────────────────────────────────────────────────────
# Check one .slk file
# ─────────────────────────────────────────────────────────────────────────────

def check_slk(filepath, rawdir):
    rawfile = rawdir / (filepath.stem + "_sleek.txt")
    output  = run([str(SLEEK), str(filepath)])
    rawfile.write_text(output)

    if output == "TIMED_OUT":
        return [{"file": str(filepath), "type": "TIMEOUT", "detail": "sleek timed out"}]

    # Check for parse/crash errors — skip annotation comparison
    if "Error3(s) detected" in output or "Stream.Error" in output or "Exception occurred" in output:
        return []  # already captured in run_examples; not an expected-output mismatch

    has_expect, entail_expected = parse_slk_annotations(filepath)
    actual_entails, validate_fails, unexpected = parse_sleek_output(output)

    mismatches = []

    # S1: SLEEK built-in validate failures
    if has_expect and (validate_fails or unexpected):
        for n in validate_fails:
            actual = actual_entails.get(n, "?")
            mismatches.append({
                "file": str(filepath),
                "type": "expect-mismatch",
                "detail": f"Entail {n}: expected (via `expect`) did not match actual={actual}",
                "entail": n,
            })
        for x in unexpected:
            if x not in [str(v) for v in validate_fails]:
                mismatches.append({
                    "file": str(filepath),
                    "type": "expect-mismatch",
                    "detail": f"Unexpected entail {x}",
                    "entail": x,
                })

    # S2/S3/S4: comment-based annotations — only when file lacks authoritative expect statements.
    # If the file uses `expect Valid.`/`expect Fail.` (S1), those are authoritative;
    # comment annotations (e.g. "// (15) Fail" as a descriptive note) would be misleading.
    if not has_expect:
        for n, expected in entail_expected.items():
            if not expected:
                continue
            actual = actual_entails.get(n)
            if actual is None:
                continue  # entail not in output (maybe crashed before reaching it)
            if actual != expected:
                mismatches.append({
                    "file": str(filepath),
                    "type": "comment-mismatch",
                    "detail": f"Entail {n}: expected={expected}, actual={actual}",
                    "entail": n,
                })

    return mismatches

# ─────────────────────────────────────────────────────────────────────────────
# Check one .ss file
# ─────────────────────────────────────────────────────────────────────────────

def check_ss(filepath, rawdir):
    ann = parse_ss_annotations(filepath)
    if not ann:
        return []

    rawfile = rawdir / (filepath.stem + "_hip.txt")
    output  = run([str(HIP), str(filepath)])
    rawfile.write_text(output)

    if output == "TIMED_OUT":
        return [{"file": str(filepath), "type": "TIMEOUT", "detail": "hip timed out"}]

    actual = parse_hip_output(output)
    mismatches = []
    for proc, expected in ann.items():
        act = actual.get(proc)
        if act is None:
            continue
        if act != expected:
            mismatches.append({
                "file": str(filepath),
                "type": "comment-mismatch",
                "detail": f"Procedure {proc}: expected={expected}, actual={act}",
            })
    return mismatches

# ─────────────────────────────────────────────────────────────────────────────
# Main scan
# ─────────────────────────────────────────────────────────────────────────────

def main():
    OUTDIR.mkdir(parents=True, exist_ok=True)
    RAWDIR.mkdir(exist_ok=True)

    all_mismatches = []  # list of mismatch dicts
    total_checked  = 0
    total_skipped  = 0  # files with no annotations

    for dirname in SCAN_DIRS:
        d = ROOT / dirname
        if not d.exists():
            continue
        slk_files = sorted(d.rglob("*.slk"))
        ss_files  = sorted(d.rglob("*.ss"))

        print(f"\n{'='*60}")
        print(f"  {dirname}/ : {len(slk_files)} .slk, {len(ss_files)} .ss")
        print(f"{'='*60}")

        for f in slk_files:
            # Skip files from excluded subtrees
            rel_str = str(f.relative_to(ROOT))
            if any(rel_str.startswith(ex) for ex in EXCLUDE_DIRS):
                total_skipped += 1
                continue
            # Quick pre-check: does file have any annotation?
            text = f.read_text(encoding="utf-8", errors="replace")
            has_ann = bool(
                re.search(r"^\s*expect\s+(Valid|Fail)", text, re.MULTILINE | re.IGNORECASE)
                or re.search(r"//.*\b(Valid|Fail)\b", text, re.IGNORECASE)
            )
            if not has_ann:
                total_skipped += 1
                continue

            rel = f.relative_to(ROOT)
            print(f"  slk  {rel}", end=" ... ", flush=True)
            ms = check_slk(f, RAWDIR)
            total_checked += 1
            if ms:
                print(f"MISMATCH ({len(ms)})")
                all_mismatches.extend(ms)
            else:
                print("ok")

        for f in ss_files:
            text = f.read_text(encoding="utf-8", errors="replace")
            has_ann = bool(
                re.search(r"//.*\bProcedure\s+\S+\s+(SUCCESS|FAIL)\b", text, re.IGNORECASE)
            )
            if not has_ann:
                total_skipped += 1
                continue

            rel = f.relative_to(ROOT)
            print(f"  ss   {rel}", end=" ... ", flush=True)
            ms = check_ss(f, RAWDIR)
            total_checked += 1
            if ms:
                print(f"MISMATCH ({len(ms)})")
                all_mismatches.extend(ms)
            else:
                print("ok")

    # ─────────────────────────────────────────────────────────────────────────
    # Group mismatches by type
    # ─────────────────────────────────────────────────────────────────────────
    groups = {}
    for m in all_mismatches:
        key = m["type"]
        groups.setdefault(key, []).append(m)

    # Also group by file for per-file view
    by_file = {}
    for m in all_mismatches:
        by_file.setdefault(m["file"], []).append(m)

    # ─────────────────────────────────────────────────────────────────────────
    # Write per-type group files
    # ─────────────────────────────────────────────────────────────────────────
    group_files = []
    for gidx, (gtype, items) in enumerate(sorted(groups.items()), start=1):
        gfile = OUTDIR / f"group_{gidx}_{gtype.replace('-','_')}.md"
        group_files.append((gtype, len(items), gfile))
        with open(gfile, "w") as f:
            f.write(f"# Group {gidx}: `{gtype}`\n\n")
            f.write(f"**Total mismatches**: {len(items)}\n\n")
            f.write("## Mismatches\n\n")
            for m in items:
                f.write(f"### `{m['file']}`\n")
                f.write(f"- {m['detail']}\n\n")

    # Per-file group
    pf_file = OUTDIR / "group_by_file.md"
    with open(pf_file, "w") as f:
        f.write("# Mismatches by File\n\n")
        for filepath, items in sorted(by_file.items()):
            f.write(f"## `{filepath}`\n\n")
            for m in items:
                f.write(f"- {m['detail']}\n")
            f.write("\n")

    # ─────────────────────────────────────────────────────────────────────────
    # Copy failing source files into case directories
    # ─────────────────────────────────────────────────────────────────────────
    cases_dir = OUTDIR / "cases"
    cases_dir.mkdir(exist_ok=True)
    for gidx, (gtype, count, gfile) in enumerate(group_files, start=1):
        gdir = cases_dir / f"group_{gidx}_{gtype.replace('-','_')}"
        gdir.mkdir(exist_ok=True)
        items = groups[gtype]
        seen = set()
        for m in items:
            fp = Path(m["file"])
            if fp.name not in seen and fp.exists():
                import shutil
                shutil.copy(fp, gdir / fp.name)
                seen.add(fp.name)
        # README
        with open(gdir / "README.md", "w") as rf:
            rf.write(f"# Mismatch group: {gtype}\n\n")
            rf.write(f"Files: {len(seen)}\n\n")
            for fp_name in seen:
                ext = Path(fp_name).suffix
                tool = "sleek" if ext == ".slk" else "hip"
                rf.write(f"`./_build/default/{tool}.exe {gdir}/{fp_name}`\n\n")

    # ─────────────────────────────────────────────────────────────────────────
    # Summary
    # ─────────────────────────────────────────────────────────────────────────
    n_mismatch_files = len(by_file)
    with open(OUTDIR / "summary.md", "w") as f:
        f.write("# Expected-Output Mismatch Report\n\n")
        f.write(f"| Metric | Count |\n|--------|-------|\n")
        f.write(f"| Files checked (had annotations) | {total_checked} |\n")
        f.write(f"| Files skipped (no annotations)  | {total_skipped} |\n")
        f.write(f"| Files with mismatches           | {n_mismatch_files} |\n")
        f.write(f"| Total mismatch entries          | {len(all_mismatches)} |\n\n")
        f.write("## Groups\n\n")
        for gtype, count, gfile in group_files:
            f.write(f"### `{gtype}` ({count} mismatches)\n\n")
            items = groups[gtype]
            seen_files = {}
            for m in items:
                seen_files.setdefault(m["file"], []).append(m["detail"])
            for fp, details in sorted(seen_files.items()):
                f.write(f"- **`{fp}`**\n")
                for d in details:
                    f.write(f"  - {d}\n")
            f.write(f"\nDetails: [`{gfile.name}`]({gfile})\n\n")
        f.write(f"\n[Full file listing]({pf_file.name})\n")

    print(f"\n{'='*60}")
    print(f" Checked: {total_checked} files")
    print(f" Mismatches in: {n_mismatch_files} files ({len(all_mismatches)} total)")
    print(f" Reports: {OUTDIR}/")
    print(f"{'='*60}")

if __name__ == "__main__":
    os.chdir(ROOT)
    main()
