use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use rand::RngCore;

use crate::error::{CoreError, Result};

pub struct CryptoEngine {
    cipher: Aes256Gcm,
}

impl CryptoEngine {
    pub fn new(master_key: &[u8]) -> Result<Self> {
        if master_key.len() != 32 {
            return Err(CoreError::Crypto(format!(
                "Master key must be exactly 32 bytes, got {}",
                master_key.len()
            )));
        }
        let cipher =
            Aes256Gcm::new_from_slice(master_key).map_err(|e| CoreError::Crypto(e.to_string()))?;
        Ok(Self { cipher })
    }

    pub fn encrypt(&self, plaintext: &str) -> Result<(Vec<u8>, [u8; 12])> {
        let mut nonce_bytes = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        let ciphertext = self
            .cipher
            .encrypt(nonce, plaintext.as_bytes())
            .map_err(|e| CoreError::Crypto(e.to_string()))?;

        Ok((ciphertext, nonce_bytes))
    }

    pub fn decrypt(&self, ciphertext: &[u8], nonce_bytes: &[u8]) -> Result<String> {
        if nonce_bytes.len() != 12 {
            return Err(CoreError::Crypto(format!(
                "Nonce must be exactly 12 bytes, got {}",
                nonce_bytes.len()
            )));
        }
        let nonce = Nonce::from_slice(nonce_bytes);
        let plaintext_bytes = self
            .cipher
            .decrypt(nonce, ciphertext)
            .map_err(|e| CoreError::Crypto(e.to_string()))?;

        String::from_utf8(plaintext_bytes)
            .map_err(|e| CoreError::Crypto(format!("Decrypted bytes not valid UTF-8: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = [42u8; 32];
        let engine = CryptoEngine::new(&key).expect("engine creation");

        let secret = "sk-live-secret-token-1234567890";
        let (ciphertext, nonce) = engine.encrypt(secret).expect("encrypt");
        assert_ne!(ciphertext, secret.as_bytes());

        let decrypted = engine.decrypt(&ciphertext, &nonce).expect("decrypt");
        assert_eq!(decrypted, secret);
    }

    #[test]
    fn test_invalid_key_length() {
        let key = [1u8; 16];
        assert!(CryptoEngine::new(&key).is_err());
    }
}
