# Vibeloy force update clients

Single-file, copy-paste clients that make your mobile app respect a version policy. Each app hosted on [Vibeloy](https://vibeloy.dev) publishes its policy as public JSON at `https://<slug>.vibeloy.dev/version.json`. The client reads it on launch and every time the app returns to the foreground, then shows one of two dialogs:

- **Force update:** blocks the app until the user updates.
- **Soft update:** suggests the update. "Later" silences it for 24 hours.

There are no pub.dev, npm, SPM or Maven packages. Copy one file into your project, and you own it.

| Platform | File | Requires |
|---|---|---|
| Flutter | [`flutter/force_update.dart`](flutter/force_update.dart) | `http`, `package_info_plus`, `shared_preferences`, `url_launcher` |
| React Native | [`react-native/ForceUpdate.tsx`](react-native/ForceUpdate.tsx) | `expo-application`, `@react-native-async-storage/async-storage` |
| iOS (Swift) | [`ios/ForceUpdate.swift`](ios/ForceUpdate.swift) | iOS 15+, no dependencies |
| Android (Kotlin) | [`android/kotlin/ForceUpdate.kt`](android/kotlin/ForceUpdate.kt) | No dependencies, compileSdk 33+ |
| Android (Java) | [`android/java/ForceUpdate.java`](android/java/ForceUpdate.java) | No dependencies, compileSdk 33+ |

**Using the Vibeloy MCP server?** The `get_force_update_client` tool returns the file for your platform with your slug's URL already filled in. Otherwise, replace the placeholder URL at the top of the file, or pass your URL as a parameter.

## Manifest

```json
{
  "schemaVersion": 1,
  "app": { "slug": "butcep", "name": "Bütcep" },
  "ios": {
    "minVersion": "1.2.0",
    "latestVersion": "1.4.0",
    "storeUrl": "https://apps.apple.com/app/id123456789"
  },
  "android": {
    "minVersion": "1.2.0",
    "latestVersion": "1.4.0",
    "storeUrl": "https://play.google.com/store/apps/details?id=com.butcep"
  },
  "message": { "tr": "Yeni sürüm hazır.", "en": "A new version is ready." },
  "updatedAt": "2026-11-01T10:00:00.000Z"
}
```

`ios`, `android` and `message` can be null. So can `minVersion`, `latestVersion` and `storeUrl` inside a platform block, and `tr` and `en` inside `message`. Clients ignore unknown keys. The JSON Schema is in [`schema/version.schema.json`](schema/version.schema.json), and this sample is in [`examples/version.json`](examples/version.json).

## Decision rule

| Condition | Result |
|---|---|
| `current < minVersion` | Force dialog |
| Otherwise, `current < latestVersion` | Soft dialog |
| Otherwise | Nothing |

Versions are compared part by part. Anything from the first `+` or `-` is dropped, so `1.2.3+45` and `1.2.3-debug` both compare as `1.2.3`. Missing parts count as zero, so `1.2` equals `1.2.0`. A non-numeric part counts as 0.

## Install and integrate

Clients check again when the user returns to the app, so someone who comes back from the store without updating still sees the force dialog. A second dialog never stacks on the first.

### Flutter

```bash
flutter pub add http package_info_plus shared_preferences url_launcher
```

Copy `flutter/force_update.dart` into `lib/`, then wrap your home screen. The gate must sit below `MaterialApp`, because the dialogs need its `Navigator`.

```dart
import 'force_update.dart';

MaterialApp(
  home: ForceUpdateGate(child: HomePage()),
);
```

For a single check with no re-check on resume, call `ForceUpdate.check(context)` instead.

On Android, release builds need the `INTERNET` permission in `android/app/src/main/AndroidManifest.xml`. Flutter's template only adds it for debug and profile. Without it the check fails silently and no dialog appears.

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

To run the example, use `flutter create . --platforms=android,ios` inside `flutter/example`, then `flutter run`.

### React Native

```bash
npx expo install expo-application @react-native-async-storage/async-storage
```

Copy `react-native/ForceUpdate.tsx` into your project, then wrap your app.

```tsx
import { ForceUpdateGate } from './ForceUpdate';

export default function Root() {
  return (
    <ForceUpdateGate>
      <App />
    </ForceUpdateGate>
  );
}
```

To draw your own dialog, call `useForceUpdate()`. It runs the same logic and returns `kind`, the text, `canOpenStore`, `openStore`, `later` and `check`.

**Bare React Native without Expo modules:** Metro resolves imports at build time, so the `expo-application` import has to go. Delete that import, make `defaultCurrentVersion` and `defaultAndroidPackage` return `null`, then pass the values yourself:

```tsx
import DeviceInfo from 'react-native-device-info';

<ForceUpdateGate
  getCurrentVersion={() => DeviceInfo.getVersion()}
  androidPackage={DeviceInfo.getBundleId()}
>
  <App />
</ForceUpdateGate>
```

### iOS (Swift)

Copy `ios/ForceUpdate.swift` into your Xcode target. There is nothing to install.

SwiftUI:

```swift
WindowGroup {
    ContentView().forceUpdate()
}
```

UIKit:

```swift
override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    ForceUpdate.check(from: self)
}
```

### Android (Kotlin)

Copy `android/kotlin/ForceUpdate.kt` into your app and change its `package` line to match. Add the permission if you don't have it already, then call the client from `onResume`.

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

```kotlin
override fun onResume() {
    super.onResume()
    ForceUpdate.check(this)
}
```

### Android (Java)

Copy `android/java/ForceUpdate.java` into your app and change its `package` line to match. Add the same permission, then call the client from `onResume`.

```java
@Override
protected void onResume() {
    super.onResume();
    ForceUpdate.check(this);
}
```

## Behavior

**Fail open.** A client never throws into your app and never blocks it because of a problem on its own side. A non-200 response, a timeout (5 seconds), invalid JSON, a `schemaVersion` other than 1 or a missing platform block all mean no dialog, and the app opens normally. If a check fails while a dialog is already on screen, that dialog stays.

**Force dialog.** One button, "Güncelle" or "Update". It opens the store and the dialog stays. Back and outside taps do nothing. If a later check finds the app no longer needs the update, the dialog closes.

**Soft dialog.** "Güncelle" or "Update", plus "Sonra" or "Later". "Later" stores the `latestVersion` with a timestamp and stays quiet for 24 hours, for that `latestVersion` only, so a newer release prompts again. On Android, the back button counts as "Later".

**Language.** Devices set to Turkish (`tr*`) get Turkish text, and all others get English. `message.tr` or `message.en` replaces the body text when present. If the device language's message is empty, the other one is used.

**Null `storeUrl`.** Android tries `market://details?id=<package>`, then `https://play.google.com/store/apps/details?id=<package>`. iOS hides the Update button and keeps the text.

## License

[MIT](LICENSE)

## Türkçe

Bu depo, mobil uygulamanızın Vibeloy üzerindeki sürüm politikasına uymasını sağlayan tek dosyalık istemciler içerir. Politika `https://<slug>.vibeloy.dev/version.json` adresinde herkese açık JSON olarak yayınlanır. İstemci bu dosyayı uygulama açıldığında ve uygulama her öne geldiğinde okur.

- **Kural:** `current < minVersion` ise zorunlu güncelleme penceresi açılır. Değilse ve `current < latestVersion` ise "Sonra" seçeneği olan bir pencere açılır. "Sonra" o `latestVersion` için 24 saat susturur; daha yeni bir sürüm yayınlanırsa pencere yeniden açılır.
- **Kurulum:** Platformunuzun dosyasını projenize kopyalayın ve yukarıdaki 3-5 satırlık entegrasyonu ekleyin. Vibeloy MCP aracı `get_force_update_client`, dosyayı kendi slug adresiniz yazılı olarak döndürür.
- **Hata durumu:** Ağ hatası, zaman aşımı (5 sn), bozuk JSON, farklı `schemaVersion` ya da eksik platform bloğu olursa hiçbir pencere açılmaz ve uygulama normal şekilde çalışır.

Lisans: MIT.
