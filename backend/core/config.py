"""IrisAI backend core configuration."""

import os
from pathlib import Path
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Environment configuration. Load from .env file or env vars."""

    # API Keys
    GEMINI_API_KEY: str = ""
    GEMINI_API_KEY_2: str = ""
    GEMINI_MODEL: str = "gemini-1.5-flash"

    # Twilio
    TWILIO_ACCOUNT_SID: str = ""
    TWILIO_AUTH_TOKEN: str = ""
    TWILIO_FROM_NUMBER: str = ""
    EMERGENCY_CONTACT: str = ""
    USER_NAME: str = "Patient"

    # Paths
    DATA_DIR: Path = Path(__file__).parent.parent / "data"
    INTERACTIONS_DB: Path = Path(__file__).parent.parent / "data" / "interactions_db.json"
    MED_HISTORY: Path = Path(__file__).parent.parent / "data" / "med_history.json"
    DOSE_LOG_PATH: Path = Path(__file__).parent.parent / "data" / "dose_log.enc"

    # Security
    ENCRYPTION_PASSPHRASE: str = "iris_ai_demo_key_change_in_production"

    # YOLO
    YOLO_MODEL_PATH: str = "yolo11n.pt"
    YOLO_CONFIDENCE: float = 0.5

    # Server
    HOST: str = "0.0.0.0"
    PORT: int = 8080

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


settings = Settings()
