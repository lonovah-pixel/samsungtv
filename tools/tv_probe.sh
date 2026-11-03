#!/usr/bin/env bash
# Read-only probe of a Samsung Smart TV over the local network.
# Does NOT write anything to the TV. Only HTTP GETs to the documented
# Smart View / remote-control REST endpoint and a TCP port check.
#
# Usage: ./tv_probe.sh <TV_IP>
# Output: tv_probe_<ip>_<timestamp>.txt in the current directory.
set -euo pipefail
IP="${1:?Usage: $0 <TV_IP>}"
OUT="tv_probe_${IP}_$(date +%Y%m%d_%H%M%S).txt"

{
  echo "== Samsung TV read-only probe: $IP  ($(date -Is))"
  echo
  echo "== GET http://$IP:8001/api/v2/  (device info: model, OS, firmware, resolution)"
  curl -s --max-time 5 "http://$IP:8001/api/v2/" || echo "(no answer on 8001 — TV off, other subnet, or API disabled)"
  echo; echo
  echo "== Open TCP ports (common Tizen services; no payload sent)"
  for p in 7676 8001 8002 8080 9197 26101; do
    if timeout 2 bash -c "</dev/tcp/$IP/$p" 2>/dev/null; then echo "  $p open"; else echo "  $p closed/filtered"; fi
  done
} | tee "$OUT"

echo
echo "Saved to $OUT. Send this file (or the 'device' JSON block) back for analysis."
