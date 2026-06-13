use serde_json::{json, Map, Value};
use std::{fs, path::{Path, PathBuf}};

use super::{err, sha256_hex, ASAR_PATCH_TARGET};
use crate::{CoreError, Result};

const ASAR_BLOCK_SIZE: usize = 4 * 1024 * 1024;

fn align4(value: usize) -> Option<usize> {
    let remainder = (4 - (value % 4)) % 4;
    value.checked_add(remainder)
}

#[derive(Clone, Debug)]
pub struct AsarArchive {
    path: PathBuf,
    data: Vec<u8>,
    header_size: usize,
    header: Value,
}

impl AsarArchive {
    pub fn open(path: &Path) -> Result<Self> {
        let data = fs::read(path)?;
        Self::from_data(path.to_path_buf(), data)
    }

    pub fn from_data(path: PathBuf, data: Vec<u8>) -> Result<Self> {
        if data.len() < 16 {
            return err(format!("Unsupported app.asar header: {}", path.display()));
        }
        let size_pickle = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
        let header_size = u32::from_le_bytes(data[4..8].try_into().unwrap()) as usize;
        if size_pickle != 4 || header_size == 0 || data.len() < 8 + header_size {
            return err(format!(
                "Unsupported app.asar size pickle: {}",
                path.display()
            ));
        }
        let header_pickle = &data[8..8 + header_size];
        let payload_size = u32::from_le_bytes(header_pickle[0..4].try_into().unwrap()) as usize;
        let raw_string_size = i32::from_le_bytes(header_pickle[4..8].try_into().unwrap());
        if raw_string_size < 0 {
            return err(format!(
                "app.asar header string_size 为负数: {raw_string_size}"
            ));
        }
        // 安全：raw_string_size 已在上方检查 >= 0，非负 i32 合法转 usize
        let string_size = raw_string_size as usize;
        let expected_payload_size = align4(
            4usize
                .checked_add(string_size)
                .ok_or_else(|| CoreError::Message("app.asar payload_size 溢出".to_string()))?,
        )
        .ok_or_else(|| CoreError::Message("app.asar align4 溢出".to_string()))?;
        let expected_pickle_size = 4usize
            .checked_add(expected_payload_size)
            .ok_or_else(|| CoreError::Message("app.asar pickle_size 溢出".to_string()))?;
        if payload_size != expected_payload_size || header_size != expected_pickle_size {
            return err(format!(
                "Unsupported app.asar header pickle: {}",
                path.display()
            ));
        }
        let header_string = std::str::from_utf8(&header_pickle[8..8 + string_size])
            .map_err(|e| CoreError::Message(e.to_string()))?;
        let header: Value = serde_json::from_str(header_string)?;
        Ok(Self {
            path,
            data,
            header_size,
            header,
        })
    }

    pub fn header_string(&self) -> Result<String> {
        Ok(serde_json::to_string(&self.header)?)
    }

    fn get_entry_mut<'a>(
        node: &'a mut Value,
        file_path: &str,
    ) -> Result<&'a mut Map<String, Value>> {
        let mut current = node;
        for part in file_path.split('/') {
            current = current
                .get_mut("files")
                .and_then(Value::as_object_mut)
                .and_then(|files| files.get_mut(part))
                .ok_or_else(|| CoreError::Message(format!("app.asar 中找不到 {file_path}")))?;
        }
        current
            .as_object_mut()
            .ok_or_else(|| CoreError::Message(format!("app.asar entry 格式无效: {file_path}")))
    }

    fn get_entry<'a>(node: &'a Value, file_path: &str) -> Result<&'a Map<String, Value>> {
        let mut current = node;
        for part in file_path.split('/') {
            current = current
                .get("files")
                .and_then(Value::as_object)
                .and_then(|files| files.get(part))
                .ok_or_else(|| CoreError::Message(format!("app.asar 中找不到 {file_path}")))?;
        }
        current
            .as_object()
            .ok_or_else(|| CoreError::Message(format!("app.asar entry 格式无效: {file_path}")))
    }

    fn entry_bounds(&self, file_path: &str) -> Result<(usize, usize, usize)> {
        let entry = Self::get_entry(&self.header, file_path)?;
        let offset = entry_value_usize(entry, "offset")?;
        let size = entry_value_usize(entry, "size")?;
        let start = 8usize
            .checked_add(self.header_size)
            .and_then(|base| base.checked_add(offset))
            .ok_or_else(|| {
                CoreError::Message(format!("app.asar offset 溢出: {file_path}"))
            })?;
        let end = start
            .checked_add(size)
            .ok_or_else(|| CoreError::Message(format!("app.asar size 溢出: {file_path}")))?;
        if end > self.data.len() {
            return err(format!("app.asar bounds 无效: {file_path}"));
        }
        Ok((offset, start, end))
    }

    pub fn read_text(&self, file_path: &str) -> Result<String> {
        let (_, start, end) = self.entry_bounds(file_path)?;
        String::from_utf8(self.data[start..end].to_vec())
            .map_err(|e| CoreError::Message(e.to_string()))
    }

    pub fn replace_file(&mut self, file_path: &str, patched: &[u8]) -> Result<bool> {
        let (target_offset, start, end) = self.entry_bounds(file_path)?;
        if self.data[start..end] == *patched {
            return Ok(false);
        }
        let old_size = end - start;
        self.data.splice(start..end, patched.iter().copied());
        let delta = patched.len() as isize - old_size as isize;
        {
            let entry = Self::get_entry_mut(&mut self.header, file_path)?;
            entry.insert("size".to_string(), json!(patched.len()));
            entry.insert("integrity".to_string(), file_integrity(patched));
        }
        if delta != 0 {
            shift_offsets(&mut self.header, target_offset, delta)?;
        }
        Ok(true)
    }

    pub fn save(&self) -> Result<String> {
        let header_string = serde_json::to_string(&self.header)?;
        let header = encode_asar_header_dynamic(&header_string)?;
        let body = &self.data[8 + self.header_size..];
        let mut out = header;
        out.extend_from_slice(body);
        fs::write(&self.path, out)?;
        Ok(header_string)
    }
}

