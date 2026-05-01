"""
IrisAI — Twilio SMS Alert Service
==================================
Sends emergency SMS alerts when dangerous drug interactions are detected.
Rate-limited to max 3 alerts per hour to prevent spam.
Reads emergency contact from med_history.json at runtime (live updates).
"""

import json
import logging
import os
import time
from typing import Optional

logger = logging.getLogger("iris.alerts")

try:
    from twilio.rest import Client as TwilioClient
    _TWILIO_AVAILABLE = True
except ImportError:
    _TWILIO_AVAILABLE = False
    logger.warning("twilio not installed — SMS alerts will be mocked")

# Path to med_history.json (relative to backend/)
_MED_HISTORY_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "med_history.json")


class AlertService:
    """Twilio SMS alert service with rate limiting."""

    MAX_ALERTS_PER_HOUR = 3

    def __init__(self, account_sid: str = "", auth_token: str = "",
                 from_number: str = "", emergency_contact: str = "",
                 user_name: str = "Patient"):
        self._client = None
        self._from = from_number
        self._default_to = emergency_contact
        self._default_user_name = user_name
        self._alert_times: list[float] = []

        if _TWILIO_AVAILABLE and account_sid and auth_token:
            try:
                self._client = TwilioClient(account_sid, auth_token)
                logger.info("Twilio client initialized")
            except Exception as e:
                logger.error(f"Twilio init failed: {e}")

    def _load_contact_from_history(self) -> tuple[str, str]:
        """Read emergency contact from med_history.json (live, no restart needed).
        
        Returns (phone, name). Falls back to .env defaults if file is missing.
        """
        try:
            with open(_MED_HISTORY_PATH, "r") as f:
                data = json.load(f)
            contact = data.get("emergency_contact", {})
            phone = contact.get("phone", "")
            name = contact.get("name", "")
            
            # Ensure country code is present
            if phone and not phone.startswith("+"):
                phone = "+91" + phone.lstrip("0")
            
            patient_name = data.get("patient_name", self._default_user_name)
            
            if phone:
                return phone, patient_name or self._default_user_name
        except Exception as e:
            logger.debug(f"Could not read med_history.json: {e}")
        
        return self._default_to, self._default_user_name

    def _is_rate_limited(self) -> bool:
        now = time.time()
        self._alert_times = [t for t in self._alert_times if now - t < 3600]
        return len(self._alert_times) >= self.MAX_ALERTS_PER_HOUR

    def send_danger_alert(self, drug_name: str, interactions: list[dict]) -> dict:
        """Send emergency SMS for dangerous drug interactions."""
        if self._is_rate_limited():
            logger.warning("Rate limited — skipping SMS alert")
            return {"sent": False, "reason": "rate_limited"}

        # Read latest contact from med_history.json
        to_number, user_name = self._load_contact_from_history()

        interaction_text = "; ".join(
            f"{i['drug_a']} + {i['drug_b']}: {i.get('description', 'interaction detected')[:80]}"
            for i in interactions[:3]
        )
        message = (
            f"Alert from IrisAI: {user_name} just scanned {drug_name} "
            f"which has a HIGH-RISK interaction (DANGER). "
            f"Conflicts: {interaction_text}. "
            f"Please check on them."
        )

        if self._client and self._from and to_number:
            try:
                msg = self._client.messages.create(
                    body=message, from_=self._from, to=to_number
                )
                self._alert_times.append(time.time())
                logger.info(f"SMS sent to {to_number}: {msg.sid}")
                return {"sent": True, "sid": msg.sid}
            except Exception as e:
                logger.error(f"SMS send failed: {e}")
                return {"sent": False, "reason": str(e)}
        else:
            logger.info(f"[MOCK SMS] {message[:100]}...")
            self._alert_times.append(time.time())
            return {"sent": False, "reason": "mock_mode", "message": message}
