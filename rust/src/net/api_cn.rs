//! Mobile Weibo API Engine (`https://api.weibo.cn/2/*`).
//!
//! 1:1 Rust port of Share v3.9.6 Build 925 networking stack (`UB.java`, `PB.java`,
//! `C3185mA.java`, `C4426oA.java`, `InterfaceC2935jA.java`, `C5746oo0Oo0o.java`,
//! and `C7024ta.java` / `C7192va.java`).
//!
//! Every request percent-encodes its query parameters once using deterministic
//! RFC-3986 ordering, injects `aid`, computes `cum = cum_getparam(suffix)` over
//! the exact wire `/2/...?...` suffix, and appends `&cum=...` verbatim so the
//! server sees byte-for-byte identical bytes.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use reqwest::header::{HeaderMap, HeaderValue, COOKIE, USER_AGENT};
use reqwest::multipart::{Form, Part};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::crypto::base62::mid_to_id;
use crate::crypto::rsa::encrypt_password;
use crate::crypto::wbutil::{
    build_guest_mfp, cum_getparam, guest_checktoken, new_calculate_s, SPOOF_APP_KEY,
    SPOOF_KEY_HASH, SPOOF_PACKAGE, WB_FROM,
};
use crate::web::cookies::is_cookie_attribute;

pub const API_CN_BASE: &str = "https://api.weibo.cn/2/";
pub const API_COM_BASE: &str = "https://api.weibo.com/2/";
pub const UPLOAD_MSS_URL: &str = "https://upload.api.weibo.com/2/mss/upload.json";
pub const FILEPLATFORM_INIT_URL: &str = "https://upload.api.weibo.com/fileplatform/init.json";
pub const FILEPLATFORM_UPLOAD_URL: &str = "https://upload.api.weibo.com/fileplatform/upload.json";
pub const PASSPORT_QR_CONFIRM_URL: &str = "https://passport.weibo.cn/signin/qrcode/confirm";

const QR_MOBILE_WEIBO_UA: &str = "Mozilla/5.0 (iPhone; CPU iPhone OS 10_2_1 like Mac OS X) \
    AppleWebKit/602.4.6 (KHTML, like Gecko) Mobile/14D27 Weibo (iPhone9,2__weibo__9.6.2__iphone__os10.2.1)";

/// Whitelisted paths that skip `-1005`/`20031`/`-200` interception (`C4426oA.O00000o0`).
const INTERCEPTOR_SKIP_PATHS: &[&str] = &[
    "/2/account/login",
    "/2/remind/unread_count",
    "/2/remind/unread_count.json",
    "/2/direct_messages/public/messages.json",
    "/2/register/by_phone",
    "/login_sendcode",
    "/2/register/sendcode",
    "/2/captcha/get",
    "/bind_fb",
];

/// Structured error returned by `ApiCnClient`.
#[derive(Debug, Clone)]
pub enum ApiCnError {
    Transport(String),
    HttpStatus {
        status: u16,
        body: String,
    },
    WeiboApi {
        errno: i64,
        errmsg: String,
        raw: Value,
    },
    Crypto(String),
    Parse(String),
}

impl fmt::Display for ApiCnError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Transport(msg) => write!(f, "Network error: {msg}"),
            Self::HttpStatus { status, body } => {
                write!(f, "HTTP {status}: {}", truncate_for_log(body, 280))
            }
            Self::WeiboApi { errno, errmsg, .. } => {
                write!(f, "({errno}) {errmsg}")
            }
            Self::Crypto(msg) => write!(f, "Crypto error: {msg}"),
            Self::Parse(msg) => write!(f, "Parse error: {msg}"),
        }
    }
}

impl std::error::Error for ApiCnError {}

/// Session and spoofed device state for `api.weibo.cn/2/*` calls.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MobileSession {
    pub uid: String,
    pub gsid: String,
    pub aid: String,
    pub cookie: String,
    pub oauth_token: String,
    pub i_value: String,
    pub validator: String,
    pub android_id: String,
    pub did: String,
    pub manufacturer: String,
    pub model: String,
    pub os_release: String,
    pub network_type: String,
    pub lang: String,
}

impl Default for MobileSession {
    fn default() -> Self {
        Self {
            uid: String::new(),
            gsid: String::new(),
            aid: String::new(),
            cookie: String::new(),
            oauth_token: String::new(),
            i_value: String::new(),
            validator: String::new(),
            android_id: "9f3c7a21e8d04b51".to_string(),
            did: "a4e81c92f01d77389bc2041e6d55a013".to_string(),
            manufacturer: "Xiaomi".to_string(),
            model: "M2012K11AC".to_string(),
            os_release: "12".to_string(),
            network_type: "wifi".to_string(),
            lang: "zh_CN".to_string(),
        }
    }
}

impl MobileSession {
    /// Maps manufacturer to Sina `oldwm` code (`UB.java` lines 209-237).
    pub fn oldwm(&self) -> &'static str {
        match self.manufacturer.trim().to_ascii_uppercase().as_str() {
            "ONEPLUS" => "14038_0004",
            "MEIZU" => "9848_0009",
            "OPPO" => "9847_0002",
            "VIVO" => "9856_0004",
            "SMARTISAN" => "14010_0013",
            "ZUK" => "20003_0002",
            "SONY" => "9982_90002",
            "XIAOMI" | "REDMI" => "20005_0002",
            _ => "3333_1001",
        }
    }

    /// Form/query `ua` parameter (`PB.O000000o`).
    pub fn ua_param(&self) -> String {
        format!(
            "{}-{}__weibo__11.6.3__android__android{}",
            self.manufacturer, self.model, self.os_release
        )
    }

    /// Sanitized HTTP `User-Agent` header (`C3185mA.O000000o`: non-ASCII / ctrl -> `'?'`).
    pub fn http_user_agent(&self) -> String {
        let raw = format!("{}_{}_weibo_11.6.3_android", self.model, self.os_release);
        sanitize_ascii_header(&raw)
    }

    /// Device label passed to `account/login` (`device_name`).
    pub fn device_name(&self) -> String {
        format!("{} {}", self.manufacturer, self.model)
    }

    /// Standard query/form parameters injected by `UB.O000000o`.
    pub fn common_params(&self, include_auth: bool) -> BTreeMap<String, String> {
        let mut map = BTreeMap::new();
        map.insert("lang".to_string(), self.lang.clone());
        map.insert("networktype".to_string(), self.network_type.clone());
        map.insert("c".to_string(), "android".to_string());
        map.insert("from".to_string(), WB_FROM.to_string());
        map.insert("wm".to_string(), "3333_2001".to_string());
        map.insert("oldwm".to_string(), self.oldwm().to_string());
        map.insert("ua".to_string(), self.ua_param());
        map.insert("v_p".to_string(), "89".to_string());
        map.insert("android_id".to_string(), self.android_id.clone());
        map.insert("wb_version".to_string(), "5005".to_string());
        map.insert("skin".to_string(), "default".to_string());
        map.insert("v_f".to_string(), "2".to_string());

        if include_auth {
            if !self.gsid.is_empty() {
                map.insert("gsid".to_string(), self.gsid.clone());
            }
            if !self.uid.is_empty() || !self.gsid.is_empty() {
                map.insert("s".to_string(), new_calculate_s(&self.uid));
            }
            if !self.i_value.is_empty() {
                map.insert("i".to_string(), self.i_value.clone());
            }
        }
        map
    }
}

/// Replaces control characters (`<= 31`) and non-ASCII (`>= 127`) with `'?'` (`C3185mA`).
pub fn sanitize_ascii_header(input: &str) -> String {
    input
        .chars()
        .map(|ch| {
            let code = ch as u32;
            if code <= 31 || code >= 127 {
                '?'
            } else {
                ch
            }
        })
        .collect()
}

/// RFC-3986 percent encoder matching byte-for-byte with signed query suffixes.
pub fn encode_component(input: &str) -> String {
    let mut out = String::with_capacity(input.len() * 3 / 2);
    for &b in input.as_bytes() {
        let unreserved = b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~');
        if unreserved {
            out.push(b as char);
        } else {
            out.push('%');
            const HEX: &[u8; 16] = b"0123456789ABCDEF";
            out.push(HEX[(b >> 4) as usize] as char);
            out.push(HEX[(b & 0x0F) as usize] as char);
        }
    }
    out
}

