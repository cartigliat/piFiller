#!/bin/bash

# Fix Pi-hole and Unbound Configuration
# Run this after the initial installation to fix remaining issues

set -e

echo "=== Pi-hole and Unbound Configuration Fix ==="
echo "Starting fix process..."

# Function to log messages
log_message() {
    echo "[FIX] $(date '+%Y-%m-%d %H:%M:%S'): $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $1" >&2
}

# Fix 1: Configure Pi-hole DNS settings for v6
log_message "Configuring Pi-hole DNS settings for v6..."

# Pi-hole v6 uses a different configuration method
# We need to edit the pihole.toml file directly
PIHOLE_CONFIG="/etc/pihole/pihole.toml"

if [[ -f "$PIHOLE_CONFIG" ]]; then
    log_message "Updating Pi-hole configuration file..."
    
    # Backup the original config
    sudo cp "$PIHOLE_CONFIG" "$PIHOLE_CONFIG.backup"
    
    # Update DNS upstream settings
    sudo sed -i 's/dns.upstreams = \[.*\]/dns.upstreams = ["127.0.0.1#5335"]/' "$PIHOLE_CONFIG"
    
    log_message "Pi-hole configuration updated"
else
    log_error "Pi-hole configuration file not found: $PIHOLE_CONFIG"
fi

# Fix 2: Fix Unbound configuration
log_message "Fixing Unbound configuration..."

# Check if our Pi-hole config exists
UNBOUND_PIHOLE_CONF="/etc/unbound/unbound.conf.d/pi-hole.conf"

if [[ -f "$UNBOUND_PIHOLE_CONF" ]]; then
    log_message "Verifying Unbound configuration..."
    
    # Test the configuration
    if sudo unbound-checkconf "$UNBOUND_PIHOLE_CONF"; then
        log_message "Unbound configuration is valid"
    else
        log_message "Fixing Unbound configuration syntax..."
        
        # Create a corrected configuration
        sudo tee "$UNBOUND_PIHOLE_CONF" > /dev/null <<'EOF'
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
    
    # Root hints
    root-hints: "/var/lib/unbound/root.hints"
    
    # Security settings
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    
    # Performance settings
    edns-buffer-size: 1472
    prefetch: yes
    num-threads: 1
    msg-cache-size: 50m
    rrset-cache-size: 100m
    cache-min-ttl: 300
    cache-max-ttl: 86400
    
    # Privacy settings
    hide-identity: yes
    hide-version: yes
    
    # Access control
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    
    # Additional settings for stability
    so-rcvbuf: 1m
    so-sndbuf: 1m
    outgoing-range: 4096
    num-queries-per-thread: 2048
EOF
        
        log_message "Unbound configuration recreated"
    fi
else
    log_error "Unbound Pi-hole configuration not found"
fi

# Fix 3: Ensure root hints are available
log_message "Checking root hints..."
ROOT_HINTS="/var/lib/unbound/root.hints"

if [[ ! -f "$ROOT_HINTS" ]]; then
    log_message "Downloading root hints..."
    sudo mkdir -p /var/lib/unbound
    sudo wget -O "$ROOT_HINTS" https://www.internic.net/domain/named.cache
    sudo chown unbound:unbound "$ROOT_HINTS"
fi

# Fix 4: Start services in correct order
log_message "Starting services..."

# Stop both services first
sudo systemctl stop unbound || true
sudo systemctl stop pihole-FTL || true

# Start Unbound first
log_message "Starting Unbound..."
sudo systemctl enable unbound
sudo systemctl start unbound

# Wait a moment for Unbound to fully start
sleep 3

# Check if Unbound is running
if sudo systemctl is-active unbound >/dev/null; then
    log_message "✓ Unbound is running"
    
    # Test Unbound
    if dig @127.0.0.1 -p 5335 google.com +short >/dev/null 2>&1; then
        log_message "✓ Unbound is responding to queries"
    else
        log_message "⚠ Unbound is running but not responding - checking logs..."
        sudo journalctl -u unbound --no-pager -n 5
    fi
else
    log_error "✗ Unbound failed to start"
    sudo journalctl -u unbound --no-pager -n 10
fi

# Start Pi-hole FTL
log_message "Starting Pi-hole FTL..."
sudo systemctl enable pihole-FTL
sudo systemctl restart pihole-FTL

# Wait for Pi-hole to start
sleep 5

# Fix 5: Verify the complete setup
log_message "Verifying installation..."

WSL_IP=$(hostname -I | awk '{print $1}')
log_message "WSL IP: $WSL_IP"

# Check Pi-hole status
if pihole status >/dev/null 2>&1; then
    log_message "✓ Pi-hole is running"
else
    log_message "⚠ Pi-hole status check failed"
fi

# Check if Pi-hole FTL is running
if sudo systemctl is-active pihole-FTL >/dev/null; then
    log_message "✓ Pi-hole FTL service is active"
else
    log_message "✗ Pi-hole FTL service is not active"
fi

# Test DNS resolution through Pi-hole
if dig @${WSL_IP} google.com +short >/dev/null 2>&1; then
    log_message "✓ Pi-hole DNS resolution working"
else
    log_message "⚠ Pi-hole DNS resolution test failed"
fi

# Test the complete chain: Pi-hole -> Unbound -> Internet
if dig @${WSL_IP} example.com +short >/dev/null 2>&1; then
    log_message "✓ Complete DNS chain working (Pi-hole -> Unbound -> Internet)"
else
    log_message "⚠ Complete DNS chain test failed"
fi

# Show final status
echo ""
echo "=== Final Status ==="
echo "Pi-hole Web Interface: http://${WSL_IP}/admin"
echo "DNS Server: ${WSL_IP}"
echo "Upstream DNS: Unbound (127.0.0.1:5335)"
echo ""

# Show service status
echo "Service Status:"
echo -n "Unbound: "
if sudo systemctl is-active unbound >/dev/null; then
    echo "✓ Running"
else
    echo "✗ Not running"
fi

echo -n "Pi-hole FTL: "
if sudo systemctl is-active pihole-FTL >/dev/null; then
    echo "✓ Running"
else
    echo "✗ Not running"
fi

log_message "Fix script completed"

# Test the stats script
echo ""
echo "=== Testing Stats Collection ==="
STATS_SCRIPT_DIR="$(dirname "$0")"
if [[ -f "$STATS_SCRIPT_DIR/get_pihole_stats.sh" ]]; then
    log_message "Testing stats script..."
    bash "$STATS_SCRIPT_DIR/get_pihole_stats.sh"
else
    log_message "Stats script not found in same directory"
fi

echo ""
echo "Setup should now be complete! Try accessing Pi-hole at: http://${WSL_IP}/admin"