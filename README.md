# counter в Kubernetes

Домашнее задание 4. Кластер локальный: kind, три ноды (control-plane и два воркера), перед ним ingress-nginx, сертификатами занимается cert-manager. Образы backend и frontend собраны из исходников и в публичные реестры не уходили, в кластер они попадают через `kind load`. Из чужих образов только `postgres:16-alpine`, `node-exporter` с quay.io и `kubectl` с registry.k8s.io.

Поднимается всё так:

```console
$ ./scripts/setup-cluster.sh
$ kubectl apply -f k8s/00-namespace.yaml -f k8s/10-tls.yaml -f k8s/20-backend.yaml -f k8s/30-frontend.yaml -f k8s/40-ingress.yaml
```

Ниже по порядку задания: что сделал, почему, и вывод команд, по которому видно, что оно работает. Вывод местами сокращён, но не переписан: это то, что напечатал терминал.

## Задание 1. Приложение

### 1.1 HTTPS и свой сертификат

Сертификат выпускает cert-manager. Сначала самоподписанный Issuer делает корневой CA, потом из этого CA выпускается сертификат для `counter.localtest.me`. Так curl можно дать именно наш CA, а не отключать проверку.

```console
$ curl -sS https://counter.localtest.me/ -o /dev/null
curl: (60) SSL certificate problem: unable to get local issuer certificate

$ curl -v --cacert ca.crt https://counter.localtest.me/ -o /dev/null 2>&1 | grep -E 'SSL connection|issuer:|SSL certificate verify|HTTP/2 [0-9]'
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / X25519 / id-ecPublicKey
*  issuer: CN=counter-ca
*  SSL certificate verify ok.
< HTTP/2 200

$ for i in 1 2 3; do curl -sS --cacert ca.crt -X POST https://counter.localtest.me/api/counter; echo; done
{"count": 1}
{"count": 2}
{"count": 3}
```

Без нашего CA curl ругается, с ним проверка проходит.

### 1.2 backend снаружи только через /api

Оба сервиса типа ClusterIP, наружу ничего не торчит. В Ingress два правила: `/api` идёт в backend, всё остальное во frontend.

```console
$ kubectl -n counter get ingress counter -o jsonpath='{range .spec.rules[*].http.paths[*]}{.path}{" -> "}{.backend.service.name}{"\n"}{end}'
/api -> backend
/ -> frontend

$ curl -sS --max-time 3 http://counter.localtest.me:9090/api/counter
curl: (7) Failed to connect to counter.localtest.me port 9090 after 1 ms: Couldn't connect to server
```

### 1.3 Порт не по умолчанию

backend слушает 9090. Значение лежит в ConfigMap (`PORT`), образ про него ничего не знает. Для проверки поменял на 9191 и заодно `containerPort` в Deployment (пробы и Service ссылаются на порт по имени, поэтому больше править ничего не пришлось), потом вернул обратно.

```console
$ kubectl -n counter logs deploy/backend | grep -i 'running on'
======== Running on http://0.0.0.0:9090 ========

$ kubectl -n counter patch configmap backend --type merge -p '{"data":{"PORT":"9191"}}'
$ kubectl -n counter patch deploy backend --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":9191}]'

$ kubectl -n counter logs -l app.kubernetes.io/name=backend --prefix | grep -i 'running on'
[pod/backend-5d5d759c97-47p77/backend] ======== Running on http://0.0.0.0:9191 ========

$ curl -sS --cacert ca.crt https://counter.localtest.me/api/counter
{"count": 0}
```

### 1.4 Готовность и «зависание»

У backend три пробы по `/api/counter`: startup (даёт время на запуск), readiness раз в 5 секунд и liveness раз в 10. Readiness убирает под из балансировки, liveness перезапускает контейнер.

