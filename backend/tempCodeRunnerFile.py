import google.generativeai as genai
import os

# Load the API key from environment variables (e.g., from .env file)
api_key = os.getenv('GEMINI_API_KEY')
if not api_key:
    raise ValueError("GEMINI_API_KEY not found in environment variables. Please set it in your .env file.")

# Configure the API client
genai.configure(api_key=api_key)

# List and print available models
try:
    models = genai.list_models()
    print("Available Gemini models:")
    for model in models:
        print(f"- {model.name} (Supported: {model.supported_generation_methods})")
except Exception as e:
    print(f"Error checking models: {str(e)}")