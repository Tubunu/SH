//! FFI surface exposed to Flutter via flutter_rust_bridge.
//!
//! Design note: list endpoints return the *raw* Weibo JSON payload as a
//! `String`. The transport/session/cache lives in Rust, while the JSON ->
//! view-model mapping happens in Dart next to the widgets that consume it.
//! This keeps the FFI boundary tiny and avoids recursive struct mirrors.

use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use crate::web::api;
use crate::web::client::WebClient;
use crate::web::session::{Account, SessionStore};

pub struct AccountDto {
    pub uid: String,
    pub screen_name: String,
    pub avatar: String,
    pub is_guest: bool,
    pub active: bool,
}

impl From<&Account> for AccountDto {
    fn from(a: &Account) -> Self {
        Self {
            uid: a.uid.clone(),
            screen_name: a.screen_name.clone(),
            avatar: a.avatar.clone(),
            is_guest: a.is_guest,
            active: false,
        }
    }
}

struct Core {
    client: WebClient,
    session: Mutex<SessionStore>,
    data_dir: PathBuf,
}

static CORE: OnceLock<Core> = OnceLock::new();

fn core() -> Result<&'static Core, String> {
    CORE.get()
        .ok_or_else(|| "核心尚未初始化，请先调用 initCore".to_string())
}

/// Must be called once at start-up with a writable app directory.
pub fn init_core(data_dir: String) -> Result<(), String> {
    if CORE.get().is_some() {
        return Ok(());
    }
    let dir = PathBuf::from(&data_dir);
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建数据目录失败：{e}"))?;

    let session = SessionStore::load(&data_dir);
    let client = WebClient::new();
    session.apply_to(&client);

    let core = Core {
        client,
        session: Mutex::new(session),
        data_dir: dir,
    };
    let _ = CORE.set(core);
    Ok(())
}

/// Creates an anonymous session (browse without signing in).
pub async fn guest_login() -> Result<AccountDto, String> {
    let core = core()?;
    let account = api::guest_login(&core.client).await.map_err(|e| e.to_string())?;
    let mut dto = AccountDto::from(&account);
    dto.active = true;
    Ok(dto)
}

/// Adopts cookies captured by the in-app login WebView, then verifies them.
pub async fn login_with_cookie(cookie: String) -> Result<AccountDto, String> {
    let core = core()?;
    core.client.clear_cookies();
    let accepted = core.client.set_cookie(&cookie);
    if accepted == 0 {
        return Err("Cookie 格式无法识别".to_string());
    }
    let _ = api::refresh_xsrf(&core.client).await;

    let account = api::fetch_self(&core.client).await.map_err(|e| e.to_string())?;
    if account.uid.is_empty() {
        return Err("登录校验失败：未获取到账号信息".to_string());
    }

    if let Ok(mut session) = core.session.lock() {
        session.upsert(account.clone());
        let _ = session.save();
    }
    let mut dto = AccountDto::from(&account);
    dto.active = true;
    Ok(dto)
}

/// Synchronizes a verified mobile login (`ShareCore` SQLite account + optional cookie) into
/// `WebClient` & `session.json` so Web fallback calls and InAppWebPage stay aligned.
pub async fn sync_account_cookie(
    uid: String,
    screen_name: String,
    avatar: String,
    cookie: String,
) -> Result<AccountDto, String> {
    let core = core()?;
    core.client.clear_cookies();
    let accepted = if cookie.trim().is_empty() {
        0
    } else {
        core.client.set_cookie(&cookie)
    };
    if accepted > 0 && core.client.has_session() {
        let _ = api::refresh_xsrf(&core.client).await;
        if let Ok(fetched) = api::fetch_self(&core.client).await {
            if !fetched.uid.is_empty() {
                if let Ok(mut session) = core.session.lock() {
                    session.upsert(fetched.clone());
                    let _ = session.save();
                }
                let mut dto = AccountDto::from(&fetched);
                dto.active = true;
                return Ok(dto);
            }
        }
    }

    if uid.trim().is_empty() {
        return Err("同步会话失败：缺少有效 UID".to_string());
    }
    let account = Account {
        uid: uid.clone(),
        screen_name: if screen_name.is_empty() { uid } else { screen_name },
        avatar,
        cookie: core.client.cookie_items(),
        is_guest: false,
    };
    if let Ok(mut session) = core.session.lock() {
        session.upsert(account.clone());
        let _ = session.save();
    }
    let mut dto = AccountDto::from(&account);
    dto.active = true;
    Ok(dto)
}

