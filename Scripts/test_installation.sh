#!/bin/bash
# test_installation.sh

echo "=== Pi-hole Installation Test Runner ==="

# Pre-test cleanup
echo "1. Cleaning previous installation..."
./cleanup_pihole_unbound.sh

# Check clean state
echo "2. Verifying clean state..."
./check_installation_status.sh

echo "3. Ready for installation test!"
echo "   - Launch your piFiller app"
echo "   - Click 'Start Protection'"
echo "   - Monitor progress with: tail -f /var/log/pifill_install.log"
echo ""
echo "4. After installation, run: ./check_installation_status.sh"