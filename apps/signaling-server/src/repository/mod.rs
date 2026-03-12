use serde::Serialize;

use crate::domain::models::{
    DirectMessageRecord, FriendRequestView, FriendUserView, MailboxAckResult, MailboxItemView,
    PublicUserResponse, RepositoryCounts, RepositoryEvent, RepositorySyncCursor, RepositoryUser,
};
use crate::storage::postgres_store::{FriendsBundle, PostgresStore};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryStatusResponse {
    pub mode: String,
    pub postgres: RepositoryCounts,
    pub notes: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryRecentEventsResponse {
    pub items: Vec<RepositoryEvent>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryRecentUsersResponse {
    pub items: Vec<RepositoryUser>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserLookupResponse {
    pub user: PublicUserResponse,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FriendsResponse {
    pub public_id: String,
    pub friends: Vec<FriendUserView>,
    pub incoming_requests: Vec<FriendRequestView>,
    pub outgoing_requests: Vec<FriendRequestView>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessagesResponse {
    pub chat_id: String,
    pub items: Vec<DirectMessageRecord>,
}

pub async fn build_repository_status(store: &PostgresStore) -> Result<RepositoryStatusResponse, String> {
    Ok(RepositoryStatusResponse {
        mode: "postgres-primary".to_string(),
        postgres: store.fetch_counts().await?,
        notes: vec![
            "JSON removed completely. Postgres is the only runtime store.".to_string(),
            "This backend is ready for mailbox, sync cursors and federation-first expansion.".to_string(),
        ],
    })
}

pub async fn build_repository_recent_events(store: &PostgresStore) -> Result<RepositoryRecentEventsResponse, String> {
    Ok(RepositoryRecentEventsResponse {
        items: store.fetch_recent_events(20).await?,
    })
}

pub async fn build_repository_recent_users(store: &PostgresStore) -> Result<RepositoryRecentUsersResponse, String> {
    Ok(RepositoryRecentUsersResponse {
        items: store.fetch_recent_users(20).await?,
    })
}

pub async fn build_user_lookup(store: &PostgresStore, public_id: &str) -> Result<UserLookupResponse, String> {
    let user = store
        .fetch_user_lookup(public_id)
        .await?
        .ok_or_else(|| "Пользователь не найден".to_string())?;
    Ok(UserLookupResponse { user })
}

pub async fn build_friends_response(store: &PostgresStore, public_id: &str) -> Result<FriendsResponse, String> {
    let FriendsBundle {
        public_id,
        friends,
        incoming_requests,
        outgoing_requests,
    } = store.fetch_friends(public_id).await?;

    Ok(FriendsResponse {
        public_id,
        friends,
        incoming_requests,
        outgoing_requests,
    })
}

pub async fn build_chat_messages(store: &PostgresStore, chat_id: &str) -> Result<ChatMessagesResponse, String> {
    Ok(ChatMessagesResponse {
        chat_id: chat_id.to_string(),
        items: store.fetch_chat_messages(chat_id).await?,
    })
}


#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MailboxResponse {
    pub device_id: String,
    pub items: Vec<MailboxItemView>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncCursorsResponse {
    pub device_id: String,
    pub items: Vec<RepositorySyncCursor>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncCursorUpsertResponse {
    pub ok: bool,
    pub item: RepositorySyncCursor,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MailboxAckResponse {
    pub ok: bool,
    pub result: MailboxAckResult,
}

pub async fn build_mailbox_response(store: &PostgresStore, device_id: &str) -> Result<MailboxResponse, String> {
    Ok(MailboxResponse {
        device_id: device_id.to_string(),
        items: store.fetch_mailbox(device_id, 100).await?,
    })
}

pub async fn build_sync_cursors_response(store: &PostgresStore, device_id: &str) -> Result<SyncCursorsResponse, String> {
    Ok(SyncCursorsResponse {
        device_id: device_id.to_string(),
        items: store.fetch_sync_cursors(device_id).await?,
    })
}
