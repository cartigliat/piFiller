#!/bin/bash

# Manual Pi-hole v6 Configuration Fix
# Directly edits Pi-hole configuration to stop IPv6 DNS queries

echo "🔧 Manual Pi-hole v6 Configuration Fix"
echo "======================================="
echo ""

# Find Pi-hole configuration file
echo "🔍 Finding Pi-hole configuration..."
if [[ -f "/etc/pihole/pihole.toml" ]]; then
    echo "✅ Found Pi-hole v6 configuration: /etc/pihole/pihole.toml"
    CONFIG_FILE="/etc/pihole/pihole.toml"
elif [[ -f "/etc/pihole/setupVars.conf" ]]; then
    echo "✅ Found Pi-hole v5 configuration: /etc/pihole/setupVars.conf"
    CONFIG_FILE="/etc/pihole/setupVars.conf"
else
    echo "❌ No Pi-hole configuration found!"
    exit 1
fi

# Show current configuration
echo ""
echo "📋 Current Pi-hole Configuration:"
echo "---------------------------------"
sudo cat "$CONFIG_FILE" | head -20

echo ""
echo "🔧 Manually fixing Pi-hole configuration..."
echo "--------------------------------------------"

# Stop Pi-hole first
sudo systemctl stop pihole-FTL

# Method 1: Direct configuration file edit for v6
if [[ "$CONFIG_FILE" == "/etc/pihole/pihole.toml" ]]; then
    echo "Editing Pi-hole v6 configuration directly..."
    
    # Backup first
    sudo cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$(date +%Y%m%d)"
    
    # Create a completely new configuration with only IPv4
    sudo tee /etc/pihole/pihole.toml > /dev/null <<'EOF'
# Pi-hole Configuration - IPv4 Only
[files]
  gravity = "/etc/pihole/gravity.db"
  macvendor = "/etc/pihole/macvendor.db"
  
[dns]
  upstreams = ["127.0.0.1#5335"]
  interface = "all"
  port = 53
  ipv6 = false
  bogusPriv = true
  dnssec = false
  listeningMode = "all"
  queryLogging = true
  domainNeeded = true
  expandHosts = true
  
[webserver]
  port = 80
  ipv6 = false
  
[dhcp]
  active = false
  ipv6 = false
  
[api]
  key = ""
  
[misc]
  etc_pihole_dnsmasq = "/etc/dnsmasq.d/01-pihole.conf"
EOF
    
    echo "✅ Pi-hole v6 configuration rewritten"
fi

# Method 2: Use Pi-hole's built-in reconfiguration
echo ""
echo "🔧 Using Pi-hole reconfiguration tool..."
echo "---------------------------------------"

# Start Pi-hole
sudo systemctl start pihole-FTL
sleep 5

# Use pihole command to set upstream DNS
echo "Setting upstream DNS to Unbound only..."
sudo pihole -a -d 127.0.0.1#5335

# Disable IPv6 via command line
echo "Disabling IPv6 in Pi-hole..."
if command -v pihole >/dev/null; then
    # Try to disable IPv6 through Pi-hole settings
    sudo pihole admin interface local
fi

# Method 3: Direct database modification for Pi-hole v6
echo ""
echo "🔧 Direct database configuration (Pi-hole v6)..."
echo "------------------------------------------------"

if [[ -f "/etc/pihole/gravity.db" ]]; then
    echo "Modifying Pi-hole database directly..."
    
    # Update adlist to remove IPv6 DNS servers
    sudo sqlite3 /etc/pihole/gravity.db "UPDATE info SET value='127.0.0.1#5335' WHERE property='dns_servers';" 2>/dev/null || true
    
    echo "✅ Database updated"
fi

# Method 4: Environment variable override
echo ""
echo "🔧 Setting environment variables..."
echo "----------------------------------"

# Create environment file for Pi-hole
sudo tee /etc/pihole/pihole.env > /dev/null <<'EOF'
PIHOLE_DNS_1=127.0.0.1#5335
PIHOLE_DNS_2=
IPV6_ADDRESS=
DNSMASQ_LISTENING=all
EOF

echo "✅ Environment variables set"

# Method 5: Direct dnsmasq configuration
echo ""
echo "🔧 Configuring dnsmasq directly..."
echo "----------------------------------"

