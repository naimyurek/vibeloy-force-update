// force_update.dart - Vibeloy force update client for Flutter. Copy this file into lib/.
//
// Install: flutter pub add http package_info_plus shared_preferences url_launcher
// Usage:   MaterialApp(home: ForceUpdateGate(child: HomePage()))    // below MaterialApp
//   or:    ForceUpdate.check(context)                               // one check, no re-check on resume
// Set your manifest URL in ForceUpdate.defaultManifestUrl, or pass manifestUrl: to either one.
// Android release builds need <uses-permission android:name="android.permission.INTERNET" /> in the
// main AndroidManifest.xml. Flutter's template only adds it for debug and profile.
//
// Fails open: on a network, timeout or parse problem nothing is shown. This code never throws.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Wraps [child], checks once on launch and again whenever the app returns to the foreground.
/// Place it below MaterialApp, for example as `home:`.
class ForceUpdateGate extends StatefulWidget {
  const ForceUpdateGate({
    super.key,
    required this.child,
    this.manifestUrl = ForceUpdate.defaultManifestUrl,
  });

  final Widget child;
  final String manifestUrl;

  @override
  State<ForceUpdateGate> createState() => _ForceUpdateGateState();
}

class _ForceUpdateGateState extends State<ForceUpdateGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  void _check() {
    if (mounted) ForceUpdate.check(context, manifestUrl: widget.manifestUrl);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class ForceUpdate {
  ForceUpdate._();

  static const String defaultManifestUrl = 'https://YOUR-SLUG.vibeloy.dev/version.json';

  static const Duration _timeout = Duration(seconds: 5);
  static const Duration _laterWindow = Duration(hours: 24);
  static const String _dismissedKey = 'vibeloy_force_update_dismissed';

  static bool _checking = false;
  static _Prompt? _prompt;

  /// Fetches the manifest and shows the force or soft dialog if one is needed.
  /// [context] must be below a MaterialApp. A failed check leaves any open dialog as it is.
  static Future<void> check(
    BuildContext context, {
    String manifestUrl = defaultManifestUrl,
  }) async {
    if (_checking || kIsWeb) return;
    final block = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : null);
    if (block == null) return;

    _checking = true;
    try {
      final info = await PackageInfo.fromPlatform();
      final policy = await _fetchPolicy(manifestUrl, block);
      if (policy == null || info.version.trim().isEmpty) return;
      final kind = await _decide(info.version, policy);
      if (context.mounted) _apply(context, kind, policy, info.packageName);
    } catch (error) {
      debugPrint('ForceUpdate: $error');
    } finally {
      _checking = false;
    }
  }

