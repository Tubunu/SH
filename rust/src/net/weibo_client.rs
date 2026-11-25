//! Weibo HTTP Network Client and Request Interceptor.
//!
//! Provides automatic signature calculation, device parameter mounting,
//! session cookie injection, and SQLite timeline caching.

use reqwest::header::{HeaderMap, HeaderValue, COOKIE, USER_AGENT};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::Duration;
use thiserror::Error;

use crate::auth::session::SessionManager;
use crate::crypto::sign::calculate_s_share;
use crate::crypto::ua::DeviceContext;
use crate::parser::comment_model::{CommentListResponse, CommentModel};
use crate::parser::search_model::{HotSearchItemModel, SearchResultModel};
use crate::parser::social_model::{
    DmConversationModel, DmMessageModel, NotificationModel, TopicModel, TopicSignInResult,
};
use crate::parser::status_model::{StatusModel, TimelineResponse, UserModel};
use crate::storage::dao::share_json_dao::ShareJsonDao;
use crate::storage::db::DatabaseManager;

const WEIBO_API_BASE: &str = "https://api.weibo.cn";
const TIMELINE_CACHE_PREFIX: &str = "home_timeline_cache_";
const COMMENTS_CACHE_PREFIX: &str = "comments_cache_";

#[derive(Error, Debug)]
pub enum NetError {
    #[error("HTTP transport error: {0}")]
    Reqwest(#[from] reqwest::Error),
    #[error("API JSON parse error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Storage error: {0}")]
    Storage(String),
    #[error("Authentication required")]
    Unauthenticated,
    #[error("Weibo API error [{code}]: {message}")]
    ApiError { code: i32, message: String },
}

#[derive(Clone)]
pub struct WeiboClient {
    client: reqwest::Client,
    device_ctx: DeviceContext,
    session: Option<SessionManager>,
    db: Option<DatabaseManager>,
    validator: Arc<RwLock<Option<String>>>,
}

impl WeiboClient {
    /// Creates a new configured WeiboClient.
    pub fn new(
        device_ctx: DeviceContext,
        session: Option<SessionManager>,
        db: Option<DatabaseManager>,
    ) -> Self {
        Self::with_shared_validator(device_ctx, session, db, Arc::new(RwLock::new(None)))
    }

    /// Creates a new configured WeiboClient sharing an external validator handle.
    pub fn with_shared_validator(
        device_ctx: DeviceContext,
        session: Option<SessionManager>,
        db: Option<DatabaseManager>,
        validator: Arc<RwLock<Option<String>>>,
    ) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .connect_timeout(Duration::from_secs(8))
            .gzip(true)
            .brotli(true)
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());

