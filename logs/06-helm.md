
#### 4.1 проверка чарта

```console
$ helm lint charts/counter
==> Linting charts/counter
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed

$ ls charts/counter/templates
backend.yaml
configmap.yaml
frontend.yaml
_helpers.tpl
ingress.yaml
NOTES.txt
postgres.yaml
scaler.yaml
tls.yaml
verify-hook.yaml

```

#### 4.1 две установки одной командой в разные namespace под разными именами

```console
$ helm install blue charts/counter -n team-blue --create-namespace --wait --timeout 5m
NAME: blue
LAST DEPLOYED: Sun Oct 25 11:29:27 2026
NAMESPACE: team-blue
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
Релиз blue установлен в namespace team-blue.

Адрес:  https://blue.localtest.me
Проверка сертификата без -k:
  kubectl -n team-blue get secret blue-counter-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/blue-ca.crt
  curl --cacert /tmp/blue-ca.crt https://blue.localtest.me/api/counter

$ helm install green charts/counter -n team-green --create-namespace -f charts/examples/values-green.yaml --wait --timeout 5m
NAME: green
LAST DEPLOYED: Sun Oct 25 11:30:21 2026
NAMESPACE: team-green
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
Релиз green установлен в namespace team-green.

Адрес:  https://green.localtest.me
Проверка сертификата без -k:
  kubectl -n team-green get secret green-counter-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/green-ca.crt
  curl --cacert /tmp/green-ca.crt https://green.localtest.me/api/counter

$ helm list -A
NAME        	NAMESPACE   	REVISION	UPDATED                                	STATUS  	CHART               	APP VERSION
blue        	team-blue   	1       	2026-10-25 11:29:27.979965984 +0300 MSK	deployed	counter-0.1.0       	1.0.0      
cert-manager	cert-manager	1       	2026-10-24 09:47:32.72033828 +0300 MSK 	deployed	cert-manager-v1.21.3	v1.21.3    
green       	team-green  	1       	2026-10-25 11:30:21.147960009 +0300 MSK	deployed	counter-0.1.0       	1.0.0      

$ kubectl get deploy,svc,ingress,certificate -n team-blue; echo; kubectl get deploy,svc,ingress,certificate -n team-green
NAME                                    READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/blue-counter-backend    1/1     1            1           84s
deployment.apps/blue-counter-frontend   1/1     1            1           84s

NAME                            TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/blue-counter-backend    ClusterIP   10.96.124.12    <none>        80/TCP    84s
service/blue-counter-frontend   ClusterIP   10.96.239.158   <none>        80/TCP    84s

NAME                                     CLASS   HOSTS               ADDRESS     PORTS     AGE
ingress.networking.k8s.io/blue-counter   nginx   blue.localtest.me   localhost   80, 443   83s

NAME                                           READY   SECRET             AGE
certificate.cert-manager.io/blue-counter-ca    True    blue-counter-ca    80s
certificate.cert-manager.io/blue-counter-tls   True    blue-counter-tls   80s

NAME                                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/green-counter-backend    2/2     2            2           31s
deployment.apps/green-counter-frontend   2/2     2            2           31s

NAME                             TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
service/green-counter-backend    ClusterIP   10.96.34.245   <none>        80/TCP    31s
service/green-counter-frontend   ClusterIP   10.96.72.183   <none>        80/TCP    31s

NAME                                      CLASS   HOSTS                ADDRESS     PORTS     AGE
ingress.networking.k8s.io/green-counter   nginx   green.localtest.me   localhost   80, 443   31s

NAME                                            READY   SECRET              AGE
certificate.cert-manager.io/green-counter-ca    True    green-counter-ca    30s
certificate.cert-manager.io/green-counter-tls   True    green-counter-tls   30s

```

#### 4.1 у каждой установки свой адрес, свой сертификат и своё состояние