pub fn current_account() -> Option<AccountDto> {
    let core = core().ok()?;
    let session = core.session.lock().ok()?;
    session.active().map(|a| {
        let mut dto = AccountDto::from(a);
        dto.active = true;
        dto
    })
}

pub fn accounts() -> Vec<AccountDto> {
    let Ok(core) = core() else {
        return Vec::new();
    };
    let Ok(session) = core.session.lock() else {
        return Vec::new();
    };
    let active_uid = session.active().map(|a| a.uid.clone()).unwrap_or_default();
    session
        .accounts()
        .iter()
        .map(|a| {
            let mut dto = AccountDto::from(a);
            dto.active = a.uid == active_uid;
            dto
        })
        .collect()
}

pub fn switch_account(uid: String) -> Result<AccountDto, String> {
    let core = core()?;
    let account = {
        let mut session = core.session.lock().map_err(|_| "会话锁失败".to_string())?;
        let account = session.set_active(&uid)?;
        session.save()?;
        account
    };
    core.client.clear_cookies();
    core.client.set_cookie(&account.cookie_string());
    let mut dto = AccountDto::from(&account);
    dto.active = true;
    Ok(dto)
}

pub fn remove_account(uid: String) -> Result<(), String> {
    let core = core()?;
    let mut session = core.session.lock().map_err(|_| "会话锁失败".to_string())?;
    session.remove(&uid);
    session.save()
}

pub fn logout() -> Result<(), String> {
    let core = core()?;
    let uid = {
        let session = core.session.lock().map_err(|_| "会话锁失败".to_string())?;
        session.active().map(|a| a.uid.clone()).unwrap_or_default()
    };
    if !uid.is_empty() {
        if let Ok(mut session) = core.session.lock() {
            session.remove(&uid);
            let _ = session.save();
        }
    }
    core.client.clear_cookies();
    Ok(())
}

pub fn is_logged_in() -> bool {
    core()
        .map(|c| c.client.has_session())
        .unwrap_or(false)
}

