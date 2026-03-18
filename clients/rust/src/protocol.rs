//! Msgpack-RPC encoding and decoding for the kgd protocol.
//!
//! The wire format follows the msgpack-RPC specification:
//! - Request:      `[0, msgid, method, [params]]`
//! - Response:     `[1, msgid, error, result]`
//! - Notification: `[2, method, [params]]`
//!
//! Parameters are encoded as a single-element array containing a map,
//! or as an empty array when there are no parameters.

use rmpv::Value;

/// Message type tag for requests (client to server).
pub const MSG_REQUEST: u64 = 0;

/// Message type tag for responses (server to client).
pub const MSG_RESPONSE: u64 = 1;

/// Message type tag for notifications (bidirectional).
pub const MSG_NOTIFICATION: u64 = 2;

// --- RPC method names ---

pub const METHOD_HELLO: &str = "hello";
pub const METHOD_UPLOAD: &str = "upload";
pub const METHOD_PLACE: &str = "place";
pub const METHOD_UNPLACE: &str = "unplace";
pub const METHOD_UNPLACE_ALL: &str = "unplace_all";
pub const METHOD_FREE: &str = "free";
pub const METHOD_REGISTER_WIN: &str = "register_win";
pub const METHOD_UPDATE_SCROLL: &str = "update_scroll";
pub const METHOD_UNREGISTER_WIN: &str = "unregister_win";
pub const METHOD_LIST: &str = "list";
pub const METHOD_STATUS: &str = "status";
pub const METHOD_STOP: &str = "stop";

// --- Notification names ---

pub const NOTIFY_EVICTED: &str = "evicted";
pub const NOTIFY_TOPOLOGY_CHANGED: &str = "topology_changed";
pub const NOTIFY_VISIBILITY_CHANGED: &str = "visibility_changed";
pub const NOTIFY_THEME_CHANGED: &str = "theme_changed";

/// Encode a request message: `[0, msgid, method, [params]]`.
///
/// If `params` is `None`, the params array is empty (`[]`).
/// Otherwise it is a single-element array containing the params value (`[params]`).
pub fn encode_request(msgid: u32, method: &str, params: Option<Value>) -> Vec<u8> {
    let params_array = match params {
        Some(v) => Value::Array(vec![v]),
        None => Value::Array(vec![]),
    };

    let msg = Value::Array(vec![
        Value::Integer(MSG_REQUEST.into()),
        Value::Integer(msgid.into()),
        Value::String(method.into()),
        params_array,
    ]);

    let mut buf = Vec::new();
    rmpv::encode::write_value(&mut buf, &msg).expect("encoding to Vec<u8> cannot fail");
    buf
}

/// Encode a notification message: `[2, method, [params]]`.
///
/// If `params` is `None`, the params array is empty (`[]`).
/// Otherwise it is a single-element array containing the params value (`[params]`).
pub fn encode_notification(method: &str, params: Option<Value>) -> Vec<u8> {
    let params_array = match params {
        Some(v) => Value::Array(vec![v]),
        None => Value::Array(vec![]),
    };

    let msg = Value::Array(vec![
        Value::Integer(MSG_NOTIFICATION.into()),
        Value::String(method.into()),
        params_array,
    ]);

    let mut buf = Vec::new();
    rmpv::encode::write_value(&mut buf, &msg).expect("encoding to Vec<u8> cannot fail");
    buf
}

/// A decoded message from the server.
#[derive(Debug)]
pub enum ServerMessage {
    /// A response to a previous request: `(msgid, error, result)`.
    Response {
        msgid: u32,
        error: Value,
        result: Value,
    },
    /// A server-initiated notification: `(method, params)`.
    Notification { method: String, params: Value },
}

/// Attempt to decode a msgpack `Value` into a `ServerMessage`.
///
/// Returns `None` if the value is not a well-formed message.
pub fn decode_message(value: Value) -> Option<ServerMessage> {
    let arr = match value {
        Value::Array(a) if a.len() >= 3 => a,
        _ => return None,
    };

    let msg_type = arr[0].as_u64()?;

    match msg_type {
        MSG_RESPONSE => {
            if arr.len() < 4 {
                return None;
            }
            let msgid = arr[1].as_u64()? as u32;
            let error = arr[2].clone();
            let result = arr[3].clone();
            Some(ServerMessage::Response {
                msgid,
                error,
                result,
            })
        }
        MSG_NOTIFICATION => {
            let method = arr[1].as_str()?.to_string();
            let params = arr[2].clone();
            Some(ServerMessage::Notification { method, params })
        }
        _ => None,
    }
}

/// Build a msgpack map `Value` from a list of key-value pairs.
///
/// This is a convenience helper for constructing RPC parameter maps.
pub fn map_from_pairs(pairs: Vec<(&str, Value)>) -> Value {
    Value::Map(
        pairs
            .into_iter()
            .map(|(k, v)| (Value::String(k.into()), v))
            .collect(),
    )
}

