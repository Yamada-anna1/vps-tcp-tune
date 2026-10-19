#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Only manage the TCP autotuning send-buffer ceiling. No kernel/service changes.
set -Eeuo pipefail

VERSION=1.0.0
KEY=net.ipv4.tcp_wmem
TARGET_MAX=33554432
CONFIG_FILE=/etc/sysctl.d/99-vps-tcp-throughput.conf
STATE_DIR=/var/lib/vps-tcp-tune
LOCK_FILE=/run/lock/vps-tcp-tune.lock
SYSCTL_CONF=/etc/sysctl.conf
SYSCTL_DIRS=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d)
TX_ACTIVE=0
TEMP_FILE=
PREP_DIR=

info() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

normalize_value() {
    local raw=$1 a b c n
    [[ $raw =~ ^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]*$ ]] || return 1
    read -r a b c <<< "$raw"
    for n in "$a" "$b" "$c"; do
        [[ ${#n} -le 10 ]] || return 1
        (( 10#$n > 0 && 10#$n <= 2147483647 )) || return 1
    done
    printf '%d %d %d\n' "$((10#$a))" "$((10#$b))" "$((10#$c))"
}

read_value() {
    local raw
    raw=$(sysctl -n "$KEY") || return 1
    normalize_value "$raw"
}

set_value() {
    sysctl -q -w "$KEY=$1" || return 1
    [[ $(read_value) == "$1" ]]
}

require_environment() {
    [[ $(uname -s) == Linux ]] || die 'This tool requires Linux.'
    (( BASH_VERSINFO[0] >= 4 )) || die 'Bash 4 or newer is required.'
    (( EUID == 0 )) || die 'Run as root (sudo bash vps-tcp-tune.sh ...).'
    local cmd
    for cmd in sysctl flock awk cp mv cmp mkdir mktemp chmod rm rmdir date; do
        command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
    done
}

# Emit line, key, value; never evaluate configuration or backup contents as code.
assignments() {
    awk '
        { sub(/[;#].*$/, ""); p=index($0,"="); if (!p) next;
          k=substr($0,1,p-1); v=substr($0,p+1);
          gsub(/^[ \t]+|[ \t]+$/, "", k); sub(/^-/, "", k);
          gsub(/\//, ".", k); gsub(/^[ \t]+|[ \t]+$/, "", v);
          printf "%d\t%s\t%s\n", NR,k,v }
    ' "$1"
}

check_one_conflict() {
    local file=$1 desired=$2 line key value normalized found=0
    [[ -f $file && -r $file ]] || return 0
    while IFS=$'\t' read -r line key value; do
        # RHS deliberately remains an unquoted glob for sysctl.d wildcard keys.
        # shellcheck disable=SC2053
        if [[ $KEY == $key ]]; then
            normalized=$(normalize_value "$value") || normalized=invalid
            if [[ $normalized != "$desired" ]]; then
                printf 'Conflict: %s:%s sets %s = %s\n' "$file" "$line" "$key" "$value" >&2
                found=1
            fi
        fi
    done < <(assignments "$file")
    return "$found"
}

check_conflicts() {
    local desired=$1 dir file base found=0
    local -A seen=()
    # Directory priority follows systemd/procps. Conservatively reject even an
    # earlier differing declaration, rather than rewrite another package's file.
    for dir in "${SYSCTL_DIRS[@]}"; do
        for file in "$dir"/*.conf; do
            [[ -e $file || -L $file ]] || continue
            base=${file##*/}
            [[ -z ${seen[$base]+x} ]] || continue
            seen[$base]=1
            if [[ $base == "${CONFIG_FILE##*/}" ]]; then
                [[ -e $CONFIG_FILE ]] || die "Creating $CONFIG_FILE would shadow $file; resolve the same-name file first."
                continue
            fi
            check_one_conflict "$file" "$desired" || found=1
        done
    done
    if [[ -f $SYSCTL_CONF && ! $SYSCTL_CONF -ef $CONFIG_FILE ]]; then
        check_one_conflict "$SYSCTL_CONF" "$desired" || found=1
    fi
    (( found == 0 )) || die 'Resolve the listed tcp_wmem declarations first; no other sysctl files were edited.'
}

check_target_file() {
    [[ ! -L $CONFIG_FILE ]] || die "Refusing symlink: $CONFIG_FILE"
    [[ ! -e $CONFIG_FILE || -f $CONFIG_FILE ]] || die "Not a regular file: $CONFIG_FILE"
    [[ -e $CONFIG_FILE ]] || return 0
    awk '
        { sub(/[;#].*$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0=="") next;
          p=index($0,"="); if (!p) exit 1; k=substr($0,1,p-1);
          gsub(/[ \t]/,"",k); sub(/^-/,"",k); gsub(/\//,".",k);
          if (k!="net.ipv4.tcp_wmem") exit 1 }
    ' "$CONFIG_FILE" || die "The target file contains unrelated settings; refusing to replace $CONFIG_FILE"
}

validate_state() {
    local f phase original applied original_file
    [[ -d $STATE_DIR && ! -L $STATE_DIR && -O $STATE_DIR ]] || die "Unsafe state directory: $STATE_DIR"
    for f in original-value applied-value original-file managed.conf phase; do
        [[ -f $STATE_DIR/$f && ! -L $STATE_DIR/$f ]] || die "Missing/unsafe backup: $STATE_DIR/$f"
    done
    original=$(normalize_value "$(<"$STATE_DIR/original-value")") || die 'Invalid original-value backup.'
    applied=$(normalize_value "$(<"$STATE_DIR/applied-value")") || die 'Invalid applied-value backup.'
    phase=$(<"$STATE_DIR/phase")
    [[ $phase == active || $phase == prepared ]] || die 'Invalid backup phase.'
    original_file=$(<"$STATE_DIR/original-file")
    case $original_file in
        present) [[ -f $STATE_DIR/original.conf && ! -L $STATE_DIR/original.conf ]] || die 'Missing original configuration backup.' ;;
        absent) ;;
        *) die 'Invalid original-file backup.' ;;
    esac
    [[ $(assignments "$STATE_DIR/managed.conf" | awk -F '\t' '{print $2 "=" $3}') == "$KEY=$applied" ]] || die 'Invalid managed configuration backup.'
}

install_file() {
    local source=$1 preserve=$2
    TEMP_FILE=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || return 1
    if [[ $preserve == yes ]]; then
        cp -p -- "$source" "$TEMP_FILE" || return 1
    else
        cp -- "$source" "$TEMP_FILE" || return 1
        chmod 644 "$TEMP_FILE" || return 1
    fi
    mv -f -- "$TEMP_FILE" "$CONFIG_FILE" || return 1
    TEMP_FILE=
}

original_file_matches() {
    if [[ $(<"$STATE_DIR/original-file") == present ]]; then
        [[ -f $CONFIG_FILE && ! -L $CONFIG_FILE ]] && cmp -s -- "$CONFIG_FILE" "$STATE_DIR/original.conf"
    else
        [[ ! -e $CONFIG_FILE && ! -L $CONFIG_FILE ]]
    fi
}

restore_snapshot() {
    local original failed=0
    original=$(<"$STATE_DIR/original-value")
    if [[ $(<"$STATE_DIR/original-file") == present ]]; then
        install_file "$STATE_DIR/original.conf" yes || failed=1
    else
        rm -f -- "$CONFIG_FILE" || failed=1
    fi
    if [[ $(read_value) != "$original" ]]; then
        set_value "$original" || failed=1
    fi
    original_file_matches || failed=1
    [[ $(read_value) == "$original" ]] || failed=1
    return "$failed"
}

archive_state() {
    local archive
    archive="${STATE_DIR}.rollback-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    [[ ! -e $archive && ! -L $archive ]] || return 1
    mv -- "$STATE_DIR" "$archive" || return 1
    info "Backup retained: $archive"
}

on_exit() {
    local code=$?
    trap - EXIT
    set +e
    if [[ -n $TEMP_FILE ]]; then
        rm -f -- "$TEMP_FILE"
        TEMP_FILE=
    fi
    if (( TX_ACTIVE )); then
        printf 'Apply did not finish; restoring the saved state...\n' >&2
        if restore_snapshot; then
            archive_state || printf 'Original state restored; backup remains at %s\n' "$STATE_DIR" >&2
        else
            printf 'Automatic restore incomplete. Keep %s and run rollback after resolving the error.\n' "$STATE_DIR" >&2
        fi
        code=1
    fi
    [[ -z $TEMP_FILE ]] || rm -f -- "$TEMP_FILE"
    if [[ -n $PREP_DIR && -d $PREP_DIR && ! -L $PREP_DIR ]]; then
        # This path is created by mktemp; only our fixed backup files exist here.
        rm -f -- "$PREP_DIR/original-value" "$PREP_DIR/applied-value" "$PREP_DIR/original.conf" "$PREP_DIR/original-file" "$PREP_DIR/managed.conf" "$PREP_DIR/phase"
        rmdir -- "$PREP_DIR"
    fi
    exit "$code"
}

apply_tuning() {
    local current a b c desired
    current=$(read_value) || die "Cannot read a valid $KEY."
    if [[ -e $STATE_DIR || -L $STATE_DIR ]]; then
        validate_state
        [[ $(<"$STATE_DIR/phase") == active ]] || die 'An incomplete operation exists. Run rollback first.'
        if [[ -L $CONFIG_FILE || ! -f $CONFIG_FILE ]] || ! cmp -s -- "$CONFIG_FILE" "$STATE_DIR/managed.conf"; then
            die 'Managed file changed; refusing to overwrite it.'
        fi
        [[ $current == "$(<"$STATE_DIR/applied-value")" ]] || die 'Runtime value changed; inspect status before making changes.'
        check_conflicts "$current"
        info "Already applied: $KEY = $current (original backup preserved)."
        return 0
    fi
    read -r a b c <<< "$current"
    (( c >= TARGET_MAX )) || c=$TARGET_MAX
    desired="$a $b $c"
    check_target_file
    check_conflicts "$desired"
    mkdir -p -- "${CONFIG_FILE%/*}" "${STATE_DIR%/*}"
    PREP_DIR=$(mktemp -d "${STATE_DIR}.prepare.XXXXXX")
    printf '%s\n' "$current" > "$PREP_DIR/original-value"
    printf '%s\n' "$desired" > "$PREP_DIR/applied-value"
    if [[ -f $CONFIG_FILE ]]; then
        cp -p -- "$CONFIG_FILE" "$PREP_DIR/original.conf"
        printf 'present\n' > "$PREP_DIR/original-file"
    else
        printf 'absent\n' > "$PREP_DIR/original-file"
    fi
    printf '# Managed by vps-tcp-tune %s; use the rollback command to restore.\n%s = %s\n' "$VERSION" "$KEY" "$desired" > "$PREP_DIR/managed.conf"
    printf 'prepared\n' > "$PREP_DIR/phase"
    mv -- "$PREP_DIR" "$STATE_DIR"
    PREP_DIR=
    TX_ACTIVE=1
    install_file "$STATE_DIR/managed.conf" no
    if [[ $current != "$desired" ]]; then
        set_value "$desired" || die 'sysctl write or read-back failed.'
    fi
    [[ $(read_value) == "$desired" ]] || die 'Runtime verification failed.'
    printf 'active\n' > "$STATE_DIR/phase.new"
    mv -f -- "$STATE_DIR/phase.new" "$STATE_DIR/phase"
    TX_ACTIVE=0
    info "Applied: $KEY = $desired"
    info "Startup configuration: $CONFIG_FILE"
    info "Original state saved: $STATE_DIR"
    info 'No reboot or proxy restart is needed. Throughput improvement depends on the actual bottleneck.'
}

rollback_tuning() {
    local current original applied
    if [[ ! -e $STATE_DIR && ! -L $STATE_DIR ]]; then
        info 'No active installation to roll back.'
        return 0
    fi
    validate_state
    current=$(read_value) || die 'Cannot read current runtime value.'
    original=$(<"$STATE_DIR/original-value")
    applied=$(<"$STATE_DIR/applied-value")
    [[ $current == "$original" || $current == "$applied" ]] || die 'Runtime value changed after installation; refusing to overwrite it.'
    if ! original_file_matches; then
        if [[ -L $CONFIG_FILE || ! -f $CONFIG_FILE ]] || ! cmp -s -- "$CONFIG_FILE" "$STATE_DIR/managed.conf"; then
            die 'Configuration changed after installation; refusing to overwrite it.'
        fi
    fi
    restore_snapshot || die "Rollback incomplete; backup preserved at $STATE_DIR."
    archive_state || die 'Original state restored, but the backup could not be archived.'
    info "Restored: $KEY = $original"
}

show_status() {
    local current
    current=$(read_value) || die "Cannot read a valid $KEY."
    info "Current: $KEY = $current"
    if [[ -e $STATE_DIR || -L $STATE_DIR ]]; then
        validate_state
        info "Installation: $(<"$STATE_DIR/phase")"
        info "Original: $(<"$STATE_DIR/original-value")"
        info "Applied: $(<"$STATE_DIR/applied-value")"
        if [[ ! -L $CONFIG_FILE && -f $CONFIG_FILE ]] && cmp -s -- "$CONFIG_FILE" "$STATE_DIR/managed.conf"; then
            info 'Managed file: matches saved version'
        else
            info 'Managed file: missing or modified'
        fi
    else
        info 'Installation: no backup managed by this tool'
    fi
}

usage() {
    printf 'vps-tcp-tune %s\nUsage: sudo bash vps-tcp-tune.sh {apply|status|rollback|help}\n' "$VERSION"
}

main() {
    (( $# <= 1 )) || die 'Expected one command. Use help.'
    local action=${1:-help}
    case $action in help|--help|-h) usage; return 0 ;; apply|status|rollback) ;; *) die "Unknown command: $action" ;; esac
    require_environment
    umask 077
    [[ ! -L $LOCK_FILE && ( ! -e $LOCK_FILE || -f $LOCK_FILE ) ]] || die "Unsafe lock path: $LOCK_FILE"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die 'Another vps-tcp-tune operation is running.'
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case $action in apply) apply_tuning ;; status) show_status ;; rollback) rollback_tuning ;; esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
