// ══════════════════════════════════════════════════════════════════════════
// Vault Encryption Module
//
// Provides at-rest encryption for all binary file content stored on disk.
// Algorithm: ChaCha20-Poly1305 (AEAD)
//   - ChaCha20: stream cipher (fast on ARM/mobile, no hardware AES needed)
//   - Poly1305: authentication tag (detects tampering / corruption)
//
// Wire format stored as .vault files:
//   Header (16 bytes):
//     [4]  magic: b"ALEM"
//     [4]  version: 1u32 little-endian
//     [8]  original_size: u64 little-endian
//   Chunks (repeated until EOF):
//     [4]  enc_len: u32 LE  — byte length of the encrypted chunk (plain + 16 tag)
//     [12] nonce             — fresh random nonce for this chunk
//     [enc_len] ciphertext  — ChaCha20-Poly1305 output
//
// Key management (priority order):
//   1. OS Keychain (Windows Credential Store / macOS Keychain / Linux Secret Service)
//   2. SQLite local_identity.vault_key (legacy — migrated to keychain on first load)
//   3. Generate new random key → save to keychain
//
// The sync engine sends ENCRYPTED bytes to the server — true E2EE.
// ══════════════════════════════════════════════════════════════════════════

pub mod epoch;
pub mod przma_vault;

use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305, Nonce,
};
use argon2::{Argon2, Algorithm, Version, Params};
use keyring::Entry;
use base64::Engine;
use hkdf::Hkdf;
use rand::RngCore;
use sha2::Sha256;
use x25519_dalek::{EphemeralSecret, PublicKey as X25519PublicKey};
use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::Path;

// ── Epoch key types ───────────────────────────────────────────────────────

/// Server's current x25519 epoch public key (fetched from /api/v1/vault/epoch/current).
/// Rotated every 90 days. Client uses this to wrap the per-file key so the
/// server can decrypt vault files for CAS content extraction.
#[derive(Clone, Copy)]
pub struct EpochPublicKey {
    pub epoch_id:   u32,
    pub public_key: [u8; 32],   // x25519 public key bytes
}

/// Returned by `encrypt_file_v2` — original size + the epoch used.
/// The caller passes epoch_id to the server during upload so it knows
/// which epoch private key to use for CAS decryption.
pub struct EncryptResult {
    pub original_size: u64,
    pub epoch_id:      u32,
}

// ══════════════════════════════════════════════════════════════════════════
// Vault v2 header layout  (169 bytes)
//
//  Offset  Bytes  Field
//  ------  -----  -----
//    0       4    magic: b"ALEM"
//    4       1    version: 2
//    5       8    original_size: u64 LE
//   13       4    epoch_id: u32 LE  (which server epoch key was used)
//   17      32    ephemeral_public_key: x25519 (server reads this for ECDH)
//   49      12    local_nonce: ChaCha20 nonce for local_wrapped_key
//   61      48    local_wrapped_key: ChaCha20Poly1305(file_key, local_permanent_key)
//  109      12    server_nonce: ChaCha20 nonce for server_wrapped_key
//  121      48    server_wrapped_key: ChaCha20Poly1305(file_key, HKDF(ECDH(ephemeral, epoch_pub)))
//  169+     ...   encrypted chunks (same format as v1)
//
// Chunk format (v1 and v2 share the same chunk layout):
//   [4]   enc_len: u32 LE   (plaintext_chunk + 16-byte Poly1305 tag)
//   [12]  nonce
//   [enc_len] ciphertext
//
// Decryption paths:
//   Client → unwrap file_key via local_wrapped_key (local permanent key, OS keychain)
//   Server → unwrap file_key via server_wrapped_key (ECDH epoch key)
// ══════════════════════════════════════════════════════════════════════════

