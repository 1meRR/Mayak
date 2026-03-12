use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicUserResponse {
    pub public_id: String,
    pub display_name: String,
    pub first_name: String,
    pub last_name: String,
    pub phone: String,
    pub about: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceResponse {
    pub device_id: String,
    pub owner_public_id: String,
    pub platform: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoveryCodeView {
    pub code: String,
    pub is_used: bool,
    pub created_at: i64,
    pub used_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FriendRequestView {
    pub id: String,
    pub from_public_id: String,
    pub from_display_name: String,
    pub to_public_id: String,
    pub to_display_name: String,
    pub status: String,
    pub created_at: i64,
    pub responded_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FriendUserView {
    pub public_id: String,
    pub display_name: String,
    pub about: String,
    pub is_online: bool,
    pub last_seen_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DirectMessageRecord {
    pub id: String,
    pub chat_id: String,
    pub from_public_id: String,
    pub to_public_id: String,
    pub text: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CallInviteView {
    pub id: String,
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
pub struct RepositoryCounts {
    pub users_count: i64,
    pub devices_count: i64,
    pub contacts_count: i64,
    pub chats_count: i64,
    pub events_count: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryEvent {
    pub event_id: String,
    pub event_type: String,
    pub origin_node: String,
    pub chat_key: Option<String>,
    pub author_public_id: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryUser {
    pub public_id: String,
    pub first_name: String,
    pub last_name: String,
    pub home_node: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthCounts {
    pub users_count: i64,
    pub call_invites_count: i64,
}


#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaObjectView {
    pub media_id: String,
    pub owner_public_id: String,
    pub owner_device_id: Option<String>,
    pub media_kind: String,
    pub content_type: String,
    pub file_name: String,
    pub file_size_bytes: i64,
    pub sha256_hex: String,
    pub created_at: i64,
    pub download_url: String,
}

#[derive(Debug, Clone)]
pub struct MediaFilePayload {
    pub content_type: String,
    pub file_name: String,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MailboxItemView {
    pub mailbox_id: String,
    pub event_id: String,
    pub chat_key: String,
    pub event_type: String,
    pub payload: serde_json::Value,
    pub status: String,
    pub created_at: i64,
    pub delivered_at: Option<i64>,
    pub acked_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MailboxAckResult {
    pub acked_count: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositorySyncCursor {
    pub device_id: String,
    pub stream_key: String,
    pub cursor_value: String,
    pub updated_at: i64,
}
