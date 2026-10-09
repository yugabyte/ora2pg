# SQL Server to AMP with Ora2Pg and tsql_compat

The SQL Server `shop` database of the parent demo, migrated into an AMP
endpoint running on Docker. The migration goes through the AMP controller's
migration API, which runs Ora2Pg (`USE_TSQL_COMPAT 1`) in a job container and
provisions a target cluster with the `tsql_compat` extension mounted.

Files:

- `amp-up.sh`: YugabyteDB and the AMP controller (Docker endpoint driver,
  migration APIs on), on the Docker network `amp-tsql`
- `amp-provision.sh`: registers the `tsql_compat` extension image, creates a
  storage pool, a cluster and an endpoint; writes `amp.env`
- `migrate.sh`: SQL Server to AMP through the migration API, then runs every
  migrated object once and shows T-SQL queries on the migrated data
- `RESULTS.md`: what migrates and what does not
- `FOLLOWUPS.md`: what is left out
- `postgres-vs-sqlserver-migration.md`: how the controller handles a
  `postgresql` and a `sqlserver` source

Needs Linux x86_64, Docker Engine 28 or newer (image mounts), `jq`, `curl` and
`psql`.

## Images

| Image | Built from |
|---|---|
| `yb-amp/neon-endpoint:tsql-poc` | `yugabyte/meko` `amp/deploy/endpoint/Dockerfile` |
| `yb-amp/controller:tsql-poc` | `yugabyte/meko` `amp/deploy/controller/Dockerfile` |
| `amp-ext-tsql_compat:1.0-poc` | `yugabyte/tsql_compat` `Dockerfile.amp` |
| `ora2pg-tsql` | `../Dockerfile` (this repository) |
| `amp-ora2pg:local` | `yugabyte/meko` `amp/deploy/ora2pg/Dockerfile` |

Use branch `ameya/tsql-compat-amp` of `yugabyte/meko`, `yugabyte/ora2pg` and
`AmeyaKasture/tsql_compat` (a fork of `yugabyte/tsql_compat`), checked out
side by side:

```bash
# meko: endpoint (slow; its base image is on quay.io) and controller
cd meko/amp
docker build -t yb-amp/neon-endpoint:tsql-poc -f deploy/endpoint/Dockerfile .
make controller-bundle-only
DOCKER_BUILDKIT=1 docker build -t yb-amp/controller:tsql-poc -f deploy/controller/Dockerfile .

# tsql_compat, compiled against that endpoint
cd ../../tsql_compat
docker build -t amp-ext-tsql_compat:1.0-poc \
  --build-arg ENDPOINT_IMAGE=yb-amp/neon-endpoint:tsql-poc -f Dockerfile.amp .

# Ora2Pg, then the AMP migration job image on top of it
cd ../ora2pg
docker build --platform linux/amd64 -t ora2pg-tsql -f demo/tsql_compat/Dockerfile .
cd ../meko/amp
docker build -t amp-ora2pg:local -f deploy/ora2pg/Dockerfile .
```

## Run

From this directory.

1. Remove the previous run: every container on `amp-tsql` (YugabyteDB, the
   controller, endpoints) and SQL Server.

   ```bash
   ./amp-up.sh down
   docker rm -f demo-mssql 2>/dev/null || true
   ```

2. Start SQL Server and wait until it is ready (about 15 s).

   ```bash
   docker run -d --name demo-mssql --platform linux/amd64 \
     -e ACCEPT_EULA=Y -e MSSQL_PID=Express -e 'MSSQL_SA_PASSWORD=Tsql_Demo#2026' \
     -p 127.0.0.1:14330:1433 mcr.microsoft.com/mssql/server:2022-latest
   until docker logs demo-mssql 2>&1 | grep -q "Recovery is complete"; do sleep 2; done
   ```

3. Load the sample application: 3 tables (9 rows), a view, a function, two
   procedures and a trigger.

   ```bash
   docker exec -i demo-mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost \
     -U sa -P 'Tsql_Demo#2026' < ../sql/shop.sql
   ```

4. Start AMP: YugabyteDB (`amp-yb`) and the controller (`amp-controller`,
   API on `http://127.0.0.1:18080`).

   ```bash
   ./amp-up.sh
   ```

5. Register the extension image and create the storage pool (plus a spare
   cluster `tsql` with an endpoint). Writes `amp.env`.

   ```bash
   ./amp-provision.sh
   ```

6. Migrate: connectivity check, create migration, assessment, provision target
   (a new cluster with `tsql_compat`), migrate, then every object run once and
   the T-SQL queries.

   ```bash
   ./migrate.sh
   ```

   Tables, view and function are `OK`. The two procedures and the trigger load
   but fail when run (Ora2Pg's T-SQL conversion, see `RESULTS.md`).

## Check the data

Connect to the migration's target (the credential is the controller's fixed
placeholder for migration targets):

```bash
MID=$(cat ../output-amp/migration_id)
T=$(curl -s http://127.0.0.1:18080/api/v1/migrations/$MID | jq .target)
export PGHOST=$(jq -r .host <<<"$T") PGPORT=$(jq -r .port <<<"$T") \
       PGUSER=$(jq -r .username <<<"$T") PGDATABASE=shop PGPASSWORD=cloud_admin
```

```bash
# tsql_compat installed, in schema sys
psql -c "SELECT extname, extnamespace::regnamespace FROM pg_extension WHERE extname = 'tsql_compat'"

# 3 rows per table, as in SQL Server
psql -c "SELECT 'customers' t, count(*) FROM customers UNION ALL SELECT 'orders', count(*) FROM orders UNION ALL SELECT 'order_items', count(*) FROM order_items"

# the data and the view
psql -c "SELECT customer_id, full_name, country, credit_limit FROM customers ORDER BY customer_id"
psql -c "SELECT * FROM v_customer_summary ORDER BY customer_id"

# T-SQL functions
psql -c "SELECT GETDATE(), DATEADD('day', 30, GETDATE()), ISNULL(NULL, 'ok'), LEN('hello')"

# SQL Server's case-insensitive collation: 'es' matches ES
psql -c "SELECT customer_id, full_name, country FROM customers WHERE country = 'es'"

# the same rows in SQL Server
docker exec demo-mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P 'Tsql_Demo#2026' \
  -d shop -W -Q "SELECT customer_id, full_name, country, credit_limit FROM dbo.customers ORDER BY customer_id"
```