/// Encrypt `input_path` into a v2 dual-key vault file at `output_path`.
///
/// A fresh random `file_key` is generated per file and wrapped twice:
///   1. With the client's permanent local key (OS keychain) → client can always decrypt
///   2. With ECDH(ephemeral_private, server_epoch_public) derived key → server can decrypt
///      for CAS content extraction without ever having the client's keychain key.
pub fn encrypt_file_v2<F>(
    input_path:  &Path,
    output_path: &Path,
    local_key:   &VaultKey,        // OS keychain key — for local decrypt
    epoch_pub:   &EpochPublicKey,  // server epoch x25519 public key
    on_progress: F,
) -> Result<EncryptResult, String>
where
    F: Fn(u64, u64),
{
    let original_size = input_path
        .metadata()
        .map_err(|e| format!("Cannot stat '{}': {}", input_path.display(), e))?
        .len();

    // ── 1. Generate a random per-file encryption key ──────────────────────
    let mut file_key = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut file_key);

    // ── 2. Local wrapping: seal file_key with the OS keychain key ─────────
    let local_cipher = ChaCha20Poly1305::new_from_slice(&local_key.0).expect("32-byte key");
    let mut local_nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut local_nonce);
    let local_wrapped = local_cipher
        .encrypt(Nonce::from_slice(&local_nonce), file_key.as_slice())
        .map_err(|e| format!("Local key wrap failed: {:?}", e))?;
    // local_wrapped = 32 (key) + 16 (tag) = 48 bytes

    // ── 3. Server wrapping: ECDH → HKDF → seal file_key ──────────────────
    let ephemeral_secret = EphemeralSecret::random_from_rng(rand::thread_rng());
    let ephemeral_public = X25519PublicKey::from(&ephemeral_secret);
    let server_pub       = X25519PublicKey::from(epoch_pub.public_key);
    let shared_secret    = ephemeral_secret.diffie_hellman(&server_pub);

    // HKDF-SHA256: shared_secret → 32-byte server wrapper key
    let hk = Hkdf::<Sha256>::new(None, shared_secret.as_bytes());
    let mut server_wrap_key = [0u8; 32];
    hk.expand(b"przma-vault-server-v2", &mut server_wrap_key)
        .map_err(|e| format!("HKDF expand failed: {}", e))?;

    let server_cipher = ChaCha20Poly1305::new_from_slice(&server_wrap_key).expect("32-byte key");
    let mut server_nonce = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut server_nonce);
    let server_wrapped = server_cipher
        .encrypt(Nonce::from_slice(&server_nonce), file_key.as_slice())
        .map_err(|e| format!("Server key wrap failed: {:?}", e))?;
    // server_wrapped = 32 (key) + 16 (tag) = 48 bytes

    // ── 4. Write vault file header (169 bytes) ────────────────────────────
    let output = File::create(output_path)
        .map_err(|e| format!("Cannot create vault file: {}", e))?;
    let mut writer = BufWriter::new(output);

    writer.write_all(VAULT_MAGIC).map_err(|e| e.to_string())?;                           // [4]
    writer.write_all(&[2u8]).map_err(|e| e.to_string())?;                                 // [1]
    writer.write_all(&original_size.to_le_bytes()).map_err(|e| e.to_string())?;           // [8]
    writer.write_all(&epoch_pub.epoch_id.to_le_bytes()).map_err(|e| e.to_string())?;      // [4]
    writer.write_all(ephemeral_public.as_bytes()).map_err(|e| e.to_string())?;            // [32]
    writer.write_all(&local_nonce).map_err(|e| e.to_string())?;                           // [12]
    writer.write_all(&local_wrapped).map_err(|e| e.to_string())?;                         // [48]
    writer.write_all(&server_nonce).map_err(|e| e.to_string())?;                          // [12]
    writer.write_all(&server_wrapped).map_err(|e| e.to_string())?;                        // [48]
    // Total header bytes: 4+1+8+4+32+12+48+12+48 = 169

    // ── 5. Encrypt file chunks with the per-file key ──────────────────────
    let file_cipher = ChaCha20Poly1305::new_from_slice(&file_key).expect("32-byte key");
    let input = File::open(input_path)
        .map_err(|e| format!("Cannot open '{}': {}", input_path.display(), e))?;
    let mut reader    = BufReader::new(input);
    let mut buf       = vec![0u8; CHUNK_SIZE];
    let mut processed = 0u64;
    let mut last_rep  = 0u64;

    loop {
        let n = reader.read(&mut buf).map_err(|e| format!("Read error: {}", e))?;
        if n == 0 { break; }

        let mut nonce_bytes = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        let encrypted = file_cipher
            .encrypt(nonce, &buf[..n])
            .map_err(|e| format!("Chunk encrypt error: {:?}", e))?;

        writer.write_all(&(encrypted.len() as u32).to_le_bytes()).map_err(|e| e.to_string())?;
        writer.write_all(&nonce_bytes).map_err(|e| e.to_string())?;
        writer.write_all(&encrypted).map_err(|e| e.to_string())?;

        processed += n as u64;
        if processed.saturating_sub(last_rep) >= PROGRESS_INTERVAL {
            on_progress(processed, original_size);
            last_rep = processed;
        }
    }

    writer.flush().map_err(|e| e.to_string())?;
    on_progress(original_size, original_size);

    // Zero sensitive key material before dropping
    file_key.fill(0);
    server_wrap_key.fill(0);

    log::info!("🔐 [Vault v2] Encrypted '{}' with epoch_id={}", input_path.display(), epoch_pub.epoch_id);
    Ok(EncryptResult { original_size, epoch_id: epoch_pub.epoch_id })
}

