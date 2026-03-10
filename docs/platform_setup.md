# Настройка платформ

## Android

После `flutter create .` открой файл:

```text
android/app/src/main/AndroidManifest.xml
```

Убедись, что там есть разрешения:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

Внутри `<application>` добавь:

```xml
<uses-library android:name="org.apache.http.legacy" android:required="false" />
```

Если тестируешь по `ws://`, а не `wss://`, для Android 9+ может понадобиться разрешить cleartext traffic:

```xml
<application
    android:usesCleartextTraffic="true"
    ... >
```

---

## iOS

Открой:

```text
ios/Runner/Info.plist
```

Добавь:

```xml
<key>NSCameraUsageDescription</key>
<string>Приложению нужен доступ к камере для видеозвонков.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Приложению нужен доступ к микрофону для голосовой связи.</string>
```

Если локально тестируешь без TLS, настрой ATS под dev-окружение.

---

## macOS

Открой:

```text
macos/Runner/DebugProfile.entitlements
macos/Runner/Release.entitlements
```

И добавь:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.device.camera</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
```

---

## Windows / Linux

Обычно достаточно прав пользователя и сетевого доступа. Для production стоит проверить:
- firewall
- доступ к устройствам камеры/микрофона
- sandbox-политику упаковки

---

## Важная заметка

Для production обязательно переходи на:
- `wss://` вместо `ws://`
- собственный STUN/TURN
- сертификаты
- нормальную аутентификацию устройств
