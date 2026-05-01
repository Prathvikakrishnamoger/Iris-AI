"""
IrisAI — FastAPI Backend
========================
Endpoints:
  POST /api/scan      → Full AI pipeline (stitch → YOLO → TrOCR → Gemini → interactions)
  POST /api/check     → Drug interaction check only
  POST /api/log       → Receive and store encrypted dose log entries
  GET  /api/history   → Retrieve decrypted dose history
  POST /api/emergency → Manual emergency SMS trigger
  GET  /health        → Health check

SAFETY:
  - Blank/featureless frames → 400 with hold_steady guidance
  - Empty OCR → NO_MEDICINE_DETECTED (no hallucination)
  - DANGER interactions → auto-SMS to emergency contact
"""

import io
import logging
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import cv2
import numpy as np
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from core.config import settings
from services.interaction_checker import InteractionChecker, Severity
from core.security import EncryptedDoseLog

# Graceful optional imports for heavy ML models
try:
    from services.classifier import MedicineClassifier
except ImportError:
    MedicineClassifier = None

try:
    from services.stitcher import stitcher as cylindrical_stitcher
except ImportError:
    cylindrical_stitcher = None

try:
    from services.ocr_engine import OCREngine
except ImportError:
    OCREngine = None

try:
    from services.gemini_service import GeminiService
except ImportError:
    GeminiService = None

try:
    from services.alert_service import AlertService
except ImportError:
    AlertService = None

# Logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(message)s")
logger = logging.getLogger("iris.main")

