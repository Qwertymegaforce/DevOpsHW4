#!/bin/sh
. "$(dirname "$0")/lib.sh"
SQL="kubectl -n $NS exec pg-client -- psql -h postgres-0.postgres -v ON_ERROR_STOP=1"

step "2.3 пароль генерируется случайно при установке и не хранится в репозитории"
run "cat scripts/create-db-secret.sh"
run "./scripts/create-db-secret.sh"
note "значение пароля не печатаем — только ключи и длину:"
run "kubectl -n $NS get secret postgres-auth -o go-template='{{range \$k, \$v := .data}}{{\$k}}: {{len (\$v | base64decode)}} символов{{\"\\n\"}}{{end}}'"
note "в репозитории пароля нет: в манифестах только ссылки на Secret"
run "grep -rn -i 'password' k8s/ charts/ | grep -v '^charts/counter/templates/NOTES'"

step "Установка БД"
run "kubectl apply -f k8s/50-postgres.yaml"
run "kubectl -n $NS rollout status statefulset/postgres --timeout=180s"
run "kubectl -n $NS get statefulset,pod,svc,pvc -l app.kubernetes.io/name=postgres -o wide; kubectl -n $NS get pvc"

step "2.3 таблица создана автоматически при первом запуске (init-скрипт из ConfigMap)"
run "kubectl -n $NS logs postgres-0 | grep -E 'docker-entrypoint-initdb.d|CREATE TABLE|INSERT|ready to accept' | head"
run "kubectl apply -f k8s/tools/pg-client.yaml && kubectl -n $NS wait --for=condition=Ready pod/pg-client --timeout=300s"
run "$SQL -c '\\d counter'"

step "2.2 стабильное сетевое имя, другой под подключается по имени и выполняет запрос"
run "kubectl -n $NS get svc postgres -o custom-columns=NAME:.metadata.name,CLUSTER-IP:.spec.clusterIP,PORT:.spec.ports[0].port"
run "kubectl -n $NS exec pg-client -- nslookup postgres-0.postgres.$NS.svc.cluster.local"
run "$SQL -c 'select inet_server_addr() as server_ip, current_user, current_database(), version()'"

step "2.1 данные переживают удаление пода"
run "$SQL -c 'update counter set value = 42 where id = 1 returning *'"
OLDIP="$(kubectl -n $NS get pod postgres-0 -o jsonpath='{.status.podIP}')"
run "kubectl -n $NS delete pod postgres-0"
run "kubectl -n $NS wait --for=condition=Ready pod/postgres-0 --timeout=120s"
note "IP пода сменился ($OLDIP -> $(kubectl -n $NS get pod postgres-0 -o jsonpath='{.status.podIP}')), имя то же:"
run "kubectl -n $NS exec pg-client -- nslookup postgres-0.postgres.$NS.svc.cluster.local | grep -A1 '^Name'"
run "$SQL -c 'select * from counter'"

step "2.1 данные переживают удаление и повторное создание StatefulSet"
run "kubectl -n $NS get statefulset postgres -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}'; echo"
run "kubectl -n $NS delete statefulset postgres --wait=true"
run "kubectl -n $NS get statefulset,pods -l app.kubernetes.io/name=postgres; kubectl -n $NS get pvc"
run "kubectl apply -f k8s/50-postgres.yaml && kubectl -n $NS rollout status statefulset/postgres --timeout=180s"
run "$SQL -c 'select * from counter'"

step "Где физически лежат данные"
PV="$(kubectl -n $NS get pvc data-postgres-0 -o jsonpath='{.spec.volumeName}')"
run "kubectl get pv $PV -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,STORAGECLASS:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,PATH:.spec.hostPath.path,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]"
DIR="$(kubectl get pv $PV -o jsonpath='{.spec.hostPath.path}')"
N="$(kubectl get pv $PV -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')"
run "docker exec $N ls $DIR/pgdata | head -5"
run "kubectl get storageclass"

NSD=counter-nsdel
PSQL="kubectl -n $NSD exec postgres-0 -- psql -U counter -d counter -v ON_ERROR_STOP=1"
install_nsdel() {
  run "kubectl create namespace $NSD"
  run "NAMESPACE=$NSD ./scripts/create-db-secret.sh"
  run "kubectl apply -f /tmp/postgres-$NSD.yaml"
  run "kubectl -n $NSD rollout status statefulset/postgres --timeout=180s"
}
step "Вопрос 2: удаление namespace удаляет и данные"
note "тот же манифест в отдельном namespace $NSD, чтобы counter остался для следующих заданий"
run "sed 's/namespace: counter\$/namespace: $NSD/' k8s/50-postgres.yaml >/tmp/postgres-$NSD.yaml"
run "grep -n 'namespace:' /tmp/postgres-$NSD.yaml"
install_nsdel
run "$PSQL -c 'update counter set value = 42 where id = 1 returning *'"
PV="$(kubectl -n $NSD get pvc data-postgres-0 -o jsonpath='{.spec.volumeName}')"
DIR="$(kubectl get pv $PV -o jsonpath='{.spec.hostPath.path}')"
N="$(kubectl get pv $PV -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')"
run "kubectl get pv $PV -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]"
run "docker exec $N ls -d $DIR"
run "kubectl delete namespace $NSD --wait=true --timeout=180s"
i=0
while { kubectl get pv "$PV" >/dev/null 2>&1 || docker exec "$N" test -e "$DIR"; } && [ "$i" -lt 120 ]; do i=$((i + 1)); sleep 1; done
run "kubectl get pv $PV"
run "docker exec $N ls -d $DIR"
note "namespace с тем же именем и тем же манифестом — база снова пустая:"
install_nsdel
run "$PSQL -c 'select * from counter'"
kubectl delete namespace "$NSD" --wait=false >/dev/null
finish
