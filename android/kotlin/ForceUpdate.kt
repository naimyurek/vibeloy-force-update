package com.example.forceupdate

// ForceUpdate.kt - Vibeloy force update client for Android. Copy this file into your app and change
// the package line above to match its folder.
//
// Install: no dependencies. AndroidManifest.xml needs <uses-permission android:name="android.permission.INTERNET" />
// Usage:   override fun onResume() { super.onResume(); ForceUpdate.check(this) }
// Set your manifest URL in DEFAULT_MANIFEST_URL below, or call ForceUpdate.check(this, url).
//
// Fails open: on a network, timeout or parse problem nothing is shown. This code never throws.

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONException
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

object ForceUpdate {
    const val DEFAULT_MANIFEST_URL = "https://YOUR-SLUG.vibeloy.dev/version.json"

    private const val TIMEOUT_MS = 5000
    private const val LATER_WINDOW_MS = 24L * 60 * 60 * 1000
    private const val PREFS_NAME = "vibeloy_force_update"
    private const val KEY_VERSION = "dismissed_version"
    private const val KEY_DISMISSED_AT = "dismissed_at"

    private enum class Kind { FORCE, SOFT }

    private class Policy(
        val minVersion: String?,
        val latestVersion: String?,
        val storeUrl: String?,
        val messageTr: String?,
        val messageEn: String?,
    )

    private val latestCheck = AtomicInteger()

    // Main thread only. Weak, so the dialog cannot keep a destroyed Activity alive.
    private var shownDialog = WeakReference<AlertDialog>(null)
    private var shownKind: Kind? = null

    /** Call from Activity.onResume, so returning from the store checks again. */
    @JvmStatic
    @JvmOverloads
    fun check(activity: Activity, manifestUrl: String = DEFAULT_MANIFEST_URL) {
        val checkId = latestCheck.incrementAndGet()
        val activityRef = WeakReference(activity)
        val appContext = activity.applicationContext
        Thread({ runCheck(checkId, activityRef, appContext, manifestUrl) }, "vibeloy-force-update").start()
    }

    /**
     * Returns a negative number, zero or a positive number when a is below, equal to or above b.
     * 1.2.3+45 and 1.2.3-debug compare as 1.2.3, 1.2 as 1.2.0, a non-numeric part as 0.
     */
    @JvmStatic
    fun compareVersions(a: String, b: String): Int {
        val left = versionParts(a)
        val right = versionParts(b)
        for (i in 0 until maxOf(left.size, right.size)) {
            val l = left.getOrElse(i) { 0L }
            val r = right.getOrElse(i) { 0L }
            if (l != r) return if (l < r) -1 else 1
        }
        return 0
    }

    private fun versionParts(version: String): List<Long> =
        version.trim()
            .split('+', '-', limit = 2)[0]
            .split('.')
            .map { it.toLongOrNull() ?: 0L }

    private fun runCheck(
        checkId: Int,
        activityRef: WeakReference<Activity>,
        appContext: Context,
        manifestUrl: String,
    ) {
        try {
            val current = currentVersion(appContext)
            if (current.isNullOrBlank()) return
            val policy = fetchPolicy(manifestUrl) ?: return // A failed check leaves any open dialog as it is.
            val kind = decide(appContext, current, policy)

            Handler(Looper.getMainLooper()).post {
                if (checkId != latestCheck.get()) return@post // A newer check will decide.
                val activity = activityRef.get()
                if (activity == null || activity.isFinishing || activity.isDestroyed) return@post
                try {
                    apply(activity, kind, policy)
                } catch (e: RuntimeException) {
                    // Fail open, for example WindowManager.BadTokenException.
                }
            }
        } catch (e: Exception) {
            // Fail open.
        }
    }

