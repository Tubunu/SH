//! Data Access Object for `USER` table.
//! Supports multi-account CRUD, Token/Cookie persistence, and profile sync.

use rusqlite::{params, Row};

use crate::storage::db::{DatabaseManager, StorageError};
use crate::storage::models::UserEntity;

pub struct UserDao<'a> {
    db: &'a DatabaseManager,
}

impl<'a> UserDao<'a> {
    pub fn new(db: &'a DatabaseManager) -> Self {
        Self { db }
    }

    fn row_to_entity(row: &Row) -> rusqlite::Result<UserEntity> {
        Ok(UserEntity {
            id: row.get(0)?,
            uid: row.get(1)?,
            token: row.get(2)?,
            parent_type: row.get(3)?,
            gsid: row.get(4)?,
            s_value: row.get(5)?,
            i_value: row.get(6)?,
            parent_json: row.get(7)?,
            refresh_token: row.get(8)?,
            expires_in: row.get(9)?,
            name: row.get(10)?,
            avatar: row.get(11)?,
            gender: row.get(12)?,
            sign: row.get(13)?,
            cover: row.get(14)?,
            account: row.get(15)?,
            password: row.get(16)?,
            ad_token: row.get(17)?,
            cookie: row.get(18)?,
            extra: row.get(19)?,
        })
    }

