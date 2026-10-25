#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-course}"
INGRESS_MANIFEST="${INGRESS_MANIFEST:-https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml}"

if [ "$(sysctl -n fs.inotify.max_user_instances)" -lt 512 ]; then
  echo "ВНИМАНИЕ: выполните sudo sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288"
fi

if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --config "$ROOT/cluster/kind-config.yaml"
fi
kubectl config use-context "kind-$CLUSTER_NAME"
kubectl wait --for=condition=Ready node --all --timeout=180s

kubectl apply -f "$INGRESS_MANIFEST"
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Equal","effect":"NoSchedule"}]}}}}'
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"20m"}]'
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s

helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true --wait

"$ROOT/scripts/build-images.sh" "${1:-1.0.0}"