Чтобы было видно, какой под отвечает, я поднял две реплики и накрутил счётчик одного из них до 100 (счётчик лежит в памяти, у каждого пода свой). Потом заморозил процесс этого пода через `kill -STOP`: процесс жив, но не отвечает. Параллельно в цикле шли запросы через ingress, по 4 в секунду.

```console
$ kubectl -n counter get endpointslices -l kubernetes.io/service-name=backend -o jsonpath='...'
backend-5dc74878b5-24sf4 ready=false
backend-5dc74878b5-sfr5m ready=true

10:59:57  {"count": 100} 200
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
```

Секунд десять после заморозки Kubernetes ещё считает под живым и отправляет туда часть запросов, они упираются в таймаут curl (это четыре `000`). Когда readiness упала дважды подряд, под вылетел из EndpointSlice и дальше отвечал только здоровый. Ответа `{"count": 100}` после этого больше нет. Потом сработала liveness:

```console
$ kubectl -n counter get pods -l app.kubernetes.io/name=backend
NAME                       READY   STATUS    RESTARTS      AGE
backend-5dc74878b5-24sf4   1/1     Running   1 (16s ago)   119s
backend-5dc74878b5-sfr5m   1/1     Running   0             99s

Normal   Killing   pod/backend-5dc74878b5-24sf4   Container backend failed liveness probe, will be restarted
```

Контейнер перезапустился, прошёл startup и readiness и вернулся в балансировку.

### 1.5 Ресурсы

Каждому контейнеру заданы и requests, и limits, причём одинаковые. Поэтому у подов класс QoS Guaranteed.

```console
$ kubectl -n counter get pods -o custom-columns=POD:.metadata.name,QOS:.status.qosClass,REQ:...,LIM:...
POD                        QOS          REQ                          LIM
backend-5dc74878b5-24sf4   Guaranteed   map[cpu:50m memory:64Mi]     map[cpu:50m memory:64Mi]
frontend-d4cff988f-mn6fm   Guaranteed   map[cpu:100m memory:192Mi]   map[cpu:100m memory:192Mi]
```

В namespace есть LimitRange на тот случай, если кто-то забудет прописать ресурсы: по умолчанию контейнер получает 50m/64Mi с лимитом 200m/128Mi, а больше 512Mi памяти взять нельзя.

```console
$ kubectl -n counter run no-resources --image=busybox:1.36 --restart=Never --dry-run=server -o jsonpath='{.spec.containers[0].resources}'
{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}

$ kubectl -n counter run greedy --image=busybox:1.36 --restart=Never --overrides='...limit 4Gi...'
Error from server (Forbidden): pods "greedy" is forbidden: maximum memory usage per Container is 512Mi, but limit is 4Gi
```

И отдельно проверил, что лимит работает: под, который пытается съесть 300 МБ при лимите 64Mi, убивается OOM killer-ом, нода это не затрагивает.

```console
$ kubectl -n counter get pod memhog -o jsonpath='{.status.containerStatuses[0].state.terminated}'
{"containerID":"containerd://0217ce33...","exitCode":137,...
```

### 1.6 Выкатка, сломанная версия, откат

Стратегия RollingUpdate с `maxSurge: 1` и `maxUnavailable: 0`: сначала поднимается новый под, и только когда он готов, уходит старый. `minReadySeconds: 5` не даёт считать под готовым в первую же секунду, `progressDeadlineSeconds: 60` заставляет Kubernetes признать зависшую выкатку неудачной. Причину каждой версии я пишу в аннотацию `kubernetes.io/change-cause`, из неё складывается история.

Обычная выкатка (новый тег 1.0.1), запросы через ingress всё время идут:

```console
$ kubectl -n counter set image deploy/backend backend=counter-backend:1.0.1
$ kubectl -n counter rollout status deploy/backend --timeout=120s
deployment "backend" successfully rolled out

$ awk '{print $NF}' /tmp/rollout-ok.txt | sort | uniq -c
    133 200
```

Теперь версия с несуществующим тегом:

```console
$ kubectl -n counter set image deploy/backend backend=counter-backend:9.9.9-does-not-exist
$ kubectl -n counter rollout status deploy/backend --timeout=90s
error: deployment "backend" exceeded its progress deadline

$ kubectl -n counter get pods -l app.kubernetes.io/name=backend
NAME                       READY   STATUS         RESTARTS   AGE
backend-56bd946744-2c26s   1/1     Running        0          106s
backend-5f9cdb5f99-7fjg9   0/1     ErrImagePull   0          62s

$ awk '{print $NF}' /tmp/rollout-broken.txt | sort | uniq -c
    235 200
```

Новый под не стал готовым, поэтому старый никто не тронул, и 235 запросов из 235 ответили 200. Откат и история:

```console
$ kubectl -n counter rollout undo deploy/backend
deployment.apps/backend rolled back

$ kubectl -n counter rollout history deploy/backend
REVISION  CHANGE-CAUSE
2         PORT 9090 -> 9191 (demo 1.3)
3         PORT 9191 -> 9090 (revert demo 1.3)
5         upgrade to counter-backend:9.9.9-does-not-exist (broken on purpose)
6         upgrade to counter-backend:1.0.1
```

Ревизия 4 пропала, потому что откат берёт шаблон ревизии 4 и записывает его заново под номером 6. Это нормальное поведение Kubernetes.

### Вопросы к заданию 1

**Что будет с тремя экземплярами backend и что менять в приложении.** Счётчик хранится в памяти процесса, поэтому у каждого пода он свой. Service раздаёт запросы по кругу, и значение прыгает:

```console
$ for i in 1 2 3 4 5 6; do curl -sS --cacert ca.crt -X POST https://counter.localtest.me/api/counter; echo; done
{"count": 1}
{"count": 1}
{"count": 1}
{"count": 2}
{"count": 2}
{"count": 2}
```

Три первых POST попали на три разных пода, и каждый ответил единицей. Чтобы приложение можно было масштабировать, состояние надо вынести из процесса в общее хранилище, например в PostgreSQL, который как раз подготовлен во втором задании. Тогда все реплики работают с одним значением. Побочно отпадает и потеря счётчика при перезапуске пода.

**Когда работающие поды увидят изменение конфигурации.** Это зависит от того, как конфигурация попала в под. У нас backend берёт её переменными окружения, а переменные читаются один раз при старте контейнера. Я поправил ConfigMap и через 70 секунд проверил под: переменной в нём нет. Увидит он её только после перезапуска (`rollout restart`). Если тот же ConfigMap смонтировать в под как том, kubelet обновляет файлы сам, но не мгновенно, а на периодической синхронизации: в моём прогоне файл поменялся примерно через 65 секунд. И даже тогда приложение должно само перечитать файл. Файлы, подключённые через `subPath`, не обновляются вообще.

```console
$ kubectl -n counter exec backend-56bd946744-lp28q -- printenv FEATURE_FLAG || echo 'переменной нет: env читается только при старте контейнера'
переменной нет: env читается только при старте контейнера

$ kubectl -n counter rollout restart deploy/backend
$ kubectl -n counter exec deploy/backend -- printenv FEATURE_FLAG
on

$ kubectl -n counter exec cm-volume -- cat /cfg/FEATURE_FLAG
on
через ~65 с файл в томе: off
```

**Класс QoS и почему такие ресурсы.** Guaranteed у backend и frontend: requests равны limits. Этот класс последним попадает под выселение, когда на ноде заканчивается память, и планировщик точно знает, сколько места резервировать. Числа выбирал по факту: backend в покое занимает около 20 МиБ памяти и почти не грузит процессор, я поставил 64 МиБ и 50m. frontend это Next.js, он потребляет около 36 МиБ, но при запуске скачет сильнее, поэтому 192 МиБ и 100m. Запас в несколько раз над реальным потреблением, и при этом лимит достаточно жёсткий, чтобы утечка не съела ноду (OOM-тест выше это показывает).

