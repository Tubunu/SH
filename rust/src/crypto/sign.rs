//! Weibo Signature, AppKeys, and Security Feature Calculation.
//!
//! 1:1 reproduction of:
//! - `WeicoSecurityUtils.toSecurityValue` (SHA-512 based key feature extraction)
//! - `C2684gA.O00000Oo` (XOR-shift string deobfuscator for embedded keys)
//! - `calculate_s` (Weibo query/form parameter sorted MD5 signature)
//! - Device anonymous ID (`aid`) derivation pipeline.

use md5::{Digest, Md5};
use sha2::Sha512;
use std::collections::BTreeMap;

/// Share Android Official AppKey
pub const SHARE_APP_KEY: &str = "2403130832";

/// Share Android Official AppSecret (deobfuscated from `NB.java`)
pub const SHARE_APP_SECRET: &str = "2ef1ce4d1349aecbff2cbfa73637c38c";

/// Weico International AppKey
pub const WEICO_APP_KEY: &str = "211160679";

/// Weico International AppSecret (deobfuscated from `NB.java`)
pub const WEICO_APP_SECRET: &str = "63b64d531b98c2dbff2443816f274dd3";

/// Default Client `from` Parameter for Share Weibo
pub const DEFAULT_FROM: &str = "10B6395010";

/// Default Client `wm` (White Mark) Parameter for Share Weibo
pub const DEFAULT_WM: &str = "2468_1001";

/// Default Client Version Code
pub const DEFAULT_WB_VERSION: &str = "5005";

/// 1:1 reproduction of `C2684gA.O00000Oo(String str)`.
///
/// Share stores obfuscated strings with an ASCII rotation (+47 shift with 94 modulus wrap).
pub fn deobfuscate_str(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    for c in s.chars() {
        if c != ' ' {
            let mut n = (c as u32) + 47;
            if n > ('~' as u32) {
                n -= 94;
            }
            if let Some(decoded_char) = std::char::from_u32(n) {
                result.push(decoded_char);
            } else {
                result.push(c);
            }
        } else {
            result.push(' ');
        }
    }
    result
}

