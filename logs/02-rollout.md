
#### 1.5 ресурсы: requests = limits у каждого контейнера, QoS Guaranteed

```console
$ kubectl -n counter get pods -o custom-columns=POD:.metadata.name,QOS:.status.qosClass,REQ:.spec.containers[*].resources.requests,LIM:.spec.containers[*].resources.limits
POD                        QOS          REQ                          LIM
backend-5dc74878b5-24sf4   Guaranteed   map[cpu:50m memory:64Mi]     map[cpu:50m memory:64Mi]
backend-5dc74878b5-sfr5m   Guaranteed   map[cpu:50m memory:64Mi]     map[cpu:50m memory:64Mi]
frontend-d4cff988f-mn6fm   Guaranteed   map[cpu:100m memory:192Mi]   map[cpu:100m memory:192Mi]

# фактическое потребление (из containerd на нодах; metrics-server в kind нет) — запас по памяти 2-3 раза:
$ ./scripts/pod-usage.sh counter
backend-5dc74878b5-sfr5m                      backend        20.3 MiB     0 mCPU
frontend-d4cff988f-mn6fm                      frontend       35.8 MiB     1 mCPU

$ kubectl -n counter describe limitrange container-limits
Name:       container-limits
Namespace:  counter
Type        Resource  Min  Max    Default Request  Default Limit  Max Limit/Request Ratio
----        --------  ---  ---    ---------------  -------------  -----------------------
Container   memory    -    512Mi  64Mi             128Mi          -
Container   cpu       -    -      50m              200m           -

# контейнер без resources получает значения по умолчанию из LimitRange (server-side dry-run проходит admission):
$ kubectl -n counter run no-resources --image=busybox:1.36 --restart=Never --dry-run=server -o jsonpath='{.spec.containers[0].resources}'; echo
{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}

# контейнер с лимитом больше разрешённого максимума не создаётся:
$ kubectl -n counter run greedy --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"greedy","image":"busybox:1.36","resources":{"limits":{"memory":"4Gi"}}}]}}'
Error from server (Forbidden): pods "greedy" is forbidden: maximum memory usage per Container is 512Mi, but limit is 4Gi

# контейнер, который пытается съесть 300 МБ при лимите 64Mi, убивается OOM killer, нода не страдает:
$ kubectl -n counter run memhog --image=counter-backend:1.0.0 --restart=Never --overrides='{"spec":{"containers":[{"name":"memhog","image":"counter-backend:1.0.0","command":["python","-c","x = bytearray(300 * 1024 * 1024); print(len(x))"],"resources":{"limits":{"memory":"64Mi","cpu":"100m"}}}]}}'
pod/memhog created

$ kubectl -n counter get pod memhog -o jsonpath='{.status.containerStatuses[0].state.terminated}'; echo
{"containerID":"containerd://0217ce3392a1356f1995e09f2f4c3cf1e79b96f1125b5e0b404d6aa4feab4b09","exitCode":137,"finishedAt":"2026-10-25T08:01:17Z","reason":"OOMKilled","startedAt":"2026-10-25T08:01:16Z"}

$ kubectl -n counter delete pod memhog --wait=false
pod "memhog" deleted from counter namespace

$ kubectl describe nodes | grep -A8 'Allocated resources'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests    Limits
  --------           --------    ------
  cpu                970m (97%)  0 (0%)
  memory             380Mi (4%)  340Mi (4%)
  ephemeral-storage  0 (0%)      0 (0%)
  hugepages-2Mi      0 (0%)      0 (0%)

--
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests    Limits
  --------           --------    ------
  cpu                150m (15%)  50m (5%)
  memory             114Mi (1%)  64Mi (0%)
  ephemeral-storage  0 (0%)      0 (0%)
  hugepages-2Mi      0 (0%)      0 (0%)

--
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests    Limits
  --------           --------    ------
  cpu                200m (20%)  100m (10%)
  memory             242Mi (3%)  192Mi (2%)
  ephemeral-storage  0 (0%)      0 (0%)
  hugepages-2Mi      0 (0%)      0 (0%)

```

#### 1.6 выкатка без простоя, сломанная версия, откат, история

