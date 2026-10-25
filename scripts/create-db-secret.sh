#!/bin/sh
set -eu

NAMESPACE="${NAMESPACE:-counter}"

if kubectl -n "$NAMESPACE" get secret postgres-auth >/dev/null 2>&1; then
  echo "secret/postgres-auth уже существует в namespace $NAMESPACE, пропускаю"
  exit 0
fi

kubectl -n "$NAMESPACE" create secret generic postgres-auth \
  --from-literal=POSTGRES_USER=counter \
  --from-literal=POSTGRES_DB=counter \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
