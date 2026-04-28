#!/bin/bash
set -euo pipefail

echo "=== Platform Health Check ==="
echo "Stage:        ${STAGE_NAME:-unknown}"
echo "Git Revision: ${GIT_REVISION:-unknown}"
echo "Timestamp:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

if [ -z "${GIT_REVISION:-}" ]; then
  echo "FAIL: GIT_REVISION is not set"
  exit 1
fi

if [ "${GIT_REVISION}" = "a1b2c3d4e5f6" ]; then
  echo "WARN: GIT_REVISION is still the initial placeholder value"
fi

echo "Checking platform health..."
sleep 3

if [ "${FORCE_FAIL:-}" = "true" ]; then
  echo "FAIL: FORCE_FAIL=true — simulating verification failure"
  exit 1
fi

echo "PASS: Platform health check succeeded"
exit 0
