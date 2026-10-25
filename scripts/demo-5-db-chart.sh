#!/bin/sh
. "$(dirname "$0")/lib.sh"
N=team-blue
PSQL="kubectl -n $N exec blue-counter-postgres-0 -- psql -U counter -d counter -v ON_ERROR_STOP=1"
pwhash() { kubectl -n $N get secret blue-counter-postgres-auth -o jsonpath='{.data.POSTGRES_PASSWORD}' | sha256sum | cut -c1-16; }

step "БД включается параметром postgres.enabled"
run "kubectl -n $N get statefulset,pvc,secret -l app.kubernetes.io/instance=blue"
run "helm upgrade blue charts/counter -n $N --reuse-values --set postgres.enabled=true --wait --timeout 5m"
run "kubectl -n $N get statefulset,pod,svc,pvc -l app.kubernetes.io/component=postgres; kubectl -n $N get pvc"
run "$PSQL -c 'update counter set value = 777 where id = 1 returning *'"
note "отпечаток пароля (sha256 от base64, сам пароль не показываем): $(pwhash)"

step "БД выключается параметром — StatefulSet удалён, PVC и Secret остались"
run "helm upgrade blue charts/counter -n $N --reuse-values --set postgres.enabled=false --wait --timeout 5m"
run "kubectl -n $N get statefulset,pods -l app.kubernetes.io/component=postgres; kubectl -n $N get pvc,secret -l app.kubernetes.io/component=postgres"
run "kubectl -n $N get pvc data-blue-counter-postgres-0"

step "Удаляем релиз целиком и ставим заново — данные на месте"
run "helm uninstall blue -n $N"
run "kubectl -n $N get all"
run "kubectl -n $N get pvc,secret"
run "helm install blue charts/counter -n $N --set postgres.enabled=true --wait --timeout 5m"
run "kubectl -n $N get statefulset,pod -l app.kubernetes.io/component=postgres"
run "$PSQL -c 'select * from counter'"
note "пароль тот же, что и до удаления релиза (иначе БД, инициализированная старым паролем, не пустила бы клиентов): $(pwhash)"
note "подключение по сети с паролем из Secret из другого пода:"
run "kubectl -n $N run psql-check --restart=Never --image=postgres:16-alpine --overrides='{\"spec\":{\"containers\":[{\"name\":\"psql-check\",\"image\":\"postgres:16-alpine\",\"command\":[\"psql\",\"-h\",\"blue-counter-postgres-0.blue-counter-postgres\",\"-c\",\"select value from counter\"],\"envFrom\":[{\"secretRef\":{\"name\":\"blue-counter-postgres-auth\"}}],\"env\":[{\"name\":\"PGUSER\",\"value\":\"counter\"},{\"name\":\"PGDATABASE\",\"value\":\"counter\"},{\"name\":\"PGPASSWORD\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"blue-counter-postgres-auth\",\"key\":\"POSTGRES_PASSWORD\"}}}]}]}}'"
run "kubectl -n $N wait --for=jsonpath='{.status.phase}'=Succeeded pod/psql-check --timeout=120s"
run "kubectl -n $N logs psql-check"
run "kubectl -n $N delete pod psql-check"
finish
