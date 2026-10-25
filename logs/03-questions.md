
#### Вопрос 1: backend в трёх экземплярах

```console
$ kubectl -n counter scale deploy/backend --replicas=3 && kubectl -n counter rollout status deploy/backend --timeout=120s
deployment.apps/backend scaled
Waiting for deployment "backend" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "backend" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "backend" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "backend" rollout to finish: 1 of 3 updated replicas are available...
deployment "backend" successfully rolled out

$ kubectl -n counter get pods -l app.kubernetes.io/name=backend -o wide
NAME                       READY   STATUS    RESTARTS   AGE     IP            NODE             NOMINATED NODE   READINESS GATES
backend-56bd946744-2c26s   1/1     Running   0          2m28s   10.244.1.50   course-worker2   <none>           <none>
backend-56bd946744-gf7hx   1/1     Running   0          18s     10.244.1.51   course-worker2   <none>           <none>
backend-56bd946744-lp28q   1/1     Running   0          18s     10.244.2.23   course-worker    <none>           <none>

$ for i in 1 2 3 4 5 6; do curl -sS --cacert ca.crt -X POST https://counter.localtest.me/api/counter; echo; done
{"count": 1}
{"count": 1}
{"count": 1}
{"count": 2}
{"count": 2}
{"count": 2}

$ for i in 1 2 3 4 5 6; do curl -sS --cacert ca.crt https://counter.localtest.me/api/counter; echo; done
{"count": 2}
{"count": 2}
{"count": 2}
{"count": 2}
{"count": 2}
{"count": 2}

# у каждого пода свой счётчик:
$ kubectl -n counter exec pod/backend-56bd946744-2c26s -- python -c 'import urllib.request as u; print(u.urlopen("http://127.0.0.1:9090/api/counter").read().decode())'
{"count": 2}

$ kubectl -n counter exec pod/backend-56bd946744-gf7hx -- python -c 'import urllib.request as u; print(u.urlopen("http://127.0.0.1:9090/api/counter").read().decode())'
{"count": 2}

$ kubectl -n counter exec pod/backend-56bd946744-lp28q -- python -c 'import urllib.request as u; print(u.urlopen("http://127.0.0.1:9090/api/counter").read().decode())'
{"count": 2}

$ kubectl -n counter scale deploy/backend --replicas=1 && kubectl -n counter rollout status deploy/backend
deployment.apps/backend scaled
deployment "backend" successfully rolled out

```

#### Вопрос 2: когда работающий под увидит изменения ConfigMap

```console
$ kubectl -n counter patch configmap backend --type merge -p '{"data":{"FEATURE_FLAG":"on"}}'
configmap/backend patched

$ sleep 70; kubectl -n counter exec backend-56bd946744-lp28q -- printenv FEATURE_FLAG || echo 'переменной нет: env читается только при старте контейнера'
command terminated with exit code 1
переменной нет: env читается только при старте контейнера

$ kubectl -n counter rollout restart deploy/backend && kubectl -n counter rollout status deploy/backend --timeout=120s
deployment.apps/backend restarted
Waiting for deployment "backend" rollout to finish: 0 out of 1 new replicas have been updated...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
deployment "backend" successfully rolled out

$ kubectl -n counter exec deploy/backend -- printenv FEATURE_FLAG
on

# для сравнения: тот же ConfigMap, смонтированный томом, обновляется в работающем поде сам (через ~1 минуту)
$ kubectl -n counter run cm-volume --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","600"],"volumeMounts":[{"name":"cfg","mountPath":"/cfg"}]}],"volumes":[{"name":"cfg","configMap":{"name":"backend"}}]}}' && kubectl -n counter wait --for=condition=Ready pod/cm-volume --timeout=60s
pod/cm-volume created
pod/cm-volume condition met

$ kubectl -n counter exec cm-volume -- cat /cfg/FEATURE_FLAG; echo
on

$ kubectl -n counter patch configmap backend --type merge -p '{"data":{"FEATURE_FLAG":"off"}}'
configmap/backend patched

$ for i in $(seq 1 30); do v=$(kubectl -n counter exec cm-volume -- cat /cfg/FEATURE_FLAG); [ "$v" = off ] && { echo "через ~$((i*5)) с файл в томе: $v"; break; }; sleep 5; done
через ~65 с файл в томе: off

$ kubectl -n counter exec deploy/backend -- printenv FEATURE_FLAG
on

$ kubectl -n counter delete pod cm-volume --wait=false
pod "cm-volume" deleted from counter namespace

# возвращаем ConfigMap как в репозитории (kubectl apply не удалит ключ, которого не было в last-applied, поэтому патчем)
$ kubectl -n counter patch configmap backend --type json -p '[{"op":"remove","path":"/data/FEATURE_FLAG"}]' && kubectl -n counter rollout restart deploy/backend && kubectl -n counter rollout status deploy/backend --timeout=120s && kubectl -n counter get configmap backend -o jsonpath='{.data}'
configmap/backend patched
deployment.apps/backend restarted
Waiting for deployment spec update to be observed...
Waiting for deployment "backend" rollout to finish: 0 out of 1 new replicas have been updated...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
deployment "backend" successfully rolled out
{"HOST":"0.0.0.0","PORT":"9090","PYTHONUNBUFFERED":"1"}
```
