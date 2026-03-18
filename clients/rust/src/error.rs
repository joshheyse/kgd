//! Error types for the kgd client library.

use std::fmt;

/// All errors that can occur when communicating with the kgd daemon.
#[derive(Debug)]
pub enum KgdError {
    /// Failed to connect to the daemon's Unix socket.
    Connect(std::io::Error),

    /// The initial hello handshake failed.
    Hello(String),

    /// Failed to send data on the socket.
    Send(std::io::Error),

    /// Failed to receive data from the socket.
    Recv(std::io::Error),

    /// Failed to decode a msgpack message.
    Decode(String),

    /// The daemon returned an RPC-level error.
    Rpc(String),

    /// An RPC call timed out waiting for a response.
    Timeout(String),

    /// The daemon was not found in PATH when attempting auto-launch.
    DaemonNotFound,

    /// The daemon failed to start within the expected time.
    DaemonLaunchTimeout,

    /// The connection was closed before a response was received.
    ConnectionClosed,
}

impl fmt::Display for KgdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            KgdError::Connect(e) => write!(f, "connect: {e}"),
            KgdError::Hello(msg) => write!(f, "hello: {msg}"),
            KgdError::Send(e) => write!(f, "send: {e}"),
            KgdError::Recv(e) => write!(f, "recv: {e}"),
            KgdError::Decode(msg) => write!(f, "decode: {msg}"),
            KgdError::Rpc(msg) => write!(f, "rpc error: {msg}"),
            KgdError::Timeout(method) => write!(f, "timeout waiting for response to {method}"),
            KgdError::DaemonNotFound => write!(f, "kgd binary not found in PATH"),
            KgdError::DaemonLaunchTimeout => {
                write!(f, "timed out waiting for kgd daemon to start")
            }
            KgdError::ConnectionClosed => write!(f, "connection closed"),
        }
    }
}

impl std::error::Error for KgdError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            KgdError::Connect(e) | KgdError::Send(e) | KgdError::Recv(e) => Some(e),
            _ => None,
        }
    }
}

/// Convenience alias used throughout the crate.
pub type Result<T> = std::result::Result<T, KgdError>;
