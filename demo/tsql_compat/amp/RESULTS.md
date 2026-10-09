# Results: SQL Server Express -> AMP (tsql_compat)

Source: `demo-mssql` (SQL Server 2022 Express), database `shop`. Target: an AMP
endpoint (forked PostgreSQL 18, Docker driver) with tsql_compat mounted as a
registered extension (`amp-ext-tsql_compat:1.0-poc`), provisioned and loaded
through the controller's migration API:

    ./migrate.sh

## Per object

| Object | Type | AMP | Root cause |
|---|---|---|---|
| customers | table | OK | |
| orders | table | OK | |
| order_items | table | OK | |
| v_customer_summary | view | OK | |
| fn_order_age | function | OK | |
| usp_place_order | procedure | loads, fails: `"v_ship" is not a known variable` | Ora2Pg: a `DECLARE`d T-SQL variable is dropped |
| usp_customer_stats | procedure | loads, fails: `"v_days" is not a known variable` | Ora2Pg: drops 2 of 4 `DECLARE`s, maps `DATETIME` variable to `varchar`, leaves `SELECT @v = col` untranslated (needs `SELECT col INTO v`) |
| trg_customers_touch | trigger | loads, fails: `syntax error at or near ":="` | Ora2Pg: `UPDATE … SET col = …` in the body becomes `UPDATE … col := …`. Once fixed, the body updates its own table from an `AFTER UPDATE` trigger, which PostgreSQL re-fires (SQL Server does not by default) |

Procedures and the trigger load because Ora2Pg's output sets
`check_function_bodies = false`; the errors appear only when they run. They are
run in a rolled-back transaction, so the data is unchanged.

## Whole run

| Check | AMP |
|---|---|
| Schema load (5 files) | OK |
| Rows copied | 9/9 |
| T-SQL queries (view, DATEADD, LEN, CHARINDEX, ISNULL, IIF, DATENAME, EOMONTH) | OK |
| tsql_compat regression suite (6 files) | pass |
| `GETDATE()` with `sys` off the search_path | fails (expected) |

The procedure and trigger failures are Ora2Pg conversion issues, not AMP ones.
`DATETIMEOFFSET` rounds from 7 to 6 fractional digits (`23:59:59.9999999`
becomes the next day). `FORMAT()` works for the cultures the extension image
ships (`en_US`, `de_DE`, `fr_FR`); see `FOLLOWUPS.md` items 1–3.
