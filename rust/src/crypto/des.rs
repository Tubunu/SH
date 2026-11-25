//! Pure-Rust FIPS 46-3 Data Encryption Standard (DES-ECB 64-bit block cipher).
//!
//! Ignores weak keys and parity bits to match `mbedtls_des_setkey_enc` used inside
//! Share's native `libwbutil.so` (`_getparam` / `cum` computation).

#[rustfmt::skip]
const IP: [u8; 64] = [
    58, 50, 42, 34, 26, 18, 10,  2,
    60, 52, 44, 36, 28, 20, 12,  4,
    62, 54, 46, 38, 30, 22, 14,  6,
    64, 56, 48, 40, 32, 24, 16,  8,
    57, 49, 41, 33, 25, 17,  9,  1,
    59, 51, 43, 35, 27, 19, 11,  3,
    61, 53, 45, 37, 29, 21, 13,  5,
    63, 55, 47, 39, 31, 23, 15,  7,
];

#[rustfmt::skip]
const FP: [u8; 64] = [
    40,  8, 48, 16, 56, 24, 64, 32,
    39,  7, 47, 15, 55, 23, 63, 31,
    38,  6, 46, 14, 54, 22, 62, 30,
    37,  5, 45, 13, 53, 21, 61, 29,
    36,  4, 44, 12, 52, 20, 60, 28,
    35,  3, 43, 11, 51, 19, 59, 27,
    34,  2, 42, 10, 50, 18, 58, 26,
    33,  1, 41,  9, 49, 17, 57, 25,
];

#[rustfmt::skip]
const E: [u8; 48] = [
    32,  1,  2,  3,  4,  5,
     4,  5,  6,  7,  8,  9,
     8,  9, 10, 11, 12, 13,
    12, 13, 14, 15, 16, 17,
    16, 17, 18, 19, 20, 21,
    20, 21, 22, 23, 24, 25,
    24, 25, 26, 27, 28, 29,
    28, 29, 30, 31, 32,  1,
];

#[rustfmt::skip]
const P: [u8; 32] = [
    16,  7, 20, 21, 29, 12, 28, 17,
     1, 15, 23, 26,  5, 18, 31, 10,
     2,  8, 24, 14, 32, 27,  3,  9,
    19, 13, 30,  6, 22, 11,  4, 25,
];

#[rustfmt::skip]
const PC1: [u8; 56] = [
    57, 49, 41, 33, 25, 17,  9,
     1, 58, 50, 42, 34, 26, 18,
    10,  2, 59, 51, 43, 35, 27,
    19, 11,  3, 60, 52, 44, 36,
    63, 55, 47, 39, 31, 23, 15,
     7, 62, 54, 46, 38, 30, 22,
    14,  6, 61, 53, 45, 37, 29,
    21, 13,  5, 28, 20, 12,  4,
];

#[rustfmt::skip]
const PC2: [u8; 48] = [
    14, 17, 11, 24,  1,  5,
     3, 28, 15,  6, 21, 10,
    23, 19, 12,  4, 26,  8,
    16,  7, 27, 20, 13,  2,
    41, 52, 31, 37, 47, 55,
    30, 40, 51, 45, 33, 48,
    44, 49, 39, 56, 34, 53,
    46, 42, 50, 36, 29, 32,
];

const SHIFTS: [u8; 16] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];

#[rustfmt::skip]
const SBOX: [[u8; 64]; 8] = [
    [
        14,  4, 13,  1,  2, 15, 11,  8,  3, 10,  6, 12,  5,  9,  0,  7,
         0, 15,  7,  4, 14,  2, 13,  1, 10,  6, 12, 11,  9,  5,  3,  8,
         4,  1, 14,  8, 13,  6,  2, 11, 15, 12,  9,  7,  3, 10,  5,  0,
        15, 12,  8,  2,  4,  9,  1,  7,  5, 11,  3, 14, 10,  0,  6, 13,
    ],
    [
        15,  1,  8, 14,  6, 11,  3,  4,  9,  7,  2, 13, 12,  0,  5, 10,
         3, 13,  4,  7, 15,  2,  8, 14, 12,  0,  1, 10,  6,  9, 11,  5,
         0, 14,  7, 11, 10,  4, 13,  1,  5,  8, 12,  6,  9,  3,  2, 15,
        13,  8, 10,  1,  3, 15,  4,  2, 11,  6,  7, 12,  0,  5, 14,  9,
    ],
    [
        10,  0,  9, 14,  6,  3, 15,  5,  1, 13, 12,  7, 11,  4,  2,  8,
        13,  7,  0,  9,  3,  4,  6, 10,  2,  8,  5, 14, 12, 11, 15,  1,
        13,  6,  4,  9,  8, 15,  3,  0, 11,  1,  2, 12,  5, 10, 14,  7,
         1, 10, 13,  0,  6,  9,  8,  7,  4, 15, 14,  3, 11,  5,  2, 12,
    ],
    [
         7, 13, 14,  3,  0,  6,  9, 10,  1,  2,  8,  5, 11, 12,  4, 15,
        13,  8, 11,  5,  6, 15,  0,  3,  4,  7,  2, 12,  1, 10, 14,  9,
        10,  6,  9,  0, 12, 11,  7, 13, 15,  1,  3, 14,  5,  2,  8,  4,
         3, 15,  0,  6, 10,  1, 13,  8,  9,  4,  5, 11, 12,  7,  2, 14,
    ],
    [
         2, 12,  4,  1,  7, 10, 11,  6,  8,  5,  3, 15, 13,  0, 14,  9,
        14, 11,  2, 12,  4,  7, 13,  1,  5,  0, 15, 10,  3,  9,  8,  6,
         4,  2,  1, 11, 10, 13,  7,  8, 15,  9, 12,  5,  6,  3,  0, 14,
        11,  8, 12,  7,  1, 14,  2, 13,  6, 15,  0,  9, 10,  4,  5,  3,
    ],
    [
        12,  1, 10, 15,  9,  2,  6,  8,  0, 13,  3,  4, 14,  7,  5, 11,
        10, 15,  4,  2,  7, 12,  9,  5,  6,  1, 13, 14,  0, 11,  3,  8,
         9, 14, 15,  5,  2,  8, 12,  3,  7,  0,  4, 10,  1, 13, 11,  6,
         4,  3,  2, 12,  9,  5, 15, 10, 11, 14,  1,  7,  6,  0,  8, 13,
    ],
    [
         4, 11,  2, 14, 15,  0,  8, 13,  3, 12,  9,  7,  5, 10,  6,  1,
        13,  0, 11,  7,  4,  9,  1, 10, 14,  3,  5, 12,  2, 15,  8,  6,
         1,  4, 11, 13, 12,  3,  7, 14, 10, 15,  6,  8,  0,  5,  9,  2,
         6, 11, 13,  8,  1,  4, 10,  7,  9,  5,  0, 15, 14,  2,  3, 12,
    ],
    [
        13,  2,  8,  4,  6, 15, 11,  1, 10,  9,  3, 14,  5,  0, 12,  7,
         1, 15, 13,  8, 10,  3,  7,  4, 12,  5,  6, 11,  0, 14,  9,  2,
         7, 11,  4,  1,  9, 12, 14,  2,  0,  6, 10, 13, 15,  3,  5,  8,
         2,  1, 14,  7,  4, 10,  8, 13, 15, 12,  9,  0,  3,  5,  6, 11,
    ],
];

