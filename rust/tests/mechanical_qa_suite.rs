use share_core::auth::account::{AccountState, AccountType, UserAccount};
use share_core::auth::session::SessionManager;
use share_core::auth::token::TokenBundle;
use share_core::crypto::base62::{id_to_mid, mid_to_id, BASE62_ALPHABET};
use share_core::crypto::rsa::{
    encrypt_password, encrypt_with_pubkey, SHARE_DEFAULT_PUBKEY_B64, WEIBO_AID_PUBKEY_B64,
};
use share_core::crypto::sign::{
    calculate_s, deobfuscate_str, md5_hex, to_security_value, SHARE_APP_SECRET,
};
use share_core::crypto::ua::{sanitize_header_value, DeviceContext};
use share_core::net::weibo_client::WeiboClient;
use share_core::parser::comment_model::{CommentListResponse, CommentModel};
use share_core::parser::status_model::{PicUrlItem, StatusModel, TimelineResponse, UserModel};
use share_core::storage::dao::draft_dao::DraftDao;
use share_core::storage::dao::history_dao::HistoryDao;
use share_core::storage::dao::share_json_dao::ShareJsonDao;
use share_core::storage::dao::user_dao::UserDao;
use share_core::storage::db::DatabaseManager;
use share_core::storage::models::*;

use std::sync::Arc;
use std::thread;

// ============================================================================
// 1. BASE62 EDGE & BOUNDARY TESTS
// ============================================================================

#[test]
fn test_base62_empty_and_whitespace() {
    assert_eq!(id_to_mid(""), "");
    assert_eq!(id_to_mid("   "), "");
    assert_eq!(mid_to_id(""), "");
    assert_eq!(mid_to_id("   "), "");
}

#[test]
fn test_base62_invalid_characters() {
    // Non-digit in ID
    assert_eq!(id_to_mid("462947192847192a"), "");
    assert_eq!(id_to_mid("462947@192847192"), "");
    assert_eq!(id_to_mid("462947 19284719"), "");
    assert_eq!(id_to_mid("462947!19284719"), "");

    // Characters outside Base62 alphabet in MID
    assert_eq!(mid_to_id("KcmHmzxW0!"), "");
    assert_eq!(mid_to_id("KcmHmzxW0@"), "");
    assert_eq!(mid_to_id("KcmHmzx W0"), "");
    assert_eq!(mid_to_id("KcmHm-zxW0"), "");
    assert_eq!(mid_to_id("KcmHm_zxW0"), "");
}

#[test]
fn test_base62_single_and_boundary_lengths() {
    // Single digit IDs
    for d in 0..=9 {
        let s = d.to_string();
        let mid = id_to_mid(&s);
        assert!(!mid.is_empty(), "id_to_mid failed for single digit {}", s);
        let back = mid_to_id(&mid);
        assert_eq!(back, s, "Roundtrip failed for single digit {}", s);
    }

    // 1-char to 4-char MIDs
    for b in BASE62_ALPHABET {
        let ch = *b as char;
        let mid_str = ch.to_string();
        let id_val = mid_to_id(&mid_str);
        assert!(!id_val.is_empty(), "mid_to_id failed for single char {}", ch);
    }
}

#[test]
fn test_base62_real_weibo_ids_roundtrip() {
    let test_ids = [
        "4629471928471928",
        "4437812984920401",
        "4500000000000000",
        "3333333333333333",
        "4712345678901234",
        "5019283746501928",
        "4999999999999999",
        "1000000000000000",
        "9999999999999999",
        "1234567",         // exactly 7 digits
        "12345678",        // 8 digits
        "12345678901234",  // 14 digits
    ];

    for id in test_ids {
        let mid = id_to_mid(id);
        assert!(!mid.is_empty(), "id_to_mid returned empty for {}", id);
        let back_id = mid_to_id(&mid);
        assert_eq!(back_id, id, "Roundtrip failed for ID {}: got {}", id, back_id);
    }
}

// ============================================================================
// 2. CRYPTOGRAPHIC ALGORITHM VERIFICATION (ZERO MOCK TOLERANCE)
// ============================================================================

#[test]
fn test_rsa_real_key_and_pkcs1_padding() {
    // Real public key encryption
    let plain = "Hello, Share Weibo RSA Encryption Engine!";
    let enc1 = encrypt_password(plain).expect("RSA encryption failed");
    let enc2 = encrypt_password(plain).expect("RSA encryption failed");

    // PKCS1v15 uses randomized padding -> ciphertexts MUST be different!
    assert_ne!(enc1, enc2, "PKCS#1 v1.5 MUST use randomized padding; ciphertexts were identical!");

    // Base64 check: 1024-bit key = 128 bytes ciphertext = 172 base64 chars
    assert_eq!(enc1.len(), 172);
    assert_eq!(enc2.len(), 172);

    // Multi-block: 250 bytes > 117 bytes max block size -> 3 blocks (117 + 117 + 16)
    let large_data = vec![b'X'; 250];
    let enc_multi = encrypt_with_pubkey(&large_data, SHARE_DEFAULT_PUBKEY_B64).unwrap();
    // 3 blocks * 128 bytes = 384 bytes -> 512 base64 chars
    assert_eq!(enc_multi.len(), 512);

    // Test Weibo AID pubkey
    let aid_enc = encrypt_with_pubkey(b"aid_fingerprint_seed", WEIBO_AID_PUBKEY_B64).unwrap();
    assert_eq!(aid_enc.len(), 172);

    // Test corrupted public key error handling
    let bad_res = encrypt_with_pubkey(b"data", "not_a_valid_base64_der_public_key!!!");
    assert!(bad_res.is_err(), "Invalid pubkey should return Err");
}

