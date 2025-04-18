from cartesia import Cartesia
client = Cartesia(api_key="sk_car_B5tpPKH9mkVGKUvr1bbeYK")
voices = client.voices.list()
print(voices)