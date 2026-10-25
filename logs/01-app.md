
#### Установка манифестов

```console
$ kubectl apply -f k8s/00-namespace.yaml -f k8s/10-tls.yaml -f k8s/20-backend.yaml -f k8s/30-frontend.yaml -f k8s/40-ingress.yaml
namespace/counter created
limitrange/container-limits created
issuer.cert-manager.io/selfsigned created
certificate.cert-manager.io/counter-ca created
issuer.cert-manager.io/counter-ca created
certificate.cert-manager.io/counter-tls created
configmap/backend created
deployment.apps/backend created
service/backend created
deployment.apps/frontend created
service/frontend created
ingress.networking.k8s.io/counter created

$ kubectl -n counter wait --for=condition=Ready certificate/counter-tls --timeout=120s
certificate.cert-manager.io/counter-tls condition met

$ kubectl -n counter rollout status deploy/backend --timeout=180s && kubectl -n counter rollout status deploy/frontend --timeout=180s
Waiting for deployment "backend" rollout to finish: 0 of 1 updated replicas are available...
Waiting for deployment "backend" rollout to finish: 0 of 1 updated replicas are available...
deployment "backend" successfully rolled out
deployment "frontend" successfully rolled out

$ kubectl -n counter get deploy,rs,pods,svc,ingress,certificate,issuer -o wide
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES                   SELECTOR
deployment.apps/backend    1/1     1            1           24s   backend      counter-backend:1.0.0    app.kubernetes.io/name=backend
deployment.apps/frontend   1/1     1            1           23s   frontend     counter-frontend:1.0.0   app.kubernetes.io/name=frontend

NAME                                 DESIRED   CURRENT   READY   AGE   CONTAINERS   IMAGES                   SELECTOR
replicaset.apps/backend-5dc74878b5   1         1         1       24s   backend      counter-backend:1.0.0    app.kubernetes.io/name=backend,pod-template-hash=5dc74878b5
replicaset.apps/frontend-d4cff988f   1         1         1       23s   frontend     counter-frontend:1.0.0   app.kubernetes.io/name=frontend,pod-template-hash=d4cff988f

NAME                           READY   STATUS    RESTARTS   AGE   IP            NODE             NOMINATED NODE   READINESS GATES
pod/backend-5dc74878b5-jd62k   1/1     Running   0          24s   10.244.1.46   course-worker2   <none>           <none>
pod/frontend-d4cff988f-mn6fm   1/1     Running   0          23s   10.244.1.47   course-worker2   <none>           <none>

NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
service/backend    ClusterIP   10.96.132.215   <none>        80/TCP    24s   app.kubernetes.io/name=backend
service/frontend   ClusterIP   10.96.165.140   <none>        80/TCP    23s   app.kubernetes.io/name=frontend

NAME                                CLASS   HOSTS                  ADDRESS   PORTS     AGE
ingress.networking.k8s.io/counter   nginx   counter.localtest.me             80, 443   23s

NAME                                      READY   SECRET        ISSUER       STATUS                                          AGE
certificate.cert-manager.io/counter-ca    True    counter-ca    selfsigned   Certificate is up to date and has not expired   25s
certificate.cert-manager.io/counter-tls   True    counter-tls   counter-ca   Certificate is up to date and has not expired   24s

NAME                                READY   STATUS                AGE
issuer.cert-manager.io/counter-ca   True    Signing CA verified   25s
issuer.cert-manager.io/selfsigned   True                          25s

```

#### 1.1 HTTPS с собственным сертификатом, curl проверяет его без -k

