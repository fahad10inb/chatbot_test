document.addEventListener('DOMContentLoaded', () => {
    // DOM elements for TTS
    const textInput = document.getElementById('text-input');
    const voiceSelect = document.getElementById('voice-select');
    const speedRange = document.getElementById('speed-range');
    const speedValue = document.getElementById('speed-value');
    const convertBtn = document.getElementById('convert-btn');
    const audioOutput = document.getElementById('audio-output');
    const loading = document.getElementById('loading');
    const errorMessage = document.getElementById('error-message');

    // DOM elements for STT
    const recordBtn = document.getElementById('record-btn');
    const stopBtn = document.getElementById('stop-btn');
    const recordingStatus = document.getElementById('recording-status');
    const transcriptOutput = document.getElementById('transcript-output');

    // Backend API URLs
    const TTS_API_URL = 'http://localhost:5000/api/convert';
    const STT_API_URL = 'http://localhost:5000/api/transcribe';

    // MediaRecorder setup
    let mediaRecorder = null;
    let audioChunks = [];

    // Update speed value display
    speedRange.addEventListener('input', () => {
        speedValue.textContent = speedRange.value;
    });

    // Handle TTS conversion
    convertBtn.addEventListener('click', async () => {
        console.log("Convert button clicked");
        const text = textInput.value.trim();
        console.log("Text to convert:", text);
        
        if (!text) {
            showError('Please enter some text to convert.');
            return;
        }

        const requestData = {
            text: text,
            voice: voiceSelect.value,
            speed: parseFloat(speedRange.value)
        };
        console.log("Request data:", requestData);

        try {
            loading.classList.remove('hidden');
            audioOutput.classList.add('hidden');
            errorMessage.classList.add('hidden');
            
            const response = await fetch(TTS_API_URL, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(requestData)
            });
            console.log("TTS response received");

            if (!response.ok) {
                const errorData = await response.json();
                throw new Error(errorData.message || 'Failed to convert text to speech');
            }

            const audioBlob = await response.blob();
            console.log("Audio blob received");
            
            const audioUrl = URL.createObjectURL(audioBlob);
            
            audioOutput.src = audioUrl;
            audioOutput.classList.remove('hidden');
            audioOutput.play();

        } catch (error) {
            console.error("TTS error:", error);
            showError(error.message || 'An error occurred during conversion');
        } finally {
            loading.classList.add('hidden');
        }
    });

    // Handle audio recording
    recordBtn.addEventListener('click', async () => {
        console.log("Start recording clicked");
        try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            mediaRecorder = new MediaRecorder(stream, { mimeType: 'audio/webm' });
            audioChunks = [];

            mediaRecorder.ondataavailable = (event) => {
                if (event.data.size > 0) {
                    audioChunks.push(event.data);
                }
            };

            mediaRecorder.onstop = async () => {
                const audioBlob = new Blob(audioChunks, { type: 'audio/webm' });
                await transcribeAudio(audioBlob);
                stream.getTracks().forEach(track => track.stop());
            };

            mediaRecorder.start();
            recordBtn.disabled = true;
            stopBtn.disabled = false;
            recordingStatus.classList.remove('hidden');
            transcriptOutput.value = '';
            errorMessage.classList.add('hidden');

        } catch (error) {
            console.error("Recording error:", error);
            showError('Error accessing microphone: ' + error.message);
        }
    });

    // Handle stopping the recording
    stopBtn.addEventListener('click', () => {
        console.log("Stop recording clicked");
        if (mediaRecorder && mediaRecorder.state !== 'inactive') {
            mediaRecorder.stop();
            recordBtn.disabled = false;
            stopBtn.disabled = true;
            recordingStatus.classList.add('hidden');
        }
    });

    // Transcribe audio
    async function transcribeAudio(audioBlob) {
        console.log("Transcribing audio");
        try {
            loading.classList.remove('hidden');
            errorMessage.classList.add('hidden');

            const formData = new FormData();
            formData.append('audio', audioBlob, 'recording.webm');

            const response = await fetch(STT_API_URL, {
                method: 'POST',
                body: formData
            });
            console.log("STT response received");

            if (!response.ok) {
                const errorData = await response.json();
                throw new Error(errorData.message || 'Failed to transcribe audio');
            }

            const result = await response.json();
            console.log("Transcription result:", result);
            transcriptOutput.value = result.transcript || 'No transcription available';

        } catch (error) {
            console.error("STT error:", error);
            showError(error.message || 'An error occurred during transcription');
        } finally {
            loading.classList.add('hidden');
        }
    }

    // Helper function to display errors
    function showError(message) {
        errorMessage.textContent = message;
        errorMessage.classList.remove('hidden');
    }
});