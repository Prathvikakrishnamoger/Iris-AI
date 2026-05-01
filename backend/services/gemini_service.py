"""
IrisAI — Gemini 1.5 Flash Structuring Service (v2 — No Guessing)
=================================================================
Takes raw OCR text → structured drug info JSON.

SAFETY RULES:
  - Empty/garbled text → NO_MEDICINE_DETECTED
  - Confidence < 0.5 → drug_name = null (forces "Unknown Medicine - Please Rescan")
  - Fuzzy matching for misspelled OCR (e.g. "Asp-rin" → "Aspirin")
  - NIH RxNorm verification before returning any drug name
  - NEVER hallucinate or guess
"""

import asyncio
import base64
import json
import logging
import re
import time
from typing import Optional

import httpx

logger = logging.getLogger("iris.gemini")

try:
    import google.generativeai as genai
    _GEMINI_AVAILABLE = True
except ImportError:
    _GEMINI_AVAILABLE = False
    logger.warning("google-generativeai not installed")

try:
    from thefuzz import fuzz
    _FUZZ_AVAILABLE = True
except ImportError:
    try:
        from fuzzywuzzy import fuzz
        _FUZZ_AVAILABLE = True
    except ImportError:
        _FUZZ_AVAILABLE = False
        logger.warning("thefuzz/fuzzywuzzy not installed — fuzzy matching disabled")

# Known drug names for fuzzy matching
_COMMON_DRUGS = [
    # International generics
    "amoxicillin", "ibuprofen", "aspirin", "acetaminophen", "metformin",
    "lisinopril", "warfarin", "omeprazole", "atorvastatin", "metoprolol",
    "amlodipine", "losartan", "gabapentin", "sertraline", "fluoxetine",
    "ciprofloxacin", "azithromycin", "prednisone", "levothyroxine",
    "hydrochlorothiazide", "clopidogrel", "pantoprazole", "ranitidine",
    "diclofenac", "naproxen", "cetirizine", "loratadine", "montelukast",
    "paracetamol", "doxycycline", "clindamycin", "erythromycin",
    "cephalexin", "levofloxacin", "tramadol", "codeine",
    "morphine", "insulin", "glipizide", "sitagliptin", "empagliflozin",
    # Indian brand names → generic mappings
    "mefenamic acid", "mefenamic", "meftal",
    "dolo", "dolo-650", "dolo 650",
    "dolostat", "dolostat-pc",
    "crocin", "calpol",
    "combiflam",
    "saridon", "disprin",
    "brufen", "flexon",
    "aceclofenac", "zerodol",
    "nimesulide", "nimulid",
    "voveran", "voveran sr",
    "panderm", "betnovate",
]

# Brand name → Generic name mapping for Indian medicines
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

_SYSTEM_PROMPT = """You are a medicine label parser for visually impaired users.
Given OCR text from a medicine label, extract ONLY information that is EXPLICITLY present.

CRITICAL RULES:
1. If the text is empty, garbled, or contains NO identifiable drug name → return {"error": "NO_MEDICINE_DETECTED"}
2. NEVER hallucinate or guess a drug name. Only use names explicitly in the text.
3. If unsure about any field, set it to null.
4. Set "confidence" to reflect how certain you are: 1.0 = perfect OCR, 0.0 = unreadable.
5. If confidence is below 0.5, set drug_name to null.

Return JSON with these fields:
{
  "drug_name": "exact name from label or null",
  "dosage": "e.g. 500mg or null",
  "form": "tablet/capsule/syrup/injection or null",
  "manufacturer": "from label or null",
  "expiry_date": "from label or null",
  "usage_instructions": "from label or null",
  "warnings": "from label or null",
  "confidence": 0.0 to 1.0
}"""


