//! Weibo Mid <-> ID Base62 bidirectional conversion algorithm.
//!
//! 1:1 reproduction of `defpackage.PB.O000000o` (id_to_mid) and
//! `defpackage.PB.O00000Oo` (mid_to_id).
//!
//! Weibo IDs are 64-bit integer strings (e.g. 16 digits like "4629471928471928").
//! In URLs and APIs, they are encoded into 62-base strings (e.g. "KcmHmzxW0")
//! by chunking into 7-digit slices from the right, converting each slice to Base62,
//! and padding with '0' to 4 chars (except the leftmost slice).

pub const BASE62_ALPHABET: &[u8; 62] =
    b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// Converts a numeric Weibo status ID (e.g. "4629471928471928") to a Base62 MID string (e.g. "KcmHmzxW0").
///
/// Returns an empty string if `id_str` is empty or invalid.
pub fn id_to_mid(id_str: &str) -> String {
    let trimmed = id_str.trim();
    if trimmed.is_empty() || !trimmed.chars().all(|c| c.is_ascii_digit()) {
        return String::new();
    }

    let mut result = String::new();
    let mut len = trimmed.len() as isize - 7;
    let mut step = 1;

    while len > -7 {
        let start = if len < 0 { 0 } else { len as usize };
        let chunk_len = if len < 0 {
            trimmed.len() % 7
        } else {
            7
        };
        let slice = &trimmed[start..start + chunk_len];
        if slice.is_empty() {
            break;
        }

        let mut val: u64 = slice.parse().unwrap_or(0);
        let mut sub = String::new();

        while val != 0 {
            let rem = (val % 62) as usize;
            sub.insert(0, BASE62_ALPHABET[rem] as char);
            val /= 62;
        }

        // As in PB.java: if step != 3 (not the 3rd chunk), pad to 4 characters with '0'
        if step != 3 {
            while sub.len() < 4 {
                sub.insert(0, '0');
            }
        }

        result = format!("{}{}", sub, result);
        step += 1;
        len -= 7;
    }

    result
}

/// Converts a Base62 Weibo MID string (e.g. "KcmHmzxW0") to a numeric ID string (e.g. "4629471928471928").
///
/// Returns an empty string if `mid_str` is empty or contains characters not in the Base62 alphabet.
pub fn mid_to_id(mid_str: &str) -> String {
    let trimmed = mid_str.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    // Validate that all characters exist in the Base62 alphabet
    for byte in trimmed.bytes() {
        if !BASE62_ALPHABET.contains(&byte) {
            return String::new();
        }
    }

    let mut result = String::new();
    let mut len = trimmed.len() as isize;

    loop {
        len -= 4;
        if len <= -4 {
            return result;
        }

        let start = if len < 0 { 0 } else { len as usize };
        let chunk_len = if len < 0 {
            trimmed.len() % 4
        } else {
            4
        };
        let slice = &trimmed[start..start + chunk_len];

        let mut val: u64 = 0;
        for (idx, ch) in slice.chars().enumerate() {
            let power = 62u64.pow((slice.len() - idx - 1) as u32);
            let pos = BASE62_ALPHABET
                .iter()
                .position(|&c| c == ch as u8)
                .unwrap_or(0) as u64;
            val += power * pos;
        }

        let mut val_str = val.to_string();
        if start > 0 {
            while val_str.len() < 7 {
                val_str.insert(0, '0');
            }
        }

        result = format!("{}{}", val_str, result);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_id_to_mid_and_back() {
        let test_cases = vec![
            ("4629471928471928", "KcmHmzxW0"),
            ("4437812984920401", "IfRGGkE1j"),
            ("4500000000000000", "J00000000"),
            ("3333333333333333", "xdZ9rdZ9r"),
        ];

        for (id, mid) in test_cases {
            assert_eq!(id_to_mid(id), mid, "Failed id_to_mid for id={}", id);
            assert_eq!(mid_to_id(mid), id, "Failed mid_to_id for mid={}", mid);
        }

        // Test arbitrary valid 16-digit IDs roundtrip
        for sample_id in &["4712345678901234", "5019283746501928", "4999999999999999"] {
            let mid = id_to_mid(sample_id);
            assert_eq!(&mid_to_id(&mid), sample_id);
        }
    }

    #[test]
    fn test_edge_cases() {
        // Empty inputs
        assert_eq!(id_to_mid(""), "");
        assert_eq!(mid_to_id(""), "");

        // Whitespace handling
        assert_eq!(id_to_mid("  4629471928471928  "), "KcmHmzxW0");
        assert_eq!(mid_to_id("  KcmHmzxW0  "), "4629471928471928");

        // Invalid characters
        assert_eq!(id_to_mid("abc462947"), "");
        assert_eq!(mid_to_id("KcmHmzxW0!@#"), "");
    }
}
