//! Integration tests for kgd-client types and serialization.

use kgd_client::protocol::*;
use kgd_client::*;
use rmpv::Value;

// ---------------------------------------------------------------------------
// Type construction tests
// ---------------------------------------------------------------------------

#[test]
fn color_default_is_zero() {
    let c = Color::default();
    assert_eq!(c.r, 0);
    assert_eq!(c.g, 0);
    assert_eq!(c.b, 0);
}

#[test]
fn color_new() {
    let c = Color::new(65535, 128, 0);
    assert_eq!(c.r, 65535);
    assert_eq!(c.g, 128);
    assert_eq!(c.b, 0);
}

#[test]
fn color_equality() {
    assert_eq!(Color::new(1, 2, 3), Color::new(1, 2, 3));
    assert_ne!(Color::new(1, 2, 3), Color::new(4, 5, 6));
}

#[test]
fn anchor_default_is_absolute() {
    let a = Anchor::default();
    assert_eq!(a.anchor_type, AnchorType::Absolute);
    assert!(a.pane_id.is_empty());
    assert_eq!(a.win_id, 0);
    assert_eq!(a.buf_line, 0);
    assert_eq!(a.row, 0);
    assert_eq!(a.col, 0);
}

#[test]
fn anchor_type_strings() {
    assert_eq!(AnchorType::Absolute.as_str(), "absolute");
    assert_eq!(AnchorType::Pane.as_str(), "pane");
    assert_eq!(AnchorType::NvimWin.as_str(), "nvim_win");
}

#[test]
fn anchor_to_value_absolute_minimal() {
    let a = Anchor {
        anchor_type: AnchorType::Absolute,
        row: 5,
        col: 10,
        ..Default::default()
    };
    let v = a.to_value();
    assert_eq!(map_get_str(&v, "type"), "absolute");
    assert_eq!(map_get_i64(&v, "row"), 5);
    assert_eq!(map_get_i64(&v, "col"), 10);
    // Zero-valued optional fields should be omitted.
    assert!(map_get(&v, "pane_id").is_none());
    assert!(map_get(&v, "win_id").is_none());
    assert!(map_get(&v, "buf_line").is_none());
}

#[test]
fn anchor_to_value_pane() {
    let a = Anchor {
        anchor_type: AnchorType::Pane,
        pane_id: "%3".into(),
        row: 2,
        col: 4,
        ..Default::default()
    };
    let v = a.to_value();
    assert_eq!(map_get_str(&v, "type"), "pane");
    assert_eq!(map_get_str(&v, "pane_id"), "%3");
    assert_eq!(map_get_i64(&v, "row"), 2);
    assert_eq!(map_get_i64(&v, "col"), 4);
}

#[test]
fn anchor_to_value_nvim_win() {
    let a = Anchor {
        anchor_type: AnchorType::NvimWin,
        win_id: 1001,
        buf_line: 42,
        row: 1,
        col: 0,
        ..Default::default()
    };
    let v = a.to_value();
    assert_eq!(map_get_str(&v, "type"), "nvim_win");
    assert_eq!(map_get_i64(&v, "win_id"), 1001);
    assert_eq!(map_get_i64(&v, "buf_line"), 42);
    assert_eq!(map_get_i64(&v, "row"), 1);
    // col == 0, so it should be omitted
    assert!(map_get(&v, "col").is_none());
}

#[test]
fn place_opts_default() {
    let o = PlaceOpts::default();
    assert_eq!(o.src_x, 0);
    assert_eq!(o.src_y, 0);
    assert_eq!(o.src_w, 0);
    assert_eq!(o.src_h, 0);
    assert_eq!(o.z_index, 0);
}

#[test]
fn placement_info_default() {
    let p = PlacementInfo::default();
    assert_eq!(p.placement_id, 0);
    assert!(p.client_id.is_empty());
    assert_eq!(p.handle, 0);
    assert!(!p.visible);
    assert_eq!(p.row, 0);
    assert_eq!(p.col, 0);
}

#[test]
fn status_result_default() {
    let s = StatusResult::default();
    assert_eq!(s.clients, 0);
    assert_eq!(s.placements, 0);
    assert_eq!(s.images, 0);
    assert_eq!(s.cols, 0);
    assert_eq!(s.rows, 0);
}

