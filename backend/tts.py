import os
import logging
import types
import hashlib
from cartesia import Cartesia
from dotenv import load_dotenv
import io
from concurrent.futures import ThreadPoolExecutor
import threading
import time

# Load environment variables
load_dotenv()

# Configure logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Create thread pool for parallel processing - shared with app.py
executor = ThreadPoolExecutor(max_workers=16)  # Increased from 4 to match stt.py

# Get API key with better error handling
api_key = os.environ.get("CARTESIA_API_KEY")
if not api_key:
    logger.error("CARTESIA_API_KEY is not set in environment variables")
    raise ValueError("CARTESIA_API_KEY is not set. Please check your .env file.")

# Initialize client
client = Cartesia(api_key=api_key)

# Create cache directory if it doesn't exist
cache_dir = "tts_cache"
os.makedirs(cache_dir, exist_ok=True)

# In-memory cache for ultra-fast responses - aligned with app.py
memory_cache = {}
MEMORY_CACHE_SIZE = 100  # Maximum number of entries to keep in memory
MEMORY_CACHE_EXPIRY = 3600  # 1 hour, matching app.py's CACHE_EXPIRY
memory_cache_lock = threading.Lock()  # Add thread safety

# Pre-define voice and speed mappings as constants for faster lookup
VOICE_MAPPING = {
    "default": "c99d36f3-5ffd-4253-803a-535c1bc9c306",
    "male": "ab109683-f31f-40d7-b264-9ec3e26fb85e",
    "female": "bf0a246a-8642-498a-9950-80c35e9276b5"
}

SPEED_MAPPING = {
    0.5: "slowest", 
    0.75: "slower", 
    1.0: "normal", 
    1.25: "faster", 
    1.5: "fast", 
    2.0: "fastest"
}
SPEED_VALUES = sorted(SPEED_MAPPING.keys())

