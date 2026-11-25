//! Session / multi-account persistence.
//!
//! Only cookie material is stored on disk. Everything else (profile, avatar)
//! is refreshed from the server on start-up so that the local cache can never
//! diverge from the real account state.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::client::WebClient;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Account {
    pub uid: String,
    pub screen_name: String,
    pub avatar: String,
    pub cookie: Vec<(String, String)>,
    #[serde(default)]
    pub is_guest: bool,
}

impl Account {
    pub fn cookie_string(&self) -> String {
        self.cookie
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SessionFile {
    #[serde(default)]
    pub accounts: Vec<Account>,
    #[serde(default)]
    pub active_uid: String,
}

pub struct SessionStore {
    path: PathBuf,
    data: SessionFile,
}

impl SessionStore {
    pub fn load(dir: &str) -> Self {
        let path = Path::new(dir).join("session.json");
        let data = std::fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<SessionFile>(&raw).ok())
            .unwrap_or_default();
        Self { path, data }
    }

    pub fn save(&self) -> Result<(), String> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("创建目录失败：{e}"))?;
        }
        let raw = serde_json::to_string_pretty(&self.data)
            .map_err(|e| format!("序列化会话失败：{e}"))?;
        std::fs::write(&self.path, raw).map_err(|e| format!("写入会话失败：{e}"))
    }

    pub fn active(&self) -> Option<&Account> {
        if self.data.active_uid.is_empty() {
            return self.data.accounts.first();
        }
        self.data
            .accounts
            .iter()
            .find(|a| a.uid == self.data.active_uid)
            .or_else(|| self.data.accounts.first())
    }

    pub fn accounts(&self) -> &[Account] {
        &self.data.accounts
    }

    /// Inserts or replaces an account and makes it the active one.
    pub fn upsert(&mut self, account: Account) {
        if account.uid.is_empty() {
            return;
        }
        self.data.active_uid = account.uid.clone();
        if let Some(existing) = self
            .data
            .accounts
            .iter_mut()
            .find(|a| a.uid == account.uid)
        {
            *existing = account;
        } else {
            self.data.accounts.push(account);
        }
    }

    pub fn set_active(&mut self, uid: &str) -> Result<Account, String> {
        let found = self
            .data
            .accounts
            .iter()
            .find(|a| a.uid == uid)
            .cloned()
            .ok_or_else(|| "账号不存在".to_string())?;
        self.data.active_uid = uid.to_string();
        Ok(found)
    }

    pub fn remove(&mut self, uid: &str) {
        self.data.accounts.retain(|a| a.uid != uid);
        if self.data.active_uid == uid {
            self.data.active_uid = self
                .data
                .accounts
                .first()
                .map(|a| a.uid.clone())
                .unwrap_or_default();
        }
    }

    /// Applies the active account's cookies onto a client instance.
    pub fn apply_to(&self, client: &WebClient) {
        client.clear_cookies();
        if let Some(account) = self.active() {
            client.set_cookie(&account.cookie_string());
        }
    }
}