/// Decrypt a v2 vault file using the client's permanent local key (OS keychain).
///
/// Reads `local_wrapped_key` from the header → unwraps `file_key` → decrypts chunks.
/// The server's `server_wrapped_key` in the header is ignored here.
pub fn decrypt_file_v2(vault_path: &Path, local_key: &VaultKey) -> Result<Vec<u8>, String> {
    let file = File::open(vault_path)
        .map_err(|e| format!("Cannot open vault file: {}", e))?;
    let mut reader = BufReader::new(file);

    // magic
    let mut magic = [0u8; 4];
    reader.read_exact(&mut magic).map_err(|e| e.to_string())?;
    if &magic != VAULT_MAGIC {
        return Err("Not a valid vault file (bad magic)".to_string());
    }
    // version
    let mut ver = [0u8; 1];
    reader.read_exact(&mut ver).map_err(|e| e.to_string())?;
    if ver[0] != 2 {
        return Err(format!("Expected vault v2, got version {}", ver[0]));
    }
    // original_size
    let mut size_buf = [0u8; 8];
    reader.read_exact(&mut size_buf).map_err(|e| e.to_string())?;
    let original_size = u64::from_le_bytes(size_buf) as usize;

    // epoch_id (skip — not needed for client decrypt)
    let mut _skip4 = [0u8; 4];
    reader.read_exact(&mut _skip4).map_err(|e| e.to_string())?;

    // ephemeral_public_key (skip — only server needs this)
    let mut _skip32 = [0u8; 32];
    reader.read_exact(&mut _skip32).map_err(|e| e.to_string())?;

    // local_nonce + local_wrapped_key
    let mut local_nonce   = [0u8; 12];
    let mut local_wrapped = [0u8; 48];
    reader.read_exact(&mut local_nonce).map_err(|e| e.to_string())?;
    reader.read_exact(&mut local_wrapped).map_err(|e| e.to_string())?;

    // server_nonce + server_wrapped_key (skip)
    let mut _skip12 = [0u8; 12];
    let mut _skip48 = [0u8; 48];
    reader.read_exact(&mut _skip12).map_err(|e| e.to_string())?;
    reader.read_exact(&mut _skip48).map_err(|e| e.to_string())?;

    // Unwrap file_key using local permanent key
    let local_cipher  = ChaCha20Poly1305::new_from_slice(&local_key.0).expect("32-byte key");
    let file_key_bytes = local_cipher
        .decrypt(Nonce::from_slice(&local_nonce), local_wrapped.as_slice())
        .map_err(|_| "Local key unwrap failed — wrong key or corrupted header".to_string())?;

    // Decrypt chunks
    let file_cipher = ChaCha20Poly1305::new_from_slice(&file_key_bytes).expect("32-byte key");
    let mut plaintext = Vec::with_capacity(original_size);

    loop {
        let mut len_buf = [0u8; 4];
        match reader.read_exact(&mut len_buf) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(format!("Read chunk len: {}", e)),
        }
        let enc_len = u32::from_le_bytes(len_buf) as usize;
        let mut nonce_bytes = [0u8; 12];
        reader.read_exact(&mut nonce_bytes).map_err(|e| e.to_string())?;
        let mut enc_chunk = vec![0u8; enc_len];
        reader.read_exact(&mut enc_chunk).map_err(|e| e.to_string())?;

        let chunk = file_cipher
            .decrypt(Nonce::from_slice(&nonce_bytes), enc_chunk.as_slice())
            .map_err(|_| "Chunk decrypt failed — tampered or wrong key".to_string())?;
        plaintext.extend_from_slice(&chunk);
    }

    Ok(plaintext)
}

