use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use base64::{engine::general_purpose, Engine as _};
use password_hash::{rand_core::OsRng, SaltString};
use rand::Rng;
use std::path::{Path, PathBuf};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sqlx::{postgres::PgPoolOptions, PgPool, Row};

use crate::domain::models::{
    CallInviteView, DeviceResponse, DirectMessageRecord, FriendRequestView, FriendUserView,
    HealthCounts, MailboxAckResult, MailboxItemView, MediaFilePayload, MediaObjectView,
    PublicUserResponse, RecoveryCodeView, RepositoryCounts, RepositoryEvent, RepositoryUser,
    RepositorySyncCursor,
};

const PRESENCE_ONLINE_WINDOW_MS: i64 = 20_000;

#[derive(Clone)]
pub struct PostgresStore {
    pool: PgPool,
    node_id: String,
    media_dir: PathBuf,
}

pub struct RegisterResult {
    pub user: PublicUserResponse,
    pub device: DeviceResponse,
    pub recovery_codes: Vec<RecoveryCodeView>,
}

pub struct LoginResult {
    pub user: PublicUserResponse,
    pub device: DeviceResponse,
}

pub struct FriendsBundle {
    pub public_id: String,
    pub friends: Vec<FriendUserView>,
    pub incoming_requests: Vec<FriendRequestView>,
    pub outgoing_requests: Vec<FriendRequestView>,
}

impl PostgresStore {
    pub async fn from_env() -> Result<Self, String> {
        let database_url = std::env::var("DATABASE_URL")
            .map_err(|_| "DATABASE_URL не настроен".to_string())?;
        let node_id = std::env::var("MAYAK_NODE_ID")
            .ok()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| "mayak-main".to_string());

        let media_dir = std::env::var("MEDIA_DIR")
            .ok()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/opt/mayak/data/media"));

        let pool = PgPoolOptions::new()
            .max_connections(10)
            .connect(&database_url)
            .await
            .map_err(|e| format!("Не удалось подключиться к Postgres: {e}"))?;

        sqlx::query("SELECT 1")
            .execute(&pool)
            .await
            .map_err(|e| format!("Postgres ping failed: {e}"))?;

        std::fs::create_dir_all(&media_dir)
            .map_err(|e| format!("Не удалось создать MEDIA_DIR: {e}"))?;

