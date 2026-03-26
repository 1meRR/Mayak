use crate::domain::models::{
    AckEnvelopeResponse, CreateFileObjectRequest, DeviceDirectoryView, DeviceKeyPackageView,
    FileKeyEnvelopeView, FileLookupResponse, FileObjectView, LoginResponse, RecipientEnvelopeInput,
    RegisterRequest, StoredEnvelopeView, UpsertDeviceKeyPackageRequest, UserProfileView,
};
use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use rand::{distr::Alphanumeric, Rng};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use uuid::Uuid;

#[derive(Clone)]
pub struct PostgresStore {
    pub pool: PgPool,
}

#[derive(Debug, Clone)]
pub struct AuthenticatedDevice {
    pub user_id: Uuid,
    pub public_id: String,
    pub device_id: String,
}

impl PostgresStore {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn register_user(&self, req: RegisterRequest) -> Result<UserProfileView, String> {
        let phone = normalize_phone(&req.phone_e164)?;
        let public_id = format!("U{}", random_upper_alnum(12));
        let friend_code = random_upper_alnum(10);
        let display_name = build_display_name(&req.first_name, &req.last_name);
        let about = req.about.unwrap_or_default();
        let password_hash = hash_password(&req.password)?;

        let row = sqlx::query(
            r#"
            INSERT INTO users (
                public_id, friend_code, phone_e164, first_name, last_name, about, password_hash
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            RETURNING
                public_id,
                friend_code,
                first_name,
                last_name,
                about,
                (EXTRACT(EPOCH FROM created_at) * 1000)::BIGINT AS created_at_ms,
                (EXTRACT(EPOCH FROM updated_at) * 1000)::BIGINT AS updated_at_ms
            "#,
        )
        .bind(&public_id)
        .bind(&friend_code)
        .bind(&phone)
        .bind(req.first_name.trim())
        .bind(req.last_name.trim())
        .bind(&about)
        .bind(&password_hash)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(UserProfileView {
            public_id: row.get("public_id"),
            friend_code: row.get("friend_code"),
            display_name,
            about: row.get("about"),
            created_at: row.get::<i64, _>("created_at_ms"),
            updated_at: row.get::<i64, _>("updated_at_ms"),
        })
    }

    pub async fn login_user(
        &self,
        phone_e164: &str,
        password: &str,
        device_id: &str,
        platform: &str,
    ) -> Result<LoginResponse, String> {
        let phone = normalize_phone(phone_e164)?;
        let device_id = normalize_device_id(device_id);
        let platform = platform.trim().to_string();

        let user_row = sqlx::query(
            r#"
            SELECT
                id,
                public_id,
                friend_code,
                first_name,
                last_name,
                about,
                password_hash,
                (EXTRACT(EPOCH FROM created_at) * 1000)::BIGINT AS created_at_ms,
                (EXTRACT(EPOCH FROM updated_at) * 1000)::BIGINT AS updated_at_ms
            FROM users
            WHERE phone_e164 = $1
            "#,
        )
        .bind(&phone)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Неверный телефон или пароль".to_string())?;

        let password_hash_value: String = user_row.get("password_hash");
        let parsed_hash = PasswordHash::new(&password_hash_value)
            .map_err(|e| e.to_string())?;
        Argon2::default()
            .verify_password(password.as_bytes(), &parsed_hash)
            .map_err(|_| "Неверный телефон или пароль".to_string())?;

        let user_id: Uuid = user_row.get("id");
        let public_id: String = user_row.get("public_id");
        let session_token = generate_session_token();
        let session_token_hash = sha256_hex(&session_token);

        sqlx::query(
            r#"
            INSERT INTO devices (user_id, device_id, platform, session_token_hash, last_seen_at, updated_at)
            VALUES ($1, $2, $3, $4, now(), now())
            ON CONFLICT (user_id, device_id)
            DO UPDATE SET
                platform = EXCLUDED.platform,
                session_token_hash = EXCLUDED.session_token_hash,
                last_seen_at = now(),
                updated_at = now()
            "#,
        )
        .bind(user_id)
        .bind(&device_id)
        .bind(&platform)
        .bind(&session_token_hash)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        let first_name: String = user_row.get("first_name");
        let last_name: String = user_row.get("last_name");

        Ok(LoginResponse {
            session_token,
            device_id,
            profile: UserProfileView {
                public_id,
                friend_code: user_row.get("friend_code"),
                display_name: build_display_name(&first_name, &last_name),
                about: user_row.get("about"),
                created_at: user_row.get::<i64, _>("created_at_ms"),
                updated_at: user_row.get::<i64, _>("updated_at_ms"),
            },
        })
    }

