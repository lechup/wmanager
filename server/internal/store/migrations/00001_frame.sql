-- The server's frame (stage 1a): companies, accounts and their second factor, sessions, and the audit log.
--
-- Row-level security is a second barrier behind the queries, which are already limited to the companies of the
-- signed-in account. Each request sets, for its transaction only:
--   wmanager.account  the signed-in account's id, or empty
--   wmanager.system   'on' for the server's own work (migrations, sign-in, background jobs)
-- The server's role must not be a superuser: a superuser passes every policy.

-- +goose Up
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
    -- failed sign-ins in a row, and the lockout they cause
    failed_signins  integer NOT NULL DEFAULT 0,
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
    token_hash  bytea PRIMARY KEY,
    account_id  uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
    stage       text NOT NULL CHECK (stage IN ('password', 'full')),
    -- a TOTP secret offered to an account that has none yet, until a code from it confirms it
    pending_totp bytea,
    created_at  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL
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
    CHECK ((chain = 'server') = (company_id IS NULL))
);

-- +goose StatementBegin
CREATE FUNCTION wm_system() RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT coalesce(current_setting('wmanager.system', true), '') = 'on'
$$;

CREATE FUNCTION wm_account() RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT nullif(coalesce(current_setting('wmanager.account', true), ''), '')::uuid
$$;

-- May the signed-in account see this company's rows? Its members may; the owner of the server sees the list of
-- companies (companies table) but not their data.
CREATE FUNCTION wm_member(company uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT wm_system() OR EXISTS (
        SELECT 1 FROM memberships m WHERE m.company_id = company AND m.account_id = wm_account())
$$;
-- +goose StatementEnd

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_log_read ON audit_log FOR SELECT
    USING (CASE WHEN company_id IS NULL
                THEN wm_system() OR EXISTS (SELECT 1 FROM accounts a WHERE a.id = wm_account() AND a.is_owner)
                ELSE wm_member(company_id) END);
-- entries are added by the server's own code only, and never changed or removed
CREATE POLICY audit_log_insert ON audit_log FOR INSERT WITH CHECK (wm_system());

ALTER TABLE audit_heads ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_heads FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_heads_system ON audit_heads USING (wm_system()) WITH CHECK (wm_system());

-- +goose Down
DROP TABLE audit_log;
DROP TABLE audit_heads;
DROP FUNCTION wm_member(uuid);
DROP FUNCTION wm_account();
DROP FUNCTION wm_system();
DROP TABLE sessions;
DROP TABLE memberships;
DROP TABLE recovery_codes;
DROP TABLE accounts;
DROP TABLE companies;