## Задание 2. База данных

PostgreSQL запущен как StatefulSet с headless Service (`clusterIP: None`) и томом, который создаётся из `volumeClaimTemplates`.

```console
$ kubectl -n counter get statefulset,pod,svc,pvc -l app.kubernetes.io/name=postgres -o wide
statefulset.apps/postgres   1/1     39s   postgres     postgres:16-alpine
pod/postgres-0   1/1     Running   0          39s   10.244.1.55   course-worker2
service/postgres   ClusterIP   None         <none>        5432/TCP
persistentvolumeclaim/data-postgres-0   Bound    pvc-85ec873f-...   1Gi   RWO   standard
```

### 2.3 Таблица и пароль

Таблицу создаёт init-скрипт из ConfigMap, смонтированный в `/docker-entrypoint-initdb.d`. Образ postgres выполняет его только при первом запуске, на пустом каталоге данных.

```console
$ kubectl -n counter logs postgres-0 | grep -E 'docker-entrypoint-initdb.d|CREATE TABLE|INSERT|ready to accept'
/usr/local/bin/docker-entrypoint.sh: running /docker-entrypoint-initdb.d/init.sql
CREATE TABLE
INSERT 0 1

$ kubectl -n counter exec pg-client -- psql -h postgres-0.postgres -c '\d counter'
 Column |  Type   | Nullable | Default
--------+---------+----------+---------
 id     | integer | not null |
 value  | bigint  | not null | 0
Check constraints:
    "counter_id_check" CHECK (id = 1)
```

Пароль создаётся скриптом `scripts/create-db-secret.sh` командой `openssl rand`, прямо в кластере. В манифестах и в репозитории его нет, там только ссылка на Secret. Само значение я в вывод не печатал, только длину:

```console
$ ./scripts/create-db-secret.sh
secret/postgres-auth created

$ kubectl -n counter get secret postgres-auth -o go-template='{{range $k, $v := .data}}{{$k}}: {{len ($v | base64decode)}} символов{{"\n"}}{{end}}'
POSTGRES_DB: 7 символов
POSTGRES_PASSWORD: 30 символов
POSTGRES_USER: 7 символов
```

### 2.2 Стабильное имя

У пода StatefulSet имя всегда `postgres-0`, а через headless Service оно превращается в DNS-запись `postgres-0.postgres.counter.svc.cluster.local`. Другой под (`pg-client`) подключается по этому имени:

```console
$ kubectl -n counter exec pg-client -- nslookup postgres-0.postgres.counter.svc.cluster.local
Name:	postgres-0.postgres.counter.svc.cluster.local
Address: 10.244.1.55

$ kubectl -n counter exec pg-client -- psql -h postgres-0.postgres -c 'select inet_server_addr() as server_ip, current_user, current_database()'
  server_ip  | current_user | current_database
-------------+--------------+------------------
 10.244.1.55 | counter      | counter
```

### 2.1 Данные переживают удаление пода и StatefulSet

Записал в таблицу 42, удалил под. Адрес у пересозданного пода другой, имя то же, данные на месте:

```console
$ kubectl -n counter delete pod postgres-0
$ kubectl -n counter exec pg-client -- psql -h postgres-0.postgres -c 'select * from counter'
 id | value
----+-------
  1 |    42
```

Потом удалил сам StatefulSet и применил манифест заново. Том остаётся, потому что в `persistentVolumeClaimRetentionPolicy` стоит `Retain` на удаление и на масштабирование:

```console
$ kubectl -n counter delete statefulset postgres --wait=true
$ kubectl -n counter get pvc
data-postgres-0   Bound    pvc-85ec873f-d4f8-451f-8930-49e934e33315   1Gi   RWO   standard

$ kubectl apply -f k8s/50-postgres.yaml && kubectl -n counter rollout status statefulset/postgres
$ kubectl -n counter exec pg-client -- psql -h postgres-0.postgres -c 'select * from counter'
 id | value
----+-------
  1 |    42
```