    pub async fn authenticate(
        &self,
        bearer_token: &str,
        device_id: &str,
    ) -> Result<AuthenticatedDevice, String> {
        let device_id = normalize_device_id(device_id);
        let token_hash = sha256_hex(bearer_token);

        let row = sqlx::query(
            r#"
            SELECT
                u.id AS user_id,
                u.public_id AS public_id,
                d.device_id AS device_id
            FROM devices d
            INNER JOIN users u ON u.id = d.user_id
            WHERE d.device_id = $1 AND d.session_token_hash = $2
            "#,
        )
        .bind(&device_id)
        .bind(&token_hash)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Невалидная авторизация устройства".to_string())?;

        sqlx::query(
            r#"
            UPDATE devices
            SET last_seen_at = now(), updated_at = now()
            WHERE user_id = $1 AND device_id = $2
            "#,
        )
        .bind(row.get::<Uuid, _>("user_id"))
        .bind(&device_id)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(AuthenticatedDevice {
            user_id: row.get("user_id"),
            public_id: row.get("public_id"),
            device_id: row.get("device_id"),
        })
    }

    pub async fn upsert_device_key_package(
        &self,
        auth: &AuthenticatedDevice,
        req: UpsertDeviceKeyPackageRequest,
    ) -> Result<DeviceKeyPackageView, String> {
        let device_id = normalize_device_id(&req.device_id);
        if device_id != auth.device_id {
            return Err("device_id в bundle должен совпадать с авторизованным устройством".to_string());
        }

        sqlx::query(
            r#"
            INSERT INTO device_key_packages (
                user_id,
                device_id,
                identity_key_alg,
                identity_key_b64,
                signed_prekey_b64,
                signed_prekey_signature_b64,
                signed_prekey_key_id,
                one_time_prekeys,
                updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())
            ON CONFLICT (user_id, device_id)
            DO UPDATE SET
                identity_key_alg = EXCLUDED.identity_key_alg,
                identity_key_b64 = EXCLUDED.identity_key_b64,
                signed_prekey_b64 = EXCLUDED.signed_prekey_b64,
                signed_prekey_signature_b64 = EXCLUDED.signed_prekey_signature_b64,
                signed_prekey_key_id = EXCLUDED.signed_prekey_key_id,
                one_time_prekeys = EXCLUDED.one_time_prekeys,
                replaced_at = now(),
                updated_at = now()
            "#,
        )
        .bind(auth.user_id)
        .bind(&device_id)
        .bind(req.identity_key_alg.trim())
        .bind(req.identity_key_b64.trim())
        .bind(req.signed_prekey_b64.trim())
        .bind(req.signed_prekey_signature_b64.trim())
        .bind(req.signed_prekey_key_id)
        .bind(json!(req.one_time_prekeys))
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        self.fetch_device_key_package_by_public_id(&auth.public_id, &device_id)
            .await
    }

    pub async fn list_user_devices(&self, public_id: &str) -> Result<Vec<DeviceDirectoryView>, String> {
        let rows = sqlx::query(
            r#"
            SELECT
                u.public_id AS public_id,
                d.device_id AS device_id,
                d.platform AS platform,
                TRUE AS is_online,
                (EXTRACT(EPOCH FROM d.last_seen_at) * 1000)::BIGINT AS last_seen_at_ms,
                NULL::TEXT AS app_version,
                '{}'::jsonb AS capabilities
            FROM users u
            INNER JOIN devices d ON d.user_id = u.id
            WHERE u.public_id = $1
            ORDER BY d.last_seen_at DESC, d.created_at DESC
            "#,
        )
        .bind(public_id.trim())
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(rows
            .into_iter()
            .map(|row| DeviceDirectoryView {
                public_id: row.get("public_id"),
                device_id: row.get("device_id"),
                platform: row.get("platform"),
                is_online: row.get("is_online"),
                last_seen_at: row.get::<i64, _>("last_seen_at_ms"),
                app_version: row.try_get("app_version").ok(),
                capabilities: row.get("capabilities"),
            })
            .collect())
    }

