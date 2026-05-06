#!/bin/bash

set -u

VPN_NAME="${1:-}"
MODE="${2:-}"

VPN_CMD="${VPN_CMD:-/opt/homebrew/bin/vpnutil}"
VPN_INTERFACE="${VPN_INTERFACE:-ipsec0}"
IFCONFIG_CMD="${IFCONFIG_CMD:-/sbin/ifconfig}"
NETSTAT_CMD="${NETSTAT_CMD:-/usr/sbin/netstat}"
SCUTIL_CMD="${SCUTIL_CMD:-/usr/sbin/scutil}"
WATCH_HOST="${WATCH_HOST:-}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-5}"
START_COOLDOWN_SECONDS="${START_COOLDOWN_SECONDS:-45}"
VPN_WATCHDOG_ONCE="${VPN_WATCHDOG_ONCE:-false}"
VPN_WATCHDOG_LOG_INFO="${VPN_WATCHDOG_LOG_INFO:-false}"
CURRENT_TIME_HHMM="${CURRENT_TIME_HHMM:-}"
WORK_START="${WORK_START:-0830}"
WORK_END="${WORK_END:-1900}"
STATE_ID="${STATE_ID:-vpnwatchdog}"
LAST_START_FILE="${LAST_START_FILE:-/tmp/${STATE_ID}.last_start}"
LOCK_DIR="${LOCK_DIR:-/tmp/${STATE_ID}.lock}"
STATUS_FILE="${STATUS_FILE:-/tmp/${STATE_ID}.status}"
ROUTE_DESTINATIONS_TEXT="${ROUTE_DESTINATIONS_TEXT:-}"
ROUTE_DESTINATIONS=()

log_line() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$VPN_NAME" "$*"
}

log_info() {
    if [ "$VPN_WATCHDOG_LOG_INFO" = "true" ]; then
        log_line "$*"
    fi
}

log_error() {
    log_line "$*" >&2
}

log_state() {
    local state="$1"
    local message="$2"
    local previous_state=""

    if [ -r "$STATUS_FILE" ]; then
        previous_state="$(/bin/cat "$STATUS_FILE" 2>/dev/null || true)"
    fi

    if [ "$previous_state" != "$state" ]; then
        log_info "$message"
        echo "$state" > "$STATUS_FILE" 2>/dev/null || true
    fi
}

usage() {
    cat >&2 <<EOF
Usage: $0 <VPN_NAME> <duringWorkingHoursOnly|runAlways>

Environment:
  VPN_CMD                  Path to vpnutil. Default: /opt/homebrew/bin/vpnutil
  VPN_INTERFACE            Interface that represents the VPN. Default: ipsec0
  ROUTE_DESTINATIONS_TEXT  Optional space-separated routes that must use VPN_INTERFACE.
  WATCH_HOST               Optional host for scutil reachability wakeups.
  WORK_START               Working window start in HHMM. Default: 0830
  WORK_END                 Working window end in HHMM. Default: 1900
EOF
}

validate_config() {
    if [ -z "$VPN_NAME" ] || [ -z "$MODE" ]; then
        usage
        exit 1
    fi

    if [ "$MODE" != "duringWorkingHoursOnly" ] && [ "$MODE" != "runAlways" ]; then
        log_error "Invalid mode: $MODE"
        usage
        exit 1
    fi

    if [ ! -x "$VPN_CMD" ]; then
        log_error "VPN command is not executable: $VPN_CMD"
        exit 1
    fi

    if [ -z "$VPN_INTERFACE" ]; then
        log_error "VPN_INTERFACE must not be empty"
        exit 1
    fi
}

configure_route_destinations() {
    ROUTE_DESTINATIONS=()

    if [ -n "$ROUTE_DESTINATIONS_TEXT" ]; then
        ROUTE_DESTINATIONS=($ROUTE_DESTINATIONS_TEXT)
    fi
}

