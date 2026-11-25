//! Data Access Object for `STATUS_DRAFTS` table.
//! Manages draft creation, editing, status tracking (0-draft, 1-sending, 2-failed), and deletion.

use rusqlite::{params, Row};

use crate::storage::db::{DatabaseManager, StorageError};
use crate::storage::models::StatusDraftEntity;

pub struct DraftDao<'a> {
    db: &'a DatabaseManager,
}

impl<'a> DraftDao<'a> {
    pub fn new(db: &'a DatabaseManager) -> Self {
        Self { db }
    }

    fn row_to_entity(row: &Row) -> rusqlite::Result<StatusDraftEntity> {
        Ok(StatusDraftEntity {
            id: row.get(0)?,
            content: row.get(1)?,
            date: row.get(2)?,
            urls: row.get(3)?,
            uid: row.get(4)?,
            target_status_json: row.get(5)?,
            target_status_id: row.get(6)?,
            target_comment_id: row.get(7)?,
            target_comment_user_name: row.get(8)?,
            target_comment_content: row.get(9)?,
            assign_group_id_str: row.get(10)?,
            assign_group_type: row.get(11)?,
            address: row.get(12)?,
            publish_timing: row.get(13)?,
            is_comment_origin: row.get(14)?,
            status: row.get(15)?,
            is_mention: row.get(16)?,
            state: row.get(17)?,
            extra: row.get(18)?,
            type_: row.get(19)?,
            parent_type: row.get(20)?,
        })
    }

