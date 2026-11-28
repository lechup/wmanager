-- Computers and their enrollment (stage 3a, docs/agent.md): the tokens an administrator makes for installers, and
-- each computer's public key, by which every request it makes is checked. A computer is in no group until a signed
-- state lists it: this table only says who may ask the server for its company's statements.

-- +goose Up
CREATE TABLE enrollment_tokens (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES companies ON DELETE CASCADE,
    token_hash bytea NOT NULL UNIQUE,
    uses_left  integer NOT NULL CHECK (uses_left >= 0),
    expires_at timestamptz NOT NULL,
    created_by uuid REFERENCES accounts ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX enrollment_tokens_company ON enrollment_tokens (company_id);

CREATE TABLE computers (
    id           text PRIMARY KEY CHECK (id ~ '^[0-9a-f]{64}$'), -- the SHA-256 of its public key (SPKI)
    company_id   uuid NOT NULL REFERENCES companies ON DELETE CASCADE,
    public_key   bytea NOT NULL,
    name         text NOT NULL,
    enrolled_at  timestamptz NOT NULL DEFAULT now(),
    token_id     uuid REFERENCES enrollment_tokens ON DELETE SET NULL,
    last_contact timestamptz,
    last_address text
);
CREATE INDEX computers_company ON computers (company_id);

ALTER TABLE enrollment_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE enrollment_tokens FORCE ROW LEVEL SECURITY;
CREATE POLICY enrollment_tokens_member ON enrollment_tokens TO wmanager_runtime
    USING (wm_member(company_id)) WITH CHECK (wm_member(company_id));
ALTER TABLE computers ENABLE ROW LEVEL SECURITY;
ALTER TABLE computers FORCE ROW LEVEL SECURITY;
CREATE POLICY computers_member ON computers TO wmanager_runtime
    USING (wm_member(company_id)) WITH CHECK (wm_member(company_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON enrollment_tokens TO wmanager_runtime;
GRANT SELECT, INSERT, UPDATE ON computers TO wmanager_runtime;

-- +goose Down
REVOKE ALL ON enrollment_tokens, computers FROM wmanager_runtime;
DROP TABLE computers;
DROP TABLE enrollment_tokens;
