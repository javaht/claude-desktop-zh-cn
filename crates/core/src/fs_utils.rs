//! 通用 IO 工具，无业务语义。
//!
//! 本模块提供项目所需的纯文件系统与数据处理基础函数：
//! - SHA-256 哈希
//! - 文件复制、目录删除
//! - JSON 读写（含 tmp 文件原子写入）
//! - 无效 JSON 的备份重建
//! - 时间戳生成
//!
//! **不感知 Claude Desktop 资源结构或语言包语义。**
//! 新增的纯 IO helper（不涉及项目特定路径、语言、JS bundle 等概念）应放在此处。
//!
//! 若涉及项目资源发现、语言包定位、JS 文件扫描等业务逻辑，请改放 `resources` 模块。

use crate::{
    error::Result,
    logging::{LogSink, LogSinkExt},
};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::{
    ffi::OsStr,
    fs,
    io::Write,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

pub fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

pub fn read_json(path: &Path) -> Result<Value> {
    let text = fs::read_to_string(path)?;
    Ok(serde_json::from_str(&text)?)
}

pub fn write_json(path: &Path, data: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!(
        "{}.tmp",
        path.extension().and_then(OsStr::to_str).unwrap_or("json")
    ));
    let mut file = fs::File::create(&tmp)?;
    serde_json::to_writer_pretty(&mut file, data)?;
    file.write_all(b"\n")?;
    fs::rename(tmp, path)?;
    Ok(())
}

pub fn load_json_object_or_backup(path: &Path, logger: &dyn LogSink) -> Result<Map<String, Value>> {
    if !path.exists() {
        return Ok(Map::new());
    }
    match read_json(path) {
        Ok(Value::Object(map)) => Ok(map),
        _ => {
            let backup = path.with_extension("json.bak-invalid");
            logger.warn(format!(
                "JSON 无效，已备份并重建: {} -> {}",
                path.display(),
                backup.display()
            ));
            let _ = fs::copy(path, backup);
            Ok(Map::new())
        }
    }
}

pub fn copy_file(src: &Path, dst: &Path) -> Result<()> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(src, dst)?;
    Ok(())
}

pub fn remove_path(path: &Path) -> Result<()> {
    if path.is_dir() && !path.is_symlink() {
        fs::remove_dir_all(path)?;
    } else if path.exists() || path.is_symlink() {
        fs::remove_file(path)?;
    }
    Ok(())
}

pub fn sha256_hex(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}
