#!/bin/sh
NS="${1:-}"
for node in $(kind get nodes --name "${CLUSTER_NAME:-course}"); do
  docker exec "$node" crictl stats -o json 2>/dev/null | NODE="$node" NS="$NS" python3 -c '
import json, os, sys
for s in json.load(sys.stdin)["stats"]:
    l = s["attributes"]["labels"]
    if os.environ["NS"] and l.get("io.kubernetes.pod.namespace") != os.environ["NS"]:
        continue
    mem = s.get("memory", {}).get("workingSetBytes", {}).get("value")
    cpu = s.get("cpu", {}).get("usageNanoCores", {}).get("value")
    if mem is None:
        continue
    print("%-45s %-12s %6.1f MiB %5s mCPU" % (l.get("io.kubernetes.pod.name"), l.get("io.kubernetes.container.name"),
          int(mem) / 2**20, int(cpu) // 10**6 if cpu is not None else "?"))
'
done | sort