### Вопросы к заданию 2

**Почему StatefulSet.** Базе нужны две вещи: постоянное имя и свой собственный диск, который привязан именно к этому экземпляру. Deployment не даёт ни того, ни другого: имена подов случайные, а общий том на все реплики для базы не подходит. StatefulSet даёт имя `postgres-0`, стабильное после любых пересозданий, и отдельный PVC на каждый экземпляр, который переживает перезапуск. Готовые операторы типа CloudNativePG здесь были бы избыточными: нам нужен один экземпляр без репликации.

**Где лежат данные и что с ними при удалении namespace.** Физически это каталог на ноде, где запущен под: StorageClass `standard` в kind это local-path provisioner, и данные лежат в `/var/local-path-provisioner/<pv>_<namespace>_<pvc>/pgdata` внутри docker-контейнера ноды (то есть, в конечном счёте, на диске хоста). У этого PV `reclaimPolicy: Delete`.

```console
$ kubectl get pv pvc-85ec873f-... -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,STORAGECLASS:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,PATH:...
NAME                CLAIM             STORAGECLASS   RECLAIM   PATH
pvc-85ec873f-...    data-postgres-0   standard       Delete    /var/local-path-provisioner/pvc-85ec873f-..._counter_data-postgres-0

$ docker exec course-worker2 ls /var/local-path-provisioner/pvc-85ec873f-..._counter_data-postgres-0/pgdata | head -3
PG_VERSION
base
global
```

Если удалить namespace, вместе с ним удаляется PVC, после этого, по политике Delete, удаляется PV и каталог на ноде. Политика Retain у StatefulSet тут не помогает: она защищает от удаления самого StatefulSet, а не namespace. Я проверил это на отдельном namespace `counter-nsdel` (чтобы не трогать рабочий):

```console
$ kubectl -n counter-nsdel exec postgres-0 -- psql -U counter -d counter -c 'update counter set value = 42 where id = 1 returning *'
  1 |    42

$ kubectl delete namespace counter-nsdel --wait=true --timeout=180s
namespace "counter-nsdel" deleted

$ kubectl get pv pvc-42b5d03b-d54b-4bfa-8aa1-bfbb9501ddfc
Error from server (NotFound): persistentvolumes "pvc-42b5d03b-d54b-4bfa-8aa1-bfbb9501ddfc" not found

$ docker exec course-worker ls -d /var/local-path-provisioner/pvc-42b5d03b-..._counter-nsdel_data-postgres-0
ls: cannot access '...': No such file or directory

 id | value
----+-------
  1 |     0
```

В реальном кластере для базы с настоящими данными стоило бы взять StorageClass с `reclaimPolicy: Retain` и делать бэкапы.

## Задание 3. Эксплуатация

### 3.1 node-exporter на каждой ноде

DaemonSet с `tolerations: [{operator: Exists}]`, поэтому он садится и на control-plane, где обычные поды не запускаются из-за taint. Работает в `hostNetwork` и `hostPID`, чтобы видеть метрики самой ноды, а не пода. Метрики отдаются на порту 9100 каждой ноды.

```console
$ kubectl -n monitoring get ds,pods -o wide
daemonset.apps/node-exporter   3   3   3   3   3
pod/node-exporter-4tjkm   1/1   Running   172.20.0.4   course-control-plane
pod/node-exporter-fkd2g   1/1   Running   172.20.0.2   course-worker2
pod/node-exporter-jzzgf   1/1   Running   172.20.0.3   course-worker

$ curl -s http://172.20.0.4:9100/metrics | grep -E '^node_uname_info|^node_load1 '
node_load1 4.24
node_uname_info{...nodename="course-control-plane",...} 1
```

То же самое по двум воркерам (IP 172.20.0.3 и 172.20.0.2) с их именами в `nodename`.

