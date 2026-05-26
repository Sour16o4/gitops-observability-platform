#!/usr/bin/env bash
# ==============================================================================
# load-test.sh — Generate synthetic traffic to demo-app for dashboard visualization
# ==============================================================================
# This script sends continuous requests to http://localhost/ to generate
# rate, latency, and error metrics in Prometheus, and log entries in Loki.
# ==============================================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "=================================================="
echo "  GitOps Observability Platform — Load Generator  "
echo "=================================================="
echo "Press [CTRL+C] to stop the load generator."
echo ""

# Infinite loop sending requests with dynamic sleep/error rates
count=0
while true; do
    count=$((count+1))
    
    # 85% of traffic is normal GET / (status 200)
    # 10% is /health
    # 5% is a non-existent path (status 404)
    rand=$((RANDOM % 100))
    
    if [ $rand -lt 85 ]; then
        path=""
    elif [ $rand -lt 95 ]; then
        path="health"
    else
        path="invalid-route-error"
    fi
    
    # Run request in background so we can parallelize or scale quickly
    url="http://localhost/${path}"
    status=$(curl -s -o /dev/null -w "%{http_code}" "$url" || echo "FAILED")
    
    if [ "$status" = "200" ]; then
        echo -e "[Request #${count}] GET ${url} -> ${GREEN}${status}${NC}"
    else
        echo -e "[Request #${count}] GET ${url} -> \033[0;31m${status}\033[0m"
    fi
    
    # Dynamic sleep between 50ms and 500ms
    sleep_time=$(awk -v min=0.05 -v max=0.5 'BEGIN{srand(); print min+rand()*(max-min)}')
    sleep "$sleep_time"
done
