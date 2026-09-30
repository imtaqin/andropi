package com.imtaqin.andropi

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import android.provider.Settings
import android.speech.RecognizerIntent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * FragmentActivity (not FlutterActivity) because the biometric lock needs it.
 * Besides the agent bridge, this handles what the rest of Android sends us:
 * shares from other apps, widget/tile shortcuts, voice input results.
 */
class MainActivity : FlutterFragmentActivity() {
    companion object {
        const val ACTION_NEW_CHAT = "com.imtaqin.andropi.NEW_CHAT"
        const val ACTION_VOICE = "com.imtaqin.andropi.VOICE"
        private const val VOICE_REQUEST = 4101
        private const val UPDATES_CHANNEL = "updates"
    }

    private var events: EventChannel.EventSink? = null
    private var pendingVoice: MethodChannel.Result? = null

    /** A launch reason Flutter has not picked up yet: a share or a shortcut. */
    private var pendingLaunch: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "andropi/agent/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })

        AgentRuntime.listener = object : AgentRuntime.Listener {
            override fun onStdout(line: String) {
                events?.success(mapOf("kind" to "stdout", "line" to line))
            }

            override fun onStderr(line: String) {
                events?.success(mapOf("kind" to "stderr", "line" to line))
            }

            override fun onExit(code: Int) {
                AgentService.setActive(this@MainActivity, false)
                events?.success(mapOf("kind" to "exit", "code" to code))
            }
        }