#[test]
fn test_sign_calculate_s_sorting_and_md5() {
    // Verify dictionary sorting: keys: a, b, m, z
    let params1 = vec![
        ("z_param".to_string(), "last".to_string()),
        ("a_param".to_string(), "first".to_string()),
        ("m_param".to_string(), "mid".to_string()),
        ("b_param".to_string(), "second".to_string()),
    ];

    let params2 = vec![
        ("a_param".to_string(), "first".to_string()),
        ("b_param".to_string(), "second".to_string()),
        ("m_param".to_string(), "mid".to_string()),
        ("z_param".to_string(), "last".to_string()),
    ];

    let s1 = calculate_s("/api/test", &params1, SHARE_APP_SECRET);
    let s2 = calculate_s("/api/test", &params2, SHARE_APP_SECRET);
    assert_eq!(s1, s2, "Parameter order must not affect signature result");

    // Verify 's' parameter exclusion
    let mut params_with_s = params1.clone();
    params_with_s.push(("s".to_string(), "existing_signature_to_ignore".to_string()));
    let s_with = calculate_s("/api/test", &params_with_s, SHARE_APP_SECRET);
    assert_eq!(s1, s_with, "Parameter 's' must be excluded from signature calculation");

    // Check manual MD5 calculation
    // sorted: a_param=first&b_param=second&m_param=mid&z_param=last
    let expected_payload = format!(
        "/api/testa_param=first&b_param=second&m_param=mid&z_param=last{}",
        SHARE_APP_SECRET
    );
    let expected_md5 = md5_hex(expected_payload.as_bytes());
    assert_eq!(s1, expected_md5);
}

#[test]
fn test_sign_to_security_value_and_deobfuscation() {
    let val1 = to_security_value("input_data", "salt_left", "salt_right");
    assert_eq!(val1.len(), 8);
    assert!(val1.chars().all(|c| c.is_ascii_hexdigit()));

    // Deterministic output
    let val2 = to_security_value("input_data", "salt_left", "salt_right");
    assert_eq!(val1, val2);

    // Different salts produce different results
    let val3 = to_security_value("input_data", "salt_left", "different_salt");
    assert_ne!(val1, val3);

    // Deobfuscation verification
    assert_eq!(deobfuscate_str(""), "");
    assert_eq!(deobfuscate_str("   "), "   ");
    // Roundtrip verification of known constants
    let orig = "hello_world_123";
    // Check that ASCII rotation behaves properly
    let deob = deobfuscate_str(orig);
    assert_ne!(deob, orig);
}

#[test]
fn test_device_context_and_ua_sanitization() {
    let ctx = DeviceContext {
        manufacturer: "Xiaomi".to_string(),
        model: "Mi 11 Pro".to_string(),
        os_release: "13".to_string(),
        android_id: "test_android_id_888".to_string(),
        network_type: "5g".to_string(),
        aid: "01_testaid1234567890".to_string(),
    };

    let params = ctx.build_common_params();
    assert_eq!(params.get("networktype").unwrap(), "5g");
    assert_eq!(params.get("aid").unwrap(), "01_testaid1234567890");
    assert_eq!(params.get("oldwm").unwrap(), "20005_0002");

    // Header sanitization test
    assert_eq!(sanitize_header_value("Normal-Header"), "Normal-Header");
    assert_eq!(sanitize_header_value("Header\x00With\x1fControl"), "Header?With?Control");
    // "Header中文测试" has 4 Chinese characters, each char is replaced by '?'
    assert_eq!(sanitize_header_value("Header中文测试"), "Header????");
}

// ============================================================================
// 3. SQLITE 9 CORE TABLES, CONSTRAINTS & CONCURRENCY
// ============================================================================

#[test]
fn test_sqlite_9_core_tables_and_indexes_exist() {
    let db = DatabaseManager::open_in_memory().unwrap();
    db.with_conn(|conn| {
        let expected_tables = [
            "USER",
            "STATUS_DRAFTS",
            "STATUS_HISTORY",
            "GROUP_LIST",
            "GROUP_MEMBER",
            "FOLLOWER",
            "BLACK_LIST",
            "USER_HISTORY",
            "SHARE_JSON",
        ];

        for table in expected_tables {
            let count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1;",
                    [table],
                    |r| r.get(0),
                )
                .expect("Failed to query sqlite_master for table");
            assert_eq!(count, 1, "Table '{}' does not exist in SQLite schema", table);
        }

        let expected_indexes = [
            "IDX_USER_UID",
            "IDX_STATUS_DRAFTS_UID",
            "IDX_STATUS_HISTORY_UID_CREATE",
            "IDX_GROUP_LIST_UID",
            "IDX_GROUP_MEMBER_GID",
            "IDX_FOLLOWER_UID",
            "IDX_FOLLOWER_NAME",
            "IDX_FOLLOWER_PINYIN",
            "IDX_BLACK_LIST_UID",
            "IDX_USER_HISTORY_UID",
            "IDX_USER_HISTORY_TARGET_UID",
        ];

        for idx in expected_indexes {
            let count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?1;",
                    [idx],
                    |r| r.get(0),
                )
                .expect("Failed to query sqlite_master for index");
            assert_eq!(count, 1, "Index '{}' does not exist in SQLite schema", idx);
        }

        Ok(())
    })
    .unwrap();
}

#[test]
fn test_user_table_insert_conflict_update() {
    let db = DatabaseManager::open_in_memory().unwrap();
    let dao = UserDao::new(&db);

    let user_v1 = UserEntity {
        uid: "user_test_conflict".to_string(),
        token: "initial_token_123".to_string(),
        parent_type: 0,
        name: Some("Initial Name".to_string()),
        sign: Some("Old bio".to_string()),
        ..Default::default()
    };
    dao.insert_or_replace(&user_v1).unwrap();
    assert_eq!(dao.count().unwrap(), 1);

    let fetched1 = dao.get_by_uid("user_test_conflict").unwrap().unwrap();
    assert_eq!(fetched1.name.as_deref(), Some("Initial Name"));
    assert_eq!(fetched1.token, "initial_token_123");

    // Re-insert with updated token and new name
    let user_v2 = UserEntity {
        uid: "user_test_conflict".to_string(),
        token: "updated_token_456".to_string(),
        parent_type: 0,
        name: Some("Updated Name".to_string()),
        sign: None, // COALESCE should keep "Old bio"
        ..Default::default()
    };
    dao.insert_or_replace(&user_v2).unwrap();

    // Must still have exactly 1 record (no duplicate rows)
    assert_eq!(dao.count().unwrap(), 1);
    let fetched2 = dao.get_by_uid("user_test_conflict").unwrap().unwrap();
    assert_eq!(fetched2.token, "updated_token_456");
    assert_eq!(fetched2.name.as_deref(), Some("Updated Name"));
    assert_eq!(fetched2.sign.as_deref(), Some("Old bio"));
}

