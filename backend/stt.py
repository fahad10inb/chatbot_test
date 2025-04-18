from deepgram import DeepgramClient, PrerecordedOptions

# Initialize the Deepgram client
DEEPGRAM_API_KEY = "USE_YOUR_API_KEY"
deepgram = DeepgramClient(DEEPGRAM_API_KEY)

def transcribe_audio(audio_data):
    """
    Transcribe audio data using Deepgram API.

    Args:
        audio_data (bytes): The audio data to transcribe.

    Returns:
        str: The transcribed text.
    """
    try:
        source = {
            "buffer": audio_data,
            "mimetype": "audio/webm"  # Assuming WebM from browser recording
        }

        options = PrerecordedOptions(
            model="nova-3",
            language="en-US",
            smart_format=True,
            diarize=True,
            punctuate=True
        )

        # Transcribe audio
        response = deepgram.listen.rest.v("1").transcribe_file(source, options)
        response_dict = response.to_dict()

        # Extract transcript
        transcript = response_dict["results"]["channels"][0]["alternatives"][0]["transcript"]
        return transcript

    except Exception as e:
        raise Exception(f"Transcription error: {str(e)}")
