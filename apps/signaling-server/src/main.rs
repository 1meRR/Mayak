mod domain;
mod repository;
mod storage;

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, State,
    },
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use domain::models::{
    CallInviteView, DeviceResponse, DirectMessageRecord, FriendRequestView, FriendUserView,
    MediaObjectView, PublicUserResponse, RecoveryCodeView,
};
use futures::{sink::SinkExt, stream::StreamExt};
use repository::{
    build_chat_messages, build_friends_response, build_mailbox_response,
    build_repository_recent_events, build_repository_recent_users, build_repository_status,
    build_sync_cursors_response, build_user_lookup, ChatMessagesResponse, FriendsResponse,
    MailboxAckResponse, MailboxResponse, RepositoryRecentEventsResponse,
    RepositoryRecentUsersResponse, RepositoryStatusResponse, SyncCursorUpsertResponse,
    SyncCursorsResponse, UserLookupResponse,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{collections::HashMap, net::SocketAddr, sync::Arc};
use storage::postgres_store::{LoginResult, PostgresStore, RegisterResult};
use tokio::sync::{mpsc, RwLock};
use tower_http::cors::CorsLayer;

type Tx = mpsc::UnboundedSender<Message>;

#[derive(Clone)]
struct AppState {
    rooms: Arc<RwLock<HashMap<String, HashMap<String, PeerHandle>>>>,
    admin_token: Arc<Option<String>>,
    store: Arc<PostgresStore>,
}

#[derive(Clone)]
struct PeerHandle {
    tx: Tx,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PeerMeta {
    peer_id: String,
    display_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IceCandidatePayload {
    candidate: Option<String>,
    sdp_mid: Option<String>,
    sdp_m_line_index: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignalMessage {
    #[serde(rename = "type")]
    message_type: String,
    room_id: Option<String>,
    peer_id: Option<String>,
    target_peer_id: Option<String>,
    display_name: Option<String>,
    sdp: Option<String>,
    sdp_type: Option<String>,
    candidate: Option<IceCandidatePayload>,
    text: Option<String>,
    timestamp: Option<i64>,
    peers: Option<Vec<PeerMeta>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HealthResponse {
    status: String,
    service: String,
    users_count: usize,
    rooms_count: usize,
    call_invites_count: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RegisterResponse {
    user: PublicUserResponse,
    device: DeviceResponse,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuthRegisterRequest {
    device_id: String,
    first_name: String,
    last_name: Option<String>,
    phone: String,
    password: String,
    about: Option<String>,
    platform: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuthLoginRequest {
    device_id: String,
    phone: String,
    password: String,
    platform: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResetPasswordRequest {
    phone: String,
    recovery_code: String,
    new_password: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthRegisterResponse {
    user: PublicUserResponse,
    device: DeviceResponse,
    recovery_codes: Vec<RecoveryCodeView>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthLoginResponse {
    user: PublicUserResponse,
    device: DeviceResponse,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct BasicSuccessResponse {
    ok: bool,
    message: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AdminUserView {
    public_id: String,
    display_name: String,
    phone: String,
    created_at: i64,
    updated_at: i64,
    recovery_codes: Vec<RecoveryCodeView>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AdminUsersResponse {
    users: Vec<AdminUserView>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PresenceHeartbeatRequest {
    public_id: String,
    device_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PresenceHeartbeatResponse {
    public_id: String,
    device_id: String,
    last_seen_at: i64,
    is_online: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FriendRequestCreateRequest {
    from_public_id: String,
    to_public_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FriendRespondRequest {
    request_id: String,
    actor_public_id: String,
    action: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SendMessageRequest {
    from_public_id: String,
    to_public_id: String,
    text: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SendMessageResponse {
    chat_id: String,
    message: DirectMessageRecord,
}


#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MediaUploadRequest {
    owner_public_id: String,
    owner_device_id: String,
    media_kind: String,
    content_type: String,
    file_name: String,
    base64_data: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MediaUploadResponse {
    media: MediaObjectView,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SendMediaMessageRequest {
    from_public_id: String,
    to_public_id: String,
    media_id: String,
    text: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SendMediaMessageResponse {
    chat_id: String,
    event_id: String,
    media_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MailboxAckRequest {
    mailbox_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncCursorUpsertRequest {
    stream_key: String,
    cursor_value: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateCallInviteRequest {
    caller_public_id: String,
    callee_public_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RespondCallInviteRequest {
    invite_id: String,
    actor_public_id: String,
    action: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CallInvitesResponse {
    public_id: String,
    items: Vec<CallInviteView>,
}

#[derive(Debug)]
enum ApiError {
    BadRequest(String),
    NotFound(String),
    Conflict(String),
    Internal(String),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            Self::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            Self::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
            Self::Conflict(msg) => (StatusCode::CONFLICT, msg),
            Self::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
        };
        let body = Json(json!({ "error": message }));
        (status, body).into_response()
    }
}

#[tokio::main]
async fn main() {
    let bind_addr = std::env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let addr: SocketAddr = bind_addr
        .parse()
        .expect("BIND_ADDR must be in host:port format");

    let admin_token = std::env::var("ADMIN_TOKEN")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty());

    let store = PostgresStore::from_env().await.expect("postgres store init failed");

    let state = AppState {
        rooms: Arc::new(RwLock::new(HashMap::new())),
        admin_token: Arc::new(admin_token),
        store: Arc::new(store),
    };

    let app = Router::new()
        .route("/health", get(health))
        .route("/ws", get(ws_handler))
        .route("/api/auth/register", post(auth_register))
        .route("/api/auth/login", post(auth_login))
        .route("/api/auth/reset-password", post(reset_password_with_code))
        .route("/api/admin/users", get(admin_list_users))
        .route("/api/presence/heartbeat", post(presence_heartbeat))
        .route("/api/users/by-public-id/{public_id}", get(get_user_by_public_id))
        .route("/api/friends/request", post(create_friend_request))
        .route("/api/friends/respond", post(respond_friend_request))
        .route("/api/friends/{public_id}", get(get_friends))
        .route("/api/messages/send", post(send_message))
        .route("/api/messages/send-media", post(send_media_message))
        .route("/api/media/upload", post(upload_media))
        .route("/api/media/file/{media_id}", get(get_media_file))
        .route("/api/mailbox/{device_id}", get(get_mailbox))
        .route("/api/mailbox/{device_id}/ack", post(ack_mailbox))
        .route("/api/sync/{device_id}", get(get_sync_cursors).post(upsert_sync_cursor))
        .route("/api/chats/{chat_id}/messages", get(get_chat_messages))
        .route("/api/calls/invite", post(create_call_invite))
        .route("/api/calls/respond", post(respond_call_invite))
        .route("/api/calls/incoming/{public_id}", get(get_incoming_calls))
        .route("/api/calls/{invite_id}", get(get_call_invite))
        .route("/api/repository/status", get(repository_status))
        .route("/api/repository/recent-events", get(repository_recent_events))
        .route("/api/repository/recent-users", get(repository_recent_users))
        .with_state(state)
        .layer(CorsLayer::permissive());

    println!("Mayak server started on http://{addr}");
    println!("Health check: http://{addr}/health");
    println!("WebSocket endpoint: ws://{addr}/ws");

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("failed to bind listener");

    axum::serve(listener, app)
        .await
        .expect("axum server failed");
}

async fn health(State(state): State<AppState>) -> Result<Json<HealthResponse>, ApiError> {
    let counts = state.store.fetch_health_counts().await.map_err(ApiError::Internal)?;
    let rooms_count = state.rooms.read().await.len();
    Ok(Json(HealthResponse {
        status: "ok".to_string(),
        service: "mayak-server".to_string(),
        users_count: counts.users_count as usize,
        rooms_count,
        call_invites_count: counts.call_invites_count as usize,
    }))
}

async fn auth_register(
    State(state): State<AppState>,
    Json(payload): Json<AuthRegisterRequest>,
) -> Result<Json<AuthRegisterResponse>, ApiError> {
    let RegisterResult { user, device, recovery_codes } = state
        .store
        .register_user(
            &payload.device_id,
            &payload.first_name,
            payload.last_name.as_deref().unwrap_or_default(),
            &payload.phone,
            &payload.password,
            payload.about.as_deref().unwrap_or_default(),
            payload.platform.as_deref().unwrap_or("unknown"),
        )
        .await
        .map_err(ApiError::Conflict)?;

    Ok(Json(AuthRegisterResponse { user, device, recovery_codes }))
}

async fn auth_login(
    State(state): State<AppState>,
    Json(payload): Json<AuthLoginRequest>,
) -> Result<Json<AuthLoginResponse>, ApiError> {
    let LoginResult { user, device } = state
        .store
        .login_user(
            &payload.device_id,
            &payload.phone,
            &payload.password,
            payload.platform.as_deref().unwrap_or("unknown"),
        )
        .await
        .map_err(ApiError::Conflict)?;

    Ok(Json(AuthLoginResponse { user, device }))
}

async fn reset_password_with_code(
    State(state): State<AppState>,
    Json(payload): Json<ResetPasswordRequest>,
) -> Result<Json<BasicSuccessResponse>, ApiError> {
    state
        .store
        .reset_password(&payload.phone, &payload.recovery_code, &payload.new_password)
        .await
        .map_err(ApiError::Conflict)?;

    Ok(Json(BasicSuccessResponse {
        ok: true,
        message: "Пароль обновлён".to_string(),
    }))
}

async fn admin_list_users(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AdminUsersResponse>, ApiError> {
    require_admin(&state, &headers)?;
    let rows = state.store.list_admin_users().await.map_err(ApiError::Internal)?;
    let users = rows
        .into_iter()
        .map(|(user, recovery_codes)| AdminUserView {
            public_id: user.public_id,
            display_name: user.display_name,
            phone: user.phone,
            created_at: user.created_at,
            updated_at: user.updated_at,
            recovery_codes,
        })
        .collect();
    Ok(Json(AdminUsersResponse { users }))
}

async fn presence_heartbeat(
    State(state): State<AppState>,
    Json(payload): Json<PresenceHeartbeatRequest>,
) -> Result<Json<PresenceHeartbeatResponse>, ApiError> {
    let (public_id, device_id, last_seen_at, is_online) = state
        .store
        .heartbeat(&payload.public_id, &payload.device_id)
        .await
        .map_err(ApiError::Conflict)?;
    Ok(Json(PresenceHeartbeatResponse { public_id, device_id, last_seen_at, is_online }))
}

async fn get_user_by_public_id(
    Path(public_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<UserLookupResponse>, ApiError> {
    let response = build_user_lookup(&state.store, &public_id)
        .await
        .map_err(ApiError::NotFound)?;
    Ok(Json(response))
}

async fn create_friend_request(
    State(state): State<AppState>,
    Json(payload): Json<FriendRequestCreateRequest>,
) -> Result<Json<FriendRequestView>, ApiError> {
    let view = state
        .store
        .create_friend_request(&payload.from_public_id, &payload.to_public_id)
        .await
        .map_err(ApiError::Conflict)?;
    Ok(Json(view))
}

async fn respond_friend_request(
    State(state): State<AppState>,
    Json(payload): Json<FriendRespondRequest>,
) -> Result<Json<FriendRequestView>, ApiError> {
    let view = state
        .store
        .respond_friend_request(&payload.request_id, &payload.actor_public_id, &payload.action)
        .await
        .map_err(ApiError::Conflict)?;
    Ok(Json(view))
}

async fn get_friends(
    Path(public_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<FriendsResponse>, ApiError> {
    let response = build_friends_response(&state.store, &public_id)
        .await
        .map_err(ApiError::NotFound)?;
    Ok(Json(response))
}

async fn send_message(
    State(state): State<AppState>,
    Json(payload): Json<SendMessageRequest>,
) -> Result<Json<SendMessageResponse>, ApiError> {
    let (chat_id, message) = state
        .store
        .send_direct_message(&payload.from_public_id, &payload.to_public_id, &payload.text)
        .await
        .map_err(ApiError::Conflict)?;
    Ok(Json(SendMessageResponse { chat_id, message }))
}

async fn get_chat_messages(
    Path(chat_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ChatMessagesResponse>, ApiError> {
    let response = build_chat_messages(&state.store, &chat_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(response))
}


async fn upload_media(
    State(state): State<AppState>,
    Json(payload): Json<MediaUploadRequest>,
) -> Result<Json<MediaUploadResponse>, ApiError> {
    let media = state
        .store
        .upload_media(
            &payload.owner_public_id,
            &payload.owner_device_id,
            &payload.media_kind,
            &payload.content_type,
            &payload.file_name,
            &payload.base64_data,
        )
        .await
        .map_err(ApiError::Conflict)?;
    Ok(Json(MediaUploadResponse { media }))
}

async fn get_media_file(
    Path(media_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let file = state
        .store
        .read_media_file(&media_id)
        .await
        .map_err(ApiError::NotFound)?;

    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(&file.content_type)
            .map_err(|e| ApiError::Internal(format!("Некорректный content-type: {e}")))?,
    );
    headers.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_str(&format!("inline; filename=\"{}\"", sanitize_header_value(&file.file_name)))
            .map_err(|e| ApiError::Internal(format!("Некорректный fileName: {e}")))?,
    );

    Ok((headers, file.bytes).into_response())
}

async fn send_media_message(
    State(state): State<AppState>,
    Json(payload): Json<SendMediaMessageRequest>,
) -> Result<Json<SendMediaMessageResponse>, ApiError> {
    let text = payload.text.as_deref().unwrap_or_default();
    let (chat_id, event_id) = state
        .store
        .send_media_message(&payload.from_public_id, &payload.to_public_id, &payload.media_id, text)
        .await
        .map_err(ApiError::Conflict)?;
    Ok(Json(SendMediaMessageResponse {
        chat_id,
        event_id,
        media_id: payload.media_id,
    }))
}

async fn get_mailbox(
    Path(device_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<MailboxResponse>, ApiError> {
    let response = build_mailbox_response(&state.store, &device_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(response))
}

async fn ack_mailbox(
    Path(device_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<MailboxAckRequest>,
) -> Result<Json<MailboxAckResponse>, ApiError> {
    let result = state
        .store
        .ack_mailbox(&device_id, &payload.mailbox_ids)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(MailboxAckResponse { ok: true, result }))
}

async fn get_sync_cursors(
    Path(device_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<SyncCursorsResponse>, ApiError> {
    let response = build_sync_cursors_response(&state.store, &device_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(response))
}

async fn upsert_sync_cursor(
    Path(device_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<SyncCursorUpsertRequest>,
) -> Result<Json<SyncCursorUpsertResponse>, ApiError> {
    let item = state
        .store
        .upsert_sync_cursor(&device_id, &payload.stream_key, &payload.cursor_value)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(SyncCursorUpsertResponse { ok: true, item }))
}

async fn create_call_invite(
    State(state): State<AppState>,
    Json(payload): Json<CreateCallInviteRequest>,
) -> Result<Json<CallInviteView>, ApiError> {
    let view = state
        .store
        .create_call_invite(&payload.caller_public_id, &payload.callee_public_id)
        .await
        .map_err(ApiError::Conflict)?;
    Ok(Json(view))
}

async fn respond_call_invite(
    State(state): State<AppState>,
    Json(payload): Json<RespondCallInviteRequest>,
) -> Result<Json<CallInviteView>, ApiError> {
    let view = state
        .store
        .respond_call_invite(&payload.invite_id, &payload.actor_public_id, &payload.action)
        .await
        .map_err(ApiError::Conflict)?;
    Ok(Json(view))
}

async fn get_incoming_calls(
    Path(public_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<CallInvitesResponse>, ApiError> {
    let items = state
        .store
        .fetch_incoming_calls(&public_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(CallInvitesResponse { public_id, items }))
}

async fn get_call_invite(
    Path(invite_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<CallInviteView>, ApiError> {
    let view = state
        .store
        .fetch_call_invite(&invite_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound("Приглашение не найдено".to_string()))?;
    Ok(Json(view))
}

async fn repository_status(
    State(state): State<AppState>,
) -> Result<Json<RepositoryStatusResponse>, ApiError> {
    let response = build_repository_status(&state.store)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(response))
}

async fn repository_recent_events(
    State(state): State<AppState>,
) -> Result<Json<RepositoryRecentEventsResponse>, ApiError> {
    let response = build_repository_recent_events(&state.store)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(response))
}

async fn repository_recent_users(
    State(state): State<AppState>,
) -> Result<Json<RepositoryRecentUsersResponse>, ApiError> {
    let response = build_repository_recent_users(&state.store)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(response))
}

async fn ws_handler(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| websocket_session(socket, state))
}

async fn websocket_session(stream: WebSocket, state: AppState) {
    let (mut sender, mut receiver) = stream.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    let writer = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            if sender.send(message).await.is_err() {
                break;
            }
        }
    });

    let mut current_room_id: Option<String> = None;
    let mut current_peer_id: Option<String> = None;

    while let Some(Ok(message)) = receiver.next().await {
        match message {
            Message::Text(text) => {
                let Ok(signal) = serde_json::from_str::<SignalMessage>(&text) else {
                    continue;
                };

                match signal.message_type.as_str() {
                    "join" => {
                        let Some(room_id) = signal.room_id.clone() else { continue; };
                        let Some(peer_id) = signal.peer_id.clone() else { continue; };

                        let peers = {
                            let mut rooms = state.rooms.write().await;
                            let room = rooms.entry(room_id.clone()).or_default();
                            room.insert(peer_id.clone(), PeerHandle { tx: tx.clone() });
                            room.keys().cloned().collect::<Vec<_>>()
                        };

                        current_room_id = Some(room_id.clone());
                        current_peer_id = Some(peer_id.clone());

                        let peer_list = peers
                            .into_iter()
                            .map(|id| PeerMeta {
                                display_name: id.clone(),
                                peer_id: id,
                            })
                            .collect::<Vec<_>>();

                        let joined_message = SignalMessage {
                            message_type: "peers".to_string(),
                            room_id: Some(room_id),
                            peer_id: Some(peer_id),
                            target_peer_id: None,
                            display_name: None,
                            sdp: None,
                            sdp_type: None,
                            candidate: None,
                            text: None,
                            timestamp: Some(now_ts()),
                            peers: Some(peer_list),
                        };

                        send_to_one(&tx, &joined_message);
                    }
                    "offer" | "answer" | "ice_candidate" => {
                        let Some(room_id) = signal.room_id.clone() else { continue; };
                        let Some(target_peer_id) = signal.target_peer_id.clone() else { continue; };
                        let target = {
                            let rooms = state.rooms.read().await;
                            rooms.get(&room_id).and_then(|room| room.get(&target_peer_id)).map(|peer| peer.tx.clone())
                        };
                        if let Some(target) = target { send_to_one(&target, &signal); }
                    }
                    "chat" => {
                        let Some(room_id) = signal.room_id.clone() else { continue; };
                        let Some(sender_peer_id) = signal.peer_id.clone() else { continue; };
                        let receivers = {
                            let rooms = state.rooms.read().await;
                            rooms.get(&room_id)
                                .map(|room| room.iter().filter(|(id, _)| *id != &sender_peer_id).map(|(_, p)| p.tx.clone()).collect::<Vec<_>>())
                                .unwrap_or_default()
                        };
                        broadcast(receivers, &signal);
                    }
                    "leave" => {
                        if let (Some(room_id), Some(peer_id)) = (signal.room_id.clone(), signal.peer_id.clone()) {
                            disconnect_peer(&state, room_id, peer_id).await;
                        }
                    }
                    _ => {}
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    if let (Some(room_id), Some(peer_id)) = (current_room_id, current_peer_id) {
        disconnect_peer(&state, room_id, peer_id).await;
    }

    writer.abort();
}

async fn disconnect_peer(state: &AppState, room_id: String, peer_id: String) {
    let receivers = {
        let mut rooms = state.rooms.write().await;
        let Some(room) = rooms.get_mut(&room_id) else { return; };
        room.remove(&peer_id);
        let receivers = room.values().map(|peer| peer.tx.clone()).collect::<Vec<_>>();
        if room.is_empty() { rooms.remove(&room_id); }
        receivers
    };

    let left_message = SignalMessage {
        message_type: "peer_left".to_string(),
        room_id: Some(room_id),
        peer_id: Some(peer_id),
        target_peer_id: None,
        display_name: None,
        sdp: None,
        sdp_type: None,
        candidate: None,
        text: None,
        timestamp: Some(now_ts()),
        peers: None,
    };

    broadcast(receivers, &left_message);
}

fn send_to_one(target: &Tx, message: &SignalMessage) {
    if let Ok(text) = serde_json::to_string(message) {
        let _ = target.send(Message::Text(text.into()));
    }
}

fn broadcast(targets: Vec<Tx>, message: &SignalMessage) {
    if let Ok(text) = serde_json::to_string(message) {
        for target in targets {
            let _ = target.send(Message::Text(text.clone().into()));
        }
    }
}

fn require_admin(state: &AppState, headers: &HeaderMap) -> Result<(), ApiError> {
    let expected = state
        .admin_token
        .as_ref()
        .as_ref()
        .ok_or_else(|| ApiError::NotFound("ADMIN_TOKEN не настроен на сервере".to_string()))?;
    let actual = headers
        .get("x-admin-token")
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ApiError::BadRequest("Нужен заголовок x-admin-token".to_string()))?;
    if actual != expected {
        return Err(ApiError::Conflict("Неверный admin token".to_string()));
    }
    Ok(())
}

fn sanitize_header_value(value: &str) -> String {
    value.chars()
        .map(|ch| if ch == "\\".chars().next().unwrap() || ch == "\r".chars().next().unwrap() || ch == "\n".chars().next().unwrap() { "_".chars().next().unwrap() } else { ch })
        .collect()
}

fn now_ts() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or_default()
}
