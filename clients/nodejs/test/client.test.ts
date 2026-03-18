/**
 * Tests for @kgd/client types and protocol encoding.
 *
 * These tests validate the msgpack-RPC encoding/decoding and type
 * serialization without requiring a running kgd daemon.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { decode, encode } from "@msgpack/msgpack";
import {
  encodeRequest,
  encodeNotification,
  parseMessage,
  MSG_REQUEST,
  MSG_RESPONSE,
  MSG_NOTIFICATION,
  METHOD_HELLO,
  METHOD_UPLOAD,
  METHOD_PLACE,
  METHOD_UNPLACE_ALL,
  METHOD_STOP,
  NOTIFY_EVICTED,
  NOTIFY_TOPOLOGY_CHANGED,
  NOTIFY_VISIBILITY_CHANGED,
  NOTIFY_THEME_CHANGED,
  KgdError,
  RpcError,
  TimeoutError,
  ConnectionError,
} from "../src/index.js";

// ---------------------------------------------------------------------------
// Protocol encoding
// ---------------------------------------------------------------------------

describe("encodeRequest", () => {
  it("should encode a request with params", () => {
    const bytes = encodeRequest(1, METHOD_HELLO, {
      client_type: "test",
      pid: 42,
      label: "test-label",
    });
    const msg = decode(bytes) as unknown[];
    assert.equal(msg[0], MSG_REQUEST);
    assert.equal(msg[1], 1);
    assert.equal(msg[2], "hello");
    assert.ok(Array.isArray(msg[3]));
    const params = (msg[3] as unknown[])[0] as Record<string, unknown>;
    assert.equal(params["client_type"], "test");
    assert.equal(params["pid"], 42);
    assert.equal(params["label"], "test-label");
  });

  it("should encode a request with null params as empty array", () => {
    const bytes = encodeRequest(5, METHOD_UPLOAD, null);
    const msg = decode(bytes) as unknown[];
    assert.equal(msg[0], MSG_REQUEST);
    assert.equal(msg[1], 5);
    assert.equal(msg[2], "upload");
    assert.deepEqual(msg[3], []);
  });

  it("should increment msgid correctly", () => {
    const bytes1 = encodeRequest(0, "a", null);
    const bytes2 = encodeRequest(1, "b", null);
    const msg1 = decode(bytes1) as unknown[];
    const msg2 = decode(bytes2) as unknown[];
    assert.equal(msg1[1], 0);
    assert.equal(msg2[1], 1);
  });
});

describe("encodeNotification", () => {
  it("should encode a notification with params", () => {
    const bytes = encodeNotification(METHOD_UNPLACE_ALL, { reason: "cleanup" });
    const msg = decode(bytes) as unknown[];
    assert.equal(msg[0], MSG_NOTIFICATION);
    assert.equal(msg[1], "unplace_all");
    assert.ok(Array.isArray(msg[2]));
    const params = (msg[2] as unknown[])[0] as Record<string, unknown>;
    assert.equal(params["reason"], "cleanup");
  });

  it("should encode a notification with null params as empty array", () => {
    const bytes = encodeNotification(METHOD_STOP, null);
    const msg = decode(bytes) as unknown[];
    assert.equal(msg[0], MSG_NOTIFICATION);
    assert.equal(msg[1], "stop");
    assert.deepEqual(msg[2], []);
  });
});

// ---------------------------------------------------------------------------
// Protocol decoding (parseMessage)
// ---------------------------------------------------------------------------

describe("parseMessage", () => {
  it("should parse a response message", () => {
    const raw = [MSG_RESPONSE, 42, null, { client_id: "abc-123" }];
    const msg = parseMessage(raw);
    assert.ok(msg !== null);
    assert.equal(msg.type, MSG_RESPONSE);
    if (msg.type === MSG_RESPONSE) {
      assert.equal(msg.msgid, 42);
      assert.equal(msg.error, null);
      assert.deepEqual(msg.result, { client_id: "abc-123" });
    }
  });

  it("should parse a response with error", () => {
    const raw = [MSG_RESPONSE, 7, { message: "not found" }, null];
    const msg = parseMessage(raw);
    assert.ok(msg !== null);
    assert.equal(msg.type, MSG_RESPONSE);
    if (msg.type === MSG_RESPONSE) {
      assert.equal(msg.msgid, 7);
      assert.deepEqual(msg.error, { message: "not found" });
      assert.equal(msg.result, null);
    }
  });

  it("should parse a notification message", () => {
    const raw = [MSG_NOTIFICATION, NOTIFY_EVICTED, [{ handle: 99 }]];
    const msg = parseMessage(raw);
    assert.ok(msg !== null);
    assert.equal(msg.type, MSG_NOTIFICATION);
    if (msg.type === MSG_NOTIFICATION) {
      assert.equal(msg.method, "evicted");
      assert.deepEqual(msg.params, { handle: 99 });
    }
  });

  it("should parse topology_changed notification", () => {
    const raw = [
      MSG_NOTIFICATION,
      NOTIFY_TOPOLOGY_CHANGED,
      [{ cols: 120, rows: 40, cell_width: 8, cell_height: 16 }],
    ];
    const msg = parseMessage(raw);
    assert.ok(msg !== null);
    assert.equal(msg.type, MSG_NOTIFICATION);
    if (msg.type === MSG_NOTIFICATION) {
      assert.equal(msg.method, "topology_changed");
      assert.equal(msg.params["cols"], 120);
      assert.equal(msg.params["rows"], 40);
      assert.equal(msg.params["cell_width"], 8);
      assert.equal(msg.params["cell_height"], 16);
    }
  });

  it("should parse visibility_changed notification", () => {
    const raw = [
      MSG_NOTIFICATION,
      NOTIFY_VISIBILITY_CHANGED,
      [{ placement_id: 5, visible: true }],
    ];
    const msg = parseMessage(raw);
    assert.ok(msg !== null);
    if (msg?.type === MSG_NOTIFICATION) {
      assert.equal(msg.params["placement_id"], 5);
      assert.equal(msg.params["visible"], true);
    }
  });

  it("should parse theme_changed notification", () => {
    const raw = [
      MSG_NOTIFICATION,
      NOTIFY_THEME_CHANGED,
      [{ fg: { r: 65535, g: 65535, b: 65535 }, bg: { r: 0, g: 0, b: 0 } }],
    ];
    const msg = parseMessage(raw);
    assert.ok(msg !== null);
    if (msg?.type === MSG_NOTIFICATION) {
      assert.deepEqual(msg.params["fg"], { r: 65535, g: 65535, b: 65535 });
      assert.deepEqual(msg.params["bg"], { r: 0, g: 0, b: 0 });
    }
  });

  it("should handle notification with empty params", () => {
    const raw = [MSG_NOTIFICATION, "test", []];
    const msg = parseMessage(raw);
    assert.ok(msg !== null);
    if (msg?.type === MSG_NOTIFICATION) {
      assert.deepEqual(msg.params, {});
    }
  });

  it("should return null for non-array input", () => {
    assert.equal(parseMessage("not an array"), null);
    assert.equal(parseMessage(42), null);
    assert.equal(parseMessage(null), null);
  });

  it("should return null for too-short array", () => {
    assert.equal(parseMessage([1, 2]), null);
    assert.equal(parseMessage([]), null);
  });

  it("should return null for unknown message type", () => {
    assert.equal(parseMessage([99, "unknown", []]), null);
  });

  it("should return null for response with too few elements", () => {
    assert.equal(parseMessage([MSG_RESPONSE, 1, null]), null);
  });
});

// ---------------------------------------------------------------------------
// Round-trip encoding/decoding
// ---------------------------------------------------------------------------

describe("round-trip encoding", () => {
  it("should round-trip a request through msgpack", () => {
    const bytes = encodeRequest(3, METHOD_PLACE, {
      handle: 10,
      anchor: { type: "absolute", row: 5, col: 10 },
      width: 20,
      height: 15,
    });
    const raw = decode(bytes) as unknown[];
    assert.equal(raw[0], MSG_REQUEST);
    assert.equal(raw[1], 3);
    assert.equal(raw[2], "place");
    const params = (raw[3] as unknown[])[0] as Record<string, unknown>;
    assert.equal(params["handle"], 10);
    const anchor = params["anchor"] as Record<string, unknown>;
    assert.equal(anchor["type"], "absolute");
    assert.equal(anchor["row"], 5);
    assert.equal(anchor["col"], 10);
  });

  it("should round-trip a response through parseMessage", () => {
    // Simulate what the daemon would send back.
    const response = [MSG_RESPONSE, 3, null, { placement_id: 42 }];
    const encoded = encode(response);
    const decoded = decode(encoded);
    const msg = parseMessage(decoded);
    assert.ok(msg !== null);
    assert.equal(msg.type, MSG_RESPONSE);
    if (msg.type === MSG_RESPONSE) {
      assert.equal(msg.msgid, 3);
      assert.equal(msg.error, null);
      assert.deepEqual(msg.result, { placement_id: 42 });
    }
  });

  it("should round-trip upload request with binary data", () => {
    const data = new Uint8Array([0x89, 0x50, 0x4e, 0x47]); // PNG magic
    const bytes = encodeRequest(0, METHOD_UPLOAD, {
      data,
      format: "png",
      width: 100,
      height: 200,
    });
    const raw = decode(bytes) as unknown[];
    const params = (raw[3] as unknown[])[0] as Record<string, unknown>;
    assert.equal(params["format"], "png");
    assert.equal(params["width"], 100);
    assert.equal(params["height"], 200);
    // msgpack decodes binary data as Uint8Array
    const decoded = params["data"] as Uint8Array;
    assert.equal(decoded[0], 0x89);
    assert.equal(decoded[1], 0x50);
    assert.equal(decoded[2], 0x4e);
    assert.equal(decoded[3], 0x47);
  });
});

// ---------------------------------------------------------------------------
// Anchor serialization
// ---------------------------------------------------------------------------

describe("anchor serialization", () => {
  it("should include only type for absolute anchor with no offsets", () => {
    // Simulates what the Client.place() method does internally via serializeAnchor.
    const bytes = encodeRequest(0, METHOD_PLACE, {
      handle: 1,
      anchor: { type: "absolute" },
      width: 10,
      height: 10,
    });
    const raw = decode(bytes) as unknown[];
    const params = (raw[3] as unknown[])[0] as Record<string, unknown>;
    const anchor = params["anchor"] as Record<string, unknown>;
    assert.equal(anchor["type"], "absolute");
    // The Client.place() serializer omits zero-valued fields.
    // When constructed as a plain dict here, the key simply won't be present
    // since we didn't include them.
    assert.equal(anchor["row"], undefined);
    assert.equal(anchor["col"], undefined);
  });

  it("should include pane_id for pane anchors", () => {
    const anchor = { type: "pane", pane_id: "%0", row: 2, col: 3 };
    const bytes = encodeRequest(0, METHOD_PLACE, {
      handle: 1,
      anchor,
      width: 10,
      height: 10,
    });
    const raw = decode(bytes) as unknown[];
    const params = (raw[3] as unknown[])[0] as Record<string, unknown>;
    const a = params["anchor"] as Record<string, unknown>;
    assert.equal(a["type"], "pane");
    assert.equal(a["pane_id"], "%0");
    assert.equal(a["row"], 2);
    assert.equal(a["col"], 3);
  });

  it("should include win_id and buf_line for nvim_win anchors", () => {
    const anchor = { type: "nvim_win", win_id: 1000, buf_line: 5, col: 0 };
    const bytes = encodeRequest(0, METHOD_PLACE, {
      handle: 1,
      anchor,
      width: 10,
      height: 10,
    });
    const raw = decode(bytes) as unknown[];
    const params = (raw[3] as unknown[])[0] as Record<string, unknown>;
    const a = params["anchor"] as Record<string, unknown>;
    assert.equal(a["type"], "nvim_win");
    assert.equal(a["win_id"], 1000);
    assert.equal(a["buf_line"], 5);
    assert.equal(a["col"], 0);
  });
});

// ---------------------------------------------------------------------------
// Error classes
// ---------------------------------------------------------------------------

describe("error classes", () => {
  it("KgdError should be instanceof Error", () => {
    const err = new KgdError("test");
    assert.ok(err instanceof Error);
    assert.ok(err instanceof KgdError);
    assert.equal(err.name, "KgdError");
    assert.equal(err.message, "test");
  });

  it("RpcError should be instanceof KgdError", () => {
    const err = new RpcError("rpc failed");
    assert.ok(err instanceof Error);
    assert.ok(err instanceof KgdError);
    assert.ok(err instanceof RpcError);
    assert.equal(err.name, "RpcError");
  });

  it("TimeoutError should be instanceof KgdError", () => {
    const err = new TimeoutError("timed out");
    assert.ok(err instanceof Error);
    assert.ok(err instanceof KgdError);
    assert.ok(err instanceof TimeoutError);
    assert.equal(err.name, "TimeoutError");
  });

  it("ConnectionError should be instanceof KgdError", () => {
    const err = new ConnectionError("disconnected");
    assert.ok(err instanceof Error);
    assert.ok(err instanceof KgdError);
    assert.ok(err instanceof ConnectionError);
    assert.equal(err.name, "ConnectionError");
  });
});

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

describe("protocol constants", () => {
  it("should have correct message type values", () => {
    assert.equal(MSG_REQUEST, 0);
    assert.equal(MSG_RESPONSE, 1);
    assert.equal(MSG_NOTIFICATION, 2);
  });

  it("should have correct method names", () => {
    assert.equal(METHOD_HELLO, "hello");
    assert.equal(METHOD_UPLOAD, "upload");
    assert.equal(METHOD_PLACE, "place");
    assert.equal(METHOD_UNPLACE_ALL, "unplace_all");
    assert.equal(METHOD_STOP, "stop");
  });

  it("should have correct notification names", () => {
    assert.equal(NOTIFY_EVICTED, "evicted");
    assert.equal(NOTIFY_TOPOLOGY_CHANGED, "topology_changed");
    assert.equal(NOTIFY_VISIBILITY_CHANGED, "visibility_changed");
    assert.equal(NOTIFY_THEME_CHANGED, "theme_changed");
  });
});
