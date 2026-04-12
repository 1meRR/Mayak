use crate::domain::models::{
    AckEnvelopeResponse, CallInviteView, CreateCallInviteRequest, CreateFileObjectRequest,
    DeviceDirectoryView, DeviceKeyPackageView, FileKeyEnvelopeView, FileLookupResponse,
    FileObjectView, FriendRequestView, FriendUserView, FriendsBundleView, LoginResponse,
    RecipientEnvelopeInput, RegisterRequest, RespondCallInviteRequest, StoredEnvelopeView,
    UpsertDeviceKeyPackageRequest, UserProfileView,
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
        let parsed_hash = PasswordHash::new(&password_hash_value).map_err(|e| e.to_string())?;
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
            return Err(
                "device_id в bundle должен совпадать с авторизованным устройством".to_string(),
            );
        }

        sqlx::query(
            r#"
            INSERT INTO device_key_packages (
                user_id,
                device_id,
                identity_key_alg,
                identity_key_b64,
                identity_signing_key_b64,
                signed_prekey_b64,
                signed_prekey_signature_b64,
                signed_prekey_key_id,
                one_time_prekeys,
                updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now())
            ON CONFLICT (user_id, device_id)
            DO UPDATE SET
                identity_key_alg = EXCLUDED.identity_key_alg,
                identity_key_b64 = EXCLUDED.identity_key_b64,
                identity_signing_key_b64 = EXCLUDED.identity_signing_key_b64,
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
        .bind(
            req.identity_signing_key_b64
                .as_deref()
                .map(|v| v.trim())
                .filter(|v| !v.is_empty()),
        )
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

    pub async fn list_user_devices(
        &self,
        public_id: &str,
    ) -> Result<Vec<DeviceDirectoryView>, String> {
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

    pub async fn lookup_user_by_public_id(
        &self,
        public_id: &str,
    ) -> Result<FriendUserView, String> {
        self.lookup_user("u.public_id = $1", public_id.trim().to_uppercase())
            .await
    }

    pub async fn lookup_user_by_friend_code(
        &self,
        friend_code: &str,
    ) -> Result<FriendUserView, String> {
        self.lookup_user("u.friend_code = $1", friend_code.trim().to_uppercase())
            .await
    }

    async fn lookup_user(&self, where_expr: &str, value: String) -> Result<FriendUserView, String> {
        let sql = format!(
            r#"
            SELECT
                u.public_id AS public_id,
                u.friend_code AS friend_code,
                u.first_name AS first_name,
                u.last_name AS last_name,
                u.about AS about,
                (EXTRACT(EPOCH FROM u.created_at) * 1000)::BIGINT AS created_at_ms,
                MAX(d.last_seen_at) AS last_seen_at
            FROM users u
            LEFT JOIN devices d ON d.user_id = u.id
            WHERE {}
            GROUP BY u.public_id, u.friend_code, u.first_name, u.last_name, u.about, u.created_at
            "#,
            where_expr
        );

        let row = sqlx::query(&sql)
            .bind(&value)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Пользователь не найден".to_string())?;

        let first_name: String = row.get("first_name");
        let last_name: String = row.get("last_name");
        let last_seen_at = row
            .try_get::<chrono::DateTime<chrono::Utc>, _>("last_seen_at")
            .ok();

        Ok(FriendUserView {
            public_id: row.get("public_id"),
            friend_code: row.get("friend_code"),
            display_name: build_display_name(&first_name, &last_name),
            about: row.get("about"),
            created_at: row.get("created_at_ms"),
            is_online: false,
            last_seen_at: last_seen_at.map(|ts| ts.timestamp_millis()),
        })
    }

    pub async fn create_friend_request(
        &self,
        from_public_id: &str,
        from_device_id: &str,
        session_token: &str,
        to_public_id: &str,
    ) -> Result<FriendRequestView, String> {
        let from_public_id = from_public_id.trim().to_uppercase();
        let from_device_id = normalize_device_id(from_device_id);
        let to_public_id = to_public_id.trim().to_uppercase();
        self.validate_session(&from_public_id, &from_device_id, session_token)
            .await?;

        if from_public_id == to_public_id {
            return Err("Нельзя отправить заявку самому себе".to_string());
        }

        let from_user = self.fetch_user_meta_by_public_id(&from_public_id).await?;
        let to_user = self.fetch_user_meta_by_public_id(&to_public_id).await?;

        let exists = sqlx::query(
            r#"
            SELECT 1
            FROM friendships
            WHERE (user_low_id = LEAST($1, $2) AND user_high_id = GREATEST($1, $2))
            "#,
        )
        .bind(from_user.0)
        .bind(to_user.0)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        if exists.is_some() {
            return Err("Пользователь уже в друзьях".to_string());
        }

        let request_id = format!("FR{}", random_upper_alnum(12));
        let row = sqlx::query(
            r#"
            INSERT INTO friend_requests (request_id, from_user_id, to_user_id, status, created_at)
            VALUES ($1, $2, $3, 'pending', now())
            ON CONFLICT (request_id) DO NOTHING
            RETURNING
                request_id,
                status,
                (EXTRACT(EPOCH FROM created_at) * 1000)::BIGINT AS created_at_ms,
                (EXTRACT(EPOCH FROM responded_at) * 1000)::BIGINT AS responded_at_ms
            "#,
        )
        .bind(&request_id)
        .bind(from_user.0)
        .bind(to_user.0)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Не удалось создать заявку".to_string())?;

        Ok(FriendRequestView {
            id: row.get("request_id"),
            request_id: row.get("request_id"),
            from_public_id: from_public_id.clone(),
            from_display_name: from_user.1,
            to_public_id: to_public_id.clone(),
            to_display_name: to_user.1,
            status: row.get("status"),
            created_at: row.get("created_at_ms"),
            responded_at: row.try_get("responded_at_ms").ok(),
        })
    }

    pub async fn respond_friend_request(
        &self,
        request_id: &str,
        actor_public_id: &str,
        actor_device_id: &str,
        session_token: &str,
        action: &str,
    ) -> Result<FriendRequestView, String> {
        let actor_public_id = actor_public_id.trim().to_uppercase();
        let actor_device_id = normalize_device_id(actor_device_id);
        self.validate_session(&actor_public_id, &actor_device_id, session_token)
            .await?;

        let action = action.trim().to_lowercase();
        if action != "accept" && action != "reject" {
            return Err("action должен быть accept или reject".to_string());
        }

        let row = sqlx::query(
            r#"
            SELECT
                fr.from_user_id AS from_user_id,
                fr.to_user_id AS to_user_id,
                fr.status AS status
            FROM friend_requests fr
            WHERE fr.request_id = $1
            "#,
        )
        .bind(request_id.trim())
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Заявка не найдена".to_string())?;

        let from_user_id: Uuid = row.get("from_user_id");
        let to_user_id: Uuid = row.get("to_user_id");
        let status: String = row.get("status");
        if status != "pending" {
            return Err("Заявка уже обработана".to_string());
        }

        let actor_row = sqlx::query("SELECT id FROM users WHERE public_id = $1")
            .bind(&actor_public_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Пользователь не найден".to_string())?;

        let actor_id: Uuid = actor_row.get("id");
        if actor_id != to_user_id {
            return Err("Только получатель заявки может её обработать".to_string());
        }

        let next_status = if action == "accept" {
            "accepted"
        } else {
            "rejected"
        };

        sqlx::query(
            r#"
            UPDATE friend_requests
            SET status = $1, responded_at = now()
            WHERE request_id = $2
            "#,
        )
        .bind(next_status)
        .bind(request_id.trim())
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        if action == "accept" {
            sqlx::query(
                r#"
                INSERT INTO friendships (user_low_id, user_high_id, created_at)
                VALUES (LEAST($1, $2), GREATEST($1, $2), now())
                ON CONFLICT (user_low_id, user_high_id) DO NOTHING
                "#,
            )
            .bind(from_user_id)
            .bind(to_user_id)
            .execute(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
        }

        self.fetch_friend_request_view(request_id).await
    }

    pub async fn fetch_friends_bundle(&self, public_id: &str) -> Result<FriendsBundleView, String> {
        let public_id = public_id.trim().to_uppercase();
        let user_row = sqlx::query("SELECT id FROM users WHERE public_id = $1")
            .bind(&public_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Пользователь не найден".to_string())?;
        let user_id: Uuid = user_row.get("id");

        let friends_rows = sqlx::query(
            r#"
            SELECT
                u.public_id AS public_id,
                u.friend_code AS friend_code,
                u.first_name AS first_name,
                u.last_name AS last_name,
                u.about AS about,
                (EXTRACT(EPOCH FROM u.created_at) * 1000)::BIGINT AS created_at_ms,
                MAX(d.last_seen_at) AS last_seen_at
            FROM friendships f
            INNER JOIN users u
                ON u.id = CASE
                    WHEN f.user_low_id = $1 THEN f.user_high_id
                    ELSE f.user_low_id
                END
            LEFT JOIN devices d ON d.user_id = u.id
            WHERE f.user_low_id = $1 OR f.user_high_id = $1
            GROUP BY u.public_id, u.friend_code, u.first_name, u.last_name, u.about, u.created_at
            ORDER BY u.created_at DESC
            "#,
        )
        .bind(user_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        let incoming_rows = sqlx::query(
            r#"
            SELECT request_id
            FROM friend_requests
            WHERE to_user_id = $1 AND status = 'pending'
            ORDER BY created_at DESC
            "#,
        )
        .bind(user_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        let outgoing_rows = sqlx::query(
            r#"
            SELECT request_id
            FROM friend_requests
            WHERE from_user_id = $1 AND status = 'pending'
            ORDER BY created_at DESC
            "#,
        )
        .bind(user_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        let mut incoming_requests = Vec::with_capacity(incoming_rows.len());
        for row in incoming_rows {
            incoming_requests.push(
                self.fetch_friend_request_view(row.get("request_id"))
                    .await?,
            );
        }

        let mut outgoing_requests = Vec::with_capacity(outgoing_rows.len());
        for row in outgoing_rows {
            outgoing_requests.push(
                self.fetch_friend_request_view(row.get("request_id"))
                    .await?,
            );
        }

        let friends = friends_rows
            .into_iter()
            .map(|row| {
                let first_name: String = row.get("first_name");
                let last_name: String = row.get("last_name");
                let last_seen_at = row
                    .try_get::<chrono::DateTime<chrono::Utc>, _>("last_seen_at")
                    .ok()
                    .map(|ts| ts.timestamp_millis());
                FriendUserView {
                    public_id: row.get("public_id"),
                    friend_code: row.get("friend_code"),
                    display_name: build_display_name(&first_name, &last_name),
                    about: row.get("about"),
                    created_at: row.get("created_at_ms"),
                    is_online: false,
                    last_seen_at,
                }
            })
            .collect();

        Ok(FriendsBundleView {
            public_id,
            friends,
            incoming_requests,
            outgoing_requests,
        })
    }

    pub async fn delete_friend(
        &self,
        actor_public_id: &str,
        actor_device_id: &str,
        session_token: &str,
        friend_public_id: &str,
    ) -> Result<bool, String> {
        let actor_public_id = actor_public_id.trim().to_uppercase();
        let actor_device_id = normalize_device_id(actor_device_id);
        let friend_public_id = friend_public_id.trim().to_uppercase();
        self.validate_session(&actor_public_id, &actor_device_id, session_token)
            .await?;

        if actor_public_id == friend_public_id {
            return Err("Нельзя удалить себя из друзей".to_string());
        }

        let actor_user = self.fetch_user_meta_by_public_id(&actor_public_id).await?;
        let friend_user = self.fetch_user_meta_by_public_id(&friend_public_id).await?;

        let removed = sqlx::query(
            r#"
            DELETE FROM friendships
            WHERE user_low_id = LEAST($1, $2)
              AND user_high_id = GREATEST($1, $2)
            "#,
        )
        .bind(actor_user.0)
        .bind(friend_user.0)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(removed.rows_affected() > 0)
    }

    pub async fn create_call_invite(
        &self,
        req: CreateCallInviteRequest,
    ) -> Result<CallInviteView, String> {
        let caller_public_id = req.caller_public_id.trim().to_uppercase();
        let caller_device_id = normalize_device_id(&req.caller_device_id);
        let callee_public_id = req.callee_public_id.trim().to_uppercase();

        self.validate_session(&caller_public_id, &caller_device_id, &req.session_token)
            .await?;

        if caller_public_id == callee_public_id {
            return Err("Нельзя звонить самому себе".to_string());
        }

        let caller = self.fetch_user_meta_by_public_id(&caller_public_id).await?;
        let callee = self.fetch_user_meta_by_public_id(&callee_public_id).await?;

        let invite_id = format!("CALL{}", random_upper_alnum(14));
        let room_id = format!("ROOM{}", random_upper_alnum(16));

        sqlx::query(
            r#"
            INSERT INTO call_invites (
                invite_id, caller_user_id, callee_user_id, room_id, status, created_at
            )
            VALUES ($1, $2, $3, $4, 'pending', now())
            "#,
        )
        .bind(&invite_id)
        .bind(caller.0)
        .bind(callee.0)
        .bind(&room_id)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        self.fetch_call_invite(&invite_id).await
    }

    pub async fn fetch_call_invite(&self, invite_id: &str) -> Result<CallInviteView, String> {
        let row = sqlx::query(
            r#"
            SELECT
                ci.invite_id AS invite_id,
                cu.public_id AS caller_public_id,
                cu.first_name AS caller_first_name,
                cu.last_name AS caller_last_name,
                tu.public_id AS callee_public_id,
                tu.first_name AS callee_first_name,
                tu.last_name AS callee_last_name,
                ci.room_id AS room_id,
                ci.status AS status,
                (EXTRACT(EPOCH FROM ci.created_at) * 1000)::BIGINT AS created_at_ms,
                (EXTRACT(EPOCH FROM ci.responded_at) * 1000)::BIGINT AS responded_at_ms
            FROM call_invites ci
            INNER JOIN users cu ON cu.id = ci.caller_user_id
            INNER JOIN users tu ON tu.id = ci.callee_user_id
            WHERE ci.invite_id = $1
            "#,
        )
        .bind(invite_id.trim())
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Invite не найден".to_string())?;

        let caller_first_name: String = row.get("caller_first_name");
        let caller_last_name: String = row.get("caller_last_name");
        let callee_first_name: String = row.get("callee_first_name");
        let callee_last_name: String = row.get("callee_last_name");

        Ok(CallInviteView {
            invite_id: row.get("invite_id"),
            caller_public_id: row.get("caller_public_id"),
            caller_display_name: build_display_name(&caller_first_name, &caller_last_name),
            callee_public_id: row.get("callee_public_id"),
            callee_display_name: build_display_name(&callee_first_name, &callee_last_name),
            room_id: row.get("room_id"),
            status: row.get("status"),
            created_at: row.get("created_at_ms"),
            responded_at: row.try_get("responded_at_ms").ok(),
        })
    }

    pub async fn list_incoming_call_invites(
        &self,
        callee_public_id: &str,
    ) -> Result<Vec<CallInviteView>, String> {
        let rows = sqlx::query(
            r#"
            SELECT invite_id
            FROM call_invites ci
            INNER JOIN users u ON u.id = ci.callee_user_id
            WHERE u.public_id = $1
              AND ci.status = 'pending'
            ORDER BY ci.created_at DESC
            LIMIT 20
            "#,
        )
        .bind(callee_public_id.trim().to_uppercase())
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let invite_id: String = row.get("invite_id");
            items.push(self.fetch_call_invite(&invite_id).await?);
        }
        Ok(items)
    }

    pub async fn respond_call_invite(
        &self,
        req: RespondCallInviteRequest,
    ) -> Result<CallInviteView, String> {
        let actor_public_id = req.actor_public_id.trim().to_uppercase();
        let actor_device_id = normalize_device_id(&req.actor_device_id);
        self.validate_session(&actor_public_id, &actor_device_id, &req.session_token)
            .await?;

        let invite_row = sqlx::query(
            r#"
            SELECT
                ci.caller_user_id AS caller_user_id,
                ci.callee_user_id AS callee_user_id,
                ci.status AS status
            FROM call_invites ci
            WHERE ci.invite_id = $1
            "#,
        )
        .bind(req.invite_id.trim())
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Invite не найден".to_string())?;

        let actor_row = sqlx::query("SELECT id FROM users WHERE public_id = $1")
            .bind(&actor_public_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Пользователь не найден".to_string())?;
        let actor_id: Uuid = actor_row.get("id");

        let caller_user_id: Uuid = invite_row.get("caller_user_id");
        let callee_user_id: Uuid = invite_row.get("callee_user_id");
        let status: String = invite_row.get("status");
        if status != "pending" {
            return Err("Invite уже обработан".to_string());
        }

        if actor_id != callee_user_id && actor_id != caller_user_id {
            return Err("Нет доступа к invite".to_string());
        }

        let action = req.action.trim().to_lowercase();
        let next_status = match action.as_str() {
            "accept" => "accepted",
            "reject" => "rejected",
            _ => return Err("action должен быть accept или reject".to_string()),
        };

        sqlx::query(
            r#"
            UPDATE call_invites
            SET status = $1, responded_at = now()
            WHERE invite_id = $2
            "#,
        )
        .bind(next_status)
        .bind(req.invite_id.trim())
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        self.fetch_call_invite(req.invite_id.trim()).await
    }

    async fn validate_session(
        &self,
        public_id: &str,
        device_id: &str,
        session_token: &str,
    ) -> Result<(), String> {
        let token_hash = sha256_hex(session_token.trim());
        let row = sqlx::query(
            r#"
            SELECT 1
            FROM devices d
            INNER JOIN users u ON u.id = d.user_id
            WHERE u.public_id = $1 AND d.device_id = $2 AND d.session_token_hash = $3
            "#,
        )
        .bind(public_id.trim().to_uppercase())
        .bind(normalize_device_id(device_id))
        .bind(token_hash)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        if row.is_none() {
            return Err("Невалидная сессия".to_string());
        }
        Ok(())
    }

    async fn fetch_user_meta_by_public_id(
        &self,
        public_id: &str,
    ) -> Result<(Uuid, String), String> {
        let row = sqlx::query(
            r#"
            SELECT id, first_name, last_name
            FROM users
            WHERE public_id = $1
            "#,
        )
        .bind(public_id.trim().to_uppercase())
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Пользователь не найден".to_string())?;

        let first_name: String = row.get("first_name");
        let last_name: String = row.get("last_name");
        Ok((row.get("id"), build_display_name(&first_name, &last_name)))
    }

    async fn fetch_friend_request_view(
        &self,
        request_id: &str,
    ) -> Result<FriendRequestView, String> {
        let row = sqlx::query(
            r#"
            SELECT
                fr.request_id AS request_id,
                fr.status AS status,
                (EXTRACT(EPOCH FROM fr.created_at) * 1000)::BIGINT AS created_at_ms,
                (EXTRACT(EPOCH FROM fr.responded_at) * 1000)::BIGINT AS responded_at_ms,
                fu.public_id AS from_public_id,
                fu.first_name AS from_first_name,
                fu.last_name AS from_last_name,
                tu.public_id AS to_public_id,
                tu.first_name AS to_first_name,
                tu.last_name AS to_last_name
            FROM friend_requests fr
            INNER JOIN users fu ON fu.id = fr.from_user_id
            INNER JOIN users tu ON tu.id = fr.to_user_id
            WHERE fr.request_id = $1
            "#,
        )
        .bind(request_id.trim())
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Заявка не найдена".to_string())?;

        let from_first_name: String = row.get("from_first_name");
        let from_last_name: String = row.get("from_last_name");
        let to_first_name: String = row.get("to_first_name");
        let to_last_name: String = row.get("to_last_name");

        Ok(FriendRequestView {
            id: row.get("request_id"),
            request_id: row.get("request_id"),
            from_public_id: row.get("from_public_id"),
            from_display_name: build_display_name(&from_first_name, &from_last_name),
            to_public_id: row.get("to_public_id"),
            to_display_name: build_display_name(&to_first_name, &to_last_name),
            status: row.get("status"),
            created_at: row.get("created_at_ms"),
            responded_at: row.try_get("responded_at_ms").ok(),
        })
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
                k.identity_signing_key_b64 AS identity_signing_key_b64,
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
                k.identity_signing_key_b64 AS identity_signing_key_b64,
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
            identity_signing_key_b64: row
                .try_get::<Option<String>, _>("identity_signing_key_b64")
                .ok()
                .flatten(),
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
            return Err(
                "sender_device_id должен совпадать с авторизованным устройством".to_string(),
            );
        }

        let mut tx = self.pool.begin().await.map_err(|e| e.to_string())?;
        let mut stored = Vec::new();

        for recipient in recipients {
            let recipient_public_id = recipient.recipient_public_id.trim().to_string();
            let recipient_device_id = normalize_device_id(&recipient.recipient_device_id);
            let envelope_id = format!("ENV{}", random_upper_alnum(20));

            let recipient_user_id: Uuid =
                sqlx::query_scalar("SELECT id FROM users WHERE public_id = $1")
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
            return Err(
                "uploader_device_id должен совпадать с авторизованным устройством".to_string(),
            );
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
            let recipient_user_id: Uuid =
                sqlx::query_scalar("SELECT id FROM users WHERE public_id = $1")
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

    pub async fn ensure_file_uploader(
        &self,
        auth: &AuthenticatedDevice,
        file_id: &str,
    ) -> Result<(), String> {
        let exists: Option<i64> = sqlx::query_scalar(
            "SELECT 1 FROM file_objects WHERE file_id = $1 AND uploader_user_id = $2 AND uploader_device_id = $3",
        )
        .bind(file_id.trim())
        .bind(auth.user_id)
        .bind(&auth.device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        if exists.is_some() {
            Ok(())
        } else {
            Err("Нет доступа на upload file chunks".to_string())
        }
    }

    pub async fn ensure_file_downloadable(
        &self,
        auth: &AuthenticatedDevice,
        file_id: &str,
    ) -> Result<(), String> {
        let allowed: Option<i64> = sqlx::query_scalar(
            r#"
            SELECT 1
            FROM file_objects f
            WHERE f.file_id = $1
              AND (
                    (f.uploader_user_id = $2 AND f.uploader_device_id = $3)
                    OR EXISTS (
                        SELECT 1
                        FROM file_key_envelopes e
                        WHERE e.file_id = f.file_id
                          AND e.recipient_user_id = $2
                          AND e.recipient_device_id = $3
                    )
              )
            "#,
        )
        .bind(file_id.trim())
        .bind(auth.user_id)
        .bind(&auth.device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        if allowed.is_some() {
            Ok(())
        } else {
            Err("Нет доступа на download file content".to_string())
        }
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
        identity_signing_key_b64: row
            .try_get::<Option<String>, _>("identity_signing_key_b64")
            .ok()
            .flatten(),
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
        delivered_at: row
            .try_get::<Option<i64>, _>("delivered_at_ms")
            .ok()
            .flatten(),
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
        completed_at: row
            .try_get::<Option<i64>, _>("completed_at_ms")
            .ok()
            .flatten(),
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
    bytes
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<String>()
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
