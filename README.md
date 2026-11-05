# Relay app

Relay keeps your thoughts. Hold the Pebble Index ring and talk, or type a note on your phone: each note goes to your own Relay server with the place where you made it. The app can also send your steps, heart rate, sleep, workouts and a history of the places you went, so each day has its notes and its context in one timeline.

This is the phone app, for iPhone and Android. It is written in Flutter.

## What it does

- **Timeline.** Every note, newest first: ring notes and typed notes, each with its time, place and device. A note made with no signal shows as *Waiting* and goes on the next sync.
- **New note.** Tap *New note*, type, and tap *Save*. With *Pin notes to a place* on, the note keeps where you are.
- **Location history.** When you turn it on, the app keeps a point each 100 m you move. A ring note then takes the nearest point within 10 minutes as its place.
- **Health.** When you turn it on, the app reads steps, heart rate, sleep and workouts from Apple Health or Health Connect, and sends them every hour.
- **Your server, your key.** The app talks only to the server you connect it to, with a key for this phone alone. You can turn off one phone's key and keep the others.

Each permission is asked for only when you turn on its setting.

## Get the app

- **Android:** download the newest `.apk` file from [Releases](../../releases/latest) and open it on your phone. Android asks once to allow installs from your browser.
- **iPhone:** install the newest build from TestFlight, from the invite the owner sends you.

## Connect it to a server

A Relay server is a private site behind Cloudflare Access. Its owner makes a key for each phone:

```
node scripts/relay-device-key.mjs create --name "Android phone"
```

The key shows once, as a QR code. In the app, tap *Scan the QR code*, or paste the key. The key holds the server's address. To try a preview, open *Settings*, tap *Server*, and enter the preview's address.

The key is kept in the iPhone Keychain or the Android Keystore, never in the app's own files.

## Build it yourself

1. Install Flutter (the version is in `pubspec.yaml`): https://docs.flutter.dev/get-started/install
2. Get the packages: `flutter pub get`
3. Check and test: `flutter analyze` and `flutter test`
4. Run it on a phone: `flutter run`

### Builds on GitHub

Each push runs `.github/workflows/ci.yml`: analyze and test, then:

- **Android** (`android.yml`): on `main`, a release with a signed `.apk`; on any other branch, the `.apk` as a run artifact. It signs with the upload key in these repository secrets, or with a debug key when they are missing:
  `RELAY_ANDROID_KEYSTORE_BASE64`, `RELAY_ANDROID_KEYSTORE_PASSWORD`, `RELAY_ANDROID_KEY_ALIAS`, `RELAY_ANDROID_KEY_PASSWORD`.
- **iPhone** (`ios.yml`): on a Mac, fastlane signs the build automatically and sends it to TestFlight. It needs a paid Apple Developer Program membership, the app's record in App Store Connect (bundle id `com.matthewwong525.relayApp`), and these secrets:
  `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_KEY_P8` (the `.p8` file in base64), `APPLE_TEAM_ID`. Until they are set, the iPhone job ends with a notice and builds nothing.

Never commit a key, a keystore, a `.p8` file or a signing profile.

## Where the code is

- `lib/data/`: the local store (SQLite through drift), the API client and the outbox that sends waiting uploads in order.
- `lib/sync/`: health, location and the hourly background sync.
- `lib/screens/`: timeline, new note, settings and connect.
- `test/`: unit tests for the store, outbox, API and sync, and widget tests for each screen.

This repository is a copy of the app folder of the Relay ring's private project, updated on each published change. Changes made here directly are overwritten.
