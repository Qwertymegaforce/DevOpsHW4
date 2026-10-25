#!/bin/sh
set -eu

NAME="${1:?usage: $0 NODE_NAME}"
CLUSTER="${CLUSTER_NAME:-course}"
CP="$CLUSTER-control-plane"
IMAGE="$(docker inspect "$CP" --format '{{.Config.Image}}')"

docker run -d --tty --init=false --cgroupns=private --name "$NAME" --hostname "$NAME" --network kind --privileged \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt label=disable \
  --tmpfs /tmp --tmpfs /run -v /var -v /lib/modules:/lib/modules:ro \
  -e KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER --restart=on-failure:1 \
  --label io.x-k8s.kind.cluster="$CLUSTER" --label io.x-k8s.kind.role=worker \
  "$IMAGE" >/dev/null

i=0
until docker exec "$NAME" systemctl is-active -q containerd 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 60 ] || [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != true ]; then
    echo "нода $NAME не запустилась:" >&2
    docker logs "$NAME" 2>&1 | grep -v '^INFO' | tail -5 >&2
    exit 1
  fi
  sleep 1
done

IP="$(docker inspect "$NAME" --format '{{.NetworkSettings.Networks.kind.IPAddress}}')"
TOKEN="$(docker exec "$CP" kubeadm token create --ttl 15m)"

docker exec -i "$NAME" sh -c 'cat > /kind/kubeadm.conf' <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: $CP:6443
    token: $TOKEN
    unsafeSkipCAVerification: true
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: $IP
    - name: provider-id
      value: kind://docker/$CLUSTER/$NAME
skipPhases:
  - preflight
EOF

docker exec "$NAME" kubeadm join --config /kind/kubeadm.conf 2>&1 | tail -3

IMAGES="$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^counter-(backend|frontend):' || true)"
if [ -n "$IMAGES" ]; then
  kind load docker-image $IMAGES --name "$CLUSTER" --nodes "$NAME" 2>&1 | tail -1
fi