  /// Returns a negative number, zero or a positive number when [a] is below, equal to or above [b].
  /// `1.2.3+45` and `1.2.3-debug` compare as `1.2.3`, `1.2` as `1.2.0`, a non-numeric part as 0.
  static int compareVersions(String a, String b) {
    final left = _versionParts(a);
    final right = _versionParts(b);
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final l = i < left.length ? left[i] : 0;
      final r = i < right.length ? right[i] : 0;
      if (l != r) return l < r ? -1 : 1;
    }
    return 0;
  }

  static List<int> _versionParts(String version) {
    final core = version.trim().split(RegExp(r'[+-]')).first;
    final digits = RegExp(r'^\d+$');
    return core
        .split('.')
        .map((part) => digits.hasMatch(part) ? (int.tryParse(part) ?? 0) : 0)
        .toList();
  }

  static Future<_Policy?> _fetchPolicy(String url, String block) async {
    final client = http.Client();
    try {
      final response = await client
          .get(Uri.parse(url), headers: const {'Accept': 'application/json'})
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      // Decode the bytes directly: http falls back to latin1 when the charset header is absent.
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is! Map || json['schemaVersion'] != 1) return null;
      final platform = json[block];
      if (platform is! Map) return null;
      final message = json['message'];
      if (message != null && message is! Map) return null;
      return _Policy(
        minVersion: _string(platform['minVersion']),
        latestVersion: _string(platform['latestVersion']),
        storeUrl: _string(platform['storeUrl']),
        messageTr: _string(message?['tr']),
        messageEn: _string(message?['en']),
      );
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Null or blank gives null. Any other non-string value throws, which `_fetchPolicy` treats as a
  /// parse error.
  static String? _string(Object? value) {
    if (value == null) return null;
    if (value is! String) throw const FormatException('expected a string');
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Future<_Kind?> _decide(String current, _Policy policy) async {
    final min = policy.minVersion;
    if (min != null && compareVersions(current, min) < 0) return _Kind.force;
    final latest = policy.latestVersion;
    if (latest != null && compareVersions(current, latest) < 0) {
      return await _isDismissed(latest) ? null : _Kind.soft;
    }
    return null;
  }

  static Future<bool> _isDismissed(String latest) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_dismissedKey);
      if (raw == null) return false;
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      if (saved['version'] != latest) return false;
      final age = DateTime.now().millisecondsSinceEpoch - (saved['dismissedAt'] as num).toInt();
      return age >= 0 && age < _laterWindow.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _saveDismissal(String? latest) async {
    if (latest == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _dismissedKey,
        jsonEncode({'version': latest, 'dismissedAt': DateTime.now().millisecondsSinceEpoch}),
      );
    } catch (error) {
      debugPrint('ForceUpdate: $error');
    }
  }

  static void _apply(BuildContext context, _Kind? kind, _Policy policy, String packageName) {
    final shown = _prompt;
    final showing = shown != null && shown.route.isActive;
    if (showing && shown.kind == kind) return; // Already on screen: never stack a second dialog.
    _prompt = null; // Clear first, so closing the old dialog here does not count as "Later".
    if (showing) shown.route.navigator?.removeRoute(shown.route);
    if (kind != null) _show(context, kind, policy, packageName);
  }

  static void _show(BuildContext context, _Kind kind, _Policy policy, String packageName) {
    final force = kind == _Kind.force;
    final turkish = WidgetsBinding.instance.platformDispatcher.locale.languageCode
        .toLowerCase()
        .startsWith('tr');
    final text = _Strings(turkish, force);
    final body = (turkish ? policy.messageTr : policy.messageEn) ??
        (turkish ? policy.messageEn : policy.messageTr) ??
        text.body;
    final storeUrls = _storeUrls(policy.storeUrl, packageName);

    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: !force,
        child: AlertDialog(
          title: Text(text.title),
          content: Text(body),
          actions: [
            if (!force)
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(text.later),
              ),
            if (storeUrls.isNotEmpty)
              TextButton(
                onPressed: () {
                  // The force dialog stays open behind the store, so there is no pop here.
                  if (!force) Navigator.of(dialogContext).pop(true);
                  _openStore(storeUrls);
                },
                child: Text(text.update),
              ),
          ],
        ),
      ),
    );

    _prompt = _Prompt(kind, route);
    navigator.push(route).then((updateTapped) {
      if (!identical(_prompt?.route, route)) return;
      _prompt = null;
      // "Later" and the Android back button both land here with updateTapped != true.
      if (!force && updateTapped != true) _saveDismissal(policy.latestVersion);
    });
  }

  static List<String> _storeUrls(String? storeUrl, String packageName) {
    return [
      if (storeUrl != null) storeUrl,
      if (Platform.isAndroid && packageName.isNotEmpty) ...[
        'market://details?id=$packageName',
        'https://play.google.com/store/apps/details?id=$packageName',
      ],
    ];
  }

  static Future<void> _openStore(List<String> urls) async {
    for (final url in urls) {
      try {
        // No canLaunchUrl here: it needs a <queries> entry on Android 11+.
        final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        if (opened) return;
      } catch (error) {
        debugPrint('ForceUpdate: $error');
      }
    }
  }
}

enum _Kind { force, soft }

class _Prompt {
  const _Prompt(this.kind, this.route);

  final _Kind kind;
  final Route<bool> route;
}

class _Policy {
  const _Policy({
    this.minVersion,
    this.latestVersion,
    this.storeUrl,
    this.messageTr,
    this.messageEn,
  });

  final String? minVersion;
  final String? latestVersion;
  final String? storeUrl;
  final String? messageTr;
  final String? messageEn;
}

class _Strings {
  _Strings(bool turkish, bool force)
      : title = force
            ? (turkish ? 'Güncelleme gerekli' : 'Update required')
            : (turkish ? 'Yeni sürüm var' : 'New version available'),
        body = force
            ? (turkish
                ? 'Devam etmek için uygulamayı güncellemeniz gerekiyor.'
                : 'Please update the app to continue.')
            : (turkish
                ? 'Uygulamanın yeni bir sürümü hazır.'
                : 'A new version of the app is available.'),
        update = turkish ? 'Güncelle' : 'Update',
        later = turkish ? 'Sonra' : 'Later';

  final String title;
  final String body;
  final String update;
  final String later;
}
