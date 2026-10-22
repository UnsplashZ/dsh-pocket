//! 身份密钥的持久化。
//!
//! `--data-dir/identity.key` 里放的是 32 字节裸密钥（**与上游 sidecar 逐字节相同**，
//! 换二进制之后 endpoint_id 不会变，手机那边不用重新配对）。
//!
//! 这个文件丢了 = 这台电脑在手机眼里换了一个人：所有已配对设备全部失效，
//! 用户只能重新配对。所以写入必须是原子的（先写临时文件再 rename），
//! 且首次创建后立刻落盘。

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use iroh::SecretKey;

const IDENTITY_FILE: &str = "identity.key";

pub struct IdentityStore {
    secret_key: SecretKey,
}

impl IdentityStore {
    /// 打开（或初始化）data-dir 里的身份。
    pub fn open(data_dir: &Path) -> Result<Self> {
        fs::create_dir_all(data_dir)
            .with_context(|| format!("创建 data-dir 失败：{}", data_dir.display()))?;
        let path = data_dir.join(IDENTITY_FILE);
        let secret_key = match fs::read(&path) {
            Ok(bytes) => {
                let array: [u8; 32] = bytes.as_slice().try_into().with_context(|| {
                    format!("{} 不是 32 字节的密钥（读到 {} 字节）", path.display(), bytes.len())
                })?;
                SecretKey::from_bytes(&array)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let key = SecretKey::generate();
                write_atomic(&path, &key.to_bytes())?;
                key
            }
            Err(error) => {
                return Err(error).with_context(|| format!("读取 {} 失败", path.display()))
            }
        };
        Ok(Self { secret_key })
    }

    pub fn secret_key(&self) -> SecretKey {
        self.secret_key.clone()
    }

    /// 本机 endpoint id（64 位小写 hex）。手机配对串的前半段就是它。
    pub fn endpoint_id(&self) -> String {
        self.secret_key.public().to_string()
    }
}

/// 先写 `*.tmp` 再 rename：中途崩掉也不会留下半截密钥文件（那等于身份被毁）。
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp: PathBuf = path.with_extension("key.tmp");
    {
        let mut file = fs::File::create(&tmp)
            .with_context(|| format!("创建 {} 失败", tmp.display()))?;
        // 私钥：只有自己能读。
        let mut perms = file.metadata()?.permissions();
        perms.set_mode(0o600);
        file.set_permissions(perms)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)
        .with_context(|| format!("把 {} 落成 {} 失败", tmp.display(), path.display()))?;
    Ok(())
}