    @Suppress("DEPRECATION") // The int overload is the only one below API 33.
    private fun currentVersion(context: Context): String? {
        val manager = context.packageManager
        val packageName = context.packageName
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0L)).versionName
        } else {
            manager.getPackageInfo(packageName, 0).versionName
        }
    }

    private fun fetchPolicy(manifestUrl: String): Policy? {
        val connection = URL(manifestUrl).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.setRequestProperty("Accept", "application/json")
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return null

            val text = connection.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
            val json = JSONObject(text)
            val schemaVersion = json.opt("schemaVersion") as? Number ?: return null
            if (schemaVersion.toDouble() != 1.0) return null
            if (json.isNull("android")) return null
            val block = json.getJSONObject("android")
            val message = if (json.isNull("message")) null else json.getJSONObject("message")
            return Policy(
                minVersion = block.optStringOrNull("minVersion"),
                latestVersion = block.optStringOrNull("latestVersion"),
                storeUrl = block.optStringOrNull("storeUrl"),
                messageTr = message?.optStringOrNull("tr"),
                messageEn = message?.optStringOrNull("en"),
            )
        } finally {
            connection.disconnect()
        }
    }

    /**
     * Null or blank gives null. Any other non-string value throws, which counts as a parse error.
     * Avoids JSONObject.optString, which turns a JSON null into the text "null".
     */
    private fun JSONObject.optStringOrNull(key: String): String? {
        if (isNull(key)) return null
        val value = get(key) as? String ?: throw JSONException("$key must be a string")
        return value.trim().ifEmpty { null }
    }

    private fun decide(context: Context, current: String, policy: Policy): Kind? {
        val min = policy.minVersion
        if (min != null && compareVersions(current, min) < 0) return Kind.FORCE
        val latest = policy.latestVersion
        if (latest != null && compareVersions(current, latest) < 0) {
            return if (isDismissed(context, latest)) null else Kind.SOFT
        }
        return null
    }

    private fun isDismissed(context: Context, latest: String): Boolean {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_VERSION, null) != latest) return false
        val age = System.currentTimeMillis() - prefs.getLong(KEY_DISMISSED_AT, 0L)
        return age >= 0 && age < LATER_WINDOW_MS
    }

    private fun saveDismissal(context: Context, latest: String?) {
        if (latest == null) return
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_VERSION, latest)
            .putLong(KEY_DISMISSED_AT, System.currentTimeMillis())
            .apply()
    }

    private fun apply(activity: Activity, kind: Kind?, policy: Policy) {
        val shown = shownDialog.get()
        if (shown != null && shown.isShowing) {
            // Already on screen: never stack a second dialog.
            if (shown.ownerActivity === activity && shownKind == kind) return
            try {
                shown.dismiss()
            } catch (e: IllegalArgumentException) {
                // Its Activity is gone (rotation, for example), and its window went with it.
            }
        }
        shownDialog.clear()
        shownKind = null
        if (kind != null) show(activity, kind, policy)
    }

    private fun show(activity: Activity, kind: Kind, policy: Policy) {
        val force = kind == Kind.FORCE
        val turkish = Locale.getDefault().language.startsWith("tr")

        val title = if (force) {
            if (turkish) "Güncelleme gerekli" else "Update required"
        } else {
            if (turkish) "Yeni sürüm var" else "New version available"
        }
        val defaultBody = if (force) {
            if (turkish) "Devam etmek için uygulamayı güncellemeniz gerekiyor." else "Please update the app to continue."
        } else {
            if (turkish) "Uygulamanın yeni bir sürümü hazır." else "A new version of the app is available."
        }
        val body = (if (turkish) policy.messageTr else policy.messageEn)
            ?: (if (turkish) policy.messageEn else policy.messageTr)
            ?: defaultBody

        val builder = AlertDialog.Builder(activity)
            .setTitle(title)
            .setMessage(body)
            .setPositiveButton(if (turkish) "Güncelle" else "Update", null) // Click handled in the show listener.
        if (!force) {
            builder.setNegativeButton(if (turkish) "Sonra" else "Later") { _, _ ->
                saveDismissal(activity, policy.latestVersion)
            }
        }
        val dialog = builder.create()
        dialog.setCancelable(!force)
        dialog.setCanceledOnTouchOutside(false)
        if (!force) {
            // The back button on the soft dialog counts as "Later".
            dialog.setOnCancelListener { saveDismissal(activity, policy.latestVersion) }
        }
        // A listener set on the builder would always close the dialog. Setting it here keeps the force
        // dialog open while the store is on screen.
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (!force) dialog.dismiss()
                openStore(activity, policy.storeUrl)
            }
        }
        dialog.show()
        shownDialog = WeakReference(dialog)
        shownKind = kind
    }

    private fun openStore(activity: Activity, storeUrl: String?) {
        val packageName = activity.packageName
        val urls = listOfNotNull(
            storeUrl,
            "market://details?id=$packageName",
            "https://play.google.com/store/apps/details?id=$packageName",
        )
        for (url in urls) {
            try {
                activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                return
            } catch (e: ActivityNotFoundException) {
                // Try the next URL.
            } catch (e: SecurityException) {
                // Try the next URL.
            }
        }
    }
}