/// Detect vault version and dispatch to the correct decrypt function.
/// v1 → uses static `local_key` directly.
/// v2 → unwraps per-file key from `local_wrapped_key` in header, then decrypts.
pub fn decrypt_file_any(vault_path: &Path, local_key: &VaultKey) -> Result<Vec<u8>, String> {
    let file = File::open(vault_path)
        .map_err(|e| format!("Cannot open vault file: {}", e))?;
    let mut reader = BufReader::new(file);

    let mut magic = [0u8; 4];
    reader.read_exact(&mut magic).map_err(|e| e.to_string())?;
    if &magic != VAULT_MAGIC {
        return Err("Not a valid vault file (bad magic)".to_string());
    }
    let mut ver = [0u8; 1];
    reader.read_exact(&mut ver).map_err(|e| e.to_string())?;

    // v1 version field is 4 bytes [1,0,0,0] — byte[4] = 1
    // v2 version field is 1 byte   [2]      — byte[4] = 2
    match ver[0] {
        1 => decrypt_file(vault_path, local_key),
        2 => decrypt_file_v2(vault_path, local_key),
        v => Err(format!("Unknown vault version: {}", v)),
    }
}

// ── Constants ─────────────────────────────────────────────────────────────

const CHUNK_SIZE: usize = 65_536;        // 64 KB read/write buffer per chunk
const VAULT_MAGIC: &[u8; 4] = b"ALEM";

/// OS keychain service name (identifies the app)
const KEYRING_SERVICE: &str = "przma-desktop";
/// OS keychain account name (identifies which secret)
const KEYRING_ACCOUNT: &str = "vault-key";

/// Emit a progress event every 5 MB of plaintext processed
const PROGRESS_INTERVAL: u64 = 5 * 1024 * 1024;

// Argon2id parameters (OWASP recommended minimums)
const ARGON2_MEMORY_KB:   u32 = 65_536; // 64 MB
const ARGON2_ITERATIONS:  u32 = 3;
const ARGON2_PARALLELISM: u32 = 4;

// ── VaultKey ──────────────────────────────────────────────────────────────

pub struct VaultKey([u8; 32]);

