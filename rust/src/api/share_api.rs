//! Unified Dual-Protocol + SQLite + WeSync API exposed to Flutter via `flutter_rust_bridge`.
//!
//! Works alongside [`crate::api::web_api`] (preserving 100% backwards compatibility with
//! existing WebView cookie callers) while adding:
//! - Full `https://api.weibo.cn/2/*` mobile protocol via [`ApiCnClient`] (`newCalculateS`, `cum`,
//!   guest bootstrap `/2/guest/login`, RSA password/SMS/QR/OAuth logins, chunked media upload).
//! - Automatic Dual-Protocol routing (`api.weibo.cn/2/*` when holding `gsid` or guest/public
//!   endpoint, falling back to `weibo.com/ajax/*` when holding WebView `SUB=` cookie only).
//! - GreenDAO 1:1 9-table SQLite persistence (`USER`, `STATUS_DRAFTS`, `STATUS_HISTORY`,
//!   `GROUP_LIST`, `GROUP_MEMBER`, `FOLLOWER`, `BLACK_LIST`, `USER_HISTORY`, `SHARE_JSON`).
//! - WeSync binary push frame codec helpers.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::params;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::net::api_cn::{
    json_id_to_string, normalize_cookie_value, resolve_numeric_status_id, ApiCnClient,
    ApiCnError, MobileSession,
};
use crate::storage::dao::{BlackListDao, DraftDao, FollowerDao, GroupDao, HistoryDao, UserDao};
use crate::storage::db::DatabaseManager;
use crate::storage::models::{
    BlackListEntity, FollowerEntity, GroupListEntity, StatusDraftEntity, StatusHistoryEntity,
    UserEntity,
};
use crate::wesync::{WeSyncCommand, WeSyncFrame};

const MOBILE_GUEST_SESSION_KEY: &str = "mobile_guest_session";
const ACTIVE_UID_KEY: &str = "active_uid";
const LEGACY_SESSION_FILE: &str = "session.json";
const DB_FILE_NAME: &str = "share_app.db";

const WEB_BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) \
    AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// ============================================================================
