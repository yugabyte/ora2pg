# Assessing and migrating: PostgreSQL vs SQL Server in the AMP controller

How the AMP controller's migration APIs handle a `postgresql` source (yb-voyager)
and a `sqlserver` source (Ora2Pg + tsql_compat): where the two paths share code,
where they diverge, and why PostgreSQL migrations are not affected by the SQL
Server work.

- Repo: `meko`, branch `ameya/tsql-compat-amp`. All paths below are relative
  to `meko/amp/` unless they start with `amp/` (this directory, in
  `yugabyte/ora2pg` `demo/tsql_compat/`).
- Line numbers are from 2026-10-06 and will drift.
- Observations marked **[observed]** come from migrations run on the local
  Docker stack, not from reading code.

---

## 1. Summary

One API, one job contract, two job images.

| | PostgreSQL source | SQL Server source |
|---|---|---|
| `db_type` | `postgresql` | `sqlserver` |
| Migration tool | yb-voyager | Ora2Pg (`USE_TSQL_COMPAT 1`) |
| Job image | `--voyager-image` / `AMP_VOYAGER_IMAGE` | `--ora2pg-image` / `AMP_ORA2PG_IMAGE` |
| Job entrypoints | `/opt/amp/voyager/{assess,migrate,end}.sh` | same paths, different scripts |
| Schemas per migration | one or more | exactly one |
| Connectivity check | real login (pgx): version, SSL, latency | TCP dial only: latency |
| Assessment | no schema analysis; complexity always `LOW`; vCPU sizing from the source host | Ora2Pg `SHOW_REPORT`; complexity from Ora2Pg's migration level; one issue per object type with code; no sizing |
| Target cluster | no extensions | `tsql_compat` mounted |
| Target database setup | `CREATE DATABASE`; yb-voyager creates the schema | `CREATE DATABASE`, `CREATE EXTENSION tsql_compat`, schema, `search_path` |
| Schema conversion | stock PostgreSQL to PostgreSQL | T-SQL types and functions kept (`sys.datetime`, `NEWID()`); provided by tsql_compat |
| Progress reporting | yb-voyager writes phase and per-table rows | none: no phase or table rows |
| Row-count verification | yb-voyager's own import | `TEST_COUNT`; any difference fails the run |
| `parallel_jobs` | passed to `import data --parallel-jobs` | ignored |
| `end` | `yb-voyager end migration` | removes Ora2Pg work files |

What is shared: the REST handlers, the task framework, the job runners (Docker
and Kubernetes), the env contract injected into the job, the export volume, the
control-plane tables the job writes assessment rows into, and the status
derivation. SQL Server was added by branching on `db_type` at five small points
in the controller and by adding a second job image. Nothing in the PostgreSQL
scripts or in the Voyager image was edited.

---

## 2. The pipeline both sources share

```
client
  |  POST /migrations/{id}/assess | /migrate | /end
  v
handler            api/voyager_handlers.go            validate, plan a task, return 202
  v
task               task/voyager_tasks.go              start_migration_run -> launch_voyager_job step
  v
runner             deploy/voyager_docker.go / _kubernetes.go
  |                  buildVoyagerJobSpec  (deploy/voyager.go)   env map + command + IMAGE
  v
job container      /opt/amp/voyager/{assess,migrate,end}.sh     <- the only place the sources differ
  |  writes
  v
control plane      ybvoyager_visualizer.ybvoyager_visualizer_metadata   (phase-1 assessment rows, phase rows)
  ^  reads
  |
GET /migrations/{id}[/assessment]   migration/visualizer.go, status.go, assessment.go
```

### 2.1 Handlers

All in `controller/internal/api/voyager_handlers.go`:

| API | Handler | Line |
|---|---|---|
| `POST /migrations/connectivity-checks` | `CheckMigrationConnectivity` | 43 |
| `POST /migrations` | `CreateMigration` | 60 |
| `GET /migrations` | `ListMigrations` | 87 |
| `GET /migrations/{id}` | `GetMigration` | 103 |
| `GET /migrations/{id}/assessment` | `GetMigrationAssessment` | 123 |
| `POST /migrations/{id}/assess` | `StartMigrationAssessment` | 139 |
| `POST /migrations/{id}/migrate` | `StartMigration` | 181 |
| `POST /migrations/{id}/end` | `EndMigration` | 234 |
| `POST /migrations/{id}/provision-target` | `ProvisionMigrationTarget` | 286 |
| input validation | `sourceFromRequest` | 394 |

`assess`, `migrate` and `end` contain no source-specific code. They check
state (not ended, no active run, target attached for migrate), allocate an
attempt number and call `c.tasks.VoyagerStartMigrationRun(...)`. Routes are
registered in the generated `api/api.gen.go` (around line 11561).

### 2.2 Task and launch

`task/voyager_tasks.go:28` defines `KindVoyagerStartMigrationRun`; its plan has
one `launch_voyager_job` step (`task/voyager_step_launch_job.go`). The step
builds a `VoyagerRunSpec` from the migration row (source, target, operation,
attempt) and calls `runner.StartRun` (line 103). The runner is chosen by
`--deploy-driver`.

