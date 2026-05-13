# iPhone Simulator Çalıştırma Rehberi

1. **Simülatörü Başlat:**
   ```bash
   flutter emulators --launch apple_ios_simulator
   ```

2. **iOS Bağımlılıklarını Güncelle (Gerekirse):**
   ```bash
   cd app/ios && pod install && cd ../..
   ```

3. **Uygulamayı Çalıştır:**
   ```bash
   cd app && flutter run
   ```

---
⚠️ **Not:** ML Kit Pose Detection simülatörde çalışmaz (kamera desteği yok). Sadece UI testi içindir. Gerçek test için fiziksel cihaz gereklidir.
