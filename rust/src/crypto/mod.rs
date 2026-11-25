//! Crypto and Security Subsystem for Share Weibo.
//!
//! Provides Base62 mid/id conversion, RSA PKCS1Padding encryption,
//! Weibo API parameter signing (calculate_s), SHA-512 security token calculation,
//! device fingerprint derivation, and User-Agent formatting.

pub mod base62;
pub mod des;
pub mod rsa;
pub mod sign;
pub mod ua;
pub mod wbutil;

pub use base62::{id_to_mid, mid_to_id};
pub use des::des_ecb_encrypt_block;
pub use rsa::{encrypt_password, encrypt_with_pubkey, SHARE_DEFAULT_PUBKEY_B64, WEIBO_AID_PUBKEY_B64};
pub use sign::{
    calculate_s, calculate_s_share, calculate_s_weico, deobfuscate_str, derive_device_aid,
    to_security_value, DEFAULT_FROM, DEFAULT_WB_VERSION, DEFAULT_WM, SHARE_APP_KEY,
    SHARE_APP_SECRET, WEICO_APP_KEY, WEICO_APP_SECRET,
};
pub use ua::{
    format_device_ua, format_user_agent, resolve_old_wm, sanitize_header_value, DeviceContext,
};
pub use wbutil::{
    build_guest_mfp, cum_getparam, guest_checktoken, new_calculate_s, SPOOF_APP_KEY,
    SPOOF_KEY_HASH, SPOOF_PACKAGE, WB_FROM, WB_PIN,
};