within_run_window() {
    local current_time

    if [ "$MODE" = "runAlways" ]; then
        return 0
    fi

    if [ -n "$CURRENT_TIME_HHMM" ]; then
        current_time="$CURRENT_TIME_HHMM"
    else
        current_time="$(date +%H%M)"
    fi

    ((10#$current_time >= 10#$WORK_START && 10#$current_time <= 10#$WORK_END))
}

vpn_interface_has_ipv4() {
    "$IFCONFIG_CMD" "$VPN_INTERFACE" 2>/dev/null | /usr/bin/grep -Eq '^[[:space:]]*inet[[:space:]]+[0-9]'
}

route_is_present() {
    local destination="$1"

    "$NETSTAT_CMD" -rn -f inet 2>/dev/null | /usr/bin/awk -v dest="$destination" -v iface="$VPN_INTERFACE" '
        $1 == dest && $NF == iface { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

routes_present() {
    local destination

    if [ "${#ROUTE_DESTINATIONS[@]}" -eq 0 ]; then
        return 0
    fi

    for destination in "${ROUTE_DESTINATIONS[@]}"; do
        if ! route_is_present "$destination"; then
            return 1
        fi
    done

    return 0
}

vpn_is_connected() {
    vpn_interface_has_ipv4 && routes_present
}

last_start_epoch() {
    local value

    if [ -r "$LAST_START_FILE" ]; then
        value="$(/bin/cat "$LAST_START_FILE" 2>/dev/null || true)"
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo 0
}

cooldown_remaining() {
    local now
    local last_start
    local elapsed

    now="$(date +%s)"
    last_start="$(last_start_epoch)"
    elapsed=$((now - last_start))

    if [ "$elapsed" -lt "$START_COOLDOWN_SECONDS" ]; then
        echo $((START_COOLDOWN_SECONDS - elapsed))
    else
        echo 0
    fi
}

mark_start_attempt() {
    date +%s > "$LAST_START_FILE" 2>/dev/null || log_error "Could not write cooldown file: $LAST_START_FILE"
}

start_vpn() {
    local remaining
    local output
    local exit_code

    remaining="$(cooldown_remaining)"
    if [ "$remaining" -gt 0 ]; then
        log_info "VPN disconnected; start skipped because cooldown has ${remaining}s remaining"
        return 0
    fi

    mark_start_attempt
    log_info "VPN disconnected; starting with: $VPN_CMD start $VPN_NAME"

    output="$("$VPN_CMD" start "$VPN_NAME" 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        log_error "Start command failed with exit code $exit_code"
        if [ -n "$output" ]; then
            log_error "Start command output: $output"
        fi
    elif [ -n "$output" ]; then
        log_info "Start command output: $output"
    fi

    return "$exit_code"
}

check_once() {
    if ! within_run_window; then
        log_state "outside-window" "Outside working hours; reconnect skipped"
        return 0
    fi

    if vpn_is_connected; then
        log_state "connected" "VPN connected; $VPN_INTERFACE is up and configured route checks passed"
        return 0
    fi

    log_state "disconnected" "VPN disconnected; $VPN_INTERFACE is down or configured route checks failed"
    start_vpn
}

cleanup() {
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock() {
    local existing_pid

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        trap cleanup EXIT INT TERM
        return 0
    fi

    existing_pid=""
    if [ -r "$LOCK_DIR/pid" ]; then
        existing_pid="$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    fi

    if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
        log_info "Another watchdog instance is already running"
        exit 0
    fi

    log_info "Removing stale watchdog lock"
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log_error "Could not acquire watchdog lock: $LOCK_DIR"
        exit 1
    fi

    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    trap cleanup EXIT INT TERM
}

watch_reachability() {
    while true; do
        log_info "Watching reachability for $WATCH_HOST"
        "$SCUTIL_CMD" -r -W "$WATCH_HOST" 2>&1 | while IFS= read -r event; do
            [ -n "$event" ] && log_info "Reachability event: $event"
            check_once
        done

        log_error "Reachability watcher exited; restarting in ${CHECK_INTERVAL_SECONDS}s"
        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

poll_fallback() {
    while true; do
        check_once
        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

main() {
    local check_status
    local watch_host_label

    validate_config
    configure_route_destinations
    acquire_lock

    watch_host_label="${WATCH_HOST:-disabled}"
    log_info "Starting persistent watchdog: mode=$MODE interface=$VPN_INTERFACE routes=${#ROUTE_DESTINATIONS[@]} watch_host=$watch_host_label interval=${CHECK_INTERVAL_SECONDS}s cooldown=${START_COOLDOWN_SECONDS}s"
    check_once
    check_status=$?

    if [ "$VPN_WATCHDOG_ONCE" = "true" ]; then
        log_info "One-shot mode finished"
        exit "$check_status"
    fi

    if [ -n "$WATCH_HOST" ]; then
        watch_reachability &
    fi

    poll_fallback &

    wait
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