        Self {
            client,
            device_ctx,
            session,
            db,
            validator,
        }
    }

    /// Returns the current X-Validator token if set.
    pub fn validator(&self) -> Option<String> {
        self.validator.read().ok().and_then(|g| g.clone())
    }

    /// Sets or clears the X-Validator token (matching C3185mA.java / C0489Lf.O0000o0O).
    pub fn set_validator(&self, validator: Option<String>) {
        if let Ok(mut g) = self.validator.write() {
            *g = validator;
        }
    }

    /// Returns a cloned Arc to the shared validator storage.
    pub fn shared_validator(&self) -> Arc<RwLock<Option<String>>> {
        Arc::clone(&self.validator)
    }

    /// Inspects HTTP response headers to capture dynamic tokens (e.g. X-Validator from C3185mA.java L58-61).
    pub fn handle_response_headers(&self, headers: &HeaderMap) {
        if let Some(val_header) = headers.get("X-Validator") {
            if let Ok(val_str) = val_header.to_str() {
                let trimmed = val_str.trim();
                if !trimmed.is_empty() {
                    self.set_validator(Some(trimmed.to_string()));
                }
            }
        }
    }

    /// Prepares URL parameters, applies device context, attaches credentials,
    /// and generates the MD5 signature `s`.
    pub fn build_signed_params(
        &self,
        path: &str,
        custom_params: &[(&str, &str)],
    ) -> Vec<(String, String)> {
        let mut map: HashMap<String, String> = self.device_ctx.build_common_params();

        // Attach custom request params
        for &(k, v) in custom_params {
            map.insert(k.to_string(), v.to_string());
        }

        // Attach session credentials
        if let Some(session) = &self.session {
            if let Some(token) = session.current_token() {
                map.insert("access_token".to_string(), token);
            }
            if let Some(gsid) = session.current_gsid() {
                map.insert("gsid".to_string(), gsid);
            }
        }

        // Convert map to param pairs
        let mut param_pairs: Vec<(String, String)> = map.into_iter().collect();

        // Calculate s signature and append
        let s_sig = calculate_s_share(path, &param_pairs);
        param_pairs.push(("s".to_string(), s_sig));

        param_pairs
    }

    /// Builds default HTTP headers including User-Agent, Cookie, X-Sessionid, X-Log-Uid, and dynamic X-Validator.
    pub fn build_headers(&self) -> HeaderMap {
        let mut headers = HeaderMap::new();

        let ua_val = self.device_ctx.user_agent();
        if let Ok(hv) = HeaderValue::from_str(&ua_val) {
            headers.insert(USER_AGENT, hv);
        }

        let mut uid_set = false;
        if let Some(session) = &self.session {
            if let Some(cookie) = session.current_cookie() {
                if !cookie.is_empty() {
                    if let Ok(hv) = HeaderValue::from_str(&cookie) {
                        headers.insert(COOKIE, hv);
                    }
                }
            }
            if let Some(uid) = session.current_uid() {
                if let Ok(hv) = HeaderValue::from_str(&uid) {
                    headers.insert("X-Log-Uid", hv);
                    uid_set = true;
                }
            }
        }

        let session_id = uuid::Uuid::new_v4().to_string();
        if let Ok(hv) = HeaderValue::from_str(&session_id) {
            headers.insert("X-Sessionid", hv);
        }

        // Dynamically inject X-Validator if present (from C3185mA.java L51-56)
        if let Some(val) = self.validator() {
            if !val.is_empty() {
                if let Ok(hv) = HeaderValue::from_str(&val) {
                    headers.insert("X-Validator", hv);
                }
                if !uid_set {
                    headers.insert("X-Log-Uid", HeaderValue::from_static(""));
                }
            }
        }

        headers
    }

    /// Fetches the authenticated user's home timeline (`2/statuses/friends/timeline`).
    pub async fn fetch_home_timeline(
        &self,
        since_id: Option<&str>,
        max_id: Option<&str>,
        count: Option<u32>,
        page: Option<u32>,
    ) -> Result<TimelineResponse, NetError> {
        let path = "/2/statuses/friends/timeline";
        let url = format!("{}{}", WEIBO_API_BASE, path);

        let mut custom = Vec::new();
        let count_str = count.unwrap_or(30).to_string();
        custom.push(("count", count_str.as_str()));

        let page_str = page.unwrap_or(1).to_string();
        custom.push(("page", page_str.as_str()));

        if let Some(sid) = since_id {
            custom.push(("since_id", sid));
        }
        if let Some(mid) = max_id {
            custom.push(("max_id", mid));
        }

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        // Intercept response headers to capture dynamic X-Validator (C3185mA.java L58-61)
        self.handle_response_headers(response.headers());

        let text = response.text().await?;

        // Parse JSON response
        let timeline: TimelineResponse = serde_json::from_str(&text)?;

        // If DB is available, persist the latest page 1 cache for instant startup
        if page.unwrap_or(1) == 1 && since_id.is_none() {
            if let Some(db) = &self.db {
                if let Some(session) = &self.session {
                    if let Some(uid) = session.current_uid() {
                        let cache_key = format!("{}{}", TIMELINE_CACHE_PREFIX, uid);
                        let dao = ShareJsonDao::new(db);
                        let _ = dao.put(&cache_key, &text);
                    }
                }
            }
        }

        Ok(timeline)
    }

    /// Fetches cached timeline from SQLite `SHARE_JSON` table for instant startup.
    pub fn get_cached_timeline(&self, uid: &str) -> Option<TimelineResponse> {
        let db = self.db.as_ref()?;
        let dao = ShareJsonDao::new(db);
        let cache_key = format!("{}{}", TIMELINE_CACHE_PREFIX, uid);
        let json_str = dao.get(&cache_key).ok()??;
        serde_json::from_str(&json_str).ok()
    }

    /// Fetches primary comments for a status (`/2/comments/show`).
    pub async fn fetch_comments(
        &self,
        id: &str,
        page: i64,
        count: i64,
    ) -> Result<CommentListResponse, NetError> {
        let path = "/2/comments/show";
        let url = format!("{}{}", WEIBO_API_BASE, path);

        let page_str = page.to_string();
        let count_str = count.to_string();
        let custom = [
            ("id", id),
            ("page", page_str.as_str()),
            ("count", count_str.as_str()),
        ];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;

        let comments_resp: CommentListResponse = serde_json::from_str(&text)?;

        // Cache page 1 in SQLite if DB is available
        if page == 1 {
            if let Some(db) = &self.db {
                let cache_key = format!("{}{}", COMMENTS_CACHE_PREFIX, id);
                let dao = ShareJsonDao::new(db);
                let _ = dao.put(&cache_key, &text);
            }
        }

        Ok(comments_resp)
    }

    /// Fetches cached comments from SQLite for instant offline loading.
    pub fn get_cached_comments(&self, id: &str) -> Option<CommentListResponse> {
        let db = self.db.as_ref()?;
        let dao = ShareJsonDao::new(db);
        let cache_key = format!("{}{}", COMMENTS_CACHE_PREFIX, id);
        let json_str = dao.get(&cache_key).ok()??;
        serde_json::from_str(&json_str).ok()
    }

    /// Fetches status reposts (`/2/statuses/repost_timeline`).
    pub async fn fetch_reposts(
        &self,
        id: &str,
        page: i64,
        count: i64,
    ) -> Result<TimelineResponse, NetError> {
        let path = "/2/statuses/repost_timeline";
        let url = format!("{}{}", WEIBO_API_BASE, path);

        let page_str = page.to_string();
        let count_str = count.to_string();
        let custom = [
            ("id", id),
            ("page", page_str.as_str()),
            ("count", count_str.as_str()),
        ];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;

        let resp: TimelineResponse = serde_json::from_str(&text)?;
        Ok(resp)
    }

    /// Fetches nested floor replies / sub-comments (`/2/comments/build_comments`).
    pub async fn fetch_comment_replies(
        &self,
        cid: &str,
        page: i64,
        count: i64,
    ) -> Result<CommentListResponse, NetError> {
        let path = "/2/comments/build_comments";
        let url = format!("{}{}", WEIBO_API_BASE, path);

        let page_str = page.to_string();
        let count_str = count.to_string();
        let custom = [
            ("cid", cid),
            ("page", page_str.as_str()),
            ("count", count_str.as_str()),
        ];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;

        let resp: CommentListResponse = serde_json::from_str(&text)?;
        Ok(resp)
    }

    /// Posts a comment or reply to an existing comment (`/2/comments/create` or `/2/comments/reply`).
    pub async fn post_comment(
        &self,
        id: &str,
        text: &str,
        reply_cid: Option<&str>,
        is_comment_origin: bool,
    ) -> Result<CommentModel, NetError> {
        let path = if reply_cid.is_some() {
            "/2/comments/reply"
        } else {
            "/2/comments/create"
        };
        let url = format!("{}{}", WEIBO_API_BASE, path);

        let mut custom = vec![
            ("id", id),
            ("comment", text),
            ("uicode", "10000445"),
            ("moduleID", "704"),
        ];

        if let Some(cid) = reply_cid {
            custom.push(("cid", cid));
        }

        let origin_flag = if is_comment_origin { "1" } else { "0" };
        custom.push(("comment_ori", origin_flag));

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .post(&url)
            .headers(headers)
            .form(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let res_text = response.text().await?;

        let comment: CommentModel = serde_json::from_str(&res_text)?;
        Ok(comment)
    }

    /// Publishes a new status to Weibo (`/2/statuses/share`).
    pub async fn publish_status(
        &self,
        content: &str,
        _pic_paths: Vec<String>,
        poi: Option<String>,
        visible_type: i32,
    ) -> Result<StatusModel, NetError> {
        let path = "/2/statuses/share";
        let url = format!("{}{}", WEIBO_API_BASE, path);

        let visible_str = visible_type.to_string();
        let mut custom = vec![
            ("status", content),
            ("visible", visible_str.as_str()),
        ];

        let poi_val;
        if let Some(p) = &poi {
            poi_val = p.clone();
            custom.push(("rip", poi_val.as_str()));
        }

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .post(&url)
            .headers(headers)
            .form(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let res_text = response.text().await?;

        let status: StatusModel = serde_json::from_str(&res_text)?;
        Ok(status)
    }

    /// Fetches a user's profile metadata (`/2/users/show`).
    pub async fn fetch_user_profile(&self, uid: &str) -> Result<UserModel, NetError> {
        let path = "/2/users/show";
        let url = format!("{}{}", WEIBO_API_BASE, path);
        let custom = [("uid", uid)];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;
        let user: UserModel = serde_json::from_str(&text)?;
        Ok(user)
    }

    /// Follows a user (`/2/friendships/create`).
    pub async fn follow_user(&self, uid: &str) -> Result<bool, NetError> {
        let path = "/2/friendships/create";
        let url = format!("{}{}", WEIBO_API_BASE, path);
        let custom = [("uid", uid)];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .post(&url)
            .headers(headers)
            .form(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        Ok(response.status().is_success())
    }

    /// Unfollows a user (`/2/friendships/destroy`).
    pub async fn unfollow_user(&self, uid: &str) -> Result<bool, NetError> {
        let path = "/2/friendships/destroy";
        let url = format!("{}{}", WEIBO_API_BASE, path);
        let custom = [("uid", uid)];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .post(&url)
            .headers(headers)
            .form(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        Ok(response.status().is_success())
    }

    /// Fetches Super Topic (超话) metadata and statistics (`/2/page/topic`).
    pub async fn fetch_topic_detail(&self, topic_name: &str) -> Result<TopicModel, NetError> {
        let path = "/2/page/topic";
        let url = format!("{}{}", WEIBO_API_BASE, path);
        let custom = [("q", topic_name)];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;
        let topic: TopicModel = serde_json::from_str(&text)?;
        Ok(topic)
    }

    /// Signs in (打卡签到) to a Super Topic (`/2/page/button`).
    pub async fn sign_in_topic(&self, topic_id: &str) -> Result<TopicSignInResult, NetError> {
        let path = "/2/page/button";
        let url = format!("{}{}", WEIBO_API_BASE, path);
        let custom = [("action", "sign"), ("id", topic_id)];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .post(&url)
            .headers(headers)
            .form(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;
        let result: TopicSignInResult = serde_json::from_str(&text)?;
        Ok(result)
    }

    /// Fetches active Direct Message conversations (`/2/direct_messages/user_list`).
    pub async fn fetch_dm_conversations(&self) -> Result<Vec<DmConversationModel>, NetError> {
        let path = "/2/direct_messages/user_list";
        let url = format!("{}{}", WEIBO_API_BASE, path);

        let params = self.build_signed_params(path, &[]);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;
        let list: Vec<DmConversationModel> = serde_json::from_str(&text)?;
        Ok(list)
    }

    /// Fetches messages in a Direct Message conversation (`/2/direct_messages/conversation`).
    pub async fn fetch_dm_messages(&self, uid: &str) -> Result<Vec<DmMessageModel>, NetError> {
        let path = "/2/direct_messages/conversation";
        let url = format!("{}{}", WEIBO_API_BASE, path);
        let custom = [("uid", uid)];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;
        let list: Vec<DmMessageModel> = serde_json::from_str(&text)?;
        Ok(list)
    }

    /// Sends a direct message to a user (`/2/direct_messages/new`).
    pub async fn send_dm(&self, uid: &str, text: &str) -> Result<DmMessageModel, NetError> {
        let path = "/2/direct_messages/new";
        let url = format!("{}{}", WEIBO_API_BASE, path);
        let custom = [("uid", uid), ("text", text)];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .post(&url)
            .headers(headers)
            .form(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let res_text = response.text().await?;
        let msg: DmMessageModel = serde_json::from_str(&res_text)?;
        Ok(msg)
    }

    /// Fetches interactive notifications (`/2/messages/notifications`).
    pub async fn fetch_notifications(
        &self,
        notify_type: i32,
    ) -> Result<Vec<NotificationModel>, NetError> {
        let path = "/2/messages/notifications";
        let url = format!("{}{}", WEIBO_API_BASE, path);
        let type_str = notify_type.to_string();
        let custom = [("type", type_str.as_str())];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;
        let list: Vec<NotificationModel> = serde_json::from_str(&text)?;
        Ok(list)
    }

    /// Fetches real-time Hot Search list (`/2/search/topics` or container ranking 1..=50).
    pub async fn fetch_hot_search(&self) -> Result<Vec<HotSearchItemModel>, NetError> {
        let path = "/2/guest/container/hotsearch";
        let url = format!("{}{}", WEIBO_API_BASE, path);

        let params = self.build_signed_params(path, &[]);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;
        let list: Vec<HotSearchItemModel> = serde_json::from_str(&text)?;
        Ok(list)
    }

    /// Searches across Weibo categories (all, user, status, pic, video, topic).
    pub async fn search_weibo(
        &self,
        query: &str,
        category: &str,
        page: u32,
    ) -> Result<SearchResultModel, NetError> {
        let path = "/2/search/universal";
        let url = format!("{}{}", WEIBO_API_BASE, path);
        let page_str = page.to_string();
        let custom = [
            ("q", query),
            ("type", category),
            ("page", page_str.as_str()),
        ];

        let params = self.build_signed_params(path, &custom);
        let headers = self.build_headers();

        let response = self
            .client
            .get(&url)
            .headers(headers)
            .query(&params)
            .send()
            .await?;

        self.handle_response_headers(response.headers());
        let text = response.text().await?;
        let result: SearchResultModel = serde_json::from_str(&text)?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_signed_params_generation() {
        let device = DeviceContext::default();
        let client = WeiboClient::new(device, None, None);

        let params = client.build_signed_params(
            "/2/statuses/friends/timeline",
            &[("count", "30"), ("page", "1")],
        );

        let param_map: HashMap<String, String> = params.into_iter().collect();
        assert!(param_map.contains_key("s"));
        assert_eq!(param_map.get("count").unwrap(), "30");
        assert_eq!(param_map.get("from").unwrap(), "10B6395010");
        assert_eq!(param_map.get("c").unwrap(), "android");
    }

    #[test]
    fn test_timeline_caching() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let device = DeviceContext::default();
        let client = WeiboClient::new(device, None, Some(db.clone()));

        let dao = ShareJsonDao::new(&db);
        let fake_json = r#"{"statuses":[{"id":123,"mid":"test","created_at":"now","text":"Cached text"}]}"#;
        dao.put("home_timeline_cache_999", fake_json).unwrap();

        let cached = client.get_cached_timeline("999").unwrap();
        assert_eq!(cached.statuses.len(), 1);
        assert_eq!(cached.statuses[0].id, 123);
        assert_eq!(cached.statuses[0].text, "Cached text");
    }

    #[test]
    fn test_validator_headers_and_response_capture() {
        let device = DeviceContext::default();
        let client = WeiboClient::new(device, None, None);

        // 1. Initially no validator
        assert!(client.validator().is_none());
        let headers = client.build_headers();
        assert!(!headers.contains_key("X-Validator"));

        // 2. Set validator manually (e.g. from prior session or server challenge)
        client.set_validator(Some("test_validator_token_12345".to_string()));
        assert_eq!(
            client.validator().as_deref(),
            Some("test_validator_token_12345")
        );

        let headers = client.build_headers();
        assert_eq!(
            headers.get("X-Validator").unwrap().to_str().unwrap(),
            "test_validator_token_12345"
        );
        assert_eq!(headers.get("X-Log-Uid").unwrap().to_str().unwrap(), "");
        assert!(headers.contains_key("X-Sessionid"));

        // 3. Simulate incoming response header containing new X-Validator (C3185mA.java L58-61)
        let mut resp_headers = HeaderMap::new();
        resp_headers.insert(
            "X-Validator",
            HeaderValue::from_static("updated_validator_token_67890"),
        );
        client.handle_response_headers(&resp_headers);

        assert_eq!(
            client.validator().as_deref(),
            Some("updated_validator_token_67890")
        );

        // 4. Verify new headers use updated validator
        let headers2 = client.build_headers();
        assert_eq!(
            headers2.get("X-Validator").unwrap().to_str().unwrap(),
            "updated_validator_token_67890"
        );

        // 5. Test client clones share the exact same validator reference
        let client_clone = client.clone();
        assert_eq!(
            client_clone.validator().as_deref(),
            Some("updated_validator_token_67890")
        );
        client_clone.set_validator(Some("shared_token_abc".to_string()));
        assert_eq!(
            client.validator().as_deref(),
            Some("shared_token_abc")
        );
    }

    #[test]
    fn test_comment_params_and_caching() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let device = DeviceContext::default();
        let client = WeiboClient::new(device, None, Some(db.clone()));

        // Test params for comments
        let params = client.build_signed_params(
            "/2/comments/show",
            &[("id", "456789"), ("page", "1"), ("count", "20")],
        );
        let param_map: HashMap<String, String> = params.into_iter().collect();
        assert_eq!(param_map.get("id").unwrap(), "456789");
        assert_eq!(param_map.get("count").unwrap(), "20");
        assert!(param_map.contains_key("s"));

        // Test cached comments
        let dao = ShareJsonDao::new(&db);
        let fake_comments_json = r#"{
            "total_number": 1,
            "comments": [
                {
                    "id": 999888,
                    "text": "测试已缓存评论",
                    "created_at": "刚刚",
                    "like_counts": 3,
                    "liked": false
                }
            ]
        }"#;
        dao.put("comments_cache_456789", fake_comments_json).unwrap();

        let cached = client.get_cached_comments("456789").unwrap();
        assert_eq!(cached.total_number, 1);
        assert_eq!(cached.comments.len(), 1);
        assert_eq!(cached.comments[0].text, "测试已缓存评论");
    }
}