    /// Inserts or replaces a user account by UID.
    pub fn insert_or_replace(&self, user: &UserEntity) -> Result<i64, StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO \"USER\" (
                    \"UID\", \"TOKEN\", \"PARENT_TYPE\", \"GSID\", \"S_VALUE\", \"I_VALUE\",
                    \"PARENT_JSON\", \"REFRESH_TOKEN\", \"EXPIRES_IN\", \"NAME\", \"AVATAR\",
                    \"GENDER\", \"SIGN\", \"COVER\", \"ACCOUNT\", \"PASSWORD\", \"AD_TOKEN\",
                    \"COOKIE\", \"EXTRA\"
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
                ON CONFLICT(\"UID\") DO UPDATE SET
                    \"TOKEN\" = excluded.\"TOKEN\",
                    \"PARENT_TYPE\" = excluded.\"PARENT_TYPE\",
                    \"GSID\" = COALESCE(excluded.\"GSID\", \"USER\".\"GSID\"),
                    \"S_VALUE\" = COALESCE(excluded.\"S_VALUE\", \"USER\".\"S_VALUE\"),
                    \"I_VALUE\" = COALESCE(excluded.\"I_VALUE\", \"USER\".\"I_VALUE\"),
                    \"PARENT_JSON\" = COALESCE(excluded.\"PARENT_JSON\", \"USER\".\"PARENT_JSON\"),
                    \"REFRESH_TOKEN\" = COALESCE(excluded.\"REFRESH_TOKEN\", \"USER\".\"REFRESH_TOKEN\"),
                    \"EXPIRES_IN\" = COALESCE(excluded.\"EXPIRES_IN\", \"USER\".\"EXPIRES_IN\"),
                    \"NAME\" = COALESCE(excluded.\"NAME\", \"USER\".\"NAME\"),
                    \"AVATAR\" = COALESCE(excluded.\"AVATAR\", \"USER\".\"AVATAR\"),
                    \"GENDER\" = COALESCE(excluded.\"GENDER\", \"USER\".\"GENDER\"),
                    \"SIGN\" = COALESCE(excluded.\"SIGN\", \"USER\".\"SIGN\"),
                    \"COVER\" = COALESCE(excluded.\"COVER\", \"USER\".\"COVER\"),
                    \"ACCOUNT\" = COALESCE(excluded.\"ACCOUNT\", \"USER\".\"ACCOUNT\"),
                    \"PASSWORD\" = COALESCE(excluded.\"PASSWORD\", \"USER\".\"PASSWORD\"),
                    \"AD_TOKEN\" = COALESCE(excluded.\"AD_TOKEN\", \"USER\".\"AD_TOKEN\"),
                    \"COOKIE\" = COALESCE(excluded.\"COOKIE\", \"USER\".\"COOKIE\"),
                    \"EXTRA\" = COALESCE(excluded.\"EXTRA\", \"USER\".\"EXTRA\");",
                params![
                    user.uid,
                    user.token,
                    user.parent_type,
                    user.gsid,
                    user.s_value,
                    user.i_value,
                    user.parent_json,
                    user.refresh_token,
                    user.expires_in,
                    user.name,
                    user.avatar,
                    user.gender,
                    user.sign,
                    user.cover,
                    user.account,
                    user.password,
                    user.ad_token,
                    user.cookie,
                    user.extra,
                ],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    /// Queries user by UID.
    pub fn get_by_uid(&self, uid: &str) -> Result<Option<UserEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"UID\", \"TOKEN\", \"PARENT_TYPE\", \"GSID\", \"S_VALUE\", \"I_VALUE\",
                        \"PARENT_JSON\", \"REFRESH_TOKEN\", \"EXPIRES_IN\", \"NAME\", \"AVATAR\",
                        \"GENDER\", \"SIGN\", \"COVER\", \"ACCOUNT\", \"PASSWORD\", \"AD_TOKEN\",
                        \"COOKIE\", \"EXTRA\"
                 FROM \"USER\" WHERE \"UID\" = ?1 LIMIT 1;",
            )?;
            let mut rows = stmt.query(params![uid])?;
            if let Some(row) = rows.next()? {
                Ok(Some(Self::row_to_entity(row)?))
            } else {
                Ok(None)
            }
        })
    }

    /// Retrieves all user accounts.
    pub fn get_all(&self) -> Result<Vec<UserEntity>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT \"_id\", \"UID\", \"TOKEN\", \"PARENT_TYPE\", \"GSID\", \"S_VALUE\", \"I_VALUE\",
                        \"PARENT_JSON\", \"REFRESH_TOKEN\", \"EXPIRES_IN\", \"NAME\", \"AVATAR\",
                        \"GENDER\", \"SIGN\", \"COVER\", \"ACCOUNT\", \"PASSWORD\", \"AD_TOKEN\",
                        \"COOKIE\", \"EXTRA\"
                 FROM \"USER\" ORDER BY \"_id\" ASC;",
            )?;
            let iter = stmt.query_map([], |row| Self::row_to_entity(row))?;
            let mut users = Vec::new();
            for user in iter {
                users.push(user?);
            }
            Ok(users)
        })
    }

    /// Deletes user by UID.
    pub fn delete_by_uid(&self, uid: &str) -> Result<bool, StorageError> {
        self.db.with_conn(|conn| {
            let affected = conn.execute("DELETE FROM \"USER\" WHERE \"UID\" = ?1;", params![uid])?;
            Ok(affected > 0)
        })
    }

    /// Updates Token and expiration.
    pub fn update_tokens(
        &self,
        uid: &str,
        token: &str,
        refresh_token: Option<&str>,
        expires_in: Option<i64>,
    ) -> Result<(), StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "UPDATE \"USER\" SET \"TOKEN\" = ?1, \"REFRESH_TOKEN\" = ?2, \"EXPIRES_IN\" = ?3 WHERE \"UID\" = ?4;",
                params![token, refresh_token, expires_in, uid],
            )?;
            Ok(())
        })
    }

    /// Updates Cookie string (e.g. SUB / SUBP).
    pub fn update_cookies(&self, uid: &str, cookie: &str) -> Result<(), StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "UPDATE \"USER\" SET \"COOKIE\" = ?1 WHERE \"UID\" = ?2;",
                params![cookie, uid],
            )?;
            Ok(())
        })
    }

    /// Returns account count.
    pub fn count(&self) -> Result<usize, StorageError> {
        self.db.with_conn(|conn| {
            let count: usize = conn.query_row("SELECT COUNT(*) FROM \"USER\";", [], |r| r.get(0))?;
            Ok(count)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_user_dao_crud() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let dao = UserDao::new(&db);

        assert_eq!(dao.count().unwrap(), 0);

        let user1 = UserEntity {
            uid: "1001001".to_string(),
            token: "token_abc".to_string(),
            parent_type: 0,
            name: Some("User 1".to_string()),
            ..Default::default()
        };
        dao.insert_or_replace(&user1).unwrap();
        assert_eq!(dao.count().unwrap(), 1);

        let fetched = dao.get_by_uid("1001001").unwrap().unwrap();
        assert_eq!(fetched.name.as_deref(), Some("User 1"));
        assert_eq!(fetched.token, "token_abc");

        // Update tokens
        dao.update_tokens("1001001", "token_new", Some("refresh_123"), Some(99999999))
            .unwrap();
        let updated = dao.get_by_uid("1001001").unwrap().unwrap();
        assert_eq!(updated.token, "token_new");
        assert_eq!(updated.refresh_token.as_deref(), Some("refresh_123"));

        // Delete
        assert!(dao.delete_by_uid("1001001").unwrap());
        assert_eq!(dao.count().unwrap(), 0);
    }
}
