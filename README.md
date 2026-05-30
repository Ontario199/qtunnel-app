# QTunnel VPN

Android VPN client built with Flutter and sing-box.

## Build

```bash
flutter pub get
flutter build apk --release
```

The release signing key is not included in this repository. To build a signed
release APK, create `android/key.properties` and provide your own keystore.

## Release verification

Official APK builds are published through GitHub Releases with a SHA-256 hash.
You can verify a downloaded APK with:

```powershell
Get-FileHash .\app-release.apk -Algorithm SHA256
```
