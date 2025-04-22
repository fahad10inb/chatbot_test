from deepgram import DeepgramClient, PrerecordedOptions
import hashlib
import os
import time
from concurrent.futures import ThreadPoolExecutor
import logging
import io
import threading

# Configure logging
logger = logging.getLogger(__name__)

# Create thread pool for parallel processing - shared with app.py
executor = ThreadPoolExecutor(max_workers=8)

# Initialize the Deepgram client
DEEPGRAM_API_KEY = "0d98d780e5151b9efdca18cd7d9c966626edff88"
deepgram = DeepgramClient(DEEPGRAM_API_KEY)

# Create cache directory if it doesn't exist
cache_dir = "stt_cache"
os.makedirs(cache_dir, exist_ok=True)

# In-memory cache for ultra-fast responses - aligned with app.py
memory_cache = {}
MEMORY_CACHE_SIZE = 200  # Increased from 100
MEMORY_CACHE_EXPIRY = 3600  # 1 hour, matching app.py's CACHE_EXPIRY
memory_cache_lock = threading.Lock()  # Add thread safety

def get_audio_fingerprint(audio_data):
    """Generate a robust fingerprint for audio content that's less sensitive to minor differences"""
    # Improved sampling method for more reliable fingerprinting
    try:
        # For larger audio files, use a more sophisticated approach
        if len(audio_data) > 10000:
            samples = []
            # Take more samples for better fingerprinting
            chunk_size = max(1, len(audio_data) // 20)  # 20 samples instead of 10
            for i in range(0, len(audio_data), chunk_size):
                if i + 20 < len(audio_data):  # Take more bytes per sample
                    samples.append(audio_data[i:i+20])
            
            fingerprint = hashlib.md5(b''.join(samples)).hexdigest()
        else:
            # For smaller files, use a simpler approach
            fingerprint = hashlib.md5(audio_data).hexdigest()
        
        return fingerprint
    except Exception as e:
        # Fallback to full hash if sampling fails
        logger.warning(f"Error in fingerprinting: {e}, using full hash")
        return hashlib.md5(audio_data).hexdigest()

def transcribe_audio(audio_data):
    """
    Transcribe audio data using Deepgram API with improved caching.
    
    Args:
        audio_data (bytes): The audio data to transcribe.
        
    Returns:
        str: The transcribed text.
    """
    try:
        # Basic validation with better error message
        if not audio_data:
            logger.warning("Empty audio data received")
            return "No speech detected, please try again with audio"
        if len(audio_data) < 500:
            logger.warning(f"Audio data too small ({len(audio_data)} bytes), likely no speech content")
            return "Audio too short, please speak for longer"
            
        start_time = time.time()
        
        # Generate fingerprints for the audio data
        audio_fingerprint = get_audio_fingerprint(audio_data)
        audio_hash = hashlib.md5(audio_data).hexdigest()
        
        # Check memory cache first (fastest) with thread safety
        with memory_cache_lock:
            if audio_fingerprint in memory_cache:
                cached_entry = memory_cache[audio_fingerprint]
                if time.time() - cached_entry['timestamp'] < MEMORY_CACHE_EXPIRY:
                    logger.debug(f"Found in-memory cached transcript for audio fingerprint: {audio_fingerprint[:8]}...")
                    # Update timestamp to keep frequently used items fresh
                    memory_cache[audio_fingerprint]['timestamp'] = time.time()
                    return cached_entry['transcript']
        
        # Then check file cache
        cache_path = os.path.join(cache_dir, f"{audio_hash}.txt")
        if os.path.exists(cache_path):
            logger.debug(f"Found cached transcript for audio hash: {audio_hash[:8]}...")
            with open(cache_path, "r") as f:
                transcript = f.read()
                
            # Also update memory cache with thread safety
            with memory_cache_lock:
                memory_cache[audio_fingerprint] = {
                    'transcript': transcript,
                    'timestamp': time.time()
                }
                
                # Clean memory cache if too large
                if len(memory_cache) > MEMORY_CACHE_SIZE:
                    # Remove oldest entry
                    oldest_key = min(memory_cache.keys(), key=lambda k: memory_cache[k]['timestamp'])
                    del memory_cache[oldest_key]
                    
            return transcript
        
        logger.debug(f"Processing audio for transcription, size: {len(audio_data)} bytes")
        
        # Improved audio format detection
        audio_format = "audio/webm"  # Default assumption
        if len(audio_data) >= 12:
            header = audio_data[:12]
            if header[:4] == b'RIFF' and header[8:12] == b'WAVE':
                audio_format = "audio/wav"
            elif header[:4] == b'OggS':
                audio_format = "audio/ogg"
            elif header[:3] == b'ID3' or header[:2] == b'\xff\xfb':
                audio_format = "audio/mpeg"
            elif header[:4] == b'fLaC':
                audio_format = "audio/flac"
        
        logger.debug(f"Detected audio format: {audio_format}")
            
        source = {
            "buffer": audio_data,
            "mimetype": audio_format
        }
        
        # Enhanced options for better transcription quality
        options = PrerecordedOptions(
            model="nova-3",
            language="en-US",
            smart_format=True,
            diarize=True,
            punctuate=True,
            utterances=True,
            filler_words=False,
            detect_language=True  # Auto-detect language for multilingual support
        )
        
        # Transcribe audio
        response = deepgram.listen.rest.v("1").transcribe_file(source, options)
        response_dict = response.to_dict()
        
        # Extract transcript with better error handling
        try:
            transcript = response_dict["results"]["channels"][0]["alternatives"][0]["transcript"]
            confidence = response_dict["results"]["channels"][0]["alternatives"][0].get("confidence", 0)
            
            # Simple quality check
            if confidence < 0.5 and len(transcript.split()) < 2:
                logger.warning(f"Low confidence transcript: {confidence}")
                transcript = "Speech unclear, please try again speaking more clearly"
        except (KeyError, IndexError) as e:
            logger.error(f"Error extracting transcript: {e}")
            transcript = "Could not transcribe audio, please try again"
        
        # Save transcript to cache
        with open(cache_path, "w") as f:
            f.write(transcript)
            
        # Also update memory cache with thread safety
        with memory_cache_lock:
            memory_cache[audio_fingerprint] = {
                'transcript': transcript,
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
        logger.debug(f"Transcription completed in {processing_time:.2f}s: {transcript[:50]}...")
        return transcript
        
    except Exception as e:
        logger.error(f"Transcription error: {str(e)}", exc_info=True)
        raise Exception(f"Transcription error: {str(e)}")