CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    public_id TEXT NOT NULL UNIQUE,
    friend_code TEXT NOT NULL UNIQUE,
    phone_e164 TEXT NOT NULL UNIQUE,
    first_name TEXT NOT NULL DEFAULT '',
    last_name TEXT NOT NULL DEFAULT '',
    about TEXT NOT NULL DEFAULT '',
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_users_phone_e164
    ON users (phone_e164);

CREATE TABLE IF NOT EXISTS devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    platform TEXT NOT NULL DEFAULT '',
    session_token_hash TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_devices_user_seen
    ON devices (user_id, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS recovery_codes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_plaintext TEXT NOT NULL,
    code_hash TEXT NOT NULL,
    is_used BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    used_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_recovery_codes_hash_unique
    ON recovery_codes (code_hash);

CREATE INDEX IF NOT EXISTS idx_recovery_codes_user_created
    ON recovery_codes (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS friend_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id TEXT NOT NULL UNIQUE,
    from_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    responded_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_friend_requests_to_user_status
    ON friend_requests (to_user_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_friend_requests_from_user_status
    ON friend_requests (from_user_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS friendships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_low_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_high_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_low_id, user_high_id),
    CHECK (user_low_id <> user_high_id)
);

CREATE INDEX IF NOT EXISTS idx_friendships_low
    ON friendships (user_low_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_friendships_high
    ON friendships (user_high_id, created_at DESC);

CREATE TABLE IF NOT EXISTS call_invites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invite_id TEXT NOT NULL UNIQUE,
    caller_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    callee_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    room_id TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    responded_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_call_invites_callee_status
    ON call_invites (callee_user_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_call_invites_caller_status
    ON call_invites (caller_user_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS p2p_device_directory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    public_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    platform TEXT NOT NULL DEFAULT '',
    app_version TEXT NOT NULL DEFAULT '',
    signaling_ws_url TEXT NOT NULL DEFAULT '',
    transport_preference TEXT NOT NULL DEFAULT 'webrtc',
    stun_servers JSONB NOT NULL DEFAULT '[]'::jsonb,
    turn_servers JSONB NOT NULL DEFAULT '[]'::jsonb,
    capabilities JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_online BOOLEAN NOT NULL DEFAULT FALSE,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (public_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_p2p_device_directory_public_online_seen
    ON p2p_device_directory (public_id, is_online, last_seen_at DESC);

CREATE INDEX IF NOT EXISTS idx_p2p_device_directory_seen
    ON p2p_device_directory (last_seen_at DESC);

CREATE TABLE IF NOT EXISTS p2p_prekey_bundles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    public_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    identity_key_b64 TEXT,
    device_key_b64 TEXT,
    signed_prekey_b64 TEXT,
    signed_prekey_signature_b64 TEXT,
    one_time_prekeys JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (public_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_p2p_prekey_bundles_public_device
    ON p2p_prekey_bundles (public_id, device_id);