```console
$ kubectl -n counter get secret counter-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt && openssl x509 -in ca.crt -noout -subject -issuer
subject=CN = counter-ca
issuer=CN = counter-ca

$ kubectl -n counter get secret counter-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -ext subjectAltName -dates
subject=
issuer=CN = counter-ca
X509v3 Subject Alternative Name: critical
    DNS:counter.localtest.me
notBefore=Oct 25 07:58:18 2026 GMT
notAfter=Jan 23 07:58:18 2027 GMT

# без нашего CA curl сертификату не доверяет:
$ curl -sS https://counter.localtest.me/ -o /dev/null
curl: (60) SSL certificate problem: unable to get local issuer certificate
More details here: https://curl.se/docs/sslcerts.html

curl failed to verify the legitimacy of the server and therefore could not
establish a secure connection to it. To learn more about this situation and
how to fix it, please visit the web page mentioned above.

# с нашим CA — проверка проходит:
$ curl -v --cacert ca.crt https://counter.localtest.me/ -o /dev/null 2>&1 | grep -E 'SSL connection|subject:|issuer:|SSL certificate verify|HTTP/2 [0-9]'
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / X25519 / id-ecPublicKey
*  subject: [NONE]
*  issuer: CN=counter-ca
*  SSL certificate verify ok.
< HTTP/2 200 

$ curl -sS --cacert ca.crt https://counter.localtest.me/ | grep -o '<button[^>]*>[^<]*</button>'
<button>Increment</button>

$ curl -sS --cacert ca.crt https://counter.localtest.me/api/counter; echo
{"count": 0}

$ for i in 1 2 3; do curl -sS --cacert ca.crt -X POST https://counter.localtest.me/api/counter; echo; done
{"count": 1}
{"count": 2}
{"count": 3}

$ curl -sS --cacert ca.crt https://counter.localtest.me/api/counter; echo
{"count": 3}

```

#### 1.2 backend снаружи доступен только через /api

```console
$ kubectl -n counter get svc -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,PORTS:.spec.ports[*].port
NAME       TYPE        CLUSTER-IP      PORTS
backend    ClusterIP   10.96.132.215   80
frontend   ClusterIP   10.96.165.140   80

$ kubectl -n counter get ingress counter -o jsonpath='{range .spec.rules[*].http.paths[*]}{.path}{" -> "}{.backend.service.name}{"\n"}{end}'
/api -> backend
/ -> frontend

# /api/* уходит в backend, всё остальное — во frontend (у него нет /counter, отсюда 404 от Next.js):
$ curl -s --cacert ca.crt -o /dev/null -w '%{http_code} %{content_type}\n' https://counter.localtest.me/api/counter
200 application/json; charset=utf-8

$ curl -s --cacert ca.crt -o /dev/null -w '%{http_code} %{content_type}\n' https://counter.localtest.me/counter
404 text/html; charset=utf-8

# порт backend на нодах/хосте не опубликован:
$ curl -sS --max-time 3 http://counter.localtest.me:9090/api/counter
curl: (7) Failed to connect to counter.localtest.me port 9090 after 1 ms: Couldn't connect to server

```

#### 1.3 backend слушает порт 9090, порт задаётся ConfigMap без пересборки образа

