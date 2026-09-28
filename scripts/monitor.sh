#!/usr/bin/env bash
# monitor.sh — service status and syslog error summary.
#
# Usage: monitor.sh <service>
#
# Exit codes:
#   0  service is active
#   1  service is not active (last journal lines are printed)
#   2  usage error
#   3  unit not found
#   4  systemd tools are missing
set -euo pipefail

readonly SYSLOG_FILES=(/var/log/syslog.1 /var/log/syslog)
readonly ERROR_PATTERN='\b(error|failed|failure|critical)\b'
readonly JOURNAL_LINES=10

if [[ -t 1 ]]; then
    RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BOLD=$'\e[1m' RESET=$'\e[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

usage() {
    echo "Usage: ${0##*/} <service>   (e.g. ${0##*/} docker)" >&2
    exit 2
}

warn() { echo "${YELLOW}WARN:${RESET} $*" >&2; }

# Prints the number of error lines from the last hour, then up to 3 top sources.
# rsyslog on Ubuntu 24.04 writes RFC3339 stamps (2026-09-28T16:03:01.123+03:00),
# older setups write "Sep 28 16:03:01". Both are in local time, so a string
# comparison against a local-time cutoff is enough.
count_syslog_errors() {
    local files=() f
    for f in "${SYSLOG_FILES[@]}"; do
        [[ -f $f ]] && files+=("$f")
    done
    if ((${#files[@]} == 0)); then
        warn "/var/log/syslog not found (journald-only system?)"
        return 0
    fi
    for f in "${files[@]}"; do
        if [[ ! -r $f ]]; then
            warn "$f is not readable: run with sudo or join the 'adm' group"
            return 0
        fi
    done

    local iso_cutoff legacy_cutoff
    iso_cutoff=$(date -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S')
    legacy_cutoff=$(date -d '1 hour ago' '+%m %d %H:%M:%S')

    # grep narrows the input cheaply; awk does the time filter and the counting.
    # grep exits 1 when nothing matches, which is a valid "0 errors" result.
    # -a: rotated syslogs can contain NUL bytes after an unclean shutdown; without
    # it grep calls the file "binary" and drops the matching lines.
    { grep -ahiE -- "$ERROR_PATTERN" "${files[@]}" || [[ $? -eq 1 ]]; } |
        awk -v iso="$iso_cutoff" -v legacy="$legacy_cutoff" '
            BEGIN {
                split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
                for (i = 1; i <= 12; i++) mon[m[i]] = sprintf("%02d", i)
            }
            $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ {
                if (substr($1, 1, 19) < iso) next
                src = $3
            }
            $1 in mon {
                if (sprintf("%s %02d %s", mon[$1], $2, $3) < legacy) next
                src = $5
            }
            !($1 in mon) && $1 !~ /^[0-9][0-9][0-9][0-9]-/ { next }
            {
                sub(/\[[0-9]+\]:?$|:$/, "", src)
                total++
                by_src[src]++
            }
            END {
                print total + 0
                for (s in by_src) print by_src[s], s
            }
        ' | {
            read -r total
            echo "Errors in syslog for the last hour: ${BOLD}${total}${RESET}"
            if ((total > 0)); then
                echo "Top sources:"
                sort -rn | head -n 3 | awk '{ printf "  %6d  %s\n", $1, $2 }'
            fi
        }
}

main() {
    (($# == 1)) || usage
    local svc=$1

    # Unit names: letters, digits and :-_.@ ; reject leading '-' so it is never an option.
    if [[ ! $svc =~ ^[A-Za-z0-9:_.@][A-Za-z0-9:_.@-]*$ ]]; then
        echo "${RED}ERROR:${RESET} invalid service name: '$svc'" >&2
        exit 2
    fi

    local cmd
    for cmd in systemctl journalctl; do
        if ! command -v "$cmd" >/dev/null; then
            echo "${RED}ERROR:${RESET} $cmd not found: systemd is required" >&2
            exit 4
        fi
    done

    echo "== Service: ${BOLD}${svc}${RESET} on $(hostname) =="

    local load_state
    load_state=$(systemctl show --property=LoadState --value -- "$svc" 2>/dev/null || true)
    if [[ $load_state == not-found || -z $load_state ]]; then
        echo "${RED}Unit '$svc' not found${RESET}"
        count_syslog_errors
        exit 3
    fi

    local state rc=0
    # is-active exits non-zero for every state except "active"; the text is what we need.
    state=$(systemctl is-active -- "$svc" 2>/dev/null) || true
    if [[ $state == active ]]; then
        echo "Status: ${GREEN}${state}${RESET}"
    else
        echo "Status: ${RED}${state:-unknown}${RESET}"
        echo "-- Last ${JOURNAL_LINES} journal lines --"
        local log
        log=$(journalctl -u "$svc" -n "$JOURNAL_LINES" --no-pager -q 2>/dev/null || true)
        if [[ -n $log ]]; then
            echo "$log"
        else
            warn "journal for '$svc' is empty or not readable (try sudo or the 'systemd-journal' group)"
        fi
        rc=1
    fi

    count_syslog_errors
    exit "$rc"
}

main "$@"