### 2.3 The env contract

`deploy/voyager.go`, `buildVoyagerJobSpec` (line 143). The same map is built for
every source; only `SOURCE_DB_TYPE` and the image differ:

```go
env := map[string]string{
    "CONTROL_PLANE_TYPE":          "yugabyted",
    "YUGABYTED_DB_CONN_STRING":    storeDbConnectionString,
    "YB_VOYAGER_MIGRATION_UUID":   spec.MigrationID.String(),
    "EXPORT_DIR":                  voyagerExportDir,        // /voyager/export
    "YB_VOYAGER_SEND_DIAGNOSTICS": "0",
    "SOURCE_DB_TYPE":              spec.Source.DBType,      // postgresql | sqlserver
    "SOURCE_HOST":                 spec.Source.Host,
    "SOURCE_PORT":                 strconv.Itoa(spec.Source.Port),
    "SOURCE_USER":                 spec.Source.Username,
    "SOURCE_DB":                   spec.Source.Database,
    "SOURCE_SCHEMAS":              strings.Join(spec.Source.Schemas, ","),
    "SOURCE_DB_PASSWORD":          spec.Source.Password,
    "TARGET_HOST":                 target.Host,
    "TARGET_PORT":                 portString(target.Port),
    "TARGET_USER":                 target.Username,
    "TARGET_DB":                   target.Database,
    "TARGET_DB_PASSWORD":          target.Password,
    "PARALLEL_JOBS":               strconv.Itoa(spec.ParallelJobs),
}
```

The command is also identical for both sources (`deploy/voyager.go:273,285,293`):

```go
func assessCommand() string  { return "set -euo pipefail\n/opt/amp/voyager/assess.sh" }
func migrateCommand() string { return "set -euo pipefail\n/opt/amp/voyager/migrate.sh" }
func endCommand() string     { return "set -euo pipefail\n/opt/amp/voyager/end.sh" }
```

That is the design: the controller never knows which tool runs. The image
decides, by what is at `/opt/amp/voyager/`.

**[observed]** The two migrate jobs, from `docker inspect`:

| | PostgreSQL job (`shopdb-pg`) | SQL Server job (`shopdb-mssql`) |
|---|---|---|
| image | `.../amp/voyager:ubuntu-0d6d579ff` | `amp-ora2pg:local` |
| entrypoint / cmd | `/bin/bash -c "set -euo pipefail\n/opt/amp/voyager/migrate.sh"` | identical |
| `SOURCE_DB_TYPE` | `postgresql` | `sqlserver` |
| `SOURCE_SCHEMAS` | `public` | `dbo` |
| `TARGET_HOST`:`TARGET_PORT` | `yb-ep-<id>`:`55433` | `yb-ep-<id>`:`55433` |
| `CONTROL_PLANE_TYPE`, `EXPORT_DIR`, `PARALLEL_JOBS` | `yugabyted`, `/voyager/export`, `8` | same |

---

## 3. Where the controller diverges

Five places, each guarded by `db_type == "sqlserver"` or an optional setting.

### 3.1 API enum and input validation

`api/openapi_spec.yaml:3144` (request) and `:3182` (response):

```yaml
db_type:
  type: string
  enum: [postgresql, sqlserver]
```

`api/voyager_handlers.go:394`, `sourceFromRequest`:

```go
if req.DbType != MigrationSourceRequestDbTypePostgresql && req.DbType != MigrationSourceRequestDbTypeSqlserver {
    return migration.SourceConfig{}, "source db_type must be postgresql or sqlserver"
}
...
if req.DbType == MigrationSourceRequestDbTypeSqlserver && len(schemas) != 1 {
    return migration.SourceConfig{}, "a sqlserver source takes exactly one schema (e.g. [\"dbo\"])"
}
```

The one-schema rule exists because Ora2Pg exports one schema per run. It is
repeated in the runner (`deploy/voyager.go:222,234`) and again in the job
(`deploy/ora2pg/scripts/ora2pg-env.sh:19`), so a request that bypasses the API
still fails fast.

### 3.2 Job image selection

`deploy/voyager.go:125-141`:

```go
type VoyagerImages struct {
    Voyager   string // postgresql sources
    SQLServer string // sqlserver sources (Ora2Pg)
}

func (i VoyagerImages) forSource(dbType string) (string, error) {
    if dbType == VoyagerSourceSQLServer {
        if i.SQLServer == "" {
            return "", errors.New("the SQL Server (Ora2Pg) job image is not configured")
        }
        return i.SQLServer, nil
    }
    if i.Voyager == "" {
        return "", errors.New("Voyager image is required")
    }
    return i.Voyager, nil
}
```

Wired from `config/config.go:456` (`--ora2pg-image`, `AMP_ORA2PG_IMAGE`) into both
runners (`cmd/controller/main.go:252,262`). With the setting unset, a PostgreSQL
run takes the `Voyager` branch exactly as before and a SQL Server run is
refused. The runners use `job.Image` (`deploy/voyager_docker.go:71`,
`deploy/voyager_kubernetes.go:227`) instead of `cfg.Image`.

### 3.3 Connectivity check

