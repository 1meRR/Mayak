ALTER TABLE recovery_codes
    ADD COLUMN IF NOT EXISTS code_plaintext TEXT NOT NULL DEFAULT '';

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
