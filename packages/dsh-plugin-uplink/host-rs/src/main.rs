//! DSH tether host —— 电脑侧 iroh endpoint（DLP v1），对插件说 JSON-lines stdio。
//!
//! 这个文件此刻只做第一步：把身份从 `--data-dir` 读出来（或建出来）、bind 一个
//! iroh endpoint，并把 `ready{endpoint_id}` 打到 stdout。控制面 / 代理流 / selftest
//! 在后续步骤里补。
//!
//! 纪律：**stdout 只许 JSON-lines**（插件按行 JSON.parse，混进一行人话就断），
//! 人读日志一律走 stderr。

mod identity;

use std::io::Write;

use anyhow::{Context, Result};
use iroh::endpoint::presets;
use iroh::Endpoint;

/// DLP v1 的 ALPN。与手机端 `TetherWire.alpn` 必须逐字节一致。
const ALPN: &[u8] = b"dsh-tether/0";

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse()?;
    let _ = cli;

    let store = identity::IdentityStore::open(&cli.data_dir)
        .with_context(|| format!("打开 data-dir 失败：{}", cli.data_dir.display()))?;

    let endpoint = Endpoint::builder(presets::N0)
        .secret_key(store.secret_key())
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await
        .context("bind iroh endpoint 失败")?;

    let endpoint_id = endpoint.id().to_string();
    log(&format!("endpoint 已就绪：{endpoint_id}"));
    emit(&format!(
        r#"{{"type":"ready","endpoint_id":"{endpoint_id}"}}"#
    ));

    // 第一步只验证"能 bind、身份能持久化、stdout 能出 ready"。
    // 一直挂着好让外部观察进程（Ctrl-C 退出）。
    tokio::signal::ctrl_c().await.ok();
    endpoint.close().await;
    Ok(())
}

/// 人读日志 → stderr。stdout 是协议通道，一个字都不能挪过去。
fn log(message: &str) {
    eprintln!("[host] {message}");
}

/// 协议通道：一行 JSON + `\n`，写完立刻 flush（插件按行读，缓冲会让它干等）。
fn emit(line: &str) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

struct Cli {
    proxy_target: Option<String>,
    lang: String,
    data_dir: std::path::PathBuf,
}

impl Cli {
    fn parse() -> Result<Self> {
        let mut args = std::env::args().skip(1);
        let mut proxy_target = None;
        let mut lang = "zh".to_string();
        let mut data_dir = default_data_dir();

        // 第一个位置参数是子命令（host / selftest 之类），这一步只认 host。
        match args.next().as_deref() {
            Some("host") => {}
            Some(other) => anyhow::bail!("未知子命令：{other}"),
            None => anyhow::bail!("缺少子命令（host）"),
        }

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--proxy-target" => {
                    proxy_target = Some(args.next().context("--proxy-target 缺少取值")?)
                }
                "--lang" => lang = args.next().context("--lang 缺少取值")?,
                "--data-dir" => {
                    data_dir = std::path::PathBuf::from(args.next().context("--data-dir 缺少取值")?)
                }
                other => anyhow::bail!("未知参数：{other}"),
            }
        }

        Ok(Self {
            proxy_target,
            lang,
            data_dir,
        })
    }
}

/// 与上游 sidecar 保持同一个默认落点，换二进制之后身份不会变。
fn default_data_dir() -> std::path::PathBuf {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default();
    home.join(".dsh").join("tether")
}
