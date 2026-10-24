#!/usr/bin/env bash
# Prueba de humo de las imágenes: genera dos días en un lago local temporal, monta el
# lago en cada contenedor y lo dispara como lo haría la nube (emulador de Lambda y
# Pub/Sub push simulado). Las peticiones salen desde dentro del contenedor para no
# depender del port forwarding del host.
#
#   scripts/smoke_images.sh            # usa docker
#   DOCKER=podman scripts/smoke_images.sh
set -euo pipefail

DOCKER=${DOCKER:-docker}
PYTHON=${PYTHON:-.venv/bin/python}
AWS_IMAGE=${AWS_IMAGE:-lakehouse:aws}
GCP_IMAGE=${GCP_IMAGE:-lakehouse:gcp}

# Un lago por imagen: la de Lambda corre como root y la de Cloud Run como uid 1000,
# así que no comparten carpetas escribibles.
WORK=$(mktemp -d)
cleanup() {
  $DOCKER rm -f lh-smoke-aws lh-smoke-gcp >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

LAKE_ROOT="$WORK/raw-only" "$PYTHON" -m lakehouse.cli generate --start 2026-10-20 --end 2026-10-21 >/dev/null
for image in aws gcp; do
  cp -r "$WORK/raw-only" "$WORK/$image"
  chmod -R a+rwX "$WORK/$image"
done

wait_ready() {  # $1 contenedor, $2 texto en logs
  for _ in $(seq 60); do
    if $DOCKER logs "$1" 2>&1 | grep -q "$2"; then return 0; fi
    sleep 1
  done
  echo "timeout esperando a $1" >&2
  $DOCKER logs "$1" >&2
  return 1
}

echo "== AWS Lambda (${AWS_IMAGE})"
$DOCKER run -d --name lh-smoke-aws --read-only --tmpfs /tmp \
  -v "$WORK/aws:/lake:z" -e LAKE_ROOT=/lake -e DBT_TARGET=local "$AWS_IMAGE" >/dev/null
sleep 2
$DOCKER exec -i lh-smoke-aws python - <<'PY'
import json, sys, urllib.request
url = "http://127.0.0.1:8080/2015-03-31/functions/function/invocations"
key = "raw/ecommerce/_markers/year%3D2026/month%3D10/day%3D{}/_SUCCESS"
for day in (20, 21):
    event = {"Records": [{"s3": {"object": {"key": key.format(day)}}}]}
    req = urllib.request.Request(url, data=json.dumps(event).encode())
    out = json.loads(urllib.request.urlopen(req, timeout=600).read())
    runs = out.get("runs") or []
    print(day, out if not runs else [(r["run_date"], r["success"]) for r in runs])
    if not runs or not all(r["success"] for r in runs):
        sys.exit(1)
PY

echo "== GCP Cloud Run (${GCP_IMAGE})"
$DOCKER run -d --name lh-smoke-gcp \
  -v "$WORK/gcp:/lake:z" -e LAKE_ROOT=/lake -e DBT_TARGET=local "$GCP_IMAGE" >/dev/null
wait_ready lh-smoke-gcp "escuchando"
$DOCKER exec -i lh-smoke-gcp python - <<'PY'
import base64, json, sys, urllib.request
def post(body):
    req = urllib.request.Request("http://127.0.0.1:8080/", data=json.dumps(body).encode())
    return json.loads(urllib.request.urlopen(req, timeout=600).read())
name = "raw/ecommerce/_markers/year=2026/month=10/day=21/_SUCCESS"
data = base64.b64encode(json.dumps({"name": name}).encode()).decode()
out = post({"message": {"data": data, "attributes": {}}})
print(out.get("runs") and [(r["run_date"], r["success"]) for r in out["runs"]])
if not out.get("runs") or not out["runs"][0]["success"]:
    sys.exit(1)
if not post({"message": {"attributes": {"objectId": "gold/x.parquet"}}}).get("skipped"):
    sys.exit(1)
PY

for image in aws gcp; do
  test -f "$WORK/$image/gold/daily_sales.parquet" || { echo "$image: falta gold/daily_sales.parquet" >&2; exit 1; }
done
echo "OK"