impl VaultKey {
    /// Generate a cryptographically random 32-byte key.
    pub fn generate() -> Self {
        let mut bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);
        Self(bytes)
    }

    /// Derive a deterministic key from a user password + 32-byte salt using Argon2id.
    ///
    /// Parameters follow OWASP recommendations:
    ///   - 64 MB memory cost
    ///   - 3 iterations
    ///   - 4 parallel threads
    pub fn derive_from_password(password: &str, salt: &[u8; 32]) -> Result<Self, String> {
        let params = Params::new(ARGON2_MEMORY_KB, ARGON2_ITERATIONS, ARGON2_PARALLELISM, Some(32))
            .map_err(|e| format!("Argon2 params error: {}", e))?;
        let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

        let mut key = [0u8; 32];
        argon2
            .hash_password_into(password.as_bytes(), salt, &mut key)
            .map_err(|e| format!("Argon2 key derivation failed: {}", e))?;

        log::info!("🔐 [Vault] Key derived via Argon2id");
        Ok(Self(key))
    }

    /// Save this key to the OS keychain.
    ///
    /// - Windows: Windows Credential Store
    /// - macOS:   Keychain
    /// - Linux:   Secret Service (libsecret)
    pub fn save_to_keyring(&self) -> Result<(), String> {
        let entry = Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
            .map_err(|e| format!("Keychain entry create failed: {}", e))?;
        entry
            .set_password(&self.to_b64())
            .map_err(|e| format!("Keychain save failed: {}", e))?;
        log::info!("🔐 [Vault] Key saved to OS keychain");
        Ok(())
    }

    /// Load the key from the OS keychain.
    ///
    /// Returns `Ok(None)` if no entry exists yet (first run or new device).
    pub fn load_from_keyring() -> Result<Option<Self>, String> {
        let entry = Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
            .map_err(|e| format!("Keychain entry create failed: {}", e))?;
        match entry.get_password() {
            Ok(b64) => {
                log::info!("🔐 [Vault] Key loaded from OS keychain");
                Ok(Some(Self::from_b64(&b64)?))
            }
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(format!("Keychain load failed: {}", e)),
        }
    }

    /// Restore a key from a base64 string (legacy SQLite storage).
    pub fn from_b64(s: &str) -> Result<Self, String> {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(s)
            .map_err(|e| format!("Invalid vault key encoding: {}", e))?;
        if bytes.len() != 32 {
            return Err(format!("Vault key must be 32 bytes, got {}", bytes.len()));
        }
        let mut arr = [0u8; 32];
        arr.copy_from_slice(&bytes);
        Ok(Self(arr))
    }

    /// Encode the key as base64 (for fallback SQLite storage).
    pub fn to_b64(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(&self.0)
    }

    // ── In-memory encrypt/decrypt (for small blobs) ───────────────────────

    /// Encrypts `plaintext` → [12-byte nonce] + [ciphertext + auth tag].
    ///
    /// A fresh random nonce is generated for every call.
    pub fn encrypt(&self, plaintext: &[u8]) -> Vec<u8> {
        let cipher = ChaCha20Poly1305::new_from_slice(&self.0)
            .expect("Key is always 32 bytes");

        let mut nonce_bytes = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        let ciphertext = cipher
            .encrypt(nonce, plaintext)
            .expect("ChaCha20-Poly1305 encryption is infallible for valid inputs");

        let mut out = Vec::with_capacity(12 + ciphertext.len());
        out.extend_from_slice(&nonce_bytes);
        out.extend(ciphertext);
        out
    }

    /// Decrypts `data` (nonce + ciphertext) → plaintext.
    ///
    /// Returns `Err` if the auth tag fails (tampered / wrong key).
    pub fn decrypt(&self, data: &[u8]) -> Result<Vec<u8>, String> {
        if data.len() < 12 {
            return Err(format!(
                "Encrypted data too short ({} bytes, minimum 12)",
                data.len()
            ));
        }
        let (nonce_bytes, ciphertext) = data.split_at(12);
        let nonce = Nonce::from_slice(nonce_bytes);
        let cipher = ChaCha20Poly1305::new_from_slice(&self.0)
            .expect("Key is always 32 bytes");

        cipher
            .decrypt(nonce, ciphertext)
            .map_err(|_| "Decryption failed — data corrupted or wrong key".to_string())
    }
}

