#!/usr/bin/env bash
# Run all top-level examples, collect failures, group by error message.

OUTDIR="failure_reports"
HIP="./_build/default/hip.exe"
SLEEK="./_build/default/sleek.exe"
TIMEOUT=30

mkdir -p "$OUTDIR/raw"

# -----------------------------------------------------------------------
# Run one file and save output; append TIMED_OUT marker if limit hit.
# -----------------------------------------------------------------------
run_and_save() {
  local tool="$1" f="$2" rawfile="$3"
  timeout "$TIMEOUT" "$tool" "$f" > "$rawfile" 2>&1
  local rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "TIMED_OUT" >> "$rawfile"
  fi
}

# -----------------------------------------------------------------------
# Failure detection
# -----------------------------------------------------------------------
is_hip_failure() {
  grep -qE "Error3\(s\) detected|Procedure .* FAIL|Exception occurred:|Stream\.Error|TIMED_OUT" "$1"
}

is_sleek_failure() {
  grep -qE "SLEEK FAILURE|Exception occurred:|Stream\.Error|TIMED_OUT" "$1"
}

# -----------------------------------------------------------------------
# Extract primary error key from raw output file.
# -----------------------------------------------------------------------
extract_error() {
  local rawfile="$1"

  if grep -q "TIMED_OUT" "$rawfile"; then
    echo "TIMEOUT (>30s)"; return
  fi

  if grep -q 'Stream\.Error' "$rawfile"; then
    grep -oE 'Stream\.Error\("[^"]+"\)' "$rawfile" | head -1; return
  fi

  if grep -q 'Invalid_argument' "$rawfile"; then
    # Grab up to the closing paren of Invalid_argument(...)
    grep 'Invalid_argument' "$rawfile" | head -1 \
      | grep -oE 'Invalid_argument\("[^"]+"\)' || \
      grep 'Invalid_argument' "$rawfile" | head -1 | sed 's/.*\(Invalid_argument[^)]*)\).*/\1/'
    return
  fi

  if grep -q 'Exception occurred:' "$rawfile"; then
    # Extract the exception type and a clean message (handles escaped quotes inside)
    local excline
    excline=$(grep 'Exception occurred:' "$rawfile" | head -1 | sed 's/Exception occurred: //')
    # Shorten very long messages
    echo "$excline" | cut -c1-120
    return
  fi

  if grep -q 'Procedure .* FAIL' "$rawfile"; then
    procs=$(grep -oE 'Procedure [^ ]+ FAIL' "$rawfile" | head -3 | tr '\n' '; ')
    echo "Procedure FAIL: $procs"; return
  fi

  if grep -q 'SLEEK FAILURE' "$rawfile"; then
    fail=$(grep -oE 'Fail \(.*\)' "$rawfile" | head -1)
    if [ -n "$fail" ]; then echo "SLEEK FAILURE: $fail"; else echo "SLEEK FAILURE"; fi
    return
  fi

  if grep -q 'Error3' "$rawfile"; then
    # Look for specific ERROR: or error N: lines (may have leading whitespace)
    errline=$(grep -v "fixcalc\|set_tp\|init_tp\|WARNING\|Error3" "$rawfile" \
              | grep -iE "^\s*ERROR:|error [0-9]+:" | head -1 | sed 's/^[[:space:]]*//')
    if [ -n "$errline" ]; then
      echo "Error3: $(echo "$errline" | cut -c1-120)"
    else
      echo "Error3(s) detected at main"
    fi
    return
  fi

  echo "UNKNOWN_FAILURE"
}

# -----------------------------------------------------------------------
# Tracking: accumulated as lines with TAB separator
# -----------------------------------------------------------------------
PASS_LIST=""
FAIL_LIST=""   # "file TAB errkey" lines

process_file() {
  local tool="$1" f="$2" check_fn="$3" toolname="$4"
  local bname rawfile
  bname=$(basename "${f%.*}")
  rawfile="$OUTDIR/raw/${bname}_${toolname}.txt"

  printf "  %-42s " "$(basename "$f")"
  run_and_save "$tool" "$f" "$rawfile"

  if "$check_fn" "$rawfile"; then
    local errkey
    errkey=$(extract_error "$rawfile")
    echo "FAIL: $errkey"
    FAIL_LIST="${FAIL_LIST}
${f}	${errkey}"
  else
    echo "OK"
    PASS_LIST="${PASS_LIST}
${f}"
  fi
}