#[test]
fn test_draft_dao_large_payload_and_images() {
    let db = DatabaseManager::open_in_memory().unwrap();
    let dao = DraftDao::new(&db);

    // Large draft text: 50,000 characters
    let long_text = "A".repeat(50000);
    // JSON of 18 local images
    let mut image_urls = Vec::new();
    for i in 1..=18 {
        image_urls.push(format!("/data/user/0/com.hengye.share/cache/img_{}.jpg", i));
    }
    let urls_json = serde_json::to_string(&image_urls).unwrap();

    let draft = StatusDraftEntity {
        content: long_text.clone(),
        date: 1710000000,
        urls: Some(urls_json.clone()),
        uid: "uid_large_draft".to_string(),
        target_status_json: Some("{\"text\":\"quoted tweet with large body\"}".to_string()),
        status: 0,
        ..Default::default()
    };

    let rowid = dao.insert(&draft).unwrap();
    assert!(rowid > 0);

    let fetched = dao.get_by_id(rowid).unwrap().unwrap();
    assert_eq!(fetched.content.len(), 50000);
    assert_eq!(fetched.content, long_text);
    assert_eq!(fetched.urls.as_deref(), Some(urls_json.as_str()));

    // Verify JSON deserialization of image URLs
    let parsed_urls: Vec<String> = serde_json::from_str(fetched.urls.as_deref().unwrap()).unwrap();
    assert_eq!(parsed_urls.len(), 18);
    assert_eq!(parsed_urls[17], "/data/user/0/com.hengye.share/cache/img_18.jpg");
}

#[test]
fn test_user_history_recording() {
    let db = DatabaseManager::open_in_memory().unwrap();
    let dao = HistoryDao::new(&db);

    // Attempting to record user profile visit
    let res = dao.record_user_visit(
        "uid_tester",
        "target_uid_100",
        "TargetUser100",
        Some("https://avatar.weibo.com/100.jpg"),
        Some("{\"profile\":\"data\"}"),
        1700000000,
    );

    // Let's assert if record_user_visit succeeds or fails
    match res {
        Ok(_) => {
            let list = dao.list_user_history("uid_tester", 10).unwrap();
            assert_eq!(list.len(), 1);
            assert_eq!(list[0].visit_count, 1);

            // Visit again -> visit_count should become 2
            dao.record_user_visit(
                "uid_tester",
                "target_uid_100",
                "TargetUser100_Updated",
                None,
                None,
                1700001000,
            ).unwrap();

            let list2 = dao.list_user_history("uid_tester", 10).unwrap();
            assert_eq!(list2.len(), 1);
            assert_eq!(list2[0].visit_count, 2);
            assert_eq!(list2[0].target_user_name, "TargetUser100_Updated");
        }
        Err(e) => {
            panic!("dao.record_user_visit failed: {:?}", e);
        }
    }
}

#[test]
fn test_sqlite_multithread_concurrency() {
    let db = DatabaseManager::open_in_memory().unwrap();
    let db_arc = Arc::new(db);

    let mut handles = Vec::new();

    // 10 concurrent threads inserting into SHARE_JSON and reading
    for t_idx in 0..10 {
        let db_clone = Arc::clone(&db_arc);
        let handle = thread::spawn(move || {
            let dao = ShareJsonDao::new(&db_clone);
            for i in 0..50 {
                let key = format!("thread_{}_key_{}", t_idx, i);
                let val = format!("val_{}_{}", t_idx, i);
                dao.put(&key, &val).expect("Concurrent put failed");
                let read = dao.get(&key).expect("Concurrent get failed").unwrap();
                assert_eq!(read, val);
            }
        });
        handles.push(handle);
    }

    for h in handles {
        h.join().expect("Thread panicked during concurrent DB access");
    }
}

// ============================================================================
// 4. TOKEN & SESSION STATE MACHINE TESTS
// ============================================================================

#[test]
fn test_token_expiration_and_refresh_boundaries() {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;

    // Boundary 1: Expired 1ms ago
    let t_expired = TokenBundle::new(
        "token_exp".to_string(),
        None,
        Some(now - 1),
        None,
        None,
        None,
        None,
    );
    assert!(t_expired.is_expired());
    assert!(t_expired.needs_refresh());

    // Boundary 2: Expires in 1 hour (< 2 hours buffer) -> not expired yet, but needs refresh
    let t_refresh = TokenBundle::new(
        "token_ref".to_string(),
        None,
        Some(now + 3600 * 1000),
        None,
        None,
        None,
        None,
    );
    assert!(!t_refresh.is_expired());
    assert!(t_refresh.needs_refresh());

    // Boundary 3: Expires in 5 hours (> 2 hours buffer) -> not expired, no refresh needed
    let t_fresh = TokenBundle::new(
        "token_fresh".to_string(),
        None,
        Some(now + 5 * 3600 * 1000),
        None,
        None,
        None,
        None,
    );
    assert!(!t_fresh.is_expired());
    assert!(!t_fresh.needs_refresh());

    // Boundary 4: None expiration (permanent token)
    let t_indefinite = TokenBundle::new(
        "token_perm".to_string(),
        None,
        None,
        None,
        None,
        None,
        None,
    );
    assert!(!t_indefinite.is_expired());
    assert!(!t_indefinite.needs_refresh());

    // Boundary 5: 0 expiration
    let t_zero = TokenBundle::new(
        "token_zero".to_string(),
        None,
        Some(0),
        None,
        None,
        None,
        None,
    );
    assert!(!t_zero.is_expired());
    assert!(!t_zero.needs_refresh());
}

#[test]
fn test_cookie_parsing_and_formatting() {
    let complex_cookie = "SUB=_2AkMSabc_xyz; SUBP=0033Wrxs_token; Path=/; Domain=.weibo.cn; HttpOnly; Secure";
    let bundle = TokenBundle::new(
        "tok".to_string(),
        None,
        None,
        None,
        None,
        None,
        Some(complex_cookie.to_string()),
    );

    assert_eq!(bundle.sub.as_deref(), Some("_2AkMSabc_xyz"));
    assert_eq!(bundle.subp.as_deref(), Some("0033Wrxs_token"));
    assert_eq!(
        bundle.formatted_cookie(),
        "SUB=_2AkMSabc_xyz; SUBP=0033Wrxs_token"
    );

    // Empty cookie
    let empty_bundle = TokenBundle::new(
        "tok".to_string(),
        None,
        None,
        None,
        None,
        None,
        Some("".to_string()),
    );
    assert!(empty_bundle.sub.is_none());
    assert!(empty_bundle.subp.is_none());
    assert_eq!(empty_bundle.formatted_cookie(), "");
}

