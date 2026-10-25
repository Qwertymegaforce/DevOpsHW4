NS="${NS:-counter}"
HOST="${HOST:-counter.localtest.me}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CA="${CA:-$ROOT/ca.crt}"
_open=""

step() {
  [ -n "$_open" ] && printf '```\n'
  printf '\n#### %s\n\n```console\n' "$*"
  _open=1
}

run() {
  printf '$ %s\n' "$*"
  sh -c "$*" 2>&1
  printf '\n'
}

note() { printf '# %s\n' "$*"; }

loop() {
  end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    out="$(curl -s --cacert "$CA" --max-time 2 -w ' %{http_code}' "https://$HOST/api/counter" || true)"
    echo "$(date +%T) ${out:-000}"
    sleep 0.25
  done >"$2"
}

settle() {
  want="$(kubectl -n "${2:-$NS}" get deploy "$1" -o jsonpath='{.spec.replicas}')"
  sel="$(kubectl -n "${2:-$NS}" get deploy "$1" -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')"
  while [ "$(kubectl -n "${2:-$NS}" get pods -l "$sel" --no-headers 2>/dev/null | wc -l)" -ne "$want" ]; do sleep 1; done
}

squash() {
  awk '{t=$1; $1=""; if ($0==prev) {n++; last=t} else {if (NR>1) print first (n>1 ? "-" last " x" n : ""), prev; prev=$0; first=t; last=t; n=1}} END {print first (n>1 ? "-" last " x" n : ""), prev}' "$1"
}

finish() { [ -n "$_open" ] && printf '```\n'; _open=""; }
