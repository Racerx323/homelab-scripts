#!/usr/bin/env bash

# This script changes the DNS servers for a specified network interface using NetworkManager.

# Exit immediately if a command exits with a non-zero status
set -e

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

# 2. Automatically find the connection profile name associated with eth0
echo "Detecting NetworkManager profile for $INTERFACE..."
PROFILE_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$INTERFACE$" | cut -d: -f1)

if [ -z "$PROFILE_NAME" ]; then
    # Fallback to check all profiles if an active one isn't found
    PROFILE_NAME=$(nmcli -t -f NAME,DEVICE connection show | grep ":$INTERFACE$" | head -n 1 | cut -d: -f1)
fi

if [ -z "$PROFILE_NAME" ]; then
    echo "Error: Could not find a NetworkManager profile for interface $INTERFACE." >&2
    exit 1
fi

echo "Found profile: '$PROFILE_NAME'"

# 3. Modify the DNS Configuration
echo "Updating IPv4 DNS servers to: $IPV4_DNS"
nmcli connection modify "$PROFILE_NAME" ipv4.dns "$IPV4_DNS"

echo "Updating IPv6 DNS servers to: $IPV6_DNS"
nmcli connection modify "$PROFILE_NAME" ipv6.dns "$IPV6_DNS"

echo "Disabling automatic DHCP DNS overrides..."
nmcli connection modify "$PROFILE_NAME" ipv4.ignore-auto-dns yes
nmcli connection modify "$PROFILE_NAME" ipv6.ignore-auto-dns yes

# 4. Apply changes by reactivating the profile
echo "Reactivating connection profile '$PROFILE_NAME'..."
nmcli connection up "$PROFILE_NAME"

# 5. Verify the updates
echo "=== Verification ==="
if command -v resolvectl &>/dev/null; then
    resolvectl status "$INTERFACE"
else
    echo "resolvectl not found. Current /etc/resolv.conf content:"
    cat /etc/resolv.conf
fi

echo "DNS configuration complete!"