    pub async fn fetch_device_key_package_by_public_id(
        &self,
        public_id: &str,
        device_id: &str,
    ) -> Result<DeviceKeyPackageView, String> {
        let row = sqlx::query(
            r#"
            SELECT
                u.public_id AS public_id,
                k.device_id AS device_id,
                k.identity_key_alg AS identity_key_alg,
                k.identity_key_b64 AS identity_key_b64,
                k.signed_prekey_b64 AS signed_prekey_b64,
                k.signed_prekey_signature_b64 AS signed_prekey_signature_b64,
                k.signed_prekey_key_id AS signed_prekey_key_id,
                k.one_time_prekeys AS one_time_prekeys,
                (EXTRACT(EPOCH FROM k.updated_at) * 1000)::BIGINT AS updated_at_ms
            FROM device_key_packages k
            INNER JOIN users u ON u.id = k.user_id
            WHERE u.public_id = $1 AND k.device_id = $2
            "#,
        )
        .bind(public_id.trim())
        .bind(normalize_device_id(device_id))
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "device key package не найден".to_string())?;

        Ok(row_to_device_key_package(row))
    }

    pub async fn claim_one_time_prekey(
        &self,
        public_id: &str,
        device_id: &str,
    ) -> Result<DeviceKeyPackageView, String> {
        let mut tx = self.pool.begin().await.map_err(|e| e.to_string())?;

        let row = sqlx::query(
            r#"
            SELECT
                u.public_id AS public_id,
                k.user_id AS user_id,
                k.device_id AS device_id,
                k.identity_key_alg AS identity_key_alg,
                k.identity_key_b64 AS identity_key_b64,
                k.signed_prekey_b64 AS signed_prekey_b64,
                k.signed_prekey_signature_b64 AS signed_prekey_signature_b64,
                k.signed_prekey_key_id AS signed_prekey_key_id,
                k.one_time_prekeys AS one_time_prekeys,
                (EXTRACT(EPOCH FROM k.updated_at) * 1000)::BIGINT AS updated_at_ms
            FROM device_key_packages k
            INNER JOIN users u ON u.id = k.user_id
            WHERE u.public_id = $1 AND k.device_id = $2
            FOR UPDATE
            "#,
        )
        .bind(public_id.trim())
        .bind(normalize_device_id(device_id))
        .fetch_optional(&mut *tx)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "device key package не найден".to_string())?;

        let mut prekeys = json_value_to_string_vec(row.get("one_time_prekeys"));
        let claimed = if prekeys.is_empty() {
            Vec::<String>::new()
        } else {
            vec![prekeys.remove(0)]
        };

        let user_id: Uuid = row.get("user_id");
        let dev_id: String = row.get("device_id");

        sqlx::query(
            r#"
            UPDATE device_key_packages
            SET one_time_prekeys = $3, updated_at = now()
            WHERE user_id = $1 AND device_id = $2
            "#,
        )
        .bind(user_id)
        .bind(&dev_id)
        .bind(json!(prekeys))
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;

        tx.commit().await.map_err(|e| e.to_string())?;

