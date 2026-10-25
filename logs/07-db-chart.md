
#### БД включается параметром postgres.enabled

```console
$ kubectl -n team-blue get statefulset,pvc,secret -l app.kubernetes.io/instance=blue
No resources found in team-blue namespace.

$ helm upgrade blue charts/counter -n team-blue --reuse-values --set postgres.enabled=true --wait --timeout 5m
Release "blue" has been upgraded. Happy Helming!
NAME: blue
LAST DEPLOYED: Sun Oct 25 11:33:55 2026
NAMESPACE: team-blue
STATUS: deployed
REVISION: 6
TEST SUITE: None
NOTES:
Релиз blue установлен в namespace team-blue.

Адрес:  https://blue.localtest.me
Проверка сертификата без -k:
  kubectl -n team-blue get secret blue-counter-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/blue-ca.crt
  curl --cacert /tmp/blue-ca.crt https://blue.localtest.me/api/counter

PostgreSQL: blue-counter-postgres-0.blue-counter-postgres
Пароль: kubectl -n team-blue get secret blue-counter-postgres-auth -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
(Secret и PVC переживают helm uninstall.)

$ kubectl -n team-blue get statefulset,pod,svc,pvc -l app.kubernetes.io/component=postgres; kubectl -n team-blue get pvc
NAME                                     READY   AGE
statefulset.apps/blue-counter-postgres   1/1     3m47s

NAME                          READY   STATUS    RESTARTS   AGE
pod/blue-counter-postgres-0   1/1     Running   0          3m46s

NAME                            TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)    AGE
service/blue-counter-postgres   ClusterIP   None         <none>        5432/TCP   3m47s

NAME                                                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/data-blue-counter-postgres-0   Bound    pvc-dc4e68f6-d2c8-4728-92c1-c45792d2c2eb   1Gi        RWO            standard       <unset>                 3m47s
NAME                           STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
data-blue-counter-postgres-0   Bound    pvc-dc4e68f6-d2c8-4728-92c1-c45792d2c2eb   1Gi        RWO            standard       <unset>                 3m47s

$ kubectl -n team-blue exec blue-counter-postgres-0 -- psql -U counter -d counter -v ON_ERROR_STOP=1 -c 'update counter set value = 777 where id = 1 returning *'
 id | value 
----+-------
  1 |   777
(1 row)

UPDATE 1

# отпечаток пароля (sha256 от base64, сам пароль не показываем): 654d306d8755c4ae
```

#### БД выключается параметром — StatefulSet удалён, PVC и Secret остались

```console
$ helm upgrade blue charts/counter -n team-blue --reuse-values --set postgres.enabled=false --wait --timeout 5m
Release "blue" has been upgraded. Happy Helming!
NAME: blue
LAST DEPLOYED: Sun Oct 25 11:37:47 2026
NAMESPACE: team-blue
STATUS: deployed
REVISION: 7
TEST SUITE: None
NOTES:
Релиз blue установлен в namespace team-blue.

Адрес:  https://blue.localtest.me
Проверка сертификата без -k:
  kubectl -n team-blue get secret blue-counter-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/blue-ca.crt
  curl --cacert /tmp/blue-ca.crt https://blue.localtest.me/api/counter

$ kubectl -n team-blue get statefulset,pods -l app.kubernetes.io/component=postgres; kubectl -n team-blue get pvc,secret -l app.kubernetes.io/component=postgres
No resources found in team-blue namespace.
NAME                                                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/data-blue-counter-postgres-0   Bound    pvc-dc4e68f6-d2c8-4728-92c1-c45792d2c2eb   1Gi        RWO            standard       <unset>                 4m1s

NAME                                TYPE     DATA   AGE
secret/blue-counter-postgres-auth   Opaque   3      4m1s

$ kubectl -n team-blue get pvc data-blue-counter-postgres-0
NAME                           STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
data-blue-counter-postgres-0   Bound    pvc-dc4e68f6-d2c8-4728-92c1-c45792d2c2eb   1Gi        RWO            standard       <unset>                 4m1s

```

#### Удаляем релиз целиком и ставим заново — данные на месте

```console
$ helm uninstall blue -n team-blue
release "blue" uninstalled

$ kubectl -n team-blue get all
NAME                                         READY   STATUS        RESTARTS   AGE
pod/blue-canary-counter-verify-ppkjr         0/1     Completed     0          6m52s
pod/blue-counter-backend-74746cd6df-vrrsf    1/1     Terminating   0          4m31s
pod/blue-counter-frontend-744487f447-z5pbb   1/1     Terminating   0          8m32s
pod/blue-counter-verify-25qpj                0/1     Completed     0          13s

NAME                                   STATUS     COMPLETIONS   DURATION   AGE
job.batch/blue-canary-counter-verify   Complete   1/1           9s         6m52s
job.batch/blue-counter-verify          Complete   1/1           9s         13s

$ kubectl -n team-blue get pvc,secret
NAME                                                 STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
persistentvolumeclaim/data-blue-counter-postgres-0   Bound    pvc-dc4e68f6-d2c8-4728-92c1-c45792d2c2eb   1Gi        RWO            standard       <unset>                 4m4s

NAME                                TYPE                DATA   AGE
secret/blue-canary-counter-ca       kubernetes.io/tls   3      7m5s
secret/blue-canary-counter-tls      kubernetes.io/tls   3      7m4s
secret/blue-counter-ca              kubernetes.io/tls   3      8m21s
secret/blue-counter-postgres-auth   Opaque              3      4m4s
secret/blue-counter-tls             kubernetes.io/tls   3      8m20s

$ helm install blue charts/counter -n team-blue --set postgres.enabled=true --wait --timeout 5m
NAME: blue
LAST DEPLOYED: Sun Oct 25 11:38:03 2026
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

PostgreSQL: blue-counter-postgres-0.blue-counter-postgres
Пароль: kubectl -n team-blue get secret blue-counter-postgres-auth -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
(Secret и PVC переживают helm uninstall.)

$ kubectl -n team-blue get statefulset,pod -l app.kubernetes.io/component=postgres
NAME                                     READY   AGE
statefulset.apps/blue-counter-postgres   1/1     22s

NAME                          READY   STATUS    RESTARTS   AGE
pod/blue-counter-postgres-0   1/1     Running   0          22s

$ kubectl -n team-blue exec blue-counter-postgres-0 -- psql -U counter -d counter -v ON_ERROR_STOP=1 -c 'select * from counter'
 id | value 
----+-------
  1 |   777
(1 row)


# пароль тот же, что и до удаления релиза (иначе БД, инициализированная старым паролем, не пустила бы клиентов): 654d306d8755c4ae
# подключение по сети с паролем из Secret из другого пода:
$ kubectl -n team-blue run psql-check --restart=Never --image=postgres:16-alpine --overrides='{"spec":{"containers":[{"name":"psql-check","image":"postgres:16-alpine","command":["psql","-h","blue-counter-postgres-0.blue-counter-postgres","-c","select value from counter"],"envFrom":[{"secretRef":{"name":"blue-counter-postgres-auth"}}],"env":[{"name":"PGUSER","value":"counter"},{"name":"PGDATABASE","value":"counter"},{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"blue-counter-postgres-auth","key":"POSTGRES_PASSWORD"}}}]}]}}'
pod/psql-check created

$ kubectl -n team-blue wait --for=jsonpath='{.status.phase}'=Succeeded pod/psql-check --timeout=120s
pod/psql-check condition met

$ kubectl -n team-blue logs psql-check
 value 
-------
   777
(1 row)


$ kubectl -n team-blue delete pod psql-check
pod "psql-check" deleted from team-blue namespace

```
