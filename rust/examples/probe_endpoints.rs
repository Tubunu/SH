//! One-off probe: harvest the real `/ajax/...` endpoints from Weibo's own
//! front-end bundle, so the client never has to guess a path.
use regex::Regex;
use share_core::web::{api, client::WebClient};
use std::collections::BTreeSet;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let client = WebClient::new();
    let acct = api::guest_login(&client).await?;
    println!("guest={} uid={}", acct.screen_name, acct.uid);

    let mut js: BTreeSet<String> = BTreeSet::new();
    for page in ["https://weibo.com/at/weibo", "https://weibo.com/"] {
        if let Ok(html) = client.get_raw(page, "https://weibo.com/").await {
            let re = Regex::new(r#"https?://[a-zA-Z0-9./_-]+\.js"#).unwrap();
            for m in re.find_iter(&html) {
                js.insert(m.as_str().to_string());
            }
            println!("{page}: {} bytes, {} js", html.len(), js.len());
        }
    }

    let ep = Regex::new(r#"(?:ajax|webim|api)/[a-zA-Z0-9_/\-]+"#).unwrap();
    let mut found: BTreeSet<String> = BTreeSet::new();
    for url in js.iter() {
        match client.get_raw(url, "https://weibo.com/").await {
            Ok(body) => {
                for m in ep.find_iter(&body) {
                    found.insert(m.as_str().to_string());
                }
            }
            Err(e) => println!("skip {url}: {e}"),
        }
    }
    println!("---- {} endpoints ----", found.len());
    for e in &found {
        println!("{e}");
    }
    Ok(())
}
