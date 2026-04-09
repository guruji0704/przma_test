#!/bin/bash
# Start a simple mock Pleroma server on port 4001 for development

echo "Starting Pleroma mock server on port 4001..."
echo "This is a simple mock server for development purposes."
echo ""
echo "To use a real Pleroma instance, set PLEROMA_BASE_URL environment variable:"
echo "  export PLEROMA_BASE_URL=http://your-pleroma-instance.com"
echo ""

# Check if port 4001 is already in use
if lsof -Pi :4001 -sTCP:LISTEN -t >/dev/null ; then
    echo "Port 4001 is already in use. Please stop the service using that port first."
    exit 1
fi

# Start a simple HTTP server using Python or Node.js if available
if command -v python3 &> /dev/null; then
    echo "Starting Python HTTP server on port 4001..."
    cd "$(dirname "$0")/../priv/pleroma_mock" 2>/dev/null || mkdir -p "$(dirname "$0")/../priv/pleroma_mock"
    cd "$(dirname "$0")/../priv/pleroma_mock"
    python3 -m http.server 4001 &
    echo $! > /tmp/pleroma_mock.pid
    echo "Pleroma mock server started (PID: $(cat /tmp/pleroma_mock.pid))"
    echo "Access it at: http://localhost:4001"
elif command -v node &> /dev/null; then
    echo "Node.js found. Please install a simple HTTP server or use Python."
    exit 1
else
    echo "Neither Python3 nor Node.js found. Please install one of them."
    exit 1
fi