// FRB-Friendly Data Transfer Objects
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoreInitResult {
    pub db_path: String,
    pub active_uid: String,
    pub active_account_type: i32,
    pub has_authenticated_user: bool,
    pub guest_aid: String,
    pub guest_gsid: String,
    pub account_count: usize,
    pub active_cookie: String,
    pub active_name: String,
    pub active_avatar: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountSummary {
    pub uid: String,
    pub name: String,
    pub avatar: String,
    pub cover: String,
    pub gender: String,
    pub sign: String,
    pub account: String,
    pub parent_type: i32,
    pub has_gsid: bool,
    pub has_oauth: bool,
    pub has_cookie: bool,
    pub is_active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DraftDto {
    pub id: i64,
    pub uid: String,
    pub content: String,
    pub date: i64,
    pub urls_json: String,
    pub target_status_id: String,
    pub target_status_json: String,
    pub target_comment_id: String,
    pub target_comment_user_name: String,
    pub target_comment_content: String,
    pub assign_group_id_str: String,
    pub assign_group_type: i32,
    pub address: String,
    pub publish_timing: i64,
    pub is_comment_origin: bool,
    pub status: i32,
    pub is_mention: bool,
    pub state: i32,
    pub type_code: i32,
    pub parent_type: i32,
    pub extra_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlacklistRuleDto {
    pub id: i64,
    pub uid: String,
    pub key: String,
    pub info: String,
    /// `0` = user UID/name, `1` = keyword, `2` = source device/client tail.
    pub rule_type: i32,
    /// `1` = enabled, `0` = paused.
    pub state: i32,
    pub black_type: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusHistoryDto {
    pub id: i64,
    pub status_id: String,
    pub username: String,
    pub avatar: String,
    pub total_text: String,
    pub status_json: String,
    pub uid: String,
    pub create_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserHistoryDto {
    pub id: i64,
    pub target_uid: String,
    pub target_user_name: String,
    pub target_user_avatar: String,
    pub user_json: String,
    pub uid: String,
    pub visit_count: i64,
    pub create_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FollowerDto {
    pub uid: String,
    pub tid: String,
    pub name: String,
    pub pinyin_name: String,
    pub gender: String,
    pub description: String,
    pub avatar: String,
    pub verified: bool,
    pub following: bool,
    pub follow_me: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CachedGroupDto {
    pub insert_number: i32,
    pub uid: String,
    pub gid: String,
    pub title: String,
    pub name: String,
    pub description: String,
    pub count: i32,
    pub group_type: String,
    pub visible: bool,
    pub remind: i32,
}

// ============================================================================
// Global CoreEngine
// ============================================================================

struct CoreEngine {
    data_dir: PathBuf,
    db: DatabaseManager,
    api_cn: ApiCnClient,
    web_http: reqwest::Client,
    visitor_web: std::sync::Mutex<Option<crate::web::client::WebClient>>,
}

static CORE_ENGINE: OnceLock<Arc<CoreEngine>> = OnceLock::new();

impl CoreEngine {
    fn open(data_dir: &Path) -> Result<Self, String> {
        fs::create_dir_all(data_dir)
            .map_err(|e| format!("Failed to create data_dir {}: {e}", data_dir.display()))?;
        let db_path = data_dir.join(DB_FILE_NAME);
        let db = DatabaseManager::open_file(&db_path).map_err(|e| e.to_string())?;
        let web_http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(25))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        let engine = Self {
            data_dir: data_dir.to_path_buf(),
            db,
            api_cn: ApiCnClient::default(),
            web_http,
            visitor_web: std::sync::Mutex::new(None),
        };
        engine.migrate_legacy_session_if_present()?;
        engine.restore_session_into_client()?;
        Ok(engine)
    }

    /// Reads optional legacy `session.json` created by `web_api.rs` and imports into `USER`.
    fn migrate_legacy_session_if_present(&self) -> Result<(), String> {
        let legacy_path = self.data_dir.join(LEGACY_SESSION_FILE);
        if !legacy_path.is_file() {
            return Ok(());
        }
        let Ok(raw) = fs::read_to_string(&legacy_path) else {
            return Ok(());
        };
        let Ok(val) = serde_json::from_str::<Value>(&raw) else {
            return Ok(());
        };
        let user_dao = UserDao::new(&self.db);
        let mut active_migrated = String::new();

        if let Some(arr) = val.get("accounts").and_then(|v| v.as_array()) {
            for item in arr {
                let uid = item
                    .get("uid")
                    .map(json_id_to_string)
                    .unwrap_or_default();
                let cookie = item
                    .get("cookie")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                if uid.is_empty() || cookie.is_empty() {
                    continue;
                }
                if user_dao.get_by_uid(&uid).map_err(|e| e.to_string())?.is_none() {
                    let entity = UserEntity {
                        uid: uid.clone(),
                        parent_type: 1,
                        name: item
                            .get("screen_name")
                            .or_else(|| item.get("name"))
                            .and_then(|v| v.as_str())
                            .map(str::to_string),
                        avatar: item
                            .get("avatar_url")
                            .or_else(|| item.get("avatar"))
                            .and_then(|v| v.as_str())
                            .map(str::to_string),
                        cookie: Some(cookie.to_string()),
                        ..Default::default()
                    };
                    user_dao.insert_or_replace(&entity).map_err(|e| e.to_string())?;
                }
                if active_migrated.is_empty() {
                    active_migrated = uid;
                }
            }
        }
        if let Some(act) = val.get("active_uid").and_then(|v| v.as_str()) {
            if !act.is_empty() {
                active_migrated = act.to_string();
            }
        }
        if !active_migrated.is_empty() && self.get_kv(ACTIVE_UID_KEY)?.is_none() {
            self.set_kv(ACTIVE_UID_KEY, &active_migrated)?;
        }
        Ok(())
    }

    fn restore_session_into_client(&self) -> Result<(), String> {
        let mut session = self
            .get_kv(MOBILE_GUEST_SESSION_KEY)?
            .and_then(|raw| serde_json::from_str::<MobileSession>(&raw).ok())
            .unwrap_or_default();

        if let Some(uid) = self.active_uid()? {
            if let Some(mut user) = UserDao::new(&self.db)
                .get_by_uid(&uid)
                .map_err(|e| e.to_string())?
            {
                if let Some(raw) = user.cookie.as_deref().filter(|s| !s.is_empty()) {
                    if let Some(cleaned) = normalize_cookie_value(&Value::String(raw.to_string())) {
                        if cleaned != raw {
                            user.cookie = Some(cleaned);
                            let _ = UserDao::new(&self.db).insert_or_replace(&user);
                        }
                    }
                }
                apply_user_to_session(&user, &mut session);
            }
        }
        self.api_cn.set_session(session);
        Ok(())
    }

    fn active_uid(&self) -> Result<Option<String>, String> {
        if let Some(uid) = self.get_kv(ACTIVE_UID_KEY)? {
            if !uid.is_empty() {
                return Ok(Some(uid));
            }
        }
        let all = UserDao::new(&self.db).get_all().map_err(|e| e.to_string())?;
        Ok(all.first().map(|u| u.uid.clone()))
    }

    fn active_user(&self) -> Result<Option<UserEntity>, String> {
        let Some(uid) = self.active_uid()? else {
            return Ok(None);
        };
        UserDao::new(&self.db)
            .get_by_uid(&uid)
            .map_err(|e| e.to_string())
    }

    fn persist_guest_snapshot(&self, sess: &MobileSession) -> Result<(), String> {
        let json_str = serde_json::to_string(sess).map_err(|e| e.to_string())?;
        self.set_kv(MOBILE_GUEST_SESSION_KEY, &json_str)
    }

    fn get_kv(&self, key: &str) -> Result<Option<String>, String> {
        self.db
            .with_conn(|conn| {
                let mut stmt = conn.prepare(
                    "SELECT \"JSON\" FROM \"SHARE_JSON\" WHERE \"MODEL\" = ?1 LIMIT 1;",
                )?;
                let mut rows = stmt.query(params![key])?;
                if let Some(row) = rows.next()? {
                    let val: Option<String> = row.get(0)?;
                    Ok(val)
                } else {
                    Ok(None)
                }
            })
            .map_err(|e| e.to_string())
    }

    fn set_kv(&self, key: &str, value: &str) -> Result<(), String> {
        self.db
            .with_conn(|conn| {
                conn.execute(
                    "INSERT INTO \"SHARE_JSON\" (\"MODEL\", \"JSON\")
                     VALUES (?1, ?2)
                     ON CONFLICT(\"MODEL\") DO UPDATE SET
                        \"JSON\" = excluded.\"JSON\";",
                    params![key, value],
                )?;
                Ok(())
            })
            .map_err(|e| e.to_string())
    }

    fn active_session_has_gsid(&self) -> bool {
        let sess = self.api_cn.session();
        if sess.gsid.is_empty() || sess.uid.is_empty() {
            return false;
        }
        self.active_user()
            .ok()
            .flatten()
            .is_some_and(|u| u.gsid.as_deref().is_some_and(|g| !g.is_empty()))
    }

    fn clean_active_web_cookie(&self) -> Option<String> {
        let user = self.active_user().ok().flatten()?;
        let raw = user.cookie.filter(|c| !c.is_empty())?;
        let cleaned = normalize_cookie_value(&Value::String(raw))?;
        cleaned.contains("SUB=").then_some(cleaned)
    }

    /// Executes an authenticated `GET` or `POST` against `weibo.com` or `api.weibo.com` using
    /// the sanitized `USER.COOKIE`. Rejects immediately if no `SUB=` cookie is present.
    async fn web_request(
        &self,
        method: &str,
        path_or_url: &str,
        query: &[(&str, String)],
        form: Option<&[(&str, String)]>,
        referer: &str,
    ) -> Result<Value, String> {
        let cookie = self
            .clean_active_web_cookie()
            .ok_or_else(|| "当前账号仅完成移动端授权，暂无网页版 SUB Cookie".to_string())?;

        let url = if path_or_url.starts_with("http://") || path_or_url.starts_with("https://") {
            path_or_url.to_string()
        } else {
            let trimmed = path_or_url.trim_start_matches('/');
            format!("https://weibo.com/{trimmed}")
        };

        let mut req = match method {
            "POST" => self.web_http.post(&url),
            _ => self.web_http.get(&url),
        }
        .query(query)
        .header("Cookie", &cookie)
        .header("Referer", referer)
        .header("X-Requested-With", "XMLHttpRequest")
        .header("User-Agent", WEB_BROWSER_UA);

        if let Some(xsrf) = extract_cookie_pair(&cookie, "XSRF-TOKEN") {
            req = req.header("X-XSRF-TOKEN", xsrf);
        }
        if let Some(f) = form {
            req = req.form(f);
        }

        let resp = req.send().await.map_err(|e| format!("Web request failed: {e}"))?;
        let status = resp.status().as_u16();
        let text = resp.text().await.map_err(|e| e.to_string())?;
        if status >= 400 {
            return Err(format!("weibo.com HTTP {status}: {text}"));
        }
        if text.trim_start().starts_with('<') {
            return Err("登录状态已失效，请重新登录".to_string());
        }
        let val: Value = serde_json::from_str(&text)
            .map_err(|e| format!("Invalid weibo JSON ({e})"))?;
        if let Some(err) = val.get("error").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
            return Err(format!("微博接口错误：{err}"));
        }
        if let Some(ok) = val.get("ok").and_then(|v| v.as_i64()) {
            if ok == 0 {
                let msg = val
                    .get("msg")
                    .or_else(|| val.get("message"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("请求失败");
                return Err(msg.to_string());
            }
        }
        Ok(val)
    }

    async fn web_ajax_get(
        &self,
        path_or_url: &str,
        query: &[(&str, String)],
    ) -> Result<Value, String> {
        self.web_request("GET", path_or_url, query, None, "https://weibo.com/")
            .await
    }

    async fn ensure_visitor_web_client(
        &self,
        force_refresh: bool,
    ) -> Result<crate::web::client::WebClient, String> {
        let client = {
            let mut guard = self
                .visitor_web
                .lock()
                .map_err(|_| "visitor_web mutex poisoned".to_string())?;
            guard
                .get_or_insert_with(crate::web::client::WebClient::new)
                .clone()
        };
        if force_refresh || !client.has_session() {
            crate::web::api::guest_login(&client)
                .await
                .map_err(|e| e.to_string())?;
        }
        Ok(client)
    }

    /// Reads public `weibo.com/ajax/*` endpoints using the signed-in account's Web
    /// cookie if available, otherwise transparently using a visitor `SUB` cookie so
    /// SMS-only mobile accounts can still view public reposts/likers/comments.
    async fn web_ajax_get_or_visitor(
        &self,
        path_or_url: &str,
        query: &[(&str, String)],
    ) -> Result<Value, String> {
        if self.clean_active_web_cookie().is_some() {
            return self.web_ajax_get(path_or_url, query).await;
        }
        let base_url = if path_or_url.starts_with("http://") || path_or_url.starts_with("https://") {
            path_or_url.to_string()
        } else {
            format!("https://weibo.com/{}", path_or_url.trim_start_matches('/'))
        };
        let url = reqwest::Url::parse_with_params(&base_url, query)
            .map_err(|e| format!("Invalid web URL: {e}"))?
            .to_string();

        let client = self.ensure_visitor_web_client(false).await?;
        match client.get(&url, "https://weibo.com/").await {
            Ok(val) => Ok(val),
            Err(crate::web::client::WebError {
                kind: crate::web::client::WebErrorKind::Unauthenticated,
                ..
            }) => {
                let refreshed = self.ensure_visitor_web_client(true).await?;
                refreshed
                    .get(&url, "https://weibo.com/")
                    .await
                    .map_err(|e| e.to_string())
            }
            Err(e) => Err(e.to_string()),
        }
    }

    async fn web_ajax_post(
        &self,
        path_or_url: &str,
        form: &[(&str, String)],
    ) -> Result<Value, String> {
        self.web_request("POST", path_or_url, &[], Some(form), "https://weibo.com/")
            .await
    }
}

fn core() -> Result<&'static Arc<CoreEngine>, String> {
    CORE_ENGINE
        .get()
        .ok_or_else(|| "CoreEngine not initialized; call init_core(data_dir) first".to_string())
}

// ============================================================================
// Core Init & Lifecycle
// ============================================================================

/// Initializes SQLite persistence, migrates any legacy session file, restores the active
/// account or registers an anonymous guest session via `POST /2/guest/login`.
pub async fn init_share_core(data_dir: String) -> Result<CoreInitResult, String> {
    let engine = if let Some(existing) = CORE_ENGINE.get() {
        existing
    } else {
        let created = Arc::new(CoreEngine::open(Path::new(&data_dir))?);
        let _ = CORE_ENGINE.set(created);
        CORE_ENGINE.get().expect("CORE_ENGINE set above")
    };

    if engine.api_cn.session().aid.is_empty() || engine.api_cn.session().gsid.is_empty() {
        if let Ok(guest) = engine.api_cn.guest_login().await {
            let _ = engine.persist_guest_snapshot(&guest);
        }
    }

    let snap = engine.api_cn.session();
    let active_user = engine.active_user()?;
    let accounts = UserDao::new(&engine.db)
        .get_all()
        .map_err(|e| e.to_string())?;
    let active_cookie = engine.clean_active_web_cookie().unwrap_or_default();

    Ok(CoreInitResult {
        db_path: engine.data_dir.join(DB_FILE_NAME).display().to_string(),
        active_uid: active_user
            .as_ref()
            .map(|u| u.uid.clone())
            .unwrap_or_default(),
        active_account_type: active_user.as_ref().map(|u| u.parent_type).unwrap_or(-1),
        has_authenticated_user: active_user.is_some(),
        guest_aid: snap.aid,
        guest_gsid: snap.gsid,
        account_count: accounts.len(),
        active_cookie,
        active_name: active_user
            .as_ref()
            .and_then(|u| u.name.clone())
            .unwrap_or_default(),
        active_avatar: active_user
            .as_ref()
            .and_then(|u| u.avatar.clone())
            .unwrap_or_default(),
    })
}

/// Ensures guest credentials exist on `ApiCnClient` and returns the session snapshot JSON.
pub async fn guest_login_mobile() -> Result<String, String> {
    let engine = core()?;
    let sess = engine
        .api_cn
        .guest_login()
        .await
        .map_err(|e| e.to_string())?;
    engine.persist_guest_snapshot(&sess)?;
    serde_json::to_string(&sess).map_err(|e| e.to_string())
}

// ============================================================================
// All 5 Authentication Flows & Multi-Account SQLite Storage
// ============================================================================

/// Performs official mobile password login (`POST /2/account/login`).
///
/// Returns `{ "status": "ok", "account": AccountSummary, "raw": ... }` on success OR
/// `{ "status": "challenge", "errno": ..., "errmsg": ..., "raw": ... }` when SMS/Safety
/// verify or Captcha is requested by Sina.
pub async fn login_password_mobile(
    username: String,
    password: String,
    cpt_id: Option<String>,
    cpt_code: Option<String>,
    alt: Option<String>,
) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let cpt_pair = match (cpt_id.as_deref(), cpt_code.as_deref()) {
        (Some(id), Some(code)) if !id.is_empty() && !code.is_empty() => Some((id, code)),
        _ => None,
    };

    match engine
        .api_cn
        .password_login(&username, &password, cpt_pair, alt.as_deref())
        .await
    {
        Ok(raw) => {
            if let Some(summary) = save_login_json_to_db(engine, &raw, Some(&username), None)? {
                return serde_json::to_string(&json!({
                    "status": "ok",
                    "account": summary,
                    "raw": raw,
                }))
                .map_err(|e| e.to_string());
            }
            serde_json::to_string(&json!({
                "status": "challenge",
                "errno": raw.get("errno").cloned().unwrap_or(Value::Null),
                "errmsg": raw.get("errmsg").or_else(|| raw.get("error")).cloned().unwrap_or(Value::Null),
                "raw": raw,
            }))
            .map_err(|e| e.to_string())
        }
        Err(ApiCnError::WeiboApi { errno, errmsg, raw }) => serde_json::to_string(&json!({
            "status": "challenge",
            "errno": errno,
            "errmsg": errmsg,
            "raw": raw,
        }))
        .map_err(|e| e.to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// Fetches a login captcha image/metadata (`POST /2/captcha/get`).
pub async fn login_captcha_get(cpt_id: Option<String>) -> Result<String, String> {
    let engine = core()?;
    let val = engine
        .api_cn
        .captcha_get(cpt_id.as_deref())
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

/// Triggers SMS dispatch during secondary safety verify (`WeiboSafetyVerifyActivity`).
pub async fn login_safety_send_sms(
    phone: String,
    area: String,
    retcode: String,
) -> Result<String, String> {
    let engine = core()?;
    let val = engine
        .api_cn
        .safety_send_sms(&phone, &area, &retcode)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

/// Triggers passwordless SMS login verification code (`POST /2/account/login_sendcode`).
pub async fn login_sms_send(phone: String, area: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let val = engine
        .api_cn
        .sms_sendcode(&phone, &area)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

/// Submits SMS verification code (`WeiboSmsVerifyActivity`) to finalize login.
pub async fn login_sms_verify(
    phone: String,
    area: String,
    number: String,
    code: String,
    is_sms_login: bool,
    username: Option<String>,
    password: Option<String>,
    retcode: Option<String>,
) -> Result<String, String> {
    let engine = core()?;
    let raw = engine
        .api_cn
        .sms_verify_login(
            &phone,
            &area,
            &number,
            &code,
            is_sms_login,
            username.as_deref(),
            password.as_deref(),
            retcode.as_deref(),
        )
        .await
        .map_err(|e| e.to_string())?;

    let summary = save_login_json_to_db(engine, &raw, username.as_deref().or(Some(&phone)), None)?
        .ok_or_else(|| format!("SMS login response did not contain uid/gsid: {raw}"))?;

    serde_json::to_string(&json!({
        "status": "ok",
        "account": summary,
        "raw": raw,
    }))
    .map_err(|e| e.to_string())
}

/// Confirms PC QR code login (`https://passport.weibo.cn/signin/qrcode/scan*`).
pub async fn qr_confirm_login(
    qr_url: String,
    custom_cookie: Option<String>,
) -> Result<String, String> {
    let engine = core()?;
    let active_cookie = custom_cookie.or_else(|| {
        engine
            .active_user()
            .ok()
            .flatten()
            .and_then(|u| u.cookie)
    });
    let res = engine
        .api_cn
        .qr_confirm_scan(&qr_url, active_cookie.as_deref())
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&res).map_err(|e| e.to_string())
}

/// Imports and verifies a WebView/browser cookie string (`SUB=...`), fetches user profile info,
/// persists the account in `USER` (`parent_type = 1`), and makes it active.
pub async fn import_cookie_account(
    cookie: String,
    uid_hint: Option<String>,
    name_hint: Option<String>,
) -> Result<AccountSummary, String> {
    let engine = core()?;
    let trimmed = cookie.trim().to_string();
    if trimmed.is_empty() {
        return Err("Cookie cannot be empty".to_string());
    }

    let mut req = engine
        .web_http
        .get("https://weibo.com/ajax/profile/info")
        .header("Cookie", &trimmed)
        .header("Referer", "https://weibo.com/")
        .header("X-Requested-With", "XMLHttpRequest")
        .header("User-Agent", WEB_BROWSER_UA);
    if let Some(xsrf) = extract_cookie_pair(&trimmed, "XSRF-TOKEN") {
        req = req.header("X-XSRF-TOKEN", xsrf);
    }

    let mut fetched_uid = uid_hint.unwrap_or_default();
    let mut screen_name = name_hint.unwrap_or_default();
    let mut avatar = String::new();
    let mut cover = String::new();
    let mut gender = String::new();
    let mut sign = String::new();

    if let Ok(resp) = req.send().await {
        if let Ok(val) = resp.json::<Value>().await {
            if let Some(u) = val.pointer("/data/user") {
                if fetched_uid.is_empty() {
                    fetched_uid = u.get("idstr").or_else(|| u.get("id")).map(json_id_to_string).unwrap_or_default();
                }
                if let Some(n) = u.get("screen_name").and_then(|v| v.as_str()) {
                    screen_name = n.to_string();
                }
                avatar = u
                    .get("avatar_hd")
                    .or_else(|| u.get("avatar_large"))
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                cover = u
                    .get("cover_image_phone")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                gender = u
                    .get("gender")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                sign = u
                    .get("description")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
            }
        }
    }

    if fetched_uid.is_empty() {
        // Attempt extracting UID from Web config endpoint when custom=0 profile fails
        if let Ok(resp) = engine
            .web_http
            .get("https://weibo.com/ajax/statuses/mymblog?uid=0&page=1")
            .header("Cookie", &trimmed)
            .header("Referer", "https://weibo.com/")
            .header("User-Agent", WEB_BROWSER_UA)
            .send()
            .await
        {
            if let Ok(v) = resp.json::<Value>().await {
                if let Some(id_val) = v.pointer("/data/uid") {
                    fetched_uid = json_id_to_string(id_val);
                }
            }
        }
    }

    if fetched_uid.is_empty() {
        return Err("Unable to verify Weibo UID from provided cookie; make sure SUB= is present and valid".to_string());
    }

    let dao = UserDao::new(&engine.db);
    let existing = dao.get_by_uid(&fetched_uid).map_err(|e| e.to_string())?;
    let mut entity = existing.unwrap_or_else(|| UserEntity {
        uid: fetched_uid.clone(),
        parent_type: 1,
        ..Default::default()
    });
    entity.cookie = Some(trimmed);
    if !screen_name.is_empty() {
        entity.name = Some(screen_name);
    }
    if !avatar.is_empty() {
        entity.avatar = Some(avatar);
    }
    if !cover.is_empty() {
        entity.cover = Some(cover);
    }
    if !gender.is_empty() {
        entity.gender = Some(gender);
    }
    if !sign.is_empty() {
        entity.sign = Some(sign);
    }
    dao.insert_or_replace(&entity).map_err(|e| e.to_string())?;
    engine.set_kv(ACTIVE_UID_KEY, &entity.uid)?;
    engine.restore_session_into_client()?;

    Ok(user_to_summary(&entity, Some(&entity.uid)))
}

/// Lists all saved accounts in `USER`.
pub async fn list_accounts_sql() -> Result<Vec<AccountSummary>, String> {
    let engine = core()?;
    let active = engine.active_uid()?;
    let users = UserDao::new(&engine.db).get_all().map_err(|e| e.to_string())?;
    Ok(users
        .iter()
        .map(|u| user_to_summary(u, active.as_deref()))
        .collect())
}

/// Switches active account by UID and refreshes `ApiCnClient` session state.
pub async fn switch_account_sql(uid: String) -> Result<AccountSummary, String> {
    let engine = core()?;
    let user = UserDao::new(&engine.db)
        .get_by_uid(&uid)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("Account UID {uid} not found"))?;
    engine.set_kv(ACTIVE_UID_KEY, &uid)?;
    engine.restore_session_into_client()?;
    Ok(user_to_summary(&user, Some(&uid)))
}

/// Deletes an account from `USER`; falls back to another account or guest mode if it was active.
pub async fn delete_account_sql(uid: String) -> Result<bool, String> {
    let engine = core()?;
    let dao = UserDao::new(&engine.db);
    let was_active = engine.active_uid()?.as_deref() == Some(uid.as_str());
    let deleted = dao.delete_by_uid(&uid).map_err(|e| e.to_string())?;
    if was_active {
        let remaining = dao.get_all().map_err(|e| e.to_string())?;
        let next_uid = remaining.first().map(|u| u.uid.as_str()).unwrap_or("");
        engine.set_kv(ACTIVE_UID_KEY, next_uid)?;
        engine.restore_session_into_client()?;
        if next_uid.is_empty() {
            let _ = engine.api_cn.guest_login().await;
        }
    }
    Ok(deleted)
}

/// Logs out the currently active account and returns the next active UID if one remains.
pub async fn logout_current_sql() -> Result<Option<String>, String> {
    let engine = core()?;
    if let Some(uid) = engine.active_uid()? {
        let _ = delete_account_sql(uid).await?;
    }
    engine.active_uid()
}

// ============================================================================
// Generic Signed /2/* & Chunked Upload Passthroughs
// ============================================================================

/// Executes a signed `GET https://api.weibo.cn/2/{path}` with JSON-object query params.
pub async fn mobile_get(path: String, params_json: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let params = parse_string_map(&params_json)?;
    let val = engine
        .api_cn
        .get_2(&path, params)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

/// Executes a signed `POST https://api.weibo.cn/2/{path}` with query & form JSON maps.
pub async fn mobile_post(
    path: String,
    query_json: String,
    form_json: String,
) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let query = parse_string_map(&query_json)?;
    let form = parse_string_map(&form_json)?;
    let val = engine
        .api_cn
        .post_2(&path, query, form)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

/// Uploads an image via `upload.api.weibo.com/2/mss/upload.json`.
pub async fn mobile_upload_pic(
    bytes: Vec<u8>,
    filename: String,
    mime: String,
) -> Result<String, String> {
    let engine = core()?;
    let val = engine
        .api_cn
        .upload_pic_mss(bytes, &filename, &mime)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

/// Initializes a large/DM attachment upload (`fileplatform/init.json`).
pub async fn mobile_upload_chunk_init(
    length: usize,
    file_hash: String,
    filename: String,
    extprops_json: String,
    mediaprops_json: String,
) -> Result<String, String> {
    let engine = core()?;
    let val = engine
        .api_cn
        .fileplatform_init(length, &file_hash, &filename, &extprops_json, &mediaprops_json)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

/// Sends one binary chunk (`fileplatform/upload.json`).
pub async fn mobile_upload_chunk_send(
    upload_url: Option<String>,
    params_json: String,
    chunk: Vec<u8>,
) -> Result<String, String> {
    let engine = core()?;
    let params = parse_string_map(&params_json)?;
    let val = engine
        .api_cn
        .fileplatform_upload_chunk(upload_url.as_deref(), params, chunk)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

// ============================================================================
// Dual-Protocol Endpoints (Mobile /2/* + Web Ajax Fallback + Blacklist Filter)
// ============================================================================

/// Fetches Hot Weibo timeline (`group_id`, default `"102803"`). Works even in guest mode!
pub async fn hot_timeline_dual(
    group_id: String,
    max_id: Option<String>,
    count: u32,
    need_jump: bool,
) -> Result<String, String> {
    let engine = core()?;
    engine
        .api_cn
        .ensure_guest_or_user()
        .await
        .map_err(|e| e.to_string())?;
    let gid = if group_id.is_empty() {
        "102803"
    } else {
        &group_id
    };
    let mut val = engine
        .api_cn
        .unread_hot_timeline(gid, max_id.as_deref(), count, need_jump)
        .await
        .map_err(|e| e.to_string())?;
    apply_blacklist_to_response(engine, &mut val);
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

/// Fetches Home or Group timeline (`list_id` optional). Routes to `api.weibo.cn/2/*`
/// when active account has `gsid`, falling back across `statuses/friends_timeline`,
/// `statuses/friends/timeline`, and `weibo.com/ajax/feed/*`.
pub async fn friends_timeline_dual(
    list_id: Option<String>,
    since_id: Option<String>,
    max_id: Option<String>,
    count: u32,
    page: u32,
) -> Result<String, String> {
    let engine = core()?;
    let lid_opt = list_id.as_deref().filter(|s| !s.is_empty());
    let is_all_follow = lid_opt.is_none() || lid_opt.is_some_and(|l| l.starts_with("10001"));
    let mut val_opt: Option<Value> = None;
    let mut last_err: Option<String> = None;

    if engine.active_session_has_gsid() {
        if !is_all_follow {
            let lid = lid_opt.unwrap();
            match engine
                .api_cn
                .groups_timeline(lid, since_id.as_deref(), max_id.as_deref(), count, page)
                .await
            {
                Ok(v) => val_opt = Some(v),
                Err(e) => last_err = Some(e.to_string()),
            }
        } else {
            // Original Share (`C6870rf.O00000Oo` `EnumC7034tf.ALL`) uses chronological
            // `statuses/friends/timeline` (`O0000oOo`), NOT `unread_friends_timeline` which
            // mixes algorithmic/out-of-order entries.
            for attempt in 0..3 {
                let res = match attempt {
                    0 => {
                        engine
                            .api_cn
                            .friends_timeline(since_id.as_deref(), max_id.as_deref(), count, page)
                            .await
                    }
                    1 => {
                        engine
                            .api_cn
                            .friends_timeline_alt(since_id.as_deref(), max_id.as_deref(), count, page)
                            .await
                    }
                    _ => {
                        engine
                            .api_cn
                            .unread_friends_timeline(since_id.as_deref(), max_id.as_deref(), count, page)
                            .await
                    }
                };
                match res {
                    Ok(v) if !statuses_empty(&v) => {
                        val_opt = Some(v);
                        break;
                    }
                    Ok(v) if val_opt.is_none() => val_opt = Some(v),
                    Ok(_) => {}
                    Err(e) => last_err = Some(e.to_string()),
                }
            }
        }
    }

    if val_opt.as_ref().is_none_or(statuses_empty) {
        let web_res = if !is_all_follow {
            let lid = lid_opt.unwrap();
            engine
                .web_ajax_get(
                    "ajax/feed/groupstimeline",
                    &[
                        ("list_id", lid.to_string()),
                        ("refresh", "4".to_string()),
                        ("count", count.to_string()),
                        ("page", page.max(1).to_string()),
                        ("max_id", max_id.clone().unwrap_or_default()),
                    ],
                )
                .await
        } else {
            engine
                .web_ajax_get(
                    "ajax/feed/friendstimeline",
                    &[
                        ("refresh", "4".to_string()),
                        ("count", count.to_string()),
                        ("page", page.max(1).to_string()),
                        ("max_id", max_id.clone().unwrap_or_default()),
                    ],
                )
                .await
        };
        match web_res {
            Ok(wv) if !statuses_empty(&wv) => val_opt = Some(wv),
            Ok(wv) if val_opt.is_none() => val_opt = Some(wv),
            Ok(_) => {}
            Err(e) => {
                if val_opt.is_none() {
                    last_err = Some(last_err.unwrap_or(e));
                }
            }
        }
    }

    let mut val = val_opt.ok_or_else(|| last_err.unwrap_or_else(|| "加载关注时间线失败".to_string()))?;
    if is_all_follow {
        clean_and_sort_chronological_statuses(&mut val);
    }
    apply_blacklist_to_response(engine, &mut val);
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn get_active_web_cookie_dual() -> Result<Option<String>, String> {
    Ok(core()?.clean_active_web_cookie())
}

pub async fn user_profile_dual(uid: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    if let Ok(v) = engine.api_cn.profile(Some(&uid), None).await {
        if v.get("userInfo").is_some() || v.pointer("/data/user").is_some() {
            return serde_json::to_string(&v).map_err(|e| e.to_string());
        }
    }
    if let Ok(wv) = engine.web_ajax_get("ajax/profile/info", &[("uid", uid.clone())]).await {
        return serde_json::to_string(&wv).map_err(|e| e.to_string());
    }
    let val = engine.api_cn.profile(Some(&uid), None).await.map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn user_timeline_dual(
    uid: String,
    max_id: Option<String>,
    count: u32,
    page: u32,
    feature: u32,
) -> Result<String, String> {
    let engine = core()?;
    let mut best: Option<Value> = None;
    let mut last_err: Option<String> = None;

    // Web-only accounts without a mobile gsid use weibo.com/ajax/statuses/mymblog first.
    if !engine.active_session_has_gsid() && engine.clean_active_web_cookie().is_some() {
        match engine
            .web_ajax_get(
                "ajax/statuses/mymblog",
                &[
                    ("uid", uid.clone()),
                    ("page", page.max(1).to_string()),
                    ("feature", feature.to_string()),
                ],
            )
            .await
        {
            Ok(wv) if !statuses_empty(&wv) => best = Some(wv),
            Ok(wv) => best = Some(wv),
            Err(e) => last_err = Some(e),
        }
    }

    // Primary mobile endpoint matching Share APK (`profile/statuses`, 230413<uid>_-_WEIBO_SECOND_PROFILE_WEIBO).
    if best.as_ref().is_none_or(statuses_empty) {
        let _ = engine.api_cn.ensure_guest_or_user().await;
        for cid in [
            None,
            Some(format!("107603{uid}_-_WEIBO_SECOND_PROFILE_WEIBO")),
        ] {
            match engine
                .api_cn
                .profile_statuses(&uid, cid.as_deref(), feature, count, page)
                .await
            {
                Ok(card_val) => {
                    let cards = extract_mblogs_from_cardlist(&card_val);
                    if !cards.is_empty() {
                        let card_count = cards.len();
                        best = Some(json!({
                            "statuses": cards,
                            "since_id": card_val.pointer("/cardlistInfo/since_id").cloned().unwrap_or(Value::Null),
                            "total_number": card_val.pointer("/cardlistInfo/total").cloned().unwrap_or(Value::Null),
                            "hasmore": card_count >= 8,
                        }));
                        break;
                    } else if best.is_none() && card_val.get("cards").is_some() {
                        best = Some(json!({
                            "statuses": [],
                            "total_number": card_val.pointer("/cardlistInfo/total").cloned().unwrap_or(json!(0)),
                        }));
                    }
                }
                Err(e) => last_err = Some(e.to_string()),
            }
        }
    }

    // Fallback 1: legacy /2/statuses/user_timeline (when mobile user session exists)
    if best.as_ref().is_none_or(statuses_empty) && engine.active_session_has_gsid() {
        match engine
            .api_cn
            .user_timeline(Some(&uid), None, None, max_id.as_deref(), feature, count, page)
            .await
        {
            Ok(v) if !statuses_empty(&v) => best = Some(v),
            Ok(v) if best.is_none() && v.get("statuses").is_some() => best = Some(v),
            Ok(_) => {}
            Err(e) => {
                if best.is_none() {
                    last_err = Some(e.to_string());
                }
            }
        }
    }

    // Fallback 2: weibo.com/ajax/statuses/mymblog when web SUB cookie is available
    if best.as_ref().is_none_or(statuses_empty) && engine.clean_active_web_cookie().is_some() {
        match engine
            .web_ajax_get(
                "ajax/statuses/mymblog",
                &[
                    ("uid", uid.clone()),
                    ("page", page.max(1).to_string()),
                    ("feature", feature.to_string()),
                ],
            )
            .await
        {
            Ok(wv) if !statuses_empty(&wv) => best = Some(wv),
            Ok(wv) if best.is_none() => best = Some(wv),
            Ok(_) => {}
            Err(e) => {
                if best.is_none() {
                    last_err = Some(e);
                }
            }
        }
    }

    let mut val = best.ok_or_else(|| last_err.unwrap_or_else(|| "无法读取该用户微博".to_string()))?;
    apply_blacklist_to_response(engine, &mut val);
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn friends_list_dual(
    uid: String,
    page: u32,
    cursor: i64,
    count: u32,
    followers: bool,
) -> Result<String, String> {
    let engine = core()?;
    if !engine.active_session_has_gsid() && engine.clean_active_web_cookie().is_some() {
        let mut q = vec![
            ("uid", uid.clone()),
            ("page", page.max(1).to_string()),
            ("count", count.to_string()),
        ];
        if followers {
            q.push(("relate", "fans".to_string()));
        }
        let val = engine.web_ajax_get("ajax/friendships/friends", &q).await?;
        return serde_json::to_string(&val).map_err(|e| e.to_string());
    }

    let _ = engine.api_cn.ensure_guest_or_user().await;
    if followers {
        let active_uid = engine.active_uid()?.unwrap_or_default();
        let containerid = if active_uid == uid {
            "231016_-_selffans".to_string()
        } else {
            format!("231051_-_fans_-_{uid}")
        };
        let val = engine
            .api_cn
            .cardlist(&containerid, page, None)
            .await
            .map_err(|e| e.to_string())?;
        let users = extract_users_from_cardlist(&val);
        return serde_json::to_string(&json!({
            "users": users,
            "total_number": val.pointer("/cardlistInfo/total").cloned().unwrap_or(Value::Null),
        }))
        .map_err(|e| e.to_string());
    }

    match engine
        .api_cn
        .friendships_friends(&uid, cursor, page, count)
        .await
    {
        Ok(v) => {
            let has_users = v
                .get("users")
                .and_then(|u| u.as_array())
                .is_some_and(|a| !a.is_empty());
            if has_users {
                return serde_json::to_string(&v).map_err(|e| e.to_string());
            }
            let extracted = extract_users_from_cardlist(&v);
            if !extracted.is_empty() {
                return serde_json::to_string(&json!({
                    "users": extracted,
                    "next_cursor": v.get("next_cursor").cloned().unwrap_or(json!(0)),
                    "total_number": v.get("total_number").cloned().unwrap_or(Value::Null),
                }))
                .map_err(|e| e.to_string());
            }
            if engine.clean_active_web_cookie().is_some() {
                if let Ok(wv) = engine
                    .web_ajax_get(
                        "ajax/friendships/friends",
                        &[
                            ("uid", uid.clone()),
                            ("page", page.max(1).to_string()),
                            ("count", count.to_string()),
                        ],
                    )
                    .await
                {
                    return serde_json::to_string(&wv).map_err(|err| err.to_string());
                }
            }
            serde_json::to_string(&v).map_err(|e| e.to_string())
        }
        Err(e) => {
            if let Ok(wv) = engine
                .web_ajax_get(
                    "ajax/friendships/friends",
                    &[
                        ("uid", uid),
                        ("page", page.max(1).to_string()),
                        ("count", count.to_string()),
                    ],
                )
                .await
            {
                return serde_json::to_string(&wv).map_err(|err| err.to_string());
            }
            Err(e.to_string())
        }
    }
}

pub async fn unread_count_dual() -> Result<String, String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        let uid = engine.active_uid()?.unwrap_or_default();
        if let Ok(v) = engine.api_cn.remind_unread_count(&uid).await {
            return serde_json::to_string(&v).map_err(|e| e.to_string());
        }
    }
    if engine.clean_active_web_cookie().is_some() {
        if let Ok(v) = engine.web_ajax_get("ajax/message/unreadHint", &[]).await {
            return serde_json::to_string(&v).map_err(|e| e.to_string());
        }
    }
    Ok("{}".to_string())
}

pub async fn notices_dual(
    kind: String,
    max_id: Option<String>,
    page: u32,
    count: u32,
) -> Result<String, String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        let res = match kind.as_str() {
            "at_weibo" | "atWeibo" => engine.api_cn.mentions_statuses(max_id.as_deref(), page, count).await,
            "at_comment" | "atComment" => engine.api_cn.mentions_comments(max_id.as_deref(), page, count).await,
            "comment" => engine.api_cn.comments_to_me(max_id.as_deref(), page, count).await,
            "like" => engine.api_cn.like_to_me(max_id.as_deref(), page, count).await,
            other => return Err(format!("Unsupported notice kind: {other}")),
        };
        if let Ok(v) = res {
            return serde_json::to_string(&v).map_err(|e| e.to_string());
        } else if let Err(err) = res {
            if engine.clean_active_web_cookie().is_none() {
                return Err(err.to_string());
            }
        }
    }
    let path = match kind.as_str() {
        "at_weibo" | "atWeibo" => "ajax/statuses/mentions",
        "at_comment" | "atComment" => "ajax/comments/mentions",
        "comment" => "ajax/message/cmt",
        "like" => "ajax/message/attitudes",
        other => return Err(format!("Unsupported notice kind: {other}")),
    };
    let val = engine
        .web_ajax_get(path, &[("page", page.max(1).to_string())])
        .await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn dm_conversations_dual(count: u32, cursor: Option<String>) -> Result<String, String> {
    let engine = core()?;
    let mut mob_err: Option<String> = None;
    if engine.active_session_has_gsid() {
        match engine.api_cn.dm_user_list(cursor.as_deref(), count).await {
            Ok(v) => return serde_json::to_string(&v).map_err(|e| e.to_string()),
            Err(e) => mob_err = Some(e.to_string()),
        }
    }
    if engine.clean_active_web_cookie().is_some() {
        let val = engine
            .web_request(
                "GET",
                "https://api.weibo.com/webim/2/direct_messages/conversation.json",
                &[("count", count.to_string()), ("convert_emoji", "1".to_string())],
                None,
                "https://api.weibo.com/chat",
            )
            .await?;
        return serde_json::to_string(&val).map_err(|e| e.to_string());
    }
    Err(mob_err.unwrap_or_else(|| "当前账号无私信权限，请在账号管理页通过网页授权补充网页凭证后重试".to_string()))
}

pub async fn dm_history_dual(
    uid: String,
    max_id: Option<String>,
    count: u32,
) -> Result<String, String> {
    let engine = core()?;
    let mut mob_err: Option<String> = None;
    if engine.active_session_has_gsid() {
        match engine.api_cn.dm_conversation(&uid, max_id.as_deref(), count).await {
            Ok(v) => return serde_json::to_string(&v).map_err(|e| e.to_string()),
            Err(e) => mob_err = Some(e.to_string()),
        }
    }
    if engine.clean_active_web_cookie().is_some() {
        let mut q = vec![
            ("convert_emoji", "1".to_string()),
            ("count", count.to_string()),
            ("uid", uid),
            ("is_include_group", "0".to_string()),
        ];
        if let Some(m) = max_id.filter(|s| !s.is_empty()) {
            q.push(("max_id", m));
        }
        let val = engine
            .web_request(
                "GET",
                "https://api.weibo.com/webim/2/direct_messages/recent_messages.json",
                &q,
                None,
                "https://api.weibo.com/chat",
            )
            .await?;
        return serde_json::to_string(&val).map_err(|e| e.to_string());
    }
    Err(mob_err.unwrap_or_else(|| "当前账号无私信权限，请在账号管理页补充网页授权".to_string()))
}

pub async fn dm_send_dual(uid: String, text: String) -> Result<String, String> {
    let engine = core()?;
    let mut mob_err: Option<String> = None;
    if engine.active_session_has_gsid() {
        match engine.api_cn.dm_create(&uid, &text).await {
            Ok(v) => return serde_json::to_string(&v).map_err(|e| e.to_string()),
            Err(e) => mob_err = Some(e.to_string()),
        }
    }
    if engine.clean_active_web_cookie().is_some() {
        let val = engine
            .web_request(
                "POST",
                "https://api.weibo.com/webim/2/direct_messages/new.json",
                &[],
                Some(&[("text", text), ("uid", uid)]),
                "https://api.weibo.com/chat",
            )
            .await?;
        return serde_json::to_string(&val).map_err(|e| e.to_string());
    }
    Err(mob_err.unwrap_or_else(|| "发送私信需要网页授权或私信权限".to_string()))
}

pub async fn status_show_dual(id: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    if engine.active_session_has_gsid() || engine.clean_active_web_cookie().is_none() {
        if let Ok(v) = engine.api_cn.status_show(&id).await {
            return serde_json::to_string(&v).map_err(|e| e.to_string());
        }
    }
    let val = engine.web_ajax_get("ajax/statuses/show", &[("id", id)]).await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn status_longtext_dual(id: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    if let Ok(v) = engine.api_cn.status_extend(&id).await {
        let txt = v
            .get("longTextContent")
            .or_else(|| v.pointer("/data/longTextContent"))
            .and_then(|x| x.as_str())
            .unwrap_or_default();
        if !txt.is_empty() {
            return Ok(txt.to_string());
        }
    }
    if let Ok(v) = engine.api_cn.status_show(&id).await {
        let txt = v
            .pointer("/longText/longTextContent")
            .or_else(|| v.get("longTextContent"))
            .or_else(|| v.pointer("/data/longTextContent"))
            .and_then(|x| x.as_str())
            .unwrap_or_default();
        if !txt.is_empty() {
            return Ok(txt.to_string());
        }
    }
    let val = engine
        .web_ajax_get_or_visitor("ajax/statuses/longtext", &[("id", id)])
        .await?;
    Ok(val
        .pointer("/data/longTextContent")
        .or_else(|| val.get("longTextContent"))
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string())
}

pub async fn comments_dual(
    status_id: String,
    author_uid: String,
    flow: u32,
    max_id: Option<String>,
    page: u32,
    count: u32,
) -> Result<String, String> {
    let engine = core()?;
    let mut empty_fallback: Option<Value> = None;
    if engine.active_session_has_gsid() || engine.clean_active_web_cookie().is_none() {
        let _ = engine.api_cn.ensure_guest_or_user().await;
        // Share APK (`InterfaceC2935jA:204`) primarily uses `comments/build_comments`
        // (returns `root_comments[]`) and falls back to `comments/show`.
        match engine
            .api_cn
            .build_comments(&status_id, max_id.as_deref(), flow as u8, count, max_id.is_none())
            .await
        {
            Ok(v) if !comments_empty(&v) => {
                return serde_json::to_string(&v).map_err(|e| e.to_string());
            }
            Ok(v) => empty_fallback = Some(v),
            Err(_) => {}
        }
        match engine
            .api_cn
            .comments_show(&status_id, max_id.as_deref(), page, count)
            .await
        {
            Ok(v) if !comments_empty(&v) => {
                return serde_json::to_string(&v).map_err(|e| e.to_string());
            }
            Ok(v) if empty_fallback.is_none() => empty_fallback = Some(v),
            Ok(_) | Err(_) => {}
        }
    }
    let mut q = vec![
        ("is_reload", "1".to_string()),
        ("id", resolve_numeric_status_id(&status_id)),
        ("is_show_bulletin", "2".to_string()),
        ("is_mix", "0".to_string()),
        ("count", count.to_string()),
        ("uid", author_uid),
        ("flow", flow.to_string()),
    ];
    if let Some(m) = max_id.filter(|s| !s.is_empty()) {
        q.push(("max_id", m));
    }
    if let Ok(val) = engine.web_ajax_get_or_visitor("ajax/statuses/buildComments", &q).await {
        if !comments_empty(&val) || empty_fallback.is_none() {
            return serde_json::to_string(&val).map_err(|e| e.to_string());
        }
    }
    if let Some(v) = empty_fallback {
        return serde_json::to_string(&v).map_err(|e| e.to_string());
    }
    Ok("{\"root_comments\":[],\"total_number\":0}".to_string())
}

/// 楼中楼 / 跟评列表（`fetch_level=1`）：先走移动端 `/2/comments/build_comments`，
/// 回退至 `ajax/statuses/buildComments?is_mix=1&fetch_level=1`（支持游客 SUB 与短信账户）。
pub async fn comment_replies_dual(
    comment_id: String,
    max_id: Option<String>,
    flow: u32,
    count: u32,
) -> Result<String, String> {
    let engine = core()?;
    let mut empty_fallback: Option<Value> = None;
    if engine.active_session_has_gsid() || engine.clean_active_web_cookie().is_none() {
        let _ = engine.api_cn.ensure_guest_or_user().await;
        match engine
            .api_cn
            .build_comments_level(&comment_id, max_id.as_deref(), flow as u8, count, max_id.is_none(), 1)
            .await
        {
            Ok(v) if !comments_empty(&v) => {
                return serde_json::to_string(&v).map_err(|e| e.to_string());
            }
            Ok(v) => empty_fallback = Some(v),
            Err(_) => {}
        }
    }
    let mut q = vec![
        ("flow", flow.to_string()),
        ("is_reload", "1".to_string()),
        ("id", resolve_numeric_status_id(&comment_id)),
        ("is_show_bulletin", "2".to_string()),
        ("is_mix", "1".to_string()),
        ("fetch_level", "1".to_string()),
        ("count", count.to_string()),
    ];
    if let Some(m) = max_id.filter(|s| !s.is_empty()) {
        q.push(("max_id", m));
    }
    if let Ok(val) = engine.web_ajax_get_or_visitor("ajax/statuses/buildComments", &q).await {
        if !comments_empty(&val) || empty_fallback.is_none() {
            return serde_json::to_string(&val).map_err(|e| e.to_string());
        }
    }
    if let Some(v) = empty_fallback {
        return serde_json::to_string(&v).map_err(|e| e.to_string());
    }
    Ok("{\"data\":[],\"total_number\":0}".to_string())
}

pub async fn repost_list_dual(status_id: String, page: u32) -> Result<String, String> {
    let engine = core()?;
    let mut mobile_fallback: Option<Value> = None;
    if engine.active_session_has_gsid() {
        if let Ok(v) = engine.api_cn.repost_timeline(&status_id, page, 20).await {
            if !reposts_empty(&v) {
                return serde_json::to_string(&v).map_err(|e| e.to_string());
            }
            mobile_fallback = Some(v);
        }
        if let Ok(v) = engine.api_cn.get_2(
            "statuses/hot_repost_timeline",
            {
                let mut p = BTreeMap::new();
                p.insert("id".to_string(), resolve_numeric_status_id(&status_id));
                p.insert("page".to_string(), page.max(1).to_string());
                p.insert("count".to_string(), "20".to_string());
                p
            },
        ).await {
            if !reposts_empty(&v) {
                return serde_json::to_string(&v).map_err(|e| e.to_string());
            }
            mobile_fallback.get_or_insert(v);
        }
    }
    match engine
        .web_ajax_get_or_visitor(
            "ajax/statuses/repostTimeline",
            &[
                ("id", resolve_numeric_status_id(&status_id)),
                ("page", page.max(1).to_string()),
                ("moduleID", "feed".to_string()),
            ],
        )
        .await
    {
        Ok(val) if !reposts_empty(&val) || mobile_fallback.is_none() => {
            serde_json::to_string(&val).map_err(|e| e.to_string())
        }
        Ok(_) => serde_json::to_string(mobile_fallback.as_ref().unwrap()).map_err(|e| e.to_string()),
        Err(e) => {
            if let Some(v) = mobile_fallback {
                serde_json::to_string(&v).map_err(|e| e.to_string())
            } else {
                Err(e)
            }
        }
    }
}

pub async fn likers_dual(status_id: String, page: u32, count: u32) -> Result<String, String> {
    let engine = core()?;
    let mut mobile_fallback: Option<Value> = None;
    if engine.active_session_has_gsid() {
        if let Ok(v) = engine.api_cn.like_show(&status_id, page, count).await {
            if !likers_empty(&v) {
                return serde_json::to_string(&v).map_err(|e| e.to_string());
            }
            mobile_fallback = Some(v);
        }
    }
    match engine
        .web_ajax_get_or_visitor(
            "ajax/statuses/likeShow",
            &[
                ("id", resolve_numeric_status_id(&status_id)),
                ("attitude_type", "0".to_string()),
                ("attitude_enable", "1".to_string()),
                ("page", page.max(1).to_string()),
                ("count", count.to_string()),
            ],
        )
        .await
    {
        Ok(val) if !likers_empty(&val) || mobile_fallback.is_none() => {
            serde_json::to_string(&val).map_err(|e| e.to_string())
        }
        Ok(_) => serde_json::to_string(mobile_fallback.as_ref().unwrap()).map_err(|e| e.to_string()),
        Err(e) => {
            if let Some(v) = mobile_fallback {
                serde_json::to_string(&v).map_err(|e| e.to_string())
            } else {
                Err(e)
            }
        }
    }
}

pub async fn like_dual(status_id: String, undo: bool) -> Result<(), String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        match engine.api_cn.like_status(&status_id, undo).await {
            Ok(_) => return Ok(()),
            Err(e) if engine.clean_active_web_cookie().is_none() => return Err(e.to_string()),
            Err(_) => {}
        }
    }
    let action = if undo { "ajax/statuses/cancelLike" } else { "ajax/statuses/setLike" };
    engine
        .web_ajax_post(action, &[("id", resolve_numeric_status_id(&status_id))])
        .await?;
    Ok(())
}

pub async fn favorite_dual(status_id: String, undo: bool) -> Result<(), String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        match engine.api_cn.favorite_status(&status_id, undo).await {
            Ok(_) => return Ok(()),
            Err(e) if engine.clean_active_web_cookie().is_none() => return Err(e.to_string()),
            Err(_) => {}
        }
    }
    let action = if undo {
        "ajax/statuses/destoryFavorites"
    } else {
        "ajax/statuses/createFavorites"
    };
    engine
        .web_ajax_post(action, &[("id", resolve_numeric_status_id(&status_id))])
        .await?;
    Ok(())
}

pub async fn favorites_dual(page: u32, count: u32) -> Result<String, String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        if let Ok(v) = engine.api_cn.favorites_list(page, count).await {
            return serde_json::to_string(&v).map_err(|e| e.to_string());
        }
    }
    let val = engine
        .web_ajax_get("ajax/favorites/all_fav", &[("page", page.max(1).to_string())])
        .await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn liked_statuses_dual(uid: String, page: u32) -> Result<String, String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        if let Ok(card_val) = engine.api_cn.cardlist(&format!("230869{uid}_-_mix"), page, None).await {
            let cards = extract_mblogs_from_cardlist(&card_val);
            if !cards.is_empty() {
                return serde_json::to_string(&json!({
                    "statuses": cards,
                    "total": card_val.pointer("/cardlistInfo/total").cloned().unwrap_or(Value::Null),
                }))
                .map_err(|e| e.to_string());
            }
        }
    }
    let val = engine
        .web_ajax_get(
            "ajax/statuses/likelist",
            &[
                ("uid", uid),
                ("page", page.max(1).to_string()),
                ("with_total", "true".to_string()),
            ],
        )
        .await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn comment_create_dual(status_id: String, text: String) -> Result<String, String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        match engine.api_cn.comment_create(&status_id, &text).await {
            Ok(v) => return serde_json::to_string(&v).map_err(|e| e.to_string()),
            Err(e) if engine.clean_active_web_cookie().is_none() => return Err(e.to_string()),
            Err(_) => {}
        }
    }
    let val = engine
        .web_ajax_post(
            "ajax/comments/create",
            &[
                ("id", resolve_numeric_status_id(&status_id)),
                ("comment", text),
                ("comment_ori", "0".to_string()),
                ("is_repost", "0".to_string()),
                ("_t", "0".to_string()),
            ],
        )
        .await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn comment_reply_dual(
    status_id: String,
    cid: String,
    text: String,
) -> Result<String, String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        match engine.api_cn.comment_reply(&status_id, &cid, &text).await {
            Ok(v) => return serde_json::to_string(&v).map_err(|e| e.to_string()),
            Err(e) if engine.clean_active_web_cookie().is_none() => return Err(e.to_string()),
            Err(_) => {}
        }
    }
    let val = engine
        .web_ajax_post(
            "ajax/comments/reply",
            &[
                ("id", resolve_numeric_status_id(&status_id)),
                ("cid", resolve_numeric_status_id(&cid)),
                ("comment", text),
                ("without_mention", "0".to_string()),
                ("is_repost", "0".to_string()),
            ],
        )
        .await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn comment_like_dual(cid: String, undo: bool) -> Result<(), String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        match engine.api_cn.like_comment(&cid, undo).await {
            Ok(_) => return Ok(()),
            Err(e) if engine.clean_active_web_cookie().is_none() => return Err(e.to_string()),
            Err(_) => {}
        }
    }
    let action = if undo {
        "ajax/comments/cancelLike"
    } else {
        "ajax/comments/like"
    };
    engine
        .web_ajax_post(action, &[("id", resolve_numeric_status_id(&cid))])
        .await?;
    Ok(())
}

pub async fn translate_status_dual(idstr: String, locale: String) -> Result<String, String> {
    let engine = core()?;
    let val = engine
        .web_ajax_get_or_visitor(
            "ajax/statuses/translate",
            &[
                ("cid", resolve_numeric_status_id(&idstr)),
                ("locale", locale),
            ],
        )
        .await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn hot_search_bands_dual() -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let mobile_res = engine
        .api_cn
        .cardlist(
            "106003type=25&t=3&disable_hot=1&filter_type=realtimehot",
            1,
            None,
        )
        .await;
    let band_res = engine
        .web_ajax_get_or_visitor("ajax/statuses/hot_band", &[])
        .await;
    let realtime_res = engine
        .web_ajax_get_or_visitor("ajax/side/hotSearch", &[])
        .await;

    let mobile = mobile_res.ok().unwrap_or(Value::Null);
    let band = band_res.as_ref().ok().cloned().unwrap_or(Value::Null);
    let realtime = realtime_res.as_ref().ok().cloned().unwrap_or(Value::Null);

    if mobile.is_null() && band.is_null() && realtime.is_null() {
        return Err(band_res
            .err()
            .or_else(|| realtime_res.err())
            .unwrap_or_else(|| "加载热搜失败".to_string()));
    }
    Ok(serde_json::json!({
        "mobile": mobile,
        "band": band,
        "realtime": realtime,
    })
    .to_string())
}

pub async fn repost_dual(status_id: String, text: String, also_comment: bool) -> Result<String, String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        match engine.api_cn.status_repost(&status_id, &text, also_comment).await {
            Ok(v) => return serde_json::to_string(&v).map_err(|e| e.to_string()),
            Err(e) if engine.clean_active_web_cookie().is_none() => return Err(e.to_string()),
            Err(_) => {}
        }
    }
    let val = engine
        .web_ajax_post(
            "ajax/statuses/repost",
            &[
                ("id", resolve_numeric_status_id(&status_id)),
                ("status", text),
                ("is_comment", if also_comment { "1" } else { "0" }.to_string()),
                ("_t", "0".to_string()),
            ],
        )
        .await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn publish_dual(
    text: String,
    visible: u32,
    pic_ids: String,
    tail: Option<String>,
) -> Result<String, String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        match engine
            .api_cn
            .status_send_with_tail(&text, visible, &pic_ids, tail.as_deref())
            .await
        {
            Ok(v) => return serde_json::to_string(&v).map_err(|e| e.to_string()),
            Err(e) if engine.clean_active_web_cookie().is_none() => return Err(e.to_string()),
            Err(_) => {}
        }
    }
    let val = engine
        .web_ajax_post(
            "ajax/statuses/update",
            &[
                ("status", text),
                ("visible", visible.to_string()),
                ("pics", pic_ids),
                ("videos", String::new()),
                ("_t", "0".to_string()),
            ],
        )
        .await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn follow_dual(uid: String, undo: bool) -> Result<(), String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        match engine.api_cn.friendships_follow(&uid, undo).await {
            Ok(_) => return Ok(()),
            Err(e) if engine.clean_active_web_cookie().is_none() => return Err(e.to_string()),
            Err(_) => {}
        }
    }
    let action = if undo { "ajax/friendships/destroy" } else { "ajax/friendships/create" };
    engine.web_ajax_post(action, &[("uid", uid), ("_t", "0".to_string())]).await?;
    Ok(())
}

pub async fn delete_status_dual(status_id: String) -> Result<(), String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        match engine.api_cn.status_destroy(&status_id).await {
            Ok(_) => return Ok(()),
            Err(e) if engine.clean_active_web_cookie().is_none() => return Err(e.to_string()),
            Err(_) => {}
        }
    }
    engine
        .web_ajax_post("ajax/statuses/destroy", &[("id", resolve_numeric_status_id(&status_id))])
        .await?;
    Ok(())
}

