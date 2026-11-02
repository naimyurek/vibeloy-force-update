// ForceUpdate.tsx - Vibeloy force update client for React Native. Copy this file into your project.
//
// Install: npx expo install expo-application @react-native-async-storage/async-storage
// Usage:   <ForceUpdateGate><App /></ForceUpdateGate>
//   or:    const update = useForceUpdate(); // same logic, draw your own dialog from update.kind
// Set your manifest URL in DEFAULT_MANIFEST_URL below, or pass manifestUrl as a prop/option.
// Bare React Native without Expo modules: follow the "Bare React Native" note below, then
//   <ForceUpdateGate getCurrentVersion={() => DeviceInfo.getVersion()} androidPackage={DeviceInfo.getBundleId()}>
//
// Fails open: on a network, timeout or parse problem nothing is shown. This code never throws.

import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  AppState,
  I18nManager,
  Linking,
  Modal,
  Platform,
  Pressable,
  Settings,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Application from 'expo-application';

export const DEFAULT_MANIFEST_URL = 'https://YOUR-SLUG.vibeloy.dev/version.json';

// Bare React Native: delete the expo-application import above and make these two return null.
// (Metro resolves imports statically, so a missing package cannot be caught at runtime.)
const defaultCurrentVersion = (): string | null => Application.nativeApplicationVersion;
const defaultAndroidPackage = (): string | null => Application.applicationId;

const TIMEOUT_MS = 5000;
const LATER_WINDOW_MS = 24 * 60 * 60 * 1000;
const DISMISSED_KEY = 'vibeloy_force_update_dismissed';

export type ForceUpdateKind = 'force' | 'soft';

export interface ForceUpdateOptions {
  /** Defaults to DEFAULT_MANIFEST_URL. */
  manifestUrl?: string;
  /** Defaults to expo-application's nativeApplicationVersion. Bare RN: () => DeviceInfo.getVersion(). */
  getCurrentVersion?: () => string | null | undefined | Promise<string | null | undefined>;
  /** Used for the Play Store fallback when storeUrl is null. Defaults to expo-application's applicationId. */
  androidPackage?: string;
}

export interface ForceUpdateState {
  /** The dialog to show now, or null for none. */
  kind: ForceUpdateKind | null;
  title: string;
  message: string;
  updateLabel: string;
  laterLabel: string;
  /** False when there is no store link to open (iOS with a null storeUrl): hide the Update button. */
  canOpenStore: boolean;
  /** Opens the store. Closes a soft dialog, leaves a force dialog open. */
  openStore: () => void;
  /** Closes a soft dialog and silences it for 24 h, for this latestVersion only. */
  later: () => void;
  /** Runs a check now. Mount and every return to the foreground already do this. */
  check: () => Promise<void>;
}

interface Policy {
  minVersion: string | null;
  latestVersion: string | null;
  storeUrl: string | null;
  messageTr: string | null;
  messageEn: string | null;
}

/** Returns a negative number, zero or a positive number when a is below, equal to or above b. */
export function compareVersions(a: string, b: string): number {
  const left = versionParts(a);
  const right = versionParts(b);
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i++) {
    const l = left[i] ?? 0;
    const r = right[i] ?? 0;
    if (l !== r) return l < r ? -1 : 1;
  }
  return 0;
}

function versionParts(version: string): number[] {
  const core = version.trim().split(/[+-]/)[0] ?? '';
  return core.split('.').map((part) => (/^\d+$/.test(part) ? parseInt(part, 10) : 0));
}

/** Null or blank gives null. Any other non-string value throws, which fetchPolicy treats as a parse error. */
function optString(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== 'string') throw new Error('expected a string');
  return value.trim() || null;
}

