CREATE TABLE IF NOT EXISTS device_key_packages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    identity_key_alg TEXT NOT NULL DEFAULT 'x25519+ed25519',
    identity_key_b64 TEXT NOT NULL,
    signed_prekey_b64 TEXT NOT NULL,
    signed_prekey_signature_b64 TEXT NOT NULL,
    signed_prekey_key_id BIGINT NOT NULL DEFAULT 1,
    one_time_prekeys JSONB NOT NULL DEFAULT '[]'::jsonb,
    replaced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_device_key_packages_user_device
    ON device_key_packages (user_id, device_id);

CREATE TABLE IF NOT EXISTS message_envelopes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    envelope_id TEXT NOT NULL UNIQUE,
    conversation_id TEXT NOT NULL,
    sender_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sender_device_id TEXT NOT NULL,
    recipient_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_device_id TEXT NOT NULL,
    message_kind TEXT NOT NULL,
    protocol TEXT NOT NULL DEFAULT 'signal-v1',
    header_b64 TEXT NOT NULL,
    ciphertext_b64 TEXT NOT NULL,
    server_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    server_seq BIGSERIAL NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at TIMESTAMPTZ,
    acked_at TIMESTAMPTZ,
    read_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_message_envelopes_recipient_pending
    ON message_envelopes (recipient_user_id, recipient_device_id, server_seq)
    WHERE acked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_message_envelopes_conversation
    ON message_envelopes (conversation_id, created_at);

CREATE TABLE IF NOT EXISTS file_objects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_id TEXT NOT NULL UNIQUE,
    uploader_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    uploader_device_id TEXT NOT NULL,
    object_key TEXT NOT NULL UNIQUE,
    media_type TEXT NOT NULL,
    file_name TEXT NOT NULL,
    ciphertext_size BIGINT NOT NULL,
    chunk_size_bytes INTEGER NOT NULL,
    total_chunks INTEGER NOT NULL,
    ciphertext_sha256_hex TEXT NOT NULL,
    upload_status TEXT NOT NULL DEFAULT 'initiated',
    client_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_file_objects_uploader
    ON file_objects (uploader_user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS file_key_envelopes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_id TEXT NOT NULL REFERENCES file_objects(file_id) ON DELETE CASCADE,
    recipient_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_device_id TEXT NOT NULL,
    protocol TEXT NOT NULL DEFAULT 'file-key-wrap-v1',
    wrapped_file_key_b64 TEXT NOT NULL,
    server_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (file_id, recipient_user_id, recipient_device_id)
);

CREATE INDEX IF NOT EXISTS idx_file_key_envelopes_recipient
    ON file_key_envelopes (recipient_user_id, recipient_device_id, created_at DESC);