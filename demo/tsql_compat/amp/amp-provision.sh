#!/usr/bin/env bash
# Provision an AMP cluster with tsql_compat mounted, through the controller API:
# admin user -> register the extension image -> storage pool -> cluster with
# extensions [tsql_compat] -> read_write endpoint. Writes amp.env next to it.
set -euo pipefail

API=${API:-http://127.0.0.1:18080/api/v1}
EXT_IMAGE=${EXT_IMAGE:-amp-ext-tsql_compat:1.0-poc}
CLUSTER=${CLUSTER:-tsql}
PASSWORD=${PASSWORD:-Tsql_Amp#2026}
OUT=${OUT:-$(dirname "$0")/amp.env}

req() { # method path [body]
    local out code
    out=$(curl -sS -X "$1" "$API$2" -H 'Content-Type: application/json' ${3:+-d "$3"} -w '\n%{http_code}')
    code=${out##*$'\n'}; out=${out%$'\n'*}
    case "$code" in 2??) printf '%s' "$out" ;; *) echo "$1 $2 -> $code: $out" >&2; return 1 ;; esac
}
wait_task() { # task json
    local id status
    id=$(jq -r .id <<<"$1")
    for _ in $(seq 1 600); do
        status=$(req GET "/tasks/$id" | jq -r .status)
        case "$status" in
            succeeded) return 0 ;;
            failed) req GET "/tasks/$id" | jq -r .error >&2; return 1 ;;
        esac
        sleep 1
    done
    echo "task $id timed out" >&2; return 1
}

USER_ID=$(req POST /users '{"is_admin": true}' | jq -r .id)
echo "admin user        $USER_ID"

# LOCPATH: the image ships the glibc locales FORMAT()/PARSE() switch to, which
# the endpoint image lacks (yugabyte/tsql_compat Dockerfile.amp).
req PUT "/extensions/tsql_compat?user_id=$USER_ID" "$(jq -n --arg img "$EXT_IMAGE" \
    '{image: $img, version: "1.0", description: "SQL Server (T-SQL) types and functions (yugabyte/tsql_compat)",
      layout: {env_paths: {LOCPATH: "locale"}}}')" \
    | jq -c '{name, image, builtin}'

POOL_ID=$(req POST /storage-pools "$(jq -n --arg u "$USER_ID" '{name: "pool-tsql", owner_user_id: $u}')" | jq -r .id)
echo "storage pool      $POOL_ID"

wait_task "$(req POST "/storage-pools/$POOL_ID/clusters" "$(jq -n --arg n "$CLUSTER" \
    '{name: $n, pg_version: 18, extensions: ["tsql_compat"]}')")"
CL=$(req GET "/storage-pools/$POOL_ID/clusters?limit=1000" | jq --arg n "$CLUSTER" '.clusters[] | select(.name == $n)')
CLUSTER_ID=$(jq -r .id <<<"$CL")
BRANCH_ID=$(jq -r .default_branch.branch_id <<<"$CL")
echo "cluster           $CLUSTER_ID (branch $BRANCH_ID, extensions $(jq -c .default_branch.extensions <<<"$CL"))"

B="/storage-pools/$POOL_ID/clusters/$CLUSTER_ID/branches/$BRANCH_ID"
wait_task "$(req POST "$B/endpoints" "$(jq -n --arg p "$PASSWORD" '{role: "read_write", password: $p}')")"
EP=$(req GET "$B/endpoints?limit=1000" | jq '.endpoints[] | select(.role == "read_write")')
EP_ID=$(jq -r .id <<<"$EP")
ADDR=$(jq -r .address <<<"$EP")
echo "endpoint          $EP_ID at $ADDR"

cat >"$OUT" <<EOF
AMP_USER_ID=$USER_ID
AMP_POOL_ID=$POOL_ID
AMP_CLUSTER_ID=$CLUSTER_ID
AMP_BRANCH_ID=$BRANCH_ID
AMP_ENDPOINT_ID=$EP_ID
AMP_ENDPOINT_CONTAINER=yb-ep-$EP_ID
AMP_HOST=${ADDR%:*}
AMP_PORT=${ADDR##*:}
AMP_USER=cloud_admin
AMP_PASSWORD='$PASSWORD'
EOF
echo "wrote $OUT"