fn entry_value_usize(entry: &Map<String, Value>, key: &str) -> Result<usize> {
    let value = entry
        .get(key)
        .ok_or_else(|| CoreError::Message(format!("asar entry 缺少 {key}")))?;
    if let Some(num) = value.as_u64() {
        Ok(num as usize)
    } else if let Some(text) = value.as_str() {
        text.parse::<usize>()
            .map_err(|e| CoreError::Message(format!("asar entry {key} 无效: {e}")))
    } else {
        err(format!("asar entry {key} 类型无效"))
    }
}

fn set_entry_offset(entry: &mut Map<String, Value>, offset: usize) {
    let as_string = entry.get("offset").is_some_and(Value::is_string);
    entry.insert(
        "offset".to_string(),
        if as_string {
            Value::String(offset.to_string())
        } else {
            json!(offset)
        },
    );
}

fn shift_offsets(node: &mut Value, target_offset: usize, delta: isize) -> Result<()> {
    let Some(files) = node.get_mut("files").and_then(Value::as_object_mut) else {
        return Ok(());
    };
    for child in files.values_mut() {
        if child.get("files").is_some() {
            shift_offsets(child, target_offset, delta)?;
        } else if let Some(entry) = child.as_object_mut() {
            if entry.contains_key("offset") && entry.contains_key("size") {
                let offset = entry_value_usize(entry, "offset")?;
                if offset > target_offset {
                    let new_offset = (offset as i64)
                        .checked_add(delta as i64)
                        .ok_or_else(|| {
                            CoreError::Message("app.asar offset 调整溢出".to_string())
                        })?;
                    if new_offset < 0 {
                        return err("app.asar offset 调整后为负数".to_string());
                    }
                    set_entry_offset(entry, new_offset as usize);
                }
            }
        }
    }
    Ok(())
}

fn file_integrity(data: &[u8]) -> Value {
    let mut blocks: Vec<Value> = data
        .chunks(ASAR_BLOCK_SIZE)
        .map(|chunk| Value::String(sha256_hex(chunk)))
        .collect();
    if blocks.is_empty() {
        blocks.push(Value::String(sha256_hex(data)));
    }
    json!({
        "algorithm": "SHA256",
        "hash": sha256_hex(data),
        "blockSize": ASAR_BLOCK_SIZE,
        "blocks": blocks
    })
}

pub fn encode_asar_header_dynamic(header_string: &str) -> Result<Vec<u8>> {
    let header_bytes = header_string.as_bytes();
    let payload_size = align4(4 + header_bytes.len()).expect("header payload 超出限制");
    let pickle_size = 4 + payload_size;
    let mut out = Vec::with_capacity(8 + pickle_size);
    out.extend_from_slice(&(4u32).to_le_bytes());
    out.extend_from_slice(
        &u32::try_from(pickle_size)
            .map_err(|_| CoreError::Message(format!("asar pickle_size {} 超过 u32::MAX", pickle_size)))?
            .to_le_bytes(),
    );
    out.extend_from_slice(
        &u32::try_from(payload_size)
            .map_err(|_| CoreError::Message(format!("asar payload_size {} 超过 u32::MAX", payload_size)))?
            .to_le_bytes(),
    );
    out.extend_from_slice(
        &i32::try_from(header_bytes.len())
            .map_err(|_| CoreError::Message(format!("asar header 长度 {} 超过 i32::MAX", header_bytes.len())))?
            .to_le_bytes(),
    );
    out.extend_from_slice(header_bytes);
    out.resize(8 + pickle_size, 0);
    Ok(out)
}

