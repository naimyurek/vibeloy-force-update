package com.example.forceupdate;

// ForceUpdate.java - Vibeloy force update client for Android. Copy this file into your app and change
// the package line above to match its folder.
//
// Install: no dependencies. AndroidManifest.xml needs <uses-permission android:name="android.permission.INTERNET" />
// Usage:   @Override protected void onResume() { super.onResume(); ForceUpdate.check(this); }
// Set your manifest URL in DEFAULT_MANIFEST_URL below, or call ForceUpdate.check(this, url).
//
// Fails open: on a network, timeout or parse problem nothing is shown. This code never throws.

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.ref.WeakReference;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicInteger;

public final class ForceUpdate {
    public static final String DEFAULT_MANIFEST_URL = "https://YOUR-SLUG.vibeloy.dev/version.json";

    private static final int TIMEOUT_MS = 5000;
    private static final long LATER_WINDOW_MS = 24L * 60 * 60 * 1000;
    private static final String PREFS_NAME = "vibeloy_force_update";
    private static final String KEY_VERSION = "dismissed_version";
    private static final String KEY_DISMISSED_AT = "dismissed_at";

    private enum Kind { FORCE, SOFT }

    private static final AtomicInteger latestCheck = new AtomicInteger();
    // Main thread only. Weak, so the dialog cannot keep a destroyed Activity alive.
    private static WeakReference<AlertDialog> shownDialog = new WeakReference<>(null);
    private static Kind shownKind;

    private ForceUpdate() {}

    /** Call from Activity.onResume, so returning from the store checks again. */
    public static void check(Activity activity) {
        check(activity, DEFAULT_MANIFEST_URL);
    }

    /** Call from Activity.onResume, so returning from the store checks again. */
    public static void check(Activity activity, String manifestUrl) {
        final int checkId = latestCheck.incrementAndGet();
        final WeakReference<Activity> activityRef = new WeakReference<>(activity);
        final Context appContext = activity.getApplicationContext();
        new Thread(() -> runCheck(checkId, activityRef, appContext, manifestUrl), "vibeloy-force-update").start();
    }

    /**
     * Returns a negative number, zero or a positive number when a is below, equal to or above b.
     * 1.2.3+45 and 1.2.3-debug compare as 1.2.3, 1.2 as 1.2.0, a non-numeric part as 0.
     */
    public static int compareVersions(String a, String b) {
        long[] left = versionParts(a);
        long[] right = versionParts(b);
        int length = Math.max(left.length, right.length);
        for (int i = 0; i < length; i++) {
            long l = i < left.length ? left[i] : 0;
            long r = i < right.length ? right[i] : 0;
            if (l != r) return l < r ? -1 : 1;
        }
        return 0;
    }

    private static long[] versionParts(String version) {
        String core = version.trim().split("[+-]", 2)[0];
        String[] parts = core.split("\\.", -1);
        long[] values = new long[parts.length];
        for (int i = 0; i < parts.length; i++) {
            try {
                values[i] = Long.parseLong(parts[i]);
            } catch (NumberFormatException e) {
                values[i] = 0;
            }
        }
        return values;
    }

    private static void runCheck(int checkId, WeakReference<Activity> activityRef, Context appContext, String manifestUrl) {
        try {
            String current = currentVersion(appContext);
            if (current == null || current.trim().isEmpty()) return;
            Policy policy = fetchPolicy(manifestUrl);
            if (policy == null) return; // A failed check leaves any open dialog as it is.
            Kind kind = decide(appContext, current, policy);

            new Handler(Looper.getMainLooper()).post(() -> {
                if (checkId != latestCheck.get()) return; // A newer check will decide.
                Activity activity = activityRef.get();
                if (activity == null || activity.isFinishing() || activity.isDestroyed()) return;
                try {
                    apply(activity, kind, policy);
                } catch (RuntimeException e) {
                    // Fail open, for example WindowManager.BadTokenException.
                }
            });
        } catch (Exception e) {
            // Fail open.
        }
    }

