//! Cookie jar used by the Weibo web API client.
//!
//! Weibo authenticates web/`ajax` requests purely through cookies (`SUB`, `SUBP`,
//! `XSRF-TOKEN`, ...).  Instead of pulling in a full RFC-6265 implementation we
//! keep an ordered name -> value map which is enough for every endpoint we call
//! and makes persistence / manual cookie import trivial.

use std::collections::BTreeMap;

use reqwest::header::HeaderMap;

#[derive(Debug, Clone, Default)]
pub struct CookieJar {
    map: BTreeMap<String, String>,
}

impl CookieJar {
    pub fn new() -> Self {
        Self::default()
    }

    /// Imports a raw `Cookie:` header style string (or multi-line `Set-Cookie` dump),
    /// filtering out HTTP cookie attributes such as `expires=`, `path=`, `domain=`.
    /// Returns the number of cookie pairs accepted.
    pub fn import(&mut self, raw: &str) -> usize {
        let mut count = 0;
        let normalized = raw.replace('\n', ";").replace("Cookie:", "");
        for part in normalized.split(';') {
            let part = part.trim();
            if part.is_empty() {
                continue;
            }
            if let Some((k, v)) = part.split_once('=') {
                let k = k.trim();
                let v = v.trim();
                if k.is_empty() || v.is_empty() || is_cookie_attribute(k) {
                    continue;
                }
                self.map.insert(k.to_string(), v.to_string());
                count += 1;
            }
        }
        count
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.map.get(key).map(|s| s.as_str())
    }

    pub fn set(&mut self, key: &str, value: &str) {
        self.map.insert(key.to_string(), value.to_string());
    }

    pub fn remove(&mut self, key: &str) {
        self.map.remove(key);
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    pub fn clear(&mut self) {
        self.map.clear();
    }

    /// Serialises the jar back into a `Cookie:` header value.
    pub fn header(&self) -> String {
        self.map
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ")
    }

    /// Persists cookies returned by the server (`Set-Cookie`).
    pub fn absorb(&mut self, headers: &HeaderMap) {
        for value in headers.get_all("set-cookie").iter() {
            let Ok(raw) = value.to_str() else { continue };
            // A single Set-Cookie header can only carry one cookie pair, but it
            // may include attributes separated by ';'.
            let mut segments = raw.split(';');
            let Some(first) = segments.next() else { continue };
            let Some((k, v)) = first.split_once('=') else {
                continue;
            };
            let (k, v) = (k.trim(), v.trim());
            if k.is_empty() || v.is_empty() {
                continue;
            }
            // Respect an immediate expiry (logout).
            let expired = segments.any(|attr| {
                let attr = attr.trim().to_ascii_lowercase();
                attr == "max-age=0"
                    || attr.starts_with("expires=thu, 01 jan 1970")
                    || attr.starts_with("expires=thu, 1 jan 1970")
            });
            if expired {
                self.map.remove(k);
            } else {
                self.map.insert(k.to_string(), v.to_string());
            }
        }
    }

    pub fn to_vec(&self) -> Vec<(String, String)> {
        self.map
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    pub fn from_vec(items: Vec<(String, String)>) -> Self {
        let mut jar = Self::default();
        for (k, v) in items {
            if !is_cookie_attribute(&k) {
                jar.map.insert(k, v);
            }
        }
        jar
    }
}

pub fn is_cookie_attribute(key: &str) -> bool {
    matches!(
        key.trim().to_ascii_lowercase().as_str(),
        "expires" | "max-age" | "domain" | "path" | "samesite" | "priority" | "httponly" | "secure"
    )
}