`voyager/migration/connectivity.go:31`, `CheckConnectivity`:

```go
if source.DBType == deploy.VoyagerSourceSQLServer {
    return checkTCPConnectivity(ctx, source)
}
// PostgreSQL continues unchanged: pgx.ConnectConfig, then
//   SELECT current_setting('server_version'), ssl FROM pg_stat_ssl ...
```

| | PostgreSQL | SQL Server |
|---|---|---|
| Method | log in with pgx (line 59) | `net.Dialer.DialContext` (line 89) |
| Returns | `reachable`, `server_version`, `ssl`, `latency_ms` | `reachable`, `latency_ms` |
| Bad password | `reachable=false` | still `reachable=true`; the assess job fails later |

The controller has no SQL Server client library, so it cannot log in.

### 3.4 Target provisioning

`api/voyager_handlers.go:286`, `ProvisionMigrationTarget`, lines 335-350:

```go
var extensions []string
if item.Source.DBType == deploy.VoyagerSourceSQLServer {
    ok := false
    if c.prov.Extensions != nil {
        if ok, err = c.prov.Extensions.Has(ctx, tsqlCompatExtension); err != nil { ... }
    }
    if !ok {
        return ProvisionMigrationTarget400JSONResponse{...
            "a sqlserver migration needs the tsql_compat extension, which is not in the extension catalog"...}, nil
    }
    extensions = []string{tsqlCompatExtension}
}
```

`extensions` flows into `VoyagerCreateMigrationTargetInput.Extensions`
(`task/voyager_tasks.go:99`, `json:"extensions,omitempty"`) and from there into
`CreateClusterArgs.Extensions` (line 156). For PostgreSQL the slice is nil and
`omitempty` drops it, so the persisted task JSON is byte-identical to before.
**[observed]** The SQL Server target cluster reports `extensions: ["tsql_compat"]`.

Everything else about provisioning (PG 18, endpoint, placeholder credential,
attach step) is shared: `task/voyager_tasks.go:79,109,131`.

### 3.5 Docker: reaching the target

On Docker, the address recorded for the target is the host-published port
(`127.0.0.1:<port>` by default), which inside the job container is the job
itself. `deploy/voyager_docker.go:91`:

```go
func dockerTargetByContainer(job *voyagerJobSpec, target *VoyagerTargetConfig) {
    if target == nil || target.EndpointID == uuid.Nil { return }
    for i := range job.Env {
        switch job.Env[i].Name {
        case "TARGET_HOST": job.Env[i].Value = EndpointName(target.EndpointID)   // yb-ep-<uuid>
        case "TARGET_PORT": job.Env[i].Value = strconv.Itoa(endpointComputePort) // 55433
        }
    }
}
```

Applied at `voyager_docker.go:48`, when a shared network is configured. This is
**not** SQL Server specific: it applies to every source type on Docker. See
section 8.

---

## 4. Assessment

### 4.1 What the two jobs have in common

Both `assess.sh` scripts:
1. validate the env contract;
2. bootstrap the `ybvoyager_visualizer` schema in the control database
   (`amp-controlplane-bootstrap.psql`, shared: the Ora2Pg image copies it from
   `deploy/voyager/scripts/`, `deploy/ora2pg/Dockerfile:22`);
3. insert a phase-1 `IN PROGRESS` row with the next `invocation_sequence`;
4. do the analysis;
5. insert a phase-1 `COMPLETED` row carrying a JSON payload in Voyager's
   `AssessMigrationPayloadYugabyteD` shape (`PayloadVersion` `1.8-amp.1`);
6. write the same JSON to `$EXPORT_DIR/assessment/reports/migration_assessment_report.json`;
7. on any non-zero exit after step 3, insert a `FAILED` row so the run cannot
   sit at `IN PROGRESS` forever.

`GET /migrations/{id}/assessment` reads that row and does not know which tool
produced it: `api/voyager_handlers.go:123` ->
`migration/visualizer.go:223` (`GetAssessment`) ->
`migration/visualizer.go:186` (`LatestCompletedAssessmentPayload`) ->
`migration/assessment.go:21` (`ParseAssessmentPayload`, requires payload
version 1.8+).

### 4.2 PostgreSQL

Entry: `deploy/voyager/scripts/assess.sh` maps the env to libpq variables and
`exec`s the driver:

```bash
export PGHOST="$SOURCE_HOST"; export PGPORT="$SOURCE_PORT"; export PGUSER="$SOURCE_USER"
export PGDATABASE="$SOURCE_DB"; export PGPASSWORD="${SOURCE_DB_PASSWORD:-}"
SCHEMA_LIST="${SOURCE_SCHEMAS//,/$'|'}"
exec "$SCRIPT_DIR/amp-assess-migration.sh" --psql-env "$SCHEMA_LIST" "$EXPORT_DIR"
```

Driver: `deploy/voyager/scripts/amp-assess-migration.sh`. It does **not** call
`yb-voyager assess-migration` and does **not** analyse the schema (its header,
lines 2-8: "voyager's YugabyteDB compatibility analysis ... does not apply").
What it measures is the source host's capacity:

