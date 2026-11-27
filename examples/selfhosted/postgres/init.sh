#!/usr/bin/env bash
# PostgreSQL's first start (docker-entrypoint-initdb.d): the roles of wmanager-server (docs/server.md).
#   wmanager_owner     owns the tables; the server's migrations run as it
#   wmanager_runtime   a group without login: what the server may do (the migrations grant it)
#   wmanager           the server's own login, in wmanager_runtime only: it can't change or remove audit entries
# The passwords are read from the secrets inside psql (\set with a backtick), never put on a command line.
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres <<'SQL'
\set owner_pw `cat /run/secrets/owner-password`
\set server_pw `cat /run/secrets/server-password`
CREATE ROLE wmanager_runtime NOLOGIN;
CREATE ROLE wmanager_owner LOGIN PASSWORD :'owner_pw';
CREATE ROLE wmanager LOGIN PASSWORD :'server_pw' IN ROLE wmanager_runtime;
CREATE DATABASE wmanager OWNER wmanager_owner;
REVOKE ALL ON DATABASE wmanager FROM PUBLIC;
GRANT CONNECT ON DATABASE wmanager TO wmanager;
SQL
