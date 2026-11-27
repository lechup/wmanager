-- One-time links for a new account to set its password and second factor (stage 1b). An account made in the
-- panel has no password until its person opens the link; the owner never knows it.

-- +goose Up
ALTER TABLE accounts ALTER COLUMN password_hash DROP NOT NULL;

CREATE TABLE setup_links (
    token_hash bytea PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX setup_links_account ON setup_links (account_id);

GRANT SELECT, INSERT, DELETE ON setup_links TO wmanager_runtime;

-- +goose Down
REVOKE ALL ON setup_links FROM wmanager_runtime;
DROP TABLE setup_links;
UPDATE accounts SET password_hash = '!' WHERE password_hash IS NULL;
ALTER TABLE accounts ALTER COLUMN password_hash SET NOT NULL;
