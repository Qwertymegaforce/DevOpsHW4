#!/bin/sh
set -u

URL="${1:?usage: $0 URL [CA_FILE]}"
CA="${2:-ca.crt}"
TMP="$(mktemp)"

summary() {
  echo
  echo "== итог: количество ответов по HTTP-кодам (000 = соединение не удалось) =="
  sort "$TMP" | uniq -c
  rm -f "$TMP"
  exit 0
}
trap summary INT TERM

while :; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" --max-time 2 "$URL" || true)"
  echo "$(date +%T) $code"
  echo "$code" >>"$TMP"
  sleep 0.2
done
