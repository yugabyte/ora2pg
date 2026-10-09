# SQL Server to PostgreSQL + tsql_compat with Ora2Pg

Files in this directory:

- `Dockerfile`: Ora2Pg from this source tree, with the Microsoft ODBC driver 18,
  DBD::ODBC, DBD::Pg and psql
- `ora2pg.conf`: Ora2Pg configuration (source `demo-mssql`, target `demo-pg`,
  `USE_TSQL_COMPAT 1`)
- `sql/shop.sql`: sample SQL Server application (tables, view, function,
  procedures, trigger, data)
- `amp/`: the same migration into an AMP endpoint on Docker, through the AMP
  controller's migration API (`amp/README.md`)

Run all commands from this directory:

```bash
cd ~/code/ora2pg/demo/tsql_compat
```

## Build the Ora2Pg image (once)

```bash
docker build --platform linux/arm64 -t ora2pg-tsql -f Dockerfile ../..
```

Use `--platform linux/amd64` on an Intel machine. Rebuild after changing the
Ora2Pg code. The PostgreSQL image `localhost/tsql_compat:pg17` is built from
the tsql_compat repository.

## Start the containers

```bash
docker network create tsql-demo

docker run -d --name demo-mssql --network tsql-demo --platform linux/amd64 \
  -e ACCEPT_EULA=Y -e MSSQL_PID=Express -e 'MSSQL_SA_PASSWORD=Tsql_Demo#2026' \
  -p 14330:1433 mcr.microsoft.com/mssql/server:2022-latest

docker run -d --name demo-pg --network tsql-demo \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=shop \
  -e TSQL_COMPAT_SEARCH_PATH='dbo, public, sys, pg_catalog' \
  -p 15432:5432 localhost/tsql_compat:pg17

docker logs demo-mssql 2>&1 | grep "Recovery is complete"    # SQL Server ready (~15 s)
```

## Load the sample application into SQL Server

```bash
docker exec -i demo-mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost \
  -U sa -P 'Tsql_Demo#2026' < sql/shop.sql
```

## Look at SQL Server

```bash
docker exec -it demo-mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost \
  -U sa -P 'Tsql_Demo#2026' -d shop -W -s '|'
```

```sql
SELECT name, type_desc FROM sys.objects
WHERE is_ms_shipped = 0 AND type IN ('U','V','FN','P','TR')
ORDER BY type_desc, name;
GO

SELECT name AS column_name, TYPE_NAME(user_type_id) AS data_type,
       max_length, precision, scale
FROM sys.columns
WHERE object_id = OBJECT_ID('dbo.customers')
ORDER BY column_id;
GO

SELECT customer_id, full_name, is_active, rating, credit_limit,
       created_at, signup_tz, badge
FROM dbo.customers ORDER BY customer_id;
GO

SELECT * FROM dbo.v_customer_summary ORDER BY customer_id;
GO

SELECT order_id, order_date, dbo.fn_order_age(order_date) AS age_days,
       DATEADD(day, 30, order_date) AS due_date
FROM dbo.orders ORDER BY order_id;
GO

exit
```

## Migration assessment

With tsql_compat:

```bash
docker run --rm --network tsql-demo -v "$PWD:/work" ora2pg-tsql \
  ora2pg -c /work/ora2pg.conf -t SHOW_REPORT --estimate_cost
```

Without tsql_compat, for comparison:

```bash
sed 's/^USE_TSQL_COMPAT.*/USE_TSQL_COMPAT	0/' ora2pg.conf > ora2pg-no-compat.conf

docker run --rm --network tsql-demo -v "$PWD:/work" ora2pg-tsql \
  ora2pg -c /work/ora2pg-no-compat.conf -t SHOW_REPORT --estimate_cost
```

## Export the schema

Ora2Pg writes to `output/` (`OUTPUT_DIR /work/output` in `ora2pg.conf`):

