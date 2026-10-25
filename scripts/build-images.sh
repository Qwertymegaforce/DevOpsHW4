#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-1.0.0}"
BACKEND_SRC="${BACKEND_SRC:-$ROOT/src/counter-backend}"
FRONTEND_SRC="${FRONTEND_SRC:-$ROOT/src/counter-frontend}"
CLUSTER="${CLUSTER:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-course}"

docker build -t "counter-backend:${TAG}" "$BACKEND_SRC"
docker build -t "counter-frontend:${TAG}" "$FRONTEND_SRC"

for image in "counter-backend:${TAG}" "counter-frontend:${TAG}"; do
  case "$CLUSTER" in
    kind) kind load docker-image "$image" --name "$CLUSTER_NAME" ;;
    minikube) minikube image load "$image" ;;
    k3d) k3d image import "$image" --cluster "$CLUSTER_NAME" ;;
    *) echo "неизвестный CLUSTER=$CLUSTER, загрузите $image в кластер вручную" ;;
  esac
done
