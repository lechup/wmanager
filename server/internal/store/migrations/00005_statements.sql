-- The statements wmanager-sign signs besides admin lists (stage 2b): the drafts it signs from, the files they name
-- by their hash, the signed statements the server hands out, and the secrets' values. The server checks each
-- statement it takes (verify), but what makes it count is the computers' own check.

-- +goose Up
-- A change made in the panel (stage 4a), waiting for wmanager-sign: the JSON of what is to be signed, without what
-- wmanager-sign sets itself (format, type, time, company, serial or id).
CREATE TABLE drafts (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES companies ON DELETE CASCADE,
    type       text NOT NULL CHECK (type IN ('state', 'job', 'stop')),
    body       bytea NOT NULL,
    created_by uuid REFERENCES accounts ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX drafts_company ON drafts (company_id, created_at);

-- The files states and jobs name, by the SHA-256 of their content: package lists, scripts, and the files added with
-- wmanager-sign add-file.
CREATE TABLE files (
    company_id uuid NOT NULL REFERENCES companies ON DELETE CASCADE,
    hash       bytea NOT NULL CHECK (length(hash) = 32),
    content    bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_id, hash)
);

-- Signed statements (each a verify.Signed as JSON). A state's serial and a job's id are each the company's once.
CREATE TABLE statements (
    company_id uuid NOT NULL REFERENCES companies ON DELETE CASCADE,
    hash       bytea NOT NULL CHECK (length(hash) = 32),
    type       text NOT NULL CHECK (type IN ('state', 'job', 'stop')),
    serial     bigint CHECK ((type = 'state') = (serial IS NOT NULL)),
    job        text CHECK ((type = 'state') = (job IS NULL)),
    signed     bytea NOT NULL,
    signed_by  text NOT NULL,
    created_by uuid REFERENCES accounts ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_id, hash)
);
CREATE UNIQUE INDEX statements_serial ON statements (company_id, serial) WHERE type = 'state';
CREATE UNIQUE INDEX statements_job ON statements (company_id, job) WHERE type = 'job';

-- Secrets' values, each with its salt and the hash a state names (verify.SecretHash). A value stays while a state
-- may still name it; the computers fetch the ones their scripts declare (stage 4b).
CREATE TABLE secrets (
    company_id uuid NOT NULL REFERENCES companies ON DELETE CASCADE,
    name       text NOT NULL,
    hash       bytea NOT NULL CHECK (length(hash) = 32),
    salt       bytea NOT NULL,
    value      bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_id, hash)
);

ALTER TABLE drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE drafts FORCE ROW LEVEL SECURITY;
CREATE POLICY drafts_member ON drafts TO wmanager_runtime
    USING (wm_member(company_id)) WITH CHECK (wm_member(company_id));
ALTER TABLE files ENABLE ROW LEVEL SECURITY;
ALTER TABLE files FORCE ROW LEVEL SECURITY;
CREATE POLICY files_member ON files TO wmanager_runtime
    USING (wm_member(company_id)) WITH CHECK (wm_member(company_id));
ALTER TABLE statements ENABLE ROW LEVEL SECURITY;
ALTER TABLE statements FORCE ROW LEVEL SECURITY;
CREATE POLICY statements_member ON statements TO wmanager_runtime
    USING (wm_member(company_id)) WITH CHECK (wm_member(company_id));
-- Secrets' values are read and written only by the server's own work, never on behalf of a member.
ALTER TABLE secrets ENABLE ROW LEVEL SECURITY;
ALTER TABLE secrets FORCE ROW LEVEL SECURITY;
CREATE POLICY secrets_system ON secrets TO wmanager_runtime USING (wm_system()) WITH CHECK (wm_system());

GRANT SELECT, INSERT, DELETE ON drafts TO wmanager_runtime;
GRANT SELECT, INSERT ON files, statements, secrets TO wmanager_runtime;

-- +goose Down
REVOKE ALL ON drafts, files, statements, secrets FROM wmanager_runtime;
DROP TABLE secrets;
DROP TABLE statements;
DROP TABLE files;
DROP TABLE drafts;