        MethodChannel(messenger, "andropi/agent").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        // Extracting assets on first launch takes a moment; keep it off the UI thread.
                        Thread {
                            try {
                                @Suppress("UNCHECKED_CAST")
                                val extra = (call.arguments as? Map<String, String>) ?: emptyMap()
                                // The store key goes to the agent host only, never to shells.
                                AgentRuntime.start(applicationContext, extra + ("ANDROPI_STORE_KEY" to SecureKey.hex(applicationContext)))
                                runOnUiThread { result.success(AgentRuntime.paths(applicationContext)) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("start_failed", e.message, null) }
                            }
                        }.start()
                    }
                    "send" -> {
                        AgentRuntime.send(call.arguments as String)
                        result.success(null)
                    }
                    "stop" -> {
                        AgentRuntime.stop()
                        result.success(null)
                    }
                    "isRunning" -> result.success(AgentRuntime.isRunning)
                    // The toolchain environment, for terminals the app opens.
                    "environment" -> result.success(AgentRuntime.prepareEnvironment(applicationContext))
                    "setBusy" -> {
                        AgentService.setActive(this, call.arguments as Boolean)
                        result.success(null)
                    }
                    // Keeps the process alive for queued runs and schedules.
                    "keepAlive" -> {
                        val on = call.argument<Boolean>("on") == true
                        AgentService.setActive(this, on, call.argument<String>("text") ?: "Background tasks active")
                        result.success(null)
                    }
                    // Shared storage: "All files access" is granted in system settings.
                    "storageAccess" -> result.success(
                        mapOf(
                            "available" to storageAccessDeclared(),
                            "granted" to (storageAccessDeclared() && hasStorageAccess()),
                            "root" to Environment.getExternalStorageDirectory().path,
                        )
                    )
                    "requestStorageAccess" -> {
                        if (Build.VERSION.SDK_INT >= 30) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
                            )
                        } else {
                            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 1)
                        }
                        result.success(null)
                    }
                    "shareFile" -> {
                        val file = File(call.argument<String>("path")!!)
                        val uri = FileProvider.getUriForFile(this, "com.imtaqin.andropi.files", file)
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = mimeOf(file.name)
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(send, file.name))
                        result.success(null)
                    }
                    "saveToDownloads" -> {
                        try {
                            result.success(saveToDownloads(File(call.argument<String>("path")!!)))
                        } catch (e: Exception) {
                            result.error("save_failed", e.message, null)
                        }
                    }
                    "openUrl" -> {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
                        result.success(null)
                    }
                    // Voice input through the system recognizer (no mic permission needed here).
                    "listen" -> {
                        pendingVoice?.error("cancelled", "Another voice request started", null)
                        pendingVoice = result
                        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                            putExtra(RecognizerIntent.EXTRA_PROMPT, "Speak to pi")
                            call.argument<String>("language")?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
                        }
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, VOICE_REQUEST)
                        } catch (e: Exception) {
                            pendingVoice = null
                            result.error("unavailable", "No speech recognizer on this device", null)
                        }
                    }
                    "takeLaunch" -> {
                        result.success(pendingLaunch)
                        pendingLaunch = null
                    }
                    "notify" -> {
                        notify(
                            call.argument<Int>("id") ?: 100,
                            call.argument<String>("title") ?: "AndroPI",
                            call.argument<String>("body") ?: "",
                        )
                        result.success(null)
                    }
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("error", e.message, null)
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VOICE_REQUEST) return
        val text = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
        pendingVoice?.success(text)
        pendingVoice = null
    }

    // -------------------------------------------------------------------------
    // Shares and shortcuts

    private fun handleIntent(intent: Intent?) {
        val launch: Map<String, Any?> = when (intent?.action) {
            ACTION_NEW_CHAT -> mapOf("action" to "new_chat")
            ACTION_VOICE -> mapOf("action" to "voice")
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                val uris = mutableListOf<Uri>()
                @Suppress("DEPRECATION")
                if (intent.action == Intent.ACTION_SEND) {
                    (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
                } else {
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
                }
                mapOf(
                    "action" to "share",
                    "text" to listOfNotNull(
                        intent.getStringExtra(Intent.EXTRA_SUBJECT),
                        intent.getStringExtra(Intent.EXTRA_TEXT),
                    ).joinToString("\n").ifBlank { null },
                    "files" to uris.mapNotNull { copyShared(it) },
                )
            }
            else -> return
        }
        pendingLaunch = launch
        events?.success(mapOf("kind" to "launch"))
    }

    /** Copies a shared content:// file into app cache so Flutter and the agent can read it. */
    private fun copyShared(uri: Uri): Map<String, Any?>? = try {
        var name = "shared"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) name = c.getString(0) ?: name
        }
        val dir = File(cacheDir, "shared/${System.currentTimeMillis()}").apply { mkdirs() }
        val target = File(dir, name.replace('/', '_'))
        contentResolver.openInputStream(uri)?.use { input -> target.outputStream().use { input.copyTo(it) } }
        mapOf("path" to target.path, "name" to target.name, "mime" to contentResolver.getType(uri))
    } catch (e: Exception) {
        null
    }

    // -------------------------------------------------------------------------
    // Notifications

    private fun notify(id: Int, title: String, body: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(UPDATES_CHANNEL, "Agent updates", NotificationManager.IMPORTANCE_DEFAULT)
        )
        val open = PendingIntent.getActivity(
            this, id,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = android.app.Notification.Builder(this, UPDATES_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_agent)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(android.app.Notification.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        manager.notify(id, n)
    }

    /** The Play build removes MANAGE_EXTERNAL_STORAGE from its manifest; the GitHub build keeps it. */
    private fun storageAccessDeclared(): Boolean {
        if (Build.VERSION.SDK_INT < 30) return true
        @Suppress("DEPRECATION")
        val info = packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
        return info.requestedPermissions?.contains(Manifest.permission.MANAGE_EXTERNAL_STORAGE) == true
    }

    private fun hasStorageAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    private fun mimeOf(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"

    /** Copies a file into Download/AndroPI and returns where it went. MediaStore needs no storage permission. */
    private fun saveToDownloads(file: File): String {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, file.name)
                put(MediaStore.Downloads.MIME_TYPE, mimeOf(file.name))
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/AndroPI")
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Could not create the download")
            contentResolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
        } else {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "AndroPI")
            dir.mkdirs()
            file.copyTo(File(dir, file.name), overwrite = true)
        }
        return "Download/AndroPI/${file.name}"
    }
}
