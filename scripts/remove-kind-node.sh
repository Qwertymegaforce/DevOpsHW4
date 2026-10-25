#!/bin/sh
set -eu
NAME="${1:?usage: $0 NODE_NAME}"
kubectl drain "$NAME" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
kubectl delete node "$NAME"
docker rm -f "$NAME" >/dev/null
echo "контейнер $NAME удалён"
