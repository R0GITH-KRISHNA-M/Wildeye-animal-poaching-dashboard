import cv2
import os
import torch
import numpy as np
import face_recognition
from contextlib import asynccontextmanager
from fastapi import FastAPI, UploadFile, File
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from ultralytics import YOLO
import gunshot_detector 
import tempfile
import httpx
import traceback

# --- Configuration & Paths ---
AUTHORIZED_FACES_DIR = "authorized_faces"
DEFAULT_MODEL_PATH = "models/yolov8s.pt"
TIGER_MODEL_PATH = "models/best.pt"

# COCO and Custom Class Indexes
PERSON_CLASS_INDEX = 0
ELEPHANT_CLASS_INDEX = 20
BEAR_CLASS_INDEX = 21
ZEBRA_CLASS_INDEX = 22
GIRAFFE_CLASS_INDEX = 23
TIGER_CLASS_INDEX = 0  # Index 0 in your custom tiger model

# Mac Hardware Acceleration
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"

# Global Shared Data
detections = {"humans": 0, "animals": []}
known_face_encodings = []
known_face_names = []

# --- 1. Load Authorized Faces (Optimization: One-time Load) ---
def load_known_faces():
    global known_face_encodings, known_face_names
    print("⏳ Loading authorized faces...")
    if not os.path.exists(AUTHORIZED_FACES_DIR):
        os.makedirs(AUTHORIZED_FACES_DIR)
        
    for filename in os.listdir(AUTHORIZED_FACES_DIR):
        if filename.lower().endswith((".jpg", ".png", ".jpeg")):
            path = os.path.join(AUTHORIZED_FACES_DIR, filename)
            try:
                img = face_recognition.load_image_file(path)
                encodings = face_recognition.face_encodings(img)
                if encodings:
                    known_face_encodings.append(encodings[0])
                    known_face_names.append(os.path.splitext(filename)[0])
            except Exception as e:
                print(f"⚠️ Error loading {filename}: {e}")
    print(f"✅ Ready: {len(known_face_names)} authorized identities.")

# --- 2. FastAPI Lifespan (Startup/Shutdown) ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"🚀 Launching Wildeye System (Hardware: {DEVICE})...")
    load_known_faces()
    
    # Load YOLO Engines
    app.state.default_model = YOLO(DEFAULT_MODEL_PATH).to(DEVICE)
    app.state.tiger_model = YOLO(TIGER_MODEL_PATH).to(DEVICE)
    
    app.state.cap = cv2.VideoCapture(0)
    yield
    app.state.cap.release()

app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ===================================================================
# --- RESTORED: Reverse Geocode Endpoint ---
# ===================================================================
@app.get("/reverse_geocode")
async def get_reverse_geocode(lat: float, lon: float):
    url = f"https://nominatim.openstreetmap.org/reverse?lat={lat}&lon={lon}&format=json"
    headers = {'User-Agent': 'wildeye-dashboard/1.0'} 
    async with httpx.AsyncClient() as client:
        try:
            response = await client.get(url, headers=headers)
            response.raise_for_status()
            return response.json()
        except Exception as e:
            return JSONResponse(status_code=500, content={"error": "Geocoding failed", "detail": str(e)})

# ===================================================================
# --- RESTORED: Gunshot Detection Endpoint ---
# ===================================================================
@app.post("/upload_audio")
async def upload_audio(file: UploadFile = File(...)):
    temp_path = None
    try:
        ext = os.path.splitext(file.filename)[1]
        with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
            tmp.write(await file.read())
            temp_path = tmp.name
        
        result, score = gunshot_detector.detect_gunshot(temp_path, threshold=0.1)
        if temp_path and os.path.exists(temp_path): os.unlink(temp_path)
        return JSONResponse(content={"result": result, "score": score})
    except Exception as e:
        if temp_path and os.path.exists(temp_path): os.unlink(temp_path)
        return JSONResponse(status_code=500, content={"error": str(e)})

# ===================================================================
# --- MERGED: Video Generation with Authorized Ghosting ---
# ===================================================================
def gen_frames():
    global detections
    model = app.state.default_model
    tiger_model = app.state.tiger_model
    cap = app.state.cap

    while True:
        success, frame = cap.read()
        if not success: break

        current_humans = 0
        current_animals = []
        annotated_frame = frame.copy()

        # Step A: Run Primary YOLO (Wildlife + Humans)
        primary_results = model(
            frame, conf=0.45, iou=0.5, device=DEVICE, verbose=False,
            classes=[PERSON_CLASS_INDEX, ELEPHANT_CLASS_INDEX, BEAR_CLASS_INDEX, ZEBRA_CLASS_INDEX, GIRAFFE_CLASS_INDEX]
        )

        # Step B: Optimize Face Recon (Resize to 1/4)
        small_frame = cv2.resize(frame, (0, 0), fx=0.25, fy=0.25)
        rgb_small = cv2.cvtColor(small_frame, cv2.COLOR_BGR2RGB)
        face_locations = face_recognition.face_locations(rgb_small)
        face_encodings = face_recognition.face_encodings(rgb_small, face_locations)

        for box in primary_results[0].boxes:
            cls = int(box.cls[0])
            x1, y1, x2, y2 = map(int, box.xyxy[0])
            conf = float(box.conf[0])

            if cls == PERSON_CLASS_INDEX:
                # Ghosting Logic: Check if authorized
                is_authorized = False
                for face_encoding in face_encodings:
                    matches = face_recognition.compare_faces(known_face_encodings, face_encoding, tolerance=0.5)
                    if True in matches:
                        is_authorized = True
                        break
                
                # ONLY draw and count if NOT authorized
                if not is_authorized:
                    current_humans += 1
                    cv2.rectangle(annotated_frame, (x1, y1), (x2, y2), (0, 255, 255), 2)
                    cv2.putText(annotated_frame, f"Unauthorized {conf:.2f}", (x1, y1 - 10), 
                                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
            else:
                # Handle Elephant, Bear, Zebra, Giraffe
                label = model.names[cls]
                current_animals.append(label.lower())
                cv2.rectangle(annotated_frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
                cv2.putText(annotated_frame, f"{label} {conf:.2f}", (x1, y1 - 10), 
                            cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)

        # Step C: Tiger Model
        tiger_res = tiger_model(frame, conf=0.75, device=DEVICE, verbose=False)
        for box in tiger_res[0].boxes:
            current_animals.append("tiger")
            x1, y1, x2, y2 = map(int, box.xyxy[0])
            cv2.rectangle(annotated_frame, (x1, y1), (x2, y2), (0, 0, 255), 2)
            cv2.putText(annotated_frame, "TIGER ALERT", (x1, y1 - 10), 
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)

        detections = {"humans": current_humans, "animals": current_animals}
        _, buffer = cv2.imencode(".jpg", annotated_frame)
        yield (b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + buffer.tobytes() + b"\r\n")

@app.get("/live")
async def live_feed():
    return StreamingResponse(gen_frames(), media_type="multipart/x-mixed-replace; boundary=frame")

@app.get("/detections")
async def get_detections():
    return JSONResponse(content=detections)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000, reload=False)