| Step | Line | What |
|---|---|---|
| source facts | 111 | one query (`amp-source-facts.psql`): superuser, `pg_read_server_files`, `max_worker_processes`, db size, version |
| bootstrap control plane | 128 | create the visualizer tables |
| `IN PROGRESS` row | 201 | |
| vCPU detection | 205-300 | tier `exact`: read `/proc` via `pg_read_file` (`Cpus_allowed_list`, cgroup `cpu.max`); tier `high`: invert `max_worker_processes`; else `-1` |
| payload | 322-355 | `json_build_object(...)` |
| `COMPLETED` row | ~357 | |

The payload is deliberately lean (lines 335-338):

```sql
SELECT json_build_object(
    'PayloadVersion', :'pver',
    'VoyagerVersion', :'vver',                       -- "amp-assess-1.0"
    'MigrationComplexity', 'LOW',                    -- constant
    'MigrationComplexityExplanation',
        'YugabyteDB AMP is a PostgreSQL-compatible compute, so a PostgreSQL source needs no schema conversion. This assessment reports sizing only; it does not analyse the schema for incompatibilities.',
    'SourceSizeDetails', json_build_object('TotalDBSize', :'dbsize'::bigint),
    'Sizing', json_build_object('SizingRecommendation', json_build_object(
        'NumNodes', 1, 'VCPUsPerInstance', :'vcpus'::int, 'MemoryPerInstance', :'memgb'::int), ...
```

Memory is `vCPU x 4 GB`. There are no `AssessmentIssues`.

### 4.3 SQL Server

Entry: `deploy/ora2pg/scripts/assess.sh` (sources `ora2pg-env.sh`). The analysis
is Ora2Pg's own migration report (line 72):

```bash
o2p -t SHOW_REPORT --estimate_cost --dump_as_json > "$WORK_DIR/report.json"
```

`ora2pg-env.sh:34` renders the config it runs with:

```
ORACLE_DSN   dbi:ODBC:driver=msodbcsql18;server=<host>,<port>;database=<db>;TrustServerCertificate=yes
SCHEMA       <schema>
USE_TSQL_COMPAT 1
CASE_INSENSITIVE_SEARCH sys.SQL_Latin1_General_CP1_CI_AS
PG_VERSION   18
```

The source login is passed as `ORA2PG_USER` / `ORA2PG_PASSWD` in the environment,
so no credential is written to the config on the persistent volume.

A `jq` program (lines 75-105) converts Ora2Pg's JSON into the Voyager payload:

| Ora2Pg report field | Payload field | Rule |
|---|---|---|
| `migration level` (`A-*`, `B-*`, `C-*`) | `MigrationComplexity` | `A`=`LOW`, `B`=`MEDIUM`, `C`=`HIGH`, else `MEDIUM` |
| level, `total cost`, `human days cost` | `MigrationComplexityExplanation` | text |
| each `objects[]` with `number > 0`, `cost value > 0`, not `TABLE` | `AssessmentIssues[]` | `Category: migration_caveats`, `Type`/`ObjectType` = object type, `ObjectName` = names scanned from `details`, `Impact`: `LEVEL_3` if `invalid > 0` else `LEVEL_2` |
| `Size` ("4.00 MB") | `SourceSizeDetails.TotalDBSize` | converted to bytes |
| `TABLE` details "Total number of rows: N" | `SourceSizeDetails.TotalTableRowCount` | |
| `ora2pg version` | `VoyagerVersion` | `ora2pg-25` |

**[observed]** For the sample `shop` database:

```
complexity: MEDIUM - Ora2Pg migration level B-4 ... Estimated effort 22 cost units (1 person-day(s))
review: FUNCTION fn_order_age
review: PROCEDURE usp_customer_stats, usp_place_order
review: TRIGGER trg_customers_touch
review: VIEW v_customer_summary
source rows: 9
```

There is no `Sizing` block, so a client gets no vCPU recommendation for a SQL
Server source. The tool detects nothing about the source host.

### 4.4 Side-by-side

| | PostgreSQL | SQL Server |
|---|---|---|
| Looks at the schema | no | yes (Ora2Pg report) |
| Complexity | constant `LOW` | from the migration level |
| Issues | none | per object type with code |
| Sizing | vCPU from source host, 4 GB/vCPU, 1 node | none |
| Source access | psql (libpq) | ODBC via Ora2Pg |
| Needs source privileges | optional `pg_read_server_files` for exact vCPU | read access to the schema |
| `VoyagerVersion` | `amp-assess-1.0` | `ora2pg-25` |
| Rows written | phase 1: seq 1 `IN PROGRESS`, seq 2 `COMPLETED` | same |
| Failure row | `FAILED` | `FAILED` |

### 4.5 A PostgreSQL-only effect: the assessment is replaced during `migrate`

**[observed]** For the PostgreSQL migration `shopdb-pg`, phase 1 holds four rows:

