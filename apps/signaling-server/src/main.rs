mod domain;
mod storage;

use axum::{
    body::Bytes,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use domain::models::{
    AckEnvelopeRequest, ClaimPrekeyRequest, CompleteFileObjectRequest, CreateFileObjectRequest,
    CreateCallInviteRequest, CreateFriendRequestRequest, ErrorResponse, IncomingCallsResponse,
    LoginRequest, PendingMessagesQuery, PendingMessagesResponse, RegisterRequest,
    RemoveFriendRequest, RespondCallInviteRequest, RespondFriendRequestRequest,
    SendEncryptedMessageRequest, SendEncryptedMessageResponse, UpsertDeviceKeyPackageRequest,
    UserLookupResponse, CallInviteView,
};
use futures::{sink::SinkExt, stream::StreamExt};
use serde_json::json;
use sqlx::postgres::PgPoolOptions;
use std::{collections::HashMap, env, net::SocketAddr, sync::Arc};
use storage::postgres_store::{AuthenticatedDevice, PostgresStore};
use tokio::sync::{mpsc, RwLock};
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing::{error, info};

type Tx = mpsc::UnboundedSender<Message>;

#[derive(Clone)]
struct AppState {
    store: PostgresStore,
    online_devices: Arc<RwLock<HashMap<String, Tx>>>,
    call_invites: Arc<RwLock<HashMap<String, CallInviteView>>>,
}

#[tokio::main]
async fn main() {
    init_tracing();

    let database_url = env::var("DATABASE_URL").unwrap_or_else(|_| {
        "postgres://postgres:postgres@localhost:5432/decentra_call".to_string()
    });
    let bind_addr = env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".to_string());

    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect(&database_url)
        .await
        .expect("DATABASE_URL connect failed");

    let state = AppState {
        store: PostgresStore::new(pool),
        online_devices: Arc::new(RwLock::new(HashMap::new())),
        call_invites: Arc::new(RwLock::new(HashMap::new())),
    };

    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/auth/register", post(register))
        .route("/v1/auth/login", post(login))
        .route("/v1/users/{public_id}/devices", get(list_user_devices))
        .route("/v1/users/by-public-id/{public_id}", get(lookup_user_by_public_id))
        .route(
            "/v1/users/by-friend-code/{friend_code}",
            get(lookup_user_by_friend_code),
        )
        .route("/v1/friends/{public_id}", get(fetch_friends_bundle))
        .route("/v1/friends/request", post(create_friend_request))
        .route("/v1/friends/respond", post(respond_friend_request))
        .route("/v1/friends/remove", post(remove_friend))
        .route("/api/calls/invite", post(create_call_invite))
        .route("/api/calls/{invite_id}", get(get_call_invite))
        .route("/api/calls/incoming/{public_id}", get(fetch_incoming_calls))
        .route("/api/calls/respond", post(respond_call_invite))
        .route("/v1/prekeys/claim", post(claim_prekey))
        .route("/v1/devices/key-package", post(upsert_device_key_package))
        .route("/v1/messages/send", post(send_encrypted_messages))
        .route("/v1/messages/pending", get(get_pending_messages))
        .route("/v1/messages/{envelope_id}/ack", post(ack_envelope))
        .route("/v1/files", post(create_file_object))
        .route("/v1/files/{file_id}/complete", post(complete_file_object))
        .route("/v1/files/{file_id}", get(get_file_for_device))
        .route(
            "/v1/files/{file_id}/chunks/{chunk_index}",
            post(upload_file_chunk),
        )
        .route("/v1/files/{file_id}/content", get(download_file_content))
        .route("/v1/ws", get(ws_handler))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr: SocketAddr = bind_addr.parse().expect("Invalid BIND_ADDR");
    info!("listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind failed");
    axum::serve(listener, app).await.expect("server failed");
}

fn init_tracing() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "info,tower_http=info".into());

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .init();
}

async fn health() -> impl IntoResponse {
    Json(json!({ "status": "ok" }))
}

