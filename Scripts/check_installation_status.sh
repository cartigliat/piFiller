#!/bin/bash

# Quick status check for Pi-hole and Unbound

echo "=== Installation Status Check ==="

# Check Pi-hole
echo -n "Pi-hole command: "
if command -v pihole &>/dev/null; then
    echo "? Installed ($(pihole -v | head -1))"
else
    echo "? Not installed"
fi

echo -n "Pi-hole FTL service: "
if systemctl is-active pihole-FTL &>/dev/null; then
    echo "? Running"
elif systemctl list-units --full -all | grep -q pihole-FTL; then
    echo "?? Installed but not running"
else
    echo "? Not installed"
fi

# Check Unbound
echo -n "Unbound service: "
if systemctl is-active unbound &>/dev/null; then
    echo "? Running"
elif systemctl list-units --full -all | grep -q unbound; then
    echo "?? Installed but not running"
else
    echo "? Not installed"
fi

# Check directories
echo -n "Pi-hole config: "
if [[ -d "/etc/pihole" ]]; then
    echo "? Present"
else
    echo "? Missing"
fi

echo -n "Unbound config: "
if [[ -d "/etc/unbound" ]]; then
    echo "? Present"
else
    echo "? Missing"
fi

# Check WSL IP
WSL_IP=$(hostname -I | awk '{print $1}')
echo "WSL IP: $WSL_IP"

# Test DNS if services are running
if systemctl is-active pihole-FTL &>/dev/null; then
    echo -n "Pi-hole DNS test: "
    if dig @${WSL_IP} google.com +short &>/dev/null; then
        echo "? Working"
    else
        echo "? Failed"
    fi
fi

if systemctl is-active unbound &>/dev/null; then
    echo -n "Unbound DNS test: "
    if dig @127.0.0.1 -p 5335 google.com +short &>/dev/null; then
        echo "? Working"
    else
        echo "? Failed"
    fi
fi