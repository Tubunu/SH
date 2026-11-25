//! High-level Crypto and Security APIs exposed to Flutter and FFI bindings.

use crate::crypto;

pub fn id_to_mid(id_str: &str) -> String {
    crypto::id_to_mid(id_str)
}

pub fn mid_to_id(mid_str: &str) -> String {
    crypto::mid_to_id(mid_str)
}

pub fn encrypt_password(password: &str) -> Result<String, String> {
    crypto::encrypt_password(password)
}

pub fn encrypt_with_pubkey(data: &[u8], pubkey_b64: &str) -> Result<String, String> {
    crypto::encrypt_with_pubkey(data, pubkey_b64)
}

pub fn calculate_s(
    path: &str,
    params: Vec<(String, String)>,
    app_secret: Option<String>,
) -> String {
    let secret = app_secret.unwrap_or_else(|| crypto::SHARE_APP_SECRET.to_string());
    crypto::calculate_s(path, &params, &secret)
}

pub fn to_security_value(str1: &str, str2: &str, str3: &str) -> String {
    crypto::to_security_value(str1, str2, str3)
}

pub fn derive_device_aid(hardware_seed: &str, package_name: &str) -> String {
    crypto::derive_device_aid(hardware_seed, package_name)
}

pub fn format_user_agent(model: &str, os_release: &str) -> String {
    crypto::format_user_agent(model, os_release)
}

pub fn format_device_ua(manufacturer: &str, model: &str, os_release: &str) -> String {
    crypto::format_device_ua(manufacturer, model, os_release)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_crypto_api_wrappers() {
        assert_eq!(id_to_mid("4629471928471928"), "KcmHmzxW0");
        assert_eq!(mid_to_id("KcmHmzxW0"), "4629471928471928");
        assert!(encrypt_password("test_pwd").is_ok());
    }
}