/// Extract a field from a msgpack map `Value` by key.
pub fn map_get<'a>(map: &'a Value, key: &str) -> Option<&'a Value> {
    match map {
        Value::Map(entries) => {
            for (k, v) in entries {
                if k.as_str() == Some(key) {
                    return Some(v);
                }
            }
            None
        }
        _ => None,
    }
}

/// Extract a string field from a msgpack map.
pub fn map_get_str(map: &Value, key: &str) -> String {
    map_get(map, key)
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

/// Extract an integer field from a msgpack map, defaulting to 0.
pub fn map_get_i64(map: &Value, key: &str) -> i64 {
    map_get(map, key).and_then(|v| v.as_i64()).unwrap_or(0)
}

/// Extract an unsigned integer field from a msgpack map, defaulting to 0.
pub fn map_get_u64(map: &Value, key: &str) -> u64 {
    map_get(map, key).and_then(|v| v.as_u64()).unwrap_or(0)
}

/// Extract a boolean field from a msgpack map, defaulting to false.
pub fn map_get_bool(map: &Value, key: &str) -> bool {
    map_get(map, key).and_then(|v| v.as_bool()).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_request_with_params() {
        let params = map_from_pairs(vec![("key", Value::String("value".into()))]);
        let bytes = encode_request(1, "test_method", Some(params));

        // Decode and verify structure
        let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
        let arr = decoded.as_array().unwrap();
        assert_eq!(arr[0].as_u64().unwrap(), MSG_REQUEST);
        assert_eq!(arr[1].as_u64().unwrap(), 1);
        assert_eq!(arr[2].as_str().unwrap(), "test_method");

        let params_arr = arr[3].as_array().unwrap();
        assert_eq!(params_arr.len(), 1);
    }

    #[test]
    fn encode_request_without_params() {
        let bytes = encode_request(42, "status", None);
        let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
        let arr = decoded.as_array().unwrap();
        assert_eq!(arr[0].as_u64().unwrap(), MSG_REQUEST);
        assert_eq!(arr[1].as_u64().unwrap(), 42);
        assert_eq!(arr[2].as_str().unwrap(), "status");
        assert!(arr[3].as_array().unwrap().is_empty());
    }

    #[test]
    fn encode_notification_with_params() {
        let params = map_from_pairs(vec![("win_id", Value::Integer(5.into()))]);
        let bytes = encode_notification("unregister_win", Some(params));
        let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
        let arr = decoded.as_array().unwrap();
        assert_eq!(arr[0].as_u64().unwrap(), MSG_NOTIFICATION);
        assert_eq!(arr[1].as_str().unwrap(), "unregister_win");
        assert_eq!(arr[2].as_array().unwrap().len(), 1);
    }

    #[test]
    fn encode_notification_without_params() {
        let bytes = encode_notification("stop", None);
        let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
        let arr = decoded.as_array().unwrap();
        assert_eq!(arr[0].as_u64().unwrap(), MSG_NOTIFICATION);
        assert_eq!(arr[1].as_str().unwrap(), "stop");
        assert!(arr[2].as_array().unwrap().is_empty());
    }

    #[test]
    fn decode_response_message() {
        let msg = Value::Array(vec![
            Value::Integer(MSG_RESPONSE.into()),
            Value::Integer(7.into()),
            Value::Nil,
            Value::String("ok".into()),
        ]);
        match decode_message(msg).unwrap() {
            ServerMessage::Response {
                msgid,
                error,
                result,
            } => {
                assert_eq!(msgid, 7);
                assert!(error.is_nil());
                assert_eq!(result.as_str().unwrap(), "ok");
            }
            _ => panic!("expected Response"),
        }
    }

    #[test]
    fn decode_notification_message() {
        let params = Value::Array(vec![map_from_pairs(vec![(
            "handle",
            Value::Integer(42.into()),
        )])]);
        let msg = Value::Array(vec![
            Value::Integer(MSG_NOTIFICATION.into()),
            Value::String("evicted".into()),
            params,
        ]);
        match decode_message(msg).unwrap() {
            ServerMessage::Notification { method, params } => {
                assert_eq!(method, "evicted");
                let arr = params.as_array().unwrap();
                assert_eq!(arr.len(), 1);
            }
            _ => panic!("expected Notification"),
        }
    }

    #[test]
    fn decode_malformed_returns_none() {
        assert!(decode_message(Value::Integer(42.into())).is_none());
        assert!(decode_message(Value::Array(vec![])).is_none());
        assert!(decode_message(Value::Array(vec![Value::Integer(99.into())])).is_none());
    }

    #[test]
    fn map_helpers() {
        let m = map_from_pairs(vec![
            ("name", Value::String("test".into())),
            ("count", Value::Integer(42.into())),
            ("flag", Value::Boolean(true)),
        ]);

        assert_eq!(map_get_str(&m, "name"), "test");
        assert_eq!(map_get_i64(&m, "count"), 42);
        assert_eq!(map_get_bool(&m, "flag"), true);
        assert_eq!(map_get_str(&m, "missing"), "");
        assert_eq!(map_get_i64(&m, "missing"), 0);
        assert_eq!(map_get_bool(&m, "missing"), false);
    }
}