#[test]
fn test_session_multi_account_lifecycle() {
    let db = DatabaseManager::open_in_memory().unwrap();
    let session = SessionManager::new(db.clone()).unwrap();

    let account_a = UserAccount {
        uid: "account_A".to_string(),
        name: "Alice".to_string(),
        avatar: None,
        gender: Some("f".to_string()),
        sign: None,
        cover: None,
        account_type: AccountType::OAuth,
        state: AccountState::Active,
        token_bundle: TokenBundle::new(
            "token_A".to_string(),
            None,
            None,
            Some("gsid_A".to_string()),
            Some("s_A".to_string()),
            None,
            None,
        ),
        raw_profile_json: None,
    };

    let account_b = UserAccount {
        uid: "account_B".to_string(),
        name: "Bob".to_string(),
        avatar: None,
        gender: Some("m".to_string()),
        sign: None,
        cover: None,
        account_type: AccountType::WebCookie,
        state: AccountState::Active,
        token_bundle: TokenBundle::new(
            "token_B".to_string(),
            None,
            None,
            Some("gsid_B".to_string()),
            Some("s_B".to_string()),
            None,
            Some("SUB=sub_B; SUBP=subp_B".to_string()),
        ),
        raw_profile_json: None,
    };

    // Activate A
    session.set_active_account(account_a).unwrap();
    assert_eq!(session.current_uid().as_deref(), Some("account_A"));
    assert_eq!(session.current_token().as_deref(), Some("token_A"));
    assert_eq!(session.current_gsid().as_deref(), Some("gsid_A"));

    // Activate B
    session.set_active_account(account_b).unwrap();
    assert_eq!(session.current_uid().as_deref(), Some("account_B"));
    assert_eq!(session.current_token().as_deref(), Some("token_B"));
    assert_eq!(session.current_cookie().as_deref(), Some("SUB=sub_B; SUBP=subp_B"));

    // Switch back to A
    let switched = session.switch_account("account_A").unwrap();
    assert_eq!(switched.uid, "account_A");
    assert_eq!(session.current_uid().as_deref(), Some("account_A"));

    // Delete active account A -> active session should become None
    session.delete_account("account_A").unwrap();
    assert!(session.current_account().is_none());

    // Switch to B
    session.switch_account("account_B").unwrap();
    assert_eq!(session.current_uid().as_deref(), Some("account_B"));

    // Logout
    session.logout().unwrap();
    assert!(session.current_account().is_none());

    // Test session restoration from new SessionManager instance on same DB
    // First set active B
    session.switch_account("account_B").unwrap();

    let restored_session = SessionManager::new(db).unwrap();
    assert_eq!(restored_session.current_uid().as_deref(), Some("account_B"));
}

// ============================================================================
// 5. PHASE 2 WEIBO COMPLEX JSON & TIMELINE SERIALIZATION TESTS
// ============================================================================

#[test]
fn test_complex_weibo_json_nested_repost_and_18_pics() {
    // Generate 18 picture URLs
    let mut pic_urls = Vec::new();
    let mut pic_ids = Vec::new();
    for i in 1..=18 {
        pic_urls.push(PicUrlItem {
            thumbnail_pic: format!("https://wx1.sinaimg.cn/thumbnail/006abcdef{i:02x}.jpg"),
        });
        pic_ids.push(format!("006abcdef{i:02x}"));
    }

    // Build nested retweeted status
    let original_status = StatusModel {
        id: 4800000000000001,
        mid: "M_ORIGINAL_001".to_string(),
        created_at: "Mon Oct 26 12:00:00 +0800 2026".to_string(),
        text: "原博文内容：探讨 Rust 与 Flutter 深度融合架构！#架构设计# [鼓掌]".to_string(),
        source: Some("<a href=\"http://app.weibo.com/t/feed/6vtZb0\" rel=\"nofollow\">微博 weibo.com</a>".to_string()),
        reposts_count: 50,
        comments_count: 88,
        attitudes_count: 200,
        user: Some(UserModel {
            id: 200001,
            idstr: "200001".to_string(),
            screen_name: "原创作者".to_string(),
            verified: true,
            verified_type: 0,
            ..Default::default()
        }),
        pic_urls: pic_urls[0..4].to_vec(),
        pic_ids: pic_ids[0..4].to_vec(),
        ..Default::default()
    };

    // 3,000 characters long text
    let super_long_text = format!(
        "【深度分析】重构工程进展报告：{}\n#Weibo# #Flutter# [doge][二哈][心]",
        "这是一段极长的测试文本内容。".repeat(150)
    );

    let status = StatusModel {
        id: 4800000000000002,
        mid: "M_FORWARD_002".to_string(),
        created_at: "Tue Oct 27 14:00:00 +0800 2026".to_string(),
        text: super_long_text.clone(),
        source: Some("<a href=\"http://weibo.com/\">Share 客户端</a>".to_string()),
        favorited: true,
        truncated: false,
        reposts_count: 120,
        comments_count: 230,
        attitudes_count: 999,
        pic_urls: pic_urls.clone(),
        pic_ids: pic_ids.clone(),
        is_long_text: true,
        liked: true,
        user: Some(UserModel {
            id: 100001,
            idstr: "100001".to_string(),
            screen_name: "转发用户".to_string(),
            verified: true,
            verified_type: 2, // blue V
            description: Some("资深移动端与跨端技术专家".to_string()),
            followers_count: Some(50000),
            following: true,
            ..Default::default()
        }),
        retweeted_status: Some(Box::new(original_status)),
        ..Default::default()
    };

    let timeline = TimelineResponse {
        statuses: vec![status],
        total_number: Some(1),
        since_id: Some("4800000000000001".to_string()),
        max_id: Some("4800000000000002".to_string()),
        hasvisible: Some(true),
        previous_cursor: Some(0),
        next_cursor: Some(4800000000000000),
    };

    // Serialize to JSON
    let json_str = serde_json::to_string(&timeline).expect("Timeline serialization failed");
    assert!(json_str.contains("M_FORWARD_002"));
    assert!(json_str.contains("M_ORIGINAL_001"));
    assert!(json_str.contains("isLongText"));

    // Deserialize back
    let deserialized: TimelineResponse =
        serde_json::from_str(&json_str).expect("Timeline deserialization failed");
    assert_eq!(deserialized.statuses.len(), 1);

    let parsed_status = &deserialized.statuses[0];
    assert_eq!(parsed_status.id, 4800000000000002);
    assert_eq!(parsed_status.mid, "M_FORWARD_002");
    assert!(parsed_status.is_long_text);
    assert!(parsed_status.liked);
    assert_eq!(parsed_status.pic_urls.len(), 18);
    assert_eq!(parsed_status.pic_ids.len(), 18);

    // Verify resolved pic urls
    let resolved = parsed_status.resolved_pic_urls();
    assert_eq!(resolved.len(), 18);
    assert!(resolved[0].contains("/bmiddle/"));

    // Verify nested retweet
    let retweet = parsed_status.retweeted_status.as_ref().unwrap();
    assert_eq!(retweet.mid, "M_ORIGINAL_001");
    assert_eq!(retweet.clean_source(), "微博 weibo.com");
    assert_eq!(retweet.user.as_ref().unwrap().screen_name, "原创作者");
    assert_eq!(retweet.pic_urls.len(), 4);
}

