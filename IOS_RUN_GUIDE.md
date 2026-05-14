# iOS Local Build — Quick Guide

## 1. Terminal prep
```bash
cd app && flutter clean && flutter pub get
cd ios && pod install --repo-update
```

## 2. Open in Xcode
Open `app/ios/Runner.xcworkspace` (never `.xcodeproj`).

## 3. Signing & Capabilities (Runner target)
- **Team:** your Apple ID
- **Bundle ID:** unique (e.g. `com.alihan.fitrack`)
- Check **Automatically manage signing**

## 4. Info.plist
Verify `NSCameraUsageDescription` exists with a non-empty string.

## 5. Device
- Plug in iPhone, trust the Mac
- Select device in Xcode's run dropdown
- First run: trust dev cert in **Settings → General → VPN & Device Management**

## 6. Run
Hit ⌘R.

If it fails:
- Clean build folder (⌘⇧K)
- Re-run `pod install`
- Or `flutter clean`