/// Encodes ordered `(k, v)` pairs into `application/x-www-form-urlencoded`-style string.
pub fn encode_pairs(params: &BTreeMap<String, String>) -> String {
    params
        .iter()
        .map(|(k, v)| format!("{}={}", encode_component(k), encode_component(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// Resolves relative endpoints (`"statuses/show"`, `"!/groups/destroy"`, `"/2/page/button"`) or
/// full URLs against `API_CN_BASE` (`https://api.weibo.cn/2/`), appends `aid` and computes
/// `cum = cum_getparam(path_and_query)` on the exact encoded wire string.
pub fn build_signed_url(
    path_or_url: &str,
    params: &BTreeMap<String, String>,
    aid: &str,
    with_aid: bool,
    with_cum: bool,
) -> Result<(String, String), ApiCnError> {
    let resolved_base = resolve_endpoint_url(API_CN_BASE, path_or_url);
    let (base_no_query, existing_query) = match resolved_base.split_once('?') {
        Some((b, q)) => (b.to_string(), Some(q.to_string())),
        None => (resolved_base, None),
    };

    let mut merged = BTreeMap::new();
    if let Some(q) = existing_query {
        for pair in q.split('&').filter(|s| !s.is_empty()) {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            merged.insert(percent_decode(k), percent_decode(v));
        }
    }
    for (k, v) in params {
        merged.insert(k.clone(), v.clone());
    }
    if with_aid && !aid.is_empty() && !merged.contains_key("aid") {
        merged.insert("aid".to_string(), aid.to_string());
    }

    let suffix_path = extract_path_portion(&base_no_query)?;
    let encoded_query = encode_pairs(&merged);
    let suffix_for_cum = if encoded_query.is_empty() {
        suffix_path.clone()
    } else {
        format!("{suffix_path}?{encoded_query}")
    };

    let final_url = if with_cum {
        let cum = cum_getparam(&suffix_for_cum);
        if encoded_query.is_empty() {
            format!("{base_no_query}?cum={cum}")
        } else {
            format!("{base_no_query}?{encoded_query}&cum={cum}")
        }
    } else if encoded_query.is_empty() {
        base_no_query
    } else {
        format!("{base_no_query}?{encoded_query}")
    };

    Ok((final_url, suffix_path))
}

/// Extracts `<input id="..." type="hidden" value="..."/>` inputs from passport QR confirm HTML.
pub fn parse_qr_hidden_inputs(html: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    let mut rest = html;
    while let Some(pos) = rest.find("<input") {
        let tag_start = &rest[pos..];
        let Some(end_idx) = tag_start.find('>') else {
            break;
        };
        let tag = &tag_start[..=end_idx];
        let lower = tag.to_ascii_lowercase();
        if lower.contains("type=\"hidden\"") || lower.contains("type='hidden'") {
            if let (Some(id), Some(val)) = (
                extract_attr(tag, "id").or_else(|| extract_attr(tag, "name")),
                extract_attr(tag, "value"),
            ) {
                if !id.is_empty() && !val.is_empty() {
                    map.insert(id, val);
                }
            }
        }
        rest = &tag_start[end_idx + 1..];
    }
    map
}

/// Dual-purpose HTTP client for `https://api.weibo.cn/2/*` + `upload.api.weibo.com` + `passport.weibo.cn`.
#[derive(Clone)]
pub struct ApiCnClient {
    http: reqwest::Client,
    session: Arc<RwLock<MobileSession>>,
}

impl Default for ApiCnClient {
    fn default() -> Self {
        Self::new(MobileSession::default())
    }
}

impl ApiCnClient {
    /// Creates a new client holding the provided mobile session state.
    pub fn new(session: MobileSession) -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(25))
            .redirect(reqwest::redirect::Policy::limited(6))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            http,
            session: Arc::new(RwLock::new(session)),
        }
    }

    /// Returns a snapshot of the active session state.
    pub fn session(&self) -> MobileSession {
        self.session.read().map(|g| g.clone()).unwrap_or_default()
    }

    /// Replaces the active session state atomically.
    pub fn set_session(&self, next: MobileSession) {
        if let Ok(mut guard) = self.session.write() {
            *guard = next;
        }
    }

    /// Updates credential fields on the active session while preserving device identity.
    pub fn apply_credentials(
        &self,
        uid: impl Into<String>,
        gsid: impl Into<String>,
        aid: Option<String>,
        cookie: Option<String>,
        oauth_token: Option<String>,
    ) {
        if let Ok(mut guard) = self.session.write() {
            guard.uid = uid.into();
            guard.gsid = gsid.into();
            if let Some(a) = aid.filter(|s| !s.is_empty()) {
                guard.aid = a;
            }
            if let Some(c) = cookie.filter(|s| !s.is_empty()) {
                guard.cookie = c;
            }
            if let Some(tok) = oauth_token.filter(|s| !s.is_empty()) {
                guard.oauth_token = tok;
            }
        }
    }

    // ------------------------------------------------------------------------
    // Auth & Security Flows
    // ------------------------------------------------------------------------

    /// Ensures we have at least guest credentials (`aid` + guest `gsid`/`uid`/`cookie`)
    /// by invoking `POST /2/guest/login` if `aid` or `gsid` is missing.
    pub async fn ensure_guest_or_user(&self) -> Result<MobileSession, ApiCnError> {
        let snap = self.session();
        if !snap.gsid.is_empty() && !snap.aid.is_empty() {
            return Ok(snap);
        }
        self.guest_login().await
    }

    /// Registers an anonymous guest session via `POST /2/guest/login` (`OP.java`).
    pub async fn guest_login(&self) -> Result<MobileSession, ApiCnError> {
        let snap = self.session();
        let mfp = build_guest_mfp(&snap.manufacturer, &snap.model, &snap.os_release)
            .map_err(ApiCnError::Crypto)?;
        let checktoken = guest_checktoken(&snap.did);

        let query = snap.common_params(false);

        let mut form = BTreeMap::new();
        form.insert("did".to_string(), snap.did.clone());
        form.insert("device_name".to_string(), snap.device_name());
        form.insert("checktoken".to_string(), checktoken);
        form.insert("key_hash".to_string(), SPOOF_KEY_HASH.to_string());
        form.insert("appkey".to_string(), SPOOF_APP_KEY.to_string());
        form.insert("mfp".to_string(), mfp);
        form.insert("packagename".to_string(), SPOOF_PACKAGE.to_string());

        let val = self
            .execute_signed("POST", "guest/login", query, Some(form), false, true)
            .await?;

        let gsid = val
            .get("gsid")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let aid = val
            .get("aid")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let uid = val
            .get("uid")
            .map(json_id_to_string)
            .unwrap_or_default();
        let sub_cookie = val
            .get("cookie")
            .and_then(|v| v.as_str())
            .map(|c| {
                if c.contains("SUB=") {
                    c.to_string()
                } else {
                    format!("SUB={c}")
                }
            })
            .unwrap_or_default();

        if gsid.is_empty() || aid.is_empty() {
            return Err(ApiCnError::Parse(format!(
                "guest/login response missing gsid or aid: {val}"
            )));
        }

        if let Ok(mut guard) = self.session.write() {
            guard.aid = aid;
            guard.gsid = gsid;
            if !uid.is_empty() {
                guard.uid = uid;
            }
            if !sub_cookie.is_empty() {
                guard.cookie = sub_cookie;
            }
            Ok(guard.clone())
        } else {
            Ok(self.session())
        }
    }

    /// Account + RSA-1024 PKCS1 password login (`POST /2/account/login`).
    ///
    /// Returns raw JSON which either contains active login credentials (`gsid`, `uid`, `cookie`,
    /// `token`, `user`) OR risk-control challenge fields (`errno` `-1005` / `20031`, `phone`,
    /// `phone_list`, `retcode`, `cpt`).
    pub async fn password_login(
        &self,
        username: &str,
        password: &str,
        cpt: Option<(&str, &str)>,
        alt: Option<&str>,
    ) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let enc_pwd = encrypt_password(password)
            .map_err(|e| ApiCnError::Crypto(format!("RSA password encryption failed: {e}")))?;

        let mut query = BTreeMap::new();
        query.insert("getuser".to_string(), "1".to_string());
        query.insert("getoauth".to_string(), "1".to_string());
        query.insert("getcookie".to_string(), "1".to_string());
        query.insert("device_name".to_string(), snap.device_name());

        let mut form = snap.common_params(false);
        if let Some(alt_val) = alt.filter(|s| !s.is_empty()) {
            form.insert("alt".to_string(), alt_val.to_string());
        } else {
            let s_val = new_calculate_s(&format!("{username}{password}"));
            form.insert("u".to_string(), username.to_string());
            form.insert("p".to_string(), enc_pwd);
            form.insert("s".to_string(), s_val);
        }
        if let Some((cpt_id, cpt_code)) = cpt {
            form.insert("cpt".to_string(), cpt_id.to_string());
            form.insert("cptcode".to_string(), cpt_code.to_string());
        }

        let res = self
            .execute_signed("POST", "account/login", query, Some(form), true, true)
            .await?;
        self.try_ingest_login_response(&res);
        Ok(res)
    }

    /// Sends SMS verification code for passwordless login (`POST /2/account/login_sendcode`).
    pub async fn sms_sendcode(&self, phone: &str, area: &str) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let mut query = snap.common_params(false);
        query.insert("phone".to_string(), phone.to_string());
        query.insert("area".to_string(), area.to_string());
        query.insert("getuser".to_string(), "1".to_string());
        query.insert("getoauth".to_string(), "1".to_string());
        query.insert("getcookie".to_string(), "1".to_string());

        let mut form = BTreeMap::new();
        if !snap.aid.is_empty() {
            form.insert("aid".to_string(), snap.aid.clone());
        }
        form.insert("pwd".to_string(), String::new());
        form.insert("flag".to_string(), "1".to_string());
        form.insert("phone".to_string(), phone.to_string());

        self.execute_signed("POST", "account/login_sendcode", query, Some(form), true, true)
            .await
    }

    /// Sends secondary safety verification SMS (`POST /2/account/login_smsverify`).
    pub async fn safety_send_sms(
        &self,
        phone: &str,
        area: &str,
        retcode: &str,
    ) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let mut query = BTreeMap::new();
        query.insert("c".to_string(), "android".to_string());
        query.insert("from".to_string(), WB_FROM.to_string());
        query.insert("i".to_string(), snap.i_value.clone());
        query.insert("phone".to_string(), phone.to_string());
        query.insert("retcode".to_string(), retcode.to_string());
        query.insert("code".to_string(), area.to_string());

        let mut form = BTreeMap::new();
        form.insert("phone".to_string(), phone.to_string());
        form.insert("retcode".to_string(), retcode.to_string());
        form.insert("code".to_string(), area.to_string());

        self.execute_signed(
            "POST",
            "account/login_smsverify",
            query,
            Some(form),
            true,
            true,
        )
        .await
    }

    /// Completes SMS login or risk-control SMS verification (`WeiboSmsVerifyActivity`).
    pub async fn sms_verify_login(
        &self,
        phone: &str,
        area: &str,
        number: &str,
        code_or_sms: &str,
        is_sms_login: bool,
        email_or_user: Option<&str>,
        password: Option<&str>,
        retcode: Option<&str>,
    ) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let mut form = snap.common_params(false);
        form.insert("phone".to_string(), phone.to_string());
        form.insert("number".to_string(), number.to_string());
        form.insert("code".to_string(), area.to_string());

        if let (Some(u), Some(p)) = (email_or_user, password) {
            if !u.is_empty() && !p.is_empty() {
                let enc_p = encrypt_password(p).map_err(ApiCnError::Crypto)?;
                form.insert("u".to_string(), u.to_string());
                form.insert("p".to_string(), enc_p);
                form.insert("s".to_string(), new_calculate_s(&format!("{u}{p}")));
            }
        }
        if is_sms_login {
            form.insert("smscode".to_string(), code_or_sms.to_string());
        } else {
            if let Some(rc) = retcode {
                form.insert("retcode".to_string(), rc.to_string());
            }
            form.insert("smsverifycode".to_string(), code_or_sms.to_string());
        }

        let mut query = BTreeMap::new();
        query.insert("getuser".to_string(), "1".to_string());
        query.insert("getoauth".to_string(), "1".to_string());
        query.insert("getcookie".to_string(), "1".to_string());
        query.insert("device_name".to_string(), snap.device_name());

        let res = self
            .execute_signed("POST", "account/login", query, Some(form), true, true)
            .await?;
        self.try_ingest_login_response(&res);
        Ok(res)
    }

    /// Requests graphic captcha (`POST /2/captcha/get`).
    pub async fn captcha_get(&self, cpt: Option<&str>) -> Result<Value, ApiCnError> {
        let mut params = self.session().common_params(false);
        if let Some(c) = cpt.filter(|s| !s.is_empty()) {
            params.insert("cpt".to_string(), c.to_string());
        }
        self.execute_signed("POST", "captcha/get", BTreeMap::new(), Some(params), true, true)
            .await
    }

    /// Exchanges active session for OAuth token (`GET /2/account/getoauth`).
    pub async fn get_oauth(&self) -> Result<Value, ApiCnError> {
        let params = self.session().common_params(true);
        self.execute_signed("GET", "account/getoauth", params, None, true, true)
            .await
    }

    /// Confirms PC QR login URL (`https://passport.weibo.cn/signin/qrcode/scan*`) using an
    /// authenticated `SUB=...` cookie (`C7024ta` + `C7192va`).
    pub async fn qr_confirm_scan(
        &self,
        qr_url: &str,
        sub_cookie: Option<&str>,
    ) -> Result<Value, ApiCnError> {
        let raw_cookie = sub_cookie
            .map(str::to_string)
            .unwrap_or_else(|| self.session().cookie);
        let sub_pair = extract_sub_cookie(&raw_cookie).ok_or_else(|| {
            ApiCnError::Parse("No SUB cookie available to confirm QR login".to_string())
        })?;

        let html_resp = self
            .http
            .get(qr_url)
            .header(COOKIE, &sub_pair)
            .header(USER_AGENT, QR_MOBILE_WEIBO_UA)
            .send()
            .await
            .map_err(|e| ApiCnError::Transport(e.to_string()))?;
        let status = html_resp.status().as_u16();
        let bytes = html_resp
            .bytes()
            .await
            .map_err(|e| ApiCnError::Transport(e.to_string()))?;
        if status >= 400 {
            return Err(ApiCnError::HttpStatus {
                status,
                body: String::from_utf8_lossy(&bytes).into_owned(),
            });
        }
        let html = String::from_utf8_lossy(&bytes);
        let hidden = parse_qr_hidden_inputs(&html);
        if hidden.is_empty() {
            return Err(ApiCnError::WeiboApi {
                errno: -1,
                errmsg: "二维码可能已经失效，请刷新尝试".to_string(),
                raw: json!({"html_len": bytes.len()}),
            });
        }

        let confirm_resp = self
            .http
            .post(PASSPORT_QR_CONFIRM_URL)
            .header(COOKIE, &sub_pair)
            .header(USER_AGENT, QR_MOBILE_WEIBO_UA)
            .form(&hidden)
            .send()
            .await
            .map_err(|e| ApiCnError::Transport(e.to_string()))?;
        let c_status = confirm_resp.status().as_u16();
        let c_text = confirm_resp
            .text()
            .await
            .map_err(|e| ApiCnError::Transport(e.to_string()))?;
        if c_status >= 400 {
            return Err(ApiCnError::HttpStatus {
                status: c_status,
                body: c_text,
            });
        }
        Ok(serde_json::from_str::<Value>(&c_text)
            .unwrap_or_else(|_| json!({"ok": 1, "raw": c_text})))
    }

    // ------------------------------------------------------------------------
    // Core Generic Signed GET / POST / Upload Engine
    // ------------------------------------------------------------------------

    /// Executes an authenticated + `cum`-signed `GET https://api.weibo.cn/2/{path}`.
    pub async fn get_2(
        &self,
        path: &str,
        extra: BTreeMap<String, String>,
    ) -> Result<Value, ApiCnError> {
        let mut params = self.session().common_params(true);
        for (k, v) in extra {
            params.insert(k, v);
        }
        self.execute_signed("GET", path, params, None, true, true)
            .await
    }

    /// Executes an authenticated + `cum`-signed `POST https://api.weibo.cn/2/{path}`.
    pub async fn post_2(
        &self,
        path: &str,
        extra_query: BTreeMap<String, String>,
        extra_form: BTreeMap<String, String>,
    ) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let mut query = snap.common_params(true);
        for (k, v) in extra_query {
            query.insert(k, v);
        }
        let mut form = snap.common_params(true);
        for (k, v) in extra_form {
            form.insert(k, v);
        }
        self.execute_signed("POST", path, query, Some(form), true, true)
            .await
    }

    /// Uploads a picture using `https://upload.api.weibo.com/2/mss/upload.json`.
    pub async fn upload_pic_mss(
        &self,
        bytes: Vec<u8>,
        filename: &str,
        mime: &str,
    ) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let mut query = snap.common_params(true);
        query.insert("source".to_string(), SPOOF_APP_KEY.to_string());
        let (signed_url, _) = build_signed_url(UPLOAD_MSS_URL, &query, &snap.aid, true, true)?;

        let part = Part::bytes(bytes)
            .file_name(filename.to_string())
            .mime_str(mime)
            .map_err(|e| ApiCnError::Parse(e.to_string()))?;
        let form = Form::new().part("pic", part);

        let mut headers = self.build_headers(&snap);
        if !snap.cookie.is_empty() {
            if let Ok(hv) = HeaderValue::from_str(&snap.cookie) {
                headers.insert(COOKIE, hv);
            }
        }
        let resp = self
            .http
            .post(signed_url)
            .headers(headers)
            .multipart(form)
            .send()
            .await
            .map_err(|e| ApiCnError::Transport(e.to_string()))?;
        self.consume_response(resp).await
    }

    /// Initializes chunked attachment upload on `upload.api.weibo.com/fileplatform/init.json`.
    pub async fn fileplatform_init(
        &self,
        length: usize,
        file_hash: &str,
        filename: &str,
        extprops_json: &str,
        mediaprops_json: &str,
    ) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let mut params = snap.common_params(true);
        params.insert("source".to_string(), SPOOF_APP_KEY.to_string());
        params.insert("moduleID".to_string(), "700".to_string());
        params.insert("act".to_string(), "init".to_string());
        params.insert("need_https".to_string(), "1".to_string());
        params.insert("uid".to_string(), snap.uid.clone());
        params.insert("dynamic".to_string(), "false".to_string());
        params.insert("check".to_string(), file_hash.to_string());
        params.insert("name".to_string(), filename.to_string());
        params.insert("length".to_string(), length.to_string());
        params.insert("type".to_string(), "dm_attachment_pic".to_string());
        params.insert("extprops".to_string(), extprops_json.to_string());
        params.insert("mediaprops".to_string(), mediaprops_json.to_string());

        self.execute_signed("POST", FILEPLATFORM_INIT_URL, params, None, true, false)
            .await
    }

    /// Sends one binary chunk to `fileplatform/upload.json`.
    pub async fn fileplatform_upload_chunk(
        &self,
        upload_url: Option<&str>,
        extra_params: BTreeMap<String, String>,
        chunk: Vec<u8>,
    ) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let url = upload_url.unwrap_or(FILEPLATFORM_UPLOAD_URL);
        let mut params = snap.common_params(true);
        params.insert("source".to_string(), SPOOF_APP_KEY.to_string());
        for (k, v) in extra_params {
            params.insert(k, v);
        }
        let (signed_url, _) = build_signed_url(url, &params, &snap.aid, true, false)?;
        let resp = self
            .http
            .post(signed_url)
            .headers(self.build_headers(&snap))
            .header("Content-Type", "application/octet-stream")
            .body(chunk)
            .send()
            .await
            .map_err(|e| ApiCnError::Transport(e.to_string()))?;
        self.consume_response(resp).await
    }

    // ------------------------------------------------------------------------
    // Domain Convenience Wrappers (InterfaceC2935jA)
    // ------------------------------------------------------------------------

    pub async fn unread_friends_timeline(
        &self,
        since_id: Option<&str>,
        max_id: Option<&str>,
        count: u32,
        page: u32,
    ) -> Result<Value, ApiCnError> {
        let mut p = page_params(since_id, max_id, count, page);
        if since_id.is_none() && max_id.is_none() {
            p.insert("since_id".to_string(), "0".to_string());
        }
        p.insert("refresh".to_string(), "auto".to_string());
        p.insert("trim_level".to_string(), "0".to_string());
        p.insert("trim_page_recom".to_string(), "0".to_string());
        p.insert("ignore_inturrpted_error".to_string(), "true".to_string());
        p.insert("load_mode".to_string(), "0".to_string());
        self.get_2("statuses/unread_friends_timeline", p).await
    }

    pub async fn friends_timeline(
        &self,
        since_id: Option<&str>,
        max_id: Option<&str>,
        count: u32,
        page: u32,
    ) -> Result<Value, ApiCnError> {
        self.get_2("statuses/friends/timeline", page_params(since_id, max_id, count, page))
            .await
    }

    pub async fn friends_timeline_alt(
        &self,
        since_id: Option<&str>,
        max_id: Option<&str>,
        count: u32,
        page: u32,
    ) -> Result<Value, ApiCnError> {
        let mut p = page_params(since_id, max_id, count, page);
        p.insert("trim_level".to_string(), "0".to_string());
        self.get_2("statuses/friends_timeline", p).await
    }

    pub async fn groups_timeline(
        &self,
        list_id: &str,
        since_id: Option<&str>,
        max_id: Option<&str>,
        count: u32,
        page: u32,
    ) -> Result<Value, ApiCnError> {
        let mut p = page_params(since_id, max_id, count, page);
        p.insert("list_id".to_string(), list_id.to_string());
        self.get_2("groups/timeline", p).await
    }

    pub async fn unread_hot_timeline(
        &self,
        group_id: &str,
        max_id: Option<&str>,
        count: u32,
        need_jump: bool,
    ) -> Result<Value, ApiCnError> {
        let mut p = page_params(None, max_id, count, 1);
        p.insert("containerid".to_string(), group_id.to_string());
        p.insert("group_id".to_string(), group_id.to_string());
        p.insert("extparam".to_string(), "discover|new_feed".to_string());
        p.insert("refresh_sourceid".to_string(), "10000001".to_string());
        p.insert(
            "need_jump_scheme".to_string(),
            if need_jump { "1" } else { "0" }.to_string(),
        );
        p.insert("trim_page_recom".to_string(), "0".to_string());
        p.insert("show_toplist".to_string(), "1".to_string());
        p.insert("refresh".to_string(), "pulldown".to_string());
        p.insert("refresh_type".to_string(), "1".to_string());
        p.insert("ignore_inturrpted_error".to_string(), "true".to_string());
        p.insert("load_mode".to_string(), "0".to_string());
        if max_id.is_none() {
            p.insert("since_id".to_string(), "0".to_string());
            p.insert("max_adid".to_string(), "0".to_string());
        }
        self.get_2("statuses/unread_hot_timeline", p).await
    }

    pub async fn user_timeline(
        &self,
        uid: Option<&str>,
        screen_name: Option<&str>,
        since_id: Option<&str>,
        max_id: Option<&str>,
        feature: u32,
        count: u32,
        page: u32,
    ) -> Result<Value, ApiCnError> {
        let mut p = page_params(since_id, max_id, count, page);
        if since_id.is_none() && max_id.is_none() {
            p.insert("since_id".to_string(), "0".to_string());
            p.insert("max_id".to_string(), "0".to_string());
        }
        p.insert("trim_level".to_string(), "0".to_string());
        p.insert("trim_page_recom".to_string(), "0".to_string());
        if let Some(u) = uid.filter(|s| !s.is_empty()) {
            p.insert("uid".to_string(), u.to_string());
        }
        if let Some(sn) = screen_name.filter(|s| !s.is_empty()) {
            p.insert("screen_name".to_string(), sn.to_string());
        }
        if feature > 0 {
            p.insert("feature".to_string(), feature.to_string());
        }
        self.get_2("statuses/user_timeline", p).await
    }

    /// Share's primary user-profile timeline endpoint (`/2/profile/statuses` with `230413<uid>_-_WEIBO_SECOND_PROFILE_WEIBO*`).
    pub async fn profile_statuses(
        &self,
        uid: &str,
        containerid: Option<&str>,
        feature: u32,
        count: u32,
        page: u32,
    ) -> Result<Value, ApiCnError> {
        let suffix = match feature {
            1 => "WEIBO_SECOND_PROFILE_WEIBO_ORI",
            2 => "WEIBO_SECOND_PROFILE_WEIBO_PIC",
            3 => "WEIBO_SECOND_PROFILE_WEIBO_VIDEO",
            _ => "WEIBO_SECOND_PROFILE_WEIBO",
        };
        let cid = containerid
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| format!("230413{uid}_-_{suffix}"));
        let mut p = BTreeMap::new();
        p.insert("uid".to_string(), uid.to_string());
        p.insert("containerid".to_string(), cid);
        p.insert("page".to_string(), page.max(1).to_string());
        p.insert("count".to_string(), count.clamp(10, 30).to_string());
        self.get_2("profile/statuses", p).await
    }

    pub async fn status_show(&self, id: &str) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(id);
        let mut p = single_kv("id", &resolved);
        p.insert("isGetLongText".to_string(), "1".to_string());
        self.get_2("statuses/show", p).await
    }

    pub async fn status_extend(&self, id: &str) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(id);
        self.get_2("statuses/extend", single_kv("id", &resolved)).await
    }

    pub async fn build_comments(
        &self,
        id: &str,
        max_id: Option<&str>,
        flow: u8,
        count: u32,
        is_reload: bool,
    ) -> Result<Value, ApiCnError> {
        self.build_comments_level(id, max_id, flow, count, is_reload, 0).await
    }

    pub async fn build_comments_level(
        &self,
        id: &str,
        max_id: Option<&str>,
        flow: u8,
        count: u32,
        is_reload: bool,
        fetch_level: u8,
    ) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(id);
        let mut p = page_params(None, max_id, count, 1);
        p.insert("id".to_string(), resolved);
        p.insert("flow".to_string(), flow.to_string());
        p.insert("fetch_level".to_string(), fetch_level.to_string());
        if fetch_level > 0 {
            p.insert("is_mix".to_string(), "1".to_string());
        }
        p.insert("is_show_bulletin".to_string(), "2".to_string());
        if is_reload {
            p.insert("is_reload".to_string(), "1".to_string());
        }
        self.get_2("comments/build_comments", p).await
    }

    pub async fn comments_show(
        &self,
        id: &str,
        max_id: Option<&str>,
        page: u32,
        count: u32,
    ) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(id);
        let mut p = page_params(None, max_id, count, page);
        p.insert("id".to_string(), resolved);
        p.insert("filter_by_author".to_string(), "0".to_string());
        self.get_2("comments/show", p).await
    }

    pub async fn comments_show_or_hot(
        &self,
        id: &str,
        flow: u8,
        max_id: Option<&str>,
        page: u32,
        count: u32,
    ) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(id);
        let mut p = page_params(None, max_id, count, page);
        p.insert("id".to_string(), resolved);
        let path = if flow == 0 && max_id.is_none() && page <= 1 {
            "comments/hot_timeline"
        } else {
            "comments/show"
        };
        self.get_2(path, p).await
    }

    pub async fn profile(&self, uid: Option<&str>, screen_name: Option<&str>) -> Result<Value, ApiCnError> {
        let mut p = BTreeMap::new();
        p.insert("enableStar".to_string(), "1".to_string());
        p.insert("uicode".to_string(), "10000198".to_string());
        if let Some(u) = uid.filter(|s| !s.is_empty()) {
            p.insert("uid".to_string(), u.to_string());
        }
        if let Some(sn) = screen_name.filter(|s| !s.is_empty()) {
            p.insert("screen_name".to_string(), sn.to_string());
        }
        self.get_2("profile", p).await
    }

    pub async fn friendships_friends(
        &self,
        uid: &str,
        cursor: i64,
        page: u32,
        count: u32,
    ) -> Result<Value, ApiCnError> {
        let mut p = BTreeMap::new();
        p.insert("uid".to_string(), uid.to_string());
        p.insert("count".to_string(), count.clamp(1, 200).to_string());
        p.insert("page".to_string(), page.max(1).to_string());
        p.insert("cursor".to_string(), cursor.max(0).to_string());
        p.insert("trim_status".to_string(), "1".to_string());
        self.get_2("friendships/friends", p).await
    }

    pub async fn friendships_follow(&self, uid: &str, destroy: bool) -> Result<Value, ApiCnError> {
        let path = if destroy { "friendships/destroy" } else { "friendships/create" };
        self.post_2(path, BTreeMap::new(), single_kv("uid", uid)).await
    }

    pub async fn remind_unread_count(&self, uid: &str) -> Result<Value, ApiCnError> {
        let mut p = BTreeMap::new();
        p.insert("source".to_string(), SPOOF_APP_KEY.to_string());
        p.insert("with_comment_attitude".to_string(), "1".to_string());
        if !uid.is_empty() {
            p.insert("uid".to_string(), uid.to_string());
        }
        self.get_2("remind/unread_count", p).await
    }

    pub async fn mentions_statuses(&self, max_id: Option<&str>, page: u32, count: u32) -> Result<Value, ApiCnError> {
        let mut p = page_params(None, max_id, count, page);
        p.insert("filter_by_author".to_string(), "0".to_string());
        self.get_2("statuses/mentions", p).await
    }

    pub async fn mentions_comments(&self, max_id: Option<&str>, page: u32, count: u32) -> Result<Value, ApiCnError> {
        let mut p = page_params(None, max_id, count, page);
        p.insert("filter_by_author".to_string(), "0".to_string());
        self.get_2("comments/mentions", p).await
    }

    pub async fn comments_to_me(&self, max_id: Option<&str>, page: u32, count: u32) -> Result<Value, ApiCnError> {
        let mut p = page_params(None, max_id, count, page);
        p.insert("filter_by_author".to_string(), "0".to_string());
        self.get_2("comments/to_me", p).await
    }

    pub async fn like_to_me(&self, max_id: Option<&str>, page: u32, count: u32) -> Result<Value, ApiCnError> {
        let mut p = page_params(None, max_id, count, page);
        p.insert("filter_by_author".to_string(), "0".to_string());
        self.get_2("like/to_me", p).await
    }

    pub async fn dm_user_list(&self, cursor: Option<&str>, count: u32) -> Result<Value, ApiCnError> {
        let mut p = BTreeMap::new();
        p.insert("count".to_string(), count.clamp(1, 50).to_string());
        if let Some(c) = cursor.filter(|s| !s.is_empty()) {
            p.insert("cursor".to_string(), c.to_string());
        }
        self.get_2("direct_messages/user_list", p).await
    }

    pub async fn dm_conversation(&self, uid: &str, max_id: Option<&str>, count: u32) -> Result<Value, ApiCnError> {
        let mut p = BTreeMap::new();
        p.insert("uid".to_string(), uid.to_string());
        p.insert("count".to_string(), count.clamp(1, 50).to_string());
        if let Some(m) = max_id.filter(|s| !s.is_empty()) {
            p.insert("max_id".to_string(), m.to_string());
        }
        self.get_2("direct_messages/conversation", p).await
    }

    pub async fn dm_create(&self, uid: &str, text: &str) -> Result<Value, ApiCnError> {
        let mut form = BTreeMap::new();
        form.insert("uid".to_string(), uid.to_string());
        form.insert("text".to_string(), text.to_string());
        form.insert("source".to_string(), SPOOF_APP_KEY.to_string());
        self.post_2("direct_messages/create", BTreeMap::new(), form).await
    }

    pub async fn repost_timeline(&self, status_id: &str, page: u32, count: u32) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(status_id);
        let mut p = page_params(None, None, count, page);
        p.insert("id".to_string(), resolved);
        self.get_2("statuses/repost_timeline", p).await
    }

    pub async fn like_show(&self, status_id: &str, page: u32, count: u32) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(status_id);
        let mut p = page_params(None, None, count, page);
        p.insert("id".to_string(), resolved);
        self.get_2("like/show", p).await
    }

    pub async fn like_status(&self, status_id: &str, undo: bool) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let resolved = resolve_numeric_status_id(status_id);
        let path = if undo { "like/cancel_like" } else { "like/set_like" };
        let mut p = BTreeMap::new();
        p.insert("id".to_string(), resolved);
        if !snap.aid.is_empty() {
            p.insert("aid".to_string(), snap.aid);
        }
        p.insert("ft".to_string(), "1".to_string());
        p.insert("sourcetype".to_string(), "feed".to_string());
        p.insert("attitude_type".to_string(), if undo { "0" } else { "1" }.to_string());
        self.get_2(path, p).await
    }

    pub async fn favorite_status(&self, status_id: &str, undo: bool) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(status_id);
        let path = if undo { "favorites/destroy" } else { "favorites/create" };
        let mut form = single_kv("id", &resolved);
        form.insert("source".to_string(), SPOOF_APP_KEY.to_string());
        self.post_2(path, BTreeMap::new(), form).await
    }

    pub async fn favorites_list(&self, page: u32, count: u32) -> Result<Value, ApiCnError> {
        self.get_2("favorites", page_params(None, None, count, page)).await
    }

    pub async fn comment_create(&self, status_id: &str, text: &str) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(status_id);
        let mut form = BTreeMap::new();
        form.insert("id".to_string(), resolved);
        form.insert("comment".to_string(), text.to_string());
        form.insert("comment_ori".to_string(), "0".to_string());
        form.insert("uicode".to_string(), "10000445".to_string());
        form.insert("moduleID".to_string(), "704".to_string());
        self.post_2("comments/create", BTreeMap::new(), form).await
    }

    pub async fn comment_reply(&self, status_id: &str, cid: &str, text: &str) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(status_id);
        let resolved_cid = resolve_numeric_status_id(cid);
        let mut form = BTreeMap::new();
        form.insert("id".to_string(), resolved);
        form.insert("cid".to_string(), resolved_cid);
        form.insert("comment".to_string(), text.to_string());
        form.insert("comment_ori".to_string(), "0".to_string());
        form.insert("uicode".to_string(), "10000445".to_string());
        form.insert("moduleID".to_string(), "704".to_string());
        self.post_2("comments/reply", BTreeMap::new(), form).await
    }

    pub async fn like_comment(&self, cid: &str, undo: bool) -> Result<Value, ApiCnError> {
        let snap = self.session();
        let resolved_cid = resolve_numeric_status_id(cid);
        let path = if undo { "like/cancel_like" } else { "like/set_like" };
        let mut p = BTreeMap::new();
        p.insert("id".to_string(), resolved_cid);
        if !snap.aid.is_empty() {
            p.insert("aid".to_string(), snap.aid);
        }
        p.insert("object_type".to_string(), "comment".to_string());
        p.insert("attitude_type".to_string(), if undo { "0" } else { "1" }.to_string());
        self.get_2(path, p).await
    }

    pub async fn status_repost(&self, status_id: &str, text: &str, also_comment: bool) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(status_id);
        let mut form = BTreeMap::new();
        form.insert("id".to_string(), resolved);
        form.insert("status".to_string(), text.to_string());
        form.insert("is_comment".to_string(), if also_comment { "1" } else { "0" }.to_string());
        form.insert("uicode".to_string(), "10000713".to_string());
        form.insert("moduleID".to_string(), "704".to_string());
        self.post_2("statuses/repost", BTreeMap::new(), form).await
    }

    pub async fn status_send(&self, content: &str, visible: u32, pic_ids_csv: &str) -> Result<Value, ApiCnError> {
        self.status_send_with_tail(content, visible, pic_ids_csv, None).await
    }

    /// Sends a status via `/2/statuses/send` (`C2850hz.java`), optionally overriding client
    /// `source` (`"intl"` -> Weibo.intl `4215535043`, `"weico"` -> `211160679`) or `source_text`.
    pub async fn status_send_with_tail(
        &self,
        content: &str,
        visible: u32,
        pic_ids_csv: &str,
        tail: Option<&str>,
    ) -> Result<Value, ApiCnError> {
        let mut form = BTreeMap::new();
        form.insert("content".to_string(), content.to_string());
        form.insert("visible".to_string(), visible.to_string());
        if !pic_ids_csv.trim().is_empty() {
            let media: Vec<Value> = pic_ids_csv
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(|pid| json!({"type": "image", "pid": pid}))
                .collect();
            if !media.is_empty() {
                form.insert("media".to_string(), Value::Array(media).to_string());
            }
        }
        let mut extra_query = BTreeMap::new();
        let trimmed_tail = tail.unwrap_or_default().trim();
        let mut has_custom_source = false;
        match trimmed_tail {
            "" | "default" | "android" | "mobile" => {}
            "intl" | "4215535043" | "Weibo.intl" => {
                extra_query.insert("source".to_string(), "4215535043".to_string());
                form.insert("source".to_string(), "4215535043".to_string());
                has_custom_source = true;
            }
            "weico" | "211160679" => {
                extra_query.insert("source".to_string(), "211160679".to_string());
                form.insert("source".to_string(), "211160679".to_string());
                has_custom_source = true;
            }
            "none" | "-1" => {
                form.insert("source".to_string(), "-1".to_string());
                has_custom_source = true;
            }
            custom => {
                let text = custom.strip_prefix("custom:").unwrap_or(custom).trim();
                if !text.is_empty() {
                    form.insert("source_text".to_string(), text.to_string());
                    has_custom_source = true;
                }
            }
        }
        match self
            .post_2("statuses/send", extra_query, form.clone())
            .await
        {
            Ok(v) => Ok(v),
            Err(ApiCnError::WeiboApi { .. }) if has_custom_source => {
                let mut clean_form = form;
                clean_form.remove("source");
                clean_form.remove("source_text");
                self.post_2("statuses/send", BTreeMap::new(), clean_form)
                    .await
            }
            Err(e) => Err(e),
        }
    }

    pub async fn status_destroy(&self, status_id: &str) -> Result<Value, ApiCnError> {
        let resolved = resolve_numeric_status_id(status_id);
        self.get_2("statuses/destroy", single_kv("id", &resolved)).await
    }

    pub async fn groups_list(&self) -> Result<Value, ApiCnError> {
        self.get_2("groups", BTreeMap::new()).await
    }

    pub async fn searchall(&self, q: &str, page: u32, count: u32) -> Result<Value, ApiCnError> {
        self.searchall_typed(q, 1, page, count).await
    }

    pub async fn searchall_typed(
        &self,
        q: &str,
        container_type: u32,
        page: u32,
        count: u32,
    ) -> Result<Value, ApiCnError> {
        let mut p = page_params(None, None, count, page);
        p.insert(
            "containerid".to_string(),
            format!("100103type={container_type}&q={q}&t=1"),
        );
        p.insert("open_searchall_164card".to_string(), "1".to_string());
        self.get_2("searchall", p).await
    }

    pub async fn cardlist(&self, containerid: &str, page: u32, since_id: Option<&str>) -> Result<Value, ApiCnError> {
        let mut p = BTreeMap::new();
        p.insert("containerid".to_string(), containerid.to_string());
        p.insert("page".to_string(), page.max(1).to_string());
        if let Some(s) = since_id.filter(|v| !v.is_empty()) {
            p.insert("since_id".to_string(), s.to_string());
        }
        self.get_2("cardlist", p).await
    }

    pub async fn page_info(&self, containerid: &str, page: u32) -> Result<Value, ApiCnError> {
        let mut p = BTreeMap::new();
        p.insert("containerid".to_string(), containerid.to_string());
        p.insert("page".to_string(), page.max(1).to_string());
        self.get_2("page", p).await
    }

    pub async fn page_button(&self, request_url: &str) -> Result<Value, ApiCnError> {
        self.get_2("/2/page/button", single_kv("request_url", request_url))
            .await
    }

    pub async fn article_show(&self, oid: &str) -> Result<Value, ApiCnError> {
        self.get_2("statuses/article_show", single_kv("oid", oid)).await
    }

    pub async fn question_show(&self, oid: &str) -> Result<Value, ApiCnError> {
        self.get_2("question/show", single_kv("oid", oid)).await
    }

    pub async fn question_watch(&self, oid: &str) -> Result<Value, ApiCnError> {
        self.get_2("question/watch", single_kv("oid", oid)).await
    }

    pub async fn video_playback_batch_get(&self, media_ids: &str) -> Result<Value, ApiCnError> {
        let mut p = BTreeMap::new();
        p.insert("media_ids".to_string(), media_ids.to_string());
        p.insert("object_ids".to_string(), media_ids.to_string());
        self.get_2("!/multimedia/playback/batch_get", p).await
    }

    pub async fn short_url_expand(&self, url_short: &str) -> Result<Value, ApiCnError> {
        self.get_2("short_url/expand", single_kv("url_short", url_short))
            .await
    }

    // ------------------------------------------------------------------------
    // Internal Request / Retry / Interceptor Pipeline
    // ------------------------------------------------------------------------

    async fn execute_signed(
        &self,
        method: &str,
        path_or_url: &str,
        query: BTreeMap<String, String>,
        form: Option<BTreeMap<String, String>>,
        with_aid: bool,
        with_cum: bool,
    ) -> Result<Value, ApiCnError> {
        for attempt in 0..=1 {
            let snap = self.session();
            let (url, suffix_path) =
                build_signed_url(path_or_url, &query, &snap.aid, with_aid, with_cum)?;
            let headers = self.build_headers(&snap);

            let req = match method {
                "POST" => {
                    let builder = self.http.post(&url).headers(headers);
                    match &form {
                        Some(f) => builder.form(f),
                        None => builder,
                    }
                }
                _ => self.http.get(&url).headers(headers),
            };

            let resp = req
                .send()
                .await
                .map_err(|e| ApiCnError::Transport(e.to_string()))?;

            match self.consume_response(resp).await {
                Ok(val) => return Ok(val),
                Err(ApiCnError::WeiboApi { errno: -200, .. })
                    if attempt == 0 && !INTERCEPTOR_SKIP_PATHS.contains(&suffix_path.as_str()) =>
                {
                    continue;
                }
                Err(err) => return Err(err),
            }
        }
        unreachable!("loop returns on attempt == 1")
    }

    fn build_headers(&self, snap: &MobileSession) -> HeaderMap {
        let mut headers = HeaderMap::new();
        if let Ok(ua) = HeaderValue::from_str(&snap.http_user_agent()) {
            headers.insert(USER_AGENT, ua);
        }
        if !snap.validator.is_empty() {
            if let Ok(v) = HeaderValue::from_str(&snap.uid) {
                headers.insert("X-Log-Uid", v);
            }
            if let Ok(sid) = HeaderValue::from_str(&pseudo_uuid()) {
                headers.insert("X-Sessionid", sid);
            }
            if let Ok(val) = HeaderValue::from_str(&snap.validator) {
                headers.insert("X-Validator", val);
            }
        }
        headers
    }

    async fn consume_response(&self, resp: reqwest::Response) -> Result<Value, ApiCnError> {
        if let Some(val_hdr) = resp.headers().get("X-Validator").and_then(|h| h.to_str().ok()) {
            let trimmed = val_hdr.trim();
            if !trimmed.is_empty() {
                if let Ok(mut guard) = self.session.write() {
                    guard.validator = trimmed.to_string();
                }
            }
        }

        let status = resp.status().as_u16();
        let text = resp
            .text()
            .await
            .map_err(|e| ApiCnError::Transport(e.to_string()))?;

        let parsed: Value = serde_json::from_str(&text).map_err(|e| {
            if status >= 400 {
                ApiCnError::HttpStatus { status, body: text.clone() }
            } else {
                ApiCnError::Parse(format!("Invalid JSON ({e}): {}", truncate_for_log(&text, 240)))
            }
        })?;

        if let Some(errno) = parsed.get("errno").and_then(json_to_i64) {
            if errno != 0 && errno != 1 {
                let errmsg = parsed
                    .get("errmsg")
                    .or_else(|| parsed.get("error"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("Weibo API error")
                    .to_string();
                return Err(ApiCnError::WeiboApi {
                    errno,
                    errmsg,
                    raw: parsed,
                });
            }
        } else if let Some(err_code) = parsed.get("error_code").and_then(json_to_i64) {
            let errmsg = parsed
                .get("error")
                .and_then(|v| v.as_str())
                .unwrap_or("Weibo error")
                .to_string();
            return Err(ApiCnError::WeiboApi {
                errno: err_code,
                errmsg,
                raw: parsed,
            });
        }

        if status >= 400 {
            return Err(ApiCnError::HttpStatus { status, body: text });
        }
        Ok(parsed)
    }

    fn try_ingest_login_response(&self, res: &Value) {
        let gsid = res.get("gsid").and_then(|v| v.as_str()).unwrap_or_default();
        let uid = res.get("uid").map(json_id_to_string).unwrap_or_default();
        if gsid.is_empty() && uid.is_empty() {
            return;
        }
        let aid = res
            .get("aid")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let oauth = res
            .get("token")
            .or_else(|| res.get("oauth_token"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let cookie = normalize_login_cookies(res.get("cookie"));
        self.apply_credentials(uid, gsid, aid, cookie, oauth);
    }
}

// ============================================================================
// Pure Helper Functions
// ============================================================================

fn single_kv(k: &str, v: &str) -> BTreeMap<String, String> {
    let mut m = BTreeMap::new();
    m.insert(k.to_string(), v.to_string());
    m
}

fn page_params(
    since_id: Option<&str>,
    max_id: Option<&str>,
    count: u32,
    page: u32,
) -> BTreeMap<String, String> {
    let mut m = BTreeMap::new();
    m.insert("count".to_string(), count.clamp(1, 100).to_string());
    m.insert("page".to_string(), page.max(1).to_string());
    if let Some(s) = since_id.filter(|v| !v.is_empty() && *v != "0") {
        m.insert("since_id".to_string(), s.to_string());
    }
    if let Some(mx) = max_id.filter(|v| !v.is_empty() && *v != "0") {
        m.insert("max_id".to_string(), mx.to_string());
    }
    m
}

fn resolve_endpoint_url(base: &str, path_or_url: &str) -> String {
    if path_or_url.starts_with("http://") || path_or_url.starts_with("https://") {
        path_or_url.to_string()
    } else if path_or_url.starts_with("/2/") {
        format!("https://api.weibo.cn{path_or_url}")
    } else if path_or_url.starts_with('/') {
        format!("https://api.weibo.cn/2{path_or_url}")
    } else {
        format!("{base}{path_or_url}")
    }
}

fn extract_path_portion(url: &str) -> Result<String, ApiCnError> {
    let after_scheme = url
        .split_once("://")
        .map(|(_, rest)| rest)
        .ok_or_else(|| ApiCnError::Parse(format!("Invalid URL missing scheme: {url}")))?;
    Ok(match after_scheme.find('/') {
        Some(idx) => after_scheme[idx..].to_string(),
        None => "/".to_string(),
    })
}

fn percent_decode(input: &str) -> String {
    let mut bytes = Vec::with_capacity(input.len());
    let src = input.as_bytes();
    let mut i = 0;
    while i < src.len() {
        if src[i] == b'+' {
            bytes.push(b' ');
            i += 1;
        } else if src[i] == b'%' && i + 2 < src.len() {
            if let (Some(hi), Some(lo)) = (hex_val(src[i + 1]), hex_val(src[i + 2])) {
                bytes.push((hi << 4) | lo);
                i += 3;
                continue;
            }
            bytes.push(src[i]);
            i += 1;
        } else {
            bytes.push(src[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn extract_attr(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    for quote in ['"', '\''] {
        let needle = format!("{name}={quote}");
        if let Some(start) = lower.find(&needle) {
            let val_start = start + needle.len();
            if let Some(end) = tag[val_start..].find(quote) {
                return Some(tag[val_start..val_start + end].to_string());
            }
        }
    }
    None
}

pub fn resolve_numeric_status_id(id_or_mid: &str) -> String {
    let trimmed = id_or_mid.trim();
    if trimmed.is_empty() || trimmed.chars().all(|c| c.is_ascii_digit()) {
        return trimmed.to_string();
    }
    let decoded = mid_to_id(trimmed);
    if decoded.is_empty() {
        trimmed.to_string()
    } else {
        decoded
    }
}

fn extract_sub_cookie(cookie_str: &str) -> Option<String> {
    for part in cookie_str.split(';') {
        let trimmed = part.trim();
        if let Some(val) = trimmed.strip_prefix("SUB=") {
            if !val.is_empty() {
                return Some(format!("SUB={val}"));
            }
        }
    }
    None
}

fn collect_clean_pairs(raw: &str, out: &mut BTreeMap<String, String>) {
    for line in raw.replace("Cookie:", "").split('\n') {
        for part in line.split(';') {
            let t = part.trim();
            if let Some((k, v)) = t.split_once('=') {
                let k = k.trim();
                let v = v.trim();
                if !k.is_empty() && !v.is_empty() && !is_cookie_attribute(k) {
                    out.insert(k.to_string(), v.to_string());
                }
            }
        }
    }
}

/// Converts Sina's `/2/account/login` cookie structure (or raw string) into a clean
/// `Cookie:` header string, stripping `expires/domain/path` metadata and prioritizing `.weibo.com`.
pub fn normalize_cookie_value(val: &Value) -> Option<String> {
    let mut jar: BTreeMap<String, String> = BTreeMap::new();
    if let Some(s) = val.as_str() {
        collect_clean_pairs(s, &mut jar);
    } else if let Some(obj) = val.as_object() {
        let cookie_map = obj.get("cookie").and_then(|v| v.as_object()).unwrap_or(obj);
        let mut keys: Vec<&String> = cookie_map.keys().collect();
        // Put .weibo.com LAST so its SUB/SUBP takes priority in BTreeMap::insert.
        keys.sort_by_key(|k| match k.as_str() {
            ".weibo.com" | "weibo.com" => 3,
            ".weibo.cn" | "weibo.cn" => 2,
            ".sina.com.cn" => 1,
            _ => 0,
        });
        for k in keys {
            if let Some(line) = cookie_map.get(k).and_then(|v| v.as_str()) {
                collect_clean_pairs(line, &mut jar);
            }
        }
    }
    if jar.is_empty() {
        None
    } else {
        Some(
            jar.into_iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join("; "),
        )
    }
}

fn normalize_login_cookies(cookie_val: Option<&Value>) -> Option<String> {
    normalize_cookie_value(cookie_val?)
}

fn json_to_i64(v: &Value) -> Option<i64> {
    v.as_i64()
        .or_else(|| v.as_str().and_then(|s| s.parse::<i64>().ok()))
}

pub fn json_id_to_string(v: &Value) -> String {
    if let Some(s) = v.as_str() {
        s.to_string()
    } else if let Some(n) = v.as_i64() {
        n.to_string()
    } else if let Some(u) = v.as_u64() {
        u.to_string()
    } else {
        String::new()
    }
}

fn pseudo_uuid() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!(
        "{:08x}-{:04x}-4{:03x}-8{:03x}-{:012x}",
        (nanos >> 64) as u32,
        (nanos >> 48) as u16,
        (nanos >> 36) as u16 & 0x0FFF,
        (nanos >> 24) as u16 & 0x0FFF,
        (nanos & 0xFFFF_FFFF_FFFF) as u64
    )
}

fn truncate_for_log(s: &str, max_chars: usize) -> String {
    let mut out: String = s.chars().take(max_chars).collect();
    if s.chars().count() > max_chars {
        out.push_str("...");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_oldwm_and_header_sanitization() {
        let mut s = MobileSession::default();
        assert_eq!(s.oldwm(), "20005_0002");
        s.manufacturer = "OnePlus".to_string();
        assert_eq!(s.oldwm(), "14038_0004");
        s.manufacturer = "UnknownOEM".to_string();
        assert_eq!(s.oldwm(), "3333_1001");

        assert_eq!(
            sanitize_ascii_header("MI-9\n测试_weibo"),
            "MI-9???_weibo"
        );
    }

    #[test]
    fn test_build_signed_url_matches_pycryptodome_vector() {
        let mut params = BTreeMap::new();
        params.insert("from".to_string(), "10B6395010".to_string());
        params.insert("wm".to_string(), "2468_1001".to_string());
        params.insert("c".to_string(), "android".to_string());
        params.insert("v_p".to_string(), "89".to_string());
        params.insert("lang".to_string(), "zh_CN".to_string());

        // Exact sorted query string vs Python insertion order test:
        let (signed_url, suffix_path) =
            build_signed_url("guest/login", &params, "", false, true).unwrap();
        assert_eq!(suffix_path, "/2/guest/login");
        assert!(signed_url.starts_with("https://api.weibo.cn/2/guest/login?"));
        let (_, query_part) = signed_url.split_once("https://api.weibo.cn").unwrap();
        let (before_cum, cum_pair) = query_part.rsplit_once("&cum=").unwrap();
        assert_eq!(cum_pair, cum_getparam(before_cum));
    }

    #[test]
    fn test_bang_prefix_and_absolute_urls_sign_cleanly() {
        let mut params = BTreeMap::new();
        params.insert("object_ids".to_string(), "1034:49999999".to_string());
        let (url, suffix) = build_signed_url(
            "!/multimedia/playback/batch_get",
            &params,
            "01AaidToken",
            true,
            true,
        )
        .unwrap();
        assert_eq!(suffix, "/2/!/multimedia/playback/batch_get");
        assert!(url.contains("aid=01AaidToken"));
        assert!(url.contains("%3A49999999"));
        let (_, raw_suffix) = url.split_once("https://api.weibo.cn").unwrap();
        let (signed_part, cum) = raw_suffix.rsplit_once("&cum=").unwrap();
        assert_eq!(cum, cum_getparam(signed_part));
    }

    #[test]
    fn test_parse_qr_hidden_inputs() {
        let html = r#"
            <form method="post">
              <input id="qr" type="hidden" value="qr_abc_123"/>
              <input id="token" type="hidden" value="tok_999"/>
              <input id="empty" type="hidden" value=""/>
            </form>
        "#;
        let parsed = parse_qr_hidden_inputs(html);
        assert_eq!(parsed.get("qr").map(String::as_str), Some("qr_abc_123"));
        assert_eq!(parsed.get("token").map(String::as_str), Some("tok_999"));
        assert!(!parsed.contains_key("empty"));
    }

    #[test]
    fn test_normalize_cookie_value_strips_attrs_and_prioritizes_weibo_com() {
        let payload = serde_json::json!({
            "cookie": {
                ".sina.com.cn": "SUB=sina_sub; expires=Thu, 01-Jan-2030 00:00:00 GMT; path=/; domain=.sina.com.cn; HttpOnly\nALC=ac_1; Max-Age=3600",
                ".weibo.cn": "SUB=cn_sub; SUBP=cn_subp; path=/; domain=.weibo.cn; SameSite=None; Secure",
                ".weibo.com": "SUB=com_sub; SUBP=com_subp; XSRF-TOKEN=xsrf_val; expires=Wed, 12-Nov-2031 08:00:00 GMT; path=/; domain=.weibo.com; Priority=High"
            }
        });
        let cleaned = normalize_cookie_value(&payload).expect("cleaned cookie");
        assert!(cleaned.contains("SUB=com_sub"), "got {cleaned}");
        assert!(cleaned.contains("SUBP=com_subp"), "got {cleaned}");
        assert!(cleaned.contains("XSRF-TOKEN=xsrf_val"), "got {cleaned}");
        assert!(cleaned.contains("ALC=ac_1"), "got {cleaned}");
        for forbidden in ["expires=", "path=", "domain=", "Max-Age=", "SameSite=", "Priority="] {
            assert!(!cleaned.contains(forbidden), "unexpected attr {forbidden} in {cleaned}");
        }

        let raw = "Cookie: SUB=raw_sub; expires=Fri, 01-Jan-2027 00:00:00 GMT; domain=.weibo.com; path=/; HttpOnly; SSOLoginState=1700000000";
        let raw_clean = normalize_cookie_value(&Value::String(raw.to_string())).unwrap();
        assert_eq!(raw_clean, "SSOLoginState=1700000000; SUB=raw_sub");
    }

    #[test]
    fn test_resolve_numeric_status_id() {
        assert_eq!(resolve_numeric_status_id(" 5012345678901234 "), "5012345678901234");
        assert_eq!(resolve_numeric_status_id(""), "");
        // Known roundtrip consistency check with base62::id_to_mid
        let numeric = "4987654321098765";
        let mid = crate::crypto::base62::id_to_mid(numeric);
        assert!(!mid.chars().all(|c| c.is_ascii_digit()));
        assert_eq!(resolve_numeric_status_id(&mid), numeric);
    }
}
