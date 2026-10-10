//! Only expose known error fields, never arbitrary response or pairing dictionaries.
use idevice::{core_device::CoreDeviceError, IdeviceError};

fn quoted(input: &str) -> Option<String> {
    let mut chars = input.strip_prefix('"')?.chars();
    let mut value = String::new();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(value),
            '\\' => value.push(match chars.next()? {
                'n' | 'r' | 't' => ' ',
                '\\' => '\\', '"' => '"',
                // Fail closed on unrecognized escapes rather than dumping the response.
                _ => return None,
            }),
            c => value.push(c),
        }
        if value.len() > 4096 { return None; }
    }
    None
}

fn device_detail(raw: &str) -> String {
    let mut fields = Vec::new();
    for key in ["domain", "errorDomain", "code", "errorCode", "NSLocalizedDescription",
                "NSLocalizedDescriptionKey", "localizedDescription", "NSLocalizedFailureReason",
                "NSLocalizedFailureReasonErrorKey", "localizedFailureReason"] {
        let marker = format!("\"{key}\": ");
        let mut rest = raw;
        // Include nested error domains/codes, but keep the diagnostic bounded.
        for _ in 0..3 {
            let Some((_, tail)) = rest.split_once(&marker) else { break; };
            rest = tail;
            let value = if let Some(text) = tail.strip_prefix("String(") {
                quoted(text)
            } else if let Some(text) = tail.strip_prefix("Integer(") {
                text.split_once(')').and_then(|(number, _)| {
                    number.parse::<i64>().ok().map(|n| n.to_string())
                })
            } else { None };
            if let Some(value) = value {
                let lower = value.to_ascii_lowercase();
                if ["privatekey", "private key", "pairing", "certificate", "-----begin"]
                    .iter().any(|word| lower.contains(word)) { continue; }
                let value: String = value.split_whitespace().collect::<Vec<_>>().join(" ")
                    .chars().take(240).collect();
                fields.push(format!("{key}={value}"));
            }
        }
    }
    if fields.is_empty() { "device rejected request; no recognized error fields".into() }
    else { fields.join("; ").chars().take(1200).collect() }
}

pub fn service_error(stage: &str, cause: &IdeviceError) -> String {
    let detail = match cause {
        IdeviceError::CoreDevice(CoreDeviceError::DeviceError(raw)) => device_detail(raw),
        IdeviceError::CoreDevice(CoreDeviceError::MissingField(field)) => format!("missing field {field}"),
        IdeviceError::CoreDevice(CoreDeviceError::MalformedField(field)) => format!("malformed field {field}"),
        IdeviceError::Socket(err) => format!("socket {:?}", err.kind()),
        IdeviceError::Timeout => "service timed out".into(),
        IdeviceError::ServiceNotFound => "service not found".into(),
        IdeviceError::ImageNotMounted => "developer image not mounted".into(),
        IdeviceError::DeveloperModeNotEnabled => "Developer Mode is off".into(),
        IdeviceError::DeviceLocked => "device locked".into(),
        IdeviceError::Xpc(err) => format!("XPC error {}", err.sub_code()),
        // Other error strings may carry arbitrary payloads; preserve only the category.
        _ => "service protocol error".into(),
    };
    format!("{stage}: {detail}")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn nested_device_errors_keep_reason_without_dumping_other_fields() {
        let raw = r#"Dictionary({"domain": String("com.apple.CoreDeviceError"), "code": Integer(1001), "userInfo": Dictionary({"NSLocalizedDescription": String("Audio stream unavailable"), "HostPrivateKey": Data([1, 2, 3]), "extra": String("PRIVATE-SENTINEL"), "NSUnderlyingError": Dictionary({"domain": String("AVConference"), "code": Integer(-5)})})})"#;
        let result = device_detail(raw);
        assert!(result.contains("code=1001"));
        assert!(result.contains("code=-5"));
        assert!(result.contains("Audio stream unavailable"));
        assert!(!result.contains("HostPrivateKey"));
        assert!(!result.contains("PRIVATE-SENTINEL"));
    }
    #[test]
    fn malformed_and_sensitive_descriptions_are_not_dumped() {
        assert!(!device_detail(r#"Dictionary({"NSLocalizedDescription": String("-----BEGIN PRIVATE KEY-----SECRET"), "arbitrary": String("SECRET")})"#).contains("SECRET"));
        assert!(!device_detail(r#"{"NSLocalizedDescription": String("unterminated SECRET)"#).contains("SECRET"));
        assert!(!service_error("audio", &IdeviceError::UnexpectedResponse("SECRET".into())).contains("SECRET"));
    }
}
