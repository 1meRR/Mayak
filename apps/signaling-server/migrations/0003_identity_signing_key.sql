ALTER TABLE device_key_packages
    ADD COLUMN IF NOT EXISTS identity_signing_key_b64 TEXT;