# In tts.py
def text_to_speech(text, voice="default", speed=1.0, streaming=False):
    """
    Convert text to speech using Cartesia API with improved caching and streaming support.
    
    Args:
        text (str): The text to convert to speech.
        voice (str): The voice to use ("default", "male", or "female").
        speed (float): The speed of speech (0.5 to 2.0).
        streaming (bool): Whether to return a streaming response.
        
    Returns:
        bytes or generator: The audio data or a generator yielding audio chunks.
    """
    try:
        start_time = time.time()
        logger.debug(f"TTS request: text='{text[:50]}...', voice={voice}, speed={speed}, streaming={streaming}")
        
        # Input validation
        if not isinstance(text, str) or not text.strip():
            raise ValueError("Text must be a non-empty string")
        if voice.lower() not in VOICE_MAPPING:
            raise ValueError(f"Voice must be one of: {', '.join(VOICE_MAPPING.keys())}")
        if not isinstance(speed, (int, float)) or speed < 0.5 or speed > 2.0:
            raise ValueError("Speed must be between 0.5 and 2.0")
        
        # Generate cache keys
        # Using a shorter hash for memory cache (just the first portion of text)
        memory_cache_key = hashlib.md5(f"{text[:100]}:{voice}:{speed}".encode()).hexdigest()
        
        # Full hash for file cache
        full_cache_key = hashlib.md5(f"{text}:{voice}:{speed}".encode()).hexdigest()
        cache_path = os.path.join(cache_dir, f"{full_cache_key}.wav")
        
        # For streaming requests, we'll still check cache first
        # If found in cache, we can send the entire file as a stream
        
        # Check memory cache first (fastest) with thread safety
        with memory_cache_lock:
            if memory_cache_key in memory_cache:
                cached_entry = memory_cache[memory_cache_key]
                if time.time() - cached_entry['timestamp'] < MEMORY_CACHE_EXPIRY:
                    logger.debug(f"Found in-memory cached audio for: {text[:20]}...")
                    # Update timestamp to keep frequently used items fresh
                    memory_cache[memory_cache_key]['timestamp'] = time.time()
                    
                    if streaming:
                        # For streaming, return a generator that yields the cached data
                        def yield_cached():
                            yield cached_entry['audio_data']
                        return yield_cached()
                    else:
                        return cached_entry['audio_data']
        
        # Then check file cache
        if os.path.exists(cache_path):
            logger.debug(f"Found cached audio file for: {text[:20]}...")
            with open(cache_path, "rb") as f:
                audio_data = f.read()
                
            # Update memory cache with thread safety
            with memory_cache_lock:
                memory_cache[memory_cache_key] = {
                    'audio_data': audio_data,
                    'timestamp': time.time()
                }
                
                # Clean memory cache if too large
                if len(memory_cache) > MEMORY_CACHE_SIZE:
                    # Remove oldest entry
                    oldest_key = min(memory_cache.keys(), key=lambda k: memory_cache[k]['timestamp'])
                    del memory_cache[oldest_key]
            
            if streaming:
                # For streaming, return a generator that yields the cached data
                def yield_cached_file():
                    yield audio_data
                return yield_cached_file()
            else:
                return audio_data
        
        # If not in cache, generate new audio
        # Get voice ID from mapping
        selected_voice = VOICE_MAPPING.get(voice.lower(), VOICE_MAPPING["default"])
        
        # Find closest speed setting
        closest_speed = min(SPEED_VALUES, key=lambda x: abs(x - speed))
        speed_setting = SPEED_MAPPING[closest_speed]
        
        logger.debug(f"Calling Cartesia TTS with model_id=sonic-2, voice_id={selected_voice}, speed={speed_setting}")
        
        # Add timeout handling
        try:
            # If streaming is requested, handle differently
            if streaming:
                # For streaming, use the generator directly from Cartesia
                audio_stream = client.tts.stream(
                    model_id="sonic-2",
                    transcript=text,
                    voice={"mode": "id", "id": selected_voice, "experimental_controls": {"speed": speed_setting}},
                    language="en",
                    output_format={"container": "wav", "encoding": "pcm_f32le", "sample_rate": 44100}
                )
                
                # Create a buffered wrapper around the stream to collect chunks for caching
                chunks = []
                
                def buffered_stream():
                    for chunk in audio_stream:
                        chunks.append(chunk)
                        yield chunk
                    
                    # After streaming completes, save to cache in background
                    def save_to_cache():
                        audio_data = b"".join(chunks)
                        if audio_data and len(audio_data) >= 100:
                            # Save to file cache
                            with open(cache_path, "wb") as f:
                                f.write(audio_data)
                            
                            # Update memory cache
                            with memory_cache_lock:
                                memory_cache[memory_cache_key] = {
                                    'audio_data': audio_data,
                                    'timestamp': time.time()
                                }
                    
                    # Submit cache saving as a background task
                    executor.submit(save_to_cache)
                
                return buffered_stream()
            else:
                # For non-streaming, get complete bytes
                audio_data = client.tts.bytes(
                    model_id="sonic-2",
                    transcript=text,
                    voice={"mode": "id", "id": selected_voice, "experimental_controls": {"speed": speed_setting}},
                    language="en",
                    output_format={"container": "wav", "encoding": "pcm_f32le", "sample_rate": 44100}
                )
        except Exception as e:
            logger.error(f"Error calling Cartesia TTS API: {e}", exc_info=True)
            raise Exception(f"TTS API error: {str(e)}")
        
        # For non-streaming mode, process the response
        if not streaming:
            logger.debug(f"Received audio_data type: {type(audio_data)}")
            if isinstance(audio_data, types.GeneratorType):
                logger.debug("Combining audio chunks from generator")
                # Combine chunks with progress tracking
                chunks = []
                chunk_count = 0
                total_bytes = 0
                
                for chunk in audio_data:
                    if isinstance(chunk, bytes):
                        chunks.append(chunk)
                        chunk_count += 1
                        total_bytes += len(chunk)
                        
                audio_data = b"".join(chunks)
                logger.debug(f"Combined {chunk_count} chunks, total size: {total_bytes} bytes")
            elif not isinstance(audio_data, bytes):
                raise TypeError(f"Expected bytes or generator, got {type(audio_data)}")
            
            # Validate audio data
            if not audio_data or len(audio_data) < 100:
                raise ValueError("Received empty or invalid audio data from TTS API")
                
            # Save to cache for future use
            with open(cache_path, "wb") as f:
                f.write(audio_data)
            
            # Update memory cache with thread safety
            with memory_cache_lock:
                memory_cache[memory_cache_key] = {
                    'audio_data': audio_data,
                    'timestamp': time.time()
                }
                
                # Clean memory cache if too large
                if len(memory_cache) > MEMORY_CACHE_SIZE:
                    # Remove oldest entries (more aggressive cleanup)
                    keys_by_age = sorted(memory_cache.keys(), key=lambda k: memory_cache[k]['timestamp'])
                    for old_key in keys_by_age[:max(1, len(keys_by_age)//10)]:  # Remove ~10% of oldest entries
                        del memory_cache[old_key]
            
            # Report timing
            processing_time = time.time() - start_time
            logger.debug(f"TTS conversion completed in {processing_time:.2f}s, audio size: {len(audio_data)} bytes")
            
            return audio_data
    
    except Exception as e:
        logger.error(f"TTS conversion failed: {str(e)}", exc_info=True)
        raise
# Add a cleanup function that can be called by app.py
def cleanup_old_cache_files(max_age_seconds=86400):  # Default to 24 hours
    """Clean up old cache files"""
    try:
        logger.debug("Cleaning up old TTS cache files")
        current_time = time.time()
        cleaned_files = 0
        
        for filename in os.listdir(cache_dir):
            if filename.endswith('.wav'):
                file_path = os.path.join(cache_dir, filename)
                if os.path.getmtime(file_path) < current_time - max_age_seconds:
                    os.remove(file_path)
                    cleaned_files += 1
        
        logger.info(f"Cleaned up {cleaned_files} old TTS cache files")
    except Exception as e:
        logger.error(f"Error cleaning TTS cache: {e}", exc_info=True)

# Add warmup function to preload common voices
def warmup_tts_engine():
    """Warm up the TTS engine by generating a short audio sample for each voice"""
    try:
        logger.debug("Warming up TTS engine...")
        test_text = "Hello, this is a test."
        
        for voice in VOICE_MAPPING.keys():
            cache_key = hashlib.md5(f"{test_text}:{voice}:1.0".encode()).hexdigest()
            cache_path = os.path.join(cache_dir, f"{cache_key}.wav")
            
            # Only generate if not already cached
            if not os.path.exists(cache_path):
                logger.debug(f"Warming up voice: {voice}")
                # Use a future to avoid blocking
                future = executor.submit(text_to_speech, test_text, voice, 1.0)
                # Don't wait for the result
        
        logger.debug("TTS engine warmup initiated")
    except Exception as e:
        logger.error(f"Error during TTS warmup: {e}", exc_info=True)