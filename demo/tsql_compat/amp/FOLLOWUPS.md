# tsql_compat on AMP: follow-ups

Deliberately left out of the POC, which is kept minimal (Docker AMP only,
registered extension, three culture locales). Each item says what is missing
and what happens without it.

## Extension (tsql_compat)

1. **More FORMAT/PARSE cultures.** The image ships only `en_US`, `de_DE`,
   `fr_FR` (+ `C.utf8`). Any other culture makes the whole statement fail with
   `invalid value for parameter "lc_numeric"`. Add more with
   `--build-arg LOCALES="..."` (all 107 glibc-supported cultures cost ~80 MB).
2. **Cultures glibc does not have at all** (en-BZ, en-JM, en-TT, fr-MC, ms-BN,
   zh-MO) error even with every locale shipped. Fix in C: map each to a close
   relative, or format through ICU instead of libc locales (removes the need to
   ship locales at all, and matches SQL Server, where every culture works).
3. **Unknown culture behaviour.** SQL Server's FORMAT returns NULL for an
   unknown culture; tsql_compat raises an error.
4. **French day/month capitalisation.** `FORMAT(..., 'D', 'fr-FR')` gives
   `Mercredi 25 Septembre`; SQL Server gives `mercredi 25 septembre`. Unverified
   whether this is tsql_compat or the glibc locale.
5. **NEWSEQUENTIALID()** returns random UUIDs, not increasing ones (same as
   before the uuid-ossp change).
6. **DATETIMEOFFSET precision.** SQL Server keeps 7 fractional digits,
   PostgreSQL 6, so values round (`23:59:59.9999999` becomes the next day).

## Migration (Ora2Pg)

7. **Procedures and triggers** load but do not run (`phase4-results.md`). Ora2Pg conversion bugs: `DECLARE`d variables dropped,
   `SELECT @v = col` not turned into `SELECT col INTO v`, `DATETIME` variables
   typed `varchar`, and `UPDATE … SET` in a trigger body turned into `:=`. Fix
   in Ora2Pg or report as manual remediation in the assessment. The trigger
   also re-fires itself on PostgreSQL (SQL Server does not by default).
8. **`nvarchar(100)` is exported as `nvarchar(200)`.**
9. **Larger sample.** `shop` has 9 rows. Test volume and more types (money,
    uniqueidentifier, varbinary, nvarchar, datetimeoffset) on SQL Server Express
    (10 GB limit).
10. ~~**Per-object results table.**~~ Done: `migrate.sh` runs every object;
    written up in `phase4-results.md`.

## Scripts

11. **Passwords in plain text** in `amp.env` (git-ignored).
12. ~~**No home.**~~ Done: the scripts live in `yugabyte/ora2pg`
    `demo/tsql_compat/amp/`.
13. **Endpoint replacement** after re-registering the extension is done by hand
    (DELETE + POST endpoint, then edit `amp.env`); worth a script.

## AMP productisation (deferred)

14. **Kubernetes**: make tsql_compat a built-in extension (manifest row,
    `catalog.go`, UI regen, regress block, CI step, Quay repo).
15. **Engine**: AMP's `sqlserver` engine bundles `hexabridge_mssql`; decide how
    tsql_compat relates to it (both install into schema `sys`).
16. ~~**Migration API**~~ Done on Docker: `db_type: sqlserver` runs through
    the existing migration APIs on the Ora2Pg job image
    (`meko/amp/deploy/ora2pg`); `migrate.sh` drives it for AMP.
    Remaining gaps:
    - The Ora2Pg image builds `FROM ora2pg-tsql` (a local image). Build Ora2Pg
      from a pinned `yugabyte/ora2pg` commit, as the Voyager image pins
      yb-voyager, and publish it to a registry.
    - Not run on Kubernetes (the runner change covers it, untested).
    - No progress while `migrating`: the job writes no phase/table-metrics rows.
    - Assessment has no sizing recommendation, and Ora2Pg reports only the
      whole database size, which the API does not show (table/index sizes are 0).
    - Connectivity check is TCP only (no login, version or SSL).
    - One schema per migration; `parallel_jobs` is ignored (ODBC handles do
      not survive Ora2Pg's fork).
17. **Review**: branch `ameya/tsql-compat-amp` in `yugabyte/meko`,
    `yugabyte/ora2pg` and `AmeyaKasture/tsql_compat` (a fork: no write access
    to `yugabyte/tsql_compat`). Pushed, no PRs yet.
