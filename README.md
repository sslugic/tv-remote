# Simply Remote

A universal Wi-Fi TV remote for iPhone. It finds TVs on your network by itself and controls them over their local network APIs: no IR blaster, no cloud account.

## Supported TVs

| Brand | How it connects | Setup on the TV |
|---|---|---|
| Samsung (2016+ Tizen) | WebSocket, port 8002 | Choose **Allow** once |
| LG (webOS) | SSAP WebSocket, port 3001/3000 | Choose **Allow** once |
| Roku players and Roku TVs (TCL, Hisense, …) | ECP, port 8060 | None |
| Google TV / Android TV (Sony, TCL, Hisense, Philips, Chromecast) | Android TV Remote v2, ports 6466/6467 | Enter the code shown on the TV |
| Sony Bravia | IRCC, port 80 | Set a Pre-Shared Key under IP control |
| Vizio SmartCast | HTTPS, port 7345/9000 | Enter the PIN shown on the TV |
| Amazon Fire TV | ADB, port 5555 | Turn on ADB debugging, then **Allow** |
| Panasonic VIERA (≈2011–2018) | SOAP, port 55000 | None |

Only the Samsung driver has been tested on real hardware so far.

## Features

- Automatic discovery of every supported brand on the Wi-Fi
- D-pad or swipe pad, volume/channel, sources (TV, HDMI, input list), TV settings
- One-tap streaming app shortcuts (Netflix, YouTube, Prime Video, Disney+, Hulu, HBO Max, Peacock, Apple TV, Paramount+)
- Type on the TV with the phone keyboard
- Power on via Wake-on-LAN, sleep timer
- Siri & Shortcuts, Home/Lock Screen widgets, Live Activity / Dynamic Island, Apple Watch app
- Themes, reorderable app shortcuts that hide apps not installed on the TV
- Trending movies and shows with where to watch, opening the title's app on the TV (data from TMDB and JustWatch)

## Build

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project SimplyRemote.xcodeproj -scheme SimplyRemote -configuration Release \
  -destination generic/platform=iOS -derivedDataPath build -allowProvisioningUpdates build
IPHONE_ID=<your device id> ./install.sh
```

Set `DEVELOPMENT_TEAM` in `project.yml` to your own team.

The Trending Now strip and What to Watch page use [TMDB](https://www.themoviedb.org). Create a free API key there and put its read access token in a `Secrets.xcconfig` next to `project.yml` (it's git-ignored):

```
TMDB_TOKEN = <your API read access token>
```

Without it, the movie sections are simply hidden.

TMDB's API is free for non-commercial use with attribution. The app shows the TMDB logo and TMDB's required notice (*"This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."*) in Settings → About & Credits, on the What to Watch page and next to Trending Now. Streaming availability is JustWatch data supplied through TMDB and is credited to JustWatch.

Streaming services appear as brand-colored text tiles. For a personal build with the official app icons, run `python3 scripts/fetch_app_icons.py Sources/Shared/Assets.xcassets`. Those icons are trademarks and are not part of this repo.

## Privacy

The app talks only to TVs on your local network. See the [privacy policy](https://sslugic.github.io/tv-remote/privacy.html).