#[test]
fn test_clean_source_edge_cases() {
    let cases = vec![
        // Standard anchor tag
        ("<a href=\"http://app.weibo.com/\" rel=\"nofollow\">iPhone 16 Pro Max</a>", "iPhone 16 Pro Max"),
        // Whitespace inside anchor
        ("<a href=\"http://weibo.com/\">  Share 微博  </a>", "Share 微博"),
        // Empty anchor
        ("<a href=\"http://weibo.com/\"></a>", ""),
        // Plain text (no HTML tags)
        ("来自 华为 Mate 60 Pro", "来自 华为 Mate 60 Pro"),
        // Malformed HTML (no closing tag)
        ("<a href=\"http://weibo.com/\">未闭合标签", "<a href=\"http://weibo.com/\">未闭合标签"),
        // Source with query params and complex attributes
        ("<a href=\"http://weibo.com/p/100808?k=test\" target=\"_blank\">超话社区</a>", "超话社区"),
        // HTML entities inside
        ("<a href=\"#\">新浪&amp;微博</a>", "新浪&amp;微博"),
    ];

    for (input, expected) in cases {
        let status = StatusModel {
            source: Some(input.to_string()),
            ..Default::default()
        };
        assert_eq!(status.clean_source(), expected, "Failed for source input: {}", input);
    }

    // None source
    let status_none = StatusModel {
        source: None,
        ..Default::default()
    };
    assert_eq!(status_none.clean_source(), "");
}

#[test]
fn test_weibo_client_cache_pipeline() {
    let db = DatabaseManager::open_in_memory().unwrap();
    let device = DeviceContext::default();
    let client = WeiboClient::new(device, None, Some(db.clone()));

    // Cache a multi-status timeline response
    let status1 = StatusModel {
        id: 1001,
        mid: "mid_1001".to_string(),
        created_at: "now".to_string(),
        text: "Status 1 text".to_string(),
        ..Default::default()
    };
    let status2 = StatusModel {
        id: 1002,
        mid: "mid_1002".to_string(),
        created_at: "now".to_string(),
        text: "Status 2 text with [doge]".to_string(),
        ..Default::default()
    };
    let timeline = TimelineResponse {
        statuses: vec![status1, status2],
        total_number: Some(2),
        ..Default::default()
    };

    let json_bytes = serde_json::to_string(&timeline).unwrap();
    let dao = ShareJsonDao::new(&db);
    dao.put("home_timeline_cache_user888", &json_bytes).unwrap();

    let cached = client.get_cached_timeline("user888").expect("Failed to retrieve cached timeline");
    assert_eq!(cached.statuses.len(), 2);
    assert_eq!(cached.statuses[0].id, 1001);
    assert_eq!(cached.statuses[1].mid, "mid_1002");
    assert_eq!(cached.statuses[1].text, "Status 2 text with [doge]");

    // Non-existent cache returns None
    assert!(client.get_cached_timeline("non_existent_user").is_none());
}

// ============================================================================
// 6. PHASE 3 COMMENTS & DRAFT PERSISTENCE BOUNDARY TESTS
// ============================================================================

#[test]
fn test_comment_model_extreme_boundaries() {
    // 1. Extreme: Anonymous comment (no user, no avatar, no nickname)
    let anon_comment = CommentModel {
        id: 9001,
        text: "这是一条匿名/用户已注销的评论".to_string(),
        created_at: "now".to_string(),
        user: None,
        reply_comment: None,
        pic_urls: vec![],
        ..Default::default()
    };
    let anon_json = serde_json::to_string(&anon_comment).unwrap();
    let anon_parsed: CommentModel = serde_json::from_str(&anon_json).unwrap();
    assert_eq!(anon_parsed.id, 9001);
    assert!(anon_parsed.user.is_none());
    assert!(anon_parsed.reply_comment.is_none());
    assert!(anon_parsed.pic_urls.is_empty());

    // 2. Extreme: 1500-character long comment with 9 picture URLs
    let long_comment_text = "千字长评论深度探讨Share微博架构：".to_string() + &"评论内容极为丰富，逐行分析代码细节。".repeat(75);
    let pics: Vec<String> = (1..=9).map(|i| format!("https://wx1.sinaimg.cn/bmiddle/comment_pic_{i}.jpg")).collect();

    let rich_comment = CommentModel {
        id: 9002,
        floor_number: Some(9999),
        text: long_comment_text.clone(),
        created_at: "Wed Oct 28 15:00:00 +0800 2026".to_string(),
        source: Some("<a href=\"http://weibo.com/\" rel=\"nofollow\">Share 微博</a>".to_string()),
        like_counts: 1500,
        liked: true,
        is_author: true,
        is_author_liked: true,
        user: Some(UserModel {
            id: 8888,
            screen_name: "超长评论博主".to_string(),
            avatar_large: Some("https://wx1.sinaimg.cn/avatar/8888.jpg".to_string()),
            verified: true,
            verified_type: 220, // Gold V
            ..Default::default()
        }),
        pic_urls: pics.clone(),
        sub_comments: vec![],
        total_number: Some(0),
        ..Default::default()
    };

    let rich_json = serde_json::to_string(&rich_comment).unwrap();
    let rich_parsed: CommentModel = serde_json::from_str(&rich_json).unwrap();
    assert_eq!(rich_parsed.id, 9002);
    assert_eq!(rich_parsed.floor_number, Some(9999));
    assert_eq!(rich_parsed.text.len(), long_comment_text.len());
    assert_eq!(rich_parsed.clean_source(), "Share 微博");
    assert_eq!(rich_parsed.pic_urls.len(), 9);
    assert!(rich_parsed.is_author);
    assert!(rich_parsed.is_author_liked);
}

