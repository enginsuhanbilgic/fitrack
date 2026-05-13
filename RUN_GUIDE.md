# FiTrack Çalıştırma Rehberi

## 📱 Gerçek iPhone (En İyi Deneyim)
Kamera ve hareket takibi özelliklerini tam test etmek için en sağlıklı yöntemdir.
1. iPhone'u kabloyla bağla.
2. `cd app`
3. `flutter run`

## 🤖 Android Simülatörü
Simülatör üzerinden test yapmak için en sorunsuz yöntemdir.
1. Simülatörü Başlat:
   ```bash
   flutter emulators --launch Pixel_8
   ```
2. Uygulamayı Çalıştır:
   ```bash
   cd app && flutter run
   ```

## 🍎 iPhone Simülatörü (Sadece Tasarım İçin)
Apple Silicon Mac'lerde mimari kısıtlamaları nedeniyle zordur ve kamera çalışmaz.
1. `flutter emulators --launch apple_ios_simulator`
2. `cd app && flutter run` (Hata alırsan Rosetta ayarlarını kontrol et).

---
⚠️ **Hatırlatma:** Pose Detection (hareket sayma) özellikleri simülatörlerde kamerasız çalışmaz. Tam test için fiziksel cihaz (Android veya iPhone) gereklidir.