def _fuzzy_match_drug(text: str) -> Optional[tuple[str, int]]:
    """Fuzzy match OCR text against known drug names.

    Handles misspellings like 'Asp-rin' → 'Aspirin', 'Ibuprofn' → 'Ibuprofen'.
    Returns (matched_drug, score) or None.
    
    SAFETY: Threshold set to 85 to prevent false positives like TOTAL→Meftal.
    A wrong medicine match is far worse than no match for a medical app.
    """
    if not _FUZZ_AVAILABLE:
        # Fallback: exact substring match
        text_lower = text.lower()
        for drug in _COMMON_DRUGS:
            if drug in text_lower:
                return (drug.capitalize(), 95)
        return None

    MATCH_THRESHOLD = 85  # High to prevent false positives
    best_match = None
    best_score = 0

    # Extract individual words from OCR text for matching
    words = re.findall(r'[a-zA-Z]{3,}', text)
    logger.info(f"Fuzzy matching words: {words}")

    for word in words:
        word_lower = word.lower()
        for drug in _COMMON_DRUGS:
            # Guard: word must be at least 60% the length of the drug name
            # Prevents short words matching long drug names spuriously
            if len(word_lower) < len(drug) * 0.6:
                continue

            score = fuzz.ratio(word_lower, drug)
            # partial_ratio is more lenient — require higher score
            partial = fuzz.partial_ratio(word_lower, drug)
            # Use partial only if it's very high (>= 90)
            best_for_pair = score
            if partial >= 90 and partial > score:
                best_for_pair = partial

            if best_for_pair > best_score and best_for_pair >= MATCH_THRESHOLD:
                best_score = best_for_pair
                best_match = drug.capitalize()
                logger.info(f"Fuzzy candidate: '{word}' → '{drug}' (score={best_for_pair})")

    # Also try matching multi-word sequences (e.g., "hydro chloro thiazide")
    text_clean = re.sub(r'[^a-zA-Z]', '', text.lower())
    for drug in _COMMON_DRUGS:
        drug_clean = drug.replace(" ", "")
        # Guard: cleaned text must be similar length
        if abs(len(text_clean) - len(drug_clean)) > max(3, len(drug_clean) * 0.4):
            continue
        score = fuzz.ratio(text_clean, drug_clean)
        if score > best_score and score >= MATCH_THRESHOLD:
            best_score = score
            best_match = drug.capitalize()
            logger.info(f"Fuzzy multi-word: '{text_clean}' → '{drug}' (score={score})")

    if best_match:
        logger.info(f"Fuzzy best match: '{best_match}' (score={best_score})")
        return (best_match, best_score)
    logger.info(f"Fuzzy: no match above threshold {MATCH_THRESHOLD} for '{text[:50]}'")
    return None


async def _verify_with_nih(drug_name: str) -> Optional[str]:
    """Verify drug name against NIH RxNorm API.

    If TrOCR extracts 'Asp-rin', fuzzy match finds 'Aspirin',
    then we verify 'Aspirin' is a real drug via NIH.
    Returns the normalized drug name or None.
    """
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
                    logger.info(f"NIH verified: {drug_name} → RxCUI {ids[0]}")
                    return drug_name
    except Exception as e:
        logger.warning(f"NIH verification failed: {e}")

    # If NIH is unreachable, still return the drug if fuzzy match was high
    return None


