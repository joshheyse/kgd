/**
 * msgpack-RPC protocol encoding/decoding for the kgd daemon.
 *
 * Wire format follows the msgpack-RPC specification:
 * - Request:      [0, msgid, method, [params]]
 * - Response:     [1, msgid, error, result]
 * - Notification: [2, method, [params]]
 *
 * @module
 */

import { encode, decodeMultiStream } from "@msgpack/msgpack";

// ---------------------------------------------------------------------------
// Message type constants
// ---------------------------------------------------------------------------

/** Client-to-server request that expects a response. */
export const MSG_REQUEST = 0 as const;

/** Server-to-client response to a prior request. */
export const MSG_RESPONSE = 1 as const;

/** Fire-and-forget message in either direction. */
export const MSG_NOTIFICATION = 2 as const;

// ---------------------------------------------------------------------------
// RPC method names
// ---------------------------------------------------------------------------

export const METHOD_HELLO = "hello" as const;
export const METHOD_UPLOAD = "upload" as const;
export const METHOD_PLACE = "place" as const;
export const METHOD_UNPLACE = "unplace" as const;
export const METHOD_UNPLACE_ALL = "unplace_all" as const;
export const METHOD_FREE = "free" as const;
export const METHOD_REGISTER_WIN = "register_win" as const;
export const METHOD_UPDATE_SCROLL = "update_scroll" as const;
export const METHOD_UNREGISTER_WIN = "unregister_win" as const;
export const METHOD_LIST = "list" as const;
export const METHOD_STATUS = "status" as const;
export const METHOD_STOP = "stop" as const;

// ---------------------------------------------------------------------------
// Server-to-client notification names
// ---------------------------------------------------------------------------

export const NOTIFY_EVICTED = "evicted" as const;
export const NOTIFY_TOPOLOGY_CHANGED = "topology_changed" as const;
export const NOTIFY_VISIBILITY_CHANGED = "visibility_changed" as const;
export const NOTIFY_THEME_CHANGED = "theme_changed" as const;

// ---------------------------------------------------------------------------
// Decoded message types
// ---------------------------------------------------------------------------

/** A decoded response message: [1, msgid, error, result]. */
export interface ResponseMessage {
	type: typeof MSG_RESPONSE;
	msgid: number;
	error: unknown;
	result: unknown;
}

/** A decoded notification message: [2, method, [params]]. */
export interface NotificationMessage {
	type: typeof MSG_NOTIFICATION;
	method: string;
	params: Record<string, unknown>;
}

export type DecodedMessage = ResponseMessage | NotificationMessage;

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/**
 * Encode an RPC request.
 *
 * @param msgid - Monotonically increasing request identifier.
 * @param method - RPC method name.
 * @param params - Parameter object, or null for methods with no parameters.
 * @returns Encoded msgpack bytes ready to write to the socket.
 */
export function encodeRequest(
	msgid: number,
	method: string,
	params: Record<string, unknown> | null,
): Uint8Array {
	const paramsArray = params !== null ? [params] : [];
	return encode([MSG_REQUEST, msgid, method, paramsArray]);
}

/**
 * Encode an RPC notification (fire-and-forget).
 *
 * @param method - Notification method name.
 * @param params - Parameter object, or null for methods with no parameters.
 * @returns Encoded msgpack bytes ready to write to the socket.
 */
export function encodeNotification(
	method: string,
	params: Record<string, unknown> | null,
): Uint8Array {
	const paramsArray = params !== null ? [params] : [];
	return encode([MSG_NOTIFICATION, method, paramsArray]);
}

// ---------------------------------------------------------------------------
// Decoding (streaming)
// ---------------------------------------------------------------------------

/**
 * Parse a raw decoded msgpack value into a typed message.
 *
 * Returns null if the value is not a valid msgpack-RPC message.
 */
export function parseMessage(value: unknown): DecodedMessage | null {
	if (!Array.isArray(value) || value.length < 3) {
		return null;
	}

	const msgType = value[0] as number;

	if (msgType === MSG_RESPONSE && value.length >= 4) {
		return {
			type: MSG_RESPONSE,
			msgid: value[1] as number,
			error: value[2],
			result: value[3],
		};
	}

	if (msgType === MSG_NOTIFICATION) {
		const paramsArr = value[2];
		let params: Record<string, unknown> = {};
		if (
			Array.isArray(paramsArr) &&
			paramsArr.length > 0 &&
			typeof paramsArr[0] === "object" &&
			paramsArr[0] !== null
		) {
			params = paramsArr[0] as Record<string, unknown>;
		}
		return {
			type: MSG_NOTIFICATION,
			method: value[1] as string,
			params,
		};
	}

	return null;
}

/**
 * Create an async iterator that yields decoded messages from a byte stream.
 *
 * Uses `decodeMultiStream` from `@msgpack/msgpack` to handle streaming
 * msgpack decoding. Each yielded value is parsed into a typed
 * {@link DecodedMessage}, skipping any malformed messages.
 *
 * @param stream - Async iterable of byte chunks (e.g., a Node.js socket).
 */
export async function* messageStream(
	stream: AsyncIterable<Uint8Array>,
): AsyncGenerator<DecodedMessage> {
	for await (const value of decodeMultiStream(stream)) {
		const msg = parseMessage(value);
		if (msg !== null) {
			yield msg;
		}
	}
}
