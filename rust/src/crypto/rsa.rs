//! RSA Encryption Engine for Share Weibo.
//!
//! 1:1 reproduction of `SAUtils.securityPsd`, `SAUtils.secP`, and `SAUtils.encryptByPublicKey`.
//! Extracted from `libSecShare.so` and original DEX bytecode.
//!
//! Algorithm: RSA/ECB/PKCS1Padding, chunked encryption (max 117 bytes per block).
//! Outputs standard Base64 string without line breaks.

use base64::Engine;
use rsa::pkcs8::DecodePublicKey;
use rsa::{Pkcs1v15Encrypt, RsaPublicKey};

/// Default RSA Public Key extracted from `libSecShare.so` (1024-bit X.509 SubjectPublicKeyInfo)
pub const SHARE_DEFAULT_PUBKEY_B64: &str =
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC46y69c1rmEk6btBLCPgxJkCxdDcAH9k7kBLffgG1KWqUErjdv+aMkEZmBaprEW846YEwBn60gyBih3KU518fL3F+sv2b6xEeOxgjWO+NPgSWmT3q1up95HmmLHlgVwqTKqRUHd8+Tr43D5h+J8T69etX0YNdT5ACvm+Ar0HdarwIDAQAB";

/// Weibo Device Aid Task RSA Public Key extracted from `OP.java`
pub const WEIBO_AID_PUBKEY_B64: &str =
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHHM0Fi2Z6+QYKXqFUX2Cy6AaWq3cPi+GSn9oeAwQbPZR75JB7Netm0HtBVVbtPhzT7UO2p1JhFUKWqrqoYuAjkgMVPmA0sFrQohns5EE44Y86XQopD4ZO+dE5KjUZFE6vrPO3rWW3np2BqlgKpjnYZri6TJApmIpGcQg9/G/3zQIDAQAB";

/// Maximum plain text block size for RSA-1024 with PKCS1Padding (128 - 11 = 117 bytes)
pub const MAX_ENCRYPT_BLOCK: usize = 117;

/// Encrypts user password using Share's default public key.
/// Equivalent to `SAUtils.securityPsd(password, pubKey)`.
pub fn encrypt_password(password: &str) -> Result<String, String> {
    if password.trim().is_empty() {
        return Ok(String::new());
    }
    encrypt_with_pubkey(password.as_bytes(), SHARE_DEFAULT_PUBKEY_B64)
}

/// Encrypts arbitrary byte payload with given Base64 encoded X.509 RSA public key.
/// Performs chunked encryption with `MAX_ENCRYPT_BLOCK = 117` bytes and concatenates
/// the resulting ciphertext blocks before Base64 encoding.
pub fn encrypt_with_pubkey(data: &[u8], pubkey_b64: &str) -> Result<String, String> {
    if data.is_empty() {
        return Ok(String::new());
    }

    let der = base64::engine::general_purpose::STANDARD
        .decode(pubkey_b64.trim())
        .map_err(|e| format!("Invalid Base64 public key: {e}"))?;

    let pub_key = RsaPublicKey::from_public_key_der(&der)
        .map_err(|e| format!("Failed to parse RSA X.509 public key: {e}"))?;

    let mut rng = rand::thread_rng();
    let mut encrypted_bytes = Vec::new();

    for chunk in data.chunks(MAX_ENCRYPT_BLOCK) {
        let enc = pub_key
            .encrypt(&mut rng, Pkcs1v15Encrypt, chunk)
            .map_err(|e| format!("RSA PKCS1v15 encryption failed: {e}"))?;
        encrypted_bytes.extend_from_slice(&enc);
    }

    Ok(base64::engine::general_purpose::STANDARD.encode(&encrypted_bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_password_empty() {
        let res = encrypt_password("").unwrap();
        assert!(res.is_empty());
    }

    #[test]
    fn test_encrypt_password_standard() {
        let res = encrypt_password("my_super_secret_password_2026").unwrap();
        assert!(!res.is_empty());
        // 1 block of 1024 bits = 128 bytes, Base64 length is 172 chars
        assert_eq!(res.len(), 172);
    }

    #[test]
    fn test_encrypt_multi_block() {
        // Create payload larger than 117 bytes (e.g., 200 bytes)
        let large_data = vec![b'A'; 200];
        let res = encrypt_with_pubkey(&large_data, SHARE_DEFAULT_PUBKEY_B64).unwrap();
        // 2 blocks = 256 bytes, Base64 length = 344 chars
        assert_eq!(res.len(), 344);
    }

    #[test]
    fn test_aid_pubkey_valid() {
        let res = encrypt_with_pubkey(b"mfp_fingerprint_data", WEIBO_AID_PUBKEY_B64).unwrap();
        assert!(!res.is_empty());
        assert_eq!(res.len(), 172);
    }
}
