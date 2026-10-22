#!/usr/bin/env bash
set -uo pipefail

# Determine the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Path to the script under test
SCRIPT="${SCRIPT_DIR}/archive_files.sh"
# Directory where backup archives are expected to be created
BACKUP_DIR="${HOME}/tmp/backup"
mkdir -p "$BACKUP_DIR"

# Counters for passed and failed tests
PASS=0
FAIL=0
# Array to track temporary directories for cleanup
TMP_DIRS=()

# Cleanup function: remove all temporary directories on exit
cleanup() {
    for d in "${TMP_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
    done
}
trap cleanup EXIT

# Create a temporary directory, register it for cleanup, and print its path
make_test_dir() {
    local d
    d=$(mktemp -d)
    TMP_DIRS+=("$d")
    echo "$d"
}

# Remove any leftover backup archives from previous test runs
clean_backup() {
    find "$BACKUP_DIR" -maxdepth 1 -type f -name '*_old_*.tar.gz' -delete 2>/dev/null || true
}

# Run a single test function and update PASS/FAIL counters
run_test() {
    local name="$1"
    if "$name"; then
        ((PASS++))
    else
        ((FAIL++))
    fi
}

# Check whether the `lsof` utility is available
has_lsof() { command -v lsof >/dev/null 2>&1; }

# --- T1 ---
# Verify that no archive is created when the size threshold is not reached
test_threshold_not_reached() {
    local test_dir
    test_dir=$(make_test_dir)
    echo "x" > "${test_dir}/file1.log"
    clean_backup

    local output
    output=$("$SCRIPT" "$test_dir" 80 5 2>&1) || true

     # Expect a message indicating the threshold was not reached 

    if ! grep -q "Threshold is not reached" <<<"$output"; then
        echo "FAIL [T1]: no statement the threshould hasnt been reached"
        return 1
    fi
    # Expect that no archive was produced
    if find "$BACKUP_DIR" -maxdepth 1 -name "${test_dir##*/}_old_*.tar.gz" | grep -q .; then
        echo "FAIL [T1]: archive was created - it shouldnt be"
        return 1
    fi
    echo "PASS [T1]"
}

# --- T2 ---
# Verify that an archive is created when the threshold is reached, and contains the expected number of files
test_threshold_reached_and_archive() {
    local test_dir
    test_dir=$(make_test_dir)
    for i in 1 2 3 4 5; do
        echo "log$i" > "${test_dir}/log${i}.txt"
        touch -t 202001011200 "${test_dir}/log${i}.txt"
    done
    clean_backup

    local output
    output=$("$SCRIPT" "$test_dir" 0 3 2>&1) || true

    # Expect an "Archive is created:" message
    if ! grep -q "Archive is created:" <<<"$output"; then
        echo "FAIL [T2]: archive hasnt been created"
        return 1
    fi
    # Locate the most recent archive file
    local archive_path
    archive_path=$(ls -1t "$BACKUP_DIR"/*_old_*.tar.gz 2>/dev/null | head -n1)
    if [[ -z "$archive_path" || ! -f "$archive_path" ]]; then
        echo "FAIL [T2]: archive file was not found in $BACKUP_DIR."
        return 1
    fi
    
    # Verify archive contents: exactly 3 files expected
    local count
    count=$(tar -tzf "$archive_path" | wc -l | tr -d ' ')
    if [[ "$count" != "3" ]]; then
        echo "FAIL [T2]: $count files in archive instead 3."
        return 1
    fi
    echo "PASS [T2]"
}

# --- T3 ---
# Verify that files matching the exclude mask are not included in the archive
test_exclude_mask() {
    local test_dir
    test_dir=$(make_test_dir)
    echo a > "${test_dir}/keep1.log"
    echo b > "${test_dir}/keep2.log"
    echo c > "${test_dir}/skip_me.tmp"
    touch -t 202001011200 "${test_dir}/skip_me.tmp"  
    clean_backup

    local output
    output=$("$SCRIPT" "$test_dir" 0 5 "*.tmp" 2>&1) || true

     # An archive must exist
    local archive_path
    archive_path=$(ls -1t "$BACKUP_DIR"/*_old_*.tar.gz 2>/dev/null | head -n1)
    if [[ -z "$archive_path" ]]; then
        echo "FAIL [T3]: archive was not created."
        return 1
    fi
     # Excluded file must not be inside the archive
    if tar -tzf "$archive_path" | grep -q "skip_me.tmp"; then
        echo "FAIL [T3]: skip_me.tmp in archive."
        return 1
    fi
    if ! tar -tzf "$archive_path" | grep -q "keep1.log"; then
        echo "FAIL [T3]: keep1.log is not in archive."
        return 1
    fi
    echo "PASS [T3]"
}

# --- T4 ---
# Verify that a non-numeric threshold argument is rejected
test_invalid_args() {
    local test_dir
    test_dir=$(make_test_dir)
    if "$SCRIPT" "$test_dir" "abc" 5 >/dev/null 2>&1; then
        echo "FAIL [T4]: non-numerical threshould accepted"
        return 1
    fi
    echo "PASS [T4]"
}

# --- T5 ---
# Verify that a non-existent directory argument is rejected
test_nonexistent_dir() {
    if "$SCRIPT" "/nonexistent/path/xyz" 80 5 >/dev/null 2>&1; then
        echo "FAIL [T5]: non-existent dir accepted"
        return 1
    fi
    echo "PASS [T5]"
}

# --- T6 ---
# Verify that a file currently opened by a running process is not archived
test_file_opened_by_process() {
    if ! has_lsof; then
        echo "SKIP [T6]: lsof not installed"
        return 0
    fi
    local test_dir
    test_dir=$(make_test_dir)
    echo "active" > "${test_dir}/active.log"
    touch -t 202001011200 "${test_dir}/active.log"
    clean_backup

    # Open the file with `tail -f` to simulate an active process holding it
    tail -f "${test_dir}/active.log" >/dev/null 2>&1 &
    local tail_pid=$!
    sleep 0.5

    local output
    output=$("$SCRIPT" "$test_dir" 1 1 2>&1) || true

    # Stop the background process
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true

    if grep -q "No files to archive" <<<"$output" || ! grep -q "active.log" <<<"$output"; then
        echo "PASS [T6]"
    else
        echo "FAIL [T6]: active file archived"
        return 1
    fi
}

# --- Run all tests ---
echo "=== start testing archive_files.sh ==="
run_test test_threshold_not_reached
run_test test_threshold_reached_and_archive
run_test test_exclude_mask
run_test test_invalid_args
run_test test_nonexistent_dir
run_test test_file_opened_by_process

echo
echo "=========================================="
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
echo "=========================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1