        Ok(DeviceKeyPackageView {
            public_id: row.get("public_id"),
            device_id: dev_id,
            identity_key_alg: row.get("identity_key_alg"),
            identity_key_b64: row.get("identity_key_b64"),
            signed_prekey_b64: row.get("signed_prekey_b64"),
            signed_prekey_signature_b64: row.get("signed_prekey_signature_b64"),
            signed_prekey_key_id: row.get("signed_prekey_key_id"),
            one_time_prekeys: claimed,
            updated_at: row.get::<i64, _>("updated_at_ms"),
        })
    }

    pub async fn store_encrypted_envelopes(
        &self,
        auth: &AuthenticatedDevice,
        conversation_id: &str,
        sender_device_id: &str,
        recipients: Vec<RecipientEnvelopeInput>,
    ) -> Result<Vec<StoredEnvelopeView>, String> {
        let sender_device_id = normalize_device_id(sender_device_id);
        if sender_device_id != auth.device_id {
            return Err("sender_device_id должен совпадать с авторизованным устройством".to_string());
        }

        let mut tx = self.pool.begin().await.map_err(|e| e.to_string())?;
        let mut stored = Vec::new();

        for recipient in recipients {
            let recipient_public_id = recipient.recipient_public_id.trim().to_string();
            let recipient_device_id = normalize_device_id(&recipient.recipient_device_id);
            let envelope_id = format!("ENV{}", random_upper_alnum(20));

            let recipient_user_id: Uuid = sqlx::query_scalar(
                "SELECT id FROM users WHERE public_id = $1",
            )
            .bind(&recipient_public_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("Пользователь {} не найден", recipient_public_id))?;

            sqlx::query(
                r#"
                INSERT INTO message_envelopes (
                    envelope_id,
                    conversation_id,
                    sender_user_id,
                    sender_device_id,
                    recipient_user_id,
                    recipient_device_id,
                    message_kind,
                    protocol,
                    header_b64,
                    ciphertext_b64,
                    server_metadata
                )
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
                "#,
            )
            .bind(&envelope_id)
            .bind(conversation_id.trim())
            .bind(auth.user_id)
            .bind(&sender_device_id)
            .bind(recipient_user_id)
            .bind(&recipient_device_id)
            .bind(recipient.message_kind.trim())
            .bind(recipient.protocol.trim())
            .bind(recipient.header_b64.trim())
            .bind(recipient.ciphertext_b64.trim())
            .bind(recipient.metadata.unwrap_or_else(|| json!({})))
            .execute(&mut *tx)
            .await
            .map_err(|e| e.to_string())?;

            let row = sqlx::query(
                r#"
                SELECT
                    e.envelope_id AS envelope_id,
                    e.conversation_id AS conversation_id,
                    su.public_id AS sender_public_id,
                    e.sender_device_id AS sender_device_id,
                    ru.public_id AS recipient_public_id,
                    e.recipient_device_id AS recipient_device_id,
                    e.message_kind AS message_kind,
                    e.protocol AS protocol,
                    e.header_b64 AS header_b64,
                    e.ciphertext_b64 AS ciphertext_b64,
                    e.server_metadata AS server_metadata,
                    (EXTRACT(EPOCH FROM e.created_at) * 1000)::BIGINT AS created_at_ms,
                    (EXTRACT(EPOCH FROM e.delivered_at) * 1000)::BIGINT AS delivered_at_ms,
                    (EXTRACT(EPOCH FROM e.acked_at) * 1000)::BIGINT AS acked_at_ms,
                    (EXTRACT(EPOCH FROM e.read_at) * 1000)::BIGINT AS read_at_ms,
                    e.server_seq AS server_seq
                FROM message_envelopes e
                INNER JOIN users su ON su.id = e.sender_user_id
                INNER JOIN users ru ON ru.id = e.recipient_user_id
                WHERE e.envelope_id = $1
                "#,
            )
            .bind(&envelope_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| e.to_string())?;

            stored.push(row_to_envelope(row));
        }

        tx.commit().await.map_err(|e| e.to_string())?;
        Ok(stored)
    }

    pub async fn list_pending_envelopes(
        &self,
        auth: &AuthenticatedDevice,
        after_server_seq: Option<i64>,
        limit: i64,
    ) -> Result<Vec<StoredEnvelopeView>, String> {
        let rows = sqlx::query(
            r#"
            SELECT
                e.envelope_id AS envelope_id,
                e.conversation_id AS conversation_id,
                su.public_id AS sender_public_id,
                e.sender_device_id AS sender_device_id,
                ru.public_id AS recipient_public_id,
                e.recipient_device_id AS recipient_device_id,
                e.message_kind AS message_kind,
                e.protocol AS protocol,
                e.header_b64 AS header_b64,
                e.ciphertext_b64 AS ciphertext_b64,
                e.server_metadata AS server_metadata,
                (EXTRACT(EPOCH FROM e.created_at) * 1000)::BIGINT AS created_at_ms,
                (EXTRACT(EPOCH FROM e.delivered_at) * 1000)::BIGINT AS delivered_at_ms,
                (EXTRACT(EPOCH FROM e.acked_at) * 1000)::BIGINT AS acked_at_ms,
                (EXTRACT(EPOCH FROM e.read_at) * 1000)::BIGINT AS read_at_ms,
                e.server_seq AS server_seq
            FROM message_envelopes e
            INNER JOIN users su ON su.id = e.sender_user_id
            INNER JOIN users ru ON ru.id = e.recipient_user_id
            WHERE e.recipient_user_id = $1
              AND e.recipient_device_id = $2
              AND ($3::BIGINT IS NULL OR e.server_seq > $3)
            ORDER BY e.server_seq ASC
            LIMIT $4
            "#,
        )
        .bind(auth.user_id)
        .bind(&auth.device_id)
        .bind(after_server_seq)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(rows.into_iter().map(row_to_envelope).collect())
    }

    pub async fn mark_envelope_acked(
        &self,
        auth: &AuthenticatedDevice,
        envelope_id: &str,
        mark_read: bool,
    ) -> Result<AckEnvelopeResponse, String> {
        let row = sqlx::query(
            r#"
            UPDATE message_envelopes
            SET
                delivered_at = COALESCE(delivered_at, now()),
                acked_at = COALESCE(acked_at, now()),
                read_at = CASE
                    WHEN $4 = TRUE THEN COALESCE(read_at, now())
                    ELSE read_at
                END
            WHERE envelope_id = $1
              AND recipient_user_id = $2
              AND recipient_device_id = $3
            RETURNING
                envelope_id,
                (EXTRACT(EPOCH FROM acked_at) * 1000)::BIGINT AS acked_at_ms,
                (EXTRACT(EPOCH FROM read_at) * 1000)::BIGINT AS read_at_ms
            "#,
        )
        .bind(envelope_id.trim())
        .bind(auth.user_id)
        .bind(&auth.device_id)
        .bind(mark_read)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Envelope не найден для данного устройства".to_string())?;

        Ok(AckEnvelopeResponse {
            envelope_id: row.get("envelope_id"),
            acked_at: row.get::<i64, _>("acked_at_ms"),
            read_at: row.try_get::<Option<i64>, _>("read_at_ms").ok().flatten(),
        })
    }

    pub async fn create_file_object(
        &self,
        auth: &AuthenticatedDevice,
        req: CreateFileObjectRequest,
    ) -> Result<FileObjectView, String> {
        let uploader_device_id = normalize_device_id(&req.uploader_device_id);
        if uploader_device_id != auth.device_id {
            return Err("uploader_device_id должен совпадать с авторизованным устройством".to_string());
        }

        let mut tx = self.pool.begin().await.map_err(|e| e.to_string())?;

        sqlx::query(
            r#"
            INSERT INTO file_objects (
                file_id,
                uploader_user_id,
                uploader_device_id,
                object_key,
                media_type,
                file_name,
                ciphertext_size,
                chunk_size_bytes,
                total_chunks,
                ciphertext_sha256_hex,
                client_metadata
            )
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
            "#,
        )
        .bind(req.file_id.trim())
        .bind(auth.user_id)
        .bind(&uploader_device_id)
        .bind(req.object_key.trim())
        .bind(req.media_type.trim())
        .bind(req.file_name.trim())
        .bind(req.ciphertext_size)
        .bind(req.chunk_size_bytes)
        .bind(req.total_chunks)
        .bind(req.ciphertext_sha256_hex.trim())
        .bind(req.client_metadata.clone().unwrap_or_else(|| json!({})))
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;

        for env in req.recipient_key_envelopes {
            let recipient_user_id: Uuid = sqlx::query_scalar(
                "SELECT id FROM users WHERE public_id = $1",
            )
            .bind(env.recipient_public_id.trim())
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("Пользователь {} не найден", env.recipient_public_id))?;

            sqlx::query(
                r#"
                INSERT INTO file_key_envelopes (
                    file_id,
                    recipient_user_id,
                    recipient_device_id,
                    wrapped_file_key_b64,
                    server_metadata
                )
                VALUES ($1,$2,$3,$4,$5)
                "#,
            )
            .bind(req.file_id.trim())
            .bind(recipient_user_id)
            .bind(normalize_device_id(&env.recipient_device_id))
            .bind(env.wrapped_file_key_b64.trim())
            .bind(env.metadata.unwrap_or_else(|| json!({})))
            .execute(&mut *tx)
            .await
            .map_err(|e| e.to_string())?;
        }

        tx.commit().await.map_err(|e| e.to_string())?;
        self.get_file_for_recipient(auth, req.file_id.trim())
            .await
            .map(|r| r.file)
    }

    pub async fn complete_file_object(
        &self,
        auth: &AuthenticatedDevice,
        file_id: &str,
        upload_status: &str,
    ) -> Result<FileObjectView, String> {
        let row = sqlx::query(
            r#"
            UPDATE file_objects
            SET
                upload_status = $3,
                completed_at = CASE
                    WHEN $3 = 'completed' THEN COALESCE(completed_at, now())
                    ELSE completed_at
                END
            WHERE file_id = $1 AND uploader_user_id = $2
            RETURNING
                file_id,
                object_key,
                media_type,
                file_name,
                ciphertext_size,
                chunk_size_bytes,
                total_chunks,
                ciphertext_sha256_hex,
                upload_status,
                client_metadata,
                (EXTRACT(EPOCH FROM created_at) * 1000)::BIGINT AS created_at_ms,
                (EXTRACT(EPOCH FROM completed_at) * 1000)::BIGINT AS completed_at_ms
            "#,
        )
        .bind(file_id.trim())
        .bind(auth.user_id)
        .bind(upload_status.trim())
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Файл не найден".to_string())?;

        Ok(row_to_file_object(row))
    }

    pub async fn get_file_for_recipient(
        &self,
        auth: &AuthenticatedDevice,
        file_id: &str,
    ) -> Result<FileLookupResponse, String> {
        let file_row = sqlx::query(
            r#"
            SELECT
                file_id,
                object_key,
                media_type,
                file_name,
                ciphertext_size,
                chunk_size_bytes,
                total_chunks,
                ciphertext_sha256_hex,
                upload_status,
                client_metadata,
                (EXTRACT(EPOCH FROM created_at) * 1000)::BIGINT AS created_at_ms,
                (EXTRACT(EPOCH FROM completed_at) * 1000)::BIGINT AS completed_at_ms
            FROM file_objects
            WHERE file_id = $1
            "#,
        )
        .bind(file_id.trim())
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Файл не найден".to_string())?;

        let key_row = sqlx::query(
            r#"
            SELECT
                fke.file_id AS file_id,
                u.public_id AS recipient_public_id,
                fke.recipient_device_id AS recipient_device_id,
                fke.wrapped_file_key_b64 AS wrapped_file_key_b64,
                fke.server_metadata AS server_metadata,
                (EXTRACT(EPOCH FROM fke.created_at) * 1000)::BIGINT AS created_at_ms
            FROM file_key_envelopes fke
            INNER JOIN users u ON u.id = fke.recipient_user_id
            WHERE fke.file_id = $1
              AND fke.recipient_user_id = $2
              AND fke.recipient_device_id = $3
            "#,
        )
        .bind(file_id.trim())
        .bind(auth.user_id)
        .bind(&auth.device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(FileLookupResponse {
            file: row_to_file_object(file_row),
            key_envelope: key_row.map(row_to_file_key_envelope),
        })
    }
}

