#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
    printf "Root privileges are required. Re-run this script with sudo.\n" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    printf "systemctl is unavailable; cannot restore services on this system.\n" >&2
    exit 1
fi

resolve_service_unit() {
    local candidate load_state unit_id existing
    local -a candidates=("$@")
    local -a found_units=()

    for candidate in "${candidates[@]}"; do
        load_state=$(systemctl show --property=LoadState --value "$candidate" 2>/dev/null) || continue
        [[ "$load_state" == loaded ]] || continue

        unit_id=$(systemctl show --property=Id --value "$candidate" 2>/dev/null) || continue
        for existing in "${found_units[@]}"; do
            [[ "$existing" == "$unit_id" ]] && continue 2
        done
        found_units+=("$unit_id")
    done

    if [[ ${#found_units[@]} -eq 0 ]]; then
        printf "Could not find an installed service unit (%s).\n" "${candidates[*]}" >&2
        return 1
    fi
    if [[ ${#found_units[@]} -gt 1 ]]; then
        printf "Found multiple matching service units (%s); refusing to guess.\n" "${found_units[*]}" >&2
        return 1
    fi

    RESOLVED_UNIT="${found_units[0]}"
}

restore_service() {
    local description="$1"
    shift
    local unit

    if ! resolve_service_unit "$@"; then
        return 1
    fi

    unit="$RESOLVED_UNIT"
    if ! systemctl enable --now "$unit"; then
        printf "Failed to enable and start %s (%s).\n" "$description" "$unit" >&2
        return 1
    fi

    printf "%s (%s) is enabled and running.\n" "$description" "$unit"
}

failed=0
restore_service "SSH" ssh.service sshd.service || failed=1
restore_service "vsftpd" vsftpd.service || failed=1

exit "$failed"