Ресурсы: requests 10m/32Mi, limits 50m/64Mi. Реальное потребление экспортёра около 18 МиБ резидентной памяти и 0,08 секунды процессорного времени с момента запуска.

```console
$ kubectl -n monitoring get ds node-exporter -o jsonpath='{.spec.template.spec.containers[0].resources}'
{"limits":{"cpu":"50m","memory":"64Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}
```

Автоматическое появление на новой ноде проверил, добавив четвёртую ноду в кластер (`scripts/add-kind-node.sh`). DaemonSet сам создал на ней под, через пару минут метрики уже отдавались:

```console
$ kubectl get nodes
course-control-plane   Ready   control-plane   25h
course-worker          Ready   <none>          25h
course-worker2         Ready   <none>          25h
course-worker4         Ready   <none>          2m7s

$ kubectl -n monitoring get ds node-exporter
NAME            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
node-exporter   4         4         4       4            4

$ curl -s http://172.20.0.5:9100/metrics | grep -E '^node_uname_info'
node_uname_info{...nodename="course-worker4",...} 1
```

### 3.2 Масштабирование frontend по расписанию

Два CronJob с `timeZone: Europe/Moscow`: в `0 9 * * *` масштабируют frontend до 3, в `0 18 * * *` до 1. Внутри обычный `kubectl scale`. Работают под отдельным ServiceAccount `frontend-scaler`, а Role разрешает ровно две вещи: читать Deployment `frontend` и менять его подресурс `scale`. Обе привязаны к имени `frontend` через `resourceNames`.

```console
$ kubectl -n counter get cronjob
NAME                  SCHEDULE     TZ              ARGS
frontend-scale-down   0 18 * * *   Europe/Moscow   [scale deployment/frontend --replicas=1 --namespace=counter]
frontend-scale-up     0 9 * * *    Europe/Moscow   [scale deployment/frontend --replicas=3 --namespace=counter]
```

Что разрешено и что запрещено, проверено от имени этого ServiceAccount:

```console
$ kubectl auth can-i patch deployments.apps/frontend --subresource=scale -n counter --as=system:serviceaccount:counter:frontend-scaler
yes
$ kubectl auth can-i patch deployments.apps/frontend -n counter --as=system:serviceaccount:counter:frontend-scaler
no
$ kubectl auth can-i delete deployments.apps/frontend -n counter --as=system:serviceaccount:counter:frontend-scaler
no
$ kubectl auth can-i patch deployments.apps/backend --subresource=scale -n counter --as=system:serviceaccount:counter:frontend-scaler
no
$ kubectl auth can-i get secrets -n counter --as=system:serviceaccount:counter:frontend-scaler
no
$ kubectl auth can-i patch deployments.apps/frontend --subresource=scale -n team-blue --as=system:serviceaccount:counter:frontend-scaler
no

$ kubectl -n counter scale deploy/backend --replicas=3 --as=system:serviceaccount:counter:frontend-scaler
Error from server (Forbidden): deployments.apps "backend" is forbidden: ...
$ kubectl -n counter get secret postgres-auth --as=system:serviceaccount:counter:frontend-scaler
Error from server (Forbidden): secrets "postgres-auth" is forbidden: ...
```

Запуск вне расписания: создаю Job из CronJob.

```console
$ kubectl -n counter create job scale-up-manual --from=cronjob/frontend-scale-up
$ kubectl -n counter logs job/scale-up-manual
deployment.apps/frontend scaled
$ kubectl -n counter get deploy frontend
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
frontend   3/3     3            3           12m

$ kubectl -n counter create job scale-down-manual --from=cronjob/frontend-scale-down
$ kubectl -n counter get deploy frontend
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
frontend   1/1     1            1           12m
```

Образ для задания `registry.k8s.io/kubectl`, не bitnami.

## Задание 4. Helm

