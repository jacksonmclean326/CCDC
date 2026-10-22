#!/usr/bin/env bash

ask_yes_no() {
    local prompt="$1"
    local answer

    while true; do
        if ! read -r -p "$prompt (y/n): " answer; then
            printf "\nInput ended before a valid answer was received.\n" >&2
            return 1
        fi

        case "$answer" in
            [yY]|[yY][eE][sS])
                REPLY=yes
                return 0
                ;;
            [nN]|[nN][oO])
                REPLY=no
                return 0
                ;;
            *)
                printf "Please answer y or n.\n" >&2
                ;;
        esac
    done
}

resolve_service_unit() {
    local candidate load_state unit_id existing
    local -a candidates=("$@")
    local -a found_units=()

    for candidate in "${candidates[@]}"; do
        load_state=$(systemctl show --property=LoadState --value "$candidate" 2>/dev/null) || continue
        if [[ "$load_state" != loaded ]]; then
            continue
        fi

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

disable_service() {
    local description="$1"
    shift
    local unit

    if [[ $EUID -ne 0 ]]; then
        printf "Root privileges are required to disable %s. Re-run this script with sudo.\n" "$description" >&2
        return 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        printf "systemctl is unavailable; cannot disable %s on this system.\n" "$description" >&2
        return 1
    fi
    if ! resolve_service_unit "$@"; then
        return 1
    fi

    unit="$RESOLVED_UNIT"
    if ! systemctl disable --now "$unit"; then
        printf "Failed to stop and disable %s (%s).\n" "$description" "$unit" >&2
        return 1
    fi

    printf "%s (%s) has been stopped and disabled.\n" "$description" "$unit"
}

if ! ask_yes_no "Keep SSH enabled?"; then
    exit 1
fi
keep_ssh="$REPLY"

if ! ask_yes_no "Keep vsftpd enabled?"; then
    exit 1
fi
keep_ftp="$REPLY"

if [[ "$keep_ssh" == no ]]; then
    disable_service "SSH" ssh.service sshd.service || exit 1
fi

if [[ "$keep_ftp" == no ]]; then
    disable_service "vsftpd" vsftpd.service || exit 1
fi

echo
echo "Listening services:"
ss -tulpn

echo
echo "Your choices:"
echo "SSH: $keep_ssh"
echo "vsftpd: $keep_ftp"