async function fetchPolicy(url: string): Promise<Policy | null> {
  if (Platform.OS !== 'ios' && Platform.OS !== 'android') return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: { Accept: 'application/json' },
    });
    if (response.status !== 200) return null;
    const json = await response.json();
    if (json?.schemaVersion !== 1) return null;
    const block = json[Platform.OS];
    if (block === null || typeof block !== 'object') return null;
    const message = json.message ?? {};
    if (typeof message !== 'object') return null;
    return {
      minVersion: optString(block.minVersion),
      latestVersion: optString(block.latestVersion),
      storeUrl: optString(block.storeUrl),
      messageTr: optString(message.tr),
      messageEn: optString(message.en),
    };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function isDismissed(latest: string): Promise<boolean> {
  try {
    const raw = await AsyncStorage.getItem(DISMISSED_KEY);
    if (raw === null) return false;
    const saved = JSON.parse(raw);
    if (saved?.version !== latest) return false;
    const age = Date.now() - Number(saved.dismissedAt);
    return age >= 0 && age < LATER_WINDOW_MS;
  } catch {
    return false;
  }
}

async function decide(current: string, policy: Policy): Promise<ForceUpdateKind | null> {
  const { minVersion, latestVersion } = policy;
  if (minVersion && compareVersions(current, minVersion) < 0) return 'force';
  if (latestVersion && compareVersions(current, latestVersion) < 0) {
    return (await isDismissed(latestVersion)) ? null : 'soft';
  }
  return null;
}

function isTurkishDevice(): boolean {
  try {
    // AppleLanguages is the device order. Intl on iOS can follow the app's own localizations instead.
    const languages: unknown = Platform.OS === 'ios' ? Settings.get('AppleLanguages') : null;
    const locale =
      (Array.isArray(languages) ? languages[0] : null) ??
      I18nManager.getConstants().localeIdentifier ??
      Intl.DateTimeFormat().resolvedOptions().locale;
    return String(locale).toLowerCase().startsWith('tr');
  } catch {
    return false;
  }
}

function storeUrls(storeUrl: string | null, androidPackage: string | null | undefined): string[] {
  const urls = storeUrl ? [storeUrl] : [];
  if (Platform.OS === 'android' && androidPackage) {
    urls.push(
      `market://details?id=${androidPackage}`,
      `https://play.google.com/store/apps/details?id=${androidPackage}`,
    );
  }
  return urls;
}

async function openFirst(urls: string[]): Promise<void> {
  for (const url of urls) {
    try {
      // No canOpenURL here: it needs extra manifest entries, and openURL rejects if nothing handles the URL.
      await Linking.openURL(url);
      return;
    } catch {
      // Try the next URL.
    }
  }
}

const STRINGS = {
  tr: {
    forceTitle: 'Güncelleme gerekli',
    forceBody: 'Devam etmek için uygulamayı güncellemeniz gerekiyor.',
    softTitle: 'Yeni sürüm var',
    softBody: 'Uygulamanın yeni bir sürümü hazır.',
    update: 'Güncelle',
    later: 'Sonra',
  },
  en: {
    forceTitle: 'Update required',
    forceBody: 'Please update the app to continue.',
    softTitle: 'New version available',
    softBody: 'A new version of the app is available.',
    update: 'Update',
    later: 'Later',
  },
};

function textFor(kind: ForceUpdateKind, policy: Policy) {
  const turkish = isTurkishDevice();
  const strings = turkish ? STRINGS.tr : STRINGS.en;
  const force = kind === 'force';
  return {
    title: force ? strings.forceTitle : strings.softTitle,
    message:
      (turkish ? policy.messageTr : policy.messageEn) ??
      (turkish ? policy.messageEn : policy.messageTr) ??
      (force ? strings.forceBody : strings.softBody),
    updateLabel: strings.update,
    laterLabel: strings.later,
  };
}

