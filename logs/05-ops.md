
#### 3.1 node-exporter на каждой ноде, включая control-plane

```console
$ kubectl apply -f k8s/60-node-exporter.yaml
namespace/monitoring created
daemonset.apps/node-exporter created

$ kubectl -n monitoring rollout status ds/node-exporter --timeout=120s
Waiting for daemon set spec update to be observed...
Waiting for daemon set "node-exporter" rollout to finish: 1 out of 3 new pods have been updated...
Waiting for daemon set "node-exporter" rollout to finish: 0 of 3 updated pods are available...
Waiting for daemon set "node-exporter" rollout to finish: 1 of 3 updated pods are available...
Waiting for daemon set "node-exporter" rollout to finish: 2 of 3 updated pods are available...
daemon set "node-exporter" successfully rolled out

$ kubectl get nodes -o wide
NAME                   STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION             CONTAINER-RUNTIME
course-control-plane   Ready    control-plane   25h   v1.37.0   172.20.0.4    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-38-generic (amd64)   containerd://2.3.4
course-worker          Ready    <none>          25h   v1.37.0   172.20.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-38-generic (amd64)   containerd://2.3.4
course-worker2         Ready    <none>          25h   v1.37.0   172.20.0.2    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-38-generic (amd64)   containerd://2.3.4

$ kubectl -n monitoring get ds,pods -o wide
NAME                           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE   CONTAINERS      IMAGES                                    SELECTOR
daemonset.apps/node-exporter   3         3         3       3            3           <none>          14s   node-exporter   quay.io/prometheus/node-exporter:v1.9.1   app.kubernetes.io/name=node-exporter

NAME                      READY   STATUS    RESTARTS   AGE   IP           NODE                   NOMINATED NODE   READINESS GATES
pod/node-exporter-4tjkm   1/1     Running   0          14s   172.20.0.4   course-control-plane   <none>           <none>
pod/node-exporter-fkd2g   1/1     Running   0          14s   172.20.0.2   course-worker2         <none>           <none>
pod/node-exporter-jzzgf   1/1     Running   0          14s   172.20.0.3   course-worker          <none>           <none>

# метрики снимаются с каждой ноды по её IP, порт 9100 (hostNetwork):
$ curl -s http://172.20.0.4:9100/metrics | grep -E '^node_uname_info|^node_load1 |^node_memory_MemAvailable_bytes'
node_load1 4.24
node_memory_MemAvailable_bytes 5.455671296e+09
node_uname_info{domainname="(none)",machine="x86_64",nodename="course-control-plane",release="6.8.0-38-generic",sysname="Linux",version="#38-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun  7 15:25:01 UTC 2024"} 1

$ curl -s http://172.20.0.3:9100/metrics | grep -E '^node_uname_info|^node_load1 |^node_memory_MemAvailable_bytes'
node_load1 4.24
node_memory_MemAvailable_bytes 5.463441408e+09
node_uname_info{domainname="(none)",machine="x86_64",nodename="course-worker",release="6.8.0-38-generic",sysname="Linux",version="#38-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun  7 15:25:01 UTC 2024"} 1

$ curl -s http://172.20.0.2:9100/metrics | grep -E '^node_uname_info|^node_load1 |^node_memory_MemAvailable_bytes'
node_load1 4.14
node_memory_MemAvailable_bytes 5.455945728e+09
node_uname_info{domainname="(none)",machine="x86_64",nodename="course-worker2",release="6.8.0-38-generic",sysname="Linux",version="#38-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun  7 15:25:01 UTC 2024"} 1

```

#### 3.1 агент занимает минимум ресурсов

```console
$ kubectl -n monitoring get ds node-exporter -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo
{"limits":{"cpu":"50m","memory":"64Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}

$ curl -s http://172.20.0.4:9100/metrics | grep -E '^process_resident_memory_bytes|^process_cpu_seconds_total|^go_goroutines'
go_goroutines 7
process_cpu_seconds_total 0.08
process_resident_memory_bytes 1.835008e+07

$ kubectl -n monitoring get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount
POD                   NODE                   RESTARTS
node-exporter-4tjkm   course-control-plane   0
node-exporter-fkd2g   course-worker2         0
node-exporter-jzzgf   course-worker          0

```

#### 3.2 CronJob масштабирует frontend в 9:00 и 18:00 по Москве

```console
$ kubectl apply -f k8s/70-frontend-scaler.yaml
serviceaccount/frontend-scaler created
role.rbac.authorization.k8s.io/frontend-scaler created
rolebinding.rbac.authorization.k8s.io/frontend-scaler created
cronjob.batch/frontend-scale-up created
cronjob.batch/frontend-scale-down created

$ kubectl -n counter get cronjob -o custom-columns=NAME:.metadata.name,SCHEDULE:.spec.schedule,TZ:.spec.timeZone,SA:.spec.jobTemplate.spec.template.spec.serviceAccountName,ARGS:.spec.jobTemplate.spec.template.spec.containers[0].args
NAME                  SCHEDULE     TZ              SA                ARGS
frontend-scale-down   0 18 * * *   Europe/Moscow   frontend-scaler   [scale deployment/frontend --replicas=1 --namespace=counter]
frontend-scale-up     0 9 * * *    Europe/Moscow   frontend-scaler   [scale deployment/frontend --replicas=3 --namespace=counter]

$ kubectl -n counter get role frontend-scaler -o yaml | sed -n '/^rules:/,$p'
rules:
- apiGroups:
  - apps
  resourceNames:
  - frontend
  resources:
  - deployments
  verbs:
  - get
- apiGroups:
  - apps
  resourceNames:
  - frontend
  resources:
  - deployments/scale
  verbs:
  - get
  - update
  - patch

```

