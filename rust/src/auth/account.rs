//! User Account Entity and Lifecycle States.

use serde::{Deserialize, Serialize};

use super::token::TokenBundle;
use crate::storage::models::UserEntity;

/// Account login protocol type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AccountType {
    OAuth = 0,
    WebCookie = 1,
    ThirdParty = 2,
}

impl From<i32> for AccountType {
    fn from(val: i32) -> Self {
        match val {
            1 => AccountType::WebCookie,
            2 => AccountType::ThirdParty,
            _ => AccountType::OAuth,
        }
    }
}

impl From<AccountType> for i32 {
    fn from(val: AccountType) -> Self {
        val as i32
    }
}

/// Account authentication and session state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AccountState {
    Active,
    Expired,
    Revoked,
    LoggedOut,
}

/// Domain model for an authenticated Weibo account
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserAccount {
    pub uid: String,
    pub name: String,
    pub avatar: Option<String>,
    pub gender: Option<String>,
    pub sign: Option<String>,
    pub cover: Option<String>,
    pub account_type: AccountType,
    pub state: AccountState,
    #[serde(skip)]
    pub token_bundle: TokenBundle,
    pub raw_profile_json: Option<String>,
}

impl UserAccount {
    /// Constructs a UserAccount from a persisted UserEntity.
    pub fn from_entity(entity: &UserEntity) -> Self {
        let token_bundle = TokenBundle::new(
            entity.token.clone(),
            entity.refresh_token.clone(),
            entity.expires_in,
            entity.gsid.clone(),
            entity.s_value.clone(),
            entity.i_value.clone(),
            entity.cookie.clone(),
        );

        let state = if token_bundle.is_expired() {
            AccountState::Expired
        } else {
            AccountState::Active
        };

        Self {
            uid: entity.uid.clone(),
            name: entity.name.clone().unwrap_or_else(|| entity.uid.clone()),
            avatar: entity.avatar.clone(),
            gender: entity.gender.clone(),
            sign: entity.sign.clone(),
            cover: entity.cover.clone(),
            account_type: AccountType::from(entity.parent_type),
            state,
            token_bundle,
            raw_profile_json: entity.parent_json.clone(),
        }
    }

    /// Converts this UserAccount back into a database UserEntity.
    pub fn to_entity(&self) -> UserEntity {
        UserEntity {
            id: None,
            uid: self.uid.clone(),
            token: self.token_bundle.access_token.clone(),
            parent_type: self.account_type.into(),
            gsid: self.token_bundle.gsid.clone(),
            s_value: self.token_bundle.s_value.clone(),
            i_value: self.token_bundle.i_value.clone(),
            parent_json: self.raw_profile_json.clone(),
            refresh_token: self.token_bundle.refresh_token.clone(),
            expires_in: self.token_bundle.expires_at_ms,
            name: Some(self.name.clone()),
            avatar: self.avatar.clone(),
            gender: self.gender.clone(),
            sign: self.sign.clone(),
            cover: self.cover.clone(),
            account: None,
            password: None,
            ad_token: None,
            cookie: self.token_bundle.raw_cookie.clone(),
            extra: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_entity_conversion() {
        let entity = UserEntity {
            uid: "123456789".to_string(),
            token: "oauth_token_val".to_string(),
            parent_type: 0,
            name: Some("CoderAgent".to_string()),
            avatar: Some("https://avatar.weibo.com/test.jpg".to_string()),
            ..Default::default()
        };

        let account = UserAccount::from_entity(&entity);
        assert_eq!(account.uid, "123456789");
        assert_eq!(account.name, "CoderAgent");
        assert_eq!(account.account_type, AccountType::OAuth);
        assert_eq!(account.state, AccountState::Active);

        let entity_back = account.to_entity();
        assert_eq!(entity_back.uid, entity.uid);
        assert_eq!(entity_back.token, entity.token);
    }
}
