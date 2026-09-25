import requests

# Try the correct World Bank DataBank bulk download URL format
urls = [
    "https://api.worldbank.org/v2/en/indicator/GE.EST?downloadformat=csv",
    "https://databank.worldbank.org/data/download/WGI_CSV.zip",
    # WGI via the newer API - direct CSV
    "https://api.worldbank.org/v2/country/AUT;DEU/indicator/GE.EST?format=json&mrv=5&per_page=20",
]
for url in urls:
    r = requests.get(url, timeout=30)
    print(f"Status {r.status_code}: {url[:80]}")
    if r.status_code == 200:
        print("  Content-Type:", r.headers.get("Content-Type",""))
        print("  Preview:", r.text[:200])
    print()
