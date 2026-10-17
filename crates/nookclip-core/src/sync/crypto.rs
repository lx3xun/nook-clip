use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use hmac::Hmac;
use pbkdf2::pbkdf2;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::error::CoreError;

pub const ENVELOPE_MAGIC: &[u8; 6] = b"NCENC1";
pub const DEFAULT_KDF_ITERATIONS: u32 = 100_000;
const VERIFIER_PLAINTEXT: &[u8] = b"NOOKCLIP_SYNC_VERIFIER_V1";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncManifest {
    pub version: u32,
    pub kdf_salt_hex: String,
    pub kdf_iterations: u32,
    pub verifier_nonce_hex: String,
    pub verifier_ciphertext_hex: String,
}

impl SyncManifest {
    pub fn to_bytes(&self) -> Result<Vec<u8>, CoreError> {
        serde_json::to_vec_pretty(self)
            .map_err(|e| CoreError::InvalidData(format!("Serialize sync manifest failed: {e}")))
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, CoreError> {
        serde_json::from_slice(bytes)
            .map_err(|e| CoreError::InvalidData(format!("Parse sync manifest failed: {e}")))
    }
}

pub fn derive_sync_key(passphrase: &str, salt: &[u8], iterations: u32) -> [u8; 32] {
    let mut key = [0u8; 32];
    let _ = pbkdf2::<Hmac<Sha256>>(passphrase.as_bytes(), salt, iterations, &mut key);
    key
}

pub fn create_manifest(passphrase: &str) -> Result<(SyncManifest, [u8; 32]), CoreError> {
    let mut salt = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut salt);

    let key = derive_sync_key(passphrase, &salt, DEFAULT_KDF_ITERATIONS);
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|e| CoreError::Crypto(format!("Failed to create cipher: {e}")))?;

    let mut nonce_bytes = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, VERIFIER_PLAINTEXT)
        .map_err(|e| CoreError::Crypto(format!("Failed to encrypt verifier: {e}")))?;

    let manifest = SyncManifest {
        version: 1,
        kdf_salt_hex: hex_encode(&salt),
        kdf_iterations: DEFAULT_KDF_ITERATIONS,
        verifier_nonce_hex: hex_encode(&nonce_bytes),
        verifier_ciphertext_hex: hex_encode(&ciphertext),
    };

    Ok((manifest, key))
}

pub fn verify_manifest(manifest: &SyncManifest, passphrase: &str) -> Result<[u8; 32], CoreError> {
    let salt = hex_decode(&manifest.kdf_salt_hex)
        .map_err(|e| CoreError::InvalidData(format!("Invalid salt hex: {e}")))?;
    let nonce_bytes = hex_decode(&manifest.verifier_nonce_hex)
        .map_err(|e| CoreError::InvalidData(format!("Invalid verifier nonce hex: {e}")))?;
    let ciphertext = hex_decode(&manifest.verifier_ciphertext_hex)
        .map_err(|e| CoreError::InvalidData(format!("Invalid verifier ciphertext hex: {e}")))?;

    if nonce_bytes.len() != 12 {
        return Err(CoreError::InvalidData("Verifier nonce must be 12 bytes".to_string()));
    }

    let iterations = if manifest.kdf_iterations > 0 {
        manifest.kdf_iterations
    } else {
        DEFAULT_KDF_ITERATIONS
    };

    let key = derive_sync_key(passphrase, &salt, iterations);
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|e| CoreError::Crypto(format!("Cipher init failed: {e}")))?;

    let nonce = Nonce::from_slice(&nonce_bytes);
    let decrypted = cipher
        .decrypt(nonce, ciphertext.as_ref())
        .map_err(|_| CoreError::Crypto("Sync passphrase mismatch or corrupted manifest".to_string()))?;

    if decrypted != VERIFIER_PLAINTEXT {
        return Err(CoreError::Crypto("Sync passphrase mismatch".to_string()));
    }

    Ok(key)
}