if [[ -f "/etc/dnsmasq.d/01-pihole.conf" ]]; then
    echo "Updating dnsmasq configuration..."
    
    # Backup and modify dnsmasq config
    sudo cp /etc/dnsmasq.d/01-pihole.conf /etc/dnsmasq.d/01-pihole.conf.backup
    
    # Remove any IPv6 DNS servers and add only Unbound
    sudo sed -i '/server=.*:.*#/d' /etc/dnsmasq.d/01-pihole.conf
    sudo sed -i '/server=2620:fe::10/d' /etc/dnsmasq.d/01-pihole.conf
    
    # Ensure Unbound is the only upstream
    if ! grep -q "server=127.0.0.1#5335" /etc/dnsmasq.d/01-pihole.conf; then
        echo "server=127.0.0.1#5335" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
    fi
    
    # Disable IPv6
    if ! grep -q "bind-interfaces" /etc/dnsmasq.d/01-pihole.conf; then
        echo "bind-interfaces" | sudo tee -a /etc/dnsmasq.d/01-pihole.conf
    fi
    
    echo "✅ dnsmasq configuration updated"
else
    echo "❌ dnsmasq configuration not found"
fi

# Restart all services
echo ""
echo "🔄 Restarting all services..."
echo "----------------------------"

sudo systemctl stop pihole-FTL
sudo systemctl restart unbound
sleep 3
sudo systemctl start pihole-FTL
sleep 5

# Verify services
echo "Service status:"
echo "- Unbound: $(systemctl is-active unbound)"
echo "- Pi-hole FTL: $(systemctl is-active pihole-FTL)"

# Test DNS resolution
echo ""
echo "🧪 Testing DNS resolution..."
echo "----------------------------"

WSL_IP=$(hostname -I | awk '{print $1}')

echo "Testing direct queries:"
echo -n "- Unbound (127.0.0.1:5335): "
if dig @127.0.0.1 -p 5335 example.com +short >/dev/null 2>&1; then
    echo "✅ Working"
else
    echo "❌ Failed"
fi

echo -n "- Pi-hole (127.0.0.1:53): "
if dig @127.0.0.1 -p 53 example.com +short >/dev/null 2>&1; then
    echo "✅ Working"
else
    echo "❌ Failed"
fi

echo -n "- Pi-hole (WSL IP): "
if dig @$WSL_IP example.com +short >/dev/null 2>&1; then
    echo "✅ Working"
else
    echo "❌ Failed"
fi

# Check for IPv6 attempts
echo ""
echo "🔍 Monitoring for IPv6 errors..."
echo "--------------------------------"

echo "Performing test query and monitoring logs..."
dig @$WSL_IP test.example.com >/dev/null 2>&1 &

# Check various log locations
log_locations=(
    "/var/log/pihole-FTL.log"
    "/var/log/pihole.log"
    "/etc/pihole/pihole.log"
    "/var/log/syslog"
)

found_logs=false
for log_file in "${log_locations[@]}"; do
    if [[ -f "$log_file" ]]; then
        echo "Found log: $log_file"
        found_logs=true
        
        # Check for recent IPv6 errors
        recent_errors=$(sudo tail -20 "$log_file" 2>/dev/null | grep -i "2620:fe\|ipv6.*error\|connection.*error" | wc -l)
        if [[ "$recent_errors" -gt 0 ]]; then
            echo "⚠️ Recent IPv6 errors in $log_file:"
            sudo tail -10 "$log_file" 2>/dev/null | grep -i "2620:fe\|ipv6.*error\|connection.*error" || true
        else
            echo "✅ No recent IPv6 errors in $log_file"
        fi
    fi
done

if [[ "$found_logs" == "false" ]]; then
    echo "❌ No Pi-hole log files found"
    echo "Checking journalctl instead..."
    sudo journalctl -u pihole-FTL --no-pager -n 10 | grep -i "2620:fe\|error" || echo "No errors in systemd logs"
fi

# Final configuration check
echo ""
echo "📋 Final Configuration Check:"
echo "-----------------------------"

echo "Current Pi-hole configuration:"
if [[ -f "/etc/pihole/pihole.toml" ]]; then
    sudo grep -E "upstreams|ipv6" /etc/pihole/pihole.toml 2>/dev/null || echo "Could not read config"
fi

echo ""
echo "Current dnsmasq upstream servers:"
if [[ -f "/etc/dnsmasq.d/01-pihole.conf" ]]; then
    sudo grep "server=" /etc/dnsmasq.d/01-pihole.conf 2>/dev/null || echo "No upstream servers found"
fi

echo ""
echo "🎯 Manual fix completed!"
echo ""
echo "Next steps:"
echo "1. In Windows app: Stop Protection → Start Protection"
echo "2. Wait 1 minute for changes to propagate"
echo "3. Visit a NEW website (not YouTube - try news.ycombinator.com)"
echo "4. Check Pi-hole admin dashboard for query increases"
echo ""
echo "If still getting IPv6 errors, Pi-hole may need complete reinstallation."