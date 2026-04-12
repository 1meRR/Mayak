use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserProfileView {
    pub public_id: String,
    pub friend_code: String,
    pub display_name: String,
    pub about: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginResponse {
    pub session_token: String,
    pub profile: UserProfileView,
    pub device_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterRequest {
    pub phone_e164: String,
    pub password: String,
    pub first_name: String,
    pub last_name: String,
    pub about: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginRequest {
    pub phone_e164: String,
    pub password: String,
    pub device_id: String,
    pub platform: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceDirectoryView {
    pub public_id: String,
    pub device_id: String,
    pub platform: String,
    pub is_online: bool,
    pub last_seen_at: i64,
    pub app_version: Option<String>,
    pub capabilities: serde_json::Value,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceKeyPackageView {
    pub public_id: String,
    pub device_id: String,
    pub identity_key_alg: String,
    pub identity_key_b64: String,
    pub identity_signing_key_b64: Option<String>,
    pub signed_prekey_b64: String,
    pub signed_prekey_signature_b64: String,
    pub signed_prekey_key_id: i64,
    pub one_time_prekeys: Vec<String>,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpsertDeviceKeyPackageRequest {
    pub device_id: String,
    pub identity_key_alg: String,
    pub identity_key_b64: String,
    pub identity_signing_key_b64: Option<String>,
    pub signed_prekey_b64: String,
    pub signed_prekey_signature_b64: String,
    pub signed_prekey_key_id: i64,
    pub one_time_prekeys: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaimPrekeyRequest {
    pub public_id: String,
    pub device_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecipientEnvelopeInput {
    pub recipient_public_id: String,
    pub recipient_device_id: String,
    pub message_kind: String,
    pub protocol: String,
    pub header_b64: String,
    pub ciphertext_b64: String,
    pub metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendEncryptedMessageRequest {
    pub envelope_group_id: String,
    pub conversation_id: String,
    pub sender_device_id: String,
    pub recipients: Vec<RecipientEnvelopeInput>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredEnvelopeView {
    pub envelope_id: String,
    pub conversation_id: String,
    pub sender_public_id: String,
    pub sender_device_id: String,
    pub recipient_public_id: String,
    pub recipient_device_id: String,
    pub message_kind: String,
    pub protocol: String,
    pub header_b64: String,
    pub ciphertext_b64: String,
    pub metadata: serde_json::Value,
    pub created_at: i64,
    pub delivered_at: Option<i64>,
    pub acked_at: Option<i64>,
    pub read_at: Option<i64>,
    pub server_seq: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SendEncryptedMessageResponse {
    pub stored: Vec<StoredEnvelopeView>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingMessagesQuery {
    pub device_id: String,
    pub limit: Option<i64>,
    pub after_server_seq: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingMessagesResponse {
    pub items: Vec<StoredEnvelopeView>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AckEnvelopeRequest {
    pub device_id: String,
    pub mark_read: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AckEnvelopeResponse {
    pub envelope_id: String,
    pub acked_at: i64,
    pub read_at: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileRecipientKeyEnvelopeInput {
    pub recipient_public_id: String,
    pub recipient_device_id: String,
    pub wrapped_file_key_b64: String,
    pub metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateFileObjectRequest {
    pub file_id: String,
    pub uploader_device_id: String,
    pub object_key: String,
    pub media_type: String,
    pub file_name: String,
    pub ciphertext_size: i64,
    pub chunk_size_bytes: i32,
    pub total_chunks: i32,
    pub ciphertext_sha256_hex: String,
    pub client_metadata: Option<serde_json::Value>,
    pub recipient_key_envelopes: Vec<FileRecipientKeyEnvelopeInput>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompleteFileObjectRequest {
    pub upload_status: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileObjectView {
    pub file_id: String,
    pub object_key: String,
    pub media_type: String,
    pub file_name: String,
    pub ciphertext_size: i64,
    pub chunk_size_bytes: i32,
    pub total_chunks: i32,
    pub ciphertext_sha256_hex: String,
    pub upload_status: String,
    pub client_metadata: serde_json::Value,
    pub created_at: i64,
    pub completed_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileKeyEnvelopeView {
    pub file_id: String,
    pub recipient_public_id: String,
    pub recipient_device_id: String,
    pub wrapped_file_key_b64: String,
    pub metadata: serde_json::Value,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileLookupResponse {
    pub file: FileObjectView,
    pub key_envelope: Option<FileKeyEnvelopeView>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorResponse {
    pub error: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FriendUserView {
    pub public_id: String,
    pub friend_code: String,
    pub display_name: String,
    pub about: String,
    pub created_at: i64,
    pub is_online: bool,
    pub last_seen_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserLookupResponse {
    pub user: FriendUserView,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FriendRequestView {
    pub id: String,
    pub request_id: String,
    pub from_public_id: String,
    pub from_display_name: String,
    pub to_public_id: String,
    pub to_display_name: String,
    pub status: String,
    pub created_at: i64,
    pub responded_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FriendsBundleView {
    pub public_id: String,
    pub friends: Vec<FriendUserView>,
    pub incoming_requests: Vec<FriendRequestView>,
    pub outgoing_requests: Vec<FriendRequestView>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateFriendRequestRequest {
    pub from_public_id: String,
    pub from_device_id: String,
    pub session_token: String,
    pub to_public_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RespondFriendRequestRequest {
    pub request_id: String,
    pub actor_public_id: String,
    pub actor_device_id: String,
    pub session_token: String,
    pub action: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeleteFriendRequest {
    pub actor_public_id: String,
    pub actor_device_id: String,
    pub session_token: String,
    pub friend_public_id: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeleteFriendResponse {
    pub removed: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateCallInviteRequest {
    pub caller_public_id: String,
    pub caller_device_id: String,
    pub session_token: String,
    pub callee_public_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RespondCallInviteRequest {
    pub invite_id: String,
    pub actor_public_id: String,
    pub actor_device_id: String,
    pub session_token: String,
    pub action: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CallInviteView {
    pub invite_id: String,
    pub caller_public_id: String,
    pub caller_display_name: String,
    pub callee_public_id: String,
    pub callee_display_name: String,
    pub room_id: String,
    pub status: String,
    pub created_at: i64,
    pub responded_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IncomingCallListResponse {
    pub items: Vec<CallInviteView>,
}
