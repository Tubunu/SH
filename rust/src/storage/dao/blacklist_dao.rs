//! Data Access Object for `BLACK_LIST` table.
//! Manages content filtering rules: user blocking, keyword filtering, and Weibo tail filtering.

use rusqlite::{params, Row};

use crate::storage::db::{DatabaseManager, StorageError};
use crate::storage::models::BlackListEntity;

pub struct BlackListDao<'a> {
    db: &'a DatabaseManager,
}

impl<'a> BlackListDao<'a> {
    pub fn new(db: &'a DatabaseManager) -> Self {
        Self { db }
    }

    fn row_to_entity(row: &Row) -> rusqlite::Result<BlackListEntity> {
        Ok(BlackListEntity {
            id: row.get(0)?,
            key: row.get(1)?,
            uid: row.get(2)?,
            info: row.get(3)?,
            type_: row.get(4)?,
            state: row.get(5)?,
            black_type: row.get(6)?,
        })
    }

    /// Adds a new blocking/filter rule.
    pub fn insert(&self, item: &BlackListEntity) -> Result<i64, StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO \"BLACK_LIST\" (\"KEY\", \"UID\", \"INFO\", \"TYPE\", \"STATE\", \"BLACK_TYPE\")
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
                params![
                    item.key,
                    item.uid,
                    item.info,
                    item.type_,
                    item.state,
                    item.black_type,
                ],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    /// Toggles active state of a filter rule.
    pub fn update_state(&self, id: i64, state: i32) -> Result<bool, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute(
                "UPDATE \"BLACK_LIST\" SET \"STATE\" = ?1 WHERE \"_id\" = ?2;",
                params![state, id],
            )?;
            Ok(affected > 0)
        })
    }

    /// Deletes a rule by ID.
    pub fn delete_by_id(&self, id: i64) -> Result<bool, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute("DELETE FROM \"BLACK_LIST\" WHERE \"_id\" = ?1;", params![id])?;
            Ok(affected > 0)
        })
    }

    /// Lists rules for a user, optionally filtered by type.
    pub fn list_by_uid(
        &self,
        uid: &str,
        rule_type: Option<i32>,
    ) -> Result<Vec<BlackListEntity>, StorageError> {
        self.db.with_conn(|conn| {
            if let Some(t) = rule_type {
                let mut stmt = conn.prepare(
                    "SELECT \"_id\", \"KEY\", \"UID\", \"INFO\", \"TYPE\", \"STATE\", \"BLACK_TYPE\"
                     FROM \"BLACK_LIST\"
                     WHERE \"UID\" = ?1 AND \"TYPE\" = ?2
                     ORDER BY \"_id\" DESC;",
                )?;
                let iter = stmt.query_map(params![uid, t], |row| Self::row_to_entity(row))?;
                let mut list = Vec::new();
                for item in iter {
                    list.push(item?);
                }
                Ok(list)
            } else {
                let mut stmt = conn.prepare(
                    "SELECT \"_id\", \"KEY\", \"UID\", \"INFO\", \"TYPE\", \"STATE\", \"BLACK_TYPE\"
                     FROM \"BLACK_LIST\"
                     WHERE \"UID\" = ?1
                     ORDER BY \"_id\" DESC;",
                )?;
                let iter = stmt.query_map(params![uid], |row| Self::row_to_entity(row))?;
                let mut list = Vec::new();
                for item in iter {
                    list.push(item?);
                }
                Ok(list)
            }
        })
    }

    /// Checks if a target user UID is blocked.
    pub fn is_blocked_user(
        &self,
        uid: &str,
        target_uid: &str,
    ) -> Result<Option<BlackListEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"KEY\", \"UID\", \"INFO\", \"TYPE\", \"STATE\", \"BLACK_TYPE\"
                 FROM \"BLACK_LIST\"
                 WHERE \"UID\" = ?1 AND \"TYPE\" = 0 AND \"STATE\" = 1 AND \"KEY\" = ?2
                 LIMIT 1;",
            )?;
            let mut rows = stmt.query(params![uid, target_uid])?;
            if let Some(row) = rows.next()? {
                Ok(Some(Self::row_to_entity(row)?))
            } else {
                Ok(None)
            }
        })
    }

    /// Checks if content matches any active keyword filter rules.
    pub fn matches_keywords(
        &self,
        uid: &str,
        text: &str,
    ) -> Result<Option<BlackListEntity>, StorageError> {
        let rules = self.list_by_uid(uid, Some(1))?;
        for r in rules {
            if r.state == 1 && !r.key.is_empty() && text.contains(&r.key) {
                return Ok(Some(r));
            }
        }
        Ok(None)
    }

    /// Checks if a Weibo source tail string is blocked.
    pub fn is_blocked_source(
        &self,
        uid: &str,
        source: &str,
    ) -> Result<Option<BlackListEntity>, StorageError> {
        let rules = self.list_by_uid(uid, Some(2))?;
        for r in rules {
            if r.state == 1 && !r.key.is_empty() && source.contains(&r.key) {
                return Ok(Some(r));
            }
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_blacklist_filters() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let dao = BlackListDao::new(&db);

        // Add user block
        dao.insert(&BlackListEntity {
            key: "blocked_uid_999".to_string(),
            uid: "1001001".to_string(),
            type_: 0,
            state: 1,
            black_type: 1,
            ..Default::default()
        })
        .unwrap();

        assert!(dao.is_blocked_user("1001001", "blocked_uid_999").unwrap().is_some());
        assert!(dao.is_blocked_user("1001001", "safe_uid_111").unwrap().is_none());

        // Add keyword filter
        dao.insert(&BlackListEntity {
            key: "垃圾广告".to_string(),
            uid: "1001001".to_string(),
            type_: 1,
            state: 1,
            black_type: 1,
            ..Default::default()
        })
        .unwrap();

        let matched = dao.matches_keywords("1001001", "这是一条垃圾广告微博").unwrap();
        assert!(matched.is_some());
        assert_eq!(matched.unwrap().key, "垃圾广告");

        let clean = dao.matches_keywords("1001001", "这是正常内容").unwrap();
        assert!(clean.is_none());
    }
}
