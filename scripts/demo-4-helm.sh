#!/bin/sh
. "$(dirname "$0")/lib.sh"

ca() {
  kubectl -n "$2" get secret "$1-counter-tls" -o jsonpath='{.data.ca\.crt}' | base64 -d >"/tmp/$1-ca.crt"
}

step "4.1 проверка чарта"
run "helm lint charts/counter"
run "ls charts/counter/templates"

step "4.1 две установки одной командой в разные namespace под разными именами"
run "helm install blue charts/counter -n team-blue --create-namespace --wait --timeout 5m"
run "helm install green charts/counter -n team-green --create-namespace -f charts/examples/values-green.yaml --wait --timeout 5m"
run "helm list -A"
run "kubectl get deploy,svc,ingress,certificate -n team-blue; echo; kubectl get deploy,svc,ingress,certificate -n team-green"

step "4.1 у каждой установки свой адрес, свой сертификат и своё состояние"
ca blue team-blue; ca green team-green
run "curl -sS --cacert /tmp/blue-ca.crt -X POST https://blue.localtest.me/api/counter; echo"
run "curl -sS --cacert /tmp/blue-ca.crt -X POST https://blue.localtest.me/api/counter; echo"
run "curl -sS --cacert /tmp/green-ca.crt https://green.localtest.me/api/counter; echo"
run "curl -sS --cacert /tmp/green-ca.crt -o /dev/null -w '%{http_code}\\n' https://green.localtest.me/"
note "сертификаты разных релизов выпущены разными CA — CA blue не подходит к green:"
run "curl -sS --cacert /tmp/blue-ca.crt https://green.localtest.me/api/counter"
note "в green backend на порту 9191 и по 2 экземпляра — заданы только параметрами:"
run "kubectl -n team-green get pods -o wide; kubectl -n team-green logs deploy/green-counter-backend | grep -i 'running on'"

step "4.1 третья установка в тот же namespace — тоже не конфликтует"
run "helm install blue-canary charts/counter -n team-blue --set ingress.host=canary.localtest.me --wait --timeout 5m"
ca blue-canary team-blue
run "curl -sS --cacert /tmp/blue-canary-ca.crt https://canary.localtest.me/api/counter; echo"
run "kubectl -n team-blue get deploy"
run "helm uninstall blue-canary -n team-blue"

step "4.2 после установки релиз проверяется автоматически (post-install hook)"
run "kubectl -n team-blue get job blue-counter-verify -o jsonpath='{.metadata.annotations.helm\\.sh/hook}'; echo"
run "kubectl -n team-blue logs job/blue-counter-verify"

step "4.2 смена конфигурации через параметры перезапускает экземпляры сама"
run "kubectl -n team-blue get pods -l app.kubernetes.io/component=backend -o custom-columns=POD:.metadata.name,CHECKSUM:.metadata.annotations.checksum/config,START:.status.startTime"
run "helm upgrade blue charts/counter -n team-blue --reuse-values --set backend.port=9292 --set backend.extraConfig.LOG_LEVEL=debug --wait --timeout 5m"
run "kubectl -n team-blue get pods -l app.kubernetes.io/component=backend -o custom-columns=POD:.metadata.name,CHECKSUM:.metadata.annotations.checksum/config,START:.status.startTime"
run "kubectl -n team-blue get configmap blue-counter-backend -o jsonpath='{.data}'; echo"
run "kubectl -n team-blue logs deploy/blue-counter-backend | grep -i 'running on'"
run "kubectl -n team-blue logs job/blue-counter-verify"

step "4.2 неудачное обновление (несуществующий образ) откатывается само, сервис работает"
run "helm upgrade blue charts/counter -n team-blue --reuse-values --set backend.image.tag=9.9.9-does-not-exist --atomic --timeout 90s"
run "kubectl -n team-blue get pods -l app.kubernetes.io/component=backend -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready"
run "curl -sS --cacert /tmp/blue-ca.crt https://blue.localtest.me/api/counter; echo"

step "4.2 история и откат на предыдущую ревизию"
run "helm history blue -n team-blue"
run "helm get values blue -n team-blue --revision 1; helm get values blue -n team-blue"
run "helm rollback blue 1 -n team-blue --wait --timeout 5m"
run "helm history blue -n team-blue"
run "kubectl -n team-blue get configmap blue-counter-backend -o jsonpath='{.data}'; echo"
run "kubectl -n team-blue logs deploy/blue-counter-backend | grep -i 'running on'"
run "kubectl -n team-blue logs job/blue-counter-verify"
run "curl -sS --cacert /tmp/blue-ca.crt https://blue.localtest.me/api/counter; echo"
finish
