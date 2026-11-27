-- Passkeys as the other second factor of the panel (stage 1d). They are not the signing keys of wmanager-sign:
-- those use the relying party id wmanager-sign.invalid, which no web page can claim, and are never kept here.

-- +goose Up
CREATE TABLE passkeys (
    id           bytea PRIMARY KEY,               -- the credential's id
    account_id   uuid NOT NULL REFERENCES accounts ON DELETE CASCADE,
    rp_id        text NOT NULL,                   -- the panel's host it was made for; others are not offered
    name         text NOT NULL CHECK (length(name) BETWEEN 1 AND 60),
    credential   bytea NOT NULL,                  -- the credential record as go-webauthn keeps it (JSON)
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz
);
CREATE INDEX passkeys_account ON passkeys (account_id);

-- A ceremony in progress (its challenge), kept with the session it belongs to
ALTER TABLE sessions ADD COLUMN webauthn bytea;

GRANT SELECT, INSERT, UPDATE, DELETE ON passkeys TO wmanager_runtime;

-- +goose Down
ALTER TABLE sessions DROP COLUMN webauthn;
REVOKE ALL ON passkeys FROM wmanager_runtime;
DROP TABLE passkeys;
