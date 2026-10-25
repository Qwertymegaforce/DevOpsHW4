#!/bin/sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

helm uninstall blue -n team-blue >/dev/null 2>&1
helm uninstall green -n team-green >/dev/null 2>&1
kubectl delete ns counter monitoring team-blue team-green --ignore-not-found --wait=true

for d in 1-app:01-app 1-rollout:02-rollout 1-questions:03-questions 2-db:04-db 3-ops:05-ops 4-helm:06-helm 5-db-chart:07-db-chart; do
  echo "== demo-${d%%:*}"
  "./scripts/demo-${d%%:*}.sh" >"logs/${d##*:}.md" 2>&1
done
echo DONE
