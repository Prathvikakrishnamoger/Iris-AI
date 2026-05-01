"""
IrisAI — Drug Interaction Checker
=================================
Pipeline:
  1. LOCAL CACHE (< 1ms)  → interactions_db.json for known lookups
  2. NIH RxNorm API       → Normalize drug names to RxCUI identifiers
  3. openFDA Label API    → Enrich with FDA interaction/warning data
  4. Severity classifier  → SAFE / CAUTION / DANGER
"""

import json
import logging
import time
from enum import Enum
from pathlib import Path
from typing import Optional

import httpx

logger = logging.getLogger("iris.interactions")


class Severity(str, Enum):
    SAFE = "SAFE"
    CAUTION = "CAUTION"
    DANGER = "DANGER"


class InteractionChecker:
    """Drug interaction checker with local cache + live API fallback."""

    def __init__(self, interactions_db_path: Path, med_history_path: Path):
        self._db: dict = {}
        self._history: dict = {}
        self._rxcui_cache: dict = {}

        if interactions_db_path.exists():
            self._db = json.loads(interactions_db_path.read_text())
            logger.info(f"Loaded {len(self._db)} drugs from interactions DB")

        if med_history_path.exists():
            self._history = json.loads(med_history_path.read_text())
            logger.info(f"Loaded patient history: {self._history.get('patient_id')}")

    @property
    def current_medications(self) -> list[str]:
        meds = self._history.get("current_medications", [])
        return [m["name"].lower() for m in meds]

    # Brand name → Generic name mapping (Indian medicines)
    _BRAND_TO_GENERIC = {
        "dolo": "paracetamol", "dolo-650": "paracetamol", "dolo 650": "paracetamol",
        "crocin": "paracetamol", "calpol": "paracetamol",
        "meftal": "mefenamic acid", "meftal-500": "mefenamic acid",
        "dolostat": "paracetamol", "dolostat-pc": "paracetamol",
        "combiflam": "ibuprofen", "brufen": "ibuprofen",
        "saridon": "paracetamol", "disprin": "aspirin",
        "flexon": "ibuprofen",
        "zerodol": "aceclofenac",
        "nimulid": "nimesulide",
        "voveran": "diclofenac", "voveran sr": "diclofenac",
    }

    async def check_drug(self, drug_name: str) -> dict:
        """Check a scanned drug against patient history for interactions.

        Resolves brand names (Dolo-650→Paracetamol, Meftal-500→Mefenamic Acid)
        and fuzzy-matches misspellings before checking interactions.
        """
        t0 = time.perf_counter()
        drug_lower = drug_name.lower().strip()

        # 0. Brand-to-generic resolution (Indian medicines)
        generic_name = self._BRAND_TO_GENERIC.get(drug_lower, None)
        if generic_name:
            logger.info(f"Brand resolved: '{drug_name}' → '{generic_name}'")
            drug_lower = generic_name

        # Fuzzy-match the drug name against the local DB keys
        resolved_name = self._fuzzy_resolve(drug_lower)
        if resolved_name != drug_lower:
            logger.info(f"Fuzzy resolved: '{drug_name}' → '{resolved_name}'")

        interactions = []
        max_severity = Severity.SAFE

        # 1. Check local cache first (< 1ms)
        for med in self.current_medications:
            interaction = self._check_local(resolved_name, med)
            if interaction:
                interactions.append(interaction)
                if Severity[interaction["severity"]] == Severity.DANGER:
                    max_severity = Severity.DANGER
                elif Severity[interaction["severity"]] == Severity.CAUTION and max_severity != Severity.DANGER:
                    max_severity = Severity.CAUTION

        # 2. Resolve RxCUI via NIH RxNorm
        # Try the resolved name first, fall back to the original
        rxcui = await self._resolve_rxcui(resolved_name.capitalize())
        if not rxcui and resolved_name != drug_lower:
            rxcui = await self._resolve_rxcui(drug_name)

        # 3. Enrich via openFDA
        fda_warnings = []
        if rxcui:
            fda_warnings = await self._fetch_fda_warnings(resolved_name.capitalize())

        elapsed = (time.perf_counter() - t0) * 1000
        logger.info(f"Interaction check for '{drug_name}': {max_severity.value}, {len(interactions)} hits, {elapsed:.0f}ms")

        return {
            "drug_name": drug_name,
            "resolved_name": resolved_name.capitalize() if resolved_name != drug_lower else drug_name,
            "rxcui": rxcui,
            "severity": max_severity.value,
            "interactions": interactions,
            "fda_warnings": fda_warnings[:3],
            "current_medications": self.current_medications,
            "check_time_ms": round(elapsed, 1),
        }

    def _fuzzy_resolve(self, drug_lower: str) -> str:
        """Fuzzy-match a potentially misspelled drug name against the local DB.

        E.g. 'ibuprofn' → 'ibuprofen', 'asprin' → 'aspirin'
        Checks BOTH top-level keys AND sub-keys (interaction targets).
        Returns the best match if score >= 85, otherwise the original name.
        """
        # Build full set of known drug names from DB (keys + sub-keys)
        all_known = set(self._db.keys()) | set(self.current_medications)
        for key in self._db:
            if isinstance(self._db[key], dict):
                all_known |= set(self._db[key].keys())

        # Exact match — no fuzzy needed
        if drug_lower in all_known:
            return drug_lower

        try:
            from thefuzz import fuzz
        except ImportError:
            try:
                from fuzzywuzzy import fuzz
            except ImportError:
                return drug_lower

        best_match = drug_lower
        best_score = 0

        for known in all_known:
            # Use ratio only (not partial) to avoid false matches like asprin→warfarin
            score = fuzz.ratio(drug_lower, known)
            if score > best_score and score >= 85:
                best_score = score
                best_match = known

        return best_match

    def _check_local(self, drug: str, against: str) -> Optional[dict]:
        """Check local interactions_db.json for known interactions."""
        # Check drug → against
        if drug in self._db and against in self._db[drug]:
            entry = self._db[drug][against]
            return {
                "drug_a": drug.capitalize(),
                "drug_b": against.capitalize(),
                "severity": entry["severity"],
                "description": entry["description"],
                "source": "local_cache",
            }
        # Check against → drug (bidirectional)
        if against in self._db and drug in self._db[against]:
            entry = self._db[against][drug]
            return {
                "drug_a": against.capitalize(),
                "drug_b": drug.capitalize(),
                "severity": entry["severity"],
                "description": entry["description"],
                "source": "local_cache",
            }
        return None

    async def _resolve_rxcui(self, drug_name: str) -> Optional[str]:
        """Resolve drug name to RxCUI via NIH RxNorm API."""
        if drug_name.lower() in self._rxcui_cache:
            return self._rxcui_cache[drug_name.lower()]

        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(
                    "https://rxnav.nlm.nih.gov/REST/rxcui.json",
                    params={"name": drug_name, "search": 1},
                )
                if resp.status_code == 200:
                    data = resp.json()
                    ids = data.get("idGroup", {}).get("rxnormId", [])
                    if ids:
                        rxcui = ids[0]
                        self._rxcui_cache[drug_name.lower()] = rxcui
                        logger.info(f"RxNorm: {drug_name} → RxCUI {rxcui}")
                        return rxcui
        except Exception as e:
            logger.warning(f"RxNorm API error: {e}")
        return None

    async def _fetch_fda_warnings(self, drug_name: str) -> list[str]:
        """Fetch FDA warnings from openFDA Drug Label API."""
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(
                    "https://api.fda.gov/drug/label.json",
                    params={"search": f'openfda.generic_name:"{drug_name}"', "limit": 1},
                )
                if resp.status_code == 200:
                    results = resp.json().get("results", [])
                    if results:
                        warnings = results[0].get("warnings", [])
                        if isinstance(warnings, list):
                            return [w[:300] for w in warnings[:3]]
        except Exception as e:
            logger.warning(f"openFDA API error: {e}")
        return []
