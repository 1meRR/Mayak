DROP TABLE IF EXISTS mailbox_items CASCADE;
DROP TABLE IF EXISTS sync_cursors CASCADE;
DROP TABLE IF EXISTS media_objects CASCADE;

CREATE TABLE media_objects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    media_id TEXT NOT NULL UNIQUE,
    owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    owner_device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
    media_kind TEXT NOT NULL,
    content_type TEXT NOT NULL,
    file_name TEXT NOT NULL,
    file_size_bytes BIGINT NOT NULL,
    storage_key TEXT NOT NULL,
    sha256_hex TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_media_objects_owner_user_created_at
    ON media_objects (owner_user_id, created_at DESC);
CREATE INDEX idx_media_objects_media_kind_created_at
    ON media_objects (media_kind, created_at DESC);

CREATE TABLE mailbox_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    mailbox_id TEXT NOT NULL UNIQUE,
    target_device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    event_id TEXT NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
    chat_key TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at TIMESTAMPTZ,
    acked_at TIMESTAMPTZ
);

CREATE INDEX idx_mailbox_items_target_device_status_created_at
    ON mailbox_items (target_device_id, status, created_at ASC);
CREATE INDEX idx_mailbox_items_target_device_created_at
    ON mailbox_items (target_device_id, created_at ASC);

CREATE TABLE sync_cursors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    stream_key TEXT NOT NULL,
    cursor_value TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (device_id, stream_key)
);

CREATE INDEX idx_sync_cursors_device_updated_at
    ON sync_cursors (device_id, updated_at DESC);