```console
$ docker image inspect counter-backend:1.0.0 --format 'ENV в образе: {{.Config.Env}}'
ENV в образе: [PATH=/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 GPG_KEY=A035C8C19219BA821ECEA86B64E628F8D684696D PYTHON_VERSION=3.11.17 PYTHON_SHA256=bfb74ad39efae27cda510f134ab408e00f9992c56851cfc0b1cdb5646da11599 HOST=0.0.0.0 PORT=8080]

$ kubectl -n counter get configmap backend -o jsonpath='{.data}'; echo
{"HOST":"0.0.0.0","PORT":"9090","PYTHONUNBUFFERED":"1"}

$ kubectl -n counter logs deploy/backend | grep -i 'running on'
======== Running on http://0.0.0.0:9090 ========

# меняем порт на 9191: правим ConfigMap и containerPort (пробы и Service ссылаются на именованный порт http)
$ kubectl -n counter patch configmap backend --type merge -p '{"data":{"PORT":"9191"}}'
configmap/backend patched

$ kubectl -n counter patch deploy backend --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":9191}]'
deployment.apps/backend patched

$ kubectl -n counter annotate deploy backend kubernetes.io/change-cause='PORT 9090 -> 9191 (demo 1.3)' --overwrite
deployment.apps/backend annotated

$ kubectl -n counter rollout status deploy/backend --timeout=120s
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
deployment "backend" successfully rolled out

$ kubectl -n counter logs -l app.kubernetes.io/name=backend --prefix | grep -i 'running on'
[pod/backend-5d5d759c97-47p77/backend] ======== Running on http://0.0.0.0:9191 ========

$ kubectl -n counter get endpointslices -l kubernetes.io/service-name=backend -o jsonpath='{range .items[*]}{.endpoints[*].addresses}{" port "}{.ports[*].port}{"\n"}{end}'
["10.244.2.20"] port 9191

$ curl -sS --cacert ca.crt https://counter.localtest.me/api/counter; echo
{"count": 0}

# возвращаем 9090
$ kubectl -n counter patch configmap backend --type merge -p '{"data":{"PORT":"9090"}}'
configmap/backend patched

$ kubectl -n counter patch deploy backend --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":9090}]'
deployment.apps/backend patched

$ kubectl -n counter annotate deploy backend kubernetes.io/change-cause='PORT 9191 -> 9090 (revert demo 1.3)' --overwrite
deployment.apps/backend annotated

$ kubectl -n counter rollout status deploy/backend --timeout=120s
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
deployment "backend" successfully rolled out

$ kubectl -n counter logs -l app.kubernetes.io/name=backend --prefix | grep -i 'running on'
[pod/backend-5dc74878b5-24sf4/backend] ======== Running on http://0.0.0.0:9090 ========

```

#### 1.4 readiness/liveness: что происходит с трафиком, когда экземпляр перестаёт быть готовым

