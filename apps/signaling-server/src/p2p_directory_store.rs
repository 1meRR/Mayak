use crate::domain::models::PrekeyBundleView;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{PgPool, Row};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnnounceP2pDeviceRequest {
    pub public_id: String,
    pub device_id: String,
    pub session_token: String,
    pub platform: String,
    pub app_version: String,
    pub signaling_ws_url: String,
    #[serde(default = "default_transport_preference")]
    pub transport_preference: String,
    #[serde(default)]
    pub stun_servers: Vec<String>,
    #[serde(default)]
    pub turn_servers: Vec<String>,
    #[serde(default = "default_capabilities")]
    pub capabilities: Value,
    pub identity_key_b64: Option<String>,
    pub device_key_b64: Option<String>,
    pub signed_prekey_b64: Option<String>,
    pub signed_prekey_signature_b64: Option<String>,
    #[serde(default = "default_one_time_prekeys")]
    pub one_time_prekeys: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetDeviceOfflineRequest {
    pub public_id: String,
    pub device_id: String,
    pub session_token: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaimPrekeyBundleRequest {
    pub public_id: String,
    pub device_id: String,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct PeerDeviceView {
    pub public_id: String,
    pub device_id: String,
    pub platform: String,
    pub app_version: String,
    pub signaling_ws_url: String,
    pub transport_preference: String,
    pub stun_servers: Vec<String>,
    pub turn_servers: Vec<String>,
    pub capabilities: Value,
    pub is_online: bool,
    pub last_seen_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerDevicesResponse {
    pub public_id: String,
    pub devices: Vec<PeerDeviceView>,
}

fn default_transport_preference() -> String {
    "webrtc".to_string()
}

fn default_capabilities() -> Value {
    json!({})
}

fn default_one_time_prekeys() -> Value {
    json!([])
}

fn normalize_upper(input: &str) -> String {
    input.trim().to_ascii_uppercase()
}

fn value_to_string_vec(value: Value) -> Vec<String> {
    match value {
        Value::Array(items) => items
            .into_iter()
            .filter_map(|item| item.as_str().map(|s| s.to_string()))
            .collect(),
        _ => Vec::new(),
    }
}

fn row_to_peer_device(row: sqlx::postgres::PgRow) -> PeerDeviceView {
    let stun_servers = row
        .try_get::<Value, _>("stun_servers")
        .map(value_to_string_vec)
        .unwrap_or_default();

    let turn_servers = row
        .try_get::<Value, _>("turn_servers")
        .map(value_to_string_vec)
        .unwrap_or_default();

    let capabilities = row
        .try_get::<Value, _>("capabilities")
        .unwrap_or_else(|_| json!({}));

    PeerDeviceView {
        public_id: row.get("public_id"),
        device_id: row.get("device_id"),
        platform: row.get("platform"),
        app_version: row.get("app_version"),
        signaling_ws_url: row.get("signaling_ws_url"),
        transport_preference: row.get("transport_preference"),
        stun_servers,
        turn_servers,
        capabilities,
        is_online: row.get("is_online"),
        last_seen_at: row.get::<f64, _>("last_seen_at_ms") as i64,
    }
}

fn row_to_prekey_bundle(row: sqlx::postgres::PgRow) -> PrekeyBundleView {
    let one_time_prekeys = row
        .try_get::<Value, _>("one_time_prekeys")
        .map(value_to_string_vec)
        .unwrap_or_default();

    PrekeyBundleView {
        public_id: row.get("public_id"),
        device_id: row.get("device_id"),
        identity_key_b64: row.try_get("identity_key_b64").ok(),
        device_key_b64: row.try_get("device_key_b64").ok(),
        signed_prekey_b64: row.try_get("signed_prekey_b64").ok(),
        signed_prekey_signature_b64: row.try_get("signed_prekey_signature_b64").ok(),
        one_time_prekeys,
        updated_at: row.get::<f64, _>("updated_at_ms") as i64,
    }
}

pub async fn upsert_announced_device(
    pool: &PgPool,
    payload: &AnnounceP2pDeviceRequest,
) -> Result<PeerDeviceView, String> {
    let public_id = normalize_upper(&payload.public_id);
    let device_id = normalize_upper(&payload.device_id);

    if public_id.is_empty() {
        return Err("publicId обязателен".to_string());
    }

    if device_id.is_empty() {
        return Err("deviceId обязателен".to_string());
    }

    let transport_preference = if payload.transport_preference.trim().is_empty() {
        "webrtc".to_string()
    } else {
        payload.transport_preference.trim().to_string()
    };

    let capabilities = if payload.capabilities.is_object() {
        payload.capabilities.clone()
    } else {
        json!({})
    };

    let one_time_prekeys = if payload.one_time_prekeys.is_array() {
        payload.one_time_prekeys.clone()
    } else {
        json!([])
    };

    let row = sqlx::query(
        r#"
        INSERT INTO p2p_device_directory (
            public_id,
            device_id,
            platform,
            app_version,
            signaling_ws_url,
            transport_preference,
            stun_servers,
            turn_servers,
            capabilities,
            is_online,
            last_seen_at,
            created_at,
            updated_at
        )
        VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, TRUE, now(), now(), now()
        )
        ON CONFLICT (public_id, device_id)
        DO UPDATE SET
            platform = EXCLUDED.platform,
            app_version = EXCLUDED.app_version,
            signaling_ws_url = EXCLUDED.signaling_ws_url,
            transport_preference = EXCLUDED.transport_preference,
            stun_servers = EXCLUDED.stun_servers,
            turn_servers = EXCLUDED.turn_servers,
            capabilities = EXCLUDED.capabilities,
            is_online = TRUE,
            last_seen_at = now(),
            updated_at = now()
        RETURNING
            public_id,
            device_id,
            platform,
            app_version,
            signaling_ws_url,
            transport_preference,
            stun_servers,
            turn_servers,
            capabilities,
            is_online,
            EXTRACT(EPOCH FROM last_seen_at) * 1000 AS last_seen_at_ms
        "#,
    )
    .bind(&public_id)
    .bind(&device_id)
    .bind(payload.platform.trim())
    .bind(payload.app_version.trim())
    .bind(payload.signaling_ws_url.trim())
    .bind(&transport_preference)
    .bind(json!(payload.stun_servers))
    .bind(json!(payload.turn_servers))
    .bind(capabilities)
    .fetch_one(pool)
    .await
    .map_err(|e| e.to_string())?;

    sqlx::query(
        r#"
        INSERT INTO p2p_prekey_bundles (
            public_id,
            device_id,
            identity_key_b64,
            device_key_b64,
            signed_prekey_b64,
            signed_prekey_signature_b64,
            one_time_prekeys,
            updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, now())
        ON CONFLICT (public_id, device_id)
        DO UPDATE SET
            identity_key_b64 = COALESCE(EXCLUDED.identity_key_b64, p2p_prekey_bundles.identity_key_b64),
            device_key_b64 = COALESCE(EXCLUDED.device_key_b64, p2p_prekey_bundles.device_key_b64),
            signed_prekey_b64 = COALESCE(EXCLUDED.signed_prekey_b64, p2p_prekey_bundles.signed_prekey_b64),
            signed_prekey_signature_b64 = COALESCE(EXCLUDED.signed_prekey_signature_b64, p2p_prekey_bundles.signed_prekey_signature_b64),
            one_time_prekeys = CASE
                WHEN jsonb_typeof(EXCLUDED.one_time_prekeys) = 'array' THEN EXCLUDED.one_time_prekeys
                ELSE p2p_prekey_bundles.one_time_prekeys
            END,
            updated_at = now()
        "#,
    )
    .bind(&public_id)
    .bind(&device_id)
    .bind(payload.identity_key_b64.as_deref())
    .bind(payload.device_key_b64.as_deref())
    .bind(payload.signed_prekey_b64.as_deref())
    .bind(payload.signed_prekey_signature_b64.as_deref())
    .bind(one_time_prekeys)
    .execute(pool)
    .await
    .map_err(|e| e.to_string())?;

    Ok(row_to_peer_device(row))
}

pub async fn mark_device_offline(
    pool: &PgPool,
    public_id: &str,
    device_id: &str,
) -> Result<(), String> {
    let public_id = normalize_upper(public_id);
    let device_id = normalize_upper(device_id);

    sqlx::query(
        r#"
        UPDATE p2p_device_directory
        SET
            is_online = FALSE,
            last_seen_at = now(),
            updated_at = now()
        WHERE public_id = $1 AND device_id = $2
        "#,
    )
    .bind(&public_id)
    .bind(&device_id)
    .execute(pool)
    .await
    .map_err(|e| e.to_string())?;

    Ok(())
}

pub async fn fetch_peer_devices(
    pool: &PgPool,
    public_id: &str,
) -> Result<Vec<PeerDeviceView>, String> {
    let public_id = normalize_upper(public_id);

    let rows = sqlx::query(
        r#"
        SELECT
            public_id,
            device_id,
            platform,
            app_version,
            signaling_ws_url,
            transport_preference,
            stun_servers,
            turn_servers,
            capabilities,
            is_online,
            EXTRACT(EPOCH FROM last_seen_at) * 1000 AS last_seen_at_ms
        FROM p2p_device_directory
        WHERE public_id = $1
        ORDER BY is_online DESC, last_seen_at DESC, created_at DESC
        "#,
    )
    .bind(&public_id)
    .fetch_all(pool)
    .await
    .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(row_to_peer_device).collect())
}

pub async fn fetch_prekey_bundle(
    pool: &PgPool,
    public_id: &str,
    device_id: &str,
) -> Result<PrekeyBundleView, String> {
    let public_id = normalize_upper(public_id);
    let device_id = normalize_upper(device_id);

    let row = sqlx::query(
        r#"
        SELECT
            public_id,
            device_id,
            identity_key_b64,
            device_key_b64,
            signed_prekey_b64,
            signed_prekey_signature_b64,
            one_time_prekeys,
            EXTRACT(EPOCH FROM updated_at) * 1000 AS updated_at_ms
        FROM p2p_prekey_bundles
        WHERE public_id = $1 AND device_id = $2
        "#,
    )
    .bind(&public_id)
    .bind(&device_id)
    .fetch_optional(pool)
    .await
    .map_err(|e| e.to_string())?
    .ok_or_else(|| "Prekey bundle не найден".to_string())?;

    Ok(row_to_prekey_bundle(row))
}

pub async fn claim_prekey_bundle(
    pool: &PgPool,
    public_id: &str,
    device_id: &str,
) -> Result<PrekeyBundleView, String> {
    let public_id = normalize_upper(public_id);
    let device_id = normalize_upper(device_id);

    let mut tx = pool.begin().await.map_err(|e| e.to_string())?;

    let row = sqlx::query(
        r#"
        SELECT
            public_id,
            device_id,
            identity_key_b64,
            device_key_b64,
            signed_prekey_b64,
            signed_prekey_signature_b64,
            one_time_prekeys,
            EXTRACT(EPOCH FROM updated_at) * 1000 AS updated_at_ms
        FROM p2p_prekey_bundles
        WHERE public_id = $1 AND device_id = $2
        FOR UPDATE
        "#,
    )
    .bind(&public_id)
    .bind(&device_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| e.to_string())?
    .ok_or_else(|| "Prekey bundle не найден".to_string())?;

    let mut one_time_prekeys = row
        .try_get::<Value, _>("one_time_prekeys")
        .map(value_to_string_vec)
        .unwrap_or_default();

    let claimed = if one_time_prekeys.is_empty() {
        Vec::<String>::new()
    } else {
        vec![one_time_prekeys.remove(0)]
    };

    sqlx::query(
        r#"
        UPDATE p2p_prekey_bundles
        SET one_time_prekeys = $3, updated_at = now()
        WHERE public_id = $1 AND device_id = $2
        "#,
    )
    .bind(&public_id)
    .bind(&device_id)
    .bind(json!(one_time_prekeys))
    .execute(&mut *tx)
    .await
    .map_err(|e| e.to_string())?;

    tx.commit().await.map_err(|e| e.to_string())?;

    Ok(PrekeyBundleView {
        public_id,
        device_id,
        identity_key_b64: row.try_get("identity_key_b64").ok(),
        device_key_b64: row.try_get("device_key_b64").ok(),
        signed_prekey_b64: row.try_get("signed_prekey_b64").ok(),
        signed_prekey_signature_b64: row.try_get("signed_prekey_signature_b64").ok(),
        one_time_prekeys: claimed,
        updated_at: row.get::<f64, _>("updated_at_ms") as i64,
    })
}