```
phase | seq | status       | time     | payload bytes | payload begins
1     | 1   | IN PROGRESS  | 13:53:28 | 0             |
1     | 2   | COMPLETED    | 13:53:28 | 947           | {"PayloadVersion" : "1.8-amp.1", "VoyagerVersion" : "amp-assess-1.0", ...
1     | 3   | IN PROGRESS  | 13:54:00 | 0             |
1     | 4   | COMPLETED    | 13:54:01 | 12760         | {"PayloadVersion":"1.8","VoyagerVersion":"main","TargetDBVersion":"2026.1.1.1",...
```

Rows 3 and 4 were written by the `migrate` job: the migrate log shows
`Assessing migration before exporting schema... Migration assessment completed
successfully.`, i.e. `yb-voyager export schema` (`deploy/voyager/scripts/migrate.sh:53`)
runs its own assessment when it starts. `LatestCompletedAssessmentPayload` takes
the newest `COMPLETED` row, so after a PostgreSQL migrate, `GET /assessment` returns
Voyager's native, YugabyteDB-oriented analysis (3 nodes, sharded tables) instead
of AMP's lean one. **[observed]** `GET .../assessment` for `shopdb-pg` returned
`num_nodes: 3` and `sharded_tables: [customers, orders, products]`.

The SQL Server migration keeps only rows 1-2 (**[observed]**): Ora2Pg writes no
visualizer rows, so its assessment is unchanged by `migrate`.

This is existing PostgreSQL behaviour, not caused by the SQL Server work, and it is
worth knowing: the same endpoint can return two different shapes depending on
whether a migration has run.

---

## 5. Migration

### 5.1 PostgreSQL: yb-voyager

`deploy/voyager/scripts/migrate.sh` runs the stock sequence, every phase with
`--start-clean true`, so a retry is a full redo:

| # | Line | Command | Effect |
|---|---|---|---|
| 1 | 53 | `yb-voyager export schema --source-db-type "$SOURCE_DB_TYPE" ... --skip-colocation-recommendations true` | dump DDL (also runs its own assessment, 4.5) |
| 2 | 62 | `psql ... -f amp-create-target-db.psql` | `CREATE DATABASE` if missing |
| 3 | 68 | `yb-voyager import schema --target-db-type yugabytedb-amp` | drops and recreates the target schema |
| 4 | 75 | `yb-voyager export data` | dump rows |
| 5 | 83 | `yb-voyager import data --parallel-jobs "$PARALLEL_JOBS" --truncate-tables true` | load rows |
| 6 | 91 | `yb-voyager finalize-schema-post-data-import` | indexes, triggers |

Because the job has `CONTROL_PLANE_TYPE=yugabyted` and
`YUGABYTED_DB_CONN_STRING`, yb-voyager itself writes the progress rows for each
phase and per-table row counts into `ybvoyager_visualizer`.

### 5.2 SQL Server: Ora2Pg

`deploy/ora2pg/scripts/migrate.sh`. Again every attempt is a full redo.

```bash
rm -rf "$WORK_DIR"                                   # line 21: start clean
render_conf with_target                              # line 22: ora2pg.conf incl. PG_DSN
pg -d postgres -v target_db="$TARGET_DB" -f "$SCRIPT_DIR/amp-create-target-db.psql"   # 25

pg -d "$TARGET_DB" -v schema="$TARGET_SCHEMA" -v db="$TARGET_DB" <<'SQL'              # 30-37
SET client_min_messages = warning;
SET search_path = pg_catalog;
CREATE EXTENSION IF NOT EXISTS tsql_compat;
SELECT format('DROP SCHEMA IF EXISTS %I CASCADE', :'schema') \gexec
SELECT format('CREATE SCHEMA %I', :'schema') \gexec
SELECT format('ALTER DATABASE %I SET search_path = %I, public, sys, pg_catalog', :'db', :'schema') \gexec
SQL

for t in TABLE VIEW FUNCTION PROCEDURE TRIGGER; do o2p -t "$t" -o "${t,,}.sql"; done   # 40-42: export
for f in table view function procedure trigger; do                                      # 45-47: load
  PGOPTIONS='-c client_min_messages=warning' pg -d "$TARGET_DB" -f "$WORK_DIR/$f.sql"
done
o2p -t COPY > "$WORK_DIR/copy.log" 2>&1 || { ...; exit 1; }                             # 50: data
pg -d "$TARGET_DB" -f "$WORK_DIR/AUTOINCREMENT_table.sql"                               # 58: sequences
o2p -t TEST_COUNT > "$WORK_DIR/TEST_COUNT.txt" 2>&1                                     # 61: verify
grep -q '^DIFF' "$WORK_DIR/TEST_COUNT.txt" && exit 1                                    # 63-66
```