```console
$ curl -sS --cacert /tmp/blue-ca.crt -X POST https://blue.localtest.me/api/counter; echo
{"count": 1}

$ curl -sS --cacert /tmp/blue-ca.crt -X POST https://blue.localtest.me/api/counter; echo
{"count": 2}

$ curl -sS --cacert /tmp/green-ca.crt https://green.localtest.me/api/counter; echo
{"count": 0}

$ curl -sS --cacert /tmp/green-ca.crt -o /dev/null -w '%{http_code}\n' https://green.localtest.me/
200

# сертификаты разных релизов выпущены разными CA — CA blue не подходит к green:
$ curl -sS --cacert /tmp/blue-ca.crt https://green.localtest.me/api/counter
curl: (60) SSL certificate problem: unable to get local issuer certificate
More details here: https://curl.se/docs/sslcerts.html

curl failed to verify the legitimacy of the server and therefore could not
establish a secure connection to it. To learn more about this situation and
how to fix it, please visit the web page mentioned above.

# в green backend на порту 9191 и по 2 экземпляра — заданы только параметрами:
$ kubectl -n team-green get pods -o wide; kubectl -n team-green logs deploy/green-counter-backend | grep -i 'running on'
NAME                                      READY   STATUS      RESTARTS   AGE   IP            NODE             NOMINATED NODE   READINESS GATES
green-counter-backend-67ddb64bbf-96p9v    1/1     Running     0          31s   10.244.5.6    course-worker4   <none>           <none>
green-counter-backend-67ddb64bbf-m4jbz    1/1     Running     0          31s   10.244.2.52   course-worker    <none>           <none>
green-counter-frontend-5b8cbbb9b6-65q4w   1/1     Running     0          31s   10.244.2.53   course-worker    <none>           <none>
green-counter-frontend-5b8cbbb9b6-r2hql   1/1     Running     0          31s   10.244.5.5    course-worker4   <none>           <none>
green-counter-verify-jklsx                0/1     Completed   0          9s    10.244.5.7    course-worker4   <none>           <none>
Found 2 pods, using pod/green-counter-backend-67ddb64bbf-96p9v
======== Running on http://0.0.0.0:9191 ========

```

#### 4.1 третья установка в тот же namespace — тоже не конфликтует

```console
$ helm install blue-canary charts/counter -n team-blue --set ingress.host=canary.localtest.me --wait --timeout 5m
NAME: blue-canary
LAST DEPLOYED: Sun Oct 25 11:30:54 2026
NAMESPACE: team-blue
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
Релиз blue-canary установлен в namespace team-blue.

Адрес:  https://canary.localtest.me
Проверка сертификата без -k:
  kubectl -n team-blue get secret blue-canary-counter-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/blue-canary-ca.crt
  curl --cacert /tmp/blue-canary-ca.crt https://canary.localtest.me/api/counter

$ curl -sS --cacert /tmp/blue-canary-ca.crt https://canary.localtest.me/api/counter; echo
{"count": 0}

$ kubectl -n team-blue get deploy
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
blue-canary-counter-backend    1/1     1            1           26s
blue-canary-counter-frontend   1/1     1            1           26s
blue-counter-backend           1/1     1            1           112s
blue-counter-frontend          1/1     1            1           112s

$ helm uninstall blue-canary -n team-blue
release "blue-canary" uninstalled

```

#### 4.2 после установки релиз проверяется автоматически (post-install hook)

```console
$ kubectl -n team-blue get job blue-counter-verify -o jsonpath='{.metadata.annotations.helm\.sh/hook}'; echo
post-install,post-upgrade,post-rollback

$ kubectl -n team-blue logs job/blue-counter-verify
backend:  GET /api/counter
{"count": 0}
frontend: GET /
200
ingress:  GET https://blue.localtest.me/api/counter (сертификат проверяется CA релиза)
{"count": 0}
OK: release blue is healthy

```

#### 4.2 смена конфигурации через параметры перезапускает экземпляры сама

```console
$ kubectl -n team-blue get pods -l app.kubernetes.io/component=backend -o custom-columns=POD:.metadata.name,CHECKSUM:.metadata.annotations.checksum/config,START:.status.startTime
POD                                           CHECKSUM                                                           START
blue-canary-counter-backend-78b674685-5gpg4   2cae05375a08fb8b347f1440b718c57afe63a026c539e31c4cab3be7d6d18323   2026-10-25T08:30:56Z
blue-counter-backend-74746cd6df-h2mk9         30c63231655e94220cd36613345c32d5abf32d53e7e6bc3adf44977c127224ee   2026-10-25T08:29:33Z

$ helm upgrade blue charts/counter -n team-blue --reuse-values --set backend.port=9292 --set backend.extraConfig.LOG_LEVEL=debug --wait --timeout 5m
Release "blue" has been upgraded. Happy Helming!
NAME: blue
LAST DEPLOYED: Sun Oct 25 11:31:24 2026
NAMESPACE: team-blue
STATUS: deployed
REVISION: 2
TEST SUITE: None
NOTES:
Релиз blue установлен в namespace team-blue.

Адрес:  https://blue.localtest.me
Проверка сертификата без -k:
  kubectl -n team-blue get secret blue-counter-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/blue-ca.crt
  curl --cacert /tmp/blue-ca.crt https://blue.localtest.me/api/counter

$ kubectl -n team-blue get pods -l app.kubernetes.io/component=backend -o custom-columns=POD:.metadata.name,CHECKSUM:.metadata.annotations.checksum/config,START:.status.startTime
POD                                     CHECKSUM                                                           START
blue-counter-backend-57b78f6479-5s6pv   2d2deb3f72f7e7d1538864edd1c09d81320c8319de4123f29f07870cb74e2e0a   2026-10-25T08:31:26Z

$ kubectl -n team-blue get configmap blue-counter-backend -o jsonpath='{.data}'; echo
{"HOST":"0.0.0.0","LOG_LEVEL":"debug","PORT":"9292","PYTHONUNBUFFERED":"1"}

$ kubectl -n team-blue logs deploy/blue-counter-backend | grep -i 'running on'
======== Running on http://0.0.0.0:9292 ========

$ kubectl -n team-blue logs job/blue-counter-verify
backend:  GET /api/counter
{"count": 0}
frontend: GET /
200
ingress:  GET https://blue.localtest.me/api/counter (сертификат проверяется CA релиза)
{"count": 0}
OK: release blue is healthy

```

