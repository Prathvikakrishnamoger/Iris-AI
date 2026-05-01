# 👁️ IrisAI — Medication Assistant for the Visually Impaired

> **Real-time Scan-to-Speech pipeline** using YOLOv11 + Gemini Vision + Twilio Safety Shield — designed for **offline-first local processing** with cloud-based emergency alerts.

### 🔗 Links

| | URL |
|---|---|
| **GitHub (HTTPS)** | `https://github.com/Prathvikakrishnamoger/Iris-AI.git` |
| **GitHub (SSH)** | `git@github.com:Prathvikakrishnamoger/Iris-AI.git` |
| **Live Backend** | [https://iris-ai-xvj5.onrender.com](https://iris-ai-xvj5.onrender.com) |
| **Health Check** | [https://iris-ai-xvj5.onrender.com/health](https://iris-ai-xvj5.onrender.com/health) |

```bash
# Clone the repo
git clone https://github.com/Prathvikakrishnamoger/Iris-AI.git
# or via SSH
git clone git@github.com:Prathvikakrishnamoger/Iris-AI.git
```

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Flutter App (Frontend)                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │   Home   │  │   Scan   │  │ History  │  │ TTS / Haptic  │  │
│  │Dashboard │  │  Camera  │  │ Dose Log │  │  Feedback     │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────────────┘  │
│       │              │              │                            │
│  ┌────┴──────────────┴──────────────┴────────────────────────┐  │
│  │  Shake-to-Undo · Swipe-to-Delete · Vision Guidance        │  │
│  │  Haptic Coaching · DANGER Banner · SMS Notification UI    │  │
│  └───────────────────────────────────────────────────────────┘  │
│                      │  HTTP/JSON                               │
└──────────────────────┼──────────────────────────────────────────┘
                       │
┌──────────────────────┼──────────────────────────────────────────┐
│                 FastAPI Backend (0.0.0.0:PORT)                   │
│                      ▼                                           │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │           🧠 Intelligence Loop (< 3s)                     │  │
│  │                                                            │  │
│  │   Camera Frame                                             │  │
│  │       │                                                    │  │
│  │       ▼                                                    │  │
│  │  ┌──────────┐   ┌──────────┐   ┌──────────┐               │  │
│  │  │ OpenCV   │──▶│ YOLOv11  │──▶│  TrOCR   │               │  │
│  │  │ Stitcher │   │Classifier│   │   OCR    │               │  │
│  │  └──────────┘   └──────────┘   └────┬─────┘               │  │
│  │                                      │                     │  │
│  │                          ┌───────────┴───────────┐         │  │
│  │                          ▼                       ▼         │  │
│  │                   ┌───────────┐           ┌───────────┐    │  │
│  │                   │ Gemini    │           │ Gemini    │    │  │
│  │                   │ Text API  │           │ Vision API│    │  │
│  │                   └─────┬─────┘           └─────┬─────┘    │  │
│  │                         └───────────┬───────────┘          │  │
│  │                                     ▼                      │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │              🛡️ Safety Shield                        │  │  │
│  │  │   Local Cache ──▶ RxNorm ──▶ openFDA ──▶ Severity   │  │  │
│  │  └──────────────────────┬───────────────────────────────┘  │  │
│  │                         │                                  │  │
│  │               ┌─────────┼─────────┐                        │  │
│  │               ▼         ▼         ▼                        │  │
│  │            SAFE     CAUTION    DANGER                      │  │
│  │                                   │                        │  │
│  │                          ┌────────▼────────┐               │  │
│  │                          │ 📱 Twilio SMS   │               │  │
│  │                          │ Emergency Alert │               │  │
│  │                          └─────────────────┘               │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  🔒 AES-256-GCM Encrypted Dose Log (dose_log.enc)        │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

---

## ✨ Key Features

### 🧠 Intelligence Loop (YOLOv11 + Gemini)
- **OpenCV Cylindrical Stitcher** — Unwraps curved bottle labels into flat 2D images
- **YOLOv11 Classifier** — Sub-50ms medicine detection with directional haptic guidance
- **TrOCR OCR Engine** — `microsoft/trocr-base-printed` with adaptive thresholding
- **Gemini Dual-Key Fallback** — 4 models per key across 2 API keys = **8 model-slots** for resilient free-tier usage
- **Gemini Vision API** — Direct image reading when OCR fails, bypassing text extraction entirely
- **85-threshold Fuzzy Matching** — Handles OCR misspellings (e.g., "Asprin" → "Aspirin")
- **Anti-Hallucination Guards** — NIH RxNorm verification + OCR cross-validation

### 🛡️ Safety Shield (Twilio SMS Alerts)
- **3-tier severity** — SAFE / CAUTION / DANGER classification
- **Local interaction cache** (40+ drug pairs) → NIH RxNorm → openFDA Label API
- **Automated Twilio SMS** on DANGER: *"Alert from IrisAI: [Name] just scanned [Medicine] which has a HIGH-RISK interaction..."*
- **Dynamic contacts** — reads emergency contact from `med_history.json` at runtime (no restart needed)
- **Rate-limited** to 3 alerts/hour to prevent spam
- **Frontend confirmation** — "Emergency Contact Notified" banner with animated icon

### ♿ Accessibility (WCAG AAA)
- **Priority-queued TTS** with urgent interrupt for DANGER alerts
- **5 haptic patterns** — launch, vision guidance, hold_steady, confirm, danger (triple-burst)
- **Vision Guidance Haptics** — gentle repeating pulse when YOLO confidence < 0.3
- **Shake-to-Undo** — shake phone within 5s to restore accidentally deleted history entries
- **Swipe-to-Delete** — left-swipe on history cards with undo SnackBar
- **56dp minimum** touch targets, WCAG AAA contrast ratios (7:1+)

### 🔒 Security
- **AES-256-GCM** encrypted dose logs with PBKDF2 key derivation (backend)
- **Hive AES-256** encrypted Flutter storage with platform Keystore keys (frontend)
- **No plaintext medical data at rest** — all patient data encrypted
- **Environment-based secrets** — all API keys loaded from `.env`, never hardcoded

---

## 🚀 Quick Start

### Prerequisites
- Python 3.10+
- Flutter 3.19+
- Android device or emulator

### Backend Setup
```bash
cd backend
pip install -r requirements.txt

# Configure environment
cp .env.example .env
# Edit .env with your Gemini API key, Twilio credentials, etc.

# Run locally
python main.py
# Or with uvicorn directly:
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

### Frontend Setup
```bash
cd iris_app
flutter pub get

# Update backend IP in lib/config/app_config.dart
# Set _deviceBackendIp to your laptop's Wi-Fi IP

flutter run                    # Connected Android device
flutter run -d chrome          # Web browser
flutter run --release          # Release build for device
```

### Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `GEMINI_API_KEY` | Google Gemini API key | ✅ |
| `GEMINI_API_KEY_2` | Backup Gemini key (doubles daily quota) | Optional |
| `GEMINI_MODEL` | Model name (default: `gemini-2.0-flash`) | Optional |
| `TWILIO_ACCOUNT_SID` | Twilio Account SID | For SMS |
| `TWILIO_AUTH_TOKEN` | Twilio Auth Token | For SMS |
| `TWILIO_FROM_NUMBER` | Twilio phone number | For SMS |
| `EMERGENCY_CONTACT` | Emergency contact phone | For SMS |
| `USER_NAME` | Patient name for alerts | Optional |
| `ENCRYPTION_PASSPHRASE` | AES-256 encryption key | ✅ |
| `PORT` | Server port (default: 8080) | Optional |

---

## 📡 API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Service health check with component status |
| `/api/scan` | POST | Full AI pipeline (multipart image upload) |
| `/api/check` | POST | Drug interaction check only |
| `/api/log` | POST | Log dose to AES-256 encrypted storage |
| `/api/history` | GET | Retrieve decrypted dose history |
| `/api/emergency` | POST | Manual emergency SMS trigger |

---

## 🛠 Tech Stack

| Layer | Technology |
|-------|-----------|
| **Backend** | FastAPI, Uvicorn, Python 3.10+ |
| **Computer Vision** | OpenCV 4.x, YOLOv11 (Ultralytics) |
| **OCR** | TrOCR (HuggingFace Transformers) |
| **AI** | Google Gemini (2.0-flash, 2.5-flash, 2.0-flash-lite) |
| **Drug APIs** | NIH RxNorm, openFDA Drug Label |
| **SMS Alerts** | Twilio Programmable Messaging |
| **Security** | AES-256-GCM, PBKDF2-HMAC-SHA256 |
| **Frontend** | Flutter 3.x, Hive, flutter_tts, sensors_plus |
| **Storage** | Hive AES-256 + flutter_secure_storage |

---

## 📱 Screenshots

### Scan Flow
1. **Home Dashboard** — Total scans, warnings count, recent scan history
2. **Camera Scan** — Real-time YOLO detection with haptic guidance
3. **Result Card** — Drug info, severity badge, interaction details
4. **DANGER Banner** — Warning overlay with "Emergency Contact Notified"
5. **Dose History** — Swipe-to-delete with shake-to-undo accessibility

---

## 🧪 Test Results

```
14 passed in 10.09s
├── TestLocalCacheLookup (5/5)     — cache hits, bidirectional, multi-drug
├── TestEncryptedDoseLog (5/5)     — write/read, no plaintext, wrong key
├── TestRxNormLive (3/3)           — resolve, cache, unknown
└── TestFullPipeline (1/1)         — end-to-end Aspirin → DANGER
```

---

## 📂 Project Structure

```
Iris-AI/
├── backend/
│   ├── core/
│   │   ├── config.py            # Pydantic settings (env-based)
│   │   └── security.py          # AES-256-GCM encryption
│   ├── services/
│   │   ├── classifier.py        # YOLOv11 medicine detector
│   │   ├── ocr_engine.py        # TrOCR text extraction
│   │   ├── gemini_service.py    # Gemini dual-key structuring
│   │   ├── interaction_checker.py  # Drug safety pipeline
│   │   ├── alert_service.py     # Twilio SMS alerts
│   │   └── stitcher.py          # OpenCV cylindrical stitcher
│   ├── data/
│   │   └── interactions_db.json # Local drug interaction cache
│   ├── tests/                   # Pytest test suite
│   ├── main.py                  # FastAPI application
│   ├── requirements.txt
│   └── .env.example
├── iris_app/
│   └── lib/
│       ├── config/app_config.dart    # Backend URL toggle
│       ├── screens/
│       │   ├── home_screen.dart      # Dashboard
│       │   ├── scan_screen.dart      # Camera + AI pipeline
│       │   └── history_screen.dart   # Swipe-to-delete + shake-undo
│       ├── services/
│       │   ├── api_service.dart      # HTTP client
│       │   ├── haptic_service.dart   # 5 haptic patterns
│       │   ├── tts_service.dart      # Priority TTS engine
│       │   ├── storage_service.dart  # Hive encrypted storage
│       │   └── scan_complete_handler.dart
│       └── theme/stitch_colors.dart  # Dark theme design system
├── .gitignore
└── README.md
```

---

## 🔮 Future Roadmap

- [ ] Cloud deployment (Render / Google Cloud Run)
- [ ] Migrate secrets to Google Secret Manager
- [ ] Image downsampling to reduce Gemini token usage
- [ ] Offline drug database for areas without connectivity
- [ ] Multi-language TTS support (Hindi, Kannada)
- [ ] Barcode/QR code scanning for pharmacy-grade accuracy

---


