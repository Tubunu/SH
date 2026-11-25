//! High-level Authentication and Session APIs.

use std::sync::OnceLock;

use crate::auth::account::UserAccount;
use crate::auth::session::SessionManager;
use crate::storage::db::DatabaseManager;

static GLOBAL_SESSION: OnceLock<SessionManager> = OnceLock::new();

#[flutter_rust_bridge::frb(ignore)]
pub fn init_auth_session(db: DatabaseManager) -> Result<(), String> {
    let session =
        SessionManager::new(db).map_err(|e| format!("Failed to create SessionManager: {e}"))?;
    let _ = GLOBAL_SESSION.set(session);
    Ok(())
}

/// Initializes auth session using the global storage database.
pub fn init_auth() -> Result<(), String> {
    let db = crate::api::storage_api::get_db()?.clone();
    init_auth_session(db)
}

#[flutter_rust_bridge::frb(ignore)]
pub fn get_session() -> Result<&'static SessionManager, String> {
    GLOBAL_SESSION
        .get()
        .ok_or_else(|| "SessionManager not initialized. Call init_auth_session first.".to_string())
}

/// Returns the currently active account, if any.
pub fn get_current_account() -> Option<UserAccount> {
    get_session().ok().and_then(|s| s.current_account())
}

/// Switches active user account by UID.
pub fn switch_account(uid: &str) -> Result<UserAccount, String> {
    let s = get_session()?;
    s.switch_account(uid).map_err(|e| e.to_string())
}

/// Retrieves all saved accounts.
pub fn get_all_accounts() -> Result<Vec<UserAccount>, String> {
    let s = get_session()?;
    s.get_all_accounts().map_err(|e| e.to_string())
}

/// Saves or updates a user account.
pub fn save_account(account: UserAccount) -> Result<(), String> {
    let s = get_session()?;
    s.set_active_account(account).map_err(|e| e.to_string())
}

/// Deletes an account by UID.
pub fn delete_account(uid: &str) -> Result<(), String> {
    let s = get_session()?;
    s.delete_account(uid).map_err(|e| e.to_string())
}

/// Refreshes token bundle for an account in DB and active session.
pub fn refresh_tokens(
    uid: &str,
    token: &str,
    expires_in: Option<i64>,
    refresh_token: Option<String>,
) -> Result<(), String> {
    let s = get_session()?;
    s.refresh_tokens(uid, token, expires_in, refresh_token.as_deref())
}

/// Logs out the active user.
pub fn logout() -> Result<(), String> {
    let s = get_session()?;
    s.logout().map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::account::{AccountState, AccountType};
    use crate::auth::token::TokenBundle;

    #[test]
    fn test_auth_api() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let _ = init_auth_session(db);

        let acct = UserAccount {
            uid: "88888888".to_string(),
            name: "AuthApiTester".to_string(),
            avatar: None,
            gender: None,
            sign: None,
            cover: None,
            account_type: AccountType::OAuth,
            state: AccountState::Active,
            token_bundle: TokenBundle::new(
                "tok_888".to_string(),
                None,
                None,
                None,
                None,
                None,
                None,
            ),
            raw_profile_json: None,
        };

        save_account(acct).unwrap();
        assert_eq!(get_current_account().unwrap().uid, "88888888");

        let all = get_all_accounts().unwrap();
        assert_eq!(all.len(), 1);

        logout().unwrap();
        assert!(get_current_account().is_none());
    }
}