#[test]
fn hello_result_default() {
    let h = HelloResult::default();
    assert!(h.client_id.is_empty());
    assert_eq!(h.cols, 0);
    assert_eq!(h.rows, 0);
    assert_eq!(h.cell_width, 0);
    assert_eq!(h.cell_height, 0);
    assert!(!h.in_tmux);
    assert_eq!(h.fg, Color::default());
    assert_eq!(h.bg, Color::default());
}

#[test]
fn options_default() {
    let o = Options::default();
    assert!(o.socket_path.is_empty());
    assert!(o.session_id.is_empty());
    assert!(o.client_type.is_empty());
    assert!(o.label.is_empty());
    assert!(o.auto_launch);
    assert_eq!(o.call_timeout, std::time::Duration::from_secs(10));
}

// ---------------------------------------------------------------------------
// Protocol encoding/decoding tests
// ---------------------------------------------------------------------------

#[test]
fn request_roundtrip_with_params() {
    let params = map_from_pairs(vec![
        ("data", Value::Binary(vec![0xDE, 0xAD])),
        ("format", Value::String("png".into())),
        ("width", Value::Integer(100.into())),
        ("height", Value::Integer(80.into())),
    ]);
    let bytes = encode_request(1, "upload", Some(params));
    let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
    let arr = decoded.as_array().unwrap();

    assert_eq!(arr[0].as_u64().unwrap(), MSG_REQUEST);
    assert_eq!(arr[1].as_u64().unwrap(), 1);
    assert_eq!(arr[2].as_str().unwrap(), "upload");

    let params_arr = arr[3].as_array().unwrap();
    assert_eq!(params_arr.len(), 1);
    let param_map = &params_arr[0];
    assert_eq!(map_get_str(param_map, "format"), "png");
    assert_eq!(map_get_i64(param_map, "width"), 100);
}

#[test]
fn request_roundtrip_nil_params() {
    let bytes = encode_request(5, "list", None);
    let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
    let arr = decoded.as_array().unwrap();

    assert_eq!(arr[0].as_u64().unwrap(), MSG_REQUEST);
    assert_eq!(arr[1].as_u64().unwrap(), 5);
    assert_eq!(arr[2].as_str().unwrap(), "list");
    assert!(arr[3].as_array().unwrap().is_empty());
}

#[test]
fn notification_roundtrip_with_params() {
    let params = map_from_pairs(vec![("win_id", Value::Integer(42.into()))]);
    let bytes = encode_notification("unregister_win", Some(params));
    let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
    let arr = decoded.as_array().unwrap();

    assert_eq!(arr[0].as_u64().unwrap(), MSG_NOTIFICATION);
    assert_eq!(arr[1].as_str().unwrap(), "unregister_win");
    assert_eq!(arr[2].as_array().unwrap().len(), 1);
}

#[test]
fn notification_roundtrip_nil_params() {
    let bytes = encode_notification("stop", None);
    let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
    let arr = decoded.as_array().unwrap();

    assert_eq!(arr[0].as_u64().unwrap(), MSG_NOTIFICATION);
    assert_eq!(arr[1].as_str().unwrap(), "stop");
    assert!(arr[2].as_array().unwrap().is_empty());
}

#[test]
fn decode_response() {
    let result_map = map_from_pairs(vec![
        ("client_id", Value::String("abc-123".into())),
        ("cols", Value::Integer(80.into())),
        ("rows", Value::Integer(24.into())),
    ]);
    let msg = Value::Array(vec![
        Value::Integer(MSG_RESPONSE.into()),
        Value::Integer(0.into()),
        Value::Nil,
        result_map,
    ]);

    match decode_message(msg).unwrap() {
        ServerMessage::Response {
            msgid,
            error,
            result,
        } => {
            assert_eq!(msgid, 0);
            assert!(error.is_nil());
            assert_eq!(map_get_str(&result, "client_id"), "abc-123");
            assert_eq!(map_get_i64(&result, "cols"), 80);
        }
        _ => panic!("expected Response"),
    }
}

#[test]
fn decode_response_with_error() {
    let err_map = map_from_pairs(vec![("message", Value::String("invalid handle".into()))]);
    let msg = Value::Array(vec![
        Value::Integer(MSG_RESPONSE.into()),
        Value::Integer(7.into()),
        err_map,
        Value::Nil,
    ]);

    match decode_message(msg).unwrap() {
        ServerMessage::Response {
            msgid,
            error,
            result,
        } => {
            assert_eq!(msgid, 7);
            assert_eq!(map_get_str(&error, "message"), "invalid handle");
            assert!(result.is_nil());
        }
        _ => panic!("expected Response"),
    }
}

