#!/usr/bin/env bash
# AMP on Docker for the tsql_compat POC: YugabyteDB + the controller with its
# Docker endpoint driver, all on one user-defined network. The controller then
# launches endpoint containers itself (meko/amp/test/integration/controller/
# run-controller.sh, kept running instead of torn down).
#
#   ./amp-up.sh          bring the stack up (idempotent; to pick up a new
#                        controller image: docker rm -f amp-controller first)
#   ./amp-up.sh down     remove it (controller, endpoints, YB, network)
set -euo pipefail

NET=${NET:-amp-tsql}
YB_CONTAINER=${YB_CONTAINER:-amp-yb}
YB_IMAGE=${YB_IMAGE:-yugabytedb/yugabyte:2026.1.2.0-b137}
DB=${DB:-yb_storage}
CONTROLLER=${CONTROLLER:-amp-controller}
CONTROLLER_IMAGE=${CONTROLLER_IMAGE:-yb-amp/controller:tsql-poc}
ENDPOINT_IMAGE=${ENDPOINT_IMAGE:-yb-amp/neon-endpoint:tsql-poc}
API_PORT=${API_PORT:-18080}
# Migration APIs: migration state lives in its own YB database; PostgreSQL
# sources run on the Voyager image, SQL Server sources on the Ora2Pg one
# (meko/amp/deploy/ora2pg).
VOYAGER_DB=${VOYAGER_DB:-yb_voyager}
VOYAGER_IMAGE=${VOYAGER_IMAGE:-454529406029.dkr.ecr.us-west-2.amazonaws.com/amp/voyager:ubuntu-0d6d579ff}
ORA2PG_IMAGE=${ORA2PG_IMAGE:-amp-ora2pg:local}

yb() { docker exec "$YB_CONTAINER" bash -c 'bin/ysqlsh -h "$(hostname -i)" -p 5433 -U yugabyte -d yugabyte "$@"' _ "$@"; }

if [ "${1:-up}" = down ]; then
    docker ps -aq --filter "network=$NET" | xargs -r docker rm -f >/dev/null
    docker network rm "$NET" >/dev/null 2>&1 || true
    echo "amp-up: removed"
    exit 0
fi

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# yugabyted binds the container's own address, and Docker isolates networks from
# one another, so YB must sit on the endpoints' network: they reach YSQL and the
# tserver RPC port (9100, the direct lane) at $YB_CONTAINER by name.
if ! docker ps -q --filter "name=^${YB_CONTAINER}$" | grep -q .; then
    docker rm -f "$YB_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$YB_CONTAINER" --hostname "$YB_CONTAINER" --network "$NET" \
        -p 127.0.0.1:5433:5433 "$YB_IMAGE" bin/yugabyted start --background=false >/dev/null
fi
echo "amp-up: waiting for YugabyteDB"
for _ in $(seq 1 120); do yb -tAc 'select 1' >/dev/null 2>&1 && break; sleep 2; done
yb -tAc 'select 1' >/dev/null
for d in "$DB" "$VOYAGER_DB"; do
    yb -tAc "SELECT 1 FROM pg_database WHERE datname='$d'" | grep -q 1 || yb -c "CREATE DATABASE $d" >/dev/null
done

if ! docker ps -q --filter "name=^${CONTROLLER}$" | grep -q .; then
    docker rm -f "$CONTROLLER" >/dev/null 2>&1 || true
    # --user root + the socket let the Docker driver launch endpoint containers.
    docker run -d --name "$CONTROLLER" --hostname "$CONTROLLER" --network "$NET" \
        --user root -p "127.0.0.1:${API_PORT}:8080" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e "AMP_DATABASE_URL=postgres://yugabyte@${YB_CONTAINER}:5433/${DB}" \
        -e AMP_LOG_FORMAT=text \
        -e AMP_DEPLOY=true \
        -e AMP_DEPLOY_DRIVER=docker \
        -e AMP_DEPLOY_NETWORK="$NET" \
        -e AMP_DEPLOY_ENDPOINT_IMAGE="$ENDPOINT_IMAGE" \
        -e AMP_DEPLOY_EXTERNAL_HOST=127.0.0.1 \
        -e AMP_DEPLOY_YB_HOST_PORTS="${YB_CONTAINER}:5433" \
        -e AMP_DEPLOY_YB_DBNAME="$DB" \
        -e "AMP_VOYAGER_DATABASE_URL=postgres://yugabyte@${YB_CONTAINER}:5433/${VOYAGER_DB}" \
        -e AMP_VOYAGER_IMAGE="$VOYAGER_IMAGE" \
        -e AMP_ORA2PG_IMAGE="$ORA2PG_IMAGE" \
        "$CONTROLLER_IMAGE" >/dev/null
fi
echo "amp-up: waiting for the controller"
for _ in $(seq 1 90); do
    curl -sf -m2 "http://127.0.0.1:${API_PORT}/readyz" >/dev/null && break
    docker ps -q --filter "name=^${CONTROLLER}$" | grep -q . || { docker logs "$CONTROLLER" 2>&1 | tail -30; exit 1; }
    sleep 1
done
curl -sf -m2 "http://127.0.0.1:${API_PORT}/readyz" >/dev/null
echo "amp-up: controller ready at http://127.0.0.1:${API_PORT}/api/v1"
