// ══════════════════════════════════════════════════════════════════════════
// Epoch Key Fetcher
//
// Fetches the server's current x25519 epoch public key so the client can
// wrap per-file keys for server-side CAS decryption.
//
// The epoch endpoint is PUBLIC (no auth required) — the server's epoch
// public key is analogous to the public key in a DID document.
// Endpoint: GET /api/v1/vault/epoch/current
//           → { "epoch_id": 4, "public_key": "<base64 x25519 public key>" }
//
// Keys rotate every 90 days.  The old private key is kept for a 30-day
// grace period (so files uploaded just before rotation can still be
// decrypted), then permanently deleted (forward secrecy).
// ══════════════════════════════════════════════════════════════════════════

use base64::Engine;
use serde::Deserialize;

#[derive(Deserialize)]
struct EpochResponse {
    epoch_id:   u32,
    public_key: String,   // base64-encoded 32-byte x25519 public key
}

/// Fetch the server's current epoch public key.
///
/// Returns `Err` if the server is unreachable or returns an invalid key.
/// Callers should treat `Err` as a soft failure and fall back to v1
/// `encrypt_file` so uploads still work without a reachable server.
pub async fn fetch_epoch_key(server_url: &str) -> Result<super::EpochPublicKey, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    let resp = client
        .get(format!("{}/api/v1/vault/epoch/current", server_url))
        .send()
        .await
        .map_err(|e| format!("Epoch key fetch failed: {}", e))?;

    if !resp.status().is_success() {
        let status = resp.status();
        return Err(format!("Epoch key endpoint returned HTTP {}", status));
    }

    let data: EpochResponse = resp
        .json()
        .await
        .map_err(|e| format!("Epoch key parse failed: {}", e))?;

    let key_bytes = base64::engine::general_purpose::STANDARD
        .decode(&data.public_key)
        .map_err(|e| format!("Invalid epoch public key encoding: {}", e))?;

    if key_bytes.len() != 32 {
        return Err(format!("Invalid epoch key length: {} (expected 32)", key_bytes.len()));
    }

    let mut arr = [0u8; 32];
    arr.copy_from_slice(&key_bytes);

    log::info!("🔑 [Epoch] Fetched epoch_id={} from {}", data.epoch_id, server_url);
    Ok(super::EpochPublicKey { epoch_id: data.epoch_id, public_key: arr })
}