// ── Streaming file encryption ─────────────────────────────────────────────

/// Reads `input_path` in 64 KB chunks, encrypts each chunk independently
/// with a fresh nonce, and writes the ALEM vault format to `output_path`.
///
/// Memory use: constant ~64 KB regardless of file size.
///
/// `on_progress(bytes_processed, bytes_total)` is called after each PROGRESS_INTERVAL
/// (5 MB) of plaintext is encrypted — useful for emitting progress events to
/// the frontend on large files. Pass `|_, _| {}` to disable.
///
/// Returns the original file size in bytes.
pub fn encrypt_file<F>(
    input_path:  &Path,
    output_path: &Path,
    key:         &VaultKey,
    on_progress: F,
) -> Result<u64, String>
where
    F: Fn(u64, u64),
{
    let original_size = input_path
        .metadata()
        .map_err(|e| format!("Cannot stat '{}': {}", input_path.display(), e))?
        .len();

    let input = File::open(input_path)
        .map_err(|e| format!("Cannot open '{}': {}", input_path.display(), e))?;
    let output = File::create(output_path)
        .map_err(|e| format!("Cannot create vault file: {}", e))?;

    let mut reader = BufReader::new(input);
    let mut writer = BufWriter::new(output);

    // Write 16-byte ALEM header
    writer.write_all(VAULT_MAGIC).map_err(|e| e.to_string())?;
    writer.write_all(&1u32.to_le_bytes()).map_err(|e| e.to_string())?;
    writer.write_all(&original_size.to_le_bytes()).map_err(|e| e.to_string())?;

    let cipher = ChaCha20Poly1305::new_from_slice(&key.0).expect("32-byte key");
    let mut buf = vec![0u8; CHUNK_SIZE];

    let mut processed:     u64 = 0;
    let mut last_reported: u64 = 0;

    loop {
        let n = reader.read(&mut buf).map_err(|e| format!("Read error: {}", e))?;
        if n == 0 {
            break;
        }

        let mut nonce_bytes = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        let encrypted = cipher
            .encrypt(nonce, &buf[..n])
            .map_err(|e| format!("Chunk encrypt error: {:?}", e))?;

        // Write chunk: [enc_len 4B][nonce 12B][ciphertext]
        writer
            .write_all(&(encrypted.len() as u32).to_le_bytes())
            .map_err(|e| e.to_string())?;
        writer.write_all(&nonce_bytes).map_err(|e| e.to_string())?;
        writer.write_all(&encrypted).map_err(|e| e.to_string())?;

        processed += n as u64;

        // Emit progress every PROGRESS_INTERVAL bytes (5 MB)
        if processed.saturating_sub(last_reported) >= PROGRESS_INTERVAL {
            on_progress(processed, original_size);
            last_reported = processed;
        }
    }

    writer.flush().map_err(|e| e.to_string())?;

    // Final 100% notification
    on_progress(original_size, original_size);

    Ok(original_size)
}

