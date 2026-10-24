# Downloads each streaming app's App Store icon into the asset catalog as app-<id>.
import json, os, sys, urllib.request

APPS = {
    "netflix": 363590051, "youtube": 544007664, "prime": 545519333, "disney": 1446075923,
    "hulu": 376510438, "max": 1666653815, "peacock": 1508186374, "appleTV": 1174078549,
    "paramount": 530168168,
}
root = sys.argv[1]
ids = ",".join(str(v) for v in APPS.values())
results = json.load(urllib.request.urlopen(f"https://itunes.apple.com/lookup?id={ids}&country=us"))["results"]
art = {r["trackId"]: r["artworkUrl512"].replace("512x512bb.jpg", "256x256bb.png") for r in results}
for name, track in APPS.items():
    folder = os.path.join(root, f"app-{name}.imageset")
    os.makedirs(folder, exist_ok=True)
    urllib.request.urlretrieve(art[track], os.path.join(folder, "icon.png"))
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "icon.png", "idiom": "universal"}],
                   "info": {"author": "xcode", "version": 1}}, f)
    print(name, "ok")
