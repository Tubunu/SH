//! Token, GSID, and Cookie Session Models.
//! Handles Access Token life cycle, expiration heuristics, and Weibo cookie parsing.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

/// Token bundle containing all authentication artifacts for a Weibo account.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TokenBundle {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at_ms: Option<i64>,
    pub gsid: Option<String>,
    pub s_value: Option<String>,
    pub i_value: Option<String>,
    pub sub: Option<String>,
    pub subp: Option<String>,
    pub raw_cookie: Option<String>,
}

impl TokenBundle {
    /// Creates a TokenBundle from raw fields and parses the cookie string if present.
    pub fn new(
        access_token: String,
        refresh_token: Option<String>,
        expires_at_ms: Option<i64>,
        gsid: Option<String>,
        s_value: Option<String>,
        i_value: Option<String>,
        cookie: Option<String>,
    ) -> Self {
        let mut bundle = Self {
            access_token,
            refresh_token,
            expires_at_ms,
            gsid,
            s_value,
            i_value,
            sub: None,
            subp: None,
            raw_cookie: cookie.clone(),
        };

        if let Some(cookie_str) = cookie {
            let parsed = Self::parse_cookie_str(&cookie_str);
            bundle.sub = parsed.get("SUB").cloned();
            bundle.subp = parsed.get("SUBP").cloned();
        }

        bundle
    }

    /// Parses a standard HTTP `Cookie` header string into key-value pairs.
    pub fn parse_cookie_str(cookie_str: &str) -> HashMap<String, String> {
        let mut map = HashMap::new();
        for item in cookie_str.split(';') {
            let part = item.trim();
            if let Some((k, v)) = part.split_once('=') {
                map.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
        map
    }

    /// Formats SUB and SUBP into standard Cookie header value.
    pub fn formatted_cookie(&self) -> String {
        let mut parts = Vec::new();
        if let Some(sub) = &self.sub {
            parts.push(format!("SUB={}", sub));
        }
        if let Some(subp) = &self.subp {
            parts.push(format!("SUBP={}", subp));
        }
        if parts.is_empty() {
            self.raw_cookie.clone().unwrap_or_default()
        } else {
            parts.join("; ")
        }
    }

    /// Returns the current system timestamp in milliseconds.
    fn now_ms() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }

    /// Checks if the access token is already expired.
    pub fn is_expired(&self) -> bool {
        if let Some(exp) = self.expires_at_ms {
            exp > 0 && Self::now_ms() >= exp
        } else {
            false
        }
    }

    /// Checks if the token should be proactively refreshed (e.g. within 2 hours of expiration).
    pub fn needs_refresh(&self) -> bool {
        if let Some(exp) = self.expires_at_ms {
            let buffer_ms = 2 * 3600 * 1000; // 2 hours buffer
            exp > 0 && Self::now_ms() + buffer_ms >= exp
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cookie_parsing() {
        let cookie_str = "SUB=_2AkMSabc123; SUBP=0033Wrxs...; Path=/; Domain=.weibo.cn";
        let bundle = TokenBundle::new(
            "test_token".to_string(),
            None,
            None,
            None,
            None,
            None,
            Some(cookie_str.to_string()),
        );

        assert_eq!(bundle.sub.as_deref(), Some("_2AkMSabc123"));
        assert_eq!(bundle.subp.as_deref(), Some("0033Wrxs..."));
        assert_eq!(
            bundle.formatted_cookie(),
            "SUB=_2AkMSabc123; SUBP=0033Wrxs..."
        );
    }

    #[test]
    fn test_token_expiration() {
        let past = TokenBundle::now_ms() - 1000;
        let expired_bundle = TokenBundle::new(
            "token".to_string(),
            None,
            Some(past),
            None,
            None,
            None,
            None,
        );
        assert!(expired_bundle.is_expired());

        let future = TokenBundle::now_ms() + 10_000_000;
        let valid_bundle = TokenBundle::new(
            "token".to_string(),
            None,
            Some(future),
            None,
            None,
            None,
            None,
        );
        assert!(!valid_bundle.is_expired());
    }
}