async fn register(State(state): State<AppState>, Json(req): Json<RegisterRequest>) -> Response {
    match state.store.register_user(req).await {
        Ok(profile) => (StatusCode::CREATED, Json(profile)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn login(State(state): State<AppState>, Json(req): Json<LoginRequest>) -> Response {
    match state
        .store
        .login_user(
            &req.phone_e164,
            &req.password,
            &req.device_id,
            &req.platform,
        )
        .await
    {
        Ok(resp) => (StatusCode::OK, Json(resp)).into_response(),
        Err(err) => error_response(StatusCode::UNAUTHORIZED, err),
    }
}

async fn list_user_devices(
    State(state): State<AppState>,
    Path(public_id): Path<String>,
) -> Response {
    match state.store.list_user_devices(&public_id).await {
        Ok(items) => (StatusCode::OK, Json(items)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn lookup_user_by_public_id(
    State(state): State<AppState>,
    Path(public_id): Path<String>,
) -> Response {
    match state.store.lookup_user_by_public_id(&public_id).await {
        Ok(user) => (StatusCode::OK, Json(UserLookupResponse { user })).into_response(),
        Err(err) => error_response(StatusCode::NOT_FOUND, err),
    }
}

async fn lookup_user_by_friend_code(
    State(state): State<AppState>,
    Path(friend_code): Path<String>,
) -> Response {
    match state.store.lookup_user_by_friend_code(&friend_code).await {
        Ok(user) => (StatusCode::OK, Json(UserLookupResponse { user })).into_response(),
        Err(err) => error_response(StatusCode::NOT_FOUND, err),
    }
}

async fn fetch_friends_bundle(
    State(state): State<AppState>,
    Path(public_id): Path<String>,
) -> Response {
    match state.store.fetch_friends_bundle(&public_id).await {
        Ok(bundle) => (StatusCode::OK, Json(bundle)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn create_friend_request(
    State(state): State<AppState>,
    Json(req): Json<CreateFriendRequestRequest>,
) -> Response {
    match state
        .store
        .create_friend_request(
            &req.from_public_id,
            &req.from_device_id,
            &req.session_token,
            &req.to_public_id,
        )
        .await
    {
        Ok(view) => (StatusCode::CREATED, Json(view)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn respond_friend_request(
    State(state): State<AppState>,
    Json(req): Json<RespondFriendRequestRequest>,
) -> Response {
    match state
        .store
        .respond_friend_request(
            &req.request_id,
            &req.actor_public_id,
            &req.actor_device_id,
            &req.session_token,
            &req.action,
        )
        .await
    {
        Ok(view) => (StatusCode::OK, Json(view)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn remove_friend(
    State(state): State<AppState>,
    Json(req): Json<RemoveFriendRequest>,
) -> Response {
    match state
        .store
        .remove_friend(
            &req.actor_public_id,
            &req.actor_device_id,
            &req.session_token,
            &req.target_public_id,
        )
        .await
    {
        Ok(_) => (StatusCode::OK, Json(json!({ "removed": true }))).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn create_call_invite(
    State(state): State<AppState>,
    Json(req): Json<CreateCallInviteRequest>,
) -> Response {
    let auth = match state
        .store
        .authenticate(&req.session_token, &req.caller_device_id)
        .await
    {
        Ok(v) => v,
        Err(err) => return error_response(StatusCode::UNAUTHORIZED, err),
    };

    let caller_public_id = req.caller_public_id.trim().to_uppercase();
    let callee_public_id = req.callee_public_id.trim().to_uppercase();
    if auth.public_id != caller_public_id {
        return error_response(StatusCode::UNAUTHORIZED, "Неверный callerPublicId");
    }
    if caller_public_id == callee_public_id {
        return error_response(StatusCode::BAD_REQUEST, "Нельзя звонить самому себе");
    }

    let caller = match state.store.lookup_user_by_public_id(&caller_public_id).await {
        Ok(v) => v,
        Err(err) => return error_response(StatusCode::BAD_REQUEST, err),
    };
    let callee = match state.store.lookup_user_by_public_id(&callee_public_id).await {
        Ok(v) => v,
        Err(err) => return error_response(StatusCode::BAD_REQUEST, err),
    };

    let now = chrono::Utc::now().timestamp_millis();
    let invite = CallInviteView {
        invite_id: format!("CI{}", uuid::Uuid::new_v4().simple()),
        caller_public_id: caller_public_id.clone(),
        caller_display_name: caller.display_name,
        callee_public_id: callee_public_id.clone(),
        callee_display_name: callee.display_name,
        room_id: format!("room_{}_{}_{}", caller_public_id, callee_public_id, now),
        status: "pending".to_string(),
        created_at: now,
        responded_at: None,
    };

    let mut invites = state.call_invites.write().await;
    invites.insert(invite.invite_id.clone(), invite.clone());
    (StatusCode::OK, Json(invite)).into_response()
}

async fn get_call_invite(
    State(state): State<AppState>,
    Path(invite_id): Path<String>,
) -> Response {
    let invites = state.call_invites.read().await;
    match invites.get(invite_id.trim()) {
        Some(invite) => (StatusCode::OK, Json(invite.clone())).into_response(),
        None => error_response(StatusCode::NOT_FOUND, "Invite не найден"),
    }
}

async fn fetch_incoming_calls(
    State(state): State<AppState>,
    Path(public_id): Path<String>,
) -> Response {
    let normalized = public_id.trim().to_uppercase();
    let now = chrono::Utc::now().timestamp_millis();

    let mut invites = state.call_invites.write().await;
    for invite in invites.values_mut() {
        if invite.status == "pending" && now - invite.created_at > 120_000 {
            invite.status = "expired".to_string();
            invite.responded_at = Some(now);
        }
    }

    let items = invites
        .values()
        .filter(|invite| invite.callee_public_id == normalized && invite.status == "pending")
        .cloned()
        .collect::<Vec<_>>();

    (StatusCode::OK, Json(IncomingCallsResponse { items })).into_response()
}

async fn respond_call_invite(
    State(state): State<AppState>,
    Json(req): Json<RespondCallInviteRequest>,
) -> Response {
    let auth = match state
        .store
        .authenticate(&req.session_token, &req.actor_device_id)
        .await
    {
        Ok(v) => v,
        Err(err) => return error_response(StatusCode::UNAUTHORIZED, err),
    };

    let action = req.action.trim().to_lowercase();
    if action != "accept" && action != "reject" {
        return error_response(StatusCode::BAD_REQUEST, "action должен быть accept/reject");
    }

    let actor_public_id = req.actor_public_id.trim().to_uppercase();
    if auth.public_id != actor_public_id {
        return error_response(StatusCode::UNAUTHORIZED, "Неверный actorPublicId");
    }

    let mut invites = state.call_invites.write().await;
    let invite = match invites.get_mut(req.invite_id.trim()) {
        Some(v) => v,
        None => return error_response(StatusCode::NOT_FOUND, "Invite не найден"),
    };

    if invite.status != "pending" {
        return (StatusCode::OK, Json(invite.clone())).into_response();
    }

    if invite.callee_public_id != actor_public_id {
        return error_response(StatusCode::FORBIDDEN, "Только вызываемый может ответить");
    }

    invite.status = if action == "accept" {
        "accepted".to_string()
    } else {
        "rejected".to_string()
    };
    invite.responded_at = Some(chrono::Utc::now().timestamp_millis());

    (StatusCode::OK, Json(invite.clone())).into_response()
}

async fn claim_prekey(
    State(state): State<AppState>,
    Json(req): Json<ClaimPrekeyRequest>,
) -> Response {
    match state
        .store
        .claim_one_time_prekey(&req.public_id, &req.device_id)
        .await
    {
        Ok(bundle) => (StatusCode::OK, Json(bundle)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn upsert_device_key_package(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<UpsertDeviceKeyPackageRequest>,
) -> Response {
    let auth = match authenticate_from_headers(&state, &headers, Some(req.device_id.clone())).await
    {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    match state.store.upsert_device_key_package(&auth, req).await {
        Ok(bundle) => (StatusCode::OK, Json(bundle)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn send_encrypted_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<SendEncryptedMessageRequest>,
) -> Response {
    let auth = match authenticate_from_headers(&state, &headers, Some(req.sender_device_id.clone()))
        .await
    {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    match state
        .store
        .store_encrypted_envelopes(
            &auth,
            &req.conversation_id,
            &req.sender_device_id,
            req.recipients,
        )
        .await
    {
        Ok(stored) => {
            notify_pending(&state, &stored).await;
            (
                StatusCode::CREATED,
                Json(SendEncryptedMessageResponse { stored }),
            )
                .into_response()
        }
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn get_pending_messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<PendingMessagesQuery>,
) -> Response {
    let auth =
        match authenticate_from_headers(&state, &headers, Some(query.device_id.clone())).await {
            Ok(v) => v,
            Err(resp) => return resp,
        };

    let limit = query.limit.unwrap_or(200).clamp(1, 1000);
    match state
        .store
        .list_pending_envelopes(&auth, query.after_server_seq, limit)
        .await
    {
        Ok(items) => (StatusCode::OK, Json(PendingMessagesResponse { items })).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn ack_envelope(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(envelope_id): Path<String>,
    Json(req): Json<AckEnvelopeRequest>,
) -> Response {
    let auth = match authenticate_from_headers(&state, &headers, Some(req.device_id.clone())).await
    {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    match state
        .store
        .mark_envelope_acked(&auth, &envelope_id, req.mark_read.unwrap_or(false))
        .await
    {
        Ok(resp) => (StatusCode::OK, Json(resp)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn create_file_object(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<CreateFileObjectRequest>,
) -> Response {
    let auth =
        match authenticate_from_headers(&state, &headers, Some(req.uploader_device_id.clone()))
            .await
        {
            Ok(v) => v,
            Err(resp) => return resp,
        };

    match state.store.create_file_object(&auth, req).await {
        Ok(file) => (StatusCode::CREATED, Json(file)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn complete_file_object(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(file_id): Path<String>,
    Json(req): Json<CompleteFileObjectRequest>,
) -> Response {
    let device_id = match required_header_string(&headers, "x-device-id") {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let auth = match authenticate_from_headers(&state, &headers, Some(device_id)).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    match state
        .store
        .complete_file_object(&auth, &file_id, &req.upload_status)
        .await
    {
        Ok(file) => (StatusCode::OK, Json(file)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn get_file_for_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(file_id): Path<String>,
) -> Response {
    let device_id = match required_header_string(&headers, "x-device-id") {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let auth = match authenticate_from_headers(&state, &headers, Some(device_id)).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    match state.store.get_file_for_recipient(&auth, &file_id).await {
        Ok(resp) => (StatusCode::OK, Json(resp)).into_response(),
        Err(err) => error_response(StatusCode::BAD_REQUEST, err),
    }
}

async fn upload_file_chunk(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((file_id, chunk_index)): Path<(String, i32)>,
    body: Bytes,
) -> Response {
    let device_id = match required_header_string(&headers, "x-device-id") {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let auth = match authenticate_from_headers(&state, &headers, Some(device_id)).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    if body.is_empty() {
        return error_response(StatusCode::BAD_REQUEST, "chunk body is empty");
    }

    match state.store.ensure_file_uploader(&auth, &file_id).await {
        Ok(_) => {}
        Err(err) => return error_response(StatusCode::FORBIDDEN, err),
    }

    let base_dir = env::var("FILE_STORAGE_DIR").unwrap_or_else(|_| "./file_storage".to_string());
    let file_dir = format!("{}/{}", base_dir, file_id.trim());

    if let Err(err) = tokio::fs::create_dir_all(&file_dir).await {
        return error_response(StatusCode::INTERNAL_SERVER_ERROR, err.to_string());
    }

    let path = format!("{}/chunk_{:06}.bin", file_dir, chunk_index);
    if let Err(err) = tokio::fs::write(&path, &body).await {
        return error_response(StatusCode::INTERNAL_SERVER_ERROR, err.to_string());
    }

    (
        StatusCode::CREATED,
        Json(json!({"ok": true, "chunkIndex": chunk_index})),
    )
        .into_response()
}

async fn download_file_content(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(file_id): Path<String>,
) -> Response {
    let device_id = match required_header_string(&headers, "x-device-id") {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    let auth = match authenticate_from_headers(&state, &headers, Some(device_id)).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    match state.store.ensure_file_downloadable(&auth, &file_id).await {
        Ok(_) => {}
        Err(err) => return error_response(StatusCode::FORBIDDEN, err),
    }

    let base_dir = env::var("FILE_STORAGE_DIR").unwrap_or_else(|_| "./file_storage".to_string());
    let file_dir = format!("{}/{}", base_dir, file_id.trim());

    let mut entries = match tokio::fs::read_dir(&file_dir).await {
        Ok(v) => v,
        Err(err) => return error_response(StatusCode::NOT_FOUND, err.to_string()),
    };

    let mut parts: Vec<(String, Vec<u8>)> = Vec::new();
    loop {
        match entries.next_entry().await {
            Ok(Some(item)) => {
                let name = item.file_name().to_string_lossy().to_string();
                if !name.starts_with("chunk_") {
                    continue;
                }
                match tokio::fs::read(item.path()).await {
                    Ok(bytes) => parts.push((name, bytes)),
                    Err(err) => {
                        return error_response(StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
                    }
                }
            }
            Ok(None) => break,
            Err(err) => return error_response(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()),
        }
    }

    parts.sort_by(|a, b| a.0.cmp(&b.0));
    let mut merged = Vec::<u8>::new();
    for (_, part) in parts {
        merged.extend_from_slice(&part);
    }

    (StatusCode::OK, merged).into_response()
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let device_id = match query.get("deviceId") {
        Some(v) => v.clone(),
        None => {
            return error_response(
                StatusCode::BAD_REQUEST,
                "deviceId query parameter is required",
            )
        }
    };

    let auth = match authenticate_from_headers(&state, &headers, Some(device_id)).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };

    ws.on_upgrade(move |socket| handle_ws_socket(state, auth, socket))
        .into_response()
}

async fn handle_ws_socket(state: AppState, auth: AuthenticatedDevice, socket: WebSocket) {
    let connection_key = online_key(&auth.public_id, &auth.device_id);
    let (mut sender, mut receiver) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    {
        let mut guard = state.online_devices.write().await;
        guard.insert(connection_key.clone(), tx);
    }

    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sender.send(msg).await.is_err() {
                break;
            }
        }
    });

    let recv_state = state.clone();
    let recv_auth = auth.clone();
    let recv_connection_key = connection_key.clone();

    let recv_task = tokio::spawn(async move {
        while let Some(result) = receiver.next().await {
            match result {
                Ok(Message::Ping(payload)) => {
                    let payload_text = String::from_utf8_lossy(&payload).to_string();
                    tracing::debug!(
                        "ws ping from {}:{} {}",
                        recv_auth.public_id,
                        recv_auth.device_id,
                        payload_text
                    );
                }
                Ok(Message::Text(text)) => {
                    tracing::debug!(
                        "ws text from {}:{} {}",
                        recv_auth.public_id,
                        recv_auth.device_id,
                        text
                    );
                }
                Ok(Message::Close(_)) => break,
                Ok(_) => {}
                Err(err) => {
                    error!("ws receive error: {}", err);
                    break;
                }
            }
        }

        let mut guard = recv_state.online_devices.write().await;
        guard.remove(&recv_connection_key);
    });

    let _ = tokio::join!(send_task, recv_task);
}

async fn authenticate_from_headers(
    state: &AppState,
    headers: &HeaderMap,
    explicit_device_id: Option<String>,
) -> Result<AuthenticatedDevice, Response> {
    let bearer = match bearer_token(headers) {
        Some(v) => v,
        None => {
            return Err(error_response(
                StatusCode::UNAUTHORIZED,
                "Missing Bearer token",
            ))
        }
    };

    let device_id = match explicit_device_id {
        Some(v) => v,
        None => match required_header_string(headers, "x-device-id") {
            Ok(v) => v,
            Err(resp) => return Err(resp),
        },
    };

    state
        .store
        .authenticate(&bearer, &device_id)
        .await
        .map_err(|err| error_response(StatusCode::UNAUTHORIZED, err))
}

fn bearer_token(headers: &HeaderMap) -> Option<String> {
    let value = headers.get("authorization")?.to_str().ok()?;
    value.strip_prefix("Bearer ").map(|v| v.trim().to_string())
}

fn required_header_string(headers: &HeaderMap, header_name: &str) -> Result<String, Response> {
    headers
        .get(header_name)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| {
            error_response(
                StatusCode::BAD_REQUEST,
                format!("Missing required header {}", header_name),
            )
        })
}

async fn notify_pending(state: &AppState, stored: &[crate::domain::models::StoredEnvelopeView]) {
    let guard = state.online_devices.read().await;

    for item in stored {
        let key = online_key(&item.recipient_public_id, &item.recipient_device_id);
        if let Some(tx) = guard.get(&key) {
            let _ = tx.send(Message::Text(
                json!({
                    "type": "pending_envelope",
                    "envelopeId": item.envelope_id,
                    "conversationId": item.conversation_id,
                    "serverSeq": item.server_seq,
                    "messageKind": item.message_kind
                })
                .to_string()
                .into(),
            ));
        }
    }
}

fn online_key(public_id: &str, device_id: &str) -> String {
    format!(
        "{}:{}",
        public_id.trim().to_ascii_uppercase(),
        device_id.trim().to_ascii_uppercase()
    )
}

fn error_response(status: StatusCode, error: impl Into<String>) -> Response {
    (
        status,
        Json(ErrorResponse {
            error: error.into(),
        }),
    )
        .into_response()
}
