# Ora2Pg from this source tree, with the Microsoft ODBC driver for SQL Server
# and the PostgreSQL client.
#
# Build from this directory (the build context is the repository root):
#
#   docker build --platform linux/arm64 -t ora2pg-tsql -f Dockerfile ../..
#
# Run:
#
#   docker run --rm --network tsql-demo -v "$PWD:/work" ora2pg-tsql ora2pg -c /work/ora2pg.conf -t SHOW_REPORT

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# Perl drivers, unixODBC and psql, then msodbcsql18 from the Microsoft
# repository (packages exist for amd64 and arm64).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg make perl \
        libdbi-perl libdbd-pg-perl libdbd-odbc-perl libterm-readkey-perl \
        unixodbc postgresql-client \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
 && echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/mssql-release.list \
 && apt-get update \
 && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
 && rm -rf /var/lib/apt/lists/*

# Ora2Pg recognizes a SQL Server DSN by "driver=msodbcsql", register the
# driver under that name.
RUN printf '[msodbcsql18]\nDescription=Microsoft ODBC Driver 18 for SQL Server\nDriver=%s\nUsageCount=1\n' \
        "$(ls /opt/microsoft/msodbcsql18/lib64/libmsodbcsql-18.*.so.* | head -1)" >> /etc/odbcinst.ini

COPY . /usr/src/ora2pg
RUN cd /usr/src/ora2pg \
 && perl Makefile.PL \
 && make \
 && make install \
 && cd / && rm -rf /usr/src/ora2pg

WORKDIR /work
CMD ["ora2pg", "--version"]