```console
$ kubectl -n counter get deploy backend -o jsonpath='strategy={.spec.strategy} minReadySeconds={.spec.minReadySeconds} progressDeadlineSeconds={.spec.progressDeadlineSeconds}'; echo
strategy={"rollingUpdate":{"maxSurge":1,"maxUnavailable":0},"type":"RollingUpdate"} minReadySeconds=5 progressDeadlineSeconds=60

$ kubectl -n counter rollout history deploy/backend
deployment.apps/backend 
REVISION  CHANGE-CAUSE
2         PORT 9090 -> 9191 (demo 1.3)
3         PORT 9191 -> 9090 (revert demo 1.3)


# версия 1.0.1 — тот же образ 1.0.0 под новым тегом
$ docker tag counter-backend:1.0.0 counter-backend:1.0.1 && kind load docker-image counter-backend:1.0.1 --name course 2>&1 | tail -1
Image: "counter-backend:1.0.1" with ID "sha256:c33548490f09d99a934f1da2a38ffc464160dc883707e4918ab8dce7d1def311" not yet present on node "course-worker2", loading...

$ kubectl -n counter set image deploy/backend backend=counter-backend:1.0.1
deployment.apps/backend image updated

$ kubectl -n counter annotate deploy/backend kubernetes.io/change-cause='upgrade to counter-backend:1.0.1' --overwrite
deployment.apps/backend annotated

$ kubectl -n counter rollout status deploy/backend --timeout=120s
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
deployment "backend" successfully rolled out

# запросы через ingress во время выкатки (по 4 в секунду), сгруппированы по HTTP-коду:
$ awk '{print $NF}' /tmp/rollout-ok.txt | sort | uniq -c
    133 200

$ kubectl -n counter get rs -l app.kubernetes.io/name=backend -o wide
NAME                 DESIRED   CURRENT   READY   AGE     CONTAINERS   IMAGES                  SELECTOR
backend-56bd946744   1         1         1       41s     backend      counter-backend:1.0.1   app.kubernetes.io/name=backend,pod-template-hash=56bd946744
backend-5d5d759c97   0         0         0       3m40s   backend      counter-backend:1.0.0   app.kubernetes.io/name=backend,pod-template-hash=5d5d759c97
backend-5dc74878b5   0         0         0       4m7s    backend      counter-backend:1.0.0   app.kubernetes.io/name=backend,pod-template-hash=5dc74878b5

# выкатываем заведомо сломанную версию — несуществующий тег
$ kubectl -n counter set image deploy/backend backend=counter-backend:9.9.9-does-not-exist
deployment.apps/backend image updated

$ kubectl -n counter annotate deploy/backend kubernetes.io/change-cause='upgrade to counter-backend:9.9.9-does-not-exist (broken on purpose)' --overwrite
deployment.apps/backend annotated

$ kubectl -n counter rollout status deploy/backend --timeout=90s
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
error: deployment "backend" exceeded its progress deadline

$ kubectl -n counter get pods -l app.kubernetes.io/name=backend
NAME                       READY   STATUS         RESTARTS   AGE
backend-56bd946744-2c26s   1/1     Running        0          106s
backend-5f9cdb5f99-7fjg9   0/1     ErrImagePull   0          62s

$ kubectl -n counter get deploy backend -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
Available=True MinimumReplicasAvailable: Deployment has minimum availability.
Progressing=False ProgressDeadlineExceeded: ReplicaSet "backend-5f9cdb5f99" has timed out progressing.

# сервис всё это время отвечал старой версией:
$ awk '{print $NF}' /tmp/rollout-broken.txt | sort | uniq -c
    235 200

$ kubectl -n counter rollout history deploy/backend
deployment.apps/backend 
REVISION  CHANGE-CAUSE
2         PORT 9090 -> 9191 (demo 1.3)
3         PORT 9191 -> 9090 (revert demo 1.3)
4         upgrade to counter-backend:1.0.1
5         upgrade to counter-backend:9.9.9-does-not-exist (broken on purpose)


$ kubectl -n counter rollout undo deploy/backend
Warning: resource deployments/backend was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, which may cause unexpected behavior on future 'kubectl apply' operations. Consider using 'kubectl apply' with your previous configuration file instead.
deployment.apps/backend rolled back

$ kubectl -n counter wait deploy/backend --for=condition=Progressing --timeout=60s
deployment.apps/backend condition met

$ kubectl -n counter rollout status deploy/backend --timeout=120s
deployment "backend" successfully rolled out

$ kubectl -n counter get pods -l app.kubernetes.io/name=backend -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready
POD                        IMAGE                   READY
backend-56bd946744-2c26s   counter-backend:1.0.1   true

$ kubectl -n counter rollout history deploy/backend
deployment.apps/backend 
REVISION  CHANGE-CAUSE
2         PORT 9090 -> 9191 (demo 1.3)
3         PORT 9191 -> 9090 (revert demo 1.3)
5         upgrade to counter-backend:9.9.9-does-not-exist (broken on purpose)
6         upgrade to counter-backend:1.0.1


$ kubectl -n counter rollout history deploy/backend --revision=6 | head -8
deployment.apps/backend with revision #6
Pod Template:
  Labels:	app.kubernetes.io/name=backend
	app.kubernetes.io/part-of=counter
	pod-template-hash=56bd946744
  Annotations:	kubernetes.io/change-cause: upgrade to counter-backend:1.0.1
  Containers:
   backend:

$ curl -sS --cacert ca.crt https://counter.localtest.me/api/counter; echo
{"count": 0}

```
