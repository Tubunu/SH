//! HTTP client for the Weibo web (`weibo.com/ajax/*`) API surface.
//!
//! Why the web API instead of the original app's `api.weibo.cn/2/*`?
//! The original client signs every request with `cum`, which is produced by
//! `libwbutil.so` (ARM-only native code calling `WeiboApplication.calculateS`).
//! That cannot be shipped on iOS and cannot be re-run off-device, so the
//! reconstruction targets the official web endpoints. They expose the same
//! underlying data (statuses, comments, profiles, hot search) and authenticate
//! through the same account cookies captured by the in-app login WebView.

use std::sync::{Arc, Mutex};

use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, ACCEPT_LANGUAGE, REFERER};
use serde_json::Value;

use super::cookies::CookieJar;

pub const DESKTOP_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
     (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

pub const WEIBO_BASE: &str = "https://weibo.com";

#[derive(Debug, Clone)]
pub struct WebError {
    pub kind: WebErrorKind,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WebErrorKind {
    /// No usable cookie / the server rejected the session.
    Unauthenticated,
    /// Server side throttling or risk control.
    Blocked,
    /// Endpoint returned `ok: 0` or an `error` field.
    Api,
    /// Networking problem (DNS, TLS, timeout...).
    Network,
    /// Unexpected payload.
    Parse,
}

impl WebError {
    pub fn new(kind: WebErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    pub fn unauthenticated() -> Self {
        Self::new(
            WebErrorKind::Unauthenticated,
            "登录状态已失效，请重新登录",
        )
    }

    pub fn blocked() -> Self {
        Self::new(
            WebErrorKind::Blocked,
            "请求被微博风控拦截，请稍后重试或更换网络",
        )
    }

    pub fn parse(message: impl Into<String>) -> Self {
        Self::new(WebErrorKind::Parse, message)
    }

    pub fn network(err: impl std::fmt::Display) -> Self {
        Self::new(WebErrorKind::Network, format!("网络请求失败：{err}"))
    }

    pub fn api(message: impl Into<String>) -> Self {
        Self::new(WebErrorKind::Api, message)
    }
}

impl std::fmt::Display for WebError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for WebError {}

pub type WebResult<T> = Result<T, WebError>;

#[derive(Clone)]
pub struct WebClient {
    http: reqwest::Client,
    jar: Arc<Mutex<CookieJar>>,
    ua: String,
}

impl WebClient {
    pub fn new() -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .connect_timeout(std::time::Duration::from_secs(10))
            .gzip(true)
            .brotli(true)
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());

        Self {
            http,
            jar: Arc::new(Mutex::new(CookieJar::new())),
            ua: DESKTOP_UA.to_string(),
        }
    }

    pub fn set_cookie(&self, raw: &str) -> usize {
        match self.jar.lock() {
            Ok(mut jar) => jar.import(raw),
            Err(_) => 0,
        }
    }

    pub fn cookie_header(&self) -> String {
        self.jar
            .lock()
            .map(|jar| jar.header())
            .unwrap_or_default()
    }

    pub fn cookie_items(&self) -> Vec<(String, String)> {
        self.jar
            .lock()
            .map(|jar| jar.to_vec())
            .unwrap_or_default()
    }

    pub fn cookie_value(&self, key: &str) -> Option<String> {
        self.jar
            .lock()
            .ok()
            .and_then(|jar| jar.get(key).map(|s| s.to_string()))
    }

    pub fn has_session(&self) -> bool {
        self.jar
            .lock()
            .map(|jar| jar.get("SUB").is_some())
            .unwrap_or(false)
    }

    pub fn clear_cookies(&self) {
        if let Ok(mut jar) = self.jar.lock() {
            jar.clear();
        }
    }

    fn headers(&self, referer: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            reqwest::header::USER_AGENT,
            HeaderValue::from_str(&self.ua).unwrap_or(HeaderValue::from_static("Mozilla/5.0")),
        );
        headers.insert(
            ACCEPT,
            HeaderValue::from_static(
                "application/json, text/plain, */*",
            ),
        );
        headers.insert(
            ACCEPT_LANGUAGE,
            HeaderValue::from_static("zh-CN,zh;q=0.9,en;q=0.8"),
        );
        headers.insert(REFERER, HeaderValue::from_str(referer).unwrap_or(HeaderValue::from_static("https://weibo.com/")));
        headers.insert("X-Requested-With", HeaderValue::from_static("XMLHttpRequest"));

        let cookie = self.cookie_header();
        if !cookie.is_empty() {
            if let Ok(value) = HeaderValue::from_str(&cookie) {
                headers.insert(reqwest::header::COOKIE, value);
            }
        }
        if let Some(xsrf) = self.cookie_value("XSRF-TOKEN") {
            if let Ok(value) = HeaderValue::from_str(&xsrf) {
                headers.insert("X-XSRF-TOKEN", value);
            }
        }
        headers
    }

    fn absorb(&self, headers: &HeaderMap) {
        if let Ok(mut jar) = self.jar.lock() {
            jar.absorb(headers);
        }
    }

    /// Raw GET that returns the body without JSON parsing (used for JSONP).
    pub async fn get_raw(&self, url: &str, referer: &str) -> WebResult<String> {
        let response = self
            .http
            .get(url)
            .headers(self.headers(referer))
            .send()
            .await
            .map_err(WebError::network)?;
        self.absorb(response.headers());
        let status = response.status();
        if status.as_u16() == 403 || status.as_u16() == 401 {
            return Err(WebError::unauthenticated());
        }
        response.text().await.map_err(WebError::network)
    }

    /// Raw form POST that returns the body without JSON parsing (used for JSONP).
    pub async fn post_form_raw(
        &self,
        url: &str,
        form: &[(String, String)],
        referer: &str,
    ) -> WebResult<String> {
        let response = self
            .http
            .post(url)
            .headers(self.headers(referer))
            .form(form)
            .send()
            .await
            .map_err(WebError::network)?;
        self.absorb(response.headers());
        let status = response.status();
        if status.as_u16() == 403 || status.as_u16() == 401 {
            return Err(WebError::unauthenticated());
        }
        response.text().await.map_err(WebError::network)
    }

    pub async fn get(&self, url: &str, referer: &str) -> WebResult<Value> {
        let response = self
            .http
            .get(url)
            .headers(self.headers(referer))
            .send()
            .await
            .map_err(WebError::network)?;

        self.absorb(response.headers());

        let status = response.status();
        if status.as_u16() == 403 || status.as_u16() == 401 {
            return Err(WebError::unauthenticated());
        }
        if status.as_u16() == 418 {
            return Err(WebError::blocked());
        }

        let text = response.text().await.map_err(WebError::network)?;
        Self::decode(&text, status.as_u16())
    }

    pub async fn post_form(
        &self,
        url: &str,
        form: &[(String, String)],
        referer: &str,
    ) -> WebResult<Value> {
        let response = self
            .http
            .post(url)
            .headers(self.headers(referer))
            .form(form)
            .send()
            .await
            .map_err(WebError::network)?;

        self.absorb(response.headers());

        let status = response.status();
        if status.as_u16() == 403 || status.as_u16() == 401 {
            return Err(WebError::unauthenticated());
        }
        if status.as_u16() == 418 {
            return Err(WebError::blocked());
        }

        let text = response.text().await.map_err(WebError::network)?;
        Self::decode(&text, status.as_u16())
    }

    /// Multipart upload (used by `picupload.weibo.com`).
    ///
    /// The endpoint answers `{"code":"A00006"}`-style JSON on success and a
    /// plain `{"code":"..."}` on failure, so errors are surfaced verbatim.
    pub async fn post_multipart(
        &self,
        url: &str,
        form: reqwest::multipart::Form,
        referer: &str,
    ) -> WebResult<Value> {
        let response = self
            .http
            .post(url)
            .headers(self.headers(referer))
            .multipart(form)
            .send()
            .await
            .map_err(WebError::network)?;

        self.absorb(response.headers());

        let status = response.status();
        if status.as_u16() == 403 || status.as_u16() == 401 {
            return Err(WebError::unauthenticated());
        }

        let text = response.text().await.map_err(WebError::network)?;
        Self::decode(&text, status.as_u16())
    }

    fn decode(text: &str, status: u16) -> WebResult<Value> {
        let trimmed = text.trim_start();
        if trimmed.starts_with('<') {
            // Weibo answers with an HTML error page for unauthorised requests.
            return Err(if status == 403 {
                WebError::unauthenticated()
            } else {
                WebError::api(format!("微博返回了网页错误（HTTP {status}）"))
            });
        }

        let value: Value = serde_json::from_str(text)
            .map_err(|e| WebError::parse(format!("响应解析失败：{e}")))?;

        if let Some(err) = value.get("error").and_then(|v| v.as_str()) {
            if !err.is_empty() {
                return Err(WebError::api(format!("微博接口错误：{err}")));
            }
        }

        if let Some(ok) = value.get("ok") {
            let ok_flag = ok.as_i64().unwrap_or(1);
            if ok_flag == 0 {
                let msg = value
                    .get("msg")
                    .or_else(|| value.get("message"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("请求失败");
                return Err(WebError::api(msg.to_string()));
            }
        }

        Ok(value)
    }
}

impl Default for WebClient {
    fn default() -> Self {
        Self::new()
    }
}