#[test]
fn test_comment_floor_replies_collapse_and_counts() {
    // 0 replies
    let comment_0 = CommentModel {
        id: 9100,
        text: "无任何楼中楼回复的主评".to_string(),
        total_number: Some(0),
        sub_comments: vec![],
        ..Default::default()
    };
    assert_eq!(comment_0.total_number, Some(0));
    assert!(comment_0.sub_comments.is_empty());

    // 1 reply
    let sub1 = CommentModel {
        id: 9101,
        rootid: Some(9100),
        text: "回复 @楼主: 唯有一条回复".to_string(),
        ..Default::default()
    };
    let comment_1 = CommentModel {
        id: 9100,
        text: "有1条楼中楼回复的主评".to_string(),
        total_number: Some(1),
        sub_comments: vec![sub1],
        ..Default::default()
    };
    assert_eq!(comment_1.total_number, Some(1));
    assert_eq!(comment_1.sub_comments.len(), 1);

    // 100+ replies (e.g. 158 replies total, 2 previewed in list)
    let sub2 = CommentModel {
        id: 9102,
        rootid: Some(9100),
        text: "回复 @楼主: 第二条回复".to_string(),
        ..Default::default()
    };
    let comment_100 = CommentModel {
        id: 9100,
        text: "热门爆款评论".to_string(),
        total_number: Some(158),
        sub_comments: vec![comment_1.sub_comments[0].clone(), sub2],
        ..Default::default()
    };
    assert_eq!(comment_100.total_number, Some(158));
    assert_eq!(comment_100.sub_comments.len(), 2);

    let resp = CommentListResponse {
        comments: vec![comment_0, comment_1, comment_100],
        total_number: 3,
        max_id: Some(9100),
        since_id: Some(0),
        root_comment: None,
    };

    let resp_json = serde_json::to_string(&resp).unwrap();
    let resp_parsed: CommentListResponse = serde_json::from_str(&resp_json).unwrap();
    assert_eq!(resp_parsed.total_number, 3);
    assert_eq!(resp_parsed.comments[2].total_number, Some(158));
}

#[test]
fn test_draft_persistence_and_state_transitions() {
    let db = DatabaseManager::open_in_memory().unwrap();
    let dao = DraftDao::new(&db);

    // 1. Initial draft creation with 18 image URLs & 2000 characters
    let urls: Vec<String> = (1..=18).map(|i| format!("/storage/emulated/0/DCIM/pic_{i}.jpg")).collect();
    let urls_json = serde_json::to_string(&urls).unwrap();
    let long_content = "【草稿内容测试】".to_string() + &"微博正文草稿持久化保存，验证SQLite存取完备性。".repeat(70);

    let draft = StatusDraftEntity {
        content: long_content.clone(),
        date: 1720000000,
        urls: Some(urls_json.clone()),
        uid: "user_test_draft_lifecycle".to_string(),
        status: 0, // 0: 草稿
        assign_group_type: Some(0), // 公开
        ..Default::default()
    };

    let draft_id = dao.insert(&draft).expect("Failed to insert initial draft");
    assert!(draft_id > 0);

    // 2. Query draft from SQLite
    let fetched = dao.get_by_id(draft_id).unwrap().expect("Draft not found");
    assert_eq!(fetched.status, 0);
    assert_eq!(fetched.content, long_content);
    assert_eq!(fetched.urls, Some(urls_json.clone()));

    // 3. User re-edits draft
    let updated_draft = StatusDraftEntity {
        id: Some(draft_id),
        content: "【二次编辑后的正文】新增了重要讨论点".to_string(),
        date: 1720001000,
        urls: Some(urls_json.clone()),
        uid: "user_test_draft_lifecycle".to_string(),
        status: 0,
        assign_group_type: Some(1), // 好友圈
        ..Default::default()
    };
    assert!(dao.update(&updated_draft).unwrap());

    let fetched2 = dao.get_by_id(draft_id).unwrap().unwrap();
    assert_eq!(fetched2.content, "【二次编辑后的正文】新增了重要讨论点");
    assert_eq!(fetched2.assign_group_type, Some(1));

    // 4. User hits Send -> Status transitions to 1 (Sending)
    dao.update_status(draft_id, 1).unwrap();
    assert_eq!(dao.get_by_id(draft_id).unwrap().unwrap().status, 1);

    // 5. Network error -> Status transitions to 2 (Failed)
    dao.update_status(draft_id, 2).unwrap();
    assert_eq!(dao.get_by_id(draft_id).unwrap().unwrap().status, 2);

    // 6. Delete draft after successful retry / user discard
    assert!(dao.delete_by_id(draft_id).unwrap());
    assert_eq!(dao.count_by_uid("user_test_draft_lifecycle").unwrap(), 0);

    // 7. Test batch delete all drafts for UID
    for i in 1..=3 {
        dao.insert(&StatusDraftEntity {
            content: format!("Draft {i}"),
            date: 1720000000 + i,
            uid: "user_batch_delete".to_string(),
            status: 0,
            ..Default::default()
        }).unwrap();
    }
    assert_eq!(dao.count_by_uid("user_batch_delete").unwrap(), 3);
    let deleted_count = dao.delete_all_by_uid("user_batch_delete").unwrap();
    assert_eq!(deleted_count, 3);
    assert_eq!(dao.count_by_uid("user_batch_delete").unwrap(), 0);
}

// ============================================================================
// 7. WESYNC PROTOCOL & SOCIAL DATA BOUNDARY TESTS
// ============================================================================

