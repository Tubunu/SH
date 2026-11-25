//! Data Access Object for `STATUS_HISTORY` and `USER_HISTORY` tables.
//! Provides reading history persistence, pagination, and user profile visit weighting.

use rusqlite::{params, Row};

use crate::storage::db::{DatabaseManager, StorageError};
use crate::storage::models::{StatusHistoryEntity, UserHistoryEntity};

pub struct HistoryDao<'a> {
    db: &'a DatabaseManager,
}

impl<'a> HistoryDao<'a> {
    pub fn new(db: &'a DatabaseManager) -> Self {
        Self { db }
    }

    fn row_to_status_history(row: &Row) -> rusqlite::Result<StatusHistoryEntity> {
        Ok(StatusHistoryEntity {
            id: row.get(0)?,
            status_id: row.get(1)?,
            username: row.get(2)?,
            total_text: row.get(3)?,
            uid: row.get(4)?,
            json: row.get(5)?,
            create_at: row.get(6)?,
        })
    }

    fn row_to_user_history(row: &Row) -> rusqlite::Result<UserHistoryEntity> {
        Ok(UserHistoryEntity {
            id: row.get(0)?,
            target_uid: row.get(1)?,
            target_user_name: row.get(2)?,
            target_user_avatar: row.get(3)?,
            uid: row.get(4)?,
            json: row.get(5)?,
            visit_count: row.get(6)?,
            create_at: row.get(7)?,
        })
    }

    // ------------------------------------------------------------------------
    // Status History
    // ------------------------------------------------------------------------

    /// Records or updates a status viewing event.
    pub fn record_status_view(&self, item: &StatusHistoryEntity) -> Result<i64, StorageError> {
        self.db.with_conn(|conn| {
            // Delete existing entry for this status and user to move it to the top
            conn.execute(
                "DELETE FROM \"STATUS_HISTORY\" WHERE \"STATUS_ID\" = ?1 AND \"UID\" = ?2;",
                params![item.status_id, item.uid],
            )?;

            conn.execute(
                "INSERT INTO \"STATUS_HISTORY\" (
                    \"STATUS_ID\", \"USERNAME\", \"TOTAL_TEXT\", \"UID\", \"JSON\", \"CREATE_AT\"
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
                params![
                    item.status_id,
                    item.username,
                    item.total_text,
                    item.uid,
                    item.json,
                    item.create_at,
                ],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    /// Paginates status viewing history for a user.
    pub fn list_status_history(
        &self,
        uid: &str,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<StatusHistoryEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"STATUS_ID\", \"USERNAME\", \"TOTAL_TEXT\", \"UID\", \"JSON\", \"CREATE_AT\"
                 FROM \"STATUS_HISTORY\"
                 WHERE \"UID\" = ?1
                 ORDER BY \"CREATE_AT\" DESC
                 LIMIT ?2 OFFSET ?3;",
            )?;
            let iter = stmt.query_map(params![uid, limit, offset], |row| {
                Self::row_to_status_history(row)
            })?;
            let mut list = Vec::new();
            for item in iter {
                list.push(item?);
            }
            Ok(list)
        })
    }

    /// Deletes a specific status history item.
    pub fn delete_status_history(&self, id: i64) -> Result<bool, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "DELETE FROM \"STATUS_HISTORY\" WHERE \"_id\" = ?1;",
                params![id],
            )?;
            Ok(affected > 0)
        })
    }

    /// Clears all status history for a user.
    pub fn clear_status_history(&self, uid: &str) -> Result<usize, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "DELETE FROM \"STATUS_HISTORY\" WHERE \"UID\" = ?1;",
                params![uid],
            )?;
            Ok(affected)
        })
    }

    // ------------------------------------------------------------------------
    // User / Profile History
    // ------------------------------------------------------------------------

    /// Records a user profile visit, incrementing `visit_count` if already visited.
    pub fn record_user_visit(
        &self,
        uid: &str,
        target_uid: &str,
        target_user_name: &str,
        target_user_avatar: Option<&str>,
        json: Option<&str>,
        timestamp: i64,
    ) -> Result<(), StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO \"USER_HISTORY\" (
                    \"TARGET_UID\", \"TARGET_USER_NAME\", \"TARGET_USER_AVATAR\",
                    \"UID\", \"JSON\", \"VISIT_COUNT\", \"CREATE_AT\"
                ) VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6)
                ON CONFLICT(\"TARGET_UID\", \"UID\") DO UPDATE SET
                    \"TARGET_USER_NAME\" = excluded.\"TARGET_USER_NAME\",
                    \"TARGET_USER_AVATAR\" = COALESCE(excluded.\"TARGET_USER_AVATAR\", \"USER_HISTORY\".\"TARGET_USER_AVATAR\"),
                    \"JSON\" = COALESCE(excluded.\"JSON\", \"USER_HISTORY\".\"JSON\"),
                    \"VISIT_COUNT\" = \"USER_HISTORY\".\"VISIT_COUNT\" + 1,
                    \"CREATE_AT\" = excluded.\"CREATE_AT\";",
                params![
                    target_uid,
                    target_user_name,
                    target_user_avatar,
                    uid,
                    json,
                    timestamp,
                ],
            )?;
            Ok(())
        })
    }

    /// Lists most frequently or recently visited users.
    pub fn list_user_history(
        &self,
        uid: &str,
        limit: usize,
    ) -> Result<Vec<UserHistoryEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"TARGET_UID\", \"TARGET_USER_NAME\", \"TARGET_USER_AVATAR\",
                        \"UID\", \"JSON\", \"VISIT_COUNT\", \"CREATE_AT\"
                 FROM \"USER_HISTORY\"
                 WHERE \"UID\" = ?1
                 ORDER BY \"CREATE_AT\" DESC
                 LIMIT ?2;",
            )?;
            let iter = stmt.query_map(params![uid, limit], |row| Self::row_to_user_history(row))?;
            let mut list = Vec::new();
            for item in iter {
                list.push(item?);
            }
            Ok(list)
        })
    }

    /// Clears user visit history for a specific account.
    pub fn clear_user_history(&self, uid: &str) -> Result<usize, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "DELETE FROM \"USER_HISTORY\" WHERE \"UID\" = ?1;",
                params![uid],
            )?;
            Ok(affected)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_history_dao_operations() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let dao = HistoryDao::new(&db);

        // Record status view
        let item1 = StatusHistoryEntity {
            status_id: "4629471928471928".to_string(),
            username: Some("WeiboUser1".to_string()),
            total_text: Some("Test status content".to_string()),
            uid: "1001001".to_string(),
            json: "{\"id\":\"4629471928471928\"}".to_string(),
            create_at: 1000,
            ..Default::default()
        };
        dao.record_status_view(&item1).unwrap();

        let list = dao.list_status_history("1001001", 10, 0).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].status_id, "4629471928471928");

        // Clear status history
        assert_eq!(dao.clear_status_history("1001001").unwrap(), 1);
        assert_eq!(dao.list_status_history("1001001", 10, 0).unwrap().len(), 0);
    }
}