# ── Global service instances ─────────────────────────────────────────
interaction_checker: Optional[InteractionChecker] = None
dose_log: Optional[EncryptedDoseLog] = None
classifier = None
ocr_engine = None
gemini_service = None
alert_service = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize all services on startup."""
    global interaction_checker, dose_log, classifier, ocr_engine, gemini_service, alert_service

    logger.info("═══ IrisAI Backend Starting ═══")

    # Core services (always available)
    interaction_checker = InteractionChecker(settings.INTERACTIONS_DB, settings.MED_HISTORY)
    dose_log = EncryptedDoseLog(settings.DOSE_LOG_PATH, settings.ENCRYPTION_PASSPHRASE)
    logger.info("✓ Interaction checker + Encrypted dose log ready")

    # ML services (optional — graceful degradation)
    if MedicineClassifier:
        try:
            classifier = MedicineClassifier(settings.YOLO_MODEL_PATH, settings.YOLO_CONFIDENCE)
            logger.info("✓ YOLOv11 classifier loaded")
        except Exception as e:
            logger.warning(f"✗ YOLO skipped: {e}")

    if OCREngine:
        try:
            ocr_engine = OCREngine()
            logger.info("✓ TrOCR engine loaded")
        except Exception as e:
            logger.warning(f"✗ TrOCR skipped: {e}")

    if GeminiService:
        try:
            gemini_service = GeminiService(settings.GEMINI_API_KEY, settings.GEMINI_MODEL, settings.GEMINI_API_KEY_2)
            logger.info("✓ Gemini 1.5 Flash configured")
        except Exception as e:
            logger.warning(f"✗ Gemini skipped: {e}")

    if AlertService:
        try:
            alert_service = AlertService(
                settings.TWILIO_ACCOUNT_SID, settings.TWILIO_AUTH_TOKEN,
                settings.TWILIO_FROM_NUMBER, settings.EMERGENCY_CONTACT,
                settings.USER_NAME,
            )
            logger.info("✓ Twilio alert service ready")
        except Exception as e:
            logger.warning(f"✗ Twilio skipped: {e}")

    logger.info("═══ IrisAI Backend Ready ═══")
    yield
    logger.info("═══ IrisAI Backend Shutting Down ═══")


app = FastAPI(title="IrisAI", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Request / Response models ────────────────────────────────────────
class DrugCheckRequest(BaseModel):
    drug_name: str

class DoseLogEntry(BaseModel):
    drug_name: str
    dosage: str = ""
    form: str = ""
    timestamp: str = ""
    interactions_found: list = []

class EmergencyRequest(BaseModel):
    drug_name: str
    interactions: list[dict] = []


# ── Frame validation ─────────────────────────────────────────────────
def _is_blank_frame(image: np.ndarray, blur_thresh: float = 30.0, edge_thresh: float = 5.0) -> bool:
    """Detect blank/featureless frames using Laplacian variance + Canny edge density."""
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image
    laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()
    edges = cv2.Canny(gray, 50, 150)
    edge_density = np.count_nonzero(edges) / edges.size * 100
    logger.info(f"Frame check: laplacian={laplacian_var:.1f} (thresh={blur_thresh}), edges={edge_density:.1f}% (thresh={edge_thresh}%), size={image.shape}")
    if laplacian_var < blur_thresh and edge_density < edge_thresh:
        return True
    return False


# ── Endpoints ────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "services": {
            "interaction_checker": interaction_checker is not None,
            "dose_log": dose_log is not None,
            "classifier": classifier is not None,
            "ocr_engine": ocr_engine is not None,
            "gemini": gemini_service is not None,
            "alerts": alert_service is not None,
        },
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.post("/api/scan")
async def scan_medicine(files: list[UploadFile] = File(...)):
    """Full AI pipeline: validate → stitch → YOLO → TrOCR → Gemini → interactions."""
    t0 = time.perf_counter()

    # 1. Decode uploaded frames
    frames = []
    for f in files:
        data = await f.read()
        arr = np.frombuffer(data, dtype=np.uint8)
        img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if img is not None:
            frames.append(img)

    if not frames:
        raise HTTPException(status_code=400, detail={
            "error": "NO_VALID_FRAMES",
            "guidance": "hold_steady",
            "message": "No valid image frames received. Please hold the camera steady.",
        })

    # 2. Validate frames — reject blank/featureless
    valid_frames = [f for f in frames if not _is_blank_frame(f)]
    if not valid_frames:
        raise HTTPException(status_code=400, detail={
            "error": "BLANK_FRAMES",
            "guidance": "hold_steady",
            "message": "Frames are too blurry or blank. Hold steady over the medicine label.",
        })

    # 3. Stitch frames
    if cylindrical_stitcher and len(valid_frames) > 1:
        panorama = cylindrical_stitcher.stitch(valid_frames)
        if panorama is None:
            panorama = valid_frames[0]
    else:
        panorama = valid_frames[0]

    # 4. YOLO classification — returns bounding box + guidance direction
    detections = []
    guidance_direction = "hold_steady"
    if classifier:
        detections = classifier.classify(panorama)
        # Extract guidance from the primary detection
        if detections and detections[0].get("guidance"):
            guidance_direction = detections[0]["guidance"]

    # 5. OCR extraction
    ocr_text = ""
    if ocr_engine:
        ocr_text = ocr_engine.extract_text(panorama)
    logger.info(f"OCR extracted: '{ocr_text[:200]}'" if ocr_text else "OCR: empty")

    # 5b. Check for blurry/unreadable OCR — don't guess
    if ocr_text and len(ocr_text.strip()) < 3:
        elapsed = (time.perf_counter() - t0) * 1000
        return {
            "status": "blurry",
            "error": "BLURRY_SCAN",
            "guidance": guidance_direction,
            "message": "Blurry scan detected. Please adjust lighting and hold steady.",
            "pipeline_ms": round(elapsed, 1),
        }

    # 6. Gemini structuring — cascading fallbacks, NO HARDCODED RESULTS
    drug_info = {"error": "NO_MEDICINE_DETECTED"}

    if gemini_service and ocr_text:
        # Step A: Try Gemini text structuring (includes fuzzy fallback internally)
        drug_info = await gemini_service.structure_text(ocr_text)
        logger.info(f"Gemini text result: {drug_info.get('drug_name')} (err={drug_info.get('error')})")

        # Step B: If Gemini text failed, try Gemini Vision on the raw image
        if drug_info.get("error") and gemini_service:
            logger.info("Gemini text failed — trying Gemini Vision on raw image")
            _, img_encoded = cv2.imencode('.jpg', panorama)
            vision_result = await gemini_service.structure_image(img_encoded.tobytes())
            logger.info(f"Gemini Vision result: {vision_result.get('drug_name')} (err={vision_result.get('error')})")
            if not vision_result.get("error"):
                drug_info = vision_result

    elif gemini_service and not ocr_text:
        # OCR returned nothing — go straight to Gemini Vision
        logger.info("OCR returned empty — using Gemini Vision directly")
        _, img_encoded = cv2.imencode('.jpg', panorama)
        drug_info = await gemini_service.structure_image(img_encoded.tobytes())
        logger.info(f"Gemini Vision result: {drug_info.get('drug_name')} (err={drug_info.get('error')})")

    elif ocr_text:
        drug_info = {"drug_name": None, "raw_text": ocr_text, "note": "Gemini unavailable"}

    # 6b. Check confidence — if < 0.5, return "Unknown Medicine"
    confidence = drug_info.get("confidence", 0.0)
    if isinstance(confidence, (int, float)) and confidence < 0.5 and drug_info.get("drug_name"):
        drug_info["drug_name"] = None
        drug_info["error"] = "LOW_CONFIDENCE"

    if drug_info.get("error"):
        elapsed = (time.perf_counter() - t0) * 1000
        error_code = drug_info["error"]
        if error_code == "LOW_CONFIDENCE":
            msg = "Low confidence scan. Please adjust lighting and try again."
        elif "GEMINI" in error_code or "429" in str(drug_info.get("message", "")):
            msg = "AI service temporarily unavailable. Please wait a moment and try again."
        else:
            msg = "No medicine detected. Try repositioning the label."
        return {
            "status": "no_medicine",
            "error": error_code,
            "guidance": guidance_direction,
            "message": msg,
            "ocr_text": ocr_text[:200] if ocr_text else "",
            "pipeline_ms": round(elapsed, 1),
        }

    # 7. Interaction check — uses the ACTUAL identified drug, not defaults
    drug_name = drug_info.get("drug_name", "")
    interaction_report = {}
    sms_alert = None
    if drug_name and interaction_checker:
        interaction_report = await interaction_checker.check_drug(drug_name)

        # 8. Safety Shield — auto-SMS on DANGER
        if interaction_report.get("severity") == "DANGER" and alert_service:
            sms_alert = alert_service.send_danger_alert(
                drug_name, interaction_report.get("interactions", [])
            )
            logger.info(f"Safety Shield SMS: {sms_alert}")

    elapsed = (time.perf_counter() - t0) * 1000
    response = {
        "status": "success",
        "drug_info": drug_info,
        "detections": detections,
        "guidance": guidance_direction,
        "interactions": interaction_report,
        "pipeline_ms": round(elapsed, 1),
    }

    # Include SMS alert status so frontend can show "Emergency Contact Notified"
    if sms_alert is not None:
        response["sms_alert"] = sms_alert

    return response


@app.post("/api/check")
async def check_interaction(req: DrugCheckRequest):
    """Check a drug against patient history for interactions."""
    if not interaction_checker:
        raise HTTPException(status_code=503, detail="Interaction checker not initialized")

    report = await interaction_checker.check_drug(req.drug_name)

    # Auto-SMS on DANGER
    if report.get("severity") == "DANGER" and alert_service:
        alert_result = alert_service.send_danger_alert(req.drug_name, report.get("interactions", []))
        report["sms_alert"] = alert_result

    return report


@app.post("/api/log")
async def log_dose(entry: DoseLogEntry):
    """Log a dose entry to encrypted storage."""
    if not dose_log:
        raise HTTPException(status_code=503, detail="Dose log not initialized")

    log_entry = {
        "drug_name": entry.drug_name,
        "dosage": entry.dosage,
        "form": entry.form,
        "timestamp": entry.timestamp or datetime.now(timezone.utc).isoformat(),
        "interactions_found": entry.interactions_found,
    }
    success = dose_log.append_log(log_entry)
    if not success:
        raise HTTPException(status_code=500, detail="Failed to write dose log")

    return {"status": "logged", "entry": log_entry}


@app.get("/api/history")
async def get_history():
    """Retrieve decrypted dose history."""
    if not dose_log:
        raise HTTPException(status_code=503, detail="Dose log not initialized")
    return {"logs": dose_log.read_logs()}


@app.post("/api/emergency")
async def trigger_emergency(req: EmergencyRequest):
    """Manually trigger an emergency SMS alert."""
    if not alert_service:
        raise HTTPException(status_code=503, detail="Alert service not configured")
    result = alert_service.send_danger_alert(req.drug_name, req.interactions)
    return result


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=settings.HOST,
        port=settings.PORT,
        reload=False,
    )

