from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
import io
import time
import threading
import queue
from tts import text_to_speech, executor  # Import the executor from tts.py
from stt import transcribe_audio
import logging
from dotenv import load_dotenv
import os
import google.generativeai as genai
import re
from collections import defaultdict

# Add this after your existing global variables
# Store conversation history keyed by some identifier (could be session ID or user ID)
conversation_histories = defaultdict(list)
MAX_HISTORY_LENGTH = 10  # Limit history to prevent tokens getting too large

# Configure logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Enable CORS for all domains - important for mobile and web clients
CORS(app, resources={r"/api/*": {"origins": "*"}})

# Load environment variables
load_dotenv()
logger.debug("Loading environment variables from .env file")

# Configure Gemini API key
API_KEY = os.getenv('GEMINI_API_KEY')
logger.debug(f"Loaded GEMINI_API_KEY: {API_KEY[:4]}...{API_KEY[-4:]}" if API_KEY else "GEMINI_API_KEY not found")  # Partial key for security
if not API_KEY:
    logger.error("GEMINI_API_KEY not found in environment variables")
    raise ValueError("GEMINI_API_KEY not found in environment variables. Please check your .env file.")

genai.configure(api_key=API_KEY)

# Optimization: Setup request queue and response cache
request_queue = queue.Queue()
response_cache = {}
CACHE_EXPIRY = 3600  # 1 hour

# Request tracking for better error handling
active_requests = {}
request_counter = 0
request_lock = threading.Lock()

def get_request_id():
    global request_counter
    with request_lock:
        request_counter += 1
        return f"req-{request_counter}"

@app.route('/api/convert', methods=['POST'])
def convert_text():
    req_id = get_request_id()
    logger.debug(f"Received TTS request [{req_id}]")
    active_requests[req_id] = {"start_time": time.time(), "status": "processing"}
    
    try:
        data = request.json
        if not data:
            logger.warning(f"[{req_id}] No data provided")
            return jsonify({"error": "No data provided"}), 400
        
        text = data.get('text', '')
        voice = data.get('voice', 'default')
        speed = float(data.get('speed', 1.0))
        streaming = data.get('streaming', False)  # New parameter for streaming
        logger.debug(f"[{req_id}] TTS parameters: text={text[:20]}..., voice={voice}, speed={speed}, streaming={streaming}")
        
        if not text:
            return jsonify({"error": "Text is required"}), 400
        if not isinstance(speed, (int, float)) or speed < 0.5 or speed > 2.0:
            return jsonify({"error": "Speed must be between 0.5 and 2.0"}), 400

        valid_voices = ['default', 'male', 'female']
        if voice.lower() not in valid_voices:
            return jsonify({"error": f"Voice must be one of: {', '.join(valid_voices)}"}), 400
        
        # For streaming mode, we handle differently
        if streaming:
            try:
                # Get streaming generator from TTS function
                audio_stream = text_to_speech(text, voice, speed, streaming=True)
                
                # Return a streaming response
                return app.response_class(
                    audio_stream,
                    mimetype='audio/wav',
                    headers={'Content-Disposition': 'attachment; filename=speech.wav'}
                )
                
            except Exception as tts_error:
                logger.error(f"[{req_id}] TTS streaming error: {str(tts_error)}", exc_info=True)
                return jsonify({"error": f"TTS streaming failed: {str(tts_error)}"}), 500
        
        # For non-streaming mode, continue with existing code
        # Check cache first for faster response
        cache_key = f"tts:{text[:100]}:{voice}:{speed}"
        if cache_key in response_cache:
            cache_entry = response_cache[cache_key]
            if time.time() - cache_entry['timestamp'] < CACHE_EXPIRY:
                logger.debug(f"[{req_id}] TTS cache hit")
                audio_data = cache_entry['data']
                audio_io = io.BytesIO(audio_data)
                audio_io.seek(0)
                return send_file(
                    audio_io,
                    mimetype='audio/wav',
                    as_attachment=True,
                    download_name='speech.wav'
                )
        
        try:
            # Submit TTS task to thread pool
            future = executor.submit(text_to_speech, text, voice, speed, False)
            # Add small timeout for better error handling
            audio_data = future.result(timeout=15)
            
            if not audio_data or len(audio_data) < 100:
                return jsonify({"error": "Generated audio data is invalid or empty"}), 500
                
            # Update cache
            response_cache[cache_key] = {
                'data': audio_data,
                'timestamp': time.time()
            }
            
            logger.debug(f"[{req_id}] TTS conversion successful, audio size: {len(audio_data)} bytes")
        except Exception as tts_error:
            logger.error(f"[{req_id}] TTS module error: {str(tts_error)}", exc_info=True)
            return jsonify({"error": f"TTS conversion failed: {str(tts_error)}"}), 500
        
        audio_io = io.BytesIO(audio_data)
        audio_io.seek(0)
        
        # Clean up request tracking
        if req_id in active_requests:
            del active_requests[req_id]
            
        return send_file(
            audio_io,
            mimetype='audio/wav',
            as_attachment=True,
            download_name='speech.wav'
        )
        
    except Exception as e:
        logger.error(f"[{req_id}] TTS endpoint error: {str(e)}", exc_info=True)
        # Clean up request tracking
        if req_id in active_requests:
            del active_requests[req_id]
        return jsonify({"error": str(e)}), 500

