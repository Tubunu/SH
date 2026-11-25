//! User-Agent and Device Headers Generator.
//!
//! 1:1 reproduction of:
//! - `PB.O000000o` (Device UA string)
//! - `PB.O00000Oo` (HTTP Request User-Agent)
//! - `C3185mA` (HTTP Header ASCII sanitization)
//! - `UB.O000000o` (Standard Weibo Request Device Parameters)

use std::collections::HashMap;

use super::sign::{DEFAULT_FROM, DEFAULT_WB_VERSION, DEFAULT_WM};

pub const DEFAULT_WEIBO_SDK_VERSION: &str = "11.6.3";

/// Sanitizes a string for HTTP headers by replacing non-ASCII characters
/// (code points <= 31 or >= 127) with '?', matching `C3185mA.java`.
pub fn sanitize_header_value(val: &str) -> String {
    let mut sanitized = String::with_capacity(val.len());
    for c in val.chars() {
        let code = c as u32;
        if code <= 31 || code >= 127 {
            sanitized.push('?');
        } else {
            sanitized.push(c);
        }
    }
    sanitized
}

/// Generates the device UA string.
/// 1:1 reproduction of `PB.O000000o`:
/// `"{MANUFACTURER}-{MODEL}__weibo__11.6.3__android__android{VERSION_RELEASE}"`
pub fn format_device_ua(manufacturer: &str, model: &str, os_release: &str) -> String {
    format!(
        "{}-{}__weibo__{}__android__android{}",
        manufacturer, model, DEFAULT_WEIBO_SDK_VERSION, os_release
    )
}

/// Generates the HTTP `User-Agent` header value.
/// 1:1 reproduction of `PB.O00000Oo` with `C3185mA` sanitization:
/// `"{MODEL}_{VERSION_RELEASE}_weibo_11.6.3_android"`
pub fn format_user_agent(model: &str, os_release: &str) -> String {
    let raw = format!(
        "{}_{}_weibo_{}_android",
        model, os_release, DEFAULT_WEIBO_SDK_VERSION
    );
    sanitize_header_value(&raw)
}

/// Resolves vendor-specific `oldwm` parameter based on device manufacturer.
/// 1:1 reproduction of `UB.java` manufacturer switch.
pub fn resolve_old_wm(manufacturer: &str) -> &'static str {
    match manufacturer.to_ascii_uppercase().as_str() {
        "ONEPLUS" => "14038_0004",
        "MEIZU" => "9848_0009",
        "OPPO" => "9847_0002",
        "VIVO" => "9856_0004",
        "SMARTISAN" => "14010_0013",
        "ZUK" => "20003_0002",
        "SONY" => "9982_90002",
        "XIAOMI" => "20005_0002",
        _ => "3333_1001",
    }
}

/// Device context descriptor for Weibo networking
#[derive(Debug, Clone)]
pub struct DeviceContext {
    pub manufacturer: String,
    pub model: String,
    pub os_release: String,
    pub android_id: String,
    pub network_type: String,
    pub aid: String,
}

impl Default for DeviceContext {
    fn default() -> Self {
        Self {
            manufacturer: "Xiaomi".to_string(),
            model: "23127PN0CC".to_string(),
            os_release: "14".to_string(),
            android_id: "0000000000000000".to_string(),
            network_type: "wifi".to_string(),
            aid: "".to_string(),
        }
    }
}

impl DeviceContext {
    /// Builds standard Weibo client query/form parameters.
    /// 1:1 reproduction of `UB.O000000o(Map<String, String> map)`.
    pub fn build_common_params(&self) -> HashMap<String, String> {
        let mut map = HashMap::new();
        map.insert("lang".to_string(), "zh_CN".to_string());
        map.insert("networktype".to_string(), self.network_type.clone());
        map.insert("c".to_string(), "android".to_string());
        map.insert("from".to_string(), DEFAULT_FROM.to_string());
        map.insert("wm".to_string(), DEFAULT_WM.to_string());
        map.insert(
            "oldwm".to_string(),
            resolve_old_wm(&self.manufacturer).to_string(),
        );
        map.insert(
            "ua".to_string(),
            format_device_ua(&self.manufacturer, &self.model, &self.os_release),
        );
        map.insert("v_p".to_string(), "89".to_string());
        map.insert("android_id".to_string(), self.android_id.clone());
        map.insert("wb_version".to_string(), DEFAULT_WB_VERSION.to_string());
        map.insert("skin".to_string(), "default".to_string());
        map.insert("v_f".to_string(), "2".to_string());

        if !self.aid.is_empty() {
            map.insert("aid".to_string(), self.aid.clone());
        }

        map
    }

    /// User-Agent string for HTTP headers
    pub fn user_agent(&self) -> String {
        format_user_agent(&self.model, &self.os_release)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_device_ua() {
        let ua = format_device_ua("Xiaomi", "MI9", "10");
        assert_eq!(ua, "Xiaomi-MI9__weibo__11.6.3__android__android10");
    }

    #[test]
    fn test_format_user_agent_clean() {
        let ua = format_user_agent("MI9", "10");
        assert_eq!(ua, "MI9_10_weibo_11.6.3_android");
    }

    #[test]
    fn test_sanitize_header_value() {
        let dirty = "MI9_小米_10\u{0001}test";
        let clean = sanitize_header_value(dirty);
        assert_eq!(clean, "MI9_??_10?test");
    }

    #[test]
    fn test_resolve_old_wm() {
        assert_eq!(resolve_old_wm("OnePlus"), "14038_0004");
        assert_eq!(resolve_old_wm("oneplus"), "14038_0004");
        assert_eq!(resolve_old_wm("Xiaomi"), "20005_0002");
        assert_eq!(resolve_old_wm("Huawei"), "3333_1001");
    }

    #[test]
    fn test_build_common_params() {
        let ctx = DeviceContext::default();
        let params = ctx.build_common_params();
        assert_eq!(params.get("c").unwrap(), "android");
        assert_eq!(params.get("from").unwrap(), "10B6395010");
        assert_eq!(params.get("oldwm").unwrap(), "20005_0002");
        assert_eq!(params.get("wb_version").unwrap(), "5005");
    }
}