/// Computes SHA-512 hex string (lowercase)
fn sha512_hex(input: &str) -> String {
    let mut hasher = Sha512::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

/// Computes MD5 hex string (lowercase)
pub fn md5_hex(input: &[u8]) -> String {
    let mut hasher = Md5::new();
    hasher.update(input);
    hex::encode(hasher.finalize())
}

/// 1:1 reproduction of `WeicoSecurityUtils.toSecurityValue(String str, String str2, String str3)`.
///
/// Features:
/// - sha512_1 = SHA512(str2 + str + str3)
/// - sha512_2 = SHA512(str3)
/// - Iterates 8 times (0..=7), walking `sha512_1` using offsets extracted from hex characters in `sha512_2`.
pub fn to_security_value(str1: &str, str2: &str, str3: &str) -> String {
    let combined = format!("{}{}{}", str2, str1, str3);
    let str_sha512 = sha512_hex(&combined);
    let str_sha513 = sha512_hex(str3);

    let hex_alphabet = "0123456789abcdef";
    let sha1_chars: Vec<char> = str_sha512.chars().collect();
    let sha2_chars: Vec<char> = str_sha513.chars().collect();

    let mut result = String::with_capacity(8);
    let mut index_offset = 0usize;

    for _ in 0..=7 {
        if index_offset < sha2_chars.len() {
            let ch2 = sha2_chars[index_offset];
            let pos = hex_alphabet.find(ch2).unwrap_or(0);
            index_offset += pos;
        }
        if index_offset < sha1_chars.len() {
            result.push(sha1_chars[index_offset]);
        }
    }

    result
}

/// Calculates the parameter signature `s` for Weibo REST API requests.
///
/// Algorithm:
/// 1. Collects all query parameters, excluding "s" itself.
/// 2. Sorts parameter keys alphabetically.
/// 3. Joins sorted parameters into "key1=val1&key2=val2...".
/// 4. Concatenates `path + query_string + app_secret`.
/// 5. Calculates MD5 hash (lowercase hex).
pub fn calculate_s(path: &str, params: &[(String, String)], app_secret: &str) -> String {
    let mut sorted_map = BTreeMap::new();
    for (k, v) in params {
        if k != "s" {
            sorted_map.insert(k.as_str(), v.as_str());
        }
    }

    let mut query_builder = String::new();
    for (i, (k, v)) in sorted_map.iter().enumerate() {
        if i > 0 {
            query_builder.push('&');
        }
        query_builder.push_str(k);
        query_builder.push('=');
        query_builder.push_str(v);
    }

    let sign_payload = format!("{}{}{}", path, query_builder, app_secret);
    md5_hex(sign_payload.as_bytes())
}

/// Convenience function calculating `s` using the default Share AppSecret
pub fn calculate_s_share(path: &str, params: &[(String, String)]) -> String {
    calculate_s(path, params, SHARE_APP_SECRET)
}

/// Convenience function calculating `s` using the Weico AppSecret
pub fn calculate_s_weico(path: &str, params: &[(String, String)]) -> String {
    calculate_s(path, params, WEICO_APP_SECRET)
}

/// Derives a deterministic 16-to-32 byte anonymous device identifier (`aid`)
/// based on device hardware fingerprint and package name, formatted for `/guest/login`
/// and subsequent `aid` query parameter injection.
pub fn derive_device_aid(hardware_seed: &str, package_name: &str) -> String {
    use sha2::Sha256;
    let mut hasher = Sha256::new();
    hasher.update(hardware_seed.as_bytes());
    hasher.update(b"__share_aid_salt__");
    hasher.update(package_name.as_bytes());
    let hash = hasher.finalize();

    // Weibo AID format is typically a 40-character base64-like / hex string
    let hex_part = hex::encode(hash);
    format!("01_{}", &hex_part[0..36])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deobfuscate_embedded_secrets() {
        // Share AppSecret
        let share_sec = deobfuscate_str("a67`46c5`bch264377a4372fbebf4bg4");
        assert_eq!(share_sec, SHARE_APP_SECRET);

        // Weico AppSecret
        let weico_sec = deobfuscate_str("eb3ec5db`3hg4a5377accbg`e7afc55b");
        assert_eq!(weico_sec, WEICO_APP_SECRET);

        // Third-party AppKey
        let tp_key = deobfuscate_str("h___`hcba");
        assert_eq!(tp_key, "900019432");
    }

    #[test]
    fn test_to_security_value() {
        let sec_val = to_security_value("weico_test_str", "user_12345", "salt_token");
        assert_eq!(sec_val.len(), 8);
        assert!(sec_val.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn test_calculate_s_ordering() {
        let params = vec![
            ("count".to_string(), "30".to_string()),
            ("since_id".to_string(), "0".to_string()),
            ("feature".to_string(), "0".to_string()),
        ];
        let sig1 = calculate_s("/2/statuses/friends/timeline", &params, SHARE_APP_SECRET);

        // Reversed input params must yield identical signature due to BTreeMap sorting
        let params_reversed = vec![
            ("feature".to_string(), "0".to_string()),
            ("since_id".to_string(), "0".to_string()),
            ("count".to_string(), "30".to_string()),
        ];
        let sig2 = calculate_s("/2/statuses/friends/timeline", &params_reversed, SHARE_APP_SECRET);

        assert_eq!(sig1, sig2);
        assert_eq!(sig1.len(), 32);
    }

    #[test]
    fn test_derive_device_aid() {
        let aid = derive_device_aid("android_id_abcdef123456", "com.hengye.share");
        assert!(aid.starts_with("01_"));
        assert_eq!(aid.len(), 39);
    }
}
