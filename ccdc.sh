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

restore_ssh_config() {
    local config="$1"
    local backup="$2"
    local unit="$3"

    if ! cp -a -- "$backup" "$config"; then
        printf "Failed to restore the SSH configuration from %s.\n" "$backup" >&2
        return 1
    fi
    if ! systemctl restart "$unit"; then
        printf "Restored the SSH configuration, but failed to restart %s.\n" "$unit" >&2
        return 1
    fi

    printf "SSH configuration was restored from %s and %s was restarted.\n" "$backup" "$unit"
}

harden_ssh() {
    local allow_password="$1"
    local config=/etc/ssh/sshd_config
    local sshd backup tmp unit auth_password auth_pubkey
    local confirmation

    if [[ $EUID -ne 0 ]]; then
        printf "Root privileges are required to harden SSH. Re-run this script with sudo.\n" >&2
        return 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        printf "systemctl is unavailable; cannot safely harden SSH on this system.\n" >&2
        return 1
    fi
    if ! sshd=$(command -v sshd); then
        printf "sshd is unavailable; cannot validate the SSH configuration.\n" >&2
        return 1
    fi
    if [[ ! -f "$config" ]]; then
        printf "SSH configuration file %s was not found.\n" "$config" >&2
        return 1
    fi
    if [[ -L "$config" ]]; then
        config=$(readlink -f -- "$config") || {
            printf "Could not resolve SSH configuration path %s.\n" /etc/ssh/sshd_config >&2
            return 1
        }
    fi
    if ! resolve_service_unit ssh.service sshd.service; then
        return 1
    fi
    unit="$RESOLVED_UNIT"

    if [[ "$allow_password" == yes ]]; then
        auth_password=yes
        auth_pubkey=no
    else
        auth_password=no
        auth_pubkey=yes
    fi

    backup=$(mktemp "${config}.ccdc.bak.XXXXXX") || {
        printf "Could not create an SSH configuration backup.\n" >&2
        return 1
    }
    if ! cp -a -- "$config" "$backup"; then
        rm -f -- "$backup"
        printf "Could not back up %s; SSH configuration was not changed.\n" "$config" >&2
        return 1
    fi

    tmp=$(mktemp "${config}.ccdc.tmp.XXXXXX") || {
        printf "Could not create a temporary SSH configuration file.\n" >&2
        return 1
    }
    if ! chown --reference="$config" "$tmp" || ! chmod --reference="$config" "$tmp"; then
        rm -f -- "$tmp"
        printf "Could not preserve ownership and permissions for the SSH configuration.\n" >&2
        return 1
    fi

    if ! {
        printf '%s\n' \
            '# BEGIN CCDC SSH hardening' \
            'PermitRootLogin no' \
            "PasswordAuthentication $auth_password" \
            "PubkeyAuthentication $auth_pubkey" \
            'KbdInteractiveAuthentication no' \
            'PermitEmptyPasswords no' \
            'MaxAuthTries 3' \
            '# END CCDC SSH hardening'
        awk '
            BEGIN { inside = 0; starts = 0; ends = 0 }
            $0 == "# BEGIN CCDC SSH hardening" {
                if (inside || starts) invalid = 1
                inside = 1
                starts++
                next
            }
            $0 == "# END CCDC SSH hardening" {
                if (!inside) invalid = 1
                inside = 0
                ends++
                next
            }
            inside { next }
            { print }
            END {
                if (inside || starts != ends || starts > 1 || invalid) exit 2
            }
        ' "$config"
    } > "$tmp"; then
        rm -f -- "$tmp"
        printf "Could not safely update the managed SSH settings in %s; it was not changed.\n" "$config" >&2
        return 1
    fi

    if ! mv -f -- "$tmp" "$config"; then
        rm -f -- "$tmp"
        printf "Could not install the new SSH configuration; the backup is at %s.\n" "$backup" >&2
        return 1
    fi

    if ! "$sshd" -t -f "$config"; then
        printf "SSH configuration validation failed; restoring the backup.\n" >&2
        restore_ssh_config "$config" "$backup" "$unit" || return 1
        return 1
    fi

    local effective_config
    if ! effective_config=$("$sshd" -T -f "$config"); then
        printf "Could not inspect the effective SSH configuration; restoring the backup.\n" >&2
        restore_ssh_config "$config" "$backup" "$unit" || return 1
        return 1
    fi
    if ! printf '%s\n' "$effective_config" | grep -Fxq 'permitrootlogin no' ||
        ! printf '%s\n' "$effective_config" | grep -Fxq "passwordauthentication $auth_password" ||
        ! printf '%s\n' "$effective_config" | grep -Fxq "pubkeyauthentication $auth_pubkey" ||
        ! printf '%s\n' "$effective_config" | grep -Fxq 'kbdinteractiveauthentication no' ||
        ! printf '%s\n' "$effective_config" | grep -Fxq 'permitemptypasswords no' ||
        ! printf '%s\n' "$effective_config" | grep -Fxq 'maxauthtries 3'; then
        printf "Effective SSH settings did not match the requested hardening; restoring the backup.\n" >&2
        restore_ssh_config "$config" "$backup" "$unit" || return 1
        return 1
    fi

    if ! systemctl restart "$unit"; then
        printf "Could not restart %s; restoring the backup.\n" "$unit" >&2
        restore_ssh_config "$config" "$backup" "$unit" || return 1
        return 1
    fi

    printf "\nSSH was restarted with the requested hardening. Backup: %s\n" "$backup"
    printf "Test a new SSH login from another terminal, then confirm within 6 seconds to keep these changes.\n"
    trap 'printf "\nInterrupted; reverting SSH configuration.\n" >&2; restore_ssh_config "$config" "$backup" "$unit"; exit 1' HUP INT TERM
    if IFS= read -r -t 6 -p "Type 'keep' to keep the new configuration: " confirmation &&
        [[ "$confirmation" == keep ]]; then
        trap - HUP INT TERM
        printf "\nSSH hardening retained.\n"
        return 0
    fi
    trap - HUP INT TERM

    printf "\nNo confirmation received; reverting SSH configuration.\n" >&2
    restore_ssh_config "$config" "$backup" "$unit"
}

if ! ask_yes_no "Keep SSH enabled?"; then
    exit 1
fi
keep_ssh="$REPLY"

if [[ "$keep_ssh" == yes ]]; then
    if ! ask_yes_no "Allow password authentication? (yes disables public-key authentication; no disables password authentication)"; then
        exit 1
    fi
    allow_password="$REPLY"
fi

if ! ask_yes_no "Keep vsftpd enabled?"; then
    exit 1
fi
keep_ftp="$REPLY"

if [[ "$keep_ssh" == yes ]]; then
    harden_ssh "$allow_password" || exit 1
fi

if [[ "$keep_ssh" == no ]]; then
    if [[ $EUID -ne 0 ]]; then
        printf "Root privileges are required to disable SSH. Re-run this script with sudo.\n" >&2
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        printf "systemctl is unavailable; cannot disable SSH on this system.\n" >&2
        exit 1
    fi

    for socket in ssh.socket sshd.socket; do
        load_state=$(systemctl show --property=LoadState --value "$socket" 2>/dev/null) || continue
        if [[ "$load_state" == loaded ]] && ! systemctl disable --now "$socket"; then
            printf "Failed to stop and disable SSH socket (%s).\n" "$socket" >&2
            exit 1
        fi
    done

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