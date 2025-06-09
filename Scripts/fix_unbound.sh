#!/bin/bash

# Quick Unbound Fix Script
echo "=== Fixing Unbound Configuration ==="

# Stop the failing service
sudo systemctl stop unbound

# Backup the current config
sudo cp /etc/unbound/unbound.conf.d/pi-hole.conf /etc/unbound/unbound.conf.d/pi-hole.conf.backup

# Create a corrected configuration
sudo tee /etc/unbound/unbound.conf.d/pi-hole.conf > /dev/null <<'EOF'
server:
    # Basic configuration
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    prefer-ip6: no
    
    # Security settings
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    harden-large-queries: yes
    harden-short-bufsize: yes
    
    # Performance settings
    edns-buffer-size: 1472
    prefetch: yes
    num-threads: 1
    msg-cache-size: 50m
    rrset-cache-size: 100m
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    
    # Privacy settings
    hide-identity: yes
    hide-version: yes
    
    # Access control
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    
    # Root hints
    root-hints: "/var/lib/unbound/root.hints"
EOF

# Ensure root hints exist
if [[ ! -f "/var/lib/unbound/root.hints" ]]; then
    echo "Downloading root hints..."
    sudo mkdir -p /var/lib/unbound
    sudo curl -s -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache
    sudo chown unbound:unbound /var/lib/unbound/root.hints
fi

# Check the configuration
echo "Checking Unbound configuration..."
if sudo unbound-checkconf; then
    echo "? Configuration is valid"
else
    echo "? Configuration still has errors"
    exit 1
fi

# Start Unbound
echo "Starting Unbound..."
sudo systemctl start unbound

# Wait a moment
sleep 2

# Check status
if sudo systemctl is-active unbound >/dev/null; then
    echo "? Unbound is now running"
    
    # Test DNS resolution
    if dig @127.0.0.1 -p 5335 google.com +short >/dev/null 2>&1; then
        echo "? Unbound DNS resolution working"
    else
        echo "?? Unbound running but DNS test failed"
    fi
else
    echo "? Unbound still failed to start"
    echo "Checking logs..."
    sudo journalctl -u unbound --no-pager -n 5
fi

echo "=== Unbound fix complete ==="