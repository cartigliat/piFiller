#!/bin/bash

# Complete Pi-hole and Unbound Removal Script
# Run this before each test to ensure clean state

set -e

echo "=== Cleaning Pi-hole and Unbound Installation ==="

# Function to log messages
log_message() {
    echo "[CLEANUP] $(date '+%Y-%m-%d %H:%M:%S'): $1"
}

log_message "Starting cleanup process..."

# Stop services first
log_message "Stopping services..."
sudo systemctl stop pihole-FTL || true
sudo systemctl stop unbound || true
sudo systemctl stop lighttpd || true

# Disable services
log_message "Disabling services..."
sudo systemctl disable pihole-FTL || true
sudo systemctl disable unbound || true
sudo systemctl disable lighttpd || true

# Remove Pi-hole
log_message "Removing Pi-hole..."
if command -v pihole &>/dev/null; then
    # Use Pi-hole's uninstall if available
    echo "yes" | sudo pihole uninstall || true
fi

# Remove Pi-hole files manually
sudo rm -rf /etc/pihole/ || true
sudo rm -rf /opt/pihole/ || true
sudo rm -rf /var/www/html/admin/ || true
sudo rm -f /usr/local/bin/pihole || true
sudo rm -f /etc/systemd/system/pihole-FTL.service || true

# Remove Unbound
log_message "Removing Unbound..."
sudo apt-get remove --purge -y unbound unbound-* || true
sudo rm -rf /etc/unbound/ || true
sudo rm -rf /var/lib/unbound/ || true

# Remove lighttpd (Pi-hole web server)
log_message "Removing lighttpd..."
sudo apt-get remove --purge -y lighttpd lighttpd-* || true
sudo rm -rf /etc/lighttpd/ || true

# Clean up DNS settings
log_message "Cleaning DNS settings..."
sudo rm -f /etc/dnsmasq.d/01-pihole.conf || true
sudo rm -f /etc/dnsmasq.d/06-rfc6761.conf || true

# Remove any Pi-hole cron jobs
sudo crontab -l 2>/dev/null | grep -v pihole | sudo crontab - || true

# Clean package cache
log_message "Cleaning package cache..."
sudo apt-get autoremove -y || true
sudo apt-get autoclean || true

# Reload systemd
sudo systemctl daemon-reload

log_message "Cleanup completed. System is ready for fresh installation."

# Verify cleanup
echo ""
echo "=== Cleanup Verification ==="
echo -n "Pi-hole command: "
if command -v pihole &>/dev/null; then
    echo "? Still present"
else
    echo "? Removed"
fi

echo -n "Unbound service: "
if systemctl list-units --full -all | grep -q unbound; then
    echo "? Still present"
else
    echo "? Removed"
fi

echo -n "Pi-hole FTL service: "
if systemctl list-units --full -all | grep -q pihole-FTL; then
    echo "? Still present"
else
    echo "? Removed"
fi

echo "Cleanup verification completed."