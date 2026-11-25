//! Session Singleton and Multi-Account Context Manager.
//!
//! Tracks currently active login session, provides tokens, cookies, and GSID to HTTP client,
//! and handles instant multi-account switching.

use std::sync::{Arc, RwLock};

use super::account::UserAccount;
use crate::storage::dao::share_json_dao::ShareJsonDao;
use crate::storage::dao::user_dao::UserDao;
use crate::storage::db::{DatabaseManager, StorageError};

const ACTIVE_UID_KEY: &str = "sys_active_account_uid";

#[derive(Clone)]
pub struct SessionManager {
    db: DatabaseManager,
    active_account: Arc<RwLock<Option<UserAccount>>>,
}

impl SessionManager {
    /// Creates a new SessionManager and restores active account from database if available.
    pub fn new(db: DatabaseManager) -> Result<Self, StorageError> {
        let mgr = Self {
            db,
            active_account: Arc::new(RwLock::new(None)),
        };
        mgr.restore_session()?;
        Ok(mgr)
    }

    /// Restores the previously active account from the database.
    pub fn restore_session(&self) -> Result<(), StorageError> {
        let json_dao = ShareJsonDao::new(&self.db);
        if let Some(active_uid) = json_dao.get(ACTIVE_UID_KEY)? {
            let user_dao = UserDao::new(&self.db);
            if let Some(entity) = user_dao.get_by_uid(&active_uid)? {
                let mut current = self.active_account.write().map_err(|_| StorageError::LockError)?;
                *current = Some(UserAccount::from_entity(&entity));
            }
        }
        Ok(())
    }

    /// Returns a clone of the currently active account.
    pub fn current_account(&self) -> Option<UserAccount> {
        self.active_account.read().ok().and_then(|guard| guard.clone())
    }

    /// Returns the currently active account UID.
    pub fn current_uid(&self) -> Option<String> {
        self.current_account().map(|a| a.uid)
    }

    /// Returns the active access token.
    pub fn current_token(&self) -> Option<String> {
        self.current_account().map(|a| a.token_bundle.access_token)
    }

    /// Returns the active GSID.
    pub fn current_gsid(&self) -> Option<String> {
        self.current_account().and_then(|a| a.token_bundle.gsid)
    }

    /// Returns the active signature s-value.
    pub fn current_s_value(&self) -> Option<String> {
        self.current_account().and_then(|a| a.token_bundle.s_value)
    }

    /// Returns the active formatted cookie string.
    pub fn current_cookie(&self) -> Option<String> {
        self.current_account().map(|a| a.token_bundle.formatted_cookie())
    }

    /// Sets or updates the active account, persisting it to database.
    pub fn set_active_account(&self, account: UserAccount) -> Result<(), StorageError> {
        let user_dao = UserDao::new(&self.db);
        user_dao.insert_or_replace(&account.to_entity())?;

        let json_dao = ShareJsonDao::new(&self.db);
        json_dao.put(ACTIVE_UID_KEY, &account.uid)?;

        let mut current = self.active_account.write().map_err(|_| StorageError::LockError)?;
        *current = Some(account);

        Ok(())
    }

    /// Switches the active account by UID.
    pub fn switch_account(&self, uid: &str) -> Result<UserAccount, StorageError> {
        let user_dao = UserDao::new(&self.db);
        let entity = user_dao
            .get_by_uid(uid)?
            .ok_or_else(|| StorageError::NotFound(format!("Account {} not found", uid)))?;

        let account = UserAccount::from_entity(&entity);
        let json_dao = ShareJsonDao::new(&self.db);
        json_dao.put(ACTIVE_UID_KEY, uid)?;

        let mut current = self.active_account.write().map_err(|_| StorageError::LockError)?;
        *current = Some(account.clone());

        Ok(account)
    }