pub fn update_macos_asar_integrity(app_path: &Path, header_string: &str) -> Result<()> {
    let info_plist = app_path.join("Contents/Info.plist");
    if !info_plist.is_file() {
        return Ok(());
    }
    let mut value = plist::Value::from_file(&info_plist)?;
    if let Some(dict) = value.as_dictionary_mut() {
        if let Some(integrity) = dict
            .get_mut("ElectronAsarIntegrity")
            .and_then(plist::Value::as_dictionary_mut)
        {
            if let Some(app_asar) = integrity
                .get_mut("Resources/app.asar")
                .and_then(plist::Value::as_dictionary_mut)
            {
                app_asar.insert(
                    "hash".to_string(),
                    plist::Value::String(sha256_hex(header_string.as_bytes())),
                );
            }
        }
    }
    value.to_file_xml(info_plist)?;
    Ok(())
}

pub fn patch_asar_text(
    asar_path: &Path,
    app_root: Option<&Path>,
    patcher: impl FnOnce(String) -> Result<Option<String>>,
) -> Result<bool> {
    let mut asar = AsarArchive::open(asar_path)?;
    let text = asar.read_text(ASAR_PATCH_TARGET)?;
    let Some(patched) = patcher(text)? else {
        return Ok(false);
    };
    if !asar.replace_file(ASAR_PATCH_TARGET, patched.as_bytes())? {
        return Ok(false);
    }
    let header_string = asar.save()?;
    if let Some(app_root) = app_root {
        update_macos_asar_integrity(app_root, &header_string)?;
    }
    Ok(true)
}

