"""
IrisAI — AES-256-GCM Encrypted Dose Log
========================================
All medical data is encrypted at rest using AES-256-GCM.
Key is derived from a passphrase via PBKDF2-HMAC-SHA256.
"""

import json
import os
import base64
import logging
from pathlib import Path
from typing import Optional
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes

logger = logging.getLogger("iris.security")

# Fixed salt for demo — in production, generate per-user and store alongside ciphertext
_SALT = b"IrisAI_Medicine_2026"


def _derive_key(passphrase: str) -> bytes:
    """Derive a 256-bit key from passphrase using PBKDF2."""
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=_SALT,
        iterations=100_000,
    )
    return kdf.derive(passphrase.encode())


class EncryptedDoseLog:
    """AES-256-GCM encrypted JSON dose log."""

    def __init__(self, path: Path, passphrase: str):
        self.path = path
        self._key = _derive_key(passphrase)
        self._aesgcm = AESGCM(self._key)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _encrypt(self, data: bytes) -> bytes:
        """Encrypt data with a random 96-bit nonce."""
        nonce = os.urandom(12)  # 96-bit nonce
        ct = self._aesgcm.encrypt(nonce, data, None)
        return base64.b64encode(nonce + ct)

    def _decrypt(self, token: bytes) -> bytes:
        """Decrypt a base64-encoded nonce+ciphertext."""
        raw = base64.b64decode(token)
        nonce, ct = raw[:12], raw[12:]
        return self._aesgcm.decrypt(nonce, ct, None)

    def read_logs(self) -> list[dict]:
        """Read and decrypt all dose logs."""
        if not self.path.exists():
            return []
        try:
            encrypted = self.path.read_bytes()
            decrypted = self._decrypt(encrypted)
            return json.loads(decrypted)
        except Exception as e:
            logger.error(f"Failed to decrypt dose log: {e}")
            return []

    def append_log(self, entry: dict) -> bool:
        """Append a dose log entry and re-encrypt."""
        try:
            logs = self.read_logs()
            logs.append(entry)
            data = json.dumps(logs, indent=2).encode()
            encrypted = self._encrypt(data)
            self.path.write_bytes(encrypted)
            logger.info(f"Dose log entry added: {entry.get('drug_name', 'unknown')}")
            return True
        except Exception as e:
            logger.error(f"Failed to write dose log: {e}")
            return False

    def clear(self):
        """Clear all dose logs."""
        if self.path.exists():
            self.path.unlink()