#### 3.2 что автоматике разрешено и что запрещено

```console
# clustertrustbundles и selfsubject* есть у любого аутентифицированного пользователя (system:basic-user), это не наша Role
$ kubectl auth can-i --list -n counter --as=system:serviceaccount:counter:frontend-scaler | grep -vE 'selfsubject|^ *(/|\[)' 
Resources                                       Non-Resource URLs                      Resource Names   Verbs
clustertrustbundles.certificates.k8s.io         []                                     []               [get list watch]
deployments.apps/scale                          []                                     [frontend]       [get update patch]
deployments.apps                                []                                     [frontend]       [get]

$ kubectl auth can-i get deployments.apps/frontend -n counter --as=system:serviceaccount:counter:frontend-scaler
yes

$ kubectl auth can-i patch deployments.apps/frontend --subresource=scale -n counter --as=system:serviceaccount:counter:frontend-scaler
yes

$ kubectl auth can-i update deployments.apps/frontend --subresource=scale -n counter --as=system:serviceaccount:counter:frontend-scaler
yes

$ kubectl auth can-i patch deployments.apps/frontend -n counter --as=system:serviceaccount:counter:frontend-scaler
no

$ kubectl auth can-i delete deployments.apps/frontend -n counter --as=system:serviceaccount:counter:frontend-scaler
no

$ kubectl auth can-i patch deployments.apps/backend --subresource=scale -n counter --as=system:serviceaccount:counter:frontend-scaler
no

$ kubectl auth can-i get secrets -n counter --as=system:serviceaccount:counter:frontend-scaler
no

$ kubectl auth can-i create pods -n counter --as=system:serviceaccount:counter:frontend-scaler
no

$ kubectl auth can-i get pods -n counter --as=system:serviceaccount:counter:frontend-scaler
no

# Role действует только в своём namespace:
$ kubectl auth can-i patch deployments.apps/frontend --subresource=scale -n team-blue --as=system:serviceaccount:counter:frontend-scaler
no

# попытки сделать что-то кроме масштабирования frontend от имени этого ServiceAccount:
$ kubectl -n counter scale deploy/backend --replicas=3 --as=system:serviceaccount:counter:frontend-scaler
Error from server (Forbidden): deployments.apps "backend" is forbidden: User "system:serviceaccount:counter:frontend-scaler" cannot get resource "deployments" in API group "apps" in the namespace "counter"

$ kubectl -n counter set image deploy/frontend frontend=nginx --as=system:serviceaccount:counter:frontend-scaler
error: failed to patch image update to pod template: deployments.apps "frontend" is forbidden: User "system:serviceaccount:counter:frontend-scaler" cannot patch resource "deployments" in API group "apps" in the namespace "counter"

$ kubectl -n counter get secret postgres-auth --as=system:serviceaccount:counter:frontend-scaler
Error from server (Forbidden): secrets "postgres-auth" is forbidden: User "system:serviceaccount:counter:frontend-scaler" cannot get resource "secrets" in API group "" in the namespace "counter"

```

#### 3.2 запуск вне расписания

```console
$ kubectl -n counter get deploy frontend
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
frontend   1/1     1            1           12m

$ kubectl -n counter create job scale-up-manual --from=cronjob/frontend-scale-up
job.batch/scale-up-manual created

$ kubectl -n counter wait --for=condition=Complete job/scale-up-manual --timeout=120s
job.batch/scale-up-manual condition met

$ kubectl -n counter logs job/scale-up-manual
deployment.apps/frontend scaled

$ kubectl -n counter rollout status deploy/frontend --timeout=180s && kubectl -n counter get deploy frontend && kubectl -n counter get pods -l app.kubernetes.io/name=frontend -o wide
Waiting for deployment "frontend" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "frontend" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "frontend" rollout to finish: 1 of 3 updated replicas are available...
deployment "frontend" successfully rolled out
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
frontend   3/3     3            3           12m
NAME                       READY   STATUS    RESTARTS   AGE   IP            NODE             NOMINATED NODE   READINESS GATES
frontend-d4cff988f-hsxwh   1/1     Running   0          16s   10.244.2.34   course-worker    <none>           <none>
frontend-d4cff988f-mn6fm   1/1     Running   0          12m   10.244.1.47   course-worker2   <none>           <none>
frontend-d4cff988f-n4r4s   1/1     Running   0          16s   10.244.2.33   course-worker    <none>           <none>

$ kubectl -n counter create job scale-down-manual --from=cronjob/frontend-scale-down
job.batch/scale-down-manual created

$ kubectl -n counter wait --for=condition=Complete job/scale-down-manual --timeout=120s
job.batch/scale-down-manual condition met

$ kubectl -n counter logs job/scale-down-manual
deployment.apps/frontend scaled

$ kubectl -n counter get deploy frontend
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
frontend   1/1     1            1           12m

$ kubectl -n counter get jobs
NAME                STATUS     COMPLETIONS   DURATION   AGE
scale-down-manual   Complete   1/1           6s         7s
scale-up-manual     Complete   1/1           29s        47s

```