pub async fn groups_dual() -> Result<String, String> {
    let engine = core()?;
    if engine.active_session_has_gsid() {
        if let Ok(v) = engine.api_cn.groups_list().await {
            if v.get("lists").and_then(|x| x.as_array()).is_some_and(|a| !a.is_empty()) {
                return serde_json::to_string(&v).map_err(|e| e.to_string());
            }
        }
    }
    let val = engine.web_ajax_get("ajax/feed/allGroups", &[]).await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn search_statuses_dual(keyword: String, page: u32, count: u32) -> Result<String, String> {
    search_typed_dual(keyword, "all".to_string(), page, count).await
}

/// 分类搜索：`all` (type=1 综合) / `realtime` (type=61 实时) / `user` (type=3 用户) / `video` (type=64 视频)。
pub async fn search_typed_dual(
    keyword: String,
    search_type: String,
    page: u32,
    count: u32,
) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let container_type = match search_type.as_str() {
        "realtime" => 61,
        "user" => 3,
        "video" => 64,
        _ => 1,
    };
    if let Ok(val) = engine
        .api_cn
        .searchall_typed(&keyword, container_type, page, count)
        .await
    {
        if search_type == "user" {
            let users = extract_users_from_cardlist(&val);
            if !users.is_empty() {
                return serde_json::to_string(&json!({ "users": users })).map_err(|e| e.to_string());
            }
        } else {
            let cards = extract_mblogs_from_cardlist(&val);
            if !cards.is_empty() {
                return serde_json::to_string(&json!({ "statuses": cards }))
                    .map_err(|e| e.to_string());
            }
        }
    }
    if search_type == "user" {
        if let Ok(val) = engine
            .web_ajax_get_or_visitor("ajax/side/search", &[("q", keyword.clone())])
            .await
        {
            return serde_json::to_string(&val).map_err(|e| e.to_string());
        }
    }
    let val = engine
        .web_ajax_get_or_visitor(
            "ajax/statuses/search",
            &[
                ("q", keyword),
                ("count", count.to_string()),
                ("page", page.max(1).to_string()),
            ],
        )
        .await?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn topic_checkin(request_url: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let val = engine
        .api_cn
        .page_button(&request_url)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn cardlist_get(
    containerid: String,
    page: u32,
    since_id: Option<String>,
) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let val = engine
        .api_cn
        .cardlist(&containerid, page, since_id.as_deref())
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn page_get(containerid: String, page: u32) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let val = engine
        .api_cn
        .page_info(&containerid, page)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn article_show(oid: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let val = engine
        .api_cn
        .article_show(&oid)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn qa_show(oid: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let val = engine
        .api_cn
        .question_show(&oid)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn qa_watch(oid: String) -> Result<String, String> {
    let engine = core()?;
    let val = engine
        .api_cn
        .question_watch(&oid)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn video_playback(object_ids: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let val = engine
        .api_cn
        .video_playback_batch_get(&object_ids)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn short_url_expand(url_short: String) -> Result<String, String> {
    let engine = core()?;
    let _ = engine.api_cn.ensure_guest_or_user().await;
    let val = engine
        .api_cn
        .short_url_expand(&url_short)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn profile_edit(fields_json: String) -> Result<String, String> {
    mobile_post("users/update".to_string(), "{}".to_string(), fields_json).await
}

pub async fn upload_avatar(bytes: Vec<u8>, filename: String) -> Result<String, String> {
    let engine = core()?;
    // First upload pic via mss, or post directly to account/avatar_upload if endpoint expects multipart
    let pic_val = engine
        .api_cn
        .upload_pic_mss(bytes, &filename, "image/jpeg")
        .await
        .map_err(|e| e.to_string())?;
    let pic_id = pic_val
        .get("pic_id")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    if pic_id.is_empty() {
        return serde_json::to_string(&pic_val).map_err(|e| e.to_string());
    }
    let form = serde_json::to_string(&json!({ "pic_id": pic_id })).map_err(|e| e.to_string())?;
    mobile_post("account/avatar_upload".to_string(), "{}".to_string(), form).await
}

pub async fn friends_list(uid: String, page: u32, count: u32, trim_status: i32) -> Result<String, String> {
    let p = json!({
        "uid": uid,
        "page": page.max(1).to_string(),
        "count": count.clamp(1, 200).to_string(),
        "trim_status": trim_status.to_string(),
    });
    mobile_get("friendships/friends".to_string(), p.to_string()).await
}

pub async fn remove_follower(uid: String) -> Result<String, String> {
    let p = json!({ "uid": uid });
    mobile_get("friendships/followers_destroy".to_string(), p.to_string()).await
}

pub async fn update_remark(uid: String, remark: String) -> Result<String, String> {
    let p = json!({ "uid": uid, "remark": remark });
    mobile_post("friendships/remark_update".to_string(), "{}".to_string(), p.to_string()).await
}

/// Unified group CRUD (`op`: `"list" | "all" | "allmembers" | "create" | "update" | "destroy"`).
pub async fn group_crud(op: String, params_json: String) -> Result<String, String> {
    match op.as_str() {
        "list" => mobile_get("groups".to_string(), params_json).await,
        "all" => mobile_get("groups/allgroups".to_string(), params_json).await,
        "allmembers" => mobile_get("groups/allmembers".to_string(), params_json).await,
        "create" => mobile_post("groups/create".to_string(), "{}".to_string(), params_json).await,
        "update" => mobile_post("groups/update".to_string(), "{}".to_string(), params_json).await,
        "destroy" => mobile_post("!/groups/destroy".to_string(), "{}".to_string(), params_json).await,
        _ => Err(format!("Unsupported group_crud op: {op}")),
    }
}

pub async fn group_order(list_ids_csv: String) -> Result<String, String> {
    let p = json!({ "list_ids": list_ids_csv });
    mobile_post("groups/order".to_string(), "{}".to_string(), p.to_string()).await
}

pub async fn group_members_edit(
    add: bool,
    list_id: String,
    uids_csv: String,
) -> Result<String, String> {
    let path = if add {
        "groups/members_add"
    } else {
        "groups/members_destroy"
    };
    let p = json!({ "list_id": list_id, "uids": uids_csv });
    mobile_post(path.to_string(), "{}".to_string(), p.to_string()).await
}

pub async fn block_user(block: bool, uid: String) -> Result<String, String> {
    let path = if block {
        "blocks/create"
    } else {
        "blocks/destroy"
    };
    let p = json!({ "uid": uid });
    mobile_post(path.to_string(), "{}".to_string(), p.to_string()).await
}

pub async fn filter_status(status_id: String, filter_type: i32) -> Result<String, String> {
    let p = json!({ "id": status_id, "type": filter_type.to_string() });
    mobile_post("statuses/filter_create".to_string(), "{}".to_string(), p.to_string()).await
}

pub async fn status_set_top(is_top: bool, status_id: String) -> Result<String, String> {
    let path = if is_top {
        "users/set_top_status"
    } else {
        "users/cancel_top_status"
    };
    let p = json!({ "id": status_id });
    mobile_post(path.to_string(), "{}".to_string(), p.to_string()).await
}

pub async fn status_modify_visible(status_id: String, visible: i32) -> Result<String, String> {
    let p = json!({ "id": status_id, "visible": visible.to_string() });
    mobile_post("statuses/modify_visible".to_string(), "{}".to_string(), p.to_string()).await
}

pub async fn status_modify(status_id: String, content: String, pic_id: Option<String>) -> Result<String, String> {
    let mut obj = BTreeMap::new();
    obj.insert("id".to_string(), Value::String(status_id));
    obj.insert("status".to_string(), Value::String(content));
    if let Some(pids) = pic_id.filter(|s| !s.is_empty()) {
        obj.insert("pic_id".to_string(), Value::String(pids));
    }
    mobile_post(
        "statuses/modify_weibo".to_string(),
        "{}".to_string(),
        Value::Object(obj.into_iter().collect()).to_string(),
    )
    .await
}

pub async fn comment_delete(cid: String, block_and_delete: bool) -> Result<String, String> {
    let path = if block_and_delete {
        "comments/block_and_delete"
    } else {
        "comments/destroy"
    };
    let p = json!({ "cid": cid });
    mobile_get(path.to_string(), p.to_string()).await
}

pub async fn comment_approval(op: String, params_json: String) -> Result<String, String> {
    match op.as_str() {
        "list" => mobile_get("comments/approval_list".to_string(), params_json).await,
        "update" => mobile_get("comments/approval_update".to_string(), params_json).await,
        "permission" => mobile_get("comments/permission_update".to_string(), params_json).await,
        _ => Err(format!("Unsupported comment_approval op: {op}")),
    }
}

pub async fn nearby_pois(lat: f64, lon: f64, q: Option<String>, page: u32) -> Result<String, String> {
    let mut obj = serde_json::Map::new();
    obj.insert("lat".to_string(), Value::String(lat.to_string()));
    obj.insert("long".to_string(), Value::String(lon.to_string()));
    obj.insert("page".to_string(), Value::String(page.max(1).to_string()));
    obj.insert("count".to_string(), Value::String("25".to_string()));
    if let Some(query) = q.filter(|s| !s.is_empty()) {
        obj.insert("q".to_string(), Value::String(query));
    }
    mobile_get("place/nearby_pois".to_string(), Value::Object(obj).to_string()).await
}

pub async fn publisher_list() -> Result<String, String> {
    mobile_get("client/publisher_list".to_string(), "{}".to_string()).await
}

// ============================================================================
// SQLite 9-Table DAOs: Drafts, History, Blacklist (.share_backup), Followers, Groups
// ============================================================================

pub async fn draft_save(draft: DraftDto) -> Result<i64, String> {
    let engine = core()?;
    let dao = DraftDao::new(&engine.db);
    let entity = StatusDraftEntity {
        id: if draft.id > 0 { Some(draft.id) } else { None },
        content: draft.content,
        date: if draft.date > 0 { draft.date } else { now_millis() },
        urls: non_empty(draft.urls_json),
        uid: draft.uid,
        target_status_json: non_empty(draft.target_status_json),
        target_status_id: non_empty(draft.target_status_id),
        target_comment_id: non_empty(draft.target_comment_id),
        target_comment_user_name: non_empty(draft.target_comment_user_name),
        target_comment_content: non_empty(draft.target_comment_content),
        assign_group_id_str: non_empty(draft.assign_group_id_str),
        assign_group_type: Some(draft.assign_group_type),
        address: non_empty(draft.address),
        publish_timing: Some(draft.publish_timing),
        is_comment_origin: Some(if draft.is_comment_origin { 1 } else { 0 }),
        status: draft.status,
        is_mention: Some(if draft.is_mention { 1 } else { 0 }),
        state: Some(draft.state),
        extra: non_empty(draft.extra_json),
        type_: Some(draft.type_code),
        parent_type: Some(draft.parent_type),
    };
    dao.insert(&entity).map_err(|e| e.to_string())
}

pub async fn draft_list(uid: String) -> Result<Vec<DraftDto>, String> {
    let engine = core()?;
    let list = DraftDao::new(&engine.db)
        .list_by_uid(&uid)
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(draft_to_dto).collect())
}

pub async fn draft_update_status(id: i64, status: i32) -> Result<bool, String> {
    DraftDao::new(&core()?.db)
        .update_status(id, status)
        .map_err(|e| e.to_string())
}

pub async fn draft_delete(id: i64) -> Result<bool, String> {
    DraftDao::new(&core()?.db)
        .delete_by_id(id)
        .map_err(|e| e.to_string())
}

pub async fn draft_clear(uid: String) -> Result<usize, String> {
    DraftDao::new(&core()?.db)
        .delete_all_by_uid(&uid)
        .map_err(|e| e.to_string())
}

pub async fn history_record_status(
    uid: String,
    status_id: String,
    username: String,
    _avatar: String,
    total_text: String,
    status_json: String,
) -> Result<i64, String> {
    let engine = core()?;
    let entity = StatusHistoryEntity {
        id: None,
        status_id,
        username: non_empty(username),
        total_text: non_empty(total_text),
        uid,
        json: status_json,
        create_at: now_millis(),
    };
    HistoryDao::new(&engine.db)
        .record_status_view(&entity)
        .map_err(|e| e.to_string())
}

pub async fn history_list_statuses(
    uid: String,
    limit: u32,
    offset: u32,
) -> Result<Vec<StatusHistoryDto>, String> {
    let list = HistoryDao::new(&core()?.db)
        .list_status_history(&uid, limit as usize, offset as usize)
        .map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|h| {
            let avatar = serde_json::from_str::<Value>(&h.json)
                .ok()
                .and_then(|v| {
                    v.pointer("/user/avatar_hd")
                        .or_else(|| v.pointer("/user/profile_image_url"))
                        .and_then(|s| s.as_str())
                        .map(str::to_string)
                })
                .unwrap_or_default();
            StatusHistoryDto {
                id: h.id.unwrap_or(0),
                status_id: h.status_id,
                username: h.username.unwrap_or_default(),
                avatar,
                total_text: h.total_text.unwrap_or_default(),
                status_json: h.json,
                uid: h.uid,
                create_at: h.create_at,
            }
        })
        .collect())
}

pub async fn history_clear_statuses(uid: String) -> Result<usize, String> {
    HistoryDao::new(&core()?.db)
        .clear_status_history(&uid)
        .map_err(|e| e.to_string())
}

pub async fn history_record_user(
    uid: String,
    target_uid: String,
    target_user_name: String,
    target_user_avatar: String,
    user_json: String,
) -> Result<(), String> {
    HistoryDao::new(&core()?.db)
        .record_user_visit(
            &uid,
            &target_uid,
            &target_user_name,
            non_empty(target_user_avatar).as_deref(),
            non_empty(user_json).as_deref(),
            now_millis(),
        )
        .map_err(|e| e.to_string())
}

pub async fn history_list_users(uid: String, limit: u32) -> Result<Vec<UserHistoryDto>, String> {
    let list = HistoryDao::new(&core()?.db)
        .list_user_history(&uid, limit as usize)
        .map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|u| UserHistoryDto {
            id: u.id.unwrap_or(0),
            target_uid: u.target_uid,
            target_user_name: u.target_user_name,
            target_user_avatar: u.target_user_avatar.unwrap_or_default(),
            user_json: u.json.unwrap_or_default(),
            uid: u.uid,
            visit_count: u.visit_count,
            create_at: u.create_at,
        })
        .collect())
}

pub async fn history_clear_users(uid: String) -> Result<usize, String> {
    HistoryDao::new(&core()?.db)
        .clear_user_history(&uid)
        .map_err(|e| e.to_string())
}

pub async fn blacklist_list(
    uid: String,
    rule_type: Option<i32>,
) -> Result<Vec<BlacklistRuleDto>, String> {
    let list = BlackListDao::new(&core()?.db)
        .list_by_uid(&uid, rule_type)
        .map_err(|e| e.to_string())?;
    Ok(list.into_iter().map(blacklist_to_dto).collect())
}

pub async fn blacklist_upsert(
    uid: String,
    key: String,
    info: String,
    rule_type: i32,
    state: i32,
    black_type: i32,
) -> Result<i64, String> {
    let entity = BlackListEntity {
        id: None,
        key,
        uid,
        info: non_empty(info),
        type_: rule_type,
        state,
        black_type,
    };
    BlackListDao::new(&core()?.db)
        .insert(&entity)
        .map_err(|e| e.to_string())
}

pub async fn blacklist_toggle(id: i64, state: i32) -> Result<bool, String> {
    core()?
        .db
        .with_conn(|conn| {
            let affected = conn.execute(
                "UPDATE \"BLACK_LIST\" SET \"STATE\" = ?1 WHERE \"_id\" = ?2;",
                params![state, id],
            )?;
            Ok(affected > 0)
        })
        .map_err(|e| e.to_string())
}

pub async fn blacklist_delete(id: i64) -> Result<bool, String> {
    core()?
        .db
        .with_conn(|conn| {
            let affected = conn.execute(
                "DELETE FROM \"BLACK_LIST\" WHERE \"_id\" = ?1;",
                params![id],
            )?;
            Ok(affected > 0)
        })
        .map_err(|e| e.to_string())
}

/// Exports `BLACK_LIST` rules into a JSON string compatible with `.share_backup`.
pub async fn blacklist_export_backup(uid: String) -> Result<String, String> {
    let rules = blacklist_list(uid.clone(), None).await?;
    serde_json::to_string_pretty(&json!({
        "version": 1,
        "uid": uid,
        "exported_at": now_millis(),
        "black_list": rules,
    }))
    .map_err(|e| e.to_string())
}

/// Imports rules from a `.share_backup` JSON string (or bare JSON array) into `BLACK_LIST`.
pub async fn blacklist_import_backup(uid: String, backup_json: String) -> Result<usize, String> {
    let val: Value = serde_json::from_str(&backup_json)
        .map_err(|e| format!("Invalid .share_backup JSON: {e}"))?;
    let arr = val
        .get("black_list")
        .and_then(|v| v.as_array())
        .or_else(|| val.as_array())
        .ok_or_else(|| "Backup JSON missing 'black_list' array".to_string())?;

    let dao = BlackListDao::new(&core()?.db);
    let mut count = 0usize;
    for item in arr {
        let key = item
            .get("key")
            .or_else(|| item.get("KEY"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .trim()
            .to_string();
        if key.is_empty() {
            continue;
        }
        let info = item
            .get("info")
            .or_else(|| item.get("INFO"))
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let rule_type = item
            .get("rule_type")
            .or_else(|| item.get("type"))
            .or_else(|| item.get("TYPE"))
            .and_then(|v| v.as_i64())
            .unwrap_or(1) as i32;
        let state = item
            .get("state")
            .or_else(|| item.get("STATE"))
            .and_then(|v| v.as_i64())
            .unwrap_or(1) as i32;
        let black_type = item
            .get("black_type")
            .or_else(|| item.get("BLACK_TYPE"))
            .and_then(|v| v.as_i64())
            .unwrap_or(1) as i32;

        dao.insert(&BlackListEntity {
            id: None,
            key,
            uid: uid.clone(),
            info,
            type_: rule_type,
            state,
            black_type,
        })
        .map_err(|e| e.to_string())?;
        count += 1;
    }
    Ok(count)
}

/// Applies local `BLACK_LIST` filters to an arbitrary timeline JSON array string.
pub async fn blacklist_filter_statuses_json(uid: String, statuses_json: String) -> Result<String, String> {
    let mut val: Value = serde_json::from_str(&statuses_json).map_err(|e| e.to_string())?;
    let engine = core()?;
    filter_value_with_uid(engine, &uid, &mut val);
    serde_json::to_string(&val).map_err(|e| e.to_string())
}

pub async fn followers_replace_batch(uid: String, users_json: String) -> Result<usize, String> {
    let val: Value = serde_json::from_str(&users_json).map_err(|e| e.to_string())?;
    let arr = val
        .get("users")
        .and_then(|v| v.as_array())
        .or_else(|| val.as_array())
        .ok_or_else(|| "Expected users array JSON".to_string())?;
    let mut entities = Vec::with_capacity(arr.len());
    for u in arr {
        let tid = u.get("idstr").or_else(|| u.get("id")).map(json_id_to_string).unwrap_or_default();
        let name = u
            .get("screen_name")
            .or_else(|| u.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        if tid.is_empty() || name.is_empty() {
            continue;
        }
        entities.push(FollowerEntity {
            id: None,
            uid: uid.clone(),
            tid,
            name,
            pinyin_name: u.get("pinyin_name").and_then(|v| v.as_str()).map(str::to_string),
            gender: u.get("gender").and_then(|v| v.as_str()).map(str::to_string),
            description: u.get("description").and_then(|v| v.as_str()).map(str::to_string),
            avatar: u
                .get("avatar_hd")
                .or_else(|| u.get("profile_image_url"))
                .and_then(|v| v.as_str())
                .map(str::to_string),
            verified: u.get("verified").and_then(|v| v.as_bool()).map(|b| if b { 1 } else { 0 }),
            verified_type: u.get("verified_type").and_then(|v| v.as_i64()).map(|n| n as i32),
            following: u.get("following").and_then(|v| v.as_bool()).map(|b| if b { 1 } else { 0 }),
            follow_me: u.get("follow_me").and_then(|v| v.as_bool()).map(|b| if b { 1 } else { 0 }),
        });
    }
    let len = entities.len();
    FollowerDao::new(&core()?.db)
        .insert_or_replace_batch(&uid, &entities)
        .map_err(|e| e.to_string())?;
    Ok(len)
}

pub async fn followers_search(
    uid: String,
    query: String,
    limit: u32,
) -> Result<Vec<FollowerDto>, String> {
    let dao = FollowerDao::new(&core()?.db);
    let rows = if query.trim().is_empty() {
        dao.list_all(&uid, limit as usize)
    } else {
        dao.search_by_query(&uid, query.trim(), limit as usize)
    }
    .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|f| FollowerDto {
            uid: f.uid,
            tid: f.tid,
            name: f.name,
            pinyin_name: f.pinyin_name.unwrap_or_default(),
            gender: f.gender.unwrap_or_default(),
            description: f.description.unwrap_or_default(),
            avatar: f.avatar.unwrap_or_default(),
            verified: f.verified.unwrap_or(0) == 1,
            following: f.following.unwrap_or(0) == 1,
            follow_me: f.follow_me.unwrap_or(0) == 1,
        })
        .collect())
}

pub async fn groups_cache_replace(uid: String, groups_json: String) -> Result<usize, String> {
    let val: Value = serde_json::from_str(&groups_json).map_err(|e| e.to_string())?;
    let arr = val
        .get("lists")
        .or_else(|| val.get("groups"))
        .and_then(|v| v.as_array())
        .or_else(|| val.as_array())
        .ok_or_else(|| "Expected groups JSON array".to_string())?;

    let mut groups = Vec::with_capacity(arr.len());
    for (idx, g) in arr.iter().enumerate() {
        let gid = g.get("idstr").or_else(|| g.get("gid")).or_else(|| g.get("id")).map(json_id_to_string).unwrap_or_default();
        if gid.is_empty() {
            continue;
        }
        let title = g
            .get("title")
            .or_else(|| g.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        groups.push(GroupListEntity {
            id: None,
            insert_number: idx as i32,
            uid: uid.clone(),
            gid,
            title: title.clone(),
            name: Some(title),
            description: g.get("description").and_then(|v| v.as_str()).map(str::to_string),
            count: g.get("member_count").or_else(|| g.get("count")).and_then(|v| v.as_i64()).map(|n| n as i32),
            type_: g.get("type").and_then(|v| v.as_i64()).map(|n| n as i32),
            visible: Some(g.get("visible").and_then(|v| v.as_i64()).unwrap_or(1) as i32),
            remind: g.get("remind").and_then(|v| v.as_i64()).map(|n| n as i32),
        });
    }
    let len = groups.len();
    GroupDao::new(&core()?.db)
        .replace_all_groups(&uid, &groups)
        .map_err(|e| e.to_string())?;
    Ok(len)
}

pub async fn groups_cache_list(
    uid: String,
    only_visible: bool,
) -> Result<Vec<CachedGroupDto>, String> {
    let list = GroupDao::new(&core()?.db)
        .get_groups(&uid, only_visible)
        .map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|g| CachedGroupDto {
            insert_number: g.insert_number,
            uid: g.uid,
            gid: g.gid,
            title: g.title,
            name: g.name.unwrap_or_default(),
            description: g.description.unwrap_or_default(),
            count: g.count.unwrap_or(0),
            group_type: g.type_.unwrap_or_default().to_string(),
            visible: g.visible.unwrap_or(1) == 1,
            remind: g.remind.unwrap_or(0),
        })
        .collect())
}

pub async fn share_json_get(key: String) -> Result<Option<String>, String> {
    core()?.get_kv(&key)
}

pub async fn share_json_set(key: String, value: String) -> Result<(), String> {
    core()?.set_kv(&key, &value)
}

// ============================================================================
// WeSync Binary Frame Helpers
// ============================================================================

#[flutter_rust_bridge::frb(sync)]
pub fn wesync_encode_frame(cmd: u16, seq: u32, payload: Vec<u8>) -> Vec<u8> {
    let parsed_cmd = WeSyncCommand::from(cmd);
    WeSyncFrame::new(parsed_cmd, seq, payload).encode()
}

#[flutter_rust_bridge::frb(sync)]
pub fn wesync_decode_frame_json(bytes: Vec<u8>) -> Result<String, String> {
    let (frame, consumed) = WeSyncFrame::decode(&bytes).map_err(|e| e.to_string())?;
    let cmd_code: u16 = match frame.cmd {
        WeSyncCommand::Handshake => 11,
        WeSyncCommand::Auth => 13,
        WeSyncCommand::LoginBindUid => 15,
        WeSyncCommand::Heartbeat => 17,
        WeSyncCommand::ServerPush => 19,
        WeSyncCommand::Disconnect => 20,
        WeSyncCommand::DynamicHeartbeat => 35,
        WeSyncCommand::Unknown(c) => c,
    };
    let push = frame.parse_push_payload().ok();
    serde_json::to_string(&json!({
        "cmd": cmd_code,
        "seq": frame.seq,
        "consumed": consumed,
        "payload_len": frame.payload.len(),
        "payload_utf8": String::from_utf8_lossy(&frame.payload),
        "push": push,
    }))
    .map_err(|e| e.to_string())
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn save_login_json_to_db(
    engine: &CoreEngine,
    raw: &Value,
    account_hint: Option<&str>,
    password_plain: Option<&str>,
) -> Result<Option<AccountSummary>, String> {
    let gsid = raw
        .get("gsid")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let uid = raw
        .get("uid")
        .or_else(|| raw.pointer("/user/idstr"))
        .or_else(|| raw.pointer("/user/id"))
        .map(json_id_to_string)
        .unwrap_or_default();

    if uid.is_empty() || gsid.is_empty() {
        return Ok(None);
    }

    let user_obj = raw.get("user");
    let token = raw
        .get("token")
        .or_else(|| raw.get("oauth_token"))
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let cookie = extract_flat_cookie(raw.get("cookie"));
    let snap = engine.api_cn.session();

    let extra = serde_json::to_string(&json!({
        "aid": if snap.aid.is_empty() { raw.get("aid").and_then(|v| v.as_str()).unwrap_or_default() } else { &snap.aid },
        "validator": snap.validator,
    }))
    .ok();

    let entity = UserEntity {
        uid: uid.clone(),
        token,
        parent_type: 0,
        gsid: Some(gsid),
        s_value: Some(crate::crypto::wbutil::new_calculate_s(&uid)),
        i_value: None,
        parent_json: raw.get("user").map(|v| v.to_string()),
        refresh_token: None,
        expires_in: raw.get("expires_in").and_then(|v| v.as_i64()),
        name: user_obj
            .and_then(|u| u.get("screen_name").or_else(|| u.get("name")))
            .and_then(|v| v.as_str())
            .map(str::to_string),
        avatar: user_obj
            .and_then(|u| u.get("avatar_hd").or_else(|| u.get("profile_image_url")))
            .and_then(|v| v.as_str())
            .map(str::to_string),
        gender: user_obj
            .and_then(|u| u.get("gender"))
            .and_then(|v| v.as_str())
            .map(str::to_string),
        sign: user_obj
            .and_then(|u| u.get("description"))
            .and_then(|v| v.as_str())
            .map(str::to_string),
        cover: user_obj
            .and_then(|u| u.get("cover_image_phone"))
            .and_then(|v| v.as_str())
            .map(str::to_string),
        account: account_hint.map(str::to_string),
        password: password_plain.map(str::to_string),
        ad_token: None,
        cookie,
        extra,
        ..Default::default()
    };

    UserDao::new(&engine.db)
        .insert_or_replace(&entity)
        .map_err(|e| e.to_string())?;
    engine.set_kv(ACTIVE_UID_KEY, &uid)?;
    engine.restore_session_into_client()?;
    Ok(Some(user_to_summary(&entity, Some(&uid))))
}

fn apply_user_to_session(user: &UserEntity, sess: &mut MobileSession) {
    sess.uid = user.uid.clone();
    sess.gsid = user.gsid.clone().unwrap_or_default();
    sess.oauth_token = user.token.clone();
    sess.i_value = user.i_value.clone().unwrap_or_default();
    if let Some(c) = user.cookie.as_ref().filter(|s| !s.is_empty()) {
        sess.cookie = normalize_cookie_value(&Value::String(c.clone())).unwrap_or_else(|| c.clone());
    }
    if let Some(extra) = user
        .extra
        .as_ref()
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
    {
        if let Some(aid) = extra.get("aid").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
            sess.aid = aid.to_string();
        }
        if let Some(val) = extra.get("validator").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
            sess.validator = val.to_string();
        }
    }
}

fn apply_blacklist_to_response(engine: &CoreEngine, val: &mut Value) {
    let Ok(Some(uid)) = engine.active_uid() else {
        return;
    };
    filter_value_with_uid(engine, &uid, val);
}

fn filter_value_with_uid(engine: &CoreEngine, uid: &str, val: &mut Value) {
    let Ok(rules) = BlackListDao::new(&engine.db).list_by_uid(uid, None) else {
        return;
    };
    let active_rules: Vec<BlackListEntity> = rules.into_iter().filter(|r| r.state == 1).collect();
    if active_rules.is_empty() {
        return;
    }

    let filter_arr = |items: &mut Vec<Value>| {
        items.retain(|st| !is_status_blocked(st, &active_rules));
    };

    if let Some(arr) = val.get_mut("statuses").and_then(|v| v.as_array_mut()) {
        filter_arr(arr);
    } else if let Some(arr) = val.get_mut("cards").and_then(|v| v.as_array_mut()) {
        filter_arr(arr);
    } else if let Some(arr) = val.as_array_mut() {
        filter_arr(arr);
    }
}

fn is_status_blocked(st: &Value, rules: &[BlackListEntity]) -> bool {
    let target = st.get("mblog").unwrap_or(st);
    let author_uid = target
        .pointer("/user/idstr")
        .or_else(|| target.pointer("/user/id"))
        .map(json_id_to_string)
        .unwrap_or_default();
    let author_name = target
        .pointer("/user/screen_name")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let text = target.get("text").and_then(|v| v.as_str()).unwrap_or_default();
    let retweet_text = target
        .pointer("/retweeted_status/text")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let source = target
        .get("source")
        .and_then(|v| v.as_str())
        .unwrap_or_default();

    for r in rules {
        if r.state != 1 || r.key.is_empty() {
            continue;
        }
        match r.type_ {
            0 => {
                if r.key == author_uid || r.key == author_name {
                    return true;
                }
            }
            1 => {
                if text.contains(&r.key) || retweet_text.contains(&r.key) {
                    return true;
                }
            }
            2 => {
                if source.contains(&r.key) {
                    return true;
                }
            }
            _ => {}
        }
    }
    false
}

fn user_to_summary(u: &UserEntity, active_uid: Option<&str>) -> AccountSummary {
    AccountSummary {
        uid: u.uid.clone(),
        name: u.name.clone().unwrap_or_default(),
        avatar: u.avatar.clone().unwrap_or_default(),
        cover: u.cover.clone().unwrap_or_default(),
        gender: u.gender.clone().unwrap_or_default(),
        sign: u.sign.clone().unwrap_or_default(),
        account: u.account.clone().unwrap_or_default(),
        parent_type: u.parent_type,
        has_gsid: u.gsid.as_ref().is_some_and(|s| !s.is_empty()),
        has_oauth: !u.token.is_empty(),
        has_cookie: u.cookie.as_ref().is_some_and(|s| !s.is_empty()),
        is_active: active_uid == Some(u.uid.as_str()),
    }
}

fn draft_to_dto(d: StatusDraftEntity) -> DraftDto {
    DraftDto {
        id: d.id.unwrap_or(0),
        uid: d.uid,
        content: d.content,
        date: d.date,
        urls_json: d.urls.unwrap_or_default(),
        target_status_id: d.target_status_id.unwrap_or_default(),
        target_status_json: d.target_status_json.unwrap_or_default(),
        target_comment_id: d.target_comment_id.unwrap_or_default(),
        target_comment_user_name: d.target_comment_user_name.unwrap_or_default(),
        target_comment_content: d.target_comment_content.unwrap_or_default(),
        assign_group_id_str: d.assign_group_id_str.unwrap_or_default(),
        assign_group_type: d.assign_group_type.unwrap_or(0),
        address: d.address.unwrap_or_default(),
        publish_timing: d.publish_timing.unwrap_or(0),
        is_comment_origin: d.is_comment_origin.unwrap_or(0) != 0,
        status: d.status,
        is_mention: d.is_mention.unwrap_or(0) != 0,
        state: d.state.unwrap_or(0),
        type_code: d.type_.unwrap_or(0),
        parent_type: d.parent_type.unwrap_or(0),
        extra_json: d.extra.unwrap_or_default(),
    }
}

fn blacklist_to_dto(b: BlackListEntity) -> BlacklistRuleDto {
    BlacklistRuleDto {
        id: b.id.unwrap_or(0),
        uid: b.uid,
        key: b.key,
        info: b.info.unwrap_or_default(),
        rule_type: b.type_,
        state: b.state,
        black_type: b.black_type,
    }
}

fn parse_string_map(json_str: &str) -> Result<BTreeMap<String, String>, String> {
    let trimmed = json_str.trim();
    if trimmed.is_empty() {
        return Ok(BTreeMap::new());
    }
    let val: Value = serde_json::from_str(trimmed)
        .map_err(|e| format!("Invalid params JSON: {e}"))?;
    let obj = val
        .as_object()
        .ok_or_else(|| "Expected JSON object for request params".to_string())?;
    let mut map = BTreeMap::new();
    for (k, v) in obj {
        let s = match v {
            Value::Null => continue,
            Value::String(s) => s.clone(),
            Value::Bool(b) => if *b { "1" } else { "0" }.to_string(),
            Value::Number(n) => n.to_string(),
            other => other.to_string(),
        };
        map.insert(k.clone(), s);
    }
    Ok(map)
}

fn statuses_empty(val: &Value) -> bool {
    let has_statuses = val
        .get("statuses")
        .and_then(|v| v.as_array())
        .is_some_and(|a| !a.is_empty());
    let has_cards = val
        .get("cards")
        .and_then(|v| v.as_array())
        .is_some_and(|a| !a.is_empty());
    let has_data_list = val
        .pointer("/data/list")
        .and_then(|v| v.as_array())
        .is_some_and(|a| !a.is_empty());
    !(has_statuses || has_cards || has_data_list)
}

fn comments_empty(val: &Value) -> bool {
    let has_key = |k: &str| {
        val.get(k)
            .and_then(|v| v.as_array())
            .is_some_and(|a| !a.is_empty())
    };
    !(has_key("root_comments") || has_key("datas") || has_key("comments") || has_key("data"))
}

fn any_non_empty_array(val: &Value, pointers: &[&str]) -> bool {
    pointers
        .iter()
        .any(|ptr| val.pointer(ptr).and_then(|v| v.as_array()).is_some_and(|a| !a.is_empty()))
}

fn reposts_empty(val: &Value) -> bool {
    !any_non_empty_array(
        val,
        &[
            "/reposts",
            "/hot_reposts",
            "/data",
            "/data/list",
            "/data/reposts",
            "/datas",
        ],
    )
}

fn likers_empty(val: &Value) -> bool {
    !any_non_empty_array(
        val,
        &[
            "/users",
            "/attitudes",
            "/data",
            "/data/data",
            "/data/users",
            "/data/list",
        ],
    )
}

fn status_numeric_id(item: &Value) -> u64 {
    if let Some(u) = item.get("id").and_then(|v| v.as_u64()) {
        return u;
    }
    if let Some(s) = item
        .get("idstr")
        .or_else(|| item.get("id"))
        .and_then(|v| v.as_str())
    {
        if let Ok(n) = s.trim().parse::<u64>() {
            return n;
        }
    }
    0
}

fn is_promoted_status(item: &Value) -> bool {
    item.get("is_ad").and_then(|v| v.as_bool()).unwrap_or(false)
        || item.get("promotion").is_some_and(|p| p.is_object())
        || item.get("mblogtype").and_then(|v| v.as_i64()) == Some(1)
}

fn clean_and_sort_chronological_statuses(val: &mut Value) {
    let Some(arr) = val.get_mut("statuses").and_then(|v| v.as_array_mut()) else {
        return;
    };
    if arr.is_empty() {
        return;
    }
    if arr.iter().any(|item| !is_promoted_status(item)) {
        arr.retain(|item| !is_promoted_status(item));
    }
    // Reverse-chronological sort by snowflake status ID while computing min_id - 1 if needed.
    arr.sort_by(|a, b| status_numeric_id(b).cmp(&status_numeric_id(a)));
    if let Some(min_id) = arr.iter().map(status_numeric_id).filter(|&id| id > 0).min() {
        let has_max = val
            .get("max_id")
            .and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
            .is_some_and(|m| m > 0);
        if !has_max {
            val["max_id"] = json!(min_id.saturating_sub(1).to_string());
        }
    }
}

fn extract_mblogs_from_cardlist(val: &Value) -> Vec<Value> {
    fn collect_cards(cards: &[Value], out: &mut Vec<Value>) {
        for c in cards {
            if let Some(mblog) = c.get("mblog") {
                if mblog.is_object() {
                    out.push(mblog.clone());
                }
            }
            if let Some(sub) = c.get("card_group").and_then(|v| v.as_array()) {
                collect_cards(sub, out);
            }
        }
    }
    let mut out = Vec::new();
    if let Some(cards) = val.get("cards").and_then(|v| v.as_array()) {
        collect_cards(cards, &mut out);
    }
    out
}

fn extract_users_from_cardlist(val: &Value) -> Vec<Value> {
    fn collect_users(cards: &[Value], out: &mut Vec<Value>) {
        for c in cards {
            if let Some(u) = c.get("user") {
                if u.is_object() {
                    out.push(u.clone());
                }
            }
            if let Some(arr) = c.get("users").and_then(|v| v.as_array()) {
                for u in arr {
                    if u.is_object() {
                        out.push(u.clone());
                    }
                }
            }
            if let Some(sub) = c.get("card_group").and_then(|v| v.as_array()) {
                collect_users(sub, out);
            }
        }
    }
    let mut out = Vec::new();
    if let Some(cards) = val.get("cards").and_then(|v| v.as_array()) {
        collect_users(cards, &mut out);
    } else if let Some(sub) = val
        .get("cards")
        .and_then(|c| c.get("card_group"))
        .and_then(|v| v.as_array())
    {
        collect_users(sub, &mut out);
    }
    if out.is_empty() {
        if let Some(arr) = val.get("users").and_then(|v| v.as_array()) {
            for u in arr {
                if u.is_object() {
                    out.push(u.clone());
                }
            }
        }
    }
    out
}

fn extract_flat_cookie(val: Option<&Value>) -> Option<String> {
    normalize_cookie_value(val?)
}

fn extract_cookie_pair(cookie: &str, name: &str) -> Option<String> {
    let prefix = format!("{name}=");
    for part in cookie.split(';') {
        if let Some(val) = part.trim().strip_prefix(&prefix) {
            if !val.is_empty() {
                return Some(val.to_string());
            }
        }
    }
    None
}

fn non_empty(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_blacklist_filtering_user_keyword_source() {
        let rules = vec![
            BlackListEntity {
                key: "999888".to_string(),
                uid: "100".to_string(),
                type_: 0,
                state: 1,
                ..Default::default()
            },
            BlackListEntity {
                key: "推广".to_string(),
                uid: "100".to_string(),
                type_: 1,
                state: 1,
                ..Default::default()
            },
            BlackListEntity {
                key: "营销号客户端".to_string(),
                uid: "100".to_string(),
                type_: 2,
                state: 1,
                ..Default::default()
            },
            BlackListEntity {
                key: "已暂停关键词".to_string(),
                uid: "100".to_string(),
                type_: 1,
                state: 0,
                ..Default::default()
            },
        ];

        let st_user = json!({"user": {"idstr": "999888", "screen_name": "A"}, "text": "hello"});
        let st_kw = json!({"user": {"idstr": "111", "screen_name": "B"}, "retweeted_status": {"text": "这是推广内容"}});
        let st_src = json!({"user": {"idstr": "111", "screen_name": "C"}, "text": "ok", "source": "<a>营销号客户端</a>"});
        let st_ok = json!({"user": {"idstr": "111", "screen_name": "D"}, "text": "包含已暂停关键词但正常", "source": "Share"});

        assert!(is_status_blocked(&st_user, &rules));
        assert!(is_status_blocked(&st_kw, &rules));
        assert!(is_status_blocked(&st_src, &rules));
        assert!(!is_status_blocked(&st_ok, &rules));
    }

    #[test]
    fn test_wesync_roundtrip_via_share_api() {
        let encoded = wesync_encode_frame(11, 42, b"{\"hello\":1}".to_vec());
        let decoded_json = wesync_decode_frame_json(encoded).unwrap();
        let val: Value = serde_json::from_str(&decoded_json).unwrap();
        assert_eq!(val["cmd"], 11);
        assert_eq!(val["seq"], 42);
        assert_eq!(val["payload_utf8"], "{\"hello\":1}");
    }

    #[test]
    fn test_core_engine_legacy_migration_and_sqlite_backup() {
        let dir = std::env::temp_dir().join(format!("share_core_test_{}", now_millis()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join(LEGACY_SESSION_FILE),
            serde_json::json!({
                "active_uid": "555123",
                "accounts": [{
                    "uid": "555123",
                    "screen_name": "LegacyUser",
                    "cookie": "SUB=_2A25TestCookie; XSRF-TOKEN=abc123",
                }]
            })
            .to_string(),
        )
        .unwrap();

        let engine = CoreEngine::open(&dir).unwrap();
        let active = engine.active_user().unwrap().unwrap();
        assert_eq!(active.uid, "555123");
        assert_eq!(active.name.as_deref(), Some("LegacyUser"));
        assert_eq!(
            engine.api_cn.session().cookie,
            "SUB=_2A25TestCookie; XSRF-TOKEN=abc123"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_restore_session_cleans_polluted_cookie() {
        let dir = std::env::temp_dir().join(format!("share_core_cookie_clean_{}", now_millis()));
        fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("share_app.db");
        let db = DatabaseManager::open_file(&db_path).unwrap();
        let dao = UserDao::new(&db);
        dao.insert_or_replace(&UserEntity {
            uid: "777888".to_string(),
            name: Some("PollutedCookieUser".to_string()),
            gsid: Some("_2A_mobile_gsid".to_string()),
            cookie: Some(
                "SUB=clean_sub; expires=Thu, 01 Jan 2030 00:00:00 GMT; domain=.weibo.com; path=/; HttpOnly\nSUBP=clean_subp; path=/; SameSite=None"
                    .to_string(),
            ),
            token: String::new(),
            parent_type: 1,
            ..Default::default()
        })
        .unwrap();
        drop(db);

        let engine = CoreEngine::open(&dir).unwrap();
        let cleaned = engine.clean_active_web_cookie().expect("cleaned cookie");
        assert!(cleaned.contains("SUB=clean_sub"), "got {cleaned}");
        assert!(cleaned.contains("SUBP=clean_subp"), "got {cleaned}");
        assert!(!cleaned.contains("expires="), "got {cleaned}");
        assert!(!cleaned.contains("domain="), "got {cleaned}");
        assert!(!cleaned.contains("path="), "got {cleaned}");
        assert!(!cleaned.contains("SameSite="), "got {cleaned}");

        let restored = engine.active_user().unwrap().unwrap();
        assert_eq!(restored.cookie.as_deref(), Some(cleaned.as_str()));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_clean_and_sort_chronological_statuses_filters_ads_and_sorts_newest_first() {
        let mut val = serde_json::json!({
            "statuses": [
                { "id": 1002, "text": "older" },
                { "id": 9999, "is_ad": true, "text": "ad_flag" },
                { "id": 9998, "mblogtype": 1, "text": "ad_mblogtype" },
                { "id": "3005", "text": "newest" },
                { "id": 2001, "text": "middle" }
            ],
            "next_cursor": 0
        });
        clean_and_sort_chronological_statuses(&mut val);
        let arr = val["statuses"].as_array().unwrap();
        assert_eq!(arr.len(), 3);
        assert_eq!(arr[0]["text"], "newest");
        assert_eq!(arr[1]["text"], "middle");
        assert_eq!(arr[2]["text"], "older");
        assert_eq!(val["max_id"].as_str(), Some("1001"));
    }

    #[test]
    fn test_comments_empty_recognizes_root_comments_and_legacy_arrays() {
        assert!(comments_empty(&serde_json::json!({
            "comments": [],
            "root_comments": [],
            "datas": [],
            "data": []
        })));
        assert!(!comments_empty(&serde_json::json!({
            "comments": [],
            "root_comments": [{"id": 123, "text": "hello"}]
        })));
        assert!(!comments_empty(&serde_json::json!({
            "datas": [{"id": 456, "text": "legacy"}]
        })));
    }

    #[test]
    fn test_reposts_and_likers_empty_helpers() {
        assert!(reposts_empty(&serde_json::json!({
            "reposts": [],
            "hot_reposts": [],
            "data": []
        })));
        assert!(!reposts_empty(&serde_json::json!({
            "reposts": [],
            "hot_reposts": [{"id": 111, "text": "hot repost"}]
        })));
        assert!(likers_empty(&serde_json::json!({
            "users": [],
            "attitudes": [],
            "data": {"users": []}
        })));
        assert!(!likers_empty(&serde_json::json!({
            "data": {"data": [{"user": {"id": 222, "screen_name": "Liker"}}]}
        })));
    }
}