pub fn is_encrypted_envelope(data: &[u8]) -> bool {
    data.starts_with(ENVELOPE_MAGIC)
}

pub fn encrypt_envelope(data: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, CoreError> {
    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|e| CoreError::Crypto(format!("Cipher init failed: {e}")))?;

    let mut salt = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut salt);

    let mut nonce_bytes = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, data)
        .map_err(|e| CoreError::Crypto(format!("Envelope encryption failed: {e}")))?;

    let mut out = Vec::with_capacity(ENVELOPE_MAGIC.len() + 16 + 12 + ciphertext.len());
    out.extend_from_slice(ENVELOPE_MAGIC);
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

pub fn decrypt_envelope(data: &[u8], key: Option<&[u8; 32]>) -> Result<Vec<u8>, CoreError> {
    if !is_encrypted_envelope(data) {
        return Ok(data.to_vec());
    }

    let key = match key {
        Some(k) => k,
        None => return Err(CoreError::Crypto("Sync passphrase required to decrypt envelope".to_string())),
    };

    const HEADER_LEN: usize = 6 + 16 + 12; // Magic(6) + Salt(16) + Nonce(12)
    if data.len() < HEADER_LEN + 16 {
        return Err(CoreError::InvalidData("Envelope payload too short".to_string()));
    }

    let nonce_bytes = &data[22..34];
    let ciphertext = &data[34..];

    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|e| CoreError::Crypto(format!("Cipher init failed: {e}")))?;
    let nonce = Nonce::from_slice(nonce_bytes);

    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| CoreError::Crypto(format!("Envelope decryption failed (wrong passphrase or corrupted payload): {e}")))
}

fn hex_encode(data: &[u8]) -> String {
    let mut s = String::with_capacity(data.len() * 2);
    for b in data {
        use std::fmt::Write;
        let _ = write!(s, "{:02x}", b);
    }
    s
}

fn hex_decode(s: &str) -> Result<Vec<u8>, String> {
    let bytes_input = s.as_bytes();
    if bytes_input.len() % 2 != 0 {
        return Err("Odd length hex string".to_string());
    }
    let mut bytes = Vec::with_capacity(bytes_input.len() / 2);
    for chunk in bytes_input.chunks_exact(2) {
        let hi = match (chunk[0] as char).to_digit(16) {
            Some(v) => v as u8,
            None => return Err(format!("Invalid hex byte: {}", chunk[0])),
        };
        let lo = match (chunk[1] as char).to_digit(16) {
            Some(v) => v as u8,
            None => return Err(format!("Invalid hex byte: {}", chunk[1])),
        };
        bytes.push((hi << 4) | lo);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_manifest_roundtrip_and_verification() {
        let passphrase = "my-secret-sync-password-2026";
        let (manifest, key1) = create_manifest(passphrase).unwrap();

        let bytes = manifest.to_bytes().unwrap();
        let parsed = SyncManifest::from_bytes(&bytes).unwrap();
        assert_eq!(manifest, parsed);

        let key2 = verify_manifest(&parsed, passphrase).unwrap();
        assert_eq!(key1, key2);

        let err = verify_manifest(&parsed, "wrong-password");
        assert!(err.is_err());
    }

    #[test]
    fn test_envelope_encryption_roundtrip() {
        let key = [7u8; 32];
        let plaintext = b"Hello, NookClip Multiplatform Sync with NCENC1 E2EE!";

        let encrypted = encrypt_envelope(plaintext, &key).unwrap();
        assert!(is_encrypted_envelope(&encrypted));
        assert_ne!(&encrypted[..], plaintext);

        let decrypted = decrypt_envelope(&encrypted, Some(&key)).unwrap();
        assert_eq!(decrypted, plaintext);

        let err = decrypt_envelope(&encrypted, None);
        assert!(err.is_err());

        let wrong_key = [8u8; 32];
        let err2 = decrypt_envelope(&encrypted, Some(&wrong_key));
        assert!(err2.is_err());
    }
}
