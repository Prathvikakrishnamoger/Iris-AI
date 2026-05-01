"""
IrisAI — Integration Tests for the Drug Interaction Pipeline
=============================================================
Tests the full chain: local cache → RxNorm → openFDA → severity
"""

import asyncio
import json
import sys
from pathlib import Path
from unittest.mock import patch, AsyncMock

import pytest

# Add backend to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from services.interaction_checker import InteractionChecker, Severity
from core.security import EncryptedDoseLog


@pytest.fixture
def checker():
    db_path = Path(__file__).parent.parent / "data" / "interactions_db.json"
    hist_path = Path(__file__).parent.parent / "data" / "med_history.json"
    return InteractionChecker(db_path, hist_path)


@pytest.fixture
def dose_log(tmp_path):
    return EncryptedDoseLog(tmp_path / "test_log.enc", "test_passphrase")


class TestLocalCacheLookup:
    @pytest.mark.asyncio
    async def test_known_danger_from_cache(self, checker):
        """Aspirin scanned → should find DANGER with Warfarin from local cache."""
        with patch.object(checker, '_resolve_rxcui', new_callable=AsyncMock, return_value="1191"):
            with patch.object(checker, '_fetch_fda_warnings', new_callable=AsyncMock, return_value=[]):
                report = await checker.check_drug("Aspirin")
                assert report["severity"] == "DANGER"
                danger = [i for i in report["interactions"] if i["severity"] == "DANGER"]
                assert len(danger) >= 1
                assert any("warfarin" in i["drug_a"].lower() or "warfarin" in i["drug_b"].lower() for i in danger)

    @pytest.mark.asyncio
    async def test_known_caution(self, checker):
        """Acetaminophen scanned → should find CAUTION with Warfarin."""
        with patch.object(checker, '_resolve_rxcui', new_callable=AsyncMock, return_value=None):
            with patch.object(checker, '_fetch_fda_warnings', new_callable=AsyncMock, return_value=[]):
                report = await checker.check_drug("Acetaminophen")
                assert report["severity"] == "CAUTION"

    @pytest.mark.asyncio
    async def test_safe_drug(self, checker):
        """Vitamin D → no known interactions, should be SAFE."""
        with patch.object(checker, '_resolve_rxcui', new_callable=AsyncMock, return_value=None):
            with patch.object(checker, '_fetch_fda_warnings', new_callable=AsyncMock, return_value=[]):
                report = await checker.check_drug("Vitamin D")
                assert report["severity"] == "SAFE"

    @pytest.mark.asyncio
    async def test_bidirectional_lookup(self, checker):
        """Warfarin should find interactions defined under 'aspirin' key too."""
        with patch.object(checker, '_resolve_rxcui', new_callable=AsyncMock, return_value=None):
            with patch.object(checker, '_fetch_fda_warnings', new_callable=AsyncMock, return_value=[]):
                # Ibuprofen is defined under warfarin AND lisinopril
                report = await checker.check_drug("Ibuprofen")
                assert report["severity"] == "DANGER"
                assert len(report["interactions"]) >= 2

    @pytest.mark.asyncio
    async def test_multiple_interactions(self, checker):
        """Ciprofloxacin has interactions with both warfarin and metformin."""
        with patch.object(checker, '_resolve_rxcui', new_callable=AsyncMock, return_value=None):
            with patch.object(checker, '_fetch_fda_warnings', new_callable=AsyncMock, return_value=[]):
                report = await checker.check_drug("Ciprofloxacin")
                assert len(report["interactions"]) >= 2


class TestEncryptedDoseLog:
    def test_write_and_read(self, dose_log):
        """Write an entry and read it back."""
        entry = {"drug_name": "Aspirin", "dosage": "100mg", "timestamp": "2026-04-30T12:00:00Z"}
        assert dose_log.append_log(entry)
        logs = dose_log.read_logs()
        assert len(logs) == 1
        assert logs[0]["drug_name"] == "Aspirin"

    def test_multiple_entries(self, dose_log):
        """Multiple entries should accumulate."""
        dose_log.append_log({"drug_name": "Aspirin", "dosage": "100mg"})
        dose_log.append_log({"drug_name": "Ibuprofen", "dosage": "200mg"})
        logs = dose_log.read_logs()
        assert len(logs) == 2

    def test_encrypted_file_not_readable(self, dose_log):
        """The .enc file should not contain plaintext drug names."""
        dose_log.append_log({"drug_name": "Aspirin", "dosage": "100mg"})
        raw = dose_log.path.read_bytes()
        assert b"Aspirin" not in raw
        assert b"drug_name" not in raw

    def test_wrong_passphrase_fails(self, tmp_path):
        """Decryption with wrong passphrase should fail gracefully."""
        log1 = EncryptedDoseLog(tmp_path / "test.enc", "correct_pass")
        log1.append_log({"drug_name": "Test"})
        log2 = EncryptedDoseLog(tmp_path / "test.enc", "wrong_pass")
        result = log2.read_logs()
        assert result == []  # Should return empty, not crash

    def test_clear(self, dose_log):
        """Clear should remove the log file."""
        dose_log.append_log({"drug_name": "Test"})
        dose_log.clear()
        assert not dose_log.path.exists()
        assert dose_log.read_logs() == []


class TestRxNormLive:
    @pytest.mark.asyncio
    async def test_resolve_aspirin(self, checker):
        """Live RxNorm API should resolve Aspirin to a valid RxCUI."""
        rxcui = await checker._resolve_rxcui("Aspirin")
        if rxcui is None:
            pytest.skip("RxNorm API unreachable — network timeout")
        assert rxcui.isdigit()

    @pytest.mark.asyncio
    async def test_rxcui_caching(self, checker):
        """Second lookup should use cache."""
        await checker._resolve_rxcui("Aspirin")
        assert "aspirin" in checker._rxcui_cache

    @pytest.mark.asyncio
    async def test_unknown_drug(self, checker):
        """Nonsense drug name should return None."""
        rxcui = await checker._resolve_rxcui("xyzzy_not_a_drug_12345")
        assert rxcui is None


class TestFullPipeline:
    @pytest.mark.asyncio
    async def test_full_check_aspirin(self, checker):
        """Full pipeline with live APIs for Aspirin."""
        report = await checker.check_drug("Aspirin")
        assert report["drug_name"] == "Aspirin"
        assert report["severity"] == "DANGER"
        assert "interactions" in report
        assert report["check_time_ms"] > 0