/// Returns the active cookie header (used to seed the WebView session).
pub fn active_cookie() -> String {
    core().map(|c| c.client.cookie_header()).unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Timelines
// ---------------------------------------------------------------------------

pub async fn home_timeline(
    since_id: Option<String>,
    max_id: Option<String>,
    count: u32,
) -> Result<String, String> {
    let core = core()?;
    let json = api::home_timeline(
        &core.client,
        since_id.as_deref(),
        max_id.as_deref(),
        count,
    )
    .await
    .map_err(|e| e.to_string())?;
    if max_id.is_none() {
        write_cache(core, "home_timeline.json", &json);
    }
    Ok(json)
}

pub fn cached_home_timeline() -> Option<String> {
    let core = core().ok()?;
    read_cache(core, "home_timeline.json")
}

pub async fn hot_timeline(max_id: Option<String>, count: u32) -> Result<String, String> {
    let core = core()?;
    api::hot_timeline(&core.client, max_id.as_deref(), count)
        .await
        .map_err(|e| e.to_string())
}

/// 分组时间线（全部关注 / 好友圈 / 自定义分组），由 `gid` 前缀自动选端点。
pub async fn feed_timeline(
    gid: String,
    since_id: Option<String>,
    max_id: Option<String>,
    count: u32,
) -> Result<String, String> {
    let core = core()?;
    api::feed_timeline(
        &core.client,
        &gid,
        since_id.as_deref(),
        max_id.as_deref(),
        count,
    )
    .await
    .map_err(|e| e.to_string())
}

/// 我赞过的微博。
pub async fn liked_statuses(uid: String, page: u32) -> Result<String, String> {
    let core = core()?;
    api::liked_statuses(&core.client, &uid, page)
        .await
        .map_err(|e| e.to_string())
}

/// 谁赞了这条微博（详情页「赞」Tab）。
pub async fn status_likers(id: String, page: u32, count: u32) -> Result<String, String> {
    let core = core()?;
    api::status_likers(&core.client, &id, page, count)
        .await
        .map_err(|e| e.to_string())
}

/// 主页内搜索微博。
pub async fn search_profile(uid: String, q: String, page: u32) -> Result<String, String> {
    let core = core()?;
    api::search_profile(&core.client, &uid, &q, page)
        .await
        .map_err(|e| e.to_string())
}

/// 新增粉丝列表。
pub async fn new_followers(
    uid: String,
    page: u32,
    count: u32,
    new_follower_count: u32,
) -> Result<String, String> {
    let core = core()?;
    api::new_followers(&core.client, &uid, page, count, new_follower_count)
        .await
        .map_err(|e| e.to_string())
}

/// 删除自己的微博。
pub async fn delete_status(id: String) -> Result<(), String> {
    let core = core()?;
    api::delete_status(&core.client, &id)
        .await
        .map_err(|e| e.to_string())
}

/// 微博编辑历史。
pub async fn edit_history(mid: String, page: u32) -> Result<String, String> {
    let core = core()?;
    api::edit_history(&core.client, &mid, page)
        .await
        .map_err(|e| e.to_string())
}

/// 机器翻译正文。
pub async fn translate_status(idstr: String, locale: String) -> Result<String, String> {
    let core = core()?;
    api::translate_status(&core.client, &idstr, &locale)
        .await
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Status detail & interactions
// ---------------------------------------------------------------------------

pub async fn status_show(id: String) -> Result<String, String> {
    let core = core()?;
    api::status_show(&core.client, &id)
        .await
        .map_err(|e| e.to_string())
}

pub async fn status_long_text(id: String) -> Result<String, String> {
    let core = core()?;
    api::status_long_text(&core.client, &id)
        .await
        .map_err(|e| e.to_string())
}

pub async fn comments(
    status_id: String,
    uid: String,
    flow: u32,
    max_id: Option<String>,
    count: u32,
) -> Result<String, String> {
    let core = core()?;
    api::comments(
        &core.client,
        &status_id,
        &uid,
        flow,
        max_id.as_deref(),
        count,
    )
    .await
    .map_err(|e| e.to_string())
}

pub async fn comment_replies(comment_id: String, max_id: Option<String>) -> Result<String, String> {
    let core = core()?;
    api::comment_replies(&core.client, &comment_id, max_id.as_deref())
        .await
        .map_err(|e| e.to_string())
}

pub async fn reposts(status_id: String, page: u32) -> Result<String, String> {
    let core = core()?;
    api::reposts(&core.client, &status_id, page)
        .await
        .map_err(|e| e.to_string())
}

pub async fn like(status_id: String, undo: bool) -> Result<(), String> {
    let core = core()?;
    api::like(&core.client, &status_id, undo)
        .await
        .map_err(|e| e.to_string())
}

pub async fn favorite(status_id: String, undo: bool) -> Result<(), String> {
    let core = core()?;
    api::favorite(&core.client, &status_id, undo)
        .await
        .map_err(|e| e.to_string())
}

pub async fn repost(status_id: String, text: String, also_comment: bool) -> Result<String, String> {
    let core = core()?;
    api::repost(&core.client, &status_id, &text, also_comment)
        .await
        .map_err(|e| e.to_string())
}

pub async fn create_comment(status_id: String, text: String) -> Result<String, String> {
    let core = core()?;
    api::create_comment(&core.client, &status_id, &text)
        .await
        .map_err(|e| e.to_string())
}

pub async fn publish(text: String, visible: u32, pic_ids: String) -> Result<String, String> {
    let core = core()?;
    api::publish(&core.client, &text, visible, &pic_ids)
        .await
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Discovery & profiles
// ---------------------------------------------------------------------------

pub async fn hot_search() -> Result<String, String> {
    let core = core()?;
    api::hot_search(&core.client).await.map_err(|e| e.to_string())
}

pub async fn search(keyword: String, page: u32) -> Result<String, String> {
    let core = core()?;
    api::search(&core.client, &keyword, page)
        .await
        .map_err(|e| e.to_string())
}

/// Nickname -> uid, used when the user taps an `@名字` inside rich text.
pub async fn resolve_nickname(name: String) -> Result<String, String> {
    let core = core()?;
    api::resolve_nickname(&core.client, &name)
        .await
        .map_err(|e| e.to_string())
}

pub async fn user_profile(uid: String) -> Result<String, String> {
    let core = core()?;
    api::user_profile(&core.client, &uid)
        .await
        .map(|v| v.to_string())
        .map_err(|e| e.to_string())
}

pub async fn user_statuses(uid: String, page: u32, feature: u32) -> Result<String, String> {
    let core = core()?;
    api::user_statuses(&core.client, &uid, page, feature)
        .await
        .map_err(|e| e.to_string())
}

pub async fn user_albums(uid: String, page: u32) -> Result<String, String> {
    let core = core()?;
    api::user_albums(&core.client, &uid, page)
        .await
        .map_err(|e| e.to_string())
}

/// 我的收藏 — `data[]` holds full status objects.
pub async fn favorites(page: u32) -> Result<String, String> {
    let core = core()?;
    api::favorites(&core.client, page)
        .await
        .map_err(|e| e.to_string())
}

/// 超话分类 — `[{id, name}]`.
/// 分组列表（游客可用）。
pub async fn groups() -> Result<String, String> {
    let core = core()?;
    api::groups(&core.client).await.map_err(|e| e.to_string())
}

/// 表情配置（10 类 / 348 个）。
pub async fn emotions() -> Result<String, String> {
    let core = core()?;
    api::emotions(&core.client).await.map_err(|e| e.to_string())
}

/// 用户 / 话题联想。
pub async fn search_users(keyword: String) -> Result<String, String> {
    let core = core()?;
    api::search_users(&core.client, &keyword)
        .await
        .map_err(|e| e.to_string())
}

pub async fn stopic_cates() -> Result<String, String> {
    let core = core()?;
    api::stopic_cates(&core.client)
        .await
        .map_err(|e| e.to_string())
}

/// 超话列表 / 超话搜索.
pub async fn stopic_list(sort_id: u32, keyword: String, page: u32) -> Result<String, String> {
    let core = core()?;
    api::stopic_list(&core.client, sort_id, &keyword, page)
        .await
        .map_err(|e| e.to_string())
}

/// Uploads one picture (raw bytes from the platform picker) and returns the
/// `pid` that `publish` needs in its `pic_ids` list.
pub async fn upload_picture(
    bytes: Vec<u8>,
    filename: String,
    mime: String,
) -> Result<String, String> {
    let core = core()?;
    api::upload_picture(&core.client, &bytes, &filename, &mime)
        .await
        .map_err(|e| e.to_string())
}

pub async fn follow(uid: String, undo: bool) -> Result<(), String> {
    let core = core()?;
    api::follow(&core.client, &uid, undo)
        .await
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Message centre
// ---------------------------------------------------------------------------

/// `@` my statuses — `data.statuses[]`, same shape as the timeline.
pub async fn at_weibo(page: u32) -> Result<String, String> {
    let core = core()?;
    api::at_weibo(&core.client, page)
        .await
        .map_err(|e| e.to_string())
}

/// `@` inside comments — `data.comments[]`.
pub async fn at_comments(page: u32) -> Result<String, String> {
    let core = core()?;
    api::at_comments(&core.client, page)
        .await
        .map_err(|e| e.to_string())
}

/// Comments left on my statuses — `data.comments[]` with `reply_comment`.
pub async fn received_comments(page: u32) -> Result<String, String> {
    let core = core()?;
    api::received_comments(&core.client, page)
        .await
        .map_err(|e| e.to_string())
}

/// Likes on my statuses — `data.attitudes[]`.
pub async fn received_likes(page: u32) -> Result<String, String> {
    let core = core()?;
    api::received_likes(&core.client, page)
        .await
        .map_err(|e| e.to_string())
}

/// Unread badges for the message hub.
pub async fn unread_hint() -> Result<String, String> {
    let core = core()?;
    api::unread_hint(&core.client)
        .await
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// 私信 (WebIM)
// ---------------------------------------------------------------------------

pub async fn dm_conversations(count: u32) -> Result<String, String> {
    let core = core()?;
    api::dm_conversations(&core.client, count)
        .await
        .map_err(|e| e.to_string())
}

pub async fn dm_history(
    uid: String,
    max_id: Option<String>,
    count: u32,
) -> Result<String, String> {
    let core = core()?;
    api::dm_history(&core.client, &uid, max_id.as_deref(), count)
        .await
        .map_err(|e| e.to_string())
}

pub async fn dm_send(uid: String, text: String) -> Result<String, String> {
    let core = core()?;
    api::dm_send(&core.client, &uid, &text)
        .await
        .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Cache helpers
// ---------------------------------------------------------------------------

fn cache_path(core: &Core, name: &str) -> PathBuf {
    core.data_dir.join("cache").join(name)
}

fn write_cache(core: &Core, name: &str, value: &str) {
    let path = cache_path(core, name);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(path, value);
}

fn read_cache(core: &Core, name: &str) -> Option<String> {
    std::fs::read_to_string(cache_path(core, name)).ok()
}