```bash
mkdir -p output

docker run --rm --network tsql-demo -v "$PWD:/work" ora2pg-tsql \
  ora2pg -c /work/ora2pg.conf -t TABLE -o table.sql

docker run --rm --network tsql-demo -v "$PWD:/work" ora2pg-tsql \
  ora2pg -c /work/ora2pg.conf -t VIEW -o view.sql

docker run --rm --network tsql-demo -v "$PWD:/work" ora2pg-tsql \
  ora2pg -c /work/ora2pg.conf -t FUNCTION -o function.sql

docker run --rm --network tsql-demo -v "$PWD:/work" ora2pg-tsql \
  ora2pg -c /work/ora2pg.conf -t PROCEDURE -o procedure.sql

docker run --rm --network tsql-demo -v "$PWD:/work" ora2pg-tsql \
  ora2pg -c /work/ora2pg.conf -t TRIGGER -o trigger.sql

cat output/table.sql output/view.sql output/function.sql
```

## Load the schema into PostgreSQL

```bash
docker exec -i demo-pg psql -U postgres -d shop < output/table.sql
docker exec -i demo-pg psql -U postgres -d shop < output/view.sql
docker exec -i demo-pg psql -U postgres -d shop < output/function.sql
docker exec -i demo-pg psql -U postgres -d shop < output/procedure.sql
docker exec -i demo-pg psql -U postgres -d shop < output/trigger.sql
```

## Migrate the data

Ora2Pg reads SQL Server and writes straight into PostgreSQL (`PG_DSN` in
`ora2pg.conf`):

```bash
docker run --rm --network tsql-demo -v "$PWD:/work" ora2pg-tsql \
  ora2pg -c /work/ora2pg.conf -t COPY
```

## Look at PostgreSQL

```bash
docker exec -it demo-pg psql -U postgres -d shop
```

```sql
\dx tsql_compat
SHOW search_path;
\d dbo.customers

SELECT a.attname AS column_name,
       format_type(a.atttypid, a.atttypmod) AS data_type,
       n.nspname AS type_schema
FROM pg_attribute a
JOIN pg_type t ON t.oid = a.atttypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE a.attrelid = 'customers'::regclass AND a.attnum > 0
ORDER BY a.attnum;

SELECT customer_id, full_name, is_active, rating, credit_limit,
       created_at, signup_tz, badge
FROM customers ORDER BY customer_id;

SELECT * FROM v_customer_summary ORDER BY customer_id;

SELECT order_id, order_date, fn_order_age(order_date) AS age_days,
       DATEADD('day', 30, order_date) AS due_date
FROM orders ORDER BY order_id;

\sf fn_order_age

SELECT GETDATE() AS now_, NEWID() AS new_id, LEN('abc   ') AS len_,
       ISNULL(NULL::int, 42) AS isnull_,
       DATEDIFF('month', '2024-01-31'::datetime, '2024-03-01'::datetime) AS months;

\q
```

## Clean up

```bash
docker rm -f demo-mssql demo-pg
docker network rm tsql-demo
rm -rf output ora2pg-no-compat.conf
```

Remove the Ora2Pg image too with `docker rmi ora2pg-tsql`.

## Notes

- In PostgreSQL the datepart of `DATEADD`, `DATEDIFF`, `DATEPART` and
  `DATENAME` is quoted (`'day'`). Ora2Pg adds the quotes when it migrates code.
- String literals passed to `DATEDIFF` need a cast (`'2024-01-31'::datetime`).
- `DATETIMEOFFSET` is rounded to microseconds (6 digits instead of 7).
- `NVARCHAR(100)` is exported as `nvarchar(200)`: Ora2Pg takes the size SQL
  Server reports in bytes.
- The procedures and the trigger are migrated but do not run: Ora2Pg does not
  translate every T-SQL construct in procedure bodies.
- SQL Server is amd64 only. On Apple Silicon it runs under Rosetta and needs
  about 2 GB of memory.
