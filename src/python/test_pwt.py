import requests

# The PWT page links to dataverse.nl file IDs — find which one is the Excel file
# Try a few candidates around the range seen on the page
candidates = [354095, 354098, 354100, 354091, 354092, 354093, 354094, 354096, 354097]
for fid in candidates:
    url = f"https://dataverse.nl/api/access/datafile/{fid}"
    r = requests.head(url, timeout=10, allow_redirects=True)
    ct = r.headers.get("Content-Type","")
    cd = r.headers.get("Content-Disposition","")
    cl = r.headers.get("Content-Length","?")
    print(f"  {fid}: {r.status_code}  {ct[:40]}  {cd[:60]}  size={cl}")
