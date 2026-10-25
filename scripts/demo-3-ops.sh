#!/bin/sh
. "$(dirname "$0")/lib.sh"
SA="system:serviceaccount:$NS:frontend-scaler"

step "3.1 node-exporter на каждой ноде, включая control-plane"
run "kubectl apply -f k8s/60-node-exporter.yaml"
run "kubectl -n monitoring rollout status ds/node-exporter --timeout=120s"
run "kubectl get nodes -o wide"
run "kubectl -n monitoring get ds,pods -o wide"
note "метрики снимаются с каждой ноды по её IP, порт 9100 (hostNetwork):"
for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  run "curl -s http://$ip:9100/metrics | grep -E '^node_uname_info|^node_load1 |^node_memory_MemAvailable_bytes'"
done

step "3.1 агент занимает минимум ресурсов"
run "kubectl -n monitoring get ds node-exporter -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo"
IP="$(kubectl get node course-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
run "curl -s http://$IP:9100/metrics | grep -E '^process_resident_memory_bytes|^process_cpu_seconds_total|^go_goroutines'"
run "kubectl -n monitoring get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount"

step "3.2 CronJob масштабирует frontend в 9:00 и 18:00 по Москве"
run "kubectl apply -f k8s/70-frontend-scaler.yaml"
run "kubectl -n $NS get cronjob -o custom-columns=NAME:.metadata.name,SCHEDULE:.spec.schedule,TZ:.spec.timeZone,SA:.spec.jobTemplate.spec.template.spec.serviceAccountName,ARGS:.spec.jobTemplate.spec.template.spec.containers[0].args"
run "kubectl -n $NS get role frontend-scaler -o yaml | sed -n '/^rules:/,\$p'"

step "3.2 что автоматике разрешено и что запрещено"
note "clustertrustbundles и selfsubject* есть у любого аутентифицированного пользователя (system:basic-user), это не наша Role"
run "kubectl auth can-i --list -n $NS --as=$SA | grep -vE 'selfsubject|^ *(/|\\[)' "
for c in \
  "get deployments.apps/frontend" \
  "patch deployments.apps/frontend --subresource=scale" \
  "update deployments.apps/frontend --subresource=scale" \
  "patch deployments.apps/frontend" \
  "delete deployments.apps/frontend" \
  "patch deployments.apps/backend --subresource=scale" \
  "get secrets" \
  "create pods" \
  "get pods"; do
  run "kubectl auth can-i $c -n $NS --as=$SA"
done
note "Role действует только в своём namespace:"
run "kubectl auth can-i patch deployments.apps/frontend --subresource=scale -n team-blue --as=$SA"
note "попытки сделать что-то кроме масштабирования frontend от имени этого ServiceAccount:"
run "kubectl -n $NS scale deploy/backend --replicas=3 --as=$SA"
run "kubectl -n $NS set image deploy/frontend frontend=nginx --as=$SA"
run "kubectl -n $NS get secret postgres-auth --as=$SA"

step "3.2 запуск вне расписания"
run "kubectl -n $NS get deploy frontend"
run "kubectl -n $NS create job scale-up-manual --from=cronjob/frontend-scale-up"
run "kubectl -n $NS wait --for=condition=Complete job/scale-up-manual --timeout=120s"
run "kubectl -n $NS logs job/scale-up-manual"
run "kubectl -n $NS rollout status deploy/frontend --timeout=180s && kubectl -n $NS get deploy frontend && kubectl -n $NS get pods -l app.kubernetes.io/name=frontend -o wide"
run "kubectl -n $NS create job scale-down-manual --from=cronjob/frontend-scale-down"
run "kubectl -n $NS wait --for=condition=Complete job/scale-down-manual --timeout=120s"
run "kubectl -n $NS logs job/scale-down-manual"
run "kubectl -n $NS get deploy frontend"
run "kubectl -n $NS get jobs"
finish
