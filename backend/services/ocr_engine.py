"""
IrisAI — TrOCR Text Extraction Engine
======================================
Extracts text from medicine label images using Microsoft TrOCR.
"""

import logging
import time
from typing import Optional
import cv2
import numpy as np

logger = logging.getLogger("iris.ocr")

try:
    from transformers import TrOCRProcessor, VisionEncoderDecoderModel
    from PIL import Image
    _TROCR_AVAILABLE = True
except ImportError:
    _TROCR_AVAILABLE = False
    logger.warning("transformers/torch not installed — OCR fallback")


class OCREngine:
    """TrOCR-based text extraction with preprocessing."""

    def __init__(self, model_name: str = "microsoft/trocr-base-printed"):
        self.model = None
        self.processor = None
        if _TROCR_AVAILABLE:
            try:
                self.processor = TrOCRProcessor.from_pretrained(model_name)
                self.model = VisionEncoderDecoderModel.from_pretrained(model_name)
                logger.info("TrOCR loaded")
            except Exception as e:
                logger.error(f"TrOCR load failed: {e}")

    def _preprocess(self, image: np.ndarray) -> np.ndarray:
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image.copy()
        binary = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 11, 2)
        coords = np.column_stack(np.where(binary < 128))
        if len(coords) > 100:
            angle = cv2.minAreaRect(coords)[-1]
            if angle < -45:
                angle = 90 + angle
            if abs(angle) > 0.5:
                h, w = binary.shape
                M = cv2.getRotationMatrix2D((w // 2, h // 2), angle, 1.0)
                binary = cv2.warpAffine(binary, M, (w, h), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)
        return binary

    def _segment_lines(self, image: np.ndarray) -> list[np.ndarray]:
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image
        proj = np.sum(255 - gray, axis=1)
        threshold = np.max(proj) * 0.1
        lines, in_line, start = [], False, 0
        for i, val in enumerate(proj):
            if val > threshold and not in_line:
                in_line, start = True, max(0, i - 2)
            elif val <= threshold and in_line:
                in_line = False
                end = min(len(proj), i + 2)
                if end - start > 8:
                    lines.append(image[start:end])
        if in_line:
            lines.append(image[start:])
        return lines if lines else [image]

    def extract_text(self, image: np.ndarray) -> str:
        t0 = time.perf_counter()
        if self.model is None or self.processor is None:
            return ""
        try:
            processed = self._preprocess(image)
            lines = self._segment_lines(processed)
            extracted = []
            for line_img in lines:
                pil_img = Image.fromarray(line_img).convert("RGB") if len(line_img.shape) == 2 else Image.fromarray(cv2.cvtColor(line_img, cv2.COLOR_BGR2RGB))
                pixel_values = self.processor(pil_img, return_tensors="pt").pixel_values
                ids = self.model.generate(pixel_values, max_new_tokens=128)
                text = self.processor.batch_decode(ids, skip_special_tokens=True)[0]
                if text.strip():
                    extracted.append(text.strip())
            result = "\n".join(extracted)
            logger.info(f"OCR: {len(extracted)} lines in {(time.perf_counter()-t0)*1000:.0f}ms")
            return result
        except Exception as e:
            logger.error(f"OCR failed: {e}")
            return ""
