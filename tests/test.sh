#!/usr/bin/env bash
# Tests run only against temporary files and a simulated sysctl implementation.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$(cd -- "$TEST_DIR/.." && pwd)/vps-tcp-tune.sh

# A separate Bash process is important: invoking main in an if/! condition would
# disable errexit inside functions and give misleading transaction test results.
if [[ ${1:-} == __run ]]; then
    fixture=$2
    shift 2
    # shellcheck source=../vps-tcp-tune.sh
    source "$SCRIPT"
    CONFIG_FILE=$fixture/etc/sysctl.d/99-vps-tcp-throughput.conf
    STATE_DIR=$fixture/var/lib/vps-tcp-tune
    LOCK_FILE=$fixture/run/lock/vps-tcp-tune.lock
    SYSCTL_CONF=$fixture/etc/sysctl.conf
    SYSCTL_DIRS=("$fixture/etc/sysctl.d" "$fixture/run/sysctl.d" "$fixture/usr/local/lib/sysctl.d" "$fixture/usr/lib/sysctl.d" "$fixture/lib/sysctl.d")
    require_environment() { :; }
    flock() {
        if [[ -e $fixture/real-lock ]]; then
            command flock "$@"
        else
            :
        fi
    }
    sysctl() {
        if [[ $# == 2 && $1 == -n && $2 == net.ipv4.tcp_wmem ]]; then
            if [[ -e $fixture/fail-next-read ]]; then
                rm -- "$fixture/fail-next-read"
                printf 'invalid read-back\n'
                return 0
            fi
            cat -- "$fixture/runtime"
        elif [[ $# == 3 && $1 == -q && $2 == -w && $3 == net.ipv4.tcp_wmem=* ]]; then
            printf '%s\n' "$3" >> "$fixture/writes"
            if [[ -e $fixture/fail-write-once ]]; then
                rm -- "$fixture/fail-write-once"
                return 23
            fi
            printf '%s\n' "${3#*=}" > "$fixture/runtime"
            if [[ -e $fixture/fail-readback-once ]]; then
                mv -- "$fixture/fail-readback-once" "$fixture/fail-next-read"
            fi
        else
            printf 'Unexpected simulated sysctl arguments\n' >&2
            return 99
        fi
    }
    mv() {
        local destination=${!#}
        if [[ $destination == "$CONFIG_FILE" && -e $fixture/fail-install-once ]]; then
            rm -- "$fixture/fail-install-once"
            return 24
        fi
        if [[ $destination == "$STATE_DIR/managed.conf" && -e $fixture/fail-update-metadata-once ]]; then
            rm -- "$fixture/fail-update-metadata-once"
            return 26
        fi
        if [[ $destination == "$STATE_DIR/applied-value" && -e $fixture/crash-update-once ]]; then
            command mv "$@"
            rm -- "$fixture/crash-update-once"
            kill -KILL "$$"
        fi
        command mv "$@"
    }
    cp() {
        local destination=${!#}
        if [[ $destination == "$STATE_DIR".prepare.*/original.conf && -e $fixture/fail-backup-once ]]; then
            printf '# Simulated partial backup\n' > "$destination"
            rm -- "$fixture/fail-backup-once"
            return 25
        fi
        command cp "$@"
    }
    main "$@"
    exit
fi

TEMP_PARENT=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
ROOT=$(mktemp -d "$TEMP_PARENT/vps-tcp-tune-tests.XXXXXX")
cleanup() {
    local resolved
    [[ -d $ROOT && ! -L $ROOT ]] || return 0
    resolved=$(cd -- "$ROOT" && pwd -P) || return 1
    if [[ ${resolved%/*} == "$TEMP_PARENT" && ${resolved##*/} == vps-tcp-tune-tests.* ]]; then
        rm -rf -- "$resolved"
    else
        printf 'Refusing cleanup outside test temporary parent: %s\n' "$resolved" >&2
        return 1
    fi
}
trap cleanup EXIT
CASE=
CONFIG=
STATE=
RESULT=0
PASSED=0
SKIPPED=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    if [[ -n $CASE && -f $CASE/command.log ]]; then
        cat -- "$CASE/command.log" >&2
    fi
    exit 1
}

new_case() {
    CASE=$ROOT/$1
    mkdir -p -- "$CASE/etc/sysctl.d" "$CASE/run/sysctl.d" "$CASE/run/lock" \
        "$CASE/usr/local/lib/sysctl.d" "$CASE/usr/lib/sysctl.d" "$CASE/lib/sysctl.d" "$CASE/var/lib"
    CONFIG=$CASE/etc/sysctl.d/99-vps-tcp-throughput.conf
    STATE=$CASE/var/lib/vps-tcp-tune
    printf '%s\n' "${2:-4096 16384 4194304}" > "$CASE/runtime"
    : > "$CASE/writes"
}

run_command() {
    set +e
    bash "$TEST_DIR/test.sh" __run "$CASE" "$@" > "$CASE/command.log" 2>&1
    RESULT=$?
    set -e
}

run_ok() {
    run_command "$@"
    (( RESULT == 0 )) || fail "$1 exited $RESULT"
}

run_fail() {
    run_command "$@"
    (( RESULT != 0 )) || fail "$1 unexpectedly succeeded"
}

assert_eq() { [[ $1 == "$2" ]] || fail "${3:-Values differ}: expected [$2], got [$1]"; }
assert_absent() { [[ ! -e $1 && ! -L $1 ]] || fail "Unexpected path: $1"; }
assert_file() { [[ -f $1 ]] || fail "Missing file: $1"; }
assert_same() { cmp -s -- "$1" "$2" || fail "Files differ: $1 and $2"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "Missing text [$2] in $1"; }
assert_archived() {
    local archives=("$STATE".rollback-*)
    [[ -d ${archives[0]} ]] || fail 'Rollback backup was not retained'
    assert_absent "$STATE"
}

test_raise_4m_preserves_first_values() {
    new_case raise '8192 32768 4194304'
    run_ok apply
    assert_eq "$(<"$CASE/runtime")" '8192 32768 33554432'
    assert_eq "$(<"$STATE/original-value")" '8192 32768 4194304'
    assert_contains "$CONFIG" 'net.ipv4.tcp_wmem = 8192 32768 33554432'
    assert_eq "$(<"$STATE/phase")" active
    run_ok status
    assert_contains "$CASE/command.log" 'Managed file: matches saved version'
}

test_existing_32m_has_no_sysctl_write() {
    new_case existing32 '8192 32768 33554432'
    run_ok apply
    assert_eq "$(<"$CASE/runtime")" '8192 32768 33554432'
    assert_eq "$(<"$CASE/writes")" ''
    run_ok rollback
    assert_eq "$(<"$CASE/runtime")" '8192 32768 33554432'
}

test_existing_64m_is_not_reduced() {
    new_case existing64 '8192 32768 67108864'
    run_ok apply
    assert_eq "$(<"$CASE/runtime")" '8192 32768 67108864'
    assert_eq "$(<"$CASE/writes")" ''
    assert_contains "$CONFIG" 'net.ipv4.tcp_wmem = 8192 32768 67108864'
}

test_idempotent_original_backup() {
    new_case idempotent
    printf '# Original custom comment\nnet.ipv4.tcp_wmem = 4096 16384 4194304\n' > "$CONFIG"
    cp -- "$CONFIG" "$CASE/original.expected"
    run_ok apply
    run_ok apply
    assert_eq "$(<"$STATE/original-value")" '4096 16384 4194304'
    assert_same "$STATE/original.conf" "$CASE/original.expected"
    assert_eq "$(wc -l < "$CASE/writes" | tr -d '[:space:]')" 1
    assert_contains "$CASE/command.log" 'Already applied:'
}

test_rollback_originally_absent() {
    new_case rollback_absent
    run_ok apply
    run_ok rollback
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_absent "$CONFIG"
    assert_archived
    run_ok rollback
    assert_contains "$CASE/command.log" 'No active installation'
}

test_rollback_existing_file_byte_exact() {
    local original_mode
    new_case rollback_present
    printf '# Keep spacing and comments\n net/ipv4/tcp_wmem = 4096 16384 4194304 # old\n\n' > "$CONFIG"
    chmod 600 "$CONFIG"
    original_mode=$(stat -c '%a' "$CONFIG")
    cp -p -- "$CONFIG" "$CASE/original.expected"
    run_ok apply
    run_ok rollback
    assert_same "$CONFIG" "$CASE/original.expected"
    assert_eq "$(stat -c '%a' "$CONFIG")" "$original_mode" 'Original file permissions not restored'
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_archived
}

test_runtime_modification_is_protected() {
    new_case runtime_modified
    run_ok apply
    printf '4096 16384 67108864\n' > "$CASE/runtime"
    run_fail apply
    run_fail rollback
    assert_eq "$(<"$CASE/runtime")" '4096 16384 67108864'
    assert_file "$STATE/original-value"
}

test_config_modification_is_protected() {
    new_case config_modified
    run_ok apply
    printf '# Administrator edit\n' >> "$CONFIG"
    cp -- "$CONFIG" "$CASE/modified.expected"
    run_fail apply
    run_fail rollback
    assert_same "$CONFIG" "$CASE/modified.expected"
    assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
    assert_file "$STATE/original-value"
}

test_conflicts_dot_slash_glob() {
    local key tag
    for tag in dotted slash glob; do
        case $tag in
            dotted) key=net.ipv4.tcp_wmem ;;
            slash) key=net/ipv4/tcp_wmem ;;
            glob) key='net.ipv4.tcp_*' ;;
        esac
        new_case "conflict_$tag"
        printf '%s = 4096 16384 4194304\n' "$key" > "$CASE/etc/sysctl.d/10-other.conf"
        run_fail apply
        assert_contains "$CASE/command.log" 'Conflict:'
        assert_absent "$CONFIG"
        assert_absent "$STATE"
        assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    done
}

test_etc_sysctl_conf_conflict() {
    new_case etc_conflict
    printf 'net.ipv4.tcp_wmem = 4096 16384 4194304\n' > "$CASE/etc/sysctl.conf"
    run_fail apply
    assert_contains "$CASE/command.log" 'Conflict:'
    assert_absent "$STATE"
}

test_same_value_declaration_allowed() {
    new_case same_value
    printf 'net.ipv4.tcp_wmem = 4096 16384 33554432\n' > "$CASE/etc/sysctl.d/10-other.conf"
    run_ok apply
    assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
}

test_same_filename_respects_directory_priority() {
    new_case shadowing
    printf '# Higher-priority file masks vendor defaults\n' > "$CASE/etc/sysctl.d/50-vendor.conf"
    printf 'net.ipv4.tcp_wmem = 4096 16384 4194304\n' > "$CASE/usr/lib/sysctl.d/50-vendor.conf"
    run_ok apply
    assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
}

test_managed_filename_shadowing_is_rejected() {
    new_case managed_shadow
    printf 'net.ipv4.tcp_wmem = 4096 16384 4194304\n' > "$CASE/usr/lib/sysctl.d/99-vps-tcp-throughput.conf"
    run_fail apply
    assert_contains "$CASE/command.log" 'would shadow'
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_absent "$CONFIG"
    assert_absent "$STATE"
}

test_target_unrelated_key_is_not_overwritten() {
    new_case unrelated
    printf 'net.ipv4.tcp_wmem = 4096 16384 4194304\nnet.ipv4.ip_forward = 1\n' > "$CONFIG"
    cp -- "$CONFIG" "$CASE/original.expected"
    run_fail apply
    assert_same "$CONFIG" "$CASE/original.expected"
    assert_absent "$STATE"
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
}

can_create_symlink() {
    local result
    set +e
    MSYS=winsymlinks:nativestrict ln -s -- "$CASE/runtime" "$CASE/link-probe" 2>/dev/null
    result=$?
    set -e
    [[ $result == 0 && -L $CASE/link-probe ]]
}

test_symlinks_are_rejected() {
    new_case symlinks
    if ! can_create_symlink; then
        printf 'SKIP: native symlinks unavailable on this host (covered on Linux CI)\n'
        SKIPPED=$((SKIPPED + 1))
        return
    fi
    MSYS=winsymlinks:nativestrict ln -s -- "$CASE/runtime" "$CONFIG"
    run_fail apply
    assert_absent "$STATE"
    rm -- "$CONFIG"
    rm -f -- "$CASE/run/lock/vps-tcp-tune.lock"
    MSYS=winsymlinks:nativestrict ln -s -- "$CASE/runtime" "$CASE/run/lock/vps-tcp-tune.lock"
    run_fail apply
    rm -- "$CASE/run/lock/vps-tcp-tune.lock"
    mkdir -- "$CASE/state-target"
    MSYS=winsymlinks:nativestrict ln -s -- "$CASE/state-target" "$STATE"
    run_fail apply
    rm -- "$STATE"
    run_ok apply
    cp -- "$STATE/original-value" "$CASE/value-target"
    rm -- "$STATE/original-value"
    MSYS=winsymlinks:nativestrict ln -s -- "$CASE/value-target" "$STATE/original-value"
    run_fail rollback
    assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
}

test_corrupt_backup_is_data_not_code() {
    new_case corrupt_backup
    run_ok apply
    # shellcheck disable=SC2016
    printf '$(touch "%s")\n' "$CASE/EXECUTED" > "$STATE/original-value"
    run_fail rollback
    assert_contains "$CASE/command.log" 'Invalid original-value'
    assert_absent "$CASE/EXECUTED"
    assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
}

test_corrupt_managed_backup_is_rejected() {
    new_case corrupt_managed
    run_ok apply
    printf 'net.ipv4.ip_forward = 1\n' >> "$STATE/managed.conf"
    run_fail rollback
    assert_contains "$CASE/command.log" 'Invalid managed configuration backup'
    assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
}

test_sysctl_write_failure_restores_original() {
    new_case write_failure
    printf '# Existing original\nnet.ipv4.tcp_wmem = 4096 16384 4194304\n' > "$CONFIG"
    cp -- "$CONFIG" "$CASE/original.expected"
    : > "$CASE/fail-write-once"
    run_fail apply
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_same "$CONFIG" "$CASE/original.expected"
    assert_archived
}

test_readback_failure_restores_runtime_and_file() {
    new_case readback_failure
    : > "$CASE/fail-readback-once"
    run_fail apply
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_absent "$CONFIG"
    assert_archived
    assert_eq "$(wc -l < "$CASE/writes" | tr -d '[:space:]')" 2
}

test_config_install_failure_restores_original() {
    new_case install_failure
    printf '# Existing original\nnet.ipv4.tcp_wmem = 4096 16384 4194304\n' > "$CONFIG"
    cp -- "$CONFIG" "$CASE/original.expected"
    : > "$CASE/fail-install-once"
    run_fail apply
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_same "$CONFIG" "$CASE/original.expected"
    assert_archived
    local files=("$CONFIG".tmp.*)
    assert_absent "${files[0]}"
}

test_backup_failure_cleans_preparation() {
    local directories
    new_case backup_failure
    printf '# Original before preparation\nnet.ipv4.tcp_wmem = 4096 16384 4194304\n' > "$CONFIG"
    cp -- "$CONFIG" "$CASE/original.expected"
    : > "$CASE/fail-backup-once"
    run_fail apply
    assert_same "$CONFIG" "$CASE/original.expected"
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_eq "$(<"$CASE/writes")" ''
    assert_absent "$STATE"
    directories=("$STATE".prepare.*)
    assert_absent "${directories[0]}"
    run_ok apply
    assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
}

test_status_read_failure_is_reported() {
    new_case status_read_failure
    : > "$CASE/fail-next-read"
    run_fail status
    assert_contains "$CASE/command.log" 'Cannot read a valid'
    assert_absent "$STATE"
    assert_eq "$(<"$CASE/writes")" ''
}

test_native_flock_prevents_concurrent_apply() {
    new_case native_lock
    if ! command -v flock >/dev/null 2>&1; then
        printf 'SKIP: native flock unavailable on this host (covered on Linux CI)\n'
        SKIPPED=$((SKIPPED + 1))
        return
    fi
    : > "$CASE/real-lock"
    exec 8>"$CASE/run/lock/vps-tcp-tune.lock"
    flock -n 8
    run_fail apply
    assert_contains "$CASE/command.log" 'Another vps-tcp-tune operation'
    assert_absent "$STATE"
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    exec 8>&-
    run_ok apply
}

test_prepared_transaction_is_recoverable() {
    new_case prepared_applied
    run_ok apply
    printf 'prepared\n' > "$STATE/phase"
    run_fail apply
    assert_contains "$CASE/command.log" 'incomplete operation'
    run_ok rollback
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_absent "$CONFIG"
    assert_archived
}

test_prepared_untouched_state_is_recoverable() {
    new_case prepared_untouched
    run_ok apply
    printf 'prepared\n' > "$STATE/phase"
    rm -- "$CONFIG"
    printf '4096 16384 4194304\n' > "$CASE/runtime"
    run_ok rollback
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_absent "$CONFIG"
    assert_archived
}

test_explicit_32_profile() {
    new_case profile32 '4096 65536 4194304'
    run_ok apply 32
    assert_eq "$(<"$CASE/runtime")" '4096 65536 33554432'
}

test_fresh_64_profile_and_rollback() {
    new_case profile64 '4096 65536 4194304'
    run_ok apply 64
    assert_eq "$(<"$CASE/runtime")" '4096 65536 67108864'
    assert_contains "$CONFIG" 'net.ipv4.tcp_wmem = 4096 65536 67108864'
    run_ok apply 64
    assert_eq "$(wc -l < "$CASE/writes" | tr -d '[:space:]')" 1
    run_ok rollback
    assert_eq "$(<"$CASE/runtime")" '4096 65536 4194304'
    assert_absent "$CONFIG"
}

test_64_profile_keeps_existing_128m() {
    new_case keep128 '4096 65536 134217728'
    run_ok apply 64
    assert_eq "$(<"$CASE/runtime")" '4096 65536 134217728'
    assert_eq "$(<"$CASE/writes")" ''
}

test_upgrade_preserves_first_backup_and_file() {
    new_case upgrade '4096 65536 4194304'
    printf '# Original before any install\nnet.ipv4.tcp_wmem = 4096 65536 4194304\n' > "$CONFIG"
    cp -p -- "$CONFIG" "$CASE/original.expected"
    run_ok apply 32
    run_ok apply 64
    assert_eq "$(<"$CASE/runtime")" '4096 65536 67108864'
    assert_eq "$(<"$STATE/applied-value")" '4096 65536 67108864'
    assert_eq "$(<"$STATE/original-value")" '4096 65536 4194304'
    assert_same "$STATE/original.conf" "$CASE/original.expected"
    assert_same "$CONFIG" "$STATE/managed.conf"
    assert_absent "$STATE/update"
    run_ok apply 32
    assert_eq "$(<"$CASE/runtime")" '4096 65536 67108864'
    run_ok apply 64
    assert_eq "$(wc -l < "$CASE/writes" | tr -d '[:space:]')" 2
    run_ok rollback
    assert_eq "$(<"$CASE/runtime")" '4096 65536 4194304'
    assert_same "$CONFIG" "$CASE/original.expected"
    assert_archived
}

test_upgrade_from_v1_0_state() {
    new_case legacy '4096 16384 33554432'
    mkdir -- "$STATE"
    printf '4096 16384 4194304\n' > "$STATE/original-value"
    printf '4096 16384 33554432\n' > "$STATE/applied-value"
    printf 'absent\n' > "$STATE/original-file"
    printf 'active\n' > "$STATE/phase"
    printf '# Managed by vps-tcp-tune 1.0.0; use the rollback command to restore.\nnet.ipv4.tcp_wmem = 4096 16384 33554432\n' > "$STATE/managed.conf"
    cp -- "$STATE/managed.conf" "$CONFIG"
    run_ok apply 64
    assert_eq "$(<"$CASE/runtime")" '4096 16384 67108864'
    assert_eq "$(<"$STATE/original-value")" '4096 16384 4194304'
    run_ok rollback
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_absent "$CONFIG"
}

test_upgrade_failures_restore_previous_working_profile() {
    local marker
    for marker in fail-write-once fail-readback-once fail-install-once fail-backup-once fail-update-metadata-once; do
        new_case "upgrade_$marker"
        run_ok apply 32
        cp -- "$CONFIG" "$CASE/previous.expected"
        : > "$CASE/$marker"
        run_fail apply 64
        assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
        assert_eq "$(<"$STATE/applied-value")" '4096 16384 33554432'
        assert_eq "$(<"$STATE/original-value")" '4096 16384 4194304'
        assert_same "$CONFIG" "$CASE/previous.expected"
        assert_same "$CONFIG" "$STATE/managed.conf"
        assert_absent "$STATE/update"
        run_ok status
        run_ok apply 64
        assert_eq "$(<"$CASE/runtime")" '4096 16384 67108864'
        run_ok rollback
        assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
        assert_absent "$CONFIG"
    done
}

test_interrupted_upgrade_recovers_without_losing_first_backup() {
    new_case interrupted_upgrade
    run_ok apply 32
    : > "$CASE/crash-update-once"
    run_fail apply 64
    assert_file "$STATE/update/original-value"
    assert_eq "$(<"$CASE/runtime")" '4096 16384 67108864'
    run_fail status
    assert_contains "$CASE/command.log" 'interrupted update'
    assert_eq "$(<"$CASE/runtime")" '4096 16384 67108864'
    run_ok apply 32
    assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
    assert_eq "$(<"$STATE/original-value")" '4096 16384 4194304'
    assert_absent "$STATE/update"
    run_ok apply 64
    run_ok rollback
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
}

test_interrupted_upgrade_rollback_and_modification_guard() {
    new_case interrupted_changed
    run_ok apply 32
    : > "$CASE/crash-update-once"
    run_fail apply 64
    printf '4096 16384 134217728\n' > "$CASE/runtime"
    run_fail apply 64
    run_fail rollback
    assert_eq "$(<"$CASE/runtime")" '4096 16384 134217728'
    assert_file "$STATE/update/original-value"
    printf '4096 16384 67108864\n' > "$CASE/runtime"
    run_ok rollback
    assert_eq "$(<"$CASE/runtime")" '4096 16384 4194304'
    assert_absent "$CONFIG"
}

test_upgrade_conflict_keeps_previous_state() {
    new_case upgrade_conflict
    run_ok apply 32
    printf 'net.ipv4.tcp_wmem = 4096 16384 33554432\n' > "$CASE/etc/sysctl.d/10-other.conf"
    run_fail apply 64
    assert_contains "$CASE/command.log" 'Conflict:'
    assert_eq "$(<"$CASE/runtime")" '4096 16384 33554432'
    assert_eq "$(<"$STATE/applied-value")" '4096 16384 33554432'
    assert_absent "$STATE/update"
}

test_upgrade_respects_administrator_changes() {
    new_case upgrade_admin
    run_ok apply 32
    cp -- "$CONFIG" "$CASE/previous.expected"
    printf '# Administrator edit\n' >> "$CONFIG"
    run_fail apply 64
    assert_contains "$CONFIG" 'Administrator edit'
    cp -- "$CASE/previous.expected" "$CONFIG"
    printf '4096 16384 134217728\n' > "$CASE/runtime"
    run_fail apply 64
    assert_eq "$(<"$CASE/runtime")" '4096 16384 134217728'
    assert_absent "$STATE/update"
}

test_invalid_profiles_do_not_modify_state() {
    local profile
    new_case bad_arguments
    for profile in '' 0 16 128 64MiB; do
        run_fail apply "$profile"
    done
    run_fail apply 32 64
    run_fail status 64
    run_fail rollback 64
    assert_absent "$STATE"
    assert_absent "$CONFIG"
    assert_eq "$(<"$CASE/writes")" ''
}

tests=(
    test_raise_4m_preserves_first_values
    test_existing_32m_has_no_sysctl_write
    test_existing_64m_is_not_reduced
    test_idempotent_original_backup
    test_rollback_originally_absent
    test_rollback_existing_file_byte_exact
    test_runtime_modification_is_protected
    test_config_modification_is_protected
    test_conflicts_dot_slash_glob
    test_etc_sysctl_conf_conflict
    test_same_value_declaration_allowed
    test_same_filename_respects_directory_priority
    test_managed_filename_shadowing_is_rejected
    test_target_unrelated_key_is_not_overwritten
    test_symlinks_are_rejected
    test_corrupt_backup_is_data_not_code
    test_corrupt_managed_backup_is_rejected
    test_sysctl_write_failure_restores_original
    test_readback_failure_restores_runtime_and_file
    test_config_install_failure_restores_original
    test_backup_failure_cleans_preparation
    test_status_read_failure_is_reported
    test_native_flock_prevents_concurrent_apply
    test_prepared_transaction_is_recoverable
    test_prepared_untouched_state_is_recoverable
    test_explicit_32_profile
    test_fresh_64_profile_and_rollback
    test_64_profile_keeps_existing_128m
    test_upgrade_preserves_first_backup_and_file
    test_upgrade_from_v1_0_state
    test_upgrade_failures_restore_previous_working_profile
    test_interrupted_upgrade_recovers_without_losing_first_backup
    test_interrupted_upgrade_rollback_and_modification_guard
    test_upgrade_conflict_keeps_previous_state
    test_upgrade_respects_administrator_changes
    test_invalid_profiles_do_not_modify_state
)

for test_function in "${tests[@]}"; do
    skipped_before=$SKIPPED
    "$test_function"
    if (( SKIPPED == skipped_before )); then
        PASSED=$((PASSED + 1))
        printf 'PASS: %s\n' "$test_function"
    fi
done
printf '\n%d passed, %d skipped. No real sysctl calls or server connections.\n' "$PASSED" "$SKIPPED"