| Step | Why it exists |
|---|---|
| `CREATE EXTENSION tsql_compat` | the converted schema uses `sys.datetime`, `sys.money`, `NEWID()` and so on |
| `SET search_path = pg_catalog` for the setup block | once a previous attempt has set the database `search_path`, tsql_compat's `sys` schema precedes `pg_catalog` and makes `format()` ambiguous |
| `DROP SCHEMA ... CASCADE`; `CREATE SCHEMA` | the redo; the schema name is the source schema lower-cased (`dbo`) |
| `ALTER DATABASE ... SET search_path = dbo, public, sys, pg_catalog` | unqualified `GETDATE()`, `LEN()` and friends resolve to tsql_compat |
| `CASE_INSENSITIVE_SEARCH sys.SQL_Latin1_General_CP1_CI_AS` (in the config) | Ora2Pg's default is `citext`, which the endpoint image does not ship; the tsql_compat collation keeps SQL Server's case-insensitive comparison |
| `AUTOINCREMENT_table.sql` | moves identity counters past the copied rows, so the next insert does not collide |
| `TEST_COUNT` | no other check that every row arrived |
| no `JOBS` setting | Ora2Pg forks its workers after connecting and the SQL Server ODBC handle does not survive the fork (`Communication link failure`) |

Credentials, `ora2pg-env.sh:26-28,54`:

```bash
export ORA2PG_USER="$SOURCE_USER"
export ORA2PG_PASSWD="${SOURCE_DB_PASSWORD:-}"      # source login, env only
export PGPASSWORD="${TARGET_DB_PASSWORD:-}"         # psql
(umask 077 && printf '%s' "$PGPASSWORD" > "$HOME/.ora2pg_pg_pwd")   # Ora2Pg PG_PWD file; unset => it prompts on stdin
```

### 5.3 Comparison

| | PostgreSQL | SQL Server |
|---|---|---|
| Phases | export schema, create db, import schema, export data, import data, finalize | create db + extension + schema, export 5 object types, load schema, COPY, reset sequences, count check |
| Schema load | yb-voyager (`yugabytedb-amp` target) | `psql -f table/view/function/procedure/trigger.sql` |
| Indexes, FKs, triggers | `finalize-schema-post-data-import` after the data | inside `table.sql` / `trigger.sql`; `DROP_FKEY 1` removes FKs during the load |
| Idempotent retry | `--start-clean`, `--truncate-tables` | wipe work dir, drop schema, `TRUNCATE_TABLE 1` |
| Parallelism | `--parallel-jobs $PARALLEL_JOBS` | none |
| Correctness check | yb-voyager's counts in the visualizer | `TEST_COUNT` fails the job on a mismatch |
| Procedures/triggers | PL/pgSQL, no conversion needed | converted by Ora2Pg; partial (section 9) |
| Job exit | non-zero on any yb-voyager failure (`set -e`) | non-zero on any step failure |

### 5.4 `end`

| | PostgreSQL | SQL Server |
|---|---|---|
| Script | `deploy/voyager/scripts/end.sh:16` | `deploy/ora2pg/scripts/end.sh` |
| Action | `yb-voyager end migration --backup-* false --yes` | `rm -rf $EXPORT_DIR/ora2pg $EXPORT_DIR/assessment` |
| Requires `TARGET_DB_PASSWORD` | yes (refuses to prompt) | no |
| State left behind | visualizer rows (same) | visualizer rows (same) |

The handler (`voyager_handlers.go:234`) and eligibility rules are identical.

---

## 6. Status and progress

`voyager/migration/status.go`:
- `DeriveStatus` (line 16) is shared. It derives `created`, `assessing`,
  `assessed`, `provisioning_target`, `target_ready`, `migrating`, `completed`,
  `ending`, `ended`, `failed` from the run rows, the job's runtime state and the
  target.
- `migrateDetail` (line 124) chooses the text shown while a migrate run is in
  flight, from the phase rows yb-voyager writes:

```go
if phases[PhaseExportSchema] != PhaseCompleted { return "exporting schema" }
if phases[PhaseImportSchema] != PhaseCompleted { return "importing schema" }
if phases[PhaseExportData]  != PhaseCompleted { return progressDetail("exporting data", ...) }
if phases[PhaseImportData]  != PhaseCompleted { return progressDetail("importing data", ...) }
return "finalizing schema (indexes, triggers)"
```

**[observed]** The two migrations in `ybvoyager_visualizer`:

| | PostgreSQL (`shopdb-pg`) | SQL Server (`shopdb-mssql`) |
|---|---|---|
| phases with rows | 1 (assess), 2 (export schema), 5 (import schema), 4 (export data), 6 (import data) | 1 only |
| per-table progress | `customers 3/3`, `orders 4/4`, `products 3/3` (export and import) | none |
| `detail` while running | follows the phases | stays `exporting schema` for the whole run: `migrateDetail` falls through to its first case when no phase 2 row exists (from the code; not captured live) |
| `detail` when done | `migration complete` | `migration complete` |

So the **final state is correct for both**, but a SQL Server migration shows no
phase or row-count progress while it runs. Adding it means `migrate.sh` inserting
phase rows (and, for data, `ybvoyager_visualizer_table_metrics`) the way
`assess.sh` already does for phase 1.

Reads of the visualizer retry on `40001` (`migration/visualizer.go:152`,
`retryAborted`): YugabyteDB aborts a read that races the jobs' DDL on those
tables, which showed up as a 500 on the first assess against a fresh database.

---

## 7. The target side

