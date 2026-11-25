//! High-level Storage APIs for drafts, history, and key-value cache.

use std::sync::OnceLock;

use crate::storage::dao::{DraftDao, HistoryDao, ShareJsonDao};
use crate::storage::db::DatabaseManager;
use crate::storage::models::{StatusDraftEntity, StatusHistoryEntity};

static GLOBAL_DB: OnceLock<DatabaseManager> = OnceLock::new();

/// Initializes the global database instance.
pub fn init_storage(db_path: &str) -> Result<(), String> {
    let db = if db_path == ":memory:" {
        DatabaseManager::open_in_memory()
    } else {
        DatabaseManager::open_file(db_path)
    }
    .map_err(|e| format!("Storage initialization failed: {e}"))?;

    let _ = GLOBAL_DB.set(db);
    Ok(())
}

/// Returns reference to global DB instance.
#[flutter_rust_bridge::frb(ignore)]
pub fn get_db() -> Result<&'static DatabaseManager, String> {
    GLOBAL_DB
        .get()
        .ok_or_else(|| "Database not initialized. Call init_storage first.".to_string())
}

/// Saves a draft and returns its allocated ID.
pub fn save_draft(draft: StatusDraftEntity) -> Result<i64, String> {
    let db = get_db()?;
    let dao = DraftDao::new(db);
    if let Some(_) = draft.id {
        dao.update(&draft)
            .map_err(|e| e.to_string())?;
        Ok(draft.id.unwrap())
    } else {
        dao.insert(&draft).map_err(|e| e.to_string())
    }
}

/// Lists all drafts for a user UID.
pub fn list_drafts(uid: &str) -> Result<Vec<StatusDraftEntity>, String> {
    let db = get_db()?;
    let dao = DraftDao::new(db);
    dao.list_by_uid(uid).map_err(|e| e.to_string())
}

/// Deletes a draft by ID.
pub fn delete_draft(id: i64) -> Result<bool, String> {
    let db = get_db()?;
    let dao = DraftDao::new(db);
    dao.delete_by_id(id).map_err(|e| e.to_string())
}

/// Retrieves a specific draft by ID.
pub fn get_draft(id: i64) -> Result<Option<StatusDraftEntity>, String> {
    let db = get_db()?;
    let dao = DraftDao::new(db);
    dao.get_by_id(id).map_err(|e| e.to_string())
}

/// Updates a draft's execution status (0: draft, 1: sending, 2: failed).
pub fn update_draft_status(id: i64, status: i32) -> Result<bool, String> {
    let db = get_db()?;
    let dao = DraftDao::new(db);
    dao.update_status(id, status).map_err(|e| e.to_string())
}

/// Clears all drafts for a user UID.
pub fn clear_drafts(uid: &str) -> Result<usize, String> {
    let db = get_db()?;
    let dao = DraftDao::new(db);
    dao.delete_all_by_uid(uid).map_err(|e| e.to_string())
}

/// Records a status view in history.
pub fn record_status_history(item: StatusHistoryEntity) -> Result<i64, String> {
    let db = get_db()?;
    let dao = HistoryDao::new(db);
    dao.record_status_view(&item).map_err(|e| e.to_string())
}

/// Lists status history with pagination.
pub fn list_status_history(
    uid: &str,
    limit: usize,
    offset: usize,
) -> Result<Vec<StatusHistoryEntity>, String> {
    let db = get_db()?;
    let dao = HistoryDao::new(db);
    dao.list_status_history(uid, limit, offset)
        .map_err(|e| e.to_string())
}

/// Stores generic JSON cache value.
pub fn set_json_cache(key: &str, json: &str) -> Result<(), String> {
    let db = get_db()?;
    let dao = ShareJsonDao::new(db);
    dao.put(key, json).map_err(|e| e.to_string())
}

/// Retrieves generic JSON cache value.
pub fn get_json_cache(key: &str) -> Result<Option<String>, String> {
    let db = get_db()?;
    let dao = ShareJsonDao::new(db);
    dao.get(key).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_storage_api() {
        let _ = init_storage(":memory:");
        let draft = StatusDraftEntity {
            content: "API Draft Test".to_string(),
            date: 1234567,
            uid: "1001".to_string(),
            ..Default::default()
        };
        let id = save_draft(draft).unwrap();
        assert!(id > 0);

        let list = list_drafts("1001").unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].content, "API Draft Test");
    }
}