#[test]
fn decode_evicted_notification() {
    let params = Value::Array(vec![map_from_pairs(vec![(
        "handle",
        Value::Integer(99.into()),
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
            assert_eq!(map_get_i64(&arr[0], "handle"), 99);
        }
        _ => panic!("expected Notification"),
    }
}

#[test]
fn decode_topology_notification() {
    let params = Value::Array(vec![map_from_pairs(vec![
        ("cols", Value::Integer(120.into())),
        ("rows", Value::Integer(40.into())),
        ("cell_width", Value::Integer(8.into())),
        ("cell_height", Value::Integer(16.into())),
    ])]);
    let msg = Value::Array(vec![
        Value::Integer(MSG_NOTIFICATION.into()),
        Value::String("topology_changed".into()),
        params,
    ]);

    match decode_message(msg).unwrap() {
        ServerMessage::Notification { method, params } => {
            assert_eq!(method, "topology_changed");
            let arr = params.as_array().unwrap();
            assert_eq!(map_get_i64(&arr[0], "cols"), 120);
            assert_eq!(map_get_i64(&arr[0], "cell_height"), 16);
        }
        _ => panic!("expected Notification"),
    }
}

#[test]
fn decode_malformed_messages() {
    // Not an array
    assert!(decode_message(Value::Integer(42.into())).is_none());
    // Empty array
    assert!(decode_message(Value::Array(vec![])).is_none());
    // Unknown message type
    assert!(decode_message(Value::Array(vec![
        Value::Integer(99.into()),
        Value::String("foo".into()),
        Value::Array(vec![]),
    ]))
    .is_none());
    // Response too short
    assert!(decode_message(Value::Array(vec![
        Value::Integer(MSG_RESPONSE.into()),
        Value::Integer(0.into()),
    ]))
    .is_none());
}

// ---------------------------------------------------------------------------
// Hello parameter encoding
// ---------------------------------------------------------------------------

#[test]
fn hello_params_encoding() {
    // Verify the hello parameter map matches what the Python client sends.
    let mut pairs: Vec<(&str, Value)> = vec![
        ("client_type", Value::String("test".into())),
        ("pid", Value::Integer(12345.into())),
        ("label", Value::String("test-label".into())),
    ];
    pairs.push(("session_id", Value::String("sess-1".into())));
    let params = map_from_pairs(pairs);

    let bytes = encode_request(0, "hello", Some(params));
    let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
    let arr = decoded.as_array().unwrap();
    let params_arr = arr[3].as_array().unwrap();
    let param = &params_arr[0];

    assert_eq!(map_get_str(param, "client_type"), "test");
    assert_eq!(map_get_i64(param, "pid"), 12345);
    assert_eq!(map_get_str(param, "label"), "test-label");
    assert_eq!(map_get_str(param, "session_id"), "sess-1");
}

// ---------------------------------------------------------------------------
// Upload parameter encoding
// ---------------------------------------------------------------------------

#[test]
fn upload_params_encoding() {
    let data = vec![0x89, 0x50, 0x4E, 0x47]; // PNG magic bytes
    let params = map_from_pairs(vec![
        ("data", Value::Binary(data.clone())),
        ("format", Value::String("png".into())),
        ("width", Value::Integer(640.into())),
        ("height", Value::Integer(480.into())),
    ]);

    let bytes = encode_request(1, "upload", Some(params));
    let decoded = rmpv::decode::read_value(&mut &bytes[..]).unwrap();
    let arr = decoded.as_array().unwrap();
    let params_arr = arr[3].as_array().unwrap();
    let param = &params_arr[0];

    assert_eq!(
        param
            .as_map()
            .unwrap()
            .iter()
            .find(|(k, _)| k.as_str() == Some("data"))
            .unwrap()
            .1
            .as_slice()
            .unwrap(),
        &data[..]
    );
    assert_eq!(map_get_str(param, "format"), "png");
    assert_eq!(map_get_i64(param, "width"), 640);
    assert_eq!(map_get_i64(param, "height"), 480);
}

// ---------------------------------------------------------------------------
// Place parameter encoding with optional fields
// ---------------------------------------------------------------------------

#[test]
fn place_params_omit_zero_opts() {
    let anchor = Anchor {
        anchor_type: AnchorType::Absolute,
        row: 10,
        col: 20,
        ..Default::default()
    };
    let mut pairs: Vec<(&str, Value)> = vec![
        ("handle", Value::Integer(1.into())),
        ("anchor", anchor.to_value()),
        ("width", Value::Integer(30.into())),
        ("height", Value::Integer(20.into())),
    ];

    // With default PlaceOpts (all zero), no extra fields should be added.
    let opts = PlaceOpts::default();
    if opts.src_x != 0 {
        pairs.push(("src_x", Value::Integer(opts.src_x.into())));
    }
    if opts.z_index != 0 {
        pairs.push(("z_index", Value::Integer(opts.z_index.into())));
    }

    let params = map_from_pairs(pairs);
    // Should have exactly 4 fields: handle, anchor, width, height
    let entries = params.as_map().unwrap();
    assert_eq!(entries.len(), 4);
}

#[test]
fn place_params_with_opts() {
    let anchor = Anchor {
        anchor_type: AnchorType::Pane,
        pane_id: "%1".into(),
        row: 5,
        col: 10,
        ..Default::default()
    };
    let opts = PlaceOpts {
        src_x: 10,
        src_y: 20,
        src_w: 100,
        src_h: 80,
        z_index: -1,
    };

    let mut pairs: Vec<(&str, Value)> = vec![
        ("handle", Value::Integer(1.into())),
        ("anchor", anchor.to_value()),
        ("width", Value::Integer(30.into())),
        ("height", Value::Integer(20.into())),
    ];
    if opts.src_x != 0 {
        pairs.push(("src_x", Value::Integer(opts.src_x.into())));
    }
    if opts.src_y != 0 {
        pairs.push(("src_y", Value::Integer(opts.src_y.into())));
    }
    if opts.src_w != 0 {
        pairs.push(("src_w", Value::Integer(opts.src_w.into())));
    }
    if opts.src_h != 0 {
        pairs.push(("src_h", Value::Integer(opts.src_h.into())));
    }
    if opts.z_index != 0 {
        pairs.push(("z_index", Value::Integer(opts.z_index.into())));
    }

    let params = map_from_pairs(pairs);
    let entries = params.as_map().unwrap();
    // 4 base + 5 opts = 9
    assert_eq!(entries.len(), 9);
    assert_eq!(map_get_i64(&params, "src_x"), 10);
    assert_eq!(map_get_i64(&params, "z_index"), -1);
}

// ---------------------------------------------------------------------------
// Error type tests
// ---------------------------------------------------------------------------

#[test]
fn error_display() {
    let e = KgdError::Timeout("upload".into());
    assert_eq!(format!("{e}"), "timeout waiting for response to upload");

    let e = KgdError::Rpc("bad handle".into());
    assert_eq!(format!("{e}"), "rpc error: bad handle");

    let e = KgdError::DaemonNotFound;
    assert_eq!(format!("{e}"), "kgd binary not found in PATH");

    let e = KgdError::ConnectionClosed;
    assert_eq!(format!("{e}"), "connection closed");
}

// ---------------------------------------------------------------------------
// Multiple messages in one buffer (streaming decode test)
// ---------------------------------------------------------------------------

#[test]
fn decode_multiple_messages_from_concatenated_bytes() {
    // Simulate receiving two messages concatenated in one read.
    let msg1_bytes = encode_request(0, "hello", None);
    let msg2_bytes = encode_notification("stop", None);

    let mut combined = msg1_bytes.clone();
    combined.extend_from_slice(&msg2_bytes);

    // Decode first message.
    let mut cursor = std::io::Cursor::new(&combined[..]);
    let v1 = rmpv::decode::read_value(&mut cursor).unwrap();
    let consumed1 = cursor.position() as usize;

    let arr1 = v1.as_array().unwrap();
    assert_eq!(arr1[0].as_u64().unwrap(), MSG_REQUEST);
    assert_eq!(arr1[2].as_str().unwrap(), "hello");

    // Decode second message from remainder.
    let remainder = &combined[consumed1..];
    let v2 = rmpv::decode::read_value(&mut &remainder[..]).unwrap();
    let arr2 = v2.as_array().unwrap();
    assert_eq!(arr2[0].as_u64().unwrap(), MSG_NOTIFICATION);
    assert_eq!(arr2[1].as_str().unwrap(), "stop");
}

// ---------------------------------------------------------------------------
// Anchor type method visibility
// ---------------------------------------------------------------------------

#[test]
fn anchor_type_as_str_is_public() {
    // Ensure the as_str method is accessible (compile-time check).
    let _ = AnchorType::Absolute.as_str();
    let _ = AnchorType::Pane.as_str();
    let _ = AnchorType::NvimWin.as_str();
}