Чарт лежит в `charts/counter`. Всё, что отличается между окружениями, вынесено в `values.yaml`: адрес, число реплик, порт backend, ресурсы, теги образов, дополнительные переменные конфигурации, включение базы и планировщика. Имена объектов строятся от имени релиза, а сертификат и Issuer свои у каждого релиза, поэтому установки между собой не пересекаются.

### 4.1 Две установки

```console
$ helm lint charts/counter
1 chart(s) linted, 0 chart(s) failed

$ helm install blue charts/counter -n team-blue --create-namespace --wait --timeout 5m
STATUS: deployed
Адрес:  https://blue.localtest.me

$ helm install green charts/counter -n team-green --create-namespace -f charts/examples/values-green.yaml --wait --timeout 5m
```

`values-green.yaml` меняет три вещи: адрес `green.localtest.me`, порт backend 9191 и по две реплики. Шаблоны никто не правил.

```console
$ curl -sS --cacert /tmp/green-ca.crt -o /dev/null -w '%{http_code}\n' https://green.localtest.me/
200

$ kubectl -n team-green get pods -o wide
green-counter-backend-67ddb64bbf-96p9v    1/1   Running     course-worker4
green-counter-backend-67ddb64bbf-m4jbz    1/1   Running     course-worker
green-counter-frontend-5b8cbbb9b6-65q4w   1/1   Running     course-worker
green-counter-frontend-5b8cbbb9b6-r2hql   1/1   Running     course-worker4
green-counter-verify-jklsx                0/1   Completed   course-worker4

$ kubectl -n team-green logs deploy/green-counter-backend | grep -i 'running on'
======== Running on http://0.0.0.0:9191 ========
```

Сертификаты у релизов выпущены разными CA, и это видно: CA от blue не подходит к green.

```console
$ curl -sS --cacert /tmp/blue-ca.crt https://green.localtest.me/api/counter
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

Третья установка в тот же namespace, что и blue, тоже не конфликтует:

```console
$ helm install blue-canary charts/counter -n team-blue --set ingress.host=canary.localtest.me --wait --timeout 5m
$ curl -sS --cacert /tmp/blue-canary-ca.crt https://canary.localtest.me/api/counter
{"count": 0}
$ kubectl -n team-blue get deploy
blue-canary-counter-backend    1/1
blue-canary-counter-frontend   1/1
blue-counter-backend           1/1
blue-counter-frontend          1/1
```

### 4.2 Перезапуск при смене конфигурации, проверка, обновление и откат

В шаблон пода backend добавлена аннотация `checksum/config` с хэшем ConfigMap. Изменилась конфигурация, изменился хэш, изменился шаблон пода, и Deployment сам перекатывает поды. Видно по хэшу и времени старта:

```console
$ helm upgrade blue charts/counter -n team-blue --reuse-values --set backend.port=9292 --set backend.extraConfig.LOG_LEVEL=debug --wait --timeout 5m
REVISION: 2

$ kubectl -n team-blue get pods -l app.kubernetes.io/component=backend -o custom-columns=POD:.metadata.name,CHECKSUM:.metadata.annotations.checksum/config,START:.status.startTime

$ kubectl -n team-blue get configmap blue-counter-backend -o jsonpath='{.data}'
{"HOST":"0.0.0.0","LOG_LEVEL":"debug","PORT":"9292","PYTHONUNBUFFERED":"1"}
$ kubectl -n team-blue logs deploy/blue-counter-backend | grep -i 'running on'
======== Running on http://0.0.0.0:9292 ========
```

Автоматическая проверка после установки: Job `verify` с хуком `post-install,post-upgrade,post-rollback`. Он идёт по тому же пути, что и пользователь: backend напрямую, frontend, потом через ingress по HTTPS с проверкой сертификата CA релиза. Если какая-то проверка падает, релиз считается неудачным.

```console
$ kubectl -n team-blue logs job/blue-counter-verify
backend:  GET /api/counter
{"count": 0}
frontend: GET /
200
ingress:  GET https://blue.localtest.me/api/counter (сертификат проверяется CA релиза)
{"count": 0}
OK: release blue is healthy
```

Неудачное обновление (несуществующий образ) с флагом `--atomic` откатывается само, сервис остаётся на старой версии:

```console
$ helm upgrade blue charts/counter -n team-blue --reuse-values --set backend.image.tag=9.9.9-does-not-exist --atomic --timeout 90s
Error: UPGRADE FAILED: release blue failed, and has been rolled back due to atomic being set: context deadline exceeded