/// Decrypts a vault file written by `encrypt_file` and returns the plaintext.
pub fn decrypt_file(vault_path: &Path, key: &VaultKey) -> Result<Vec<u8>, String> {
    let file = File::open(vault_path)
        .map_err(|e| format!("Cannot open vault file: {}", e))?;
    let mut reader = BufReader::new(file);

    // Verify magic
    let mut magic = [0u8; 4];
    reader.read_exact(&mut magic).map_err(|e| e.to_string())?;
    if &magic != VAULT_MAGIC {
        return Err("Not a valid vault file (bad magic)".to_string());
    }

    let mut _ver = [0u8; 4];
    reader.read_exact(&mut _ver).map_err(|e| e.to_string())?;

    let mut size_bytes = [0u8; 8];
    reader.read_exact(&mut size_bytes).map_err(|e| e.to_string())?;
    let original_size = u64::from_le_bytes(size_bytes) as usize;

    let cipher = ChaCha20Poly1305::new_from_slice(&key.0).expect("32-byte key");
    let mut plaintext = Vec::with_capacity(original_size);

    loop {
        let mut len_buf = [0u8; 4];
        match reader.read_exact(&mut len_buf) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(format!("Read chunk len: {}", e)),
        }
        let enc_len = u32::from_le_bytes(len_buf) as usize;

        let mut nonce_bytes = [0u8; 12];
        reader.read_exact(&mut nonce_bytes).map_err(|e| e.to_string())?;

        let mut enc_chunk = vec![0u8; enc_len];
        reader.read_exact(&mut enc_chunk).map_err(|e| e.to_string())?;

        let nonce = Nonce::from_slice(&nonce_bytes);
        let chunk = cipher
            .decrypt(nonce, enc_chunk.as_slice())
            .map_err(|_| "Chunk decrypt failed — tampered or wrong key".to_string())?;

        plaintext.extend_from_slice(&chunk);
    }

    Ok(plaintext)
}

// ── Key bootstrap ─────────────────────────────────────────────────────────

/// Loads the vault key using a priority chain, or generates + stores a new one.
///
/// Priority:
///   1. OS keychain (Windows Credential Store / macOS Keychain / Linux Secret Service)
///   2. SQLite `local_identity.vault_key` — legacy path; migrated to keychain on first load
///   3. Generate new random 256-bit key → save to keychain
///
/// Called once at app startup before `AppState` is created.
pub async fn load_or_generate_key(db: &libsql::Database) -> Result<VaultKey, String> {
    // ── Step 1: OS keychain ───────────────────────────────────────────────
    match VaultKey::load_from_keyring() {
        Ok(Some(key)) => return Ok(key),
        Ok(None) => {}
        Err(e) => log::warn!("🔐 [Vault] Keychain unavailable (non-fatal): {}", e),
    }

    // ── Step 2: SQLite legacy path (migrate to keychain) ─────────────────
    let conn = crate::db::connect(db).await.map_err(|e| e.to_string())?;

    let mut rows = conn
        .query(
            "SELECT vault_key FROM local_identity WHERE id = 'singleton'",
            (),
        )
        .await
        .map_err(|e| e.to_string())?;

    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        if let Ok(libsql::Value::Text(b64)) = row.get_value(0) {
            if !b64.is_empty() {
                let key = VaultKey::from_b64(&b64)?;
                log::info!("🔐 [Vault] Key found in SQLite — migrating to OS keychain");

                // Migrate: move the key to the keychain
                match key.save_to_keyring() {
                    Ok(_) => {
                        // Clear the plain-text key from SQLite for security
                        let _ = conn
                            .execute(
                                "UPDATE local_identity SET vault_key = '' WHERE id = 'singleton'",
                                (),
                            )
                            .await;
                        log::info!("🔐 [Vault] Migration complete — plain-text key cleared from SQLite");
                    }
                    Err(e) => {
                        log::warn!("🔐 [Vault] Keychain migration failed (keeping in SQLite): {}", e);
                    }
                }

                return Ok(key);
            }
        }
    }

    // ── Step 3: Generate a new key ────────────────────────────────────────
    let key = VaultKey::generate();

    match key.save_to_keyring() {
        Ok(_) => {
            log::info!("🔐 [Vault] New key generated and saved to OS keychain");
        }
        Err(e) => {
            log::warn!("🔐 [Vault] Keychain save failed — falling back to SQLite: {}", e);
            // Fallback: store in SQLite (keychain unavailable, e.g. headless CI)
            conn.execute(
                "INSERT INTO local_identity (id, vault_key)
                 VALUES ('singleton', ?)
                 ON CONFLICT(id) DO UPDATE SET vault_key = excluded.vault_key",
                libsql::params![key.to_b64()],
            )
            .await
            .map_err(|e| e.to_string())?;
        }
    }

    Ok(key)
}
