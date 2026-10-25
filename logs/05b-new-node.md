
#### 3.1 на новой ноде агент появляется автоматически

```console
$ sysctl fs.inotify.max_user_instances
fs.inotify.max_user_instances = 512

$ kubectl get nodes
NAME                   STATUS   ROLES           AGE   VERSION
course-control-plane   Ready    control-plane   25h   v1.37.0
course-worker          Ready    <none>          25h   v1.37.0
course-worker2         Ready    <none>          25h   v1.37.0

$ kubectl -n monitoring get ds node-exporter
NAME            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-exporter   3         3         3       3            3           <none>          8m5s

# добавляем новую ноду — в манифестах ничего не меняем и ничего не применяем:
$ ./scripts/add-kind-node.sh course-worker4

Run 'kubectl get nodes' on the control-plane to see this node join the cluster.

Image: "counter-backend:1.0.1" with ID "sha256:c33548490f09d99a934f1da2a38ffc464160dc883707e4918ab8dce7d1def311" not yet present on node "course-worker4", loading...

$ kubectl wait --for=condition=Ready node/course-worker4 --timeout=180s
node/course-worker4 condition met

$ kubectl -n monitoring rollout status ds/node-exporter --timeout=180s
daemon set "node-exporter" successfully rolled out

$ kubectl get nodes -o wide
NAME                   STATUS   ROLES           AGE    VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION             CONTAINER-RUNTIME
course-control-plane   Ready    control-plane   25h    v1.37.0   172.20.0.4    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-38-generic (amd64)   containerd://2.3.4
course-worker          Ready    <none>          25h    v1.37.0   172.20.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-38-generic (amd64)   containerd://2.3.4
course-worker2         Ready    <none>          25h    v1.37.0   172.20.0.2    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-38-generic (amd64)   containerd://2.3.4
course-worker4         Ready    <none>          2m7s   v1.37.0   172.20.0.5    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-38-generic (amd64)   containerd://2.3.4

$ kubectl -n monitoring get ds node-exporter; kubectl -n monitoring get pods -o wide
NAME            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-exporter   4         4         4       4            4           <none>          10m
NAME                  READY   STATUS    RESTARTS   AGE    IP           NODE                   NOMINATED NODE   READINESS GATES
node-exporter-4tjkm   1/1     Running   0          10m    172.20.0.4   course-control-plane   <none>           <none>
node-exporter-9p49s   1/1     Running   0          2m7s   172.20.0.5   course-worker4         <none>           <none>
node-exporter-fkd2g   1/1     Running   0          10m    172.20.0.2   course-worker2         <none>           <none>
node-exporter-jzzgf   1/1     Running   0          10m    172.20.0.3   course-worker          <none>           <none>

$ curl -s http://172.20.0.5:9100/metrics | grep -E '^node_uname_info|^node_load1 '
node_load1 26.67
node_uname_info{domainname="(none)",machine="x86_64",nodename="course-worker4",release="6.8.0-38-generic",sysname="Linux",version="#38-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun  7 15:25:01 UTC 2024"} 1

```
