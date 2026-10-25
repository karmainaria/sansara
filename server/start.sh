#!/usr/bin/env bash
# Starts the AI appraiser in the background and makes it public
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
cd /workspaces/sansara
pkill -f "node server/server.mjs" 2>/dev/null || true
nohup node server/server.mjs > server/appraiser.log 2>&1 &
sleep 3
gh codespace ports visibility 8787:public -c "$CODESPACE_NAME" >/dev/null 2>&1 \
  && echo "Port 8787 is public" \
  || echo "Make port 8787 public: Ports tab > right-click 8787 > Port Visibility > Public"
curl -s localhost:8787/health; echo
tail -n 3 server/appraiser.log