/** Checks on mount and whenever the app returns to the foreground. A failed check leaves the state as it is. */
export function useForceUpdate(options: ForceUpdateOptions = {}): ForceUpdateState {
  const latestOptions = useRef(options);
  latestOptions.current = options;

  const [prompt, setPrompt] = useState<{ kind: ForceUpdateKind; policy: Policy } | null>(null);
  const checking = useRef(false);
  const mounted = useRef(true);

  const check = useCallback(async () => {
    if (checking.current) return;
    checking.current = true;
    try {
      const { manifestUrl, getCurrentVersion } = latestOptions.current;
      const current = await (getCurrentVersion ?? defaultCurrentVersion)();
      if (!current || !current.trim()) return;
      const policy = await fetchPolicy(manifestUrl ?? DEFAULT_MANIFEST_URL);
      if (!policy) return;
      const kind = await decide(current, policy);
      if (mounted.current) setPrompt(kind ? { kind, policy } : null);
    } catch {
      // Fail open.
    } finally {
      checking.current = false;
    }
  }, []);

  useEffect(() => {
    mounted.current = true;
    void check();
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') void check();
    });
    return () => {
      mounted.current = false;
      subscription.remove();
    };
  }, [check]);

  const urls = prompt
    ? storeUrls(prompt.policy.storeUrl, options.androidPackage ?? defaultAndroidPackage())
    : [];
  const kind = prompt?.kind ?? null;

  const openStore = () => {
    if (kind === 'soft') setPrompt(null);
    void openFirst(urls);
  };

  const later = () => {
    if (kind !== 'soft') return;
    const version = prompt?.policy.latestVersion;
    setPrompt(null);
    if (version) {
      AsyncStorage.setItem(DISMISSED_KEY, JSON.stringify({ version, dismissedAt: Date.now() })).catch(
        () => undefined,
      );
    }
  };

  const text = prompt
    ? textFor(prompt.kind, prompt.policy)
    : { title: '', message: '', updateLabel: '', laterLabel: '' };

  return { kind, ...text, canOpenStore: urls.length > 0, openStore, later, check };
}

export interface ForceUpdateGateProps extends ForceUpdateOptions {
  children?: React.ReactNode;
}

/** Renders children and, when needed, the force or soft dialog above them. */
export function ForceUpdateGate({ children, ...options }: ForceUpdateGateProps) {
  const update = useForceUpdate(options);
  const force = update.kind === 'force';

  return (
    <>
      {children}
      <Modal
        visible={update.kind !== null}
        transparent
        animationType="fade"
        statusBarTranslucent
        // Android back button: ignored on the force dialog, counts as "Later" on the soft dialog.
        onRequestClose={force ? () => undefined : update.later}
      >
        <View style={styles.backdrop}>
          <View style={styles.card} accessibilityViewIsModal>
            <Text style={styles.title} accessibilityRole="header">
              {update.title}
            </Text>
            <Text style={styles.message}>{update.message}</Text>
            <View style={styles.actions}>
              {!force && (
                <Pressable accessibilityRole="button" onPress={update.later} style={styles.button}>
                  <Text style={styles.buttonText}>{update.laterLabel}</Text>
                </Pressable>
              )}
              {update.canOpenStore && (
                <Pressable accessibilityRole="button" onPress={update.openStore} style={styles.button}>
                  <Text style={[styles.buttonText, styles.primaryText]}>{update.updateLabel}</Text>
                </Pressable>
              )}
            </View>
          </View>
        </View>
      </Modal>
    </>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
  },
  card: {
    width: '100%',
    maxWidth: 360,
    padding: 20,
    borderRadius: 14,
    backgroundColor: '#ffffff',
  },
  title: { fontSize: 18, fontWeight: '600', color: '#111111', marginBottom: 8 },
  message: { fontSize: 15, lineHeight: 21, color: '#333333' },
  actions: { flexDirection: 'row', justifyContent: 'flex-end', marginTop: 16 },
  button: { paddingVertical: 10, paddingHorizontal: 14, minHeight: 44, justifyContent: 'center' },
  buttonText: { fontSize: 15, color: '#555555' },
  primaryText: { color: '#0a66d8', fontWeight: '600' },
});