fn row_to_device_key_package(row: sqlx::postgres::PgRow) -> DeviceKeyPackageView {
    DeviceKeyPackageView {
        public_id: row.get("public_id"),
        device_id: row.get("device_id"),
        identity_key_alg: row.get("identity_key_alg"),
        identity_key_b64: row.get("identity_key_b64"),
        signed_prekey_b64: row.get("signed_prekey_b64"),
        signed_prekey_signature_b64: row.get("signed_prekey_signature_b64"),
        signed_prekey_key_id: row.get("signed_prekey_key_id"),
        one_time_prekeys: json_value_to_string_vec(row.get("one_time_prekeys")),
        updated_at: row.get::<i64, _>("updated_at_ms"),
    }
}

fn row_to_envelope(row: sqlx::postgres::PgRow) -> StoredEnvelopeView {
    StoredEnvelopeView {
        envelope_id: row.get("envelope_id"),
        conversation_id: row.get("conversation_id"),
        sender_public_id: row.get("sender_public_id"),
        sender_device_id: row.get("sender_device_id"),
        recipient_public_id: row.get("recipient_public_id"),
        recipient_device_id: row.get("recipient_device_id"),
        message_kind: row.get("message_kind"),
        protocol: row.get("protocol"),
        header_b64: row.get("header_b64"),
        ciphertext_b64: row.get("ciphertext_b64"),
        metadata: row.get("server_metadata"),
        created_at: row.get::<i64, _>("created_at_ms"),
        delivered_at: row.try_get::<Option<i64>, _>("delivered_at_ms").ok().flatten(),
        acked_at: row.try_get::<Option<i64>, _>("acked_at_ms").ok().flatten(),
        read_at: row.try_get::<Option<i64>, _>("read_at_ms").ok().flatten(),
        server_seq: row.get("server_seq"),
    }
}