@app.route('/api/transcribe', methods=['POST'])
def transcribe():
    req_id = get_request_id()
    logger.debug(f"Received STT request [{req_id}]")
    active_requests[req_id] = {"start_time": time.time(), "status": "processing"}
    
    try:
        # Check if audio file is provided
        if 'audio' not in request.files:
            logger.warning(f"[{req_id}] No audio file provided")
            return jsonify({"error": "No audio file provided"}), 400
        
        audio_file = request.files['audio']
        if audio_file.filename == '':
            logger.warning(f"[{req_id}] No selected file")
            return jsonify({"error": "No selected file"}), 400

        # Read audio data
        buffer_data = audio_file.read()
        if not buffer_data:
            logger.warning(f"[{req_id}] Empty audio file")
            return jsonify({"error": "Empty audio file"}), 400
            
        logger.debug(f"[{req_id}] Audio data received, size: {len(buffer_data)} bytes")
        
        # Special case for very small audio files - probably noise or silent
        if len(buffer_data) < 1000:  # Arbitrary threshold for "too small to be meaningful"
            logger.warning(f"[{req_id}] Audio file too small, likely empty/noise")
            return jsonify({"transcript": "No speech detected, please try again."}), 200
            
        # Submit transcription task to thread pool
        future = executor.submit(transcribe_audio, buffer_data)
        transcript = future.result(timeout=20)  # Add timeout for better error handling
        
        # Clean up empty transcripts
        if not transcript or transcript.strip() == "":
            transcript = "No speech detected, please try again."
            
        logger.debug(f"[{req_id}] Transcription successful: {transcript[:50]}...")
        
        # Clean up request tracking
        if req_id in active_requests:
            del active_requests[req_id]
            
        return jsonify({
            "transcript": transcript,
            "confidence": 0.9  # Add confidence for Flutter app
        })

    except Exception as e:
        logger.error(f"[{req_id}] STT error: {str(e)}", exc_info=True)
        # Clean up request tracking
        if req_id in active_requests:
            del active_requests[req_id]
        return jsonify({"error": str(e)}), 500


@app.route('/api/gemini', methods=['POST'])
def gemini_endpoint():
    req_id = get_request_id()
    logger.debug(f"Received Gemini API request [{req_id}]")
    active_requests[req_id] = {"start_time": time.time(), "status": "processing"}
    
    try:
        data = request.get_json()
        if not data:
            logger.warning(f"[{req_id}] No data provided")
            return jsonify({"error": "No data provided"}), 400
            
        prompt = data.get('prompt', '')
        if not prompt:
            logger.warning(f"[{req_id}] No prompt provided")
            return jsonify({"error": "No prompt provided"}), 400
            
        # Get user identifier - could be IP address, session ID, or something provided in request
        # For simplicity, we'll use IP address in this example
        user_id = request.remote_addr
        
        # Check if this is a new conversation (optional reset mechanism)
        if data.get('reset_conversation', False):
            conversation_histories[user_id] = []
            
        # Optimization: Check cache first for exact same prompt (less useful with conversation history)
        cache_key = f"gemini:{user_id}:{prompt[:100]}"
        if cache_key in response_cache:
            cache_entry = response_cache[cache_key]
            if time.time() - cache_entry['timestamp'] < CACHE_EXPIRY:
                logger.debug(f"[{req_id}] Gemini cache hit")
                return jsonify({'response': cache_entry['data']})

        # Add instructions for keeping responses short and removing special characters
        system_instruction = """
        Respond using clear, grammatically correct, and well-structured language. Keep your responses concise and direct. 
        For simple topics, use 3-4 short sentences. For complex topics, provide a brief explanation of 5-7 sentences maximum.
        
        Do not use asterisks, special characters, or emojis. Maintain a conversational, helpful tone as if you're speaking
        directly to the person. Answer questions directly without unnecessary preamble.
        
        Consider the conversation history when responding. Make your response relevant to the entire conversation,
        not just the most recent message.
        """
        
        # Build conversation history prompt
        conversation_prompt = system_instruction + "\n\nConversation history:\n"
        
        # Add previous exchanges from history
        for i, (old_prompt, old_response) in enumerate(conversation_histories[user_id]):
            conversation_prompt += f"User: {old_prompt}\n"
            conversation_prompt += f"Assistant: {old_response}\n"
        
        # Add current prompt
        conversation_prompt += f"\nUser: {prompt}\nAssistant:"
        
        logger.debug(f"[{req_id}] Generating content with conversation history (total exchanges: {len(conversation_histories[user_id])})")
        model = genai.GenerativeModel('gemini-2.0-flash')
        response = model.generate_content(
            conversation_prompt,
            generation_config={
                "temperature": 0.2,
                "max_output_tokens": 400,  # Reduced for even shorter responses
                "top_p": 0.9,
                "top_k": 40
            }
        )

        result_text = response.text
        
        # Remove asterisks if any still appear
        result_text = result_text.replace('*', '')
        
        # Store in conversation history
        conversation_histories[user_id].append((prompt, result_text))
        
        # Limit history size to prevent token overflow
        if len(conversation_histories[user_id]) > MAX_HISTORY_LENGTH:
            conversation_histories[user_id] = conversation_histories[user_id][-MAX_HISTORY_LENGTH:]
        
        # Update cache
        response_cache[cache_key] = {
            'data': result_text,
            'timestamp': time.time()
        }
        
        logger.debug(f"[{req_id}] Gemini response generated successfully")
        
        # Clean up request tracking
        if req_id in active_requests:
            del active_requests[req_id]
            
        return jsonify({'response': result_text})

    except genai.errors.GenerativeError as e:
        logger.error(f"[{req_id}] Gemini API specific error: {str(e)}", exc_info=True)
        # Clean up request tracking
        if req_id in active_requests:
            del active_requests[req_id]
        return jsonify({"error": f"Gemini API failed: {str(e)}"}), 500
    except Exception as e:
        logger.error(f"[{req_id}] Unexpected error: {str(e)}", exc_info=True)
        # Clean up request tracking
        if req_id in active_requests:
            del active_requests[req_id]
        return jsonify({"error": f"Failed to get Gemini response: {str(e)}"}), 500
    