| | PostgreSQL | SQL Server |
|---|---|---|
| Cluster extensions | none | `tsql_compat` (mounted as an image volume) |
| Registration | n/a | `PUT /extensions/tsql_compat`, via `amp/amp-provision.sh`; 400 on provision if absent |
| Database objects | the source's schema, names as-is | schema `dbo` (lower-cased source schema), `sys.*` types |
| `search_path` | default | `dbo, public, sys, pg_catalog` set on the database |
| Locale for `FORMAT()` | n/a | the extension image ships `en_US`, `de_DE`, `fr_FR` plus `C.utf8`; other cultures raise an error (`amp/FOLLOWUPS.md`) |
| Collation | source collations | case-insensitive columns use `sys.SQL_Latin1_General_CP1_CI_AS` |
| Credential | placeholder `cloud_admin` (shared, `task/voyager_tasks.go:131`) | same |

---

## 8. Why PostgreSQL migrations are not affected

### 8.1 Mechanism

1. **Selection is by value, not by default.** Every SQL Server branch is guarded
   by `DBType == "sqlserver"` (`voyager_handlers.go:339,417`, `deploy/voyager.go:131,234`,
   `connectivity.go:35`). A `postgresql` request never enters them.
2. **The new setting is optional.** With `AMP_ORA2PG_IMAGE` unset, nothing about
   PostgreSQL changes; only a `sqlserver` run is refused.
3. **The API change is additive.** One new enum value; request and response
   shapes for `postgresql` are identical. Generated Go names for existing values
   were pinned with `x-enum-varnames` so none were renamed.
4. **Persisted data is unchanged for PostgreSQL.** `Extensions` is
   `omitempty`; a PostgreSQL target's task JSON is the same bytes as before, so
   tasks written by an older controller still decode, and a rolling upgrade is safe.
5. **PostgreSQL scripts and image were not edited.** `deploy/voyager/` has no
   changes in this work. The new job lives in a new directory, `deploy/ora2pg/`,
   with its own image.
6. **The two jobs share only what was already generic.** The Ora2Pg image copies
   two helper scripts from `deploy/voyager/scripts/` (`amp-create-target-db.psql`,
   `amp-controlplane-bootstrap.psql`); it does not modify them.

### 8.2 Evidence

**[observed]** A PostgreSQL migration, `shopdb-pg` (source `demo-src-pg`,
PostgreSQL 17, schema `public`), ran on the same controller after the SQL Server
changes were built and deployed, using the unmodified Voyager image
(`amp/voyager:ubuntu-0d6d579ff`). Both runs succeeded:

```
shopdb-pg     completed   assess: succeeded 13:53:27-13:53:31   migrate: succeeded 13:53:57-13:54:18
shopdb-mssql  completed
```

The migrate log shows the unchanged six-step sequence:

```
Exporting schema from demo-src-pg:5432/shopdb...
Ensuring target database shopdb exists...
Importing schema into yb-ep-<id>:55433/shopdb...
Exporting data from demo-src-pg:5432/shopdb...
Importing data into yb-ep-<id>:55433/shopdb...
Finalizing schema (indexes, triggers) on the target...
Done.
```

Per-table progress for the three tables was written to the visualizer and read
back through `GET /migrations/{id}`, so the status path works for PostgreSQL.

**Unit tests** (`go test ./...` in `controller/`, plus `go vet`, `gofmt`) pin the
PostgreSQL side: `TestVoyagerSQLServerSource` asserts the PostgreSQL job still gets
the Voyager image and the same command; `TestServiceCreateMigrationTargetPlan`
exercises the shared target plan; the existing `TestCreateMigrationValidation`
and `TestStartMigration*` handler tests are unchanged and pass.

### 8.3 What is *not* PostgreSQL-neutral

State these plainly; "unaffected" is true for behaviour, not for every line.

| Change | Applies to PostgreSQL? | Effect | Evidence |
|---|---|---|---|
| Docker job reaches the target by container name (`voyager_docker.go:48,91`) | **yes**, on Docker with a shared network | `TARGET_HOST`/`TARGET_PORT` become `yb-ep-<id>:55433` instead of the recorded published address. Fixes jobs that could not reach a target published on `127.0.0.1`. Assumes the endpoint is on the job's network (true here: both use `cfg.Deploy.Network`). | `shopdb-pg` job env shows `TARGET_HOST=yb-ep-...`; migrate succeeded |
| Visualizer reads retry on `40001` (`visualizer.go:152`) | **yes** | A transient YugabyteDB error is retried (up to 5 times) instead of returned as a 500. Read-only. | unit test `TestRetryAborted`; no `40001` in the controller log on the final runs |
| `buildVoyagerJobSpec` signature takes `VoyagerImages` | yes (internal) | Same image chosen. The error text for a missing image changed from "Docker Voyager image is required" to "Voyager image is required". | `TestVoyagerSQLServerSource` |
| Docker endpoints mount extensions, Docker CLI 26.1.3 to 28.5.2 in the controller image (earlier commit `764f93234`) | yes, Docker driver | No extensions requested, so `dockerExtensions` returns nothing (`TestDockerExtensions`). The newer CLI is used for every `docker run`. | `shopdb-pg` ran through it |
| `VoyagerTargetConfig.EndpointID` added (`json:"endpoint_id,omitempty"`) | yes (internal) | Carries the endpoint id to the Docker runner. | covered by `TestDockerTargetByContainer` |