fn permute_u64(val: u64, table: &[u8], in_bits: u8) -> u64 {
    let mut out = 0u64;
    for &pos in table {
        let shift = in_bits - pos;
        out = (out << 1) | ((val >> shift) & 1);
    }
    out
}

fn key_schedule(key: &[u8; 8]) -> [u64; 16] {
    let k64 = u64::from_be_bytes(*key);
    let k56 = permute_u64(k64, &PC1, 64);
    let mut c = ((k56 >> 28) & 0x0FFF_FFFF) as u32;
    let mut d = (k56 & 0x0FFF_FFFF) as u32;

    let mut subkeys = [0u64; 16];
    for i in 0..16 {
        let sh = SHIFTS[i] as u32;
        c = ((c << sh) | (c >> (28 - sh))) & 0x0FFF_FFFF;
        d = ((d << sh) | (d >> (28 - sh))) & 0x0FFF_FFFF;
        let cd = ((c as u64) << 28) | (d as u64);
        subkeys[i] = permute_u64(cd, &PC2, 56);
    }
    subkeys
}

fn feistel(r: u32, subkey: u64) -> u32 {
    let expanded = permute_u64(r as u64, &E, 32) ^ subkey;
    let mut s_out = 0u32;
    for box_idx in 0..8 {
        let chunk = ((expanded >> (42 - box_idx * 6)) & 0x3F) as u8;
        let row = ((chunk & 0x20) >> 4) | (chunk & 0x01);
        let col = (chunk >> 1) & 0x0F;
        let val = SBOX[box_idx][(row as usize) * 16 + (col as usize)];
        s_out = (s_out << 4) | (val as u32);
    }
    permute_u64(s_out as u64, &P, 32) as u32
}

/// Encrypts a single 8-byte block using DES-ECB without weak-key rejection.
pub fn des_ecb_encrypt_block(key: &[u8; 8], block: &[u8; 8]) -> [u8; 8] {
    let subkeys = key_schedule(key);
    let input = u64::from_be_bytes(*block);
    let ip = permute_u64(input, &IP, 64);

    let mut l = (ip >> 32) as u32;
    let mut r = (ip & 0xFFFF_FFFF) as u32;

    for &sk in &subkeys {
        let next_r = l ^ feistel(r, sk);
        l = r;
        r = next_r;
    }

    // Final swap R16 || L16 before FP
    let pre_fp = ((r as u64) << 32) | (l as u64);
    permute_u64(pre_fp, &FP, 64).to_be_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_des_vectors_match_pycryptodome() {
        let cases = [
            (
                "0123456789ABCDEF",
                "0123456789ABCDEF",
                "56CC09E7CFDC4CEF",
            ),
            (
                "0000000000000000",
                "0000000000000000",
                "8CA64DE9C1B123A7",
            ),
            (
                "133457799BBCDFF1",
                "0123456789ABCDEF",
                "85E813540F0AB405",
            ),
            (
                "38627974656B6579",
                "73686F7274202F32",
                "556E348D658D2428",
            ),
        ];
        for (k_hex, p_hex, expected) in cases {
            let k: [u8; 8] = hex::decode(k_hex).unwrap().try_into().unwrap();
            let p: [u8; 8] = hex::decode(p_hex).unwrap().try_into().unwrap();
            let ct = des_ecb_encrypt_block(&k, &p);
            assert_eq!(hex::encode_upper(ct), expected);
        }
    }
}
