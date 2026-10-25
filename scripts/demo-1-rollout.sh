#!/bin/sh
. "$(dirname "$0")/lib.sh"

step "1.5 ресурсы: requests = limits у каждого контейнера, QoS Guaranteed"
run "kubectl -n $NS get pods -o custom-columns=POD:.metadata.name,QOS:.status.qosClass,REQ:.spec.containers[*].resources.requests,LIM:.spec.containers[*].resources.limits"
note "фактическое потребление (из containerd на нодах; metrics-server в kind нет) — запас по памяти 2-3 раза:"
run "./scripts/pod-usage.sh $NS"
run "kubectl -n $NS describe limitrange container-limits"
note "контейнер без resources получает значения по умолчанию из LimitRange (server-side dry-run проходит admission):"
run "kubectl -n $NS run no-resources --image=busybox:1.36 --restart=Never --dry-run=server -o jsonpath='{.spec.containers[0].resources}'; echo"
note "контейнер с лимитом больше разрешённого максимума не создаётся:"
run "kubectl -n $NS run greedy --image=busybox:1.36 --restart=Never --overrides='{\"spec\":{\"containers\":[{\"name\":\"greedy\",\"image\":\"busybox:1.36\",\"resources\":{\"limits\":{\"memory\":\"4Gi\"}}}]}}'"
note "контейнер, который пытается съесть 300 МБ при лимите 64Mi, убивается OOM killer, нода не страдает:"
run "kubectl -n $NS run memhog --image=counter-backend:1.0.0 --restart=Never --overrides='{\"spec\":{\"containers\":[{\"name\":\"memhog\",\"image\":\"counter-backend:1.0.0\",\"command\":[\"python\",\"-c\",\"x = bytearray(300 * 1024 * 1024); print(len(x))\"],\"resources\":{\"limits\":{\"memory\":\"64Mi\",\"cpu\":\"100m\"}}}]}}'"
kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Failed pod/memhog --timeout=60s >/dev/null 2>&1
run "kubectl -n $NS get pod memhog -o jsonpath='{.status.containerStatuses[0].state.terminated}'; echo"
run "kubectl -n $NS delete pod memhog --wait=false"
run "kubectl describe nodes | grep -A8 'Allocated resources'"

step "1.6 выкатка без простоя, сломанная версия, откат, история"
run "kubectl -n $NS get deploy backend -o jsonpath='strategy={.spec.strategy} minReadySeconds={.spec.minReadySeconds} progressDeadlineSeconds={.spec.progressDeadlineSeconds}'; echo"
run "kubectl -n $NS rollout history deploy/backend"
note "версия 1.0.1 — тот же образ 1.0.0 под новым тегом"
run "docker tag counter-backend:1.0.0 counter-backend:1.0.1 && kind load docker-image counter-backend:1.0.1 --name course 2>&1 | tail -1"
loop 45 /tmp/rollout-ok.txt &
LOOP=$!
sleep 3
run "kubectl -n $NS set image deploy/backend backend=counter-backend:1.0.1"
run "kubectl -n $NS annotate deploy/backend kubernetes.io/change-cause='upgrade to counter-backend:1.0.1' --overwrite"
run "kubectl -n $NS rollout status deploy/backend --timeout=120s"
wait $LOOP
note "запросы через ingress во время выкатки (по 4 в секунду), сгруппированы по HTTP-коду:"
run "awk '{print \$NF}' /tmp/rollout-ok.txt | sort | uniq -c"
run "kubectl -n $NS get rs -l app.kubernetes.io/name=backend -o wide"

note "выкатываем заведомо сломанную версию — несуществующий тег"
loop 80 /tmp/rollout-broken.txt &
LOOP=$!
sleep 3
run "kubectl -n $NS set image deploy/backend backend=counter-backend:9.9.9-does-not-exist"
run "kubectl -n $NS annotate deploy/backend kubernetes.io/change-cause='upgrade to counter-backend:9.9.9-does-not-exist (broken on purpose)' --overwrite"
run "kubectl -n $NS rollout status deploy/backend --timeout=90s"
run "kubectl -n $NS get pods -l app.kubernetes.io/name=backend"
run "kubectl -n $NS get deploy backend -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{\"\\n\"}{end}'"
wait $LOOP
note "сервис всё это время отвечал старой версией:"
run "awk '{print \$NF}' /tmp/rollout-broken.txt | sort | uniq -c"
run "kubectl -n $NS rollout history deploy/backend"
run "kubectl -n $NS rollout undo deploy/backend"
run "kubectl -n $NS wait deploy/backend --for=condition=Progressing --timeout=60s"
run "kubectl -n $NS rollout status deploy/backend --timeout=120s"
settle backend
run "kubectl -n $NS get pods -l app.kubernetes.io/name=backend -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready"
run "kubectl -n $NS rollout history deploy/backend"
LAST="$(kubectl -n $NS rollout history deploy/backend | awk 'NF && $1 ~ /^[0-9]+$/ {r=$1} END {print r}')"
run "kubectl -n $NS rollout history deploy/backend --revision=$LAST | head -8"
run "curl -sS --cacert ca.crt https://$HOST/api/counter; echo"
finish
