-- The files added with wmanager-sign add-file (installers, drivers): kept on disk by their SHA-256, in the folder
-- WMANAGER_FILES_DIR names, too large for the database; here is which company has which.

-- +goose Up
CREATE TABLE stored_files (
    company_id uuid NOT NULL REFERENCES companies ON DELETE CASCADE,
    hash       bytea NOT NULL CHECK (length(hash) = 32),
    size       bigint NOT NULL CHECK (size >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_id, hash)
);

ALTER TABLE stored_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE stored_files FORCE ROW LEVEL SECURITY;
CREATE POLICY stored_files_member ON stored_files TO wmanager_runtime
    USING (wm_member(company_id)) WITH CHECK (wm_member(company_id));

GRANT SELECT, INSERT ON stored_files TO wmanager_runtime;

-- +goose Down
REVOKE ALL ON stored_files FROM wmanager_runtime;
DROP TABLE stored_files;
