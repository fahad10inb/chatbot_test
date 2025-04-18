import os
import logging
import types
from cartesia import Cartesia
from dotenv import load_dotenv
import io
# Removed mutagen import for now, will add back if needed

load_dotenv()  # this loads variables from .env into os.environ

# Configure logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Load API key
api_key = os.environ.get("CARTESIA_API_KEY")
if not api_key:
    logger.error("CARTESIA_API_KEY is not set")
    raise ValueError("CARTESIA_API_KEY is not set")

# Initialize Cartesia client
client = Cartesia(api_key=api_key)

def text_to_speech(text, voice="default", speed=1.0):
    """
    Converts text to speech using Cartesia API.

    Args:
        text (str): Text to convert.
        voice (str): Voice choice ('default', 'male', or 'female').
        speed (float): Speed factor between 0.5 and 2.0.

    Returns:
        bytes: WAV audio data.
    """
    try:
        logger.debug(f"Input: text='{text[:50]}...', voice={voice}, speed={speed}")

        # Validation
        if not isinstance(text, str) or not text.strip():
            raise ValueError("Text must be a non-empty string")
        if voice.lower() not in ["default", "male", "female"]:
            raise ValueError("Voice must be 'default', 'male', or 'female'")
        if not isinstance(speed, (int, float)) or speed < 0.5 or speed > 2.0:
            raise ValueError("Speed must be between 0.5 and 2.0")

        # Voice ID mapping
        voice_mapping = {
            "default": "c99d36f3-5ffd-4253-803a-535c1bc9c306",
            "male": "ab109683-f31f-40d7-b264-9ec3e26fb85e",
            "female": "bf0a246a-8642-498a-9950-80c35e9276b5"
        }
        selected_voice = voice_mapping.get(voice.lower(), voice_mapping["default"])
        logger.debug(f"Selected voice ID: {selected_voice}")

        # Speed mapping
        speed_mapping = {
            0.5: "slowest",
            0.75: "slower",
            1.0: "normal",
            1.25: "faster",
            1.5: "fast",
            2.0: "fastest"
        }
        speed_values = sorted(speed_mapping.keys())
        closest_speed = min(speed_values, key=lambda x: abs(x - speed))
        speed_setting = speed_mapping.get(closest_speed, "normal")
        logger.debug(f"Selected speed setting: {speed_setting}")

        # Call the Cartesia API
        logger.debug("Calling client.tts.bytes with model_id=sonic-2, voice_id=%s, speed=%s, text='%s'", selected_voice, speed_setting, text[:50])
        audio_data = client.tts.bytes(
            model_id="sonic-2",
            transcript=text,
            voice={
                "mode": "id",
                "id": selected_voice,
                "experimental_controls": {"speed": speed_setting}
            },
            language="en",
            output_format={
                "container": "wav",  # Changed to WAV
                "encoding": "pcm_f32le",  # Changed to PCM F32 LE
                "sample_rate": 44100  # Updated to 44100 Hz
            }
        )

        # Handle generator or byte response
        logger.debug(f"Received audio_data type: {type(audio_data)}")
        if isinstance(audio_data, types.GeneratorType):
            logger.warning("Unexpected generator from tts.bytes, combining chunks")
            audio_data = b"".join(chunk for chunk in audio_data if isinstance(chunk, bytes))
            logger.debug(f"Combined audio_data length: {len(audio_data)} bytes")
            # Removed WAV validation due to import issue, returning raw data
            logger.warning("Skipping WAV validation due to mutagen import issue")
        elif not isinstance(audio_data, bytes):
            raise TypeError(f"Expected bytes, got {type(audio_data)}")

        return audio_data

    except Exception as e:
        logger.error(f"Error in TTS conversion: {str(e)}")
        raise Exception(f"Failed to convert text to speech: {str(e)}")