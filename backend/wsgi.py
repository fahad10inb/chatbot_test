from app import app
from waitress import serve

if __name__ == "__main__":
    print("Starting production server...")
    print("Server running on http://0.0.0.0:5000")
    
    # Increase threads for handling multiple concurrent connections
    # Adjust timeout values as needed
    serve(
        app,
        host='0.0.0.0',
        port=5000,
        threads=8,
        connection_limit=100,
        channel_timeout=60,
        ident="TTS-STT-Server"
    )