#[test]
fn test_wesync_binary_protocol_extreme_boundaries() {
    use share_core::wesync::{WeSyncCommand, WeSyncError, WeSyncFrame, HEADER_SIZE, WESYNC_MAGIC};

    // 1. Invalid Magic defense
    let bad_magics = [
        [0x00, 0x00],
        [0x77, 0x00],
        [0x00, 0x62],
        [0xFF, 0xFF],
    ];
    for magic in bad_magics {
        let mut buf = vec![magic[0], magic[1]];
        buf.extend_from_slice(&[0, 11, 0, 0, 0, 1, 0, 0, 0, 0]); // total 12 bytes
        let err = WeSyncFrame::decode(&buf).unwrap_err();
        assert_eq!(err, WeSyncError::InvalidMagic(magic[0], magic[1]));
    }

    // 2. Abnormal Command opcodes
    let opcodes = [0u16, 65535u16, 999u16];
    for op in opcodes {
        let frame = WeSyncFrame::new(WeSyncCommand::Unknown(op), 12345, b"test_abnormal".to_vec());
        let encoded = frame.encode();
        let (decoded, consumed) = WeSyncFrame::decode(&encoded).unwrap();
        assert_eq!(consumed, encoded.len());
        assert_eq!(decoded.cmd, WeSyncCommand::Unknown(op));
        assert_eq!(decoded.seq, 12345);
        assert_eq!(decoded.payload, b"test_abnormal");
    }

    // 3. Payload length field overflow / truncation
    let mut truncated_buf = Vec::new();
    truncated_buf.extend_from_slice(&WESYNC_MAGIC);
    truncated_buf.extend_from_slice(&17u16.to_be_bytes()); // Cmd: Heartbeat
    truncated_buf.extend_from_slice(&100u32.to_be_bytes()); // Seq
    truncated_buf.extend_from_slice(&10000u32.to_be_bytes()); // Declared Body Len = 10000
    truncated_buf.extend_from_slice(b"short"); // Actual Body = 5 bytes (Total = 17 bytes)

    let err = WeSyncFrame::decode(&truncated_buf).unwrap_err();
    match err {
        WeSyncError::BufferTooShort { expected, actual } => {
            assert_eq!(expected, HEADER_SIZE + 10000);
            assert_eq!(actual, 17);
        }
        _ => panic!("Expected BufferTooShort error"),
    }

    // 4. Empty payload packet
    let empty_frame = WeSyncFrame::new(WeSyncCommand::Heartbeat, 99, vec![]);
    let empty_encoded = empty_frame.encode();
    assert_eq!(empty_encoded.len(), HEADER_SIZE);
    let (empty_decoded, consumed) = WeSyncFrame::decode(&empty_encoded).unwrap();
    assert_eq!(consumed, HEADER_SIZE);
    assert_eq!(empty_decoded.seq, 99);
    assert!(empty_decoded.payload.is_empty());

    // 5. Incomplete frame boundary (less than HEADER_SIZE)
    for len in 0..HEADER_SIZE {
        let partial_buf = vec![0x77; len];
        let err = WeSyncFrame::decode(&partial_buf).unwrap_err();
        match err {
            WeSyncError::BufferTooShort { expected, actual } => {
                assert_eq!(expected, HEADER_SIZE);
                assert_eq!(actual, len);
            }
            _ => panic!("Expected BufferTooShort"),
        }
    }

    // 6. Multiple concatenated frames in a continuous byte stream
    let frame1 = WeSyncFrame::new(WeSyncCommand::Handshake, 1, b"FRAME_ONE".to_vec());
    let frame2 = WeSyncFrame::new(WeSyncCommand::Heartbeat, 2, b"FRAME_TWO".to_vec());
    let mut stream = frame1.encode();
    stream.extend_from_slice(&frame2.encode());

    let (dec1, consumed1) = WeSyncFrame::decode(&stream).unwrap();
    assert_eq!(dec1.cmd, WeSyncCommand::Handshake);
    assert_eq!(dec1.payload, b"FRAME_ONE");

    let remaining = &stream[consumed1..];
    let (dec2, consumed2) = WeSyncFrame::decode(remaining).unwrap();
    assert_eq!(dec2.cmd, WeSyncCommand::Heartbeat);
    assert_eq!(dec2.payload, b"FRAME_TWO");
    assert_eq!(consumed1 + consumed2, stream.len());
}

#[test]
fn test_mps_push_payload_boundary_and_malformed_json() {
    use share_core::wesync::{WeSyncCommand, WeSyncError, WeSyncFrame};

    // 1. Missing fields (empty object {})
    let empty_json_frame = WeSyncFrame::new(
        WeSyncCommand::ServerPush,
        1,
        b"{}".to_vec(),
    );
    let parsed = empty_json_frame.parse_push_payload().unwrap();
    assert_eq!(parsed.msg_type, "");
    assert_eq!(parsed.id, 0);
    assert_eq!(parsed.sender_uid, "");
    assert_eq!(parsed.sender_name, "");
    assert_eq!(parsed.content, "");
    assert_eq!(parsed.timestamp, 0);
    assert_eq!(parsed.unread_count, None);
    assert_eq!(parsed.extra, None);

    // 2. Malformed JSON
    let broken_frame = WeSyncFrame::new(
        WeSyncCommand::ServerPush,
        2,
        b"{ broken json ".to_vec(),
    );
    let err = broken_frame.parse_push_payload().unwrap_err();
    match err {
        WeSyncError::JsonParse(_) => {}
        _ => panic!("Expected JsonParse error"),
    }

    // 3. Extreme timestamps and abnormal unread counts
    let edge_json = r#"{
        "msg_type": "notification",
        "id": 9223372036854775807,
        "sender_uid": "0",
        "sender_name": "系统通知",
        "content": "极值时间戳与大未读数测试",
        "timestamp": 9223372036854775807,
        "unread_count": 99999
    }"#;
    let edge_frame = WeSyncFrame::new(
        WeSyncCommand::ServerPush,
        3,
        edge_json.as_bytes().to_vec(),
    );
    let edge_parsed = edge_frame.parse_push_payload().unwrap();
    assert_eq!(edge_parsed.id, i64::MAX);
    assert_eq!(edge_parsed.timestamp, i64::MAX);
    assert_eq!(edge_parsed.unread_count, Some(99999));
}

