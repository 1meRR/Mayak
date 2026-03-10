use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, State,
    },
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use futures::{sink::SinkExt, stream::StreamExt};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::HashMap,
    net::SocketAddr,
    path::PathBuf,
    sync::Arc,
};
use tokio::sync::{mpsc, RwLock};
use tower_http::cors::CorsLayer;

type Tx = mpsc::UnboundedSender<Message>;

const PRESENCE_ONLINE_WINDOW_MS: i64 = 20_000;
const CALL_INVITE_TTL_MS: i64 = 45_000;

#[derive(Clone)]
struct AppState {
    rooms: Arc<RwLock<HashMap<String, HashMap<String, PeerHandle>>>>,
    db: Arc<RwLock<AppDb>>,
    data_file: Arc<PathBuf>,
}

#[derive(Clone)]
struct PeerHandle {
    display_name: String,
    tx: Tx,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct AppDb {
    users: HashMap<String, UserRecord>,
    devices: HashMap<String, DeviceRecord>,
    presences: HashMap<String, PresenceRecord>,
    friend_requests: HashMap<String, FriendRequestRecord>,
    friendships: Vec<FriendshipRecord>,
    messages: HashMap<String, Vec<DirectMessageRecord>>,
    call_invites: HashMap<String, CallInviteRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UserRecord {
    public_id: String,
    first_name: String,
    last_name: String,
    phone: String,
    about: String,
    created_at: i64,
    updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceRecord {
    device_id: String,
    owner_public_id: String,
    platform: String,
    created_at: i64,
    updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PresenceRecord {
    device_id: String,
    owner_public_id: String,
    last_seen_at: i64,
    updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FriendRequestRecord {
    id: String,
    from_public_id: String,
    to_public_id: String,
    status: String,
    created_at: i64,
    responded_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FriendshipRecord {
    user_a_public_id: String,
    user_b_public_id: String,
    created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DirectMessageRecord {
    id: String,
    chat_id: String,
    from_public_id: String,
    to_public_id: String,
    text: String,
    created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CallInviteRecord {
    id: String,
    caller_public_id: String,
    caller_display_name: String,
    callee_public_id: String,
    callee_display_name: String,
    room_id: String,
    status: String,
    created_at: i64,
    responded_at: Option<i64>,
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RegisterRequest {
    public_id: String,
    device_id: String,
    first_name: String,
    last_name: Option<String>,
    phone: Option<String>,
    about: Option<String>,
    platform: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublicUserResponse {
    public_id: String,
    display_name: String,
    first_name: String,
    last_name: String,
    phone: String,
    about: String,
    created_at: i64,
    updated_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceResponse {
    device_id: String,
    owner_public_id: String,
    platform: String,
    created_at: i64,
    updated_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RegisterResponse {
    user: PublicUserResponse,
    device: DeviceResponse,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UserLookupResponse {
    user: PublicUserResponse,
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

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FriendRequestView {
    id: String,
    from_public_id: String,
    from_display_name: String,
    to_public_id: String,
    to_display_name: String,
    status: String,
    created_at: i64,
    responded_at: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FriendUserView {
    public_id: String,
    display_name: String,
    about: String,
    is_online: bool,
    last_seen_at: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FriendsResponse {
    public_id: String,
    friends: Vec<FriendUserView>,
    incoming_requests: Vec<FriendRequestView>,
    outgoing_requests: Vec<FriendRequestView>,
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

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatMessagesResponse {
    chat_id: String,
    items: Vec<DirectMessageRecord>,
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
struct CallInviteView {
    id: String,
    caller_public_id: String,
    caller_display_name: String,
    callee_public_id: String,
    callee_display_name: String,
    room_id: String,
    status: String,
    created_at: i64,
    responded_at: Option<i64>,
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

        let body = Json(json!({
            "error": message,
        }));

        (status, body).into_response()
    }
}

#[tokio::main]
async fn main() {
    let bind_addr = std::env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let addr: SocketAddr = bind_addr
        .parse()
        .expect("BIND_ADDR must be in host:port format");

    let data_file = std::env::var("DATA_FILE").unwrap_or_else(|_| "./data/state.json".to_string());
    let data_file = PathBuf::from(data_file);

    let db = load_db(&data_file).await;

    let state = AppState {
        rooms: Arc::new(RwLock::new(HashMap::new())),
        db: Arc::new(RwLock::new(db)),
        data_file: Arc::new(data_file),
    };

    let app = Router::new()
        .route("/health", get(health))
        .route("/ws", get(ws_handler))
        .route("/api/register", post(register_user))
        .route("/api/presence/heartbeat", post(presence_heartbeat))
        .route("/api/users/by-public-id/{public_id}", get(get_user_by_public_id))
        .route("/api/friends/request", post(create_friend_request))
        .route("/api/friends/respond", post(respond_friend_request))
        .route("/api/friends/{public_id}", get(get_friends))
        .route("/api/messages/send", post(send_message))
        .route("/api/chats/{chat_id}/messages", get(get_chat_messages))
        .route("/api/calls/invite", post(create_call_invite))
        .route("/api/calls/respond", post(respond_call_invite))
        .route("/api/calls/incoming/{public_id}", get(get_incoming_calls))
        .route("/api/calls/{invite_id}", get(get_call_invite))
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

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    let users_count = state.db.read().await.users.len();
    let call_invites_count = state.db.read().await.call_invites.len();
    let rooms_count = state.rooms.read().await.len();

    Json(HealthResponse {
        status: "ok".to_string(),
        service: "mayak-server".to_string(),
        users_count,
        rooms_count,
        call_invites_count,
    })
}

async fn register_user(
    State(state): State<AppState>,
    Json(payload): Json<RegisterRequest>,
) -> Result<Json<RegisterResponse>, ApiError> {
    let public_id = normalize_id(&payload.public_id);
    let device_id = normalize_id(&payload.device_id);
    let first_name = payload.first_name.trim().to_string();
    let last_name = payload.last_name.unwrap_or_default().trim().to_string();
    let phone = payload.phone.unwrap_or_default().trim().to_string();
    let about = payload.about.unwrap_or_default().trim().to_string();
    let platform = payload.platform.unwrap_or_else(|| "unknown".to_string());
    let now = now_ts();

    if public_id.is_empty() {
        return Err(ApiError::BadRequest("publicId обязателен".to_string()));
    }
    if device_id.is_empty() {
        return Err(ApiError::BadRequest("deviceId обязателен".to_string()));
    }
    if first_name.is_empty() {
        return Err(ApiError::BadRequest("firstName обязателен".to_string()));
    }

    let response = {
        let mut db = state.db.write().await;

        if let Some(existing_device) = db.devices.get(&device_id) {
            if existing_device.owner_public_id != public_id {
                return Err(ApiError::Conflict(
                    "Этот deviceId уже привязан к другому пользователю".to_string(),
                ));
            }
        }

        let user_snapshot = {
            let user_entry = db.users.entry(public_id.clone()).or_insert(UserRecord {
                public_id: public_id.clone(),
                first_name: first_name.clone(),
                last_name: last_name.clone(),
                phone: phone.clone(),
                about: about.clone(),
                created_at: now,
                updated_at: now,
            });

            user_entry.first_name = first_name.clone();
            user_entry.last_name = last_name.clone();
            user_entry.phone = phone.clone();
            user_entry.about = about.clone();
            user_entry.updated_at = now;

            user_entry.clone()
        };

        let device_snapshot = {
            let device_entry = db.devices.entry(device_id.clone()).or_insert(DeviceRecord {
                device_id: device_id.clone(),
                owner_public_id: public_id.clone(),
                platform: platform.clone(),
                created_at: now,
                updated_at: now,
            });

            device_entry.owner_public_id = public_id.clone();
            device_entry.platform = platform.clone();
            device_entry.updated_at = now;

            device_entry.clone()
        };

        db.presences.insert(
            device_id.clone(),
            PresenceRecord {
                device_id: device_id.clone(),
                owner_public_id: public_id.clone(),
                last_seen_at: now,
                updated_at: now,
            },
        );

        RegisterResponse {
            user: to_public_user(&user_snapshot),
            device: to_device_response(&device_snapshot),
        }
    };

    persist_db(&state).await?;
    Ok(Json(response))
}

async fn presence_heartbeat(
    State(state): State<AppState>,
    Json(payload): Json<PresenceHeartbeatRequest>,
) -> Result<Json<PresenceHeartbeatResponse>, ApiError> {
    let public_id = normalize_id(&payload.public_id);
    let device_id = normalize_id(&payload.device_id);
    let now = now_ts();

    if public_id.is_empty() || device_id.is_empty() {
        return Err(ApiError::BadRequest("publicId и deviceId обязательны".to_string()));
    }

    let response = {
        let mut db = state.db.write().await;

        if !db.users.contains_key(&public_id) {
            return Err(ApiError::NotFound("Пользователь не найден".to_string()));
        }

        let device_entry = db.devices.entry(device_id.clone()).or_insert(DeviceRecord {
            device_id: device_id.clone(),
            owner_public_id: public_id.clone(),
            platform: "unknown".to_string(),
            created_at: now,
            updated_at: now,
        });

        device_entry.owner_public_id = public_id.clone();
        device_entry.updated_at = now;

        db.presences.insert(
            device_id.clone(),
            PresenceRecord {
                device_id: device_id.clone(),
                owner_public_id: public_id.clone(),
                last_seen_at: now,
                updated_at: now,
            },
        );

        PresenceHeartbeatResponse {
            public_id,
            device_id,
            last_seen_at: now,
            is_online: true,
        }
    };

    persist_db(&state).await?;
    Ok(Json(response))
}

async fn get_user_by_public_id(
    Path(public_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<UserLookupResponse>, ApiError> {
    let public_id = normalize_id(&public_id);

    let response = {
        let db = state.db.read().await;
        let user = db
            .users
            .get(&public_id)
            .ok_or_else(|| ApiError::NotFound("Пользователь не найден".to_string()))?;

        UserLookupResponse {
            user: to_public_user(user),
        }
    };

    Ok(Json(response))
}

async fn create_friend_request(
    State(state): State<AppState>,
    Json(payload): Json<FriendRequestCreateRequest>,
) -> Result<Json<FriendRequestView>, ApiError> {
    let from_public_id = normalize_id(&payload.from_public_id);
    let to_public_id = normalize_id(&payload.to_public_id);

    if from_public_id.is_empty() || to_public_id.is_empty() {
        return Err(ApiError::BadRequest("fromPublicId и toPublicId обязательны".to_string()));
    }
    if from_public_id == to_public_id {
        return Err(ApiError::BadRequest("Нельзя добавить самого себя".to_string()));
    }

    let response = {
        let mut db = state.db.write().await;

        if !db.users.contains_key(&from_public_id) {
            return Err(ApiError::NotFound("Отправитель не найден".to_string()));
        }
        if !db.users.contains_key(&to_public_id) {
            return Err(ApiError::NotFound("Получатель не найден".to_string()));
        }

        if are_friends(&db.friendships, &from_public_id, &to_public_id) {
            return Err(ApiError::Conflict("Пользователи уже в друзьях".to_string()));
        }

        let already_pending = db.friend_requests.values().any(|item| {
            item.status == "pending"
                && ((item.from_public_id == from_public_id && item.to_public_id == to_public_id)
                    || (item.from_public_id == to_public_id
                        && item.to_public_id == from_public_id))
        });

        if already_pending {
            return Err(ApiError::Conflict("Заявка уже существует".to_string()));
        }

        let now = now_ts();
        let request_id = generate_entity_id("FR");
        let record = FriendRequestRecord {
            id: request_id.clone(),
            from_public_id: from_public_id.clone(),
            to_public_id: to_public_id.clone(),
            status: "pending".to_string(),
            created_at: now,
            responded_at: None,
        };

        db.friend_requests.insert(request_id.clone(), record.clone());

        to_friend_request_view(&db, &record)
    };

    persist_db(&state).await?;
    Ok(Json(response))
}

async fn respond_friend_request(
    State(state): State<AppState>,
    Json(payload): Json<FriendRespondRequest>,
) -> Result<Json<FriendRequestView>, ApiError> {
    let request_id = payload.request_id.trim().to_string();
    let actor_public_id = normalize_id(&payload.actor_public_id);
    let action = payload.action.trim().to_lowercase();

    if request_id.is_empty() {
        return Err(ApiError::BadRequest("requestId обязателен".to_string()));
    }
    if actor_public_id.is_empty() {
        return Err(ApiError::BadRequest("actorPublicId обязателен".to_string()));
    }
    if action != "accept" && action != "reject" {
        return Err(ApiError::BadRequest("action должен быть accept или reject".to_string()));
    }

    let response = {
        let mut db = state.db.write().await;

        let snapshot = db
            .friend_requests
            .get(&request_id)
            .cloned()
            .ok_or_else(|| ApiError::NotFound("Заявка не найдена".to_string()))?;

        if snapshot.status != "pending" {
            return Err(ApiError::Conflict("Заявка уже обработана".to_string()));
        }

        if snapshot.to_public_id != actor_public_id {
            return Err(ApiError::Conflict(
                "Только получатель заявки может её обработать".to_string(),
            ));
        }

        let now = now_ts();

        if action == "accept"
            && !are_friends(
                &db.friendships,
                &snapshot.from_public_id,
                &snapshot.to_public_id,
            )
        {
            let (user_a_public_id, user_b_public_id) =
                sort_two_ids(&snapshot.from_public_id, &snapshot.to_public_id);

            db.friendships.push(FriendshipRecord {
                user_a_public_id,
                user_b_public_id,
                created_at: now,
            });
        }

        let item_snapshot = {
            let item = db
                .friend_requests
                .get_mut(&request_id)
                .ok_or_else(|| ApiError::NotFound("Заявка не найдена".to_string()))?;

            item.status = if action == "accept" {
                "accepted".to_string()
            } else {
                "rejected".to_string()
            };
            item.responded_at = Some(now);

            item.clone()
        };

        to_friend_request_view(&db, &item_snapshot)
    };

    persist_db(&state).await?;
    Ok(Json(response))
}

async fn get_friends(
    Path(public_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<FriendsResponse>, ApiError> {
    let public_id = normalize_id(&public_id);

    let response = {
        let db = state.db.read().await;

        if !db.users.contains_key(&public_id) {
            return Err(ApiError::NotFound("Пользователь не найден".to_string()));
        }

        let friends = collect_friends(&db, &public_id);
        let incoming_requests = db
            .friend_requests
            .values()
            .filter(|item| item.to_public_id == public_id && item.status == "pending")
            .map(|item| to_friend_request_view(&db, item))
            .collect::<Vec<_>>();

        let outgoing_requests = db
            .friend_requests
            .values()
            .filter(|item| item.from_public_id == public_id && item.status == "pending")
            .map(|item| to_friend_request_view(&db, item))
            .collect::<Vec<_>>();

        FriendsResponse {
            public_id,
            friends,
            incoming_requests,
            outgoing_requests,
        }
    };

    Ok(Json(response))
}

async fn send_message(
    State(state): State<AppState>,
    Json(payload): Json<SendMessageRequest>,
) -> Result<Json<SendMessageResponse>, ApiError> {
    let from_public_id = normalize_id(&payload.from_public_id);
    let to_public_id = normalize_id(&payload.to_public_id);
    let text = payload.text.trim().to_string();

    if from_public_id.is_empty() || to_public_id.is_empty() {
        return Err(ApiError::BadRequest("fromPublicId и toPublicId обязательны".to_string()));
    }
    if text.is_empty() {
        return Err(ApiError::BadRequest("text обязателен".to_string()));
    }

    let response = {
        let mut db = state.db.write().await;

        if !db.users.contains_key(&from_public_id) {
            return Err(ApiError::NotFound("Отправитель не найден".to_string()));
        }
        if !db.users.contains_key(&to_public_id) {
            return Err(ApiError::NotFound("Получатель не найден".to_string()));
        }

        if from_public_id != to_public_id
            && !are_friends(&db.friendships, &from_public_id, &to_public_id)
        {
            return Err(ApiError::Conflict(
                "Сообщения доступны только друзьям".to_string(),
            ));
        }

        let chat_id = build_direct_chat_id(&from_public_id, &to_public_id);
        let record = DirectMessageRecord {
            id: generate_entity_id("MSG"),
            chat_id: chat_id.clone(),
            from_public_id: from_public_id.clone(),
            to_public_id: to_public_id.clone(),
            text,
            created_at: now_ts(),
        };

        db.messages
            .entry(chat_id.clone())
            .or_default()
            .push(record.clone());

        SendMessageResponse {
            chat_id,
            message: record,
        }
    };

    persist_db(&state).await?;
    Ok(Json(response))
}

async fn get_chat_messages(
    Path(chat_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ChatMessagesResponse>, ApiError> {
    let response = {
        let db = state.db.read().await;
        let items = db.messages.get(&chat_id).cloned().unwrap_or_default();

        ChatMessagesResponse { chat_id, items }
    };

    Ok(Json(response))
}

async fn create_call_invite(
    State(state): State<AppState>,
    Json(payload): Json<CreateCallInviteRequest>,
) -> Result<Json<CallInviteView>, ApiError> {
    let caller_public_id = normalize_id(&payload.caller_public_id);
    let callee_public_id = normalize_id(&payload.callee_public_id);

    if caller_public_id.is_empty() || callee_public_id.is_empty() {
        return Err(ApiError::BadRequest(
            "callerPublicId и calleePublicId обязательны".to_string(),
        ));
    }
    if caller_public_id == callee_public_id {
        return Err(ApiError::BadRequest("Нельзя звонить самому себе".to_string()));
    }

    let response = {
        let mut db = state.db.write().await;
        expire_stale_call_invites(&mut db);

        let caller = db
            .users
            .get(&caller_public_id)
            .cloned()
            .ok_or_else(|| ApiError::NotFound("Звонящий не найден".to_string()))?;
        let callee = db
            .users
            .get(&callee_public_id)
            .cloned()
            .ok_or_else(|| ApiError::NotFound("Получатель звонка не найден".to_string()))?;

        if !are_friends(&db.friendships, &caller_public_id, &callee_public_id) {
            return Err(ApiError::Conflict(
                "Звонок доступен только друзьям".to_string(),
            ));
        }

        let has_pending = db.call_invites.values().any(|item| {
            item.status == "pending"
                && ((item.caller_public_id == caller_public_id
                    && item.callee_public_id == callee_public_id)
                    || (item.caller_public_id == callee_public_id
                        && item.callee_public_id == caller_public_id))
        });

        if has_pending {
            return Err(ApiError::Conflict(
                "Уже есть активный звонок или приглашение".to_string(),
            ));
        }

        let record = CallInviteRecord {
            id: generate_entity_id("CALL"),
            caller_public_id: caller_public_id.clone(),
            caller_display_name: display_name_of(&caller),
            callee_public_id: callee_public_id.clone(),
            callee_display_name: display_name_of(&callee),
            room_id: build_direct_room_id(&caller_public_id, &callee_public_id),
            status: "pending".to_string(),
            created_at: now_ts(),
            responded_at: None,
        };

        let snapshot = record.clone();
        db.call_invites.insert(record.id.clone(), record);

        to_call_invite_view(&snapshot)
    };

    persist_db(&state).await?;
    Ok(Json(response))
}

async fn respond_call_invite(
    State(state): State<AppState>,
    Json(payload): Json<RespondCallInviteRequest>,
) -> Result<Json<CallInviteView>, ApiError> {
    let invite_id = payload.invite_id.trim().to_string();
    let actor_public_id = normalize_id(&payload.actor_public_id);
    let action = payload.action.trim().to_lowercase();

    if invite_id.is_empty() {
        return Err(ApiError::BadRequest("inviteId обязателен".to_string()));
    }
    if actor_public_id.is_empty() {
        return Err(ApiError::BadRequest("actorPublicId обязателен".to_string()));
    }
    if action != "accept" && action != "reject" {
        return Err(ApiError::BadRequest(
            "action должен быть accept или reject".to_string(),
        ));
    }

    let response = {
        let mut db = state.db.write().await;
        expire_stale_call_invites(&mut db);

        let snapshot = db
            .call_invites
            .get(&invite_id)
            .cloned()
            .ok_or_else(|| ApiError::NotFound("Приглашение не найдено".to_string()))?;

        if snapshot.status != "pending" {
            return Err(ApiError::Conflict(
                "Приглашение уже обработано".to_string(),
            ));
        }

        if snapshot.callee_public_id != actor_public_id {
            return Err(ApiError::Conflict(
                "Только вызываемый пользователь может ответить".to_string(),
            ));
        }

        let updated = {
            let item = db
                .call_invites
                .get_mut(&invite_id)
                .ok_or_else(|| ApiError::NotFound("Приглашение не найдено".to_string()))?;

            item.status = if action == "accept" {
                "accepted".to_string()
            } else {
                "rejected".to_string()
            };
            item.responded_at = Some(now_ts());

            item.clone()
        };

        to_call_invite_view(&updated)
    };

    persist_db(&state).await?;
    Ok(Json(response))
}

async fn get_incoming_calls(
    Path(public_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<CallInvitesResponse>, ApiError> {
    let public_id = normalize_id(&public_id);

    let response = {
        let mut db = state.db.write().await;
        expire_stale_call_invites(&mut db);

        let items = db
            .call_invites
            .values()
            .filter(|item| item.callee_public_id == public_id && item.status == "pending")
            .cloned()
            .map(|item| to_call_invite_view(&item))
            .collect::<Vec<_>>();

        CallInvitesResponse { public_id, items }
    };

    persist_db(&state).await?;
    Ok(Json(response))
}

async fn get_call_invite(
    Path(invite_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<CallInviteView>, ApiError> {
    let response = {
        let mut db = state.db.write().await;
        expire_stale_call_invites(&mut db);

        let item = db
            .call_invites
            .get(&invite_id)
            .cloned()
            .ok_or_else(|| ApiError::NotFound("Приглашение не найдено".to_string()))?;

        to_call_invite_view(&item)
    };

    persist_db(&state).await?;
    Ok(Json(response))
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut sender, mut receiver) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            if sender.send(message).await.is_err() {
                break;
            }
        }
    });

    let mut current_room_id: Option<String> = None;
    let mut current_peer_id: Option<String> = None;

    while let Some(Ok(message)) = receiver.next().await {
        if let Message::Text(text) = message {
            let parsed = serde_json::from_str::<SignalMessage>(&text);
            let Ok(signal) = parsed else {
                continue;
            };

            match signal.message_type.as_str() {
                "join" => {
                    let Some(room_id) = signal.room_id.clone() else {
                        continue;
                    };
                    let Some(peer_id) = signal.peer_id.clone() else {
                        continue;
                    };
                    let display_name = signal
                        .display_name
                        .clone()
                        .unwrap_or_else(|| "Guest".to_string());

                    current_room_id = Some(room_id.clone());
                    current_peer_id = Some(peer_id.clone());

                    let (existing_peers, receivers_to_notify) = {
                        let mut rooms = state.rooms.write().await;
                        let room = rooms.entry(room_id.clone()).or_default();

                        let existing_peers = room
                            .iter()
                            .map(|(id, peer)| PeerMeta {
                                peer_id: id.clone(),
                                display_name: peer.display_name.clone(),
                            })
                            .collect::<Vec<_>>();

                        room.insert(
                            peer_id.clone(),
                            PeerHandle {
                                display_name: display_name.clone(),
                                tx: tx.clone(),
                            },
                        );

                        let receivers = room
                            .iter()
                            .filter(|(id, _)| *id != &peer_id)
                            .map(|(_, peer)| peer.tx.clone())
                            .collect::<Vec<_>>();

                        (existing_peers, receivers)
                    };

                    let existing_message = SignalMessage {
                        message_type: "existing_peers".to_string(),
                        room_id: Some(room_id.clone()),
                        peer_id: Some(peer_id.clone()),
                        target_peer_id: None,
                        display_name: Some(display_name.clone()),
                        sdp: None,
                        sdp_type: None,
                        candidate: None,
                        text: None,
                        timestamp: Some(now_ts()),
                        peers: Some(existing_peers),
                    };
                    send_to_one(&tx, &existing_message);

                    let joined_message = SignalMessage {
                        message_type: "peer_joined".to_string(),
                        room_id: Some(room_id),
                        peer_id: Some(peer_id),
                        target_peer_id: None,
                        display_name: Some(display_name),
                        sdp: None,
                        sdp_type: None,
                        candidate: None,
                        text: None,
                        timestamp: Some(now_ts()),
                        peers: None,
                    };
                    broadcast(receivers_to_notify, &joined_message);
                }
                "offer" | "answer" | "ice_candidate" => {
                    let Some(room_id) = signal.room_id.clone() else {
                        continue;
                    };
                    let Some(target_peer_id) = signal.target_peer_id.clone() else {
                        continue;
                    };
                    let target = {
                        let rooms = state.rooms.read().await;
                        rooms
                            .get(&room_id)
                            .and_then(|room| room.get(&target_peer_id))
                            .map(|peer| peer.tx.clone())
                    };
                    if let Some(target_tx) = target {
                        send_to_one(&target_tx, &signal);
                    }
                }
                "chat" => {
                    let Some(room_id) = signal.room_id.clone() else {
                        continue;
                    };
                    let Some(sender_peer_id) = signal.peer_id.clone() else {
                        continue;
                    };

                    let receivers = {
                        let rooms = state.rooms.read().await;
                        rooms
                            .get(&room_id)
                            .map(|room| {
                                room.iter()
                                    .filter(|(id, _)| *id != &sender_peer_id)
                                    .map(|(_, peer)| peer.tx.clone())
                                    .collect::<Vec<_>>()
                            })
                            .unwrap_or_default()
                    };

                    broadcast(receivers, &signal);
                }
                "leave" => {
                    if let (Some(room_id), Some(peer_id)) =
                        (signal.room_id.clone(), signal.peer_id.clone())
                    {
                        disconnect_peer(&state, room_id, peer_id).await;
                    }
                }
                _ => {}
            }
        }
    }

    if let (Some(room_id), Some(peer_id)) = (current_room_id, current_peer_id) {
        disconnect_peer(&state, room_id, peer_id).await;
    }
}

async fn disconnect_peer(state: &AppState, room_id: String, peer_id: String) {
    let receivers = {
        let mut rooms = state.rooms.write().await;
        let Some(room) = rooms.get_mut(&room_id) else {
            return;
        };

        room.remove(&peer_id);

        let receivers = room.values().map(|peer| peer.tx.clone()).collect::<Vec<_>>();

        if room.is_empty() {
            rooms.remove(&room_id);
        }

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

fn to_public_user(user: &UserRecord) -> PublicUserResponse {
    PublicUserResponse {
        public_id: user.public_id.clone(),
        display_name: display_name_of(user),
        first_name: user.first_name.clone(),
        last_name: user.last_name.clone(),
        phone: user.phone.clone(),
        about: user.about.clone(),
        created_at: user.created_at,
        updated_at: user.updated_at,
    }
}

fn to_device_response(device: &DeviceRecord) -> DeviceResponse {
    DeviceResponse {
        device_id: device.device_id.clone(),
        owner_public_id: device.owner_public_id.clone(),
        platform: device.platform.clone(),
        created_at: device.created_at,
        updated_at: device.updated_at,
    }
}

fn to_friend_request_view(db: &AppDb, item: &FriendRequestRecord) -> FriendRequestView {
    let from_display_name = db
        .users
        .get(&item.from_public_id)
        .map(display_name_of)
        .unwrap_or_else(|| item.from_public_id.clone());

    let to_display_name = db
        .users
        .get(&item.to_public_id)
        .map(display_name_of)
        .unwrap_or_else(|| item.to_public_id.clone());

    FriendRequestView {
        id: item.id.clone(),
        from_public_id: item.from_public_id.clone(),
        from_display_name,
        to_public_id: item.to_public_id.clone(),
        to_display_name,
        status: item.status.clone(),
        created_at: item.created_at,
        responded_at: item.responded_at,
    }
}

fn to_call_invite_view(item: &CallInviteRecord) -> CallInviteView {
    CallInviteView {
        id: item.id.clone(),
        caller_public_id: item.caller_public_id.clone(),
        caller_display_name: item.caller_display_name.clone(),
        callee_public_id: item.callee_public_id.clone(),
        callee_display_name: item.callee_display_name.clone(),
        room_id: item.room_id.clone(),
        status: item.status.clone(),
        created_at: item.created_at,
        responded_at: item.responded_at,
    }
}

fn collect_friends(db: &AppDb, public_id: &str) -> Vec<FriendUserView> {
    let mut result = Vec::new();

    for item in &db.friendships {
        let other = if item.user_a_public_id == public_id {
            Some(item.user_b_public_id.clone())
        } else if item.user_b_public_id == public_id {
            Some(item.user_a_public_id.clone())
        } else {
            None
        };

        if let Some(other_public_id) = other {
            if let Some(user) = db.users.get(&other_public_id) {
                let (is_online, last_seen_at) = user_presence_info(db, &other_public_id);

                result.push(FriendUserView {
                    public_id: user.public_id.clone(),
                    display_name: display_name_of(user),
                    about: user.about.clone(),
                    is_online,
                    last_seen_at,
                });
            }
        }
    }

    result.sort_by(|a, b| a.display_name.cmp(&b.display_name));
    result
}

fn user_presence_info(db: &AppDb, public_id: &str) -> (bool, Option<i64>) {
    let mut last_seen_at: Option<i64> = None;

    for presence in db.presences.values() {
        if presence.owner_public_id == public_id {
            last_seen_at = match last_seen_at {
                Some(current) => Some(current.max(presence.last_seen_at)),
                None => Some(presence.last_seen_at),
            };
        }
    }

    let now = now_ts();
    let is_online = match last_seen_at {
        Some(value) => now - value <= PRESENCE_ONLINE_WINDOW_MS,
        None => false,
    };

    (is_online, last_seen_at)
}

fn normalize_id(value: &str) -> String {
    value.trim().to_uppercase()
}

fn display_name_of(user: &UserRecord) -> String {
    let full = format!("{} {}", user.first_name.trim(), user.last_name.trim())
        .trim()
        .to_string();

    if full.is_empty() {
        "Пользователь".to_string()
    } else {
        full
    }
}

fn sort_two_ids(a: &str, b: &str) -> (String, String) {
    let mut ids = [a.to_string(), b.to_string()];
    ids.sort();
    (ids[0].clone(), ids[1].clone())
}

fn are_friends(friendships: &[FriendshipRecord], a: &str, b: &str) -> bool {
    let (left, right) = sort_two_ids(a, b);

    friendships.iter().any(|item| {
        item.user_a_public_id == left && item.user_b_public_id == right
    })
}

fn build_direct_chat_id(a: &str, b: &str) -> String {
    let (left, right) = sort_two_ids(a, b);
    format!("{left}__{right}")
}

fn build_direct_room_id(a: &str, b: &str) -> String {
    let chat_id = build_direct_chat_id(a, b);
    format!("dm_{chat_id}")
}

fn expire_stale_call_invites(db: &mut AppDb) {
    let now = now_ts();

    for item in db.call_invites.values_mut() {
        if item.status == "pending" && now - item.created_at > CALL_INVITE_TTL_MS {
            item.status = "expired".to_string();
            item.responded_at = Some(now);
        }
    }
}

fn generate_entity_id(prefix: &str) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::rng();

    let suffix = (0..8)
        .map(|_| {
            let index = rng.random_range(0..ALPHABET.len());
            ALPHABET[index] as char
        })
        .collect::<String>();

    format!("{prefix}-{suffix}")
}

async fn load_db(path: &PathBuf) -> AppDb {
    if let Some(parent) = path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }

    if !path.exists() {
        return AppDb::default();
    }

    match tokio::fs::read_to_string(path).await {
        Ok(content) => serde_json::from_str::<AppDb>(&content).unwrap_or_default(),
        Err(_) => AppDb::default(),
    }
}

async fn persist_db(state: &AppState) -> Result<(), ApiError> {
    let snapshot = { state.db.read().await.clone() };

    if let Some(parent) = state.data_file.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| ApiError::Internal(format!("Не удалось создать data dir: {e}")))?;
    }

    let payload = serde_json::to_string_pretty(&snapshot)
        .map_err(|e| ApiError::Internal(format!("Не удалось сериализовать БД: {e}")))?;

    tokio::fs::write(&*state.data_file, payload)
        .await
        .map_err(|e| ApiError::Internal(format!("Не удалось сохранить БД: {e}")))?;

    Ok(())
}

fn now_ts() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();

    duration.as_millis() as i64
}