### 8.4 What is *not* proven

- The Kubernetes runner was changed (`voyager_kubernetes.go:58,227`) the same way
  but was not run; it was not tested for either source type.
- Only one PostgreSQL migration was run, with three small tables.
- The SQL Server and PostgreSQL migrations were not run concurrently to check for
  interference (they use separate volumes and target clusters).

---

## 9. Limits of the SQL Server path

| Limit | Detail |
|---|---|
| Procedures and triggers load but fail when run | Ora2Pg's T-SQL conversion is partial: dropped `DECLARE`s, `SELECT @v = col` not converted to `SELECT col INTO v`, `UPDATE ... SET` in a trigger body turned into `:=` (`amp/RESULTS.md`). |
| No progress while migrating | no phase or table rows (section 6) |
| No sizing recommendation | the assessment has no `Sizing` block |
| Database size only | table and index sizes read as 0 in the API |
| One schema per migration | Ora2Pg exports one schema per run |
| `parallel_jobs` ignored | ODBC handle does not survive Ora2Pg's fork |
| Connectivity is TCP only | wrong credentials show up in the assess run |
| `FORMAT()` cultures | only the cultures baked into the extension image work (`yugabyte/tsql_compat` `Dockerfile.amp`) |
| `DATETIMEOFFSET` | 7 fractional digits round to 6 (PostgreSQL limit) |
| Image base | `deploy/ora2pg/Dockerfile` builds `FROM ora2pg-tsql`, a local image; it should build Ora2Pg from a pinned commit |
| Kubernetes | not tested |

---

## 10. File index

**Shared (both sources)**
- `controller/internal/api/voyager_handlers.go`: all handlers
- `controller/internal/task/voyager_tasks.go`, `voyager_step_launch_job.go`, `voyager_step_attach_target.go`
- `controller/internal/deploy/voyager.go`, `voyager_docker.go`, `voyager_kubernetes.go`
- `controller/internal/voyager/migration/{store,visualizer,status,assessment,connectivity}.go`
- `deploy/voyager/scripts/amp-controlplane-bootstrap.psql`, `amp-create-target-db.psql`

**PostgreSQL only**
- `deploy/voyager/Dockerfile` and `deploy/voyager/scripts/{assess,migrate,end}.sh`
- `deploy/voyager/scripts/amp-assess-migration.sh`, `amp-source-facts.psql`, `amp-source-os-capacity.psql`

**SQL Server only**
- `deploy/ora2pg/Dockerfile`
- `deploy/ora2pg/scripts/{assess,migrate,end,ora2pg-env}.sh`
- `controller/internal/voyager/migration/connectivity.go` (`checkTCPConnectivity`)
- `controller/internal/api/voyager_handlers.go` (provision branch, one-schema rule)
- `yugabyte/tsql_compat` `Dockerfile.amp`, `amp/amp-provision.sh` (extension image and registration)

**Tests**
- `api/voyager_handlers_test.go`: `TestSQLServerMigration` (590)
- `deploy/voyager_test.go`: `TestVoyagerSQLServerSource` (174), `TestDockerTargetByContainer` (327)
- `voyager/migration/connectivity_test.go`: `TestCheckConnectivitySQLServerIsATCPProbe` (63)
- `voyager/migration/visualizer_test.go`: `TestRetryAborted` (14)
- `task/voyager_target_test.go`: `TestServiceCreateMigrationTargetPlan` (136, checks extensions reach the cluster step)

---

## 11. Reproducing the observations

```bash
API=http://127.0.0.1:18080/api/v1

# the migrations and their state
curl -s "$API/migrations?limit=10" | jq -r '.migrations[] | "\(.created_at) \(.state) \(.id) \(.name)"'

# job images and env for the two sources (passwords omitted)
for c in voyager-migrate-<pg-id8>-a1 voyager-migrate-<mssql-id8>-a1; do
  docker inspect $c --format '{{.Config.Image}}'
  docker inspect $c --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep -E '^(SOURCE_DB_TYPE|SOURCE_SCHEMAS|TARGET_HOST|TARGET_PORT)='
done

# phase rows each migration wrote (shows 4 phase-1 rows for PostgreSQL, 2 for SQL Server)
docker exec amp-yb bash -c "bin/ysqlsh -h \$(hostname -i) -p 5433 -U yugabyte -d yb_voyager -At \
  -c \"select migration_phase, invocation_sequence, status, length(payload) \
       from ybvoyager_visualizer.ybvoyager_visualizer_metadata \
       where migration_uuid='<migration-id>' order by 1,2\""

# the same assessment endpoint, both shapes
curl -s $API/migrations/<pg-id>/assessment    | jq '{migration_complexity, voyager_version, n: .sizing_recommendation.num_nodes}'
curl -s $API/migrations/<mssql-id>/assessment | jq '{migration_complexity, voyager_version, issues: [.issues[].object_type]}'

# job logs
docker logs voyager-assess-<id8>-a1
docker logs voyager-migrate-<id8>-a1 | tr '\r' '\n' | grep -v '^\[20'
```