class GeminiService:
    """Structures raw OCR text into drug info using Gemini.
    
    Uses a primary model (e.g. gemini-2.0-flash) with automatic fallback
    to an alternate model (gemini-2.0-flash-lite) when daily quota is exhausted.
    Free-tier quotas are per-model, so this effectively doubles our capacity.
    """

    # Fallback models to try when primary is rate-limited (each has separate daily quota)
    _FALLBACK_MODELS = ["gemini-2.5-flash-lite", "gemini-2.0-flash-lite", "gemini-2.5-flash"]

    def __init__(self, api_key: str = "", model_name: str = "gemini-1.5-flash", api_key_2: str = ""):
        self.model = None
        self.fallback_models = []  # List of all fallback models (each has separate quota)
        self._primary_daily_exhausted = False
        self._api_key = api_key
        self._api_key_2 = api_key_2
        self._model_name = model_name
        self._key2_exhausted = False  # Track if key2 is also done
        self._current_key = api_key  # Track which key is currently active
        
        if _GEMINI_AVAILABLE and api_key:
            try:
                genai.configure(api_key=api_key)
                gen_config = genai.types.GenerationConfig(
                    response_mime_type="application/json",
                    temperature=0.1,
                )
                self.model = genai.GenerativeModel(
                    model_name,
                    system_instruction=_SYSTEM_PROMPT,
                    generation_config=gen_config,
                )
                logger.info(f"Gemini primary configured: {model_name}")
                
                # Set up ALL fallback models on primary key (each has its own separate daily quota)
                for fb_name in self._FALLBACK_MODELS:
                    if fb_name != model_name:
                        try:
                            fb_model = genai.GenerativeModel(
                                fb_name,
                                system_instruction=_SYSTEM_PROMPT,
                                generation_config=gen_config,
                            )
                            self.fallback_models.append(fb_model)
                            logger.info(f"Gemini fallback configured: {fb_name}")
                        except Exception:
                            continue
                            
            except Exception as e:
                logger.error(f"Gemini init failed: {e}")

    def _switch_to_key2(self):
        """Switch ALL models to use the second API key when key1 is fully exhausted."""
        if not self._api_key_2 or self._key2_exhausted:
            return False
        if self._current_key == self._api_key_2:
            return False  # Already on key2
        
        logger.info("══ Switching to Gemini API Key 2 ══")
        try:
            genai.configure(api_key=self._api_key_2)
            self._current_key = self._api_key_2
            self._primary_daily_exhausted = False  # Reset — key2 has fresh quotas
            
            # Rebuild all models under key2
            gen_config = genai.types.GenerationConfig(
                response_mime_type="application/json",
                temperature=0.1,
            )
            self.model = genai.GenerativeModel(
                self._model_name,
                system_instruction=_SYSTEM_PROMPT,
                generation_config=gen_config,
            )
            self.fallback_models = []
            for fb_name in self._FALLBACK_MODELS:
                if fb_name != self._model_name:
                    try:
                        fb_model = genai.GenerativeModel(
                            fb_name,
                            system_instruction=_SYSTEM_PROMPT,
                            generation_config=gen_config,
                        )
                        self.fallback_models.append(fb_model)
                        logger.info(f"Key2 fallback: {fb_name}")
                    except Exception:
                        continue
            return True
        except Exception as e:
            logger.error(f"Key2 switch failed: {e}")
            # Restore key1
            genai.configure(api_key=self._api_key)
            self._current_key = self._api_key
            return False

    def _validate_text(self, text: str) -> bool:
        """Check if text is likely to contain medicine information."""
        if not text or len(text.strip()) < 3:
            return False
        alpha_chars = sum(1 for c in text if c.isalpha())
        if len(text) > 0 and alpha_chars / len(text) < 0.3:
            return False
        return True

    def _get_active_model(self):
        """Return the best available model, skipping daily-exhausted primary."""
        if self._primary_daily_exhausted and self.fallback_models:
            return self.fallback_models[0]
        return self.model

    async def structure_text(self, ocr_text: str) -> dict:
        """Parse OCR text into structured drug info.

        Pipeline:
          1. Pre-validate text quality
          2. Gemini structuring (if available)
          3. Fuzzy match OCR text against drug database
          4. Verify against NIH RxNorm
          5. Enforce confidence >= 0.5 threshold
        """
        t0 = time.perf_counter()

        if not self._validate_text(ocr_text):
            logger.info("Text failed pre-validation — no medicine detected")
            return {"error": "NO_MEDICINE_DETECTED", "raw_text": ocr_text}

        result = None

        # Step 1: Try Gemini (primary → fallback on daily limit)
        active_model = self._get_active_model()
        if active_model is not None:
            max_retries = 1
            for attempt in range(max_retries + 1):
                try:
                    prompt = f"Extract medicine info from this label text:\n\n{ocr_text}"
                    response = active_model.generate_content(prompt)
                    result = json.loads(response.text)

                    if result.get("error") == "NO_MEDICINE_DETECTED":
                        return result

                    # Anti-hallucination: check if drug_name appears in OCR text
                    drug_name = result.get("drug_name")
                    if drug_name and drug_name.lower() not in ocr_text.lower():
                        # Check fuzzy match before rejecting
                        fuzzy = _fuzzy_match_drug(ocr_text)
                        if fuzzy and fuzzy[0].lower() == drug_name.lower():
                            logger.info(f"Gemini name confirmed by fuzzy match: {drug_name} (score {fuzzy[1]})")
                        else:
                            logger.warning(f"Gemini hallucinated '{drug_name}' — not in OCR text, no fuzzy match")
                            result["drug_name"] = None
                            result["confidence"] = 0.1
                    break  # Success — exit retry loop

                except Exception as e:
                    err_str = str(e)
                    err_lower = err_str.lower()
                    is_rate_limit = '429' in err_lower or 'quota' in err_lower or 'rate' in err_lower
                    is_daily_limit = 'PerDay' in err_str or 'per_day' in err_lower
                    
                    if is_daily_limit:
                        self._primary_daily_exhausted = True
                        logger.warning("Gemini primary DAILY quota exhausted — trying fallback models")
                        # Try all fallback models
                        for fb_model in self.fallback_models:
                            if fb_model == active_model:
                                continue
                            try:
                                prompt = f"Extract medicine info from this label text:\n\n{ocr_text}"
                                response = fb_model.generate_content(prompt)
                                result = json.loads(response.text)
                                if result.get("error") != "NO_MEDICINE_DETECTED":
                                    drug_name = result.get("drug_name")
                                    if drug_name:
                                        logger.info(f"Fallback model identified: {drug_name}")
                                break
                            except Exception as fb_e:
                                logger.warning(f"Fallback model failed: {fb_e}")
                                continue
                        
                        # All fallbacks on current key failed — try key2
                        if result is None or result.get("drug_name") is None:
                            if self._switch_to_key2():
                                logger.info("Key2 activated — retrying structure_text")
                                return await self.structure_text(ocr_text)
                        break
                    elif is_rate_limit and attempt < max_retries:
                        wait = 3
                        logger.warning(f"Gemini per-minute rate-limited, retrying in {wait}s...")
                        await asyncio.sleep(wait)
                    else:
                        logger.error(f"Gemini failed: {e}")
                        result = None
                        break

        # Step 2: Fallback to fuzzy matching if Gemini failed or unavailable
        if result is None or result.get("drug_name") is None:
            result = result or {}
            fuzzy = _fuzzy_match_drug(ocr_text)
            if fuzzy:
                drug_name, score = fuzzy
                confidence = score / 100.0
                result["drug_name"] = drug_name
                result["confidence"] = confidence
                logger.info(f"Fuzzy matched: {drug_name} (score {score})")
            else:
                result = self._fallback_parse(ocr_text)

        # Step 3: Verify with NIH RxNorm (if we have a drug name)
        drug_name = result.get("drug_name")
        if drug_name and drug_name != "null":
            verified = await _verify_with_nih(drug_name)
            if verified:
                result["nih_verified"] = True
                logger.info(f"NIH verified: {drug_name}")
            else:
                result["nih_verified"] = False
                # Lower confidence if NIH can't verify
                current_conf = result.get("confidence", 0.5)
                if isinstance(current_conf, (int, float)):
                    result["confidence"] = min(current_conf, 0.6)

        # Step 4: ENFORCE CONFIDENCE THRESHOLD
        confidence = result.get("confidence", 0.0)
        if isinstance(confidence, (int, float)) and confidence < 0.5:
            logger.warning(f"Low confidence ({confidence}) for '{result.get('drug_name')}' — rejecting")
            result["drug_name"] = None
            result["error"] = "LOW_CONFIDENCE"

        elapsed = (time.perf_counter() - t0) * 1000
        logger.info(f"Gemini pipeline: {elapsed:.0f}ms → {result.get('drug_name')} (conf={result.get('confidence')})")
        return result

    def _fallback_parse(self, text: str) -> dict:
        """Regex fallback parser — no guessing."""
        result = {
            "drug_name": None, "dosage": None, "form": None,
            "manufacturer": None, "expiry_date": None,
            "usage_instructions": None, "warnings": None,
            "confidence": 0.0,
        }

        # Try fuzzy matching first
        fuzzy = _fuzzy_match_drug(text)
        if fuzzy:
            result["drug_name"] = fuzzy[0]
            result["confidence"] = fuzzy[1] / 100.0

        dosage_match = re.search(r'(\d+(?:\.\d+)?)\s*(mg|ml|mcg|g|iu)', text, re.IGNORECASE)
        if dosage_match:
            result["dosage"] = dosage_match.group(0)

        for form in ["tablet", "capsule", "syrup", "injection", "cream", "ointment"]:
            if form in text.lower():
                result["form"] = form.capitalize()
                break

        expiry = re.search(r'(?:exp|expiry|expires?)[\s:]*(\d{1,2}[/-]\d{2,4}|\d{4}[/-]\d{2})', text, re.IGNORECASE)
        if expiry:
            result["expiry_date"] = expiry.group(1)

        if not result["drug_name"]:
            return {"error": "NO_MEDICINE_DETECTED", "raw_text": text[:200], "confidence": 0.0}

        return result

    async def structure_image(self, image_bytes: bytes) -> dict:
        """Send the raw image to Gemini Vision to read the medicine label directly.
        
        This bypasses OCR entirely — Gemini can natively read text from images.
        Used as fallback when TrOCR OCR produces empty/garbled results.
        """
        active_model = self._get_active_model()
        if active_model is None:
            return {"error": "GEMINI_UNAVAILABLE"}

        t0 = time.perf_counter()
        b64_image = base64.b64encode(image_bytes).decode("utf-8")
        
        vision_prompt = """Look at this medicine label/packaging image carefully.
Read ALL visible text on the label and extract the medicine information.

CRITICAL RULES:
1. Read the drug/brand name EXACTLY as printed on the label.
2. Extract dosage, composition, manufacturer, expiry if visible.
3. If you can see a medicine name clearly, set confidence to 0.8 or higher.
4. If the image is too blurry to read, return {"error": "NO_MEDICINE_DETECTED"}.
5. NEVER make up or guess a drug name — only report what you can actually read.

Return JSON:
{
  "drug_name": "exact name from label or null",
  "dosage": "e.g. 500mg or null",
  "form": "tablet/capsule/syrup or null",
  "manufacturer": "from label or null",
  "expiry_date": "from label or null",
  "usage_instructions": "from label or null",
  "warnings": "from label or null",
  "active_ingredients": "composition if visible or null",
  "confidence": 0.0 to 1.0
}"""

        vision_content = [
            vision_prompt,
            {"mime_type": "image/jpeg", "data": b64_image},
        ]

        # Try active model, then all fallbacks on daily limit
        models_to_try = [active_model]
        for fb in self.fallback_models:
            if fb != active_model:
                models_to_try.append(fb)

        for model in models_to_try:
            try:
                response = model.generate_content(vision_content)
                result = json.loads(response.text)
                elapsed = (time.perf_counter() - t0) * 1000
                logger.info(f"Gemini Vision: {elapsed:.0f}ms → {result.get('drug_name')} (conf={result.get('confidence')})")

                # Apply brand-to-generic mapping
                drug_name = result.get("drug_name")
                if drug_name:
                    drug_lower = drug_name.lower().strip()
                    generic = _BRAND_TO_GENERIC.get(drug_lower)
                    if generic:
                        result["generic_name"] = generic.capitalize()
                        logger.info(f"Brand→Generic: {drug_name} → {generic}")

                return result

            except Exception as e:
                err_str = str(e)
                is_daily_limit = 'PerDay' in err_str or 'per_day' in err_str.lower()
                if is_daily_limit:
                    self._primary_daily_exhausted = True
                    logger.warning(f"Gemini Vision daily quota hit — trying next model")
                    continue  # Try next model in list
                else:
                    logger.error(f"Gemini Vision failed: {e}")
                    return {"error": "GEMINI_VISION_FAILED", "message": str(e)}

        # All models on current key exhausted — try switching to key2
        if self._switch_to_key2():
            logger.info("Key2 activated — retrying Gemini Vision")
            return await self.structure_image(image_bytes)

        return {"error": "GEMINI_VISION_FAILED", "message": "All models quota exhausted"}
