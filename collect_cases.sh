#!/usr/bin/env bash
# Build failure_reports/cases/<group_dir>/ directories containing copies of
# the failing source files, grouped by error message.
# Must be run after run_examples.sh (needs failure_reports/raw/ to exist).

OUTDIR="failure_reports"
CASEDIR="$OUTDIR/cases"
HIP="./_build/default/hip.exe"
SLEEK="./_build/default/sleek.exe"
TIMEOUT=30

mkdir -p "$CASEDIR"

# -----------------------------------------------------------------------
# Re-derive the same failure classification used in run_examples.sh
# -----------------------------------------------------------------------

is_hip_failure() {
  grep -qE "Error3\(s\) detected|Procedure .* FAIL|Exception occurred:|Stream\.Error|TIMED_OUT" "$1"
}

is_sleek_failure() {
  grep -qE "SLEEK FAILURE|Exception occurred:|Stream\.Error|TIMED_OUT" "$1"
}

extract_error() {
  local rawfile="$1"
  if grep -q "TIMED_OUT" "$rawfile"; then echo "TIMEOUT (>30s)"; return; fi
  if grep -q 'Stream\.Error' "$rawfile"; then
    grep -oE 'Stream\.Error\("[^"]+"\)' "$rawfile" | head -1; return; fi
  if grep -q 'Invalid_argument' "$rawfile"; then
    grep 'Invalid_argument' "$rawfile" | head -1 \
      | grep -oE 'Invalid_argument\("[^"]+"\)' || \
      grep 'Invalid_argument' "$rawfile" | head -1 | sed 's/.*\(Invalid_argument[^)]*)\).*/\1/'
    return; fi
  if grep -q 'Exception occurred:' "$rawfile"; then
    grep 'Exception occurred:' "$rawfile" | head -1 | sed 's/Exception occurred: //' | cut -c1-120
    return; fi
  if grep -q 'Procedure .* FAIL' "$rawfile"; then
    procs=$(grep -oE 'Procedure [^ ]+ FAIL' "$rawfile" | head -3 | tr '\n' '; ')
    echo "Procedure FAIL: $procs"; return; fi
  if grep -q 'SLEEK FAILURE' "$rawfile"; then
    fail=$(grep -oE 'Fail \(.*\)' "$rawfile" | head -1)
    if [ -n "$fail" ]; then echo "SLEEK FAILURE: $fail"; else echo "SLEEK FAILURE"; fi
    return; fi
  if grep -q 'Error3' "$rawfile"; then
    errline=$(grep -v "fixcalc\|set_tp\|init_tp\|WARNING\|Error3" "$rawfile" \
              | grep -iE "^\s*ERROR:|error [0-9]+:" | head -1 | sed 's/^[[:space:]]*//')
    if [ -n "$errline" ]; then echo "Error3: $(echo "$errline" | cut -c1-120)"
    else echo "Error3(s) detected at main"; fi
    return; fi
  echo "UNKNOWN_FAILURE"
}

# -----------------------------------------------------------------------
# Walk all raw files, classify, accumulate FAIL_LIST
# -----------------------------------------------------------------------

FAIL_LIST=""

for rawfile in "$OUTDIR"/raw/*_hip.txt; do
  [ -f "$rawfile" ] || continue
  base=$(basename "$rawfile" _hip.txt)
  srcfile="examples/${base}.ss"
  [ -f "$srcfile" ] || continue
  if is_hip_failure "$rawfile"; then
    errkey=$(extract_error "$rawfile")
    FAIL_LIST="${FAIL_LIST}
${srcfile}	${errkey}"
  fi
done

for rawfile in "$OUTDIR"/raw/*_sleek.txt; do
  [ -f "$rawfile" ] || continue
  base=$(basename "$rawfile" _sleek.txt)
  srcfile="examples/${base}.slk"
  [ -f "$srcfile" ] || continue
  if is_sleek_failure "$rawfile"; then
    errkey=$(extract_error "$rawfile")
    FAIL_LIST="${FAIL_LIST}
${srcfile}	${errkey}"
  fi
done

# -----------------------------------------------------------------------
# Group by error key and copy source files
# -----------------------------------------------------------------------

unique_errors=$(printf '%s\n' "$FAIL_LIST" | grep -v '^$' | cut -f2 | sort -u)

group_idx=0
INDEX_MD="$CASEDIR/INDEX.md"

{
  echo "# Failure Cases Index"
  echo ""
  echo "Each subdirectory contains the source files for one error category."
  echo "Run from the project root: \`./_build/default/hip.exe <file>\` or \`./_build/default/sleek.exe <file>\`"
  echo ""
} > "$INDEX_MD"

while IFS= read -r errkey; do
  [ -z "$errkey" ] && continue
  group_idx=$((group_idx + 1))

  matched_files=$(printf '%s\n' "$FAIL_LIST" | grep -F "	$errkey" | cut -f1)
  count=$(printf '%s\n' "$matched_files" | grep -c '.' || true)

  # Short readable dir name: first 50 chars of sanitized key
  safename=$(printf '%s' "$errkey" | tr -cs 'a-zA-Z0-9_' '_' | cut -c1-50)
  groupdir="$CASEDIR/group_${group_idx}_${safename}"
  mkdir -p "$groupdir"

  # Write a README inside the group dir
  {
    echo "# Error: $errkey"
    echo ""
    echo "Files: $count"
    echo ""
    echo "## How to reproduce"
    echo ""
    printf '%s\n' "$matched_files" | while IFS= read -r fn; do
      [ -z "$fn" ] && continue
      ext="${fn##*.}"
      if [ "$ext" = "ss" ]; then
        echo "\`\`./_build/default/hip.exe $groupdir/$(basename "$fn")\`\`"
      else
        echo "\`\`./_build/default/sleek.exe $groupdir/$(basename "$fn")\`\`"
      fi
    done
  } > "$groupdir/README.md"

  # Copy source files
  printf '%s\n' "$matched_files" | while IFS= read -r fn; do
    [ -n "$fn" ] && cp "$fn" "$groupdir/"
  done

  echo "  Group $group_idx ($count files): $errkey"
  echo "    -> $groupdir/"

  # Add to index
  {
    echo "## Group $group_idx — \`$errkey\` ($count files)"
    echo ""
    printf '%s\n' "$matched_files" | while IFS= read -r fn; do
      [ -n "$fn" ] && echo "- \`$(basename "$fn")\`  →  \`$groupdir/$(basename "$fn")\`"
    done
    echo ""
  } >> "$INDEX_MD"

done <<< "$unique_errors"

echo ""
echo "Created $group_idx group directories under $CASEDIR/"
echo "Index: $INDEX_MD"