#### 4.2 неудачное обновление (несуществующий образ) откатывается само, сервис работает

```console
$ helm upgrade blue charts/counter -n team-blue --reuse-values --set backend.image.tag=9.9.9-does-not-exist --atomic --timeout 90s
Error: UPGRADE FAILED: release blue failed, and has been rolled back due to atomic being set: context deadline exceeded

$ kubectl -n team-blue get pods -l app.kubernetes.io/component=backend -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready
POD                                     IMAGE                   READY
blue-counter-backend-57b78f6479-5s6pv   counter-backend:1.0.0   true

$ curl -sS --cacert /tmp/blue-ca.crt https://blue.localtest.me/api/counter; echo
{"count": 0}

```

#### 4.2 история и откат на предыдущую ревизию

```console
$ helm history blue -n team-blue
REVISION	UPDATED                 	STATUS    	CHART        	APP VERSION	DESCRIPTION                                     
1       	Sun Oct 25 11:29:27 2026	superseded	counter-0.1.0	1.0.0      	Install complete                                
2       	Sun Oct 25 11:31:24 2026	superseded	counter-0.1.0	1.0.0      	Upgrade complete                                
3       	Sun Oct 25 11:31:48 2026	failed    	counter-0.1.0	1.0.0      	Upgrade "blue" failed: context deadline exceeded
4       	Sun Oct 25 11:33:20 2026	deployed  	counter-0.1.0	1.0.0      	Rollback to 2                                   

$ helm get values blue -n team-blue --revision 1; helm get values blue -n team-blue
USER-SUPPLIED VALUES:
null
USER-SUPPLIED VALUES:
backend:
  extraConfig:
    LOG_LEVEL: debug
  port: 9292

$ helm rollback blue 1 -n team-blue --wait --timeout 5m
Rollback was a success! Happy Helming!

$ helm history blue -n team-blue
REVISION	UPDATED                 	STATUS    	CHART        	APP VERSION	DESCRIPTION                                     
1       	Sun Oct 25 11:29:27 2026	superseded	counter-0.1.0	1.0.0      	Install complete                                
2       	Sun Oct 25 11:31:24 2026	superseded	counter-0.1.0	1.0.0      	Upgrade complete                                
3       	Sun Oct 25 11:31:48 2026	failed    	counter-0.1.0	1.0.0      	Upgrade "blue" failed: context deadline exceeded
4       	Sun Oct 25 11:33:20 2026	superseded	counter-0.1.0	1.0.0      	Rollback to 2                                   
5       	Sun Oct 25 11:33:32 2026	deployed  	counter-0.1.0	1.0.0      	Rollback to 1                                   

$ kubectl -n team-blue get configmap blue-counter-backend -o jsonpath='{.data}'; echo
{"HOST":"0.0.0.0","PORT":"9090","PYTHONUNBUFFERED":"1"}

$ kubectl -n team-blue logs deploy/blue-counter-backend | grep -i 'running on'
======== Running on http://0.0.0.0:9090 ========

$ kubectl -n team-blue logs job/blue-counter-verify
backend:  GET /api/counter
{"count": 0}
frontend: GET /
200
ingress:  GET https://blue.localtest.me/api/counter (сертификат проверяется CA релиза)
{"count": 0}
OK: release blue is healthy

$ curl -sS --cacert /tmp/blue-ca.crt https://blue.localtest.me/api/counter; echo
{"count": 0}

```
