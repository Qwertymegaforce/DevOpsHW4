#!/bin/sh
. "$(dirname "$0")/lib.sh"

step "Вопрос 1: backend в трёх экземплярах"
run "kubectl -n $NS scale deploy/backend --replicas=3 && kubectl -n $NS rollout status deploy/backend --timeout=120s"
run "kubectl -n $NS get pods -l app.kubernetes.io/name=backend -o wide"
run "for i in 1 2 3 4 5 6; do curl -sS --cacert ca.crt -X POST https://$HOST/api/counter; echo; done"
run "for i in 1 2 3 4 5 6; do curl -sS --cacert ca.crt https://$HOST/api/counter; echo; done"
note "у каждого пода свой счётчик:"
for p in $(kubectl -n $NS get pods -l app.kubernetes.io/name=backend -o name); do
  run "kubectl -n $NS exec $p -- python -c 'import urllib.request as u; print(u.urlopen(\"http://127.0.0.1:9090/api/counter\").read().decode())'"
done
run "kubectl -n $NS scale deploy/backend --replicas=1 && kubectl -n $NS rollout status deploy/backend"
settle backend

step "Вопрос 2: когда работающий под увидит изменения ConfigMap"
POD="$(kubectl -n $NS get pod -l app.kubernetes.io/name=backend -o jsonpath='{.items[0].metadata.name}')"
run "kubectl -n $NS patch configmap backend --type merge -p '{\"data\":{\"FEATURE_FLAG\":\"on\"}}'"
run "sleep 70; kubectl -n $NS exec $POD -- printenv FEATURE_FLAG || echo 'переменной нет: env читается только при старте контейнера'"
run "kubectl -n $NS rollout restart deploy/backend && kubectl -n $NS rollout status deploy/backend --timeout=120s"
settle backend
run "kubectl -n $NS exec deploy/backend -- printenv FEATURE_FLAG"
note "для сравнения: тот же ConfigMap, смонтированный томом, обновляется в работающем поде сам (через ~1 минуту)"
run "kubectl -n $NS run cm-volume --image=busybox:1.36 --restart=Never --overrides='{\"spec\":{\"containers\":[{\"name\":\"c\",\"image\":\"busybox:1.36\",\"command\":[\"sleep\",\"600\"],\"volumeMounts\":[{\"name\":\"cfg\",\"mountPath\":\"/cfg\"}]}],\"volumes\":[{\"name\":\"cfg\",\"configMap\":{\"name\":\"backend\"}}]}}' && kubectl -n $NS wait --for=condition=Ready pod/cm-volume --timeout=60s"
run "kubectl -n $NS exec cm-volume -- cat /cfg/FEATURE_FLAG; echo"
run "kubectl -n $NS patch configmap backend --type merge -p '{\"data\":{\"FEATURE_FLAG\":\"off\"}}'"
run "for i in \$(seq 1 30); do v=\$(kubectl -n $NS exec cm-volume -- cat /cfg/FEATURE_FLAG); [ \"\$v\" = off ] && { echo \"через ~\$((i*5)) с файл в томе: \$v\"; break; }; sleep 5; done"
run "kubectl -n $NS exec deploy/backend -- printenv FEATURE_FLAG"
run "kubectl -n $NS delete pod cm-volume --wait=false"
note "возвращаем ConfigMap как в репозитории (kubectl apply не удалит ключ, которого не было в last-applied, поэтому патчем)"
run "kubectl -n $NS patch configmap backend --type json -p '[{\"op\":\"remove\",\"path\":\"/data/FEATURE_FLAG\"}]' && kubectl -n $NS rollout restart deploy/backend && kubectl -n $NS rollout status deploy/backend --timeout=120s && kubectl -n $NS get configmap backend -o jsonpath='{.data}'"
finish