    /// Retrieves all configured user accounts.
    pub fn get_all_accounts(&self) -> Result<Vec<UserAccount>, StorageError> {
        let user_dao = UserDao::new(&self.db);
        let entities = user_dao.get_all()?;
        Ok(entities.iter().map(UserAccount::from_entity).collect())
    }

    /// Deletes an account by UID and clears active session if it was active.
    pub fn delete_account(&self, uid: &str) -> Result<(), StorageError> {
        let user_dao = UserDao::new(&self.db);
        user_dao.delete_by_uid(uid)?;

        let mut current = self.active_account.write().map_err(|_| StorageError::LockError)?;
        if let Some(active) = &*current {
            if active.uid == uid {
                *current = None;
                let json_dao = ShareJsonDao::new(&self.db);
                let _ = json_dao.delete(ACTIVE_UID_KEY);
            }
        }
        Ok(())
    }

    /// Refreshes access token in SQLite and updates the active in-memory session if matching UID.
    pub fn refresh_tokens(
        &self,
        uid: &str,
        token: &str,
        expires_in: Option<i64>,
        refresh_token: Option<&str>,
    ) -> Result<(), String> {
        let user_dao = UserDao::new(&self.db);
        user_dao
            .update_tokens(uid, token, refresh_token, expires_in)
            .map_err(|e| e.to_string())?;

        let mut current = self.active_account.write().map_err(|_| "Lock acquisition error".to_string())?;
        if let Some(active) = current.as_mut() {
            if active.uid == uid {
                active.token_bundle.access_token = token.to_string();
                if let Some(exp) = expires_in {
                    active.token_bundle.expires_at_ms = Some(exp);
                }
                if let Some(ref_tok) = refresh_token {
                    active.token_bundle.refresh_token = Some(ref_tok.to_string());
                }
                active.state = if active.token_bundle.is_expired() {
                    crate::auth::account::AccountState::Expired
                } else {
                    crate::auth::account::AccountState::Active
                };
            }
        }
        Ok(())
    }

    /// Logs out the current user by clearing active session.
    pub fn logout(&self) -> Result<(), StorageError> {
        let mut current = self.active_account.write().map_err(|_| StorageError::LockError)?;
        *current = None;
        let json_dao = ShareJsonDao::new(&self.db);
        let _ = json_dao.delete(ACTIVE_UID_KEY);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::account::AccountType;
    use crate::auth::token::TokenBundle;

    #[test]
    fn test_session_manager_flow() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let session = SessionManager::new(db).unwrap();

        assert!(session.current_account().is_none());

        let account1 = UserAccount {
            uid: "1001001".to_string(),
            name: "WeiboDev1".to_string(),
            avatar: None,
            gender: Some("m".to_string()),
            sign: None,
            cover: None,
            account_type: AccountType::OAuth,
            state: crate::auth::account::AccountState::Active,
            token_bundle: TokenBundle::new(
                "token_1".to_string(),
                None,
                None,
                Some("gsid_1".to_string()),
                Some("s_val_1".to_string()),
                None,
                None,
            ),
            raw_profile_json: None,
        };

        session.set_active_account(account1).unwrap();
        assert_eq!(session.current_uid().as_deref(), Some("1001001"));
        assert_eq!(session.current_token().as_deref(), Some("token_1"));
        assert_eq!(session.current_gsid().as_deref(), Some("gsid_1"));

        // Test refresh_tokens in-place
        session
            .refresh_tokens("1001001", "new_refreshed_token", Some(9999999999999), Some("new_refresh_tok"))
            .unwrap();
        let refreshed = session.current_account().unwrap();
        assert_eq!(refreshed.token_bundle.access_token, "new_refreshed_token");
        assert_eq!(
            refreshed.token_bundle.refresh_token.as_deref(),
            Some("new_refresh_tok")
        );
        assert_eq!(refreshed.token_bundle.expires_at_ms, Some(9999999999999));

        // Switch or logout
        session.logout().unwrap();
        assert!(session.current_account().is_none());
    }
}