```console
$ kubectl -n counter get deploy backend -o jsonpath='{range .spec.template.spec.containers[0]}startup:   {.startupProbe}{"\n"}readiness: {.readinessProbe}{"\n"}liveness:  {.livenessProbe}{"\n"}{end}'
startup:   {"failureThreshold":30,"httpGet":{"path":"/api/counter","port":"http","scheme":"HTTP"},"periodSeconds":2,"successThreshold":1,"timeoutSeconds":1}
readiness: {"failureThreshold":2,"httpGet":{"path":"/api/counter","port":"http","scheme":"HTTP"},"periodSeconds":5,"successThreshold":1,"timeoutSeconds":2}
liveness:  {"failureThreshold":3,"httpGet":{"path":"/api/counter","port":"http","scheme":"HTTP"},"periodSeconds":10,"successThreshold":1,"timeoutSeconds":2}

$ kubectl -n counter scale deploy backend --replicas=2 && kubectl -n counter rollout status deploy/backend --timeout=120s
deployment.apps/backend scaled
Waiting for deployment "backend" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "backend" rollout to finish: 1 of 2 updated replicas are available...
Waiting for deployment "backend" rollout to finish: 1 of 2 updated replicas are available...
deployment "backend" successfully rolled out

# счётчик у каждого пода свой (в памяти), поэтому по ответу видно, какой под ответил.
# накручиваем счётчик пода backend-5dc74878b5-24sf4 до 100 напрямую, в обход Service:
$ kubectl -n counter exec backend-5dc74878b5-24sf4 -- python -c 'import urllib.request as u; [u.urlopen(u.Request("http://127.0.0.1:9090/api/counter", method="POST")) for _ in range(100)]; print(u.urlopen("http://127.0.0.1:9090/api/counter").read().decode())'
{"count": 100}

$ kubectl -n counter get endpointslices -l kubernetes.io/service-name=backend -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name} ready={.conditions.ready}{"\n"}{end}'
backend-5dc74878b5-24sf4 ready=true
backend-5dc74878b5-sfr5m ready=true

# 10:59:57 «вешаем» под backend-5dc74878b5-24sf4: SIGSTOP процессу backend (pid 21820 на ноде course-worker2) — процесс жив, но не отвечает
$ docker exec course-worker2 kill -STOP 21820

# 11:00:12 через ~10 с readiness-проба упала, под исключён из EndpointSlice:
$ kubectl -n counter get endpointslices -l kubernetes.io/service-name=backend -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name} ready={.conditions.ready}{"\n"}{end}'
backend-5dc74878b5-24sf4 ready=false
backend-5dc74878b5-sfr5m ready=true

$ kubectl -n counter get pods -l app.kubernetes.io/name=backend
NAME                       READY   STATUS    RESTARTS   AGE
backend-5dc74878b5-24sf4   0/1     Running   0          63s
backend-5dc74878b5-sfr5m   1/1     Running   0          43s

# лог запросов через ingress, 4 запроса в секунду (время, тело ответа, HTTP-код; 000 — таймаут curl 2 с).
# одинаковые подряд идущие ответы свёрнуты: «с-по xN»
# squash — функция из scripts/lib.sh, сворачивает подряд идущие одинаковые ответы
$ squash /tmp/counter-loop.txt
10:59:53  {"count": 0} 200
10:59:53  {"count": 100} 200
10:59:53  {"count": 0} 200
10:59:54  {"count": 100} 200
10:59:54  {"count": 0} 200
10:59:54  {"count": 100} 200
10:59:55  {"count": 0} 200
10:59:55  {"count": 100} 200
10:59:55  {"count": 0} 200
10:59:56  {"count": 100} 200
10:59:56  {"count": 0} 200
10:59:56  {"count": 100} 200
10:59:57  {"count": 0} 200
10:59:57  {"count": 100} 200
10:59:57  {"count": 0} 200
11:00:00  000
11:00:00  {"count": 0} 200
11:00:02  000
11:00:03  {"count": 0} 200
11:00:05  000
11:00:05  {"count": 0} 200
11:00:08  000
11:00:08-11:01:07 x177  {"count": 0} 200

$ awk '{print $NF}' /tmp/counter-loop.txt | sort | uniq -c
      4 000
    195 200

# liveness-проба тоже упала (3 x 10 с) — kubelet перезапустил зависший контейнер:
$ kubectl -n counter get pods -l app.kubernetes.io/name=backend
NAME                       READY   STATUS    RESTARTS      AGE
backend-5dc74878b5-24sf4   1/1     Running   1 (16s ago)   119s
backend-5dc74878b5-sfr5m   1/1     Running   0             99s

$ kubectl -n counter get events --field-selector involvedObject.name=backend-5dc74878b5-24sf4 --sort-by=.lastTimestamp | grep -E 'Unhealthy|Killing|Started' | tail -6
46s         Normal    Killing     pod/backend-5dc74878b5-24sf4   Container backend failed liveness probe, will be restarted
19s         Warning   Unhealthy   pod/backend-5dc74878b5-24sf4   Readiness probe failed: Get "http://10.244.1.48:9090/api/counter": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
16s         Warning   Unhealthy   pod/backend-5dc74878b5-24sf4   Readiness probe failed: Get "http://10.244.1.48:9090/api/counter": read tcp 10.244.1.1:44456->10.244.1.48:9090: read: connection reset by peer
14s         Normal    Started     pod/backend-5dc74878b5-24sf4   Container started
13s         Warning   Unhealthy   pod/backend-5dc74878b5-24sf4   Readiness probe failed: Get "http://10.244.1.48:9090/api/counter": dial tcp 10.244.1.48:9090: connect: connection refused
8s          Warning   Unhealthy   pod/backend-5dc74878b5-24sf4   Startup probe failed: Get "http://10.244.1.48:9090/api/counter": dial tcp 10.244.1.48:9090: connect: connection refused

$ kubectl -n counter wait --for=condition=Ready pod/backend-5dc74878b5-24sf4 --timeout=120s
pod/backend-5dc74878b5-24sf4 condition met

$ kubectl -n counter get endpointslices -l kubernetes.io/service-name=backend -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name} ready={.conditions.ready}{"\n"}{end}'
backend-5dc74878b5-24sf4 ready=true
backend-5dc74878b5-sfr5m ready=true

$ kubectl -n counter scale deploy backend --replicas=1 && kubectl -n counter rollout status deploy/backend
deployment.apps/backend scaled
deployment "backend" successfully rolled out

```