        println!("[postgres-store] enabled for node_id={node_id}");
        Ok(Self { pool, node_id, media_dir })
    }

    pub async fn fetch_health_counts(&self) -> Result<HealthCounts, String> {
        let users_count = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users")
            .fetch_one(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
        let call_invites_count = sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM call_invites WHERE status = 'pending'",
        )
        .fetch_one(&self.pool)
        .await
        .unwrap_or(0);

        Ok(HealthCounts {
            users_count,
            call_invites_count,
        })
    }

    pub async fn fetch_counts(&self) -> Result<RepositoryCounts, String> {
        let row = sqlx::query(
            r#"
            SELECT
              (SELECT COUNT(*) FROM users) AS users_count,
              (SELECT COUNT(*) FROM devices) AS devices_count,
              (SELECT COUNT(*) FROM contacts WHERE state = 'accepted') AS contacts_count,
              (SELECT COUNT(*) FROM chats) AS chats_count,
              (SELECT COUNT(*) FROM events) AS events_count
            "#,
        )
        .fetch_one(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(RepositoryCounts {
            users_count: row.get("users_count"),
            devices_count: row.get("devices_count"),
            contacts_count: row.get("contacts_count"),
            chats_count: row.get("chats_count"),
            events_count: row.get("events_count"),
        })
    }

    pub async fn fetch_recent_events(&self, limit: i64) -> Result<Vec<RepositoryEvent>, String> {
        let rows = sqlx::query(
            r#"
            SELECT
                e.event_id,
                e.event_type,
                e.origin_node,
                c.chat_key,
                u.public_id AS author_public_id,
                to_char(e.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at
            FROM events e
            LEFT JOIN chats c ON c.id = e.chat_id
            LEFT JOIN users u ON u.id = e.author_user_id
            ORDER BY e.created_at DESC
            LIMIT $1
            "#,
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(rows
            .into_iter()
            .map(|row| RepositoryEvent {
                event_id: row.get("event_id"),
                event_type: row.get("event_type"),
                origin_node: row.get("origin_node"),
                chat_key: row.try_get("chat_key").ok(),
                author_public_id: row.try_get("author_public_id").ok(),
                created_at: row.get("created_at"),
            })
            .collect())
    }

    pub async fn fetch_recent_users(&self, limit: i64) -> Result<Vec<RepositoryUser>, String> {
        let rows = sqlx::query(
            r#"
            SELECT
                public_id,
                first_name,
                last_name,
                home_node,
                to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at
            FROM users
            ORDER BY created_at DESC
            LIMIT $1
            "#,
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(rows
            .into_iter()
            .map(|row| RepositoryUser {
                public_id: row.get("public_id"),
                first_name: row.get("first_name"),
                last_name: row.get("last_name"),
                home_node: row.get("home_node"),
                created_at: row.get("created_at"),
            })
            .collect())
    }

    pub async fn fetch_user_lookup(&self, public_id: &str) -> Result<Option<PublicUserResponse>, String> {
        let row = sqlx::query(
            r#"
            SELECT
                public_id,
                first_name,
                last_name,
                phone_e164,
                about,
                (extract(epoch from created_at) * 1000)::bigint AS created_at_ms,
                (extract(epoch from updated_at) * 1000)::bigint AS updated_at_ms
            FROM users
            WHERE public_id = $1
            "#,
        )
        .bind(public_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(row.map(|row| map_public_user_row(&row)))
    }

    pub async fn fetch_device(&self, device_id: &str) -> Result<Option<DeviceResponse>, String> {
        let row = sqlx::query(
            r#"
            SELECT
                d.device_id,
                u.public_id AS owner_public_id,
                d.platform,
                (extract(epoch from d.created_at) * 1000)::bigint AS created_at_ms,
                (extract(epoch from d.updated_at) * 1000)::bigint AS updated_at_ms
            FROM devices d
            JOIN users u ON u.id = d.user_id
            WHERE d.device_id = $1
            "#,
        )
        .bind(device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(row.map(|row| DeviceResponse {
            device_id: row.get("device_id"),
            owner_public_id: row.get("owner_public_id"),
            platform: row.get("platform"),
            created_at: row.get("created_at_ms"),
            updated_at: row.get("updated_at_ms"),
        }))
    }

    pub async fn register_user(
        &self,
        device_id: &str,
        first_name: &str,
        last_name: &str,
        phone: &str,
        password: &str,
        about: &str,
        platform: &str,
    ) -> Result<RegisterResult, String> {
        if first_name.trim().is_empty() {
            return Err("Имя обязательно".to_string());
        }
        let phone = normalize_phone(phone);
        if phone.is_empty() {
            return Err("Телефон обязателен".to_string());
        }
        if password.len() < 6 {
            return Err("Пароль должен быть не короче 6 символов".to_string());
        }

        let exists = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users WHERE phone_e164 = $1")
            .bind(&phone)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
        if exists > 0 {
            return Err("Пользователь с таким телефоном уже существует".to_string());
        }

        let public_id = generate_entity_id("M");
        let password_hash = hash_password(password)?;
        let about = if about.trim().is_empty() {
            "На связи в Маяке".to_string()
        } else {
            about.trim().to_string()
        };
        let device_id = if device_id.trim().is_empty() {
            generate_entity_id("D")
        } else {
            device_id.trim().to_string()
        };
        let recovery_codes = generate_recovery_codes();

        let mut tx = self.pool.begin().await.map_err(|e| e.to_string())?;
        sqlx::query(
            r#"
            INSERT INTO users (
                public_id, username, home_node, phone_e164, first_name, last_name, about,
                password_hash, password_algo, password_params
            ) VALUES ($1, NULL, $2, $3, $4, $5, $6, $7, 'argon2id', '{}'::jsonb)
            "#,
        )
        .bind(&public_id)
        .bind(&self.node_id)
        .bind(&phone)
        .bind(first_name.trim())
        .bind(last_name.trim())
        .bind(&about)
        .bind(&password_hash)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;

        sqlx::query(
            r#"
            INSERT INTO devices (user_id, device_id, platform, display_name, last_seen_at)
            VALUES ((SELECT id FROM users WHERE public_id = $1), $2, $3, '', now())
            ON CONFLICT (device_id)
            DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, updated_at = now(), last_seen_at = now()
            "#,
        )
        .bind(&public_id)
        .bind(&device_id)
        .bind(platform)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;

        for item in &recovery_codes {
            sqlx::query(
                "INSERT INTO recovery_codes (user_id, code_hash, code_plaintext) VALUES ((SELECT id FROM users WHERE public_id = $1), $2, $3)",
            )
            .bind(&public_id)
            .bind(hash_recovery_code(&item.code))
            .bind(&item.code)
            .execute(&mut *tx)
            .await
            .map_err(|e| e.to_string())?;
        }
        tx.commit().await.map_err(|e| e.to_string())?;

        let user = self.fetch_user_lookup(&public_id).await?.ok_or_else(|| "Пользователь не найден".to_string())?;
        let device = self.fetch_device(&device_id).await?.ok_or_else(|| "Устройство не найдено".to_string())?;

        Ok(RegisterResult { user, device, recovery_codes })
    }

    pub async fn login_user(&self, device_id: &str, phone: &str, password: &str, platform: &str) -> Result<LoginResult, String> {
        let phone = normalize_phone(phone);
        let row = sqlx::query("SELECT public_id, password_hash FROM users WHERE phone_e164 = $1")
            .bind(&phone)
            .fetch_optional(&self.pool)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "Пользователь не найден".to_string())?;
        let public_id: String = row.get("public_id");
        let password_hash: String = row.get("password_hash");
        verify_password(&password_hash, password)?;

        let device_id = if device_id.trim().is_empty() { generate_entity_id("D") } else { device_id.trim().to_string() };
        sqlx::query(
            r#"
            INSERT INTO devices (user_id, device_id, platform, display_name, last_seen_at)
            VALUES ((SELECT id FROM users WHERE public_id = $1), $2, $3, '', now())
            ON CONFLICT (device_id)
            DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, updated_at = now(), last_seen_at = now()
            "#,
        )
        .bind(&public_id)
        .bind(&device_id)
        .bind(platform)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        let user = self.fetch_user_lookup(&public_id).await?.ok_or_else(|| "Пользователь не найден".to_string())?;
        let device = self.fetch_device(&device_id).await?.ok_or_else(|| "Устройство не найдено".to_string())?;
        Ok(LoginResult { user, device })
    }

    pub async fn reset_password(&self, phone: &str, recovery_code: &str, new_password: &str) -> Result<(), String> {
        if new_password.len() < 6 {
            return Err("Новый пароль должен быть не короче 6 символов".to_string());
        }
        let phone = normalize_phone(phone);
        let recovery_code_hash = hash_recovery_code(recovery_code);

        let row = sqlx::query(
            r#"
            SELECT u.public_id AS public_id
            FROM users u
            JOIN recovery_codes rc ON rc.user_id = u.id
            WHERE u.phone_e164 = $1
              AND rc.code_hash = $2
              AND rc.used_at IS NULL
            LIMIT 1
            "#,
        )
        .bind(&phone)
        .bind(&recovery_code_hash)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Неверный код восстановления".to_string())?;

        let public_id: String = row.get("public_id");
        let new_hash = hash_password(new_password)?;

        let mut tx = self.pool.begin().await.map_err(|e| e.to_string())?;
        sqlx::query(
            r#"
            UPDATE users
            SET password_hash = $1,
                password_algo = 'argon2id',
                password_params = '{}'::jsonb,
                updated_at = now()
            WHERE public_id = $2
            "#,
        )
        .bind(&new_hash)
        .bind(&public_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
        sqlx::query(
            r#"
            UPDATE recovery_codes
            SET used_at = now()
            WHERE user_id = (SELECT id FROM users WHERE public_id = $1)
              AND code_hash = $2
              AND used_at IS NULL
            "#,
        )
        .bind(&public_id)
        .bind(&recovery_code_hash)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
        tx.commit().await.map_err(|e| e.to_string())?;
        Ok(())
    }

    pub async fn list_admin_users(&self) -> Result<Vec<(PublicUserResponse, Vec<RecoveryCodeView>)>, String> {
        let rows = sqlx::query(
            r#"
            SELECT public_id FROM users ORDER BY created_at DESC
            "#,
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        let mut items = Vec::new();
        for row in rows {
            let public_id: String = row.get("public_id");
            let user = self.fetch_user_lookup(&public_id).await?.ok_or_else(|| "Пользователь не найден".to_string())?;
            let codes_rows = sqlx::query(
                r#"
                SELECT code_plaintext, (used_at IS NOT NULL) AS is_used,
                       (extract(epoch from created_at) * 1000)::bigint AS created_at_ms,
                       CASE WHEN used_at IS NULL THEN NULL ELSE (extract(epoch from used_at) * 1000)::bigint END AS used_at_ms
                FROM recovery_codes
                WHERE user_id = (SELECT id FROM users WHERE public_id = $1)
                ORDER BY created_at ASC
                "#,
            )
            .bind(&public_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
            let codes = codes_rows.into_iter().map(|r| RecoveryCodeView {
                code: r.get("code_plaintext"),
                is_used: r.get("is_used"),
                created_at: r.get("created_at_ms"),
                used_at: r.try_get::<i64,_>("used_at_ms").ok(),
            }).collect();
            items.push((user, codes));
        }
        Ok(items)
    }

    pub async fn heartbeat(&self, public_id: &str, device_id: &str) -> Result<(String, String, i64, bool), String> {
        let exists = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users WHERE public_id = $1")
            .bind(public_id)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
        if exists == 0 { return Err("Пользователь не найден".to_string()); }
        sqlx::query(
            r#"
            INSERT INTO devices (user_id, device_id, platform, display_name, last_seen_at)
            VALUES ((SELECT id FROM users WHERE public_id = $1), $2, 'unknown', '', now())
            ON CONFLICT (device_id)
            DO UPDATE SET user_id = EXCLUDED.user_id, last_seen_at = now(), updated_at = now()
            "#,
        )
        .bind(public_id)
        .bind(device_id)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        Ok((public_id.to_string(), device_id.to_string(), current_timestamp_ms(), true))
    }

    pub async fn create_friend_request(&self, from_public_id: &str, to_public_id: &str) -> Result<FriendRequestView, String> {
        if from_public_id == to_public_id { return Err("Нельзя добавить самого себя".to_string()); }
        let pending = sqlx::query_scalar::<_, i64>(
            r#"
            SELECT COUNT(*) FROM friend_requests
            WHERE status = 'pending'
              AND ((from_user_id = (SELECT id FROM users WHERE public_id = $1) AND to_user_id = (SELECT id FROM users WHERE public_id = $2))
                OR (from_user_id = (SELECT id FROM users WHERE public_id = $2) AND to_user_id = (SELECT id FROM users WHERE public_id = $1)))
            "#,
        )
        .bind(from_public_id)
        .bind(to_public_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        if pending > 0 { return Err("Заявка уже существует".to_string()); }
        let request_id = generate_entity_id("FR");
        sqlx::query(
            r#"
            INSERT INTO friend_requests (request_id, from_user_id, to_user_id, status)
            VALUES ($1, (SELECT id FROM users WHERE public_id = $2), (SELECT id FROM users WHERE public_id = $3), 'pending')
            "#,
        )
        .bind(&request_id)
        .bind(from_public_id)
        .bind(to_public_id)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        self.fetch_friend_request_view(&request_id).await?.ok_or_else(|| "Заявка не найдена".to_string())
    }

    pub async fn respond_friend_request(&self, request_id: &str, actor_public_id: &str, action: &str) -> Result<FriendRequestView, String> {
        if action != "accept" && action != "reject" { return Err("action должен быть accept или reject".to_string()); }
        let row = sqlx::query(
            r#"
            SELECT fu.public_id AS from_public_id, tu.public_id AS to_public_id, fr.status
            FROM friend_requests fr
            JOIN users fu ON fu.id = fr.from_user_id
            JOIN users tu ON tu.id = fr.to_user_id
            WHERE fr.request_id = $1
            "#,
        )
        .bind(request_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Заявка не найдена".to_string())?;
        let from_public_id: String = row.get("from_public_id");
        let to_public_id: String = row.get("to_public_id");
        let status: String = row.get("status");
        if status != "pending" { return Err("Заявка уже обработана".to_string()); }
        if to_public_id != actor_public_id { return Err("Только получатель заявки может её обработать".to_string()); }
        let mut tx = self.pool.begin().await.map_err(|e| e.to_string())?;
        sqlx::query("UPDATE friend_requests SET status = $1, responded_at = now() WHERE request_id = $2")
            .bind(if action == "accept" { "accepted" } else { "rejected" })
            .bind(request_id)
            .execute(&mut *tx)
            .await
            .map_err(|e| e.to_string())?;
        if action == "accept" {
            for (owner, contact) in [(&from_public_id, &to_public_id), (&to_public_id, &from_public_id)] {
                sqlx::query(
                    r#"
                    INSERT INTO contacts (owner_user_id, contact_user_id, state)
                    VALUES ((SELECT id FROM users WHERE public_id = $1), (SELECT id FROM users WHERE public_id = $2), 'accepted')
                    ON CONFLICT (owner_user_id, contact_user_id)
                    DO UPDATE SET state = 'accepted', updated_at = now()
                    "#,
                )
                .bind(owner)
                .bind(contact)
                .execute(&mut *tx)
                .await
                .map_err(|e| e.to_string())?;
            }
        }
        tx.commit().await.map_err(|e| e.to_string())?;
        self.fetch_friend_request_view(request_id).await?.ok_or_else(|| "Заявка не найдена".to_string())
    }

    pub async fn fetch_friends(&self, public_id: &str) -> Result<FriendsBundle, String> {
        let exists = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users WHERE public_id = $1")
            .bind(public_id)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
        if exists == 0 { return Err("Пользователь не найден".to_string()); }

        let rows = sqlx::query(
            r#"
            SELECT
                u.public_id,
                u.first_name,
                u.last_name,
                u.about,
                MAX((extract(epoch from d.last_seen_at) * 1000)::bigint) AS last_seen_at_ms
            FROM contacts c
            JOIN users u ON u.id = c.contact_user_id
            LEFT JOIN devices d ON d.user_id = u.id
            WHERE c.owner_user_id = (SELECT id FROM users WHERE public_id = $1)
              AND c.state = 'accepted'
            GROUP BY u.public_id, u.first_name, u.last_name, u.about
            ORDER BY u.first_name, u.last_name, u.public_id
            "#,
        )
        .bind(public_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        let now = current_timestamp_ms();
        let friends = rows.into_iter().map(|row| {
            let pid: String = row.get("public_id");
            let first_name: String = row.get("first_name");
            let last_name: String = row.get("last_name");
            let last_seen_at = row.try_get::<i64,_>("last_seen_at_ms").ok();
            FriendUserView {
                public_id: pid.clone(),
                display_name: build_display_name(&first_name, &last_name, &pid),
                about: row.get("about"),
                is_online: last_seen_at.map(|ts| now - ts <= PRESENCE_ONLINE_WINDOW_MS).unwrap_or(false),
                last_seen_at,
            }
        }).collect::<Vec<_>>();

        let incoming_requests = self.fetch_request_list(public_id, true).await?;
        let outgoing_requests = self.fetch_request_list(public_id, false).await?;
        Ok(FriendsBundle { public_id: public_id.to_string(), friends, incoming_requests, outgoing_requests })
    }

    pub async fn send_direct_message(&self, from_public_id: &str, to_public_id: &str, text: &str) -> Result<(String, DirectMessageRecord), String> {
        if text.trim().is_empty() { return Err("text обязателен".to_string()); }
        if from_public_id != to_public_id {
            let are_friends = sqlx::query_scalar::<_, i64>(
                r#"
                SELECT COUNT(*) FROM contacts
                WHERE owner_user_id = (SELECT id FROM users WHERE public_id = $1)
                  AND contact_user_id = (SELECT id FROM users WHERE public_id = $2)
                  AND state = 'accepted'
                "#,
            )
            .bind(from_public_id)
            .bind(to_public_id)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
            if are_friends == 0 { return Err("Сообщения доступны только друзьям".to_string()); }
        }

        let chat_id = build_direct_chat_id(from_public_id, to_public_id);
        let message = DirectMessageRecord {
            id: generate_entity_id("MSG"),
            chat_id: chat_id.clone(),
            from_public_id: from_public_id.to_string(),
            to_public_id: to_public_id.to_string(),
            text: text.trim().to_string(),
            created_at: current_timestamp_ms(),
        };
        let payload = serde_json::to_value(&message).map_err(|e| e.to_string())?;

        let mut tx = self.pool.begin().await.map_err(|e| e.to_string())?;
        sqlx::query(
            r#"
            INSERT INTO chats (chat_key, chat_type, created_by)
            VALUES ($1, 'direct', (SELECT id FROM users WHERE public_id = $2))
            ON CONFLICT (chat_key)
            DO UPDATE SET updated_at = now()
            "#,
        )
        .bind(&chat_id)
        .bind(from_public_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
        for member in [from_public_id, to_public_id] {
            sqlx::query(
                r#"
                INSERT INTO chat_members (chat_id, user_id, role)
                VALUES ((SELECT id FROM chats WHERE chat_key = $1), (SELECT id FROM users WHERE public_id = $2), 'member')
                ON CONFLICT (chat_id, user_id)
                DO UPDATE SET role = 'member', left_at = NULL
                "#,
            )
            .bind(&chat_id)
            .bind(member)
            .execute(&mut *tx)
            .await
            .map_err(|e| e.to_string())?;
        }
        sqlx::query(
            r#"
            INSERT INTO events (event_id, chat_id, author_user_id, author_device_id, event_type, payload, plaintext_preview, previous_event_id, origin_node, created_at, server_received_at, is_deleted)
            VALUES ($1, (SELECT id FROM chats WHERE chat_key = $2), (SELECT id FROM users WHERE public_id = $3), NULL, 'message.text', $4, $5, NULL, $6, to_timestamp($7::double precision / 1000.0), to_timestamp($7::double precision / 1000.0), false)
            "#,
        )
        .bind(&message.id)
        .bind(&chat_id)
        .bind(from_public_id)
        .bind(sqlx::types::Json(payload.clone()))
        .bind(text.trim())
        .bind(&self.node_id)
        .bind(message.created_at as f64)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
        self.enqueue_mailbox_for_public_id(&mut tx, to_public_id, &message.id, &chat_id, "message.text", &payload)
            .await?;
        tx.commit().await.map_err(|e| e.to_string())?;
        Ok((chat_id, message))
    }

    pub async fn fetch_chat_messages(&self, chat_id: &str) -> Result<Vec<DirectMessageRecord>, String> {
        let rows = sqlx::query(
            r#"
            SELECT payload FROM events
            WHERE chat_id = (SELECT id FROM chats WHERE chat_key = $1)
              AND event_type IN ('message.text', 'legacy.message')
              AND is_deleted = false
            ORDER BY created_at ASC
            "#,
        )
        .bind(chat_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        let mut items = Vec::new();
        for row in rows {
            let payload: Value = row.get("payload");
            items.push(serde_json::from_value(payload).map_err(|e| e.to_string())?);
        }
        Ok(items)
    }


    pub async fn upload_media(
        &self,
        owner_public_id: &str,
        owner_device_id: &str,
        media_kind: &str,
        content_type: &str,
        file_name: &str,
        base64_data: &str,
    ) -> Result<MediaObjectView, String> {
        let media_kind = media_kind.trim().to_lowercase();
        if !matches!(media_kind.as_str(), "image" | "video" | "audio" | "file") {
            return Err("mediaKind должен быть image, video, audio или file".to_string());
        }
        let content_type = content_type.trim().to_string();
        if content_type.is_empty() {
            return Err("contentType обязателен".to_string());
        }
        let safe_file_name = sanitize_file_name(file_name);
        if safe_file_name.is_empty() {
            return Err("fileName обязателен".to_string());
        }
        let bytes = general_purpose::STANDARD
            .decode(base64_data.trim())
            .map_err(|e| format!("base64 повреждён: {e}"))?;
        if bytes.is_empty() {
            return Err("Файл пустой".to_string());
        }

        let media_id = generate_entity_id("MEDIA");
        let sha256_hex = sha256_hex(&bytes);
        let storage_key = build_storage_key(&media_id, &safe_file_name);
        let abs_path = self.media_dir.join(&storage_key);
        if let Some(parent) = abs_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        std::fs::write(&abs_path, &bytes).map_err(|e| format!("Не удалось сохранить файл: {e}"))?;

        sqlx::query(
            r#"
            INSERT INTO media_objects (
                media_id, owner_user_id, owner_device_id, media_kind, content_type,
                file_name, file_size_bytes, storage_key, sha256_hex
            )
            VALUES (
                $1,
                (SELECT id FROM users WHERE public_id = $2),
                (SELECT id FROM devices WHERE device_id = $3),
                $4, $5, $6, $7, $8, $9
            )
            "#,
        )
        .bind(&media_id)
        .bind(owner_public_id)
        .bind(owner_device_id)
        .bind(&media_kind)
        .bind(&content_type)
        .bind(&safe_file_name)
        .bind(bytes.len() as i64)
        .bind(&storage_key)
        .bind(&sha256_hex)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        self.fetch_media_object(&media_id)
            .await?
            .ok_or_else(|| "Медиа не найдено".to_string())
    }

    pub async fn fetch_media_object(&self, media_id: &str) -> Result<Option<MediaObjectView>, String> {
        let row = sqlx::query(
            r#"
            SELECT mo.media_id,
                   u.public_id AS owner_public_id,
                   d.device_id AS owner_device_id,
                   mo.media_kind,
                   mo.content_type,
                   mo.file_name,
                   mo.file_size_bytes,
                   mo.sha256_hex,
                   mo.storage_key,
                   (extract(epoch from mo.created_at) * 1000)::bigint AS created_at_ms
            FROM media_objects mo
            JOIN users u ON u.id = mo.owner_user_id
            LEFT JOIN devices d ON d.id = mo.owner_device_id
            WHERE mo.media_id = $1
            "#,
        )
        .bind(media_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(row.map(|row| MediaObjectView {
            media_id: row.get("media_id"),
            owner_public_id: row.get("owner_public_id"),
            owner_device_id: row.try_get("owner_device_id").ok(),
            media_kind: row.get("media_kind"),
            content_type: row.get("content_type"),
            file_name: row.get("file_name"),
            file_size_bytes: row.get("file_size_bytes"),
            sha256_hex: row.get("sha256_hex"),
            created_at: row.get("created_at_ms"),
            download_url: format!("/api/media/file/{}", row.get::<String,_>("media_id")),
        }))
    }

    pub async fn read_media_file(&self, media_id: &str) -> Result<MediaFilePayload, String> {
        let row = sqlx::query(
            r#"
            SELECT content_type, file_name, storage_key
            FROM media_objects
            WHERE media_id = $1
            "#,
        )
        .bind(media_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Файл не найден".to_string())?;

        let content_type: String = row.get("content_type");
        let file_name: String = row.get("file_name");
        let storage_key: String = row.get("storage_key");
        let abs_path = self.media_dir.join(&storage_key);
        let bytes = std::fs::read(&abs_path).map_err(|e| format!("Не удалось прочитать файл: {e}"))?;

        Ok(MediaFilePayload { content_type, file_name, bytes })
    }

    pub async fn send_media_message(
        &self,
        from_public_id: &str,
        to_public_id: &str,
        media_id: &str,
        text: &str,
    ) -> Result<(String, String), String> {
        if from_public_id != to_public_id {
            let are_friends = sqlx::query_scalar::<_, i64>(
                r#"
                SELECT COUNT(*) FROM contacts
                WHERE owner_user_id = (SELECT id FROM users WHERE public_id = $1)
                  AND contact_user_id = (SELECT id FROM users WHERE public_id = $2)
                  AND state = 'accepted'
                "#,
            )
            .bind(from_public_id)
            .bind(to_public_id)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
            if are_friends == 0 { return Err("Сообщения доступны только друзьям".to_string()); }
        }
        let media = self
            .fetch_media_object(media_id)
            .await?
            .ok_or_else(|| "Медиа не найдено".to_string())?;
        let chat_id = build_direct_chat_id(from_public_id, to_public_id);
        let event_id = generate_entity_id("MSG");
        let created_at = current_timestamp_ms();
        let payload = serde_json::json!({
            "id": event_id,
            "chatId": chat_id,
            "fromPublicId": from_public_id,
            "toPublicId": to_public_id,
            "text": text.trim(),
            "mediaId": media.media_id,
            "mediaKind": media.media_kind,
            "contentType": media.content_type,
            "fileName": media.file_name,
            "createdAt": created_at,
        });

        let mut tx = self.pool.begin().await.map_err(|e| e.to_string())?;
        sqlx::query(
            r#"
            INSERT INTO chats (chat_key, chat_type, created_by)
            VALUES ($1, 'direct', (SELECT id FROM users WHERE public_id = $2))
            ON CONFLICT (chat_key)
            DO UPDATE SET updated_at = now()
            "#,
        )
        .bind(&chat_id)
        .bind(from_public_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
        for member in [from_public_id, to_public_id] {
            sqlx::query(
                r#"
                INSERT INTO chat_members (chat_id, user_id, role)
                VALUES ((SELECT id FROM chats WHERE chat_key = $1), (SELECT id FROM users WHERE public_id = $2), 'member')
                ON CONFLICT (chat_id, user_id)
                DO UPDATE SET role = 'member', left_at = NULL
                "#,
            )
            .bind(&chat_id)
            .bind(member)
            .execute(&mut *tx)
            .await
            .map_err(|e| e.to_string())?;
        }
        sqlx::query(
            r#"
            INSERT INTO events (event_id, chat_id, author_user_id, author_device_id, event_type, payload, plaintext_preview, previous_event_id, origin_node, created_at, server_received_at, is_deleted)
            VALUES ($1, (SELECT id FROM chats WHERE chat_key = $2), (SELECT id FROM users WHERE public_id = $3), NULL, 'message.media', $4, $5, NULL, $6, to_timestamp($7::double precision / 1000.0), to_timestamp($7::double precision / 1000.0), false)
            "#,
        )
        .bind(&event_id)
        .bind(&chat_id)
        .bind(from_public_id)
        .bind(sqlx::types::Json(payload.clone()))
        .bind(text.trim())
        .bind(&self.node_id)
        .bind(created_at as f64)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
        self.enqueue_mailbox_for_public_id(&mut tx, to_public_id, &event_id, &chat_id, "message.media", &payload)
            .await?;
        tx.commit().await.map_err(|e| e.to_string())?;
        Ok((chat_id, event_id))
    }

    pub async fn fetch_mailbox(&self, device_id: &str, limit: i64) -> Result<Vec<MailboxItemView>, String> {
        let rows = sqlx::query(
            r#"
            SELECT mi.mailbox_id, mi.event_id, mi.chat_key, mi.event_type, mi.payload, mi.status,
                   (extract(epoch from mi.created_at) * 1000)::bigint AS created_at_ms,
                   CASE WHEN mi.delivered_at IS NULL THEN NULL ELSE (extract(epoch from mi.delivered_at) * 1000)::bigint END AS delivered_at_ms,
                   CASE WHEN mi.acked_at IS NULL THEN NULL ELSE (extract(epoch from mi.acked_at) * 1000)::bigint END AS acked_at_ms
            FROM mailbox_items mi
            JOIN devices d ON d.id = mi.target_device_id
            WHERE d.device_id = $1
            ORDER BY mi.created_at ASC
            LIMIT $2
            "#,
        )
        .bind(device_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        Ok(rows.into_iter().map(|row| MailboxItemView {
            mailbox_id: row.get("mailbox_id"),
            event_id: row.get("event_id"),
            chat_key: row.get("chat_key"),
            event_type: row.get("event_type"),
            payload: row.get("payload"),
            status: row.get("status"),
            created_at: row.get("created_at_ms"),
            delivered_at: row.try_get::<i64,_>("delivered_at_ms").ok(),
            acked_at: row.try_get::<i64,_>("acked_at_ms").ok(),
        }).collect())
    }

    pub async fn ack_mailbox(&self, device_id: &str, mailbox_ids: &[String]) -> Result<MailboxAckResult, String> {
        if mailbox_ids.is_empty() {
            return Ok(MailboxAckResult { acked_count: 0 });
        }
        let result = sqlx::query(
            r#"
            UPDATE mailbox_items mi
            SET status = 'acked', acked_at = now(), delivered_at = COALESCE(delivered_at, now())
            WHERE mi.mailbox_id = ANY($1)
              AND mi.target_device_id = (SELECT id FROM devices WHERE device_id = $2)
            "#,
        )
        .bind(mailbox_ids)
        .bind(device_id)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        Ok(MailboxAckResult { acked_count: result.rows_affected() as i64 })
    }

    pub async fn fetch_sync_cursors(&self, device_id: &str) -> Result<Vec<RepositorySyncCursor>, String> {
        let rows = sqlx::query(
            r#"
            SELECT d.device_id, sc.stream_key, sc.cursor_value,
                   (extract(epoch from sc.updated_at) * 1000)::bigint AS updated_at_ms
            FROM sync_cursors sc
            JOIN devices d ON d.id = sc.device_id
            WHERE d.device_id = $1
            ORDER BY sc.stream_key ASC
            "#,
        )
        .bind(device_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        Ok(rows.into_iter().map(|row| RepositorySyncCursor {
            device_id: row.get("device_id"),
            stream_key: row.get("stream_key"),
            cursor_value: row.get("cursor_value"),
            updated_at: row.get("updated_at_ms"),
        }).collect())
    }

    pub async fn upsert_sync_cursor(&self, device_id: &str, stream_key: &str, cursor_value: &str) -> Result<RepositorySyncCursor, String> {
        sqlx::query(
            r#"
            INSERT INTO sync_cursors (device_id, stream_key, cursor_value)
            VALUES ((SELECT id FROM devices WHERE device_id = $1), $2, $3)
            ON CONFLICT (device_id, stream_key)
            DO UPDATE SET cursor_value = EXCLUDED.cursor_value, updated_at = now()
            "#,
        )
        .bind(device_id)
        .bind(stream_key)
        .bind(cursor_value)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;

        let rows = self.fetch_sync_cursors(device_id).await?;
        rows.into_iter()
            .find(|item| item.stream_key == stream_key)
            .ok_or_else(|| "sync cursor не найден".to_string())
    }

    async fn enqueue_mailbox_for_public_id(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        target_public_id: &str,
        event_id: &str,
        chat_key: &str,
        event_type: &str,
        payload: &Value,
    ) -> Result<(), String> {
        let rows = sqlx::query(
            r#"
            SELECT d.id::text AS target_device_id
            FROM devices d
            JOIN users u ON u.id = d.user_id
            WHERE u.public_id = $1
            "#,
        )
        .bind(target_public_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(|e| e.to_string())?;

        for row in rows {
            let target_device_id: String = row.get("target_device_id");
            sqlx::query(
                r#"
                INSERT INTO mailbox_items (
                    mailbox_id, target_device_id, event_id, chat_key, event_type, payload, status
                )
                VALUES ($1, $2::uuid, $3, $4, $5, $6, 'pending')
                ON CONFLICT (mailbox_id) DO NOTHING
                "#,
            )
            .bind(generate_entity_id("MBX"))
            .bind(&target_device_id)
            .bind(event_id)
            .bind(chat_key)
            .bind(event_type)
            .bind(sqlx::types::Json(payload.clone()))
            .execute(&mut **tx)
            .await
            .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    pub async fn create_call_invite(&self, caller_public_id: &str, callee_public_id: &str) -> Result<CallInviteView, String> {
        if caller_public_id == callee_public_id { return Err("Нельзя звонить самому себе".to_string()); }
        let are_friends = sqlx::query_scalar::<_, i64>(
            r#"
            SELECT COUNT(*) FROM contacts
            WHERE owner_user_id = (SELECT id FROM users WHERE public_id = $1)
              AND contact_user_id = (SELECT id FROM users WHERE public_id = $2)
              AND state = 'accepted'
            "#,
        )
        .bind(caller_public_id)
        .bind(callee_public_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        if are_friends == 0 { return Err("Звонок доступен только друзьям".to_string()); }
        let invite_id = generate_entity_id("CALL");
        let room_id = build_direct_room_id(caller_public_id, callee_public_id);
        sqlx::query(
            r#"
            INSERT INTO call_invites (invite_id, caller_user_id, callee_user_id, room_id, status)
            VALUES ($1, (SELECT id FROM users WHERE public_id = $2), (SELECT id FROM users WHERE public_id = $3), $4, 'pending')
            "#,
        )
        .bind(&invite_id)
        .bind(caller_public_id)
        .bind(callee_public_id)
        .bind(&room_id)
        .execute(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        self.fetch_call_invite(&invite_id).await?.ok_or_else(|| "Приглашение не найдено".to_string())
    }

    pub async fn respond_call_invite(&self, invite_id: &str, actor_public_id: &str, action: &str) -> Result<CallInviteView, String> {
        if action != "accept" && action != "reject" { return Err("action должен быть accept или reject".to_string()); }
        let row = sqlx::query(
            r#"
            SELECT tu.public_id AS callee_public_id, ci.status
            FROM call_invites ci
            JOIN users tu ON tu.id = ci.callee_user_id
            WHERE ci.invite_id = $1
            "#,
        )
        .bind(invite_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Приглашение не найдено".to_string())?;
        let callee_public_id: String = row.get("callee_public_id");
        let status: String = row.get("status");
        if status != "pending" { return Err("Приглашение уже обработано".to_string()); }
        if callee_public_id != actor_public_id { return Err("Только вызываемый пользователь может обработать приглашение".to_string()); }
        sqlx::query("UPDATE call_invites SET status = $1, responded_at = now() WHERE invite_id = $2")
            .bind(if action == "accept" { "accepted" } else { "rejected" })
            .bind(invite_id)
            .execute(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
        self.fetch_call_invite(invite_id).await?.ok_or_else(|| "Приглашение не найдено".to_string())
    }

    pub async fn fetch_incoming_calls(&self, public_id: &str) -> Result<Vec<CallInviteView>, String> {
        let rows = sqlx::query(
            r#"
            SELECT ci.invite_id, ci.room_id, ci.status,
                   (extract(epoch from ci.created_at) * 1000)::bigint AS created_at_ms,
                   CASE WHEN ci.responded_at IS NULL THEN NULL ELSE (extract(epoch from ci.responded_at) * 1000)::bigint END AS responded_at_ms,
                   cu.public_id AS caller_public_id, cu.first_name AS caller_first_name, cu.last_name AS caller_last_name,
                   tu.public_id AS callee_public_id, tu.first_name AS callee_first_name, tu.last_name AS callee_last_name
            FROM call_invites ci
            JOIN users cu ON cu.id = ci.caller_user_id
            JOIN users tu ON tu.id = ci.callee_user_id
            WHERE tu.public_id = $1 AND ci.status = 'pending'
            ORDER BY ci.created_at DESC
            "#,
        )
        .bind(public_id)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        Ok(rows.into_iter().map(|row| map_call_invite_row(&row)).collect())
    }

    pub async fn fetch_call_invite(&self, invite_id: &str) -> Result<Option<CallInviteView>, String> {
        let row = sqlx::query(
            r#"
            SELECT ci.invite_id, ci.room_id, ci.status,
                   (extract(epoch from ci.created_at) * 1000)::bigint AS created_at_ms,
                   CASE WHEN ci.responded_at IS NULL THEN NULL ELSE (extract(epoch from ci.responded_at) * 1000)::bigint END AS responded_at_ms,
                   cu.public_id AS caller_public_id, cu.first_name AS caller_first_name, cu.last_name AS caller_last_name,
                   tu.public_id AS callee_public_id, tu.first_name AS callee_first_name, tu.last_name AS callee_last_name
            FROM call_invites ci
            JOIN users cu ON cu.id = ci.caller_user_id
            JOIN users tu ON tu.id = ci.callee_user_id
            WHERE ci.invite_id = $1
            "#,
        )
        .bind(invite_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        Ok(row.map(|r| map_call_invite_row(&r)))
    }

    async fn fetch_friend_request_view(&self, request_id: &str) -> Result<Option<FriendRequestView>, String> {
        let row = sqlx::query(
            r#"
            SELECT fr.request_id, fr.status,
                   (extract(epoch from fr.created_at) * 1000)::bigint AS created_at_ms,
                   CASE WHEN fr.responded_at IS NULL THEN NULL ELSE (extract(epoch from fr.responded_at) * 1000)::bigint END AS responded_at_ms,
                   fu.public_id AS from_public_id, fu.first_name AS from_first_name, fu.last_name AS from_last_name,
                   tu.public_id AS to_public_id, tu.first_name AS to_first_name, tu.last_name AS to_last_name
            FROM friend_requests fr
            JOIN users fu ON fu.id = fr.from_user_id
            JOIN users tu ON tu.id = fr.to_user_id
            WHERE fr.request_id = $1
            "#,
        )
        .bind(request_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        Ok(row.map(|r| map_friend_request_row(&r)))
    }

    async fn fetch_request_list(&self, public_id: &str, incoming: bool) -> Result<Vec<FriendRequestView>, String> {
        let sql = if incoming {
            r#"
            SELECT fr.request_id, fr.status,
                   (extract(epoch from fr.created_at) * 1000)::bigint AS created_at_ms,
                   CASE WHEN fr.responded_at IS NULL THEN NULL ELSE (extract(epoch from fr.responded_at) * 1000)::bigint END AS responded_at_ms,
                   fu.public_id AS from_public_id, fu.first_name AS from_first_name, fu.last_name AS from_last_name,
                   tu.public_id AS to_public_id, tu.first_name AS to_first_name, tu.last_name AS to_last_name
            FROM friend_requests fr
            JOIN users fu ON fu.id = fr.from_user_id
            JOIN users tu ON tu.id = fr.to_user_id
            WHERE tu.public_id = $1 AND fr.status = 'pending'
            ORDER BY fr.created_at DESC
            "#
        } else {
            r#"
            SELECT fr.request_id, fr.status,
                   (extract(epoch from fr.created_at) * 1000)::bigint AS created_at_ms,
                   CASE WHEN fr.responded_at IS NULL THEN NULL ELSE (extract(epoch from fr.responded_at) * 1000)::bigint END AS responded_at_ms,
                   fu.public_id AS from_public_id, fu.first_name AS from_first_name, fu.last_name AS from_last_name,
                   tu.public_id AS to_public_id, tu.first_name AS to_first_name, tu.last_name AS to_last_name
            FROM friend_requests fr
            JOIN users fu ON fu.id = fr.from_user_id
            JOIN users tu ON tu.id = fr.to_user_id
            WHERE fu.public_id = $1 AND fr.status = 'pending'
            ORDER BY fr.created_at DESC
            "#
        };
        let rows = sqlx::query(sql)
            .bind(public_id)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| e.to_string())?;
        Ok(rows.into_iter().map(|r| map_friend_request_row(&r)).collect())
    }
}

fn map_public_user_row(row: &sqlx::postgres::PgRow) -> PublicUserResponse {
    let public_id: String = row.get("public_id");
    let first_name: String = row.get("first_name");
    let last_name: String = row.get("last_name");
    PublicUserResponse {
        public_id: public_id.clone(),
        display_name: build_display_name(&first_name, &last_name, &public_id),
        first_name,
        last_name,
        phone: row.get::<Option<String>, _>("phone_e164").unwrap_or_default(),
        about: row.get("about"),
        created_at: row.get("created_at_ms"),
        updated_at: row.get("updated_at_ms"),
    }
}

fn map_friend_request_row(row: &sqlx::postgres::PgRow) -> FriendRequestView {
    let from_public_id: String = row.get("from_public_id");
    let to_public_id: String = row.get("to_public_id");
    let from_first_name: String = row.get("from_first_name");
    let from_last_name: String = row.get("from_last_name");
    let to_first_name: String = row.get("to_first_name");
    let to_last_name: String = row.get("to_last_name");
    FriendRequestView {
        id: row.get("request_id"),
        from_public_id: from_public_id.clone(),
        from_display_name: build_display_name(&from_first_name, &from_last_name, &from_public_id),
        to_public_id: to_public_id.clone(),
        to_display_name: build_display_name(&to_first_name, &to_last_name, &to_public_id),
        status: row.get("status"),
        created_at: row.get("created_at_ms"),
        responded_at: row.try_get::<i64,_>("responded_at_ms").ok(),
    }
}

fn map_call_invite_row(row: &sqlx::postgres::PgRow) -> CallInviteView {
    let caller_public_id: String = row.get("caller_public_id");
    let callee_public_id: String = row.get("callee_public_id");
    let caller_first_name: String = row.get("caller_first_name");
    let caller_last_name: String = row.get("caller_last_name");
    let callee_first_name: String = row.get("callee_first_name");
    let callee_last_name: String = row.get("callee_last_name");
    CallInviteView {
        id: row.get("invite_id"),
        caller_public_id: caller_public_id.clone(),
        caller_display_name: build_display_name(&caller_first_name, &caller_last_name, &caller_public_id),
        callee_public_id: callee_public_id.clone(),
        callee_display_name: build_display_name(&callee_first_name, &callee_last_name, &callee_public_id),
        room_id: row.get("room_id"),
        status: row.get("status"),
        created_at: row.get("created_at_ms"),
        responded_at: row.try_get::<i64,_>("responded_at_ms").ok(),
    }
}

fn sanitize_file_name(value: &str) -> String {
    value.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '_') { ch } else { '_' }
        })
        .collect::<String>()
        .trim_matches('_')
        .to_string()
}

fn build_storage_key(media_id: &str, file_name: &str) -> String {
    let date_prefix = chrono_like_date_prefix();
    format!("{date_prefix}/{media_id}_{}", sanitize_file_name(file_name))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn chrono_like_date_prefix() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let days = secs / 86_400;
    format!("{}", days)
}

fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|v| v.to_string())
        .map_err(|e| format!("Не удалось захэшировать пароль: {e}"))
}

fn verify_password(hash: &str, password: &str) -> Result<(), String> {
    let parsed = PasswordHash::new(hash).map_err(|e| format!("Пароль повреждён: {e}"))?;
    Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .map_err(|_| "Неверный пароль".to_string())
}

fn hash_recovery_code(code: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(code.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn generate_recovery_codes() -> Vec<RecoveryCodeView> {
    let created_at = current_timestamp_ms();
    (0..8)
        .map(|_| RecoveryCodeView {
            code: generate_entity_id("RC"),
            is_used: false,
            created_at,
            used_at: None,
        })
        .collect()
}

fn generate_entity_id(prefix: &str) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::rng();
    let chars: String = (0..8)
        .map(|_| {
            let idx = rng.random_range(0..ALPHABET.len());
            ALPHABET[idx] as char
        })
        .collect();
    format!("{prefix}-{chars}")
}

fn normalize_phone(value: &str) -> String {
    value.chars().filter(|ch| ch.is_ascii_digit()).collect()
}

fn build_display_name(first_name: &str, last_name: &str, public_id: &str) -> String {
    let full = format!("{} {}", first_name.trim(), last_name.trim()).trim().to_string();
    if full.is_empty() { public_id.to_string() } else { full }
}

fn build_direct_chat_id(a: &str, b: &str) -> String {
    let mut ids = [a.to_string(), b.to_string()];
    ids.sort();
    format!("{}__{}", ids[0], ids[1])
}

fn build_direct_room_id(a: &str, b: &str) -> String {
    format!("dm_{}", build_direct_chat_id(a, b))
}

fn current_timestamp_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or_default()
}
