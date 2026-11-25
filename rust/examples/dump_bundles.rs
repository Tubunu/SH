//! Saves Weibo's own JS bundles so endpoint call-sites (and their params) can
//! be grepped locally instead of guessed.
use regex::Regex;
use share_core::web::{api, client::WebClient};
use std::collections::BTreeSet;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    std::fs::create_dir_all("../audit/js")?;
    let client = WebClient::new();
    api::guest_login(&client).await?;
    let mut js: BTreeSet<String> = BTreeSet::new();
    for page in ["https://weibo.com/at/weibo", "https://weibo.com/"] {
        if let Ok(html) = client.get_raw(page, "https://weibo.com/").await {
            let re = Regex::new(r#"https?://[a-zA-Z0-9./_-]+\.js"#).unwrap();
            for m in re.find_iter(&html) {
                js.insert(m.as_str().to_string());
            }
        }
    }
    for (i, url) in js.iter().enumerate() {
        if let Ok(body) = client.get_raw(url, "https://weibo.com/").await {
            let name = url.rsplit('/').next().unwrap_or("x.js");
            std::fs::write(format!("../audit/js/{i:03}_{name}"), body)?;
        }
    }
    println!("saved {}", js.len());
    Ok(())
}