# -----------------------------------------------------------------------
# Run all examples
# -----------------------------------------------------------------------
echo "=== Running HIP on .ss files ==="
for f in examples/*.ss; do
  [ -f "$f" ] && process_file "$HIP" "$f" is_hip_failure "hip"
done

echo ""
echo "=== Running SLEEK on .slk files ==="
for f in examples/*.slk; do
  [ -f "$f" ] && process_file "$SLEEK" "$f" is_sleek_failure "sleek"
done

# -----------------------------------------------------------------------
# Group failures by error key
# -----------------------------------------------------------------------
echo ""
echo "=== Writing grouped reports ==="

unique_errors=$(printf '%s' "$FAIL_LIST" | grep -v '^$' | cut -f2 | sort -u)

group_idx=0
GROUP_SUMMARY=""

while IFS= read -r errkey; do
  [ -z "$errkey" ] && continue
  group_idx=$((group_idx + 1))

  matched_files=$(printf '%s\n' "$FAIL_LIST" | grep -F "	$errkey" | cut -f1)
  count=$(printf '%s\n' "$matched_files" | grep -c '.' || true)

  safename=$(printf '%s' "$errkey" | tr -cs 'a-zA-Z0-9_' '_' | cut -c1-70)
  groupfile="$OUTDIR/group_${group_idx}_${safename}.md"

  {
    printf '# Group %d: `%s`\n\n' "$group_idx" "$errkey"
    printf '**Files affected**: %d\n\n' "$count"
    printf '## Affected Files\n\n'
    printf '%s\n' "$matched_files" | while IFS= read -r fn; do
      [ -n "$fn" ] && echo "- \`$fn\`"
    done
    printf '\n## Sample Output (up to 3 files)\n\n'
    sample=0
    printf '%s\n' "$matched_files" | while IFS= read -r fn; do
      [ -z "$fn" ] && continue
      [ "$sample" -ge 3 ] && break
      ext="${fn##*.}"
      base=$(basename "${fn%.*}")
      if [ "$ext" = "ss" ]; then rawfile="$OUTDIR/raw/${base}_hip.txt"
      else rawfile="$OUTDIR/raw/${base}_sleek.txt"; fi
      printf '### `%s`\n```\n' "$fn"
      grep -v "fixcalc cannot be found\|set_tp z3\|init_tp\|WARNING.*astsimp\|WARNING.*sleekmain\|WARNING.*logtime\|processing primitives\|Full processing file\|Parsing file" \
        "$rawfile" 2>/dev/null | grep -v '^$' | head -35 || true
      printf '```\n\n'
      sample=$((sample + 1))
    done
  } > "$groupfile"

  GROUP_SUMMARY="${GROUP_SUMMARY}
### Group ${group_idx} — \`${errkey}\` (${count} files)

$(printf '%s\n' "$matched_files" | while IFS= read -r fn; do [ -n "$fn" ] && echo "- \`$fn\`"; done)

Details: [\`$(basename "$groupfile")\`]($groupfile)
"
done <<< "$unique_errors"

# -----------------------------------------------------------------------
# Write master summary
# -----------------------------------------------------------------------
total_fail=$(printf '%s\n' "$FAIL_LIST" | grep -c '.' || true)
total_pass=$(printf '%s\n' "$PASS_LIST" | grep -c '.' || true)
total=$((total_fail + total_pass))

{
  printf '# Example Run Summary — %s\n\n' "$(date '+%Y-%m-%d')"
  printf '| Metric | Count |\n|--------|-------|\n'
  printf '| Total files run | %d |\n' "$total"
  printf '| Passed | %d |\n' "$total_pass"
  printf '| Failed | %d |\n' "$total_fail"
  printf '| Failure groups | %d |\n\n' "$group_idx"

  printf '## Passing Files\n\n'
  printf '%s\n' "$PASS_LIST" | while IFS= read -r f; do
    [ -n "$f" ] && echo "- \`$f\`"
  done

  printf '\n## Failure Groups\n\n%s\n' "$GROUP_SUMMARY"
} > "$OUTDIR/summary.md"

echo ""
echo "============================================"
printf " Results: %d passed, %d failed / %d total\n" "$total_pass" "$total_fail" "$total"
printf " Failure groups: %d\n" "$group_idx"
echo " Reports: $OUTDIR/"
echo " Summary: $OUTDIR/summary.md"
echo "============================================"
