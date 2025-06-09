#!/bin/bash

# Test Different Unbound Configurations
echo "🧪 Testing Unbound Configuration Options"
echo "======================================="
echo ""

# Function to test DNS resolution
test_dns() {
    local description="$1"
    echo -n "Testing $description: "
    if timeout 5 dig @127.0.0.1 -p 5335 google.com +short >/dev/null 2>&1; then
        echo "✅ Working"
        return 0
    else
        echo "❌ Failed"
        return 1
    fi
}

# Test current configuration
echo "📋 Current Unbound Status:"
echo "- Service: $(systemctl is-active unbound 2>/dev/null || echo 'inactive')"
echo ""

if systemctl is-active unbound >/dev/null; then
    test_dns "current configuration"
    echo ""
fi

echo "🔧 Testing Forwarding Configuration (Quad9 upstream)..."
echo "------------------------------------------------------"

# Create forwarding configuration
sudo tee /etc/unbound/unbound.conf.d/pi-hole.conf > /dev/null <<'EOF'
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    prefer-ip6: no
    
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    
    edns-buffer-size: 1472
    prefetch: yes
    num-threads: 1
    msg-cache-size: 50m
    rrset-cache-size: 100m
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    
    hide-identity: yes
    hide-version: yes
    
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse

forward-zone:
    name: "."
    forward-addr: 9.9.9.9        # Quad9 Primary
    forward-addr: 149.112.112.112 # Quad9 Secondary  
    forward-addr: 1.1.1.1        # Cloudflare Primary
    forward-addr: 1.0.0.1        # Cloudflare Secondary
EOF

# Restart and test
sudo systemctl restart unbound
sleep 3

if systemctl is-active unbound >/dev/null; then
    test_dns "Quad9 forwarding"
    forwarding_works=true
else
    echo "❌ Unbound failed to start with forwarding config"
    forwarding_works=false
fi

echo ""
echo "🔧 Testing Recursive Configuration (root servers)..."
echo "---------------------------------------------------"

# Create recursive configuration  
sudo tee /etc/unbound/unbound.conf.d/pi-hole.conf > /dev/null <<'EOF'
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    prefer-ip6: no
    
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    
    edns-buffer-size: 1472
    prefetch: yes
    num-threads: 1
    msg-cache-size: 50m
    rrset-cache-size: 100m
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    
    hide-identity: yes
    hide-version: yes
    
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    
    root-hints: "/var/lib/unbound/root.hints"
EOF

# Download root hints if needed
if [[ ! -f "/var/lib/unbound/root.hints" ]]; then
    echo "Downloading root hints..."
    sudo mkdir -p /var/lib/unbound
    sudo curl -s -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache
    sudo chown unbound:unbound /var/lib/unbound/root.hints 2>/dev/null || true
fi

# Restart and test
sudo systemctl restart unbound
sleep 5  # Recursive resolution takes longer to start

if systemctl is-active unbound >/dev/null; then
    test_dns "recursive resolution"
    recursive_works=true
else
    echo "❌ Unbound failed to start with recursive config"
    recursive_works=false
fi

echo ""
echo "🎯 Test Results Summary:"
echo "========================"

if [[ "$forwarding_works" == "true" ]]; then
    echo "✅ Forwarding (Quad9): Working"
else
    echo "❌ Forwarding (Quad9): Failed"
fi

if [[ "$recursive_works" == "true" ]]; then
    echo "✅ Recursive (Root servers): Working"
else
    echo "❌ Recursive (Root servers): Failed"
fi

echo ""
echo "📋 Recommendation:"
if [[ "$forwarding_works" == "true" ]]; then
    echo "🎉 Use FORWARDING configuration (Quad9 upstream)"
    echo "   - More reliable in WSL environments"
    echo "   - Faster startup time"
    echo "   - Still provides privacy and malware protection"
    
    # Set the working forwarding config
    sudo tee /etc/unbound/unbound.conf.d/pi-hole.conf > /dev/null <<'EOF'
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    prefer-ip6: no
    
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    
    edns-buffer-size: 1472
    prefetch: yes
    num-threads: 1
    msg-cache-size: 50m
    rrset-cache-size: 100m
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    
    hide-identity: yes
    hide-version: yes
    
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse

forward-zone:
    name: "."
    forward-addr: 9.9.9.9
    forward-addr: 149.112.112.112
    forward-addr: 1.1.1.1
    forward-addr: 1.0.0.1
EOF

elif [[ "$recursive_works" == "true" ]]; then
    echo "✅ Use RECURSIVE configuration (root servers)"
    echo "   - More privacy (no upstream providers)"
    echo "   - Direct queries to authoritative servers"
else
    echo "❌ Both configurations failed"
    echo "   - Check WSL network connectivity"
    echo "   - Check firewall settings"
    echo "   - Try manual DNS test: dig @8.8.8.8 google.com"
fi

# Final restart with chosen config
sudo systemctl restart unbound
sleep 3
sudo systemctl restart pihole-FTL

echo ""
echo "✅ Final configuration applied and services restarted"