    @SuppressWarnings("deprecation") // The int overload is the only one below API 33.
    private static String currentVersion(Context context) throws PackageManager.NameNotFoundException {
        PackageManager manager = context.getPackageManager();
        String packageName = context.getPackageName();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return manager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0)).versionName;
        }
        return manager.getPackageInfo(packageName, 0).versionName;
    }

    private static Policy fetchPolicy(String manifestUrl) throws IOException, JSONException {
        HttpURLConnection connection = (HttpURLConnection) new URL(manifestUrl).openConnection();
        try {
            connection.setConnectTimeout(TIMEOUT_MS);
            connection.setReadTimeout(TIMEOUT_MS);
            connection.setRequestProperty("Accept", "application/json");
            if (connection.getResponseCode() != HttpURLConnection.HTTP_OK) return null;

            JSONObject json = new JSONObject(readAll(connection.getInputStream()));
            Object schemaVersion = json.opt("schemaVersion");
            if (!(schemaVersion instanceof Number) || ((Number) schemaVersion).doubleValue() != 1) return null;
            if (json.isNull("android")) return null;
            JSONObject block = json.getJSONObject("android");
            JSONObject message = json.isNull("message") ? null : json.getJSONObject("message");
            return new Policy(
                    optString(block, "minVersion"),
                    optString(block, "latestVersion"),
                    optString(block, "storeUrl"),
                    optString(message, "tr"),
                    optString(message, "en"));
        } finally {
            connection.disconnect();
        }
    }

    private static String readAll(InputStream stream) throws IOException {
        try (InputStream input = stream) {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            return new String(output.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    /**
     * Null or blank gives null. Any other non-string value throws, which counts as a parse error.
     * Avoids JSONObject.optString, which turns a JSON null into the text "null".
     */
    private static String optString(JSONObject object, String key) throws JSONException {
        if (object == null || object.isNull(key)) return null;
        Object value = object.get(key);
        if (!(value instanceof String)) throw new JSONException(key + " must be a string");
        String trimmed = ((String) value).trim();
        return trimmed.isEmpty() ? null : trimmed;
    }

    private static Kind decide(Context context, String current, Policy policy) {
        if (policy.minVersion != null && compareVersions(current, policy.minVersion) < 0) return Kind.FORCE;
        if (policy.latestVersion != null && compareVersions(current, policy.latestVersion) < 0) {
            return isDismissed(context, policy.latestVersion) ? null : Kind.SOFT;
        }
        return null;
    }

    private static boolean isDismissed(Context context, String latest) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        if (!latest.equals(prefs.getString(KEY_VERSION, null))) return false;
        long age = System.currentTimeMillis() - prefs.getLong(KEY_DISMISSED_AT, 0);
        return age >= 0 && age < LATER_WINDOW_MS;
    }

    private static void saveDismissal(Context context, String latest) {
        if (latest == null) return;
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_VERSION, latest)
                .putLong(KEY_DISMISSED_AT, System.currentTimeMillis())
                .apply();
    }

    private static void apply(Activity activity, Kind kind, Policy policy) {
        AlertDialog shown = shownDialog.get();
        if (shown != null && shown.isShowing()) {
            // Already on screen: never stack a second dialog.
            if (shown.getOwnerActivity() == activity && shownKind == kind) return;
            try {
                shown.dismiss();
            } catch (IllegalArgumentException e) {
                // Its Activity is gone (rotation, for example), and its window went with it.
            }
        }
        shownDialog.clear();
        shownKind = null;
        if (kind != null) show(activity, kind, policy);
    }

    private static void show(Activity activity, Kind kind, Policy policy) {
        boolean force = kind == Kind.FORCE;
        boolean turkish = Locale.getDefault().getLanguage().startsWith("tr");

        String title = force
                ? (turkish ? "Güncelleme gerekli" : "Update required")
                : (turkish ? "Yeni sürüm var" : "New version available");
        String defaultBody = force
                ? (turkish ? "Devam etmek için uygulamayı güncellemeniz gerekiyor." : "Please update the app to continue.")
                : (turkish ? "Uygulamanın yeni bir sürümü hazır." : "A new version of the app is available.");
        String body = turkish ? policy.messageTr : policy.messageEn;
        if (body == null) body = turkish ? policy.messageEn : policy.messageTr;
        if (body == null) body = defaultBody;

        AlertDialog.Builder builder = new AlertDialog.Builder(activity)
                .setTitle(title)
                .setMessage(body)
                .setPositiveButton(turkish ? "Güncelle" : "Update", null); // Click handled in the show listener.
        if (!force) {
            builder.setNegativeButton(turkish ? "Sonra" : "Later",
                    (dialog, which) -> saveDismissal(activity, policy.latestVersion));
        }
        AlertDialog dialog = builder.create();
        dialog.setCancelable(!force);
        dialog.setCanceledOnTouchOutside(false);
        if (!force) {
            // The back button on the soft dialog counts as "Later".
            dialog.setOnCancelListener(d -> saveDismissal(activity, policy.latestVersion));
        }
        // A listener set on the builder would always close the dialog. Setting it here keeps the force
        // dialog open while the store is on screen.
        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            if (!force) dialog.dismiss();
            openStore(activity, policy.storeUrl);
        }));
        dialog.show();
        shownDialog = new WeakReference<>(dialog);
        shownKind = kind;
    }

    private static void openStore(Activity activity, String storeUrl) {
        String packageName = activity.getPackageName();
        String[] urls = {
                storeUrl,
                "market://details?id=" + packageName,
                "https://play.google.com/store/apps/details?id=" + packageName,
        };
        for (String url : urls) {
            if (url == null) continue;
            try {
                activity.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
                return;
            } catch (ActivityNotFoundException | SecurityException e) {
                // Try the next URL.
            }
        }
    }

    private static final class Policy {
        final String minVersion;
        final String latestVersion;
        final String storeUrl;
        final String messageTr;
        final String messageEn;

        Policy(String minVersion, String latestVersion, String storeUrl, String messageTr, String messageEn) {
            this.minVersion = minVersion;
            this.latestVersion = latestVersion;
            this.storeUrl = storeUrl;
            this.messageTr = messageTr;
            this.messageEn = messageEn;
        }
    }
}
