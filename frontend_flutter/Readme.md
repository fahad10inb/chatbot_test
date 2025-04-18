TTS & STT Flutter App
A Flutter application for Text-to-Speech (TTS) and Speech-to-Text (STT) using a Flask backend.
Prerequisites

Flutter SDK: https://flutter.dev/docs/get-started/install
Python 3.8+: For the Flask backend
Android Studio/Xcode: For running on Android/iOS
Deepgram and Cartesia API keys (set in backend)

Setup
Backend

Navigate to backend/.
Install dependencies: pip install -r requirements.txt.
Set the CARTESIA_API_KEY environment variable.
Run the Flask server: python app.py.

Frontend

Navigate to frontend_flutter/.
Install Flutter dependencies: flutter pub get.
Update _ttsApiUrl and _sttApiUrl in lib/main.dart if the backend is not at http://10.0.2.2:5000.
Run the app: flutter run.

Usage

TTS: Enter text, select voice and speed, and click "Convert to Speech" to hear the audio.
STT: Click "Start Recording", speak, and click "Stop Recording" to see the transcription.

Notes

Ensure the backend is running and accessible (e.g., http://10.0.2.2:5000 for Android emulators).
Microphone permissions are required for STT.

