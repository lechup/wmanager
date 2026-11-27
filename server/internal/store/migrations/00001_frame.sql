-- The server's frame (stage 1a): companies, accounts and their second factor, sessions, and the audit log.
--
-- Two roles: the migrations run as the role that owns the tables; the server runs as a role in the group
-- wmanager_runtime, which gets only what it needs. It can't TRUNCATE, change or remove audit entries, and it
-- doesn't own the tables, so it can't turn row-level security off.
--
-- Row-level security is a second barrier against a query that forgets to limit itself to a company. It is not a
-- barrier against SQL injection or a hacked server: any SQL can set the settings below. The audit log's hash
-- chain and its head written down elsewhere are what catch a hacked server. Each transaction of the server sets,
-- for itself only:
--   wmanager.account  the signed-in account's id, or empty
--   wmanager.system   'on' for the server's own work (sign-in, the audit log, background jobs)

-- +goose Up
-- +goose StatementBegin
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wmanager_runtime') THEN
        RAISE EXCEPTION 'the role wmanager_runtime is missing: create it (NOLOGIN) and put the server''s role in it';
    END IF;
END $$;
-- +goose StatementEnd

CREATE TABLE companies (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 100),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email           text NOT NULL UNIQUE CHECK (email = lower(email) AND length(email) BETWEEN 3 AND 254),
    name            text NOT NULL DEFAULT '' CHECK (length(name) <= 100),
    password_hash   text NOT NULL,
    -- the owner of the server makes companies and accounts
    is_owner        boolean NOT NULL DEFAULT false,
    -- TOTP: the secret, set when the account confirms it, and the last time step used (a code works once)
    totp_secret     bytea,
    totp_last_step  bigint NOT NULL DEFAULT 0,
    -- wrong second-factor codes in a row (they need the right password), the lockouts they caused since the last
    -- sign-in (each one twice as long), and the end of the current one
    failed_codes    integer NOT NULL DEFAULT 0,
    lockouts        integer NOT NULL DEFAULT 0,
    locked_until    timestamptz,
    disabled        boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE recovery_codes (
    account_id uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
    code_hash  bytea NOT NULL,
    used_at    timestamptz,
    PRIMARY KEY (account_id, code_hash)
);

-- An account's role in a company: 'admin' edits it and prepares statements; 'person' has the rights an
-- administrator gave in units (stage 4, docs/architecture.md "People and their rights").
CREATE TABLE memberships (
    account_id uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
    company_id uuid NOT NULL REFERENCES companies ON DELETE CASCADE,
    role       text NOT NULL CHECK (role IN ('admin', 'person')),
    PRIMARY KEY (account_id, company_id)
);
CREATE INDEX memberships_company ON memberships (company_id);

-- Sessions of the panel. The cookie holds a random token; only its SHA-256 is kept, so a copy of the database
-- signs no one in. A session is 'password' until the second factor is given, then 'full'.
CREATE TABLE sessions (
    token_hash   bytea PRIMARY KEY,
    account_id   uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
    stage        text NOT NULL CHECK (stage IN ('password', 'full')),
    -- a TOTP secret offered to an account that has none yet, until a code from it confirms it
    pending_totp bytea,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen    timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL
);
CREATE INDEX sessions_account ON sessions (account_id);

-- The audit log: one chain for the server ('server') and one per company ('company:<id>'). Each entry is the
-- exact JSON that was hashed; its hash is SHA-256(the previous hash || the entry). audit_heads holds the newest
-- entry of each chain and is locked while one is added, so entries of a chain are never added side by side.
CREATE TABLE audit_heads (
    chain text PRIMARY KEY,
    seq   bigint NOT NULL,
    hash  bytea NOT NULL
);

CREATE TABLE audit_log (
    chain      text NOT NULL,
    seq        bigint NOT NULL,
    company_id uuid REFERENCES companies ON DELETE RESTRICT,
    entry      bytea NOT NULL,
    hash       bytea NOT NULL,
    PRIMARY KEY (chain, seq),
    CHECK (chain = coalesce('company:' || company_id::text, 'server'))
);

-- +goose StatementBegin
-- Entries are never changed or removed, not even by the role that owns the table (unless it drops this).
CREATE FUNCTION wm_audit_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'the audit log is append-only';
END $$;
-- +goose StatementEnd
CREATE TRIGGER audit_log_no_update BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION wm_audit_append_only();
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION wm_audit_append_only();

-- +goose StatementBegin
CREATE FUNCTION wm_system() RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT coalesce(current_setting('wmanager.system', true), '') = 'on'
$$;

CREATE FUNCTION wm_account() RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT nullif(coalesce(current_setting('wmanager.account', true), ''), '')::uuid
$$;

-- May the signed-in account see this company's rows? Its members may; the owner of the server sees the list of
-- companies but not their data.
CREATE FUNCTION wm_member(company uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT wm_system() OR EXISTS (
        SELECT 1 FROM memberships m JOIN accounts a ON a.id = m.account_id
        WHERE m.company_id = company AND m.account_id = wm_account() AND NOT a.disabled)
$$;
-- +goose StatementEnd

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_log_read ON audit_log FOR SELECT TO wmanager_runtime
    USING (CASE WHEN company_id IS NULL
                THEN wm_system() OR EXISTS (SELECT 1 FROM accounts a
                                            WHERE a.id = wm_account() AND a.is_owner AND NOT a.disabled)
                ELSE wm_member(company_id) END);
CREATE POLICY audit_log_insert ON audit_log FOR INSERT TO wmanager_runtime WITH CHECK (wm_system());

ALTER TABLE audit_heads ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_heads FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_heads_system ON audit_heads TO wmanager_runtime USING (wm_system()) WITH CHECK (wm_system());

-- What the server's role may do: everything it needs, and on the audit log only reading and adding.
GRANT SELECT, INSERT, UPDATE, DELETE ON companies, accounts, recovery_codes, memberships, sessions TO wmanager_runtime;
GRANT SELECT, INSERT, UPDATE ON audit_heads TO wmanager_runtime;
GRANT SELECT, INSERT ON audit_log TO wmanager_runtime;
GRANT SELECT ON goose_db_version TO wmanager_runtime;

-- +goose Down
REVOKE ALL ON companies, accounts, recovery_codes, memberships, sessions, audit_heads, audit_log, goose_db_version
    FROM wmanager_runtime;
DROP TABLE audit_log;
DROP FUNCTION wm_audit_append_only();
DROP TABLE audit_heads;
DROP FUNCTION wm_member(uuid);
DROP FUNCTION wm_account();
DROP FUNCTION wm_system();
DROP TABLE sessions;
DROP TABLE memberships;
DROP TABLE recovery_codes;
DROP TABLE accounts;
DROP TABLE companies;