#[test]
fn test_social_topic_and_dm_models_boundaries() {
    use share_core::parser::social_model::{DmMessageModel, NotificationModel, TopicModel, TopicSignInResult};

    // 1. TopicModel boundary: 365+ days consecutive sign in, 0 vs 10M followers
    let topic_extreme = TopicModel {
        id: "topic_extreme_999".to_string(),
        title: "Rust并发架构超话".to_string(),
        desc: "".to_string(),
        banner_url: None,
        avatar_url: None,
        rank_badge: Some("超话 TOP.1".to_string()),
        followers_count: 10_000_000,
        posts_count: 50_000_000,
        is_signed: true,
        sign_days: 999,
        sign_rank: Some(1),
    };
    assert_eq!(topic_extreme.sign_days, 999);
    assert_eq!(topic_extreme.followers_count, 10_000_000);
    assert!(topic_extreme.banner_url.is_none());

    let json = serde_json::to_string(&topic_extreme).unwrap();
    let back: TopicModel = serde_json::from_str(&json).unwrap();
    assert_eq!(back, topic_extreme);

    // 2. TopicSignInResult: duplicate sign-in
    let duplicate_result = TopicSignInResult {
        success: false,
        sign_days: 999,
        rank: 0,
        message: "今日已打卡".to_string(),
    };
    assert!(!duplicate_result.success);
    assert_eq!(duplicate_result.message, "今日已打卡");

    // 3. DmMessageModel revoke window validation (120s threshold)
    let base_now = 1720000000i64;
    let within_window = DmMessageModel {
        id: 1,
        sender_uid: "me".to_string(),
        recipient_uid: "peer".to_string(),
        text: "撤回时效内消息".to_string(),
        timestamp: base_now - 119, // 1m59s
        is_outgoing: true,
        is_recalled: false,
    };
    let expired_window = DmMessageModel {
        id: 2,
        sender_uid: "me".to_string(),
        recipient_uid: "peer".to_string(),
        text: "超出撤回时效消息".to_string(),
        timestamp: base_now - 121, // 2m01s
        is_outgoing: true,
        is_recalled: false,
    };
    assert!(base_now - within_window.timestamp <= 120);
    assert!(base_now - expired_window.timestamp > 120);

    // 4. NotificationModel: 4 notification types and null sender fallback
    for t in 0..=3 {
        let notify = NotificationModel {
            id: 100 + t as i64,
            notify_type: t,
            sender: None,
            created_at: "刚刚".to_string(),
            action_text: format!("Type {t} Action"),
            target_summary: "".to_string(),
            target_id: None,
        };
        assert_eq!(notify.notify_type, t);
        assert!(notify.sender.is_none());
    }
}

// ============================================================================
// 8. SEARCH ENGINE & HOT SEARCH 1..=50 RANKING TESTS
// ============================================================================

#[test]
fn test_hot_search_ranking_50_items_and_badges() {
    use share_core::parser::search_model::{HotSearchItemModel, SearchResultModel};

    // 1. Generate 50 hot search ranking items
    let mut items = Vec::with_capacity(50);
    for rank in 1..=50 {
        let tag = match rank {
            1 => Some("沸".to_string()),
            2 | 3 => Some("热".to_string()),
            r if r % 7 == 0 => Some("新".to_string()),
            r if r % 11 == 0 => Some("商".to_string()),
            r if r % 13 == 0 => Some("荐".to_string()),
            _ => None,
        };
        items.push(HotSearchItemModel {
            rank,
            keyword: format!("热搜榜单第 {rank} 位话题关键词"),
            tag,
            search_num: Some((5_000_000 - rank as u64 * 80_000).max(100_000)),
            icon_url: None,
            is_pinned: rank == 1,
        });
    }

    assert_eq!(items.len(), 50);
    assert_eq!(items[0].rank, 1);
    assert_eq!(items[0].tag.as_deref(), Some("沸"));
    assert!(items[0].is_pinned);
    assert_eq!(items[1].tag.as_deref(), Some("热"));
    assert_eq!(items[2].tag.as_deref(), Some("热"));
    assert_eq!(items[6].tag.as_deref(), Some("新")); // rank 7
    assert_eq!(items[10].tag.as_deref(), Some("商")); // rank 11
    assert_eq!(items[12].tag.as_deref(), Some("荐")); // rank 13
    assert_eq!(items[49].rank, 50);

    // Round-trip serialization
    let json = serde_json::to_string(&items).unwrap();
    let back: Vec<HotSearchItemModel> = serde_json::from_str(&json).unwrap();
    assert_eq!(back.len(), 50);
    assert_eq!(back[0], items[0]);
    assert_eq!(back[49], items[49]);

    // 2. SearchResultModel categories and pagination boundaries
    let categories = ["all", "user", "status", "pic", "video", "topic"];
    for cat in categories {
        let res = SearchResultModel {
            category: cat.to_string(),
            query: "Share微博客户端".to_string(),
            page: 1,
            has_more: true,
            statuses: vec![],
            users: vec![],
            topics: vec![],
        };
        assert_eq!(res.category, cat);
        assert!(res.has_more);
    }
}

#[test]
fn test_search_history_persistence_in_sqlite() {
    let db = DatabaseManager::open_in_memory().unwrap();
    let dao = ShareJsonDao::new(&db);

    let history_key = "weibo_search_history";
    let initial_history = vec![
        "Flutter 3.24".to_string(),
        "Rust 2024".to_string(),
        "Weibo 1:1 重构".to_string(),
    ];
    let history_json = serde_json::to_string(&initial_history).unwrap();

    // 1. Save history to SQLite
    dao.put(history_key, &history_json).unwrap();

    // 2. Read back
    let fetched = dao.get(history_key).unwrap().expect("History json missing");
    let parsed: Vec<String> = serde_json::from_str(&fetched).unwrap();
    assert_eq!(parsed, initial_history);

    // 3. Update history: prepend new search term & remove oldest if needed
    let mut updated_history = parsed;
    updated_history.insert(0, "神舟十九号".to_string());
    let updated_json = serde_json::to_string(&updated_history).unwrap();
    dao.put(history_key, &updated_json).unwrap();

    let fetched2 = dao.get(history_key).unwrap().unwrap();
    let parsed2: Vec<String> = serde_json::from_str(&fetched2).unwrap();
    assert_eq!(parsed2.len(), 4);
    assert_eq!(parsed2[0], "神舟十九号");

    // 4. Clear history
    dao.delete(history_key).unwrap();
    assert!(dao.get(history_key).unwrap().is_none());
}