$ curl -sS --cacert /tmp/blue-ca.crt https://blue.localtest.me/api/counter
{"count": 0}
```

История и ручной откат на первую ревизию:

```console
$ helm rollback blue 1 -n team-blue --wait --timeout 5m
Rollback was a success! Happy Helming!

$ helm history blue -n team-blue
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         superseded  Upgrade complete
3         failed      Upgrade "blue" failed: context deadline exceeded
4         superseded  Rollback to 2
5         deployed    Rollback to 1

$ kubectl -n team-blue get configmap blue-counter-backend -o jsonpath='{.data}'
{"HOST":"0.0.0.0","PORT":"9090","PYTHONUNBUFFERED":"1"}
```

После отката порт снова 9090, дополнительной переменной нет.

## ★ База данных в чарте

За базу отвечает параметр `postgres.enabled`, по умолчанию выключен. Включил и записал в таблицу 777:

```console
$ helm upgrade blue charts/counter -n team-blue --reuse-values --set postgres.enabled=true --wait --timeout 5m
$ kubectl -n team-blue exec blue-counter-postgres-0 -- psql -U counter -d counter -c 'update counter set value = 777 where id = 1 returning *'
 id | value
----+-------
  1 |   777
```

Пароль чарт генерирует сам (`randAlphaNum`) при первой установке. У Secret стоит `helm.sh/resource-policy: keep`, а при повторной установке шаблон находит существующий Secret через `lookup` и берёт пароль из него. Так он не меняется: иначе база, уже инициализированная старым паролем, не пустила бы клиентов. Диск тоже остаётся: StatefulSet хранит PVC и после своего удаления.

Выключение параметром убирает StatefulSet, но не данные и не пароль:

```console
$ helm upgrade blue charts/counter -n team-blue --reuse-values --set postgres.enabled=false --wait --timeout 5m
$ kubectl -n team-blue get pvc data-blue-counter-postgres-0
data-blue-counter-postgres-0   Bound   ...   1Gi
```

Теперь удаляю релиз целиком, смотрю, что осталось, и ставлю заново:

```console
$ helm uninstall blue -n team-blue
These resources were kept due to the resource policy:
[Secret] blue-counter-postgres-auth

$ kubectl -n team-blue get pvc,secret
persistentvolumeclaim/data-blue-counter-postgres-0   Bound   ...   1Gi
secret/blue-counter-postgres-auth                    Opaque  ...

$ helm install blue charts/counter -n team-blue --set postgres.enabled=true --wait --timeout 5m
$ kubectl -n team-blue exec blue-counter-postgres-0 -- psql -U counter -d counter -c 'select * from counter'
 id | value
----+-------
  1 |   777
```

777 на месте. Пароль тот же: сравнил отпечатки (первые 16 символов sha256 от значения в Secret) до удаления и после: в обоих случаях `654d306d8755c4ae`, само значение при этом никуда не печаталось. Подключение из отдельного пода по сети с паролем из Secret тоже работает:

```console
$ kubectl -n team-blue logs psql-check
 value
-------
   777
(1 row)
```

## Что осталось за рамками

Приложение по-прежнему хранит счётчик в памяти и к базе не подключено: в задании так и сказано. Поэтому при перезапуске пода backend счётчик обнуляется, а при нескольких репликах значения расходятся (см. ответ на первый вопрос). Для настоящей эксплуатации понадобились бы ещё резервные копии базы и StorageClass с политикой Retain, но для учебного кластера этого достаточно.
