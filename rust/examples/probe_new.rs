use share_core::web::{api, client::WebClient};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let c = WebClient::new();
    api::guest_login(&c).await?;

    for (name, gid) in [("全部关注", "1000123456789"), ("好友圈", "1100012345678"), ("分组", "2000012345678")] {
        match api::feed_timeline(&c, gid, None, None, 5).await {
            Ok(js) => {
                let v: serde_json::Value = serde_json::from_str(&js).unwrap_or_default();
                let n = v.get("statuses").and_then(|s| s.as_array()).map(|a| a.len()).unwrap_or(0);
                println!("{name}: ok statuses={n} keys={:?}", v.as_object().map(|o| o.keys().take(6).cloned().collect::<Vec<_>>()));
            }
            Err(e) => println!("{name}: ERR {e}"),
        }
    }

    println!("--- translate ---");
    match api::translate_status(&c, "Rph1TsL3e", "zh").await {
        Ok(js) => println!("{}", &js[..js.len().min(240)]),
        Err(e) => println!("ERR {e}"),
    }
    println!("--- edit history ---");
    match api::edit_history(&c, "Rph1TsL3e", 1).await {
        Ok(js) => println!("{}", &js[..js.len().min(240)]),
        Err(e) => println!("ERR {e}"),
    }
    println!("--- delete (should be rejected) ---");
    match api::delete_status(&c, "Rph1TsL3e").await {
        Ok(_) => println!("unexpected ok"),
        Err(e) => println!("ERR {e}"),
    }
    println!("--- like (should be rejected) ---");
    match api::like(&c, "Rph1TsL3e", false).await {
        Ok(_) => println!("unexpected ok"),
        Err(e) => println!("ERR {e}"),
    }
    Ok(())
}
