-- wmanager-sign's access to the server (stage 2b): a short code made in the panel becomes a token of the sign
-- API; the companies' chains of admin lists; and the signing keys people register, waiting to be added to a list.
-- The server checks every list it takes (verify.Chain), but it is not what makes a list count: the computers check
-- the whole chain themselves.

-- +goose Up
CREATE TABLE sign_codes (
    code_hash  bytea PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
    expires_at timestamptz NOT NULL
);
CREATE INDEX sign_codes_account ON sign_codes (account_id);

CREATE TABLE sign_tokens (
    token_hash bytea PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL
);
CREATE INDEX sign_tokens_account ON sign_tokens (account_id);

-- Each company's chain: the signed admin lists in order (each a verify.Signed as JSON). A list names its company
-- and the list before, so one list hash in two companies would be one chain under two names: refused.
CREATE TABLE admin_lists (
    company_id uuid NOT NULL REFERENCES companies ON DELETE CASCADE,
    sequence   bigint NOT NULL,
    list_hash  bytea NOT NULL UNIQUE,
    signed     bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_id, sequence)
);

-- Signing keys registered by people (their COSE public key, with a proof signed by the key that its holder
-- registers it for this account), so an administrator can add them to a list after typing the key's fingerprint,
-- which its owner reads off their own wmanager-sign.
CREATE TABLE signing_keys (
    id         text PRIMARY KEY CHECK (id ~ '^[0-9a-f]{64}$'), -- the SHA-256 of the COSE key
    account_id uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
    cose       bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX signing_keys_account ON signing_keys (account_id);

ALTER TABLE admin_lists ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_lists FORCE ROW LEVEL SECURITY;
CREATE POLICY admin_lists_member ON admin_lists TO wmanager_runtime
    USING (wm_member(company_id)) WITH CHECK (wm_member(company_id));

GRANT SELECT, INSERT, DELETE ON sign_codes, sign_tokens TO wmanager_runtime;
GRANT SELECT, INSERT ON admin_lists TO wmanager_runtime;
GRANT SELECT, INSERT, DELETE ON signing_keys TO wmanager_runtime;

-- +goose Down
REVOKE ALL ON sign_codes, sign_tokens, admin_lists, signing_keys FROM wmanager_runtime;
DROP TABLE signing_keys;
DROP TABLE admin_lists;
DROP TABLE sign_tokens;
DROP TABLE sign_codes;
