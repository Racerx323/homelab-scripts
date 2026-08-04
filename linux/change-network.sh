#!/usr/bin/env bash

# This script changes the DNS servers for a specified network interface using NetworkManager.

# Exit immediately if a command exits with a non-zero status
set -e
set -o pipefail

# Define DNS variables (Change these if you want to use different providers)
IPV4_DNS="8.8.8.8 8.8.4.4"
IPV6_DNS="2001:4860:4860::8888 2001:4860:4860::8844"
INTERFACE="eth0"

echo "=== NetworkManager DNS Configuration Script ==="

# 1. Ensure the script is run with sudo/root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script with sudo or as root." >&2
    exit 1
fi

# 2. Automatically find the connection profile UUID associated with eth0
echo "Detecting NetworkManager profile for $INTERFACE..."
ACTIVE_MATCHES=$(nmcli -t -f UUID,DEVICE connection show --active | awk -F: -v device="$INTERFACE" '$2 == device { print $1 }')

if [ -n "$ACTIVE_MATCHES" ]; then
    MATCHING_COUNT=$(printf '%s\n' "$ACTIVE_MATCHES" | sed '/^$/d' | wc -l)
    if [ "$MATCHING_COUNT" -eq 1 ]; then
        PROFILE_UUID=$(printf '%s\n' "$ACTIVE_MATCHES")
    else
        echo "Error: Multiple NetworkManager profiles match interface $INTERFACE:" >&2
        printf '%s\n' "$ACTIVE_MATCHES" | sed 's/^/  /' >&2
        exit 1
    fi
else
    # Fallback to check explicitly configured profiles by interface binding
    FALLBACK_MATCHES=$(nmcli -t -f UUID,connection.interface-name connection show | awk -F: -v iface="$INTERFACE" '$2 == iface { print $1 }')

    if [ -z "$FALLBACK_MATCHES" ]; then
        echo "Error: Could not find a NetworkManager profile for interface $INTERFACE." >&2
        exit 1
    fi

    MATCHING_COUNT=$(printf '%s\n' "$FALLBACK_MATCHES" | sed '/^$/d' | wc -l)
    if [ "$MATCHING_COUNT" -eq 1 ]; then
        PROFILE_UUID=$(printf '%s\n' "$FALLBACK_MATCHES")
    else
        echo "Error: Multiple NetworkManager profiles match interface $INTERFACE:" >&2
        printf '%s\n' "$FALLBACK_MATCHES" | sed 's/^/  /' >&2
        exit 1
    fi
fi

PROFILE_NAME=$(nmcli -g NAME connection show "$PROFILE_UUID")

echo "Found profile: '$PROFILE_NAME' ($PROFILE_UUID)"

# 3. Verify DNS backend availability before changing the profile
echo "=== Verification prerequisites ==="
if ! command -v resolvectl &>/dev/null; then
    echo "Error: resolvectl not found; unable to verify DNS configuration." >&2
    exit 1
fi

if ! resolvectl status "$INTERFACE" >/dev/null 2>&1; then
    echo "Error: systemd-resolved backend is unavailable for interface $INTERFACE." >&2
    exit 1
fi

# 4. Modify the DNS Configuration
echo "Updating IPv4 DNS servers to: $IPV4_DNS"
echo "Updating IPv6 DNS servers to: $IPV6_DNS"
nmcli connection modify "$PROFILE_UUID" ipv4.dns "$IPV4_DNS" ipv6.dns "$IPV6_DNS" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes

echo "Disabling automatic DHCP DNS overrides..."

# 5. Apply changes by reactivating the profile
echo "Reactivating connection profile '$PROFILE_NAME'..."
nmcli connection up "$PROFILE_UUID" ifname "$INTERFACE"

# 6. Verify the updates
echo "=== Verification ==="
if ! RESOLVECTL_OUTPUT=$(resolvectl dns "$INTERFACE" 2>/dev/null); then
    echo "Error: Unable to query resolvectl DNS settings for interface $INTERFACE." >&2
    exit 1
fi

if ! PROFILE_OUTPUT=$(nmcli -e no -g ipv4.dns,ipv6.dns connection show "$PROFILE_UUID" 2>/dev/null); then
    echo "Error: Unable to query NetworkManager DNS settings for profile '$PROFILE_NAME'." >&2
    exit 1
fi

RESOLVECTL_OUTPUT=$(printf '%s\n' "$RESOLVECTL_OUTPUT" | sed 's/[[:space:],]\+/\n/g')
PROFILE_OUTPUT=$(printf '%s\n' "$PROFILE_OUTPUT" | sed 's/[[:space:],]\+/\n/g')

for dns_server in $IPV4_DNS; do
    if ! printf '%s\n' "$RESOLVECTL_OUTPUT" | grep -Fqx -- "$dns_server" || ! printf '%s\n' "$PROFILE_OUTPUT" | grep -Fqx -- "$dns_server"; then
        echo "Error: IPv4 DNS server '$dns_server' was not found in the verification output." >&2
        exit 1
    fi
done

for dns_server in $IPV6_DNS; do
    if ! printf '%s\n' "$RESOLVECTL_OUTPUT" | grep -Fqx -- "$dns_server" || ! printf '%s\n' "$PROFILE_OUTPUT" | grep -Fqx -- "$dns_server"; then
        echo "Error: IPv6 DNS server '$dns_server' was not found in the verification output." >&2
        exit 1
    fi
done

echo "DNS configuration complete!"