@app.route('/api/status', methods=['GET'])
def api_status():
    """Provides status information about the API services."""
    try:
        # Check if critical services are working
        tts_ok = os.path.exists("tts_cache")
        stt_ok = os.path.exists("stt_cache")
        
        # Count active requests
        active_count = len(active_requests)
        
        # Count cached items
        cache_stats = {
            "tts_cache_size": len([f for f in os.listdir("tts_cache") if f.endswith('.wav')]) if tts_ok else 0,
            "stt_cache_size": len([f for f in os.listdir("stt_cache") if f.endswith('.txt')]) if stt_ok else 0,
            "memory_cache_size": len(response_cache)
        }
        
        return jsonify({
            "status": "healthy",
            "services": {
                "tts": "ok" if tts_ok else "error",
                "stt": "ok" if stt_ok else "error",
                "gemini": "ok"  # We can't easily test this without making a real request
            },
            "active_requests": active_count,
            "cache_stats": cache_stats,
            "uptime_seconds": time.time() - app.config.get('START_TIME', time.time())
        }), 200
    except Exception as e:
        logger.error(f"Status endpoint error: {str(e)}", exc_info=True)
        return jsonify({"status": "degraded", "error": str(e)}), 200  # Still return 200 to avoid monitoring failures

@app.route('/', methods=['GET'])
def health_check():
    """Simple health check endpoint."""
    logger.debug("Health check requested")
    return jsonify({"status": "healthy", "message": "Server is running"}), 200

# Cache cleaning thread
def clean_cache_periodically():
    while True:
        try:
            # Sleep first to allow server to start properly
            time.sleep(3600)  # Clean every hour
            
            # Clean memory cache
            current_time = time.time()
            expired_keys = [k for k, v in response_cache.items() 
                           if current_time - v['timestamp'] > CACHE_EXPIRY]
            
            for key in expired_keys:
                del response_cache[key]
                
            logger.info(f"Cleaned {len(expired_keys)} items from memory cache")
            
            # Clean file caches (older than 24 hours)
            tts_files = [os.path.join("tts_cache", f) for f in os.listdir("tts_cache") 
                        if f.endswith('.wav') and 
                        os.path.getmtime(os.path.join("tts_cache", f)) < current_time - 86400]
            
            stt_files = [os.path.join("stt_cache", f) for f in os.listdir("stt_cache") 
                        if f.endswith('.txt') and 
                        os.path.getmtime(os.path.join("stt_cache", f)) < current_time - 86400]
            
            for file_path in tts_files + stt_files:
                os.remove(file_path)
                
            logger.info(f"Cleaned {len(tts_files)} TTS files and {len(stt_files)} STT files")
            
        except Exception as e:
            logger.error(f"Error in cache cleaning thread: {e}")

if __name__ == '__main__':
    # Make sure to run on 0.0.0.0 to allow external connections
    host = '0.0.0.0'  # Listens on all network interfaces
    port = 5000
    
    # Record start time for uptime tracking
    app.config['START_TIME'] = time.time()
    
    # Start cache cleaning thread
    cache_cleaner = threading.Thread(target=clean_cache_periodically, daemon=True)
    cache_cleaner.start()
    
    logger.info(f"Starting server on {host}:{port}")
    app.run(debug=True, host=host, port=port, threaded=True)
    logger.info(f"Server running on http://{host}:{port}")