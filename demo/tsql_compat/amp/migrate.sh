#!/usr/bin/env bash
# SQL Server (demo-mssql) -> AMP, through the controller's migration API:
# create migration -> assess -> provision target -> migrate, polling the
# migration's state. Each run is a new migration with its own target cluster
# (tsql_compat mounted by the controller). Then every migrated object is run
# once and a few T-SQL queries are shown against the migrated data.
#
# Needs amp-up.sh (migration APIs on, AMP_ORA2PG_IMAGE set) and amp.env from
# amp-provision.sh (for the storage pool).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/amp.env"
DEMO=${DEMO:-$HERE/..}
NET=${NET:-amp-tsql}
API=${API:-http://127.0.0.1:18080/api/v1}
OUT=output-amp
cd "$DEMO"

docker network connect "$NET" demo-mssql 2>/dev/null || true
rm -rf "$OUT" && mkdir -p "$OUT"

# GETs are retried on a 5xx (the controller can answer one while a job's DDL is
# in flight); writes are not.
req() { # method path [body]
    local out code try
    for try in 1 2 3 4 5; do
        out=$(curl -sS -X "$1" "$API$2" -H 'Content-Type: application/json' ${3:+-d "$3"} -w '\n%{http_code}')
        code=${out##*$'\n'}; out=${out%$'\n'*}
        [ "$1" = GET ] && [[ "$code" == 5?? ]] && { sleep 1; continue; }
        break
    done
    case "$code" in 2??) printf '%s' "$out" ;; *) echo "$1 $2 -> $code: $out" >&2; return 1 ;; esac
}

# wait_state state: poll the migration until it reaches the state. On failure,
# print the failed run and the tail of its job container's log.
wait_state() {
    local st m
    for _ in $(seq 1 900); do
        m=$(req GET "/migrations/$MIGRATION_ID"); st=$(jq -r .state <<<"$m")
        [ "$st" = "$1" ] && { echo "  state: $st"; return 0; }
        if [ "$st" = failed ]; then
            echo "  state: failed ($(jq -r .detail <<<"$m"))" >&2
            docker logs "$(jq -r '.runs | max_by(.started_at) | .deployer_metadata.container_id' <<<"$m")" 2>&1 \
                | tr '\r' '\n' | grep -v '^\[20' | tail -15 | sed 's/^/    /' >&2
            exit 1
        fi
        sleep 2
    done
    echo "timed out waiting for state $1" >&2; exit 1
}

SOURCE=$(jq -n --arg pwd "$(awk '$1 == "ORACLE_PWD" {print $2}' ora2pg.conf)" \
    '{db_type: "sqlserver", host: "demo-mssql", port: 1433, username: "sa",
      password: $pwd, database: "shop", schemas: ["dbo"]}')

echo "== connectivity check"
req POST /migrations/connectivity-checks "$(jq -n --argjson s "$SOURCE" '{source: $s}')" | jq -c . | sed 's/^/  /'

echo "== create migration"
MIGRATION_ID=$(req POST /migrations "$(jq -n --arg n "shop-$(date +%m%d-%H%M%S)" --argjson s "$SOURCE" \
    '{name: $n, source: $s}')" | jq -r .id)
echo "$MIGRATION_ID" > "$OUT/migration_id"
echo "  id: $MIGRATION_ID"

echo "== assessment"
req POST "/migrations/$MIGRATION_ID/assess" >/dev/null
wait_state assessed
req GET "/migrations/$MIGRATION_ID/assessment" > "$OUT/assessment.json"
jq -r '"  complexity: \(.migration_complexity) — \(.migration_complexity_explanation)",
       (.issues[] | "  review: \(.object_type) \(.object_name)")' "$OUT/assessment.json"

echo "== provision target"
req POST "/migrations/$MIGRATION_ID/provision-target" "$(jq -n --arg p "$AMP_POOL_ID" '{pool_id: $p}')" >/dev/null
wait_state target_ready
TARGET=$(req GET "/migrations/$MIGRATION_ID" | jq .target)
CLUSTER=$(req GET "/storage-pools/$AMP_POOL_ID/clusters/$(jq -r .cluster_id <<<"$TARGET")")
echo "  cluster $(jq -r .id <<<"$CLUSTER"), extensions $(jq -c .default_branch.extensions <<<"$CLUSTER")"

echo "== migrate"
req POST "/migrations/$MIGRATION_ID/migrate" '{}' >/dev/null
wait_state completed

# The credential is the controller's fixed placeholder for migration targets.
export PGHOST=$(jq -r .host <<<"$TARGET") PGPORT=$(jq -r .port <<<"$TARGET") \
       PGUSER=$(jq -r .username <<<"$TARGET") PGDATABASE=shop PGPASSWORD=cloud_admin
echo "  target: psql -h $PGHOST -p $PGPORT -U $PGUSER -d shop (password cloud_admin)"

# Run every migrated object once. Procedures and the trigger change data, so they
# run in a transaction that is rolled back. One line per object: OK or the error.
echo "== objects"
obj() { # name type sql
    local res
    if res=$(psql -X -v ON_ERROR_STOP=1 -Atq -c "$3" 2>&1); then
        printf '%-22s %-10s OK\n' "$1" "$2"
    else
        printf '%-22s %-10s %s\n' "$1" "$2" "$(grep -m1 -E 'ERROR' <<<"$res" | sed 's/^.*ERROR: *//')"
    fi
}
{ for t in customers orders order_items; do obj "$t" table "SELECT count(*) FROM $t"; done
  obj v_customer_summary view "SELECT * FROM v_customer_summary"
  obj fn_order_age function "SELECT fn_order_age(order_date) FROM orders"
  obj usp_place_order procedure "BEGIN; CALL usp_place_order(1, 'Widget', 2::smallint, 9.99::money); ROLLBACK;"
  obj usp_customer_stats procedure "BEGIN; CALL usp_customer_stats(1); ROLLBACK;"
  obj trg_customers_touch trigger "BEGIN; UPDATE customers SET rating = rating WHERE customer_id = 1; ROLLBACK;"
} | tee "$OUT/objects.txt" | sed 's/^/  /'

echo "== T-SQL on AMP"
psql -X -P footer=off \
    -c "SELECT customer_id, full_name, is_active, rating, credit_limit, created_at, signup_tz, badge FROM customers ORDER BY customer_id" \
    -c "SELECT * FROM v_customer_summary ORDER BY customer_id" \
    -c "SELECT order_id, order_date, DATEADD('day', 30, order_date) AS due_date FROM orders ORDER BY order_id" \
    -c "SELECT customer_id, full_name, LEN(full_name), CHARINDEX(' ', full_name), ISNULL(email, 'no email'), IIF(is_active = 1, 'active', 'inactive'), DATENAME('month', created_at), EOMONTH(created_at::date) FROM customers ORDER BY customer_id" \
    | tee "$OUT/tsql_results.txt"