fn row_to_file_object(row: sqlx::postgres::PgRow) -> FileObjectView {
    FileObjectView {
        file_id: row.get("file_id"),
        object_key: row.get("object_key"),
        media_type: row.get("media_type"),
        file_name: row.get("file_name"),
        ciphertext_size: row.get("ciphertext_size"),
        chunk_size_bytes: row.get("chunk_size_bytes"),
        total_chunks: row.get("total_chunks"),
        ciphertext_sha256_hex: row.get("ciphertext_sha256_hex"),
        upload_status: row.get("upload_status"),
        client_metadata: row.get("client_metadata"),
        created_at: row.get::<i64, _>("created_at_ms"),
        completed_at: row.try_get::<Option<i64>, _>("completed_at_ms").ok().flatten(),
    }
}

fn row_to_file_key_envelope(row: sqlx::postgres::PgRow) -> FileKeyEnvelopeView {
    FileKeyEnvelopeView {
        file_id: row.get("file_id"),
        recipient_public_id: row.get("recipient_public_id"),
        recipient_device_id: row.get("recipient_device_id"),
        wrapped_file_key_b64: row.get("wrapped_file_key_b64"),
        metadata: row.get("server_metadata"),
        created_at: row.get::<i64, _>("created_at_ms"),
    }
}

fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|v| v.to_string())
        .map_err(|e| e.to_string())
}

fn build_display_name(first_name: &str, last_name: &str) -> String {
    let full = format!("{} {}", first_name.trim(), last_name.trim())
        .trim()
        .to_string();
    if full.is_empty() {
        "User".to_string()
    } else {
        full
    }
}

fn random_upper_alnum(len: usize) -> String {
    rand::rng()
        .sample_iter(&Alphanumeric)
        .take(len)
        .map(char::from)
        .map(|c| c.to_ascii_uppercase())
        .collect()
}

fn generate_session_token() -> String {
    format!("st_{}", random_upper_alnum(48))
}

fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    let bytes = hasher.finalize();
    bytes.iter().map(|b| format!("{:02x}", b)).collect::<String>()
}

fn normalize_phone(phone: &str) -> Result<String, String> {
    let phone = phone.trim();
    if !phone.starts_with('+') || phone.len() < 8 {
        return Err("phone_e164 должен быть в формате E.164".to_string());
    }
    Ok(phone.to_string())
}

fn normalize_device_id(device_id: &str) -> String {
    device_id.trim().to_ascii_uppercase()
}

fn json_value_to_string_vec(value: Value) -> Vec<String> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|v| v.as_str().map(ToOwned::to_owned))
                .collect::<Vec<String>>()
        })
        .unwrap_or_default()
}