    /// Inserts a new draft entry and returns the allocated row ID.
    pub fn insert(&self, draft: &StatusDraftEntity) -> Result<i64, StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO \"STATUS_DRAFTS\" (
                    \"CONTENT\", \"DATE\", \"URLS\", \"UID\", \"TARGET_STATUS_JSON\",
                    \"TARGET_STATUS_ID\", \"TARGET_COMMENT_ID\", \"TARGET_COMMENT_USER_NAME\",
                    \"TARGET_COMMENT_CONTENT\", \"ASSIGN_GROUP_ID_STR\", \"ASSIGN_GROUP_TYPE\",
                    \"ADDRESS\", \"PUBLISH_TIMING\", \"IS_COMMENT_ORIGIN\", \"STATUS\",
                    \"IS_MENTION\", \"STATE\", \"EXTRA\", \"TYPE\", \"PARENT_TYPE\"
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20);",
                params![
                    draft.content,
                    draft.date,
                    draft.urls,
                    draft.uid,
                    draft.target_status_json,
                    draft.target_status_id,
                    draft.target_comment_id,
                    draft.target_comment_user_name,
                    draft.target_comment_content,
                    draft.assign_group_id_str,
                    draft.assign_group_type,
                    draft.address,
                    draft.publish_timing,
                    draft.is_comment_origin,
                    draft.status,
                    draft.is_mention,
                    draft.state,
                    draft.extra,
                    draft.type_,
                    draft.parent_type,
                ],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    /// Updates an existing draft by ID.
    pub fn update(&self, draft: &StatusDraftEntity) -> Result<bool, StorageError> {
        let draft_id = draft
            .id
            .ok_or_else(|| StorageError::Validation("Draft ID required for update".to_string()))?;

        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "UPDATE \"STATUS_DRAFTS\" SET
                    \"CONTENT\" = ?1, \"DATE\" = ?2, \"URLS\" = ?3, \"UID\" = ?4,
                    \"TARGET_STATUS_JSON\" = ?5, \"TARGET_STATUS_ID\" = ?6,
                    \"TARGET_COMMENT_ID\" = ?7, \"TARGET_COMMENT_USER_NAME\" = ?8,
                    \"TARGET_COMMENT_CONTENT\" = ?9, \"ASSIGN_GROUP_ID_STR\" = ?10,
                    \"ASSIGN_GROUP_TYPE\" = ?11, \"ADDRESS\" = ?12, \"PUBLISH_TIMING\" = ?13,
                    \"IS_COMMENT_ORIGIN\" = ?14, \"STATUS\" = ?15, \"IS_MENTION\" = ?16,
                    \"STATE\" = ?17, \"EXTRA\" = ?18, \"TYPE\" = ?19, \"PARENT_TYPE\" = ?20
                 WHERE \"_id\" = ?21;",
                params![
                    draft.content,
                    draft.date,
                    draft.urls,
                    draft.uid,
                    draft.target_status_json,
                    draft.target_status_id,
                    draft.target_comment_id,
                    draft.target_comment_user_name,
                    draft.target_comment_content,
                    draft.assign_group_id_str,
                    draft.assign_group_type,
                    draft.address,
                    draft.publish_timing,
                    draft.is_comment_origin,
                    draft.status,
                    draft.is_mention,
                    draft.state,
                    draft.extra,
                    draft.type_,
                    draft.parent_type,
                    draft_id,
                ],
            )?;
            Ok(affected > 0)
        })
    }

    /// Retrieves a draft by ID.
    pub fn get_by_id(&self, id: i64) -> Result<Option<StatusDraftEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"CONTENT\", \"DATE\", \"URLS\", \"UID\", \"TARGET_STATUS_JSON\",
                        \"TARGET_STATUS_ID\", \"TARGET_COMMENT_ID\", \"TARGET_COMMENT_USER_NAME\",
                        \"TARGET_COMMENT_CONTENT\", \"ASSIGN_GROUP_ID_STR\", \"ASSIGN_GROUP_TYPE\",
                        \"ADDRESS\", \"PUBLISH_TIMING\", \"IS_COMMENT_ORIGIN\", \"STATUS\",
                        \"IS_MENTION\", \"STATE\", \"EXTRA\", \"TYPE\", \"PARENT_TYPE\"
                 FROM \"STATUS_DRAFTS\" WHERE \"_id\" = ?1 LIMIT 1;",
            )?;
            let mut rows = stmt.query(params![id])?;
            if let Some(row) = rows.next()? {
                Ok(Some(Self::row_to_entity(row)?))
            } else {
                Ok(None)
            }
        })
    }

    /// Lists drafts for a specific user UID sorted by date descending.
    pub fn list_by_uid(&self, uid: &str) -> Result<Vec<StatusDraftEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"CONTENT\", \"DATE\", \"URLS\", \"UID\", \"TARGET_STATUS_JSON\",
                        \"TARGET_STATUS_ID\", \"TARGET_COMMENT_ID\", \"TARGET_COMMENT_USER_NAME\",
                        \"TARGET_COMMENT_CONTENT\", \"ASSIGN_GROUP_ID_STR\", \"ASSIGN_GROUP_TYPE\",
                        \"ADDRESS\", \"PUBLISH_TIMING\", \"IS_COMMENT_ORIGIN\", \"STATUS\",
                        \"IS_MENTION\", \"STATE\", \"EXTRA\", \"TYPE\", \"PARENT_TYPE\"
                 FROM \"STATUS_DRAFTS\" WHERE \"UID\" = ?1 ORDER BY \"DATE\" DESC;",
            )?;
            let iter = stmt.query_map(params![uid], |row| Self::row_to_entity(row))?;
            let mut list = Vec::new();
            for item in iter {
                list.push(item?);
            }
            Ok(list)
        })
    }

    /// Updates the draft execution status (0-draft, 1-sending, 2-failed).
    pub fn update_status(&self, id: i64, status: i32) -> Result<bool, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "UPDATE \"STATUS_DRAFTS\" SET \"STATUS\" = ?1 WHERE \"_id\" = ?2;",
                params![status, id],
            )?;
            Ok(affected > 0)
        })
    }

    /// Deletes a draft by ID.
    pub fn delete_by_id(&self, id: i64) -> Result<bool, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "DELETE FROM \"STATUS_DRAFTS\" WHERE \"_id\" = ?1;",
                params![id],
            )?;
            Ok(affected > 0)
        })
    }

    /// Counts drafts for a specific user UID.
    pub fn count_by_uid(&self, uid: &str) -> Result<usize, StorageError> {
        self.db.with_conn(|conn| {
            let count: usize = conn.query_row(
                "SELECT COUNT(*) FROM \"STATUS_DRAFTS\" WHERE \"UID\" = ?1;",
                params![uid],
                |r| r.get(0),
            )?;
            Ok(count)
        })
    }

    /// Deletes all drafts for a user UID.
    pub fn delete_all_by_uid(&self, uid: &str) -> Result<usize, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "DELETE FROM \"STATUS_DRAFTS\" WHERE \"UID\" = ?1;",
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
    fn test_draft_dao_lifecycle() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let dao = DraftDao::new(&db);

        let draft = StatusDraftEntity {
            content: "Hello Weibo from Rust!".to_string(),
            date: 1700000000,
            uid: "1001001".to_string(),
            status: 0,
            urls: Some("[\"/cache/p1.jpg\"]".to_string()),
            ..Default::default()
        };

        let id = dao.insert(&draft).unwrap();
        assert!(id > 0);

        let fetched = dao.get_by_id(id).unwrap().unwrap();
        assert_eq!(fetched.content, "Hello Weibo from Rust!");
        assert_eq!(fetched.status, 0);

        // Update status to sending (1)
        dao.update_status(id, 1).unwrap();
        let sending = dao.get_by_id(id).unwrap().unwrap();
        assert_eq!(sending.status, 1);

        // List by UID
        let drafts = dao.list_by_uid("1001001").unwrap();
        assert_eq!(drafts.len(), 1);

        // Delete
        assert!(dao.delete_by_id(id).unwrap());
        assert_eq!(dao.count_by_uid("1001001").unwrap(), 0);
    }
}
