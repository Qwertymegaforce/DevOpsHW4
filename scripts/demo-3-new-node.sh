#!/bin/sh
. "$(dirname "$0")/lib.sh"
NEW="${1:-course-worker4}"

if [ "$(sysctl -n fs.inotify.max_user_instances)" -lt 512 ]; then
  echo "нужно: sudo sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288" >&2
  exit 1
fi

step "3.1 на новой ноде агент появляется автоматически"
run "sysctl fs.inotify.max_user_instances"
run "kubectl get nodes"
run "kubectl -n monitoring get ds node-exporter"
note "добавляем новую ноду — в манифестах ничего не меняем и ничего не применяем:"
run "./scripts/add-kind-node.sh $NEW"
run "kubectl wait --for=condition=Ready node/$NEW --timeout=180s"
run "kubectl -n monitoring rollout status ds/node-exporter --timeout=180s"
run "kubectl get nodes -o wide"
run "kubectl -n monitoring get ds node-exporter; kubectl -n monitoring get pods -o wide"
IP="$(kubectl get node $NEW -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
run "curl -s http://$IP:9100/metrics | grep -E '^node_uname_info|^node_load1 '"
finish
