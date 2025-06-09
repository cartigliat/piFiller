#!/bin/bash

# Fix WSL Internet Connectivity After Tailscale Removal

echo "🔧 Fixing WSL Internet Connectivity"
echo "===================================="
echo ""

# Test current connectivity
echo "📡 Testing current connectivity..."
echo "--------------------------------"
echo -n "Ping Google DNS: "
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "✅ IPv4 connectivity working"
else
    echo "❌ IPv4 connectivity failed"
fi

echo -n "DNS resolution: "
if ping -c 1 google.com >/dev/null 2>&1; then
    echo "✅ DNS resolution working"
else
    echo "❌ DNS resolution failed"
fi

echo ""
echo "🔍 Current network configuration:"
echo "--------------------------------"
echo "Current nameservers in /etc/resolv.conf:"
cat /etc/resolv.conf

echo ""
echo "Network interfaces:"
ip addr show | grep -E "(inet |^\d+:)" | grep -v "127.0.0.1"

echo ""
echo "Default route:"
ip route show default

# Fix 1: Restore default DNS
echo ""
echo "🔧 Fix 1: Restore DNS configuration"
echo "-----------------------------------"

# Remove any immutable attribute
sudo chattr -i /etc/resolv.conf 2>/dev/null || true

# Backup current resolv.conf
sudo cp /etc/resolv.conf /etc/resolv.conf.backup 2>/dev/null || true

# Create new resolv.conf with working DNS
echo "Creating new DNS configuration..."
sudo tee /etc/resolv.conf > /dev/null <<'EOF'
# DNS configuration for WSL
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
search localdomain
EOF

echo "✅ DNS configuration updated"

# Fix 2: Restart WSL networking
echo ""
echo "🔧 Fix 2: Restart network services"
echo "----------------------------------"

# Try to restart networking if available
if command -v systemctl >/dev/null 2>&1; then
    echo "Restarting systemd-networkd..."
    sudo systemctl restart systemd-networkd 2>/dev/null || echo "systemd-networkd not available"
    
    echo "Restarting systemd-resolved..."
    sudo systemctl restart systemd-resolved 2>/dev/null || echo "systemd-resolved not available"
fi

# Fix 3: Flush DNS cache and refresh network
echo ""
echo "🔧 Fix 3: Refresh network configuration"
echo "---------------------------------------"

# Flush any DNS cache
if command -v systemd-resolve >/dev/null 2>&1; then
    sudo systemd-resolve --flush-caches 2>/dev/null || true
fi

# Refresh network interface
interface=$(ip route show default | grep -oP 'dev \K\S+' | head -1)
if [[ -n "$interface" ]]; then
    echo "Refreshing interface: $interface"
    sudo ip link set "$interface" down 2>/dev/null || true
    sleep 1
    sudo ip link set "$interface" up 2>/dev/null || true
fi

echo "✅ Network refresh completed"

# Fix 4: Test connectivity again
echo ""
echo "🧪 Testing connectivity after fixes"
echo "-----------------------------------"

echo -n "Ping Google DNS: "
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "✅ IPv4 connectivity working"
else
    echo "❌ IPv4 connectivity still failed"
fi

echo -n "DNS resolution: "
if ping -c 1 google.com >/dev/null 2>&1; then
    echo "✅ DNS resolution working"
    dns_working=true
else
    echo "❌ DNS resolution still failed"
    dns_working=false
fi

echo -n "HTTPS connectivity: "
if curl -s --connect-timeout 5 https://google.com >/dev/null 2>&1; then
    echo "✅ HTTPS working"
else
    echo "❌ HTTPS failed"
fi

# If still not working, try alternative fixes
if [[ "$dns_working" != "true" ]]; then
    echo ""
    echo "🔧 Alternative Fix: Windows DNS passthrough"
    echo "-------------------------------------------"
    
    # Try to use Windows DNS servers
    windows_dns=$(cat /proc/net/route | awk '/^[A-Za-z0-9]+[ \t]+00000000/ { print $1 }' | head -1)
    if [[ -n "$windows_dns" ]]; then
        echo "Attempting to use Windows DNS configuration..."
        
        # Get Windows DNS from registry if possible
        # This is a fallback approach
        sudo tee /etc/resolv.conf > /dev/null <<'EOF'
# Fallback DNS configuration
nameserver 192.168.1.1
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
        
        echo "Testing with fallback DNS..."
        if ping -c 1 google.com >/dev/null 2>&1; then
            echo "✅ Fallback DNS working"
        else
            echo "❌ Fallback DNS failed"
        fi
    fi
fi

echo ""
echo "📋 Final network status:"
echo "------------------------"
echo "Current DNS servers:"
grep nameserver /etc/resolv.conf

echo ""
echo "Network connectivity test:"
if ping -c 3 google.com >/dev/null 2>&1; then
    echo "✅ Internet connectivity restored!"
    echo ""
    echo "🎉 WSL networking is now working!"
    echo "You can now run the Pi-hole installation."
else
    echo "❌ Internet connectivity still not working"
    echo ""
    echo "📝 Manual steps to try:"
    echo "1. Restart Windows"
    echo "2. Run 'wsl --shutdown' in Windows, then restart WSL"
    echo "3. Check Windows network adapter settings"
    echo "4. Disable/enable Wi-Fi adapter in Windows"
fi

echo ""
echo "Next steps:"
echo "1. If connectivity is restored, go back to your app"
echo "2. Click 'Start Protection' to install Pi-hole"
echo "3. The installation should now work"