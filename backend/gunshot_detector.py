import tensorflow as tf
import tensorflow_hub as hub
import numpy as np
import librosa
import csv
import os

# --- Model and Class Loading ---

# Suppress TensorFlow warnings
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'
tf.get_logger().setLevel('ERROR')

def load_yamnet_model():
    """Loads the YAMNet model from TensorFlow Hub."""
    try:
        model = hub.load('https://tfhub.dev/google/yamnet/1')
        return model
    except Exception as e:
        print("Error loading YAMNet model. Check your internet connection.")
        print(f"Details: {e}")
        return None

def load_class_names(model):
    """Loads class names from the YAMNet CSV file."""
    try:
        class_map_path = model.class_map_path().numpy().decode('utf-8')
        class_names = []
        with open(class_map_path, 'r') as csvfile:
            reader = csv.reader(csvfile)
            next(reader)  # Skip header
            for row in reader:
                class_names.append(row[2])  # Class name is in the 3rd column
        return class_names
    except Exception as e:
        print(f"Error loading class map from model: {e}")
        return None

# Load the model and class names globally when the module is imported
model = load_yamnet_model()
class_names = load_class_names(model) if model else []

# Find the index for 'Gunshot'
GUNSHOT_CLASS_INDEX = -1
if class_names:
    try:
        # The official class name in YAMNet is "Gunshot, gunfire"
        GUNSHOT_CLASS_INDEX = class_names.index("Gunshot, gunfire")
    except ValueError:
        try:
            GUNSHOT_CLASS_INDEX = class_names.index("Gunshot") # Fallback
        except ValueError:
            print("Error: 'Gunshot' or 'Gunshot, gunfire' not found in class list.")
else:
    print("Error: Could not load class names.")

# --- Core Detection Function ---

def detect_gunshot(audio_file_path, threshold=0.1):
    """
    Detects a gunshot in an audio file.

    Args:
        audio_file_path (str): Path to the audio file.
        threshold (float): The minimum score (0.0 to 1.0) to be considered a detection.

    Returns:
        tuple: (detection_result_string, highest_score)
    """
    if model is None or GUNSHOT_CLASS_INDEX == -1:
        return "Detection error: Model or class not loaded", 0.0

    try:
        # 1. Load the audio file
        # Librosa loads as float32, mono, and resamples to 16kHz (required by YAMNet)
        wav_data, sr = librosa.load(audio_file_path, sr=16000, mono=True)
        
        # 2. Get the model's predictions
        # The model returns: (scores, embeddings, log_mel_spectrogram)
        scores, _, _ = model(wav_data)
        
        # Scores is a 2D tensor (frames, 521 classes). 
        # We check the max score for our class across all frames.
        scores_np = scores.numpy()
        gunshot_scores = scores_np[:, GUNSHOT_CLASS_INDEX]
        
        # --- START OF FIX ---
        # Get the max score (which is a numpy.float32)
        highest_score_np = np.max(gunshot_scores)
        
        # Convert it to a standard Python float so it's JSON serializable
        highest_score = float(highest_score_np) 
        # --- END OF FIX ---

        # 3. Check against the threshold
        if highest_score >= threshold:
            return f"Gunshot detected (Confidence: {highest_score:.2f})", highest_score
        else:
            return f"No gunshot detected (Max score: {highest_score:.2f})", highest_score

    except Exception as e:
        return f"Error processing file {audio_file_path}: {e}", 0.0

# --- Example Usage (when run directly) ---

if __name__ == "__main__":
    """
    This part runs only when you execute `python gunshot_detector.py`
    It's for testing the module itself.
    """
    print("--- Testing gunshot_detector.py module ---")
    
    # Example: Use a known test file from the Librosa library (will not contain a gunshot)
    try:
        test_file = librosa.example('trumpet')
        print(f"--- Running test on a known file (trumpet) ---")
        result, score = detect_gunshot(test_file, threshold=0.1)
        print(f"File: 'librosa_example_trumpet'")
        print(f"Result: {result}\n")

    except Exception as e:
        print(f"Could not load librosa example file for testing: {e}")
        print("Please test with your own audio file path.")

    # You can uncomment this to test your own file directly
    # print(f"--- Running test on a custom file ---")
    # my_custom_file = "audio_samples/your_test_file.wav" # Make sure this path is correct
    # if os.path.exists(my_custom_file):
    #     result, score = detect_gunshot(my_custom_file, threshold=0.1)
    #     print(f"File: {my_custom_file}")
    #     print(f"Result: {result}\n")
    # else:
    #     print(f"Test file not found: {my_custom_file}")