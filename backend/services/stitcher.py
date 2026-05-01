"""
IrisAI — OpenCV Cylindrical Label Stitcher
===========================================
Stitches 4-6 overlapping frames of a cylindrical medicine bottle
into a single flat panorama image for OCR processing.

Pipeline:
  1. Primary: OpenCV Stitcher (SCANS mode) — handles most cases
  2. Fallback: ORB feature matching + homography warp — for difficult labels
"""

import logging
import time
from typing import Optional
import cv2
import numpy as np

logger = logging.getLogger("iris.stitcher")


class CylindricalStitcher:
    """Unwraps curved medicine labels into flat 2D panoramas."""

    def __init__(self):
        self._stitcher = cv2.Stitcher.create(cv2.Stitcher_SCANS)
        # Tune for medicine labels (high overlap, small images)
        self._stitcher.setPanoConfidenceThresh(0.5)
        self._orb = cv2.ORB.create(nfeatures=1000)
        self._bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)

    def stitch(self, frames: list[np.ndarray]) -> Optional[np.ndarray]:
        """
        Stitch multiple frames into a single panorama.
        Returns the stitched image or None if stitching fails.
        """
        if not frames:
            return None
        if len(frames) == 1:
            return frames[0]

        t0 = time.perf_counter()

        # Primary path: OpenCV Stitcher (SCANS mode)
        status, panorama = self._stitcher.stitch(frames)
        if status == cv2.Stitcher_OK:
            elapsed = (time.perf_counter() - t0) * 1000
            logger.info(f"Stitcher OK: {len(frames)} frames → {panorama.shape} in {elapsed:.0f}ms")
            return panorama

        logger.warning(f"Stitcher failed (status={status}), trying ORB fallback...")

        # Fallback: ORB feature matching
        result = self._orb_stitch(frames)
        elapsed = (time.perf_counter() - t0) * 1000
        if result is not None:
            logger.info(f"ORB fallback OK: {len(frames)} frames in {elapsed:.0f}ms")
        else:
            logger.error(f"Both stitching methods failed after {elapsed:.0f}ms")
        return result

    def _orb_stitch(self, frames: list[np.ndarray]) -> Optional[np.ndarray]:
        """Fallback stitcher using ORB features + homography."""
        try:
            base = frames[0]
            for i in range(1, len(frames)):
                kp1, des1 = self._orb.detectAndCompute(
                    cv2.cvtColor(base, cv2.COLOR_BGR2GRAY), None
                )
                kp2, des2 = self._orb.detectAndCompute(
                    cv2.cvtColor(frames[i], cv2.COLOR_BGR2GRAY), None
                )

                if des1 is None or des2 is None or len(des1) < 10 or len(des2) < 10:
                    logger.warning(f"Insufficient features in frame {i}")
                    continue

                matches = self._bf.match(des1, des2)
                matches = sorted(matches, key=lambda x: x.distance)

                if len(matches) < 10:
                    logger.warning(f"Insufficient matches for frame {i}: {len(matches)}")
                    continue

                good = matches[:50]
                src_pts = np.float32([kp1[m.queryIdx].pt for m in good]).reshape(-1, 1, 2)
                dst_pts = np.float32([kp2[m.trainIdx].pt for m in good]).reshape(-1, 1, 2)

                H, mask = cv2.findHomography(dst_pts, src_pts, cv2.RANSAC, 5.0)
                if H is None:
                    continue

                h1, w1 = base.shape[:2]
                h2, w2 = frames[i].shape[:2]
                warped = cv2.warpPerspective(frames[i], H, (w1 + w2, max(h1, h2)))
                warped[0:h1, 0:w1] = base
                # Crop black borders
                gray = cv2.cvtColor(warped, cv2.COLOR_BGR2GRAY)
                _, thresh = cv2.threshold(gray, 1, 255, cv2.THRESH_BINARY)
                contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
                if contours:
                    x, y, w, h = cv2.boundingRect(max(contours, key=cv2.contourArea))
                    base = warped[y:y + h, x:x + w]
                else:
                    base = warped

            return base
        except Exception as e:
            logger.error(f"ORB stitch error: {e}")
            return None


# Singleton
stitcher = CylindricalStitcher()
