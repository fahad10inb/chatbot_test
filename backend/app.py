from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
import io
from tts import text_to_speech
from stt import transcribe_audio
import logging

logging.basicConfig(level=logging.DEBUG)

app = Flask(__name__)
CORS(app)  # Enable CORS for all routes

@app.route('/api/convert', methods=['POST'])
def convert_text():
    logging.debug("Received TTS request")
    try:
        # Get JSON data from request
        data = request.json
        
        if not data:
            logging.warning("No data provided")
            return jsonify({"message": "No data provided"}), 400
        
        # Extract parameters
        text = data.get('text')
        voice = data.get('voice', 'default')
        speed = float(data.get('speed', 1.0))
        logging.debug(f"Extracted parameters: text={text}, voice={voice}, speed={speed}")
        
        # Validate inputs
        if not text:
            logging.warning("Text is required")
            return jsonify({"message": "Text is required"}), 400
        if not isinstance(speed, (int, float)) or speed < 0.5 or speed > 2.0:
            logging.warning("Speed must be between 0.5 and 2.0")
            return jsonify({"message": "Speed must be between 0.5 and 2.0"}), 400
        if voice.lower() not in ['default', 'male', 'female']:
            logging.warning("Voice must be 'default', 'male', or 'female'")
            return jsonify({"message": "Voice must be 'default', 'male', or 'female'"}), 400
        
        # Convert text to speech
        audio_data = text_to_speech(text, voice, speed)
        logging.debug("TTS conversion successful")
        
        # Create a BytesIO object to serve the audio
        audio_io = io.BytesIO(audio_data)
        audio_io.seek(0)
        
        # Return the audio file as WAV
        return send_file(
            audio_io,
            mimetype='audio/wav',  # Changed to audio/wav
            as_attachment=True,
            download_name='speech.wav'  # Changed to speech.wav
        )
        
    except ValueError as ve:
        logging.error(f"Invalid input: {str(ve)}")
        return jsonify({"message": f"Invalid input: {str(ve)}"}), 400
    except Exception as e:
        logging.error(f"Error: {str(e)}")
        return jsonify({"message": f"Error: {str(e)}"}), 500

@app.route('/api/transcribe', methods=['POST'])
def transcribe():
    logging.debug("Received STT request")
    try:
        # Check if audio file is provided
        if 'audio' not in request.files:
            logging.warning("No audio file provided")
            return jsonify({"message": "No audio file provided"}), 400
        
        audio_file = request.files['audio']
        if audio_file.filename == '':
            logging.warning("No selected file")
            return jsonify({"message": "No selected file"}), 400

        # Read audio data
        buffer_data = audio_file.read()
        logging.debug("Audio data read")
        
        # Call the transcribe_audio function from stt.py
        transcript = transcribe_audio(buffer_data)
        logging.debug("STT transcription successful")
        
        return jsonify({
            "transcript": transcript
        })

    except Exception as e:
        logging.error(f"Error: {str(e)}")
        return jsonify({"message": f"Error: {str(e)}"}), 500

@app.route('/', methods=['GET'])
def health_check():
    logging.debug("Health check requested")
    return jsonify({"message": "Server is running"}), 200

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)
    print("Server running on http://localhost:5000")