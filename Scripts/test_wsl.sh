#!/bin/bash
echo "=== WSL Test Script ==="
echo "Current user: $(whoami)"
echo "Current directory: $(pwd)"
echo "Date: $(date)"
echo "Ubuntu version: $(lsb_release -d)"
echo "Can we sudo? $(sudo -n echo 'YES' 2>/dev/null || echo 'NO')"
echo "=== Test Complete ==="