pub fn asar_header_hash(path: &Path) -> Result<String> {
    let asar = AsarArchive::open(path)?;
    Ok(sha256_hex(asar.header_string()?.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asar_header_round_trip_encodes_parseable_header() {
        let header = r#"{"files":{"a.txt":{"offset":"0","size":3}}}"#;
        let encoded = encode_asar_header_dynamic(header).unwrap();
        assert_eq!(&encoded[0..4], &(4u32).to_le_bytes());
        let header_size = u32::from_le_bytes(encoded[4..8].try_into().unwrap()) as usize;
        assert_eq!(encoded.len(), 8 + header_size);
    }

    // ── asar 整数安全测试 ──────────────────────────────────────────────

    /// 构造一个合法的最小 asar 二进制数据。
    /// 返回 (data, header_string)。
    fn make_asar_data(header_json: &str) -> Vec<u8> {
        let header_bytes = header_json.as_bytes();
        let string_size = header_bytes.len();
        let payload_size = align4(4 + string_size).unwrap();
        let pickle_size = 4 + payload_size;

        let mut data = Vec::new();
        data.extend_from_slice(&4u32.to_le_bytes());
        data.extend_from_slice(&u32::try_from(pickle_size).unwrap().to_le_bytes());
        data.extend_from_slice(&u32::try_from(payload_size).unwrap().to_le_bytes());
        data.extend_from_slice(&i32::try_from(string_size).unwrap().to_le_bytes());
        data.extend_from_slice(header_bytes);
        data.resize(8 + pickle_size, 0);
        data
    }

    #[test]
    fn asar_data_too_short_returns_error() {
        // 不足 16 字节
        let err = AsarArchive::from_data("test.asar".into(), vec![0u8; 10]).unwrap_err();
        assert!(err.to_string().contains("Unsupported app.asar header"));
    }

    #[test]
    fn asar_negative_string_size_returns_error() {
        // header_size = 8 (enough for payload_size + string_size)
        // payload_size = 0, string_size = -1
        let mut data = Vec::new();
        data.extend_from_slice(&4u32.to_le_bytes());        // size_pickle = 4
        data.extend_from_slice(&8u32.to_le_bytes());        // header_size = 8
        data.extend_from_slice(&0u32.to_le_bytes());        // payload_size = 0
        data.extend_from_slice(&(-1i32).to_le_bytes());     // string_size = -1
        data.resize(24, 0); // ensure data.len() >= 8 + header_size

        let err = AsarArchive::from_data("test.asar".into(), data).unwrap_err();
        assert!(err.to_string().contains("string_size 为负数"));
    }

    #[test]
    fn asar_header_size_overflow_returns_error() {
        // header_size = usize::MAX → 8 + header_size 溢出
        let mut data = vec![0u8; 20];
        data[0..4].copy_from_slice(&4u32.to_le_bytes());
        data[4..8].copy_from_slice(&u32::MAX.to_le_bytes()); // header_size = 4294967295

        let err = AsarArchive::from_data("test.asar".into(), data).unwrap_err();
        // 应被 data.len() < 8 + header_size 或溢出检查拦截
        assert!(err.to_string().contains("Unsupported app.asar"));
    }

    #[test]
    fn asar_payload_size_mismatch_returns_error() {
        // 手工构造 payload_size 错误的 header
        let header_json = r#"{"files":{}}"#;
        let string_size = header_json.len(); // 12
        let correct_payload = align4(4 + string_size).unwrap(); // 16

        let mut data = Vec::new();
        data.extend_from_slice(&4u32.to_le_bytes());
        data.extend_from_slice(&(4 + u32::try_from(correct_payload).unwrap()).to_le_bytes()); // header_size 正确
        data.extend_from_slice(&(u32::try_from(correct_payload).unwrap() + 8).to_le_bytes()); // payload_size 故意错误
        data.extend_from_slice(&i32::try_from(string_size).unwrap().to_le_bytes());
        data.extend_from_slice(header_json.as_bytes());
        data.resize(8 + 4 + correct_payload, 0);

        let err = AsarArchive::from_data("test.asar".into(), data).unwrap_err();
        assert!(err.to_string().contains("Unsupported app.asar header pickle"));
    }

    #[test]
    fn asar_entry_offset_exceeds_data_returns_error() {
        let header_json =
            r#"{"files":{"a.txt":{"offset":"999999","size":10}}}"#;
        let data = make_asar_data(header_json);

        let asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        let err = asar.read_text("a.txt").unwrap_err();
        assert!(err.to_string().contains("bounds 无效"));
    }

    #[test]
    fn asar_entry_size_exceeds_data_returns_error() {
        let header_json =
            r#"{"files":{"a.txt":{"offset":"0","size":999999}}}"#;
        let data = make_asar_data(header_json);

        let asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        let err = asar.read_text("a.txt").unwrap_err();
        assert!(err.to_string().contains("bounds 无效"));
    }

    #[test]
    fn asar_normal_file_roundtrip_works() {
        let body = b"hello world";
        let header_json = format!(
            r#"{{"files":{{"a.txt":{{"offset":"0","size":{}}}}}}}"#,
            body.len()
        );
        let mut data = make_asar_data(&header_json);
        data.extend_from_slice(body);

        let asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        assert_eq!(asar.read_text("a.txt").unwrap(), "hello world");
    }

    #[test]
    fn asar_replace_file_and_save_roundtrip() {
        let body = b"hello";
        let header_json = format!(
            r#"{{"files":{{"a.txt":{{"offset":"0","size":{}}}}}}}"#,
            body.len()
        );
        let mut data = make_asar_data(&header_json);
        data.extend_from_slice(body);

        let mut asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        assert!(asar.replace_file("a.txt", b"new content!").unwrap());
        assert_eq!(asar.read_text("a.txt").unwrap(), "new content!");
    }

    #[test]
    fn asar_shift_offsets_with_negative_delta_works() {
        let body_a = b"aaa";
        let body_b = b"bbbbb";
        let header_json = format!(
            r#"{{"files":{{"a.txt":{{"offset":"0","size":{}}},"b.txt":{{"offset":"3","size":{}}}}}}}"#,
            body_a.len(),
            body_b.len()
        );
        let mut data = make_asar_data(&header_json);
        data.extend_from_slice(body_a);
        data.extend_from_slice(body_b);

        let mut asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        // 替换 a.txt 为更短的内容 → delta 为负
        assert!(asar.replace_file("a.txt", b"x").unwrap());
        // b.txt 应该仍然可读
        assert_eq!(asar.read_text("b.txt").unwrap(), "bbbbb");
    }

    // ── align4 整数安全测试 ──────────────────────────────────────────────

    #[test]
    fn align4_returns_none_on_overflow() {
        // 接近 usize::MAX 时 +3 溢出
        assert!(align4(usize::MAX).is_none());
        assert!(align4(usize::MAX - 1).is_none());
        assert!(align4(usize::MAX - 2).is_none());
        assert_eq!(align4(usize::MAX - 3), Some(usize::MAX - 3));
    }

    #[test]
    fn align4_aligns_correctly() {
        assert_eq!(align4(0), Some(0));
        assert_eq!(align4(1), Some(4));
        assert_eq!(align4(4), Some(4));
        assert_eq!(align4(5), Some(8));
    }
}
