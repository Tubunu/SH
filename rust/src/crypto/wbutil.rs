//! Exact 1:1 Rust port of `libwbutil.so` (`newCalculateS`, `_getparam` / `cum`)
//! and `OP.java` (`/2/guest/login` `checktoken` & `mfp`).
//!
//! Verified against `Share.apk` (v3.9.6 Build 925) arm64-v8a disassembly and live
//! 2026 responses from `https://api.weibo.cn/2/*`.

use md5::{Digest as Md5Digest, Md5};
use sha2::{Sha256, Sha512};

use super::des::des_ecb_encrypt_block;
use super::rsa::{encrypt_with_pubkey, WEIBO_AID_PUBKEY_B64};

/// Decrypted `g_pin` from `libwbutil.so` (`0xd2b8` DES-ECB with `"704e6c1b"`).
pub const WB_PIN: &str = "5l0WXnhiY4pJ794KIJ7Rw5F45VXg9sjo";

/// Official Share client `from` value (`NB.O00000o0`).
pub const WB_FROM: &str = "10B6395010";

/// Official Weibo Android `com.sina.weibo` credentials spoofed by Share.
pub const SPOOF_APP_KEY: &str = "7501641714";
pub const SPOOF_PACKAGE: &str = "com.sina.weibo";
pub const SPOOF_KEY_HASH: &str = "18da2bf10352443a00a5e046d9fca6bd";

/// Computes `WeiboApplication.newCalculateS(uid)` (`libwbutil.so` @ `0x5850`/`0x9010`).
///
/// Steps:
/// 1. `s1 = lowercase_hex(SHA512(WB_PIN + uid + WB_FROM))`
/// 2. `s2 = lowercase_hex(SHA512(WB_FROM))`
/// 3. `pos = 0`; 8 times: `pos += hex_val(s2[pos])`, pick `s1[pos]`.
pub fn new_calculate_s(uid: &str) -> String {
    let mut h1 = Sha512::new();
    h1.update(WB_PIN.as_bytes());
    h1.update(uid.as_bytes());
    h1.update(WB_FROM.as_bytes());
    let s1 = hex::encode(h1.finalize());

    let mut h2 = Sha512::new();
    h2.update(WB_FROM.as_bytes());
    let s2 = hex::encode(h2.finalize());

    let s1_bytes = s1.as_bytes();
    let s2_bytes = s2.as_bytes();
    let mut pos: usize = 0;
    let mut out = String::with_capacity(8);

    for _ in 0..8 {
        let nibble = (s2_bytes[pos] as char).to_digit(16).unwrap_or(0) as usize;
        pos += nibble;
        out.push(s1_bytes[pos] as char);
    }

    out
}

/// Computes `_getparam(url_suffix)` -> `cum` parameter (`libwbutil.so`).
///
/// `url_suffix` starts with `/2/...` including sorted/encoded query string BEFORE `&cum=...`.
pub fn cum_getparam(url_suffix: &str) -> String {
    let b = url_suffix.as_bytes();
    let d1: [u8; 32] = Sha256::digest(b).into();

    let start = (8 - (d1[0] & 7)) as usize; // 1..=8
    let mut key = [0u8; 8];
    let slice = if start < b.len() {
        let end = (start + 8).min(b.len());
        &b[start..end]
    } else {
        &[][..]
    };
    let take = slice.len();
    key[..take].copy_from_slice(slice);
    if take < 8 {
        let pad_byte = (8 - take) as u8;
        for slot in &mut key[take..8] {
            *slot = pad_byte;
        }
    }

    // cpdata = b[-4:] || b[:4]
    let mut cpdata = [0u8; 8];
    if b.len() >= 4 {
        cpdata[..4].copy_from_slice(&b[b.len() - 4..]);
        cpdata[4..].copy_from_slice(&b[..4]);
    } else if !b.is_empty() {
        for (i, slot) in cpdata.iter_mut().enumerate() {
            *slot = b[i % b.len()];
        }
    }

    let des_out = des_ecb_encrypt_block(&key, &cpdata);

    let mut h2 = Sha256::new();
    h2.update(d1);
    h2.update(des_out);
    let d2_hex = hex::encode_upper(h2.finalize());

    d2_hex[start..start + 8].to_string()
}

/// Computes `checktoken` for `/2/guest/login` (`OP.java`): `md5("/" + did + "/obiew")`.
pub fn guest_checktoken(did: &str) -> String {
    let mut m = Md5::new();
    m.update(format!("/{did}/obiew").as_bytes());
    hex::encode(m.finalize())
}

/// Computes `mfp` for `/2/guest/login` (`OP.java`): `"01" + base64(RSA(mfp_json))`.
pub fn build_guest_mfp(manufacturer: &str, model: &str, os_release: &str) -> Result<String, String> {
    let payload = serde_json::json!({
        "os": "1",
        "osver": os_release,
        "man": manufacturer,
        "model": model,
        "res": "1080*2400",
    })
    .to_string();
    let enc = encrypt_with_pubkey(payload.as_bytes(), WEIBO_AID_PUBKEY_B64)?;
    Ok(format!("01{enc}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_calculate_s_matches_disassembly() {
        assert_eq!(new_calculate_s(""), "2bfa3d98");
        assert_eq!(new_calculate_s("2803301701"), "3f802f19");
        assert_eq!(new_calculate_s("1234567890"), "ca903adb");
    }

    #[test]
    fn test_cum_getparam_matches_pycryptodome() {
        assert_eq!(
            cum_getparam("/2/guest/login?from=10B6395010&wm=2468_1001&c=android&v_p=89&lang=zh_CN"),
            "8017F55F"
        );
        assert_eq!(
            cum_getparam("/2/statuses/unread_hot_timeline"),
            "659FF800"
        );
        assert_eq!(cum_getparam("/2/profile?uid=2803301701"), "39D2CEE5");
        assert_eq!(cum_getparam("/2/a"), "85D7AD68");
    }

    #[test]
    fn test_guest_mfp_and_checktoken() {
        let did = hex::encode(Md5::digest(b"share-flutter-rust-test-device-001"));
        assert_eq!(did.len(), 32);
        let chk = guest_checktoken(&did);
        assert_eq!(chk.len(), 32);
        let mfp = build_guest_mfp("Xiaomi", "MIX 4", "11").unwrap();
        assert!(mfp.starts_with("01"));
        assert!(mfp.len() > 170);
    }
}
