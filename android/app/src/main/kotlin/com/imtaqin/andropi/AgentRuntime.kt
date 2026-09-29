package com.imtaqin.andropi

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.system.Os
import android.util.Log
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.Executors
import java.util.zip.ZipInputStream

/**
 * Owns the Node.js child process that runs the pi agent host.
 *
 * Binaries ship as lib*.so in the APK's native library dir (the only place an
 * app targeting API 29+ may exec from). The agent's JavaScript ships in
 * assets/agent.zip and is unpacked to filesDir whenever agent.stamp changes.
 */
object AgentRuntime {
    private const val TAG = "AgentRuntime"

    interface Listener {
        fun onStdout(line: String)
        fun onStderr(line: String)
        fun onExit(code: Int)
    }

    var listener: Listener? = null

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()
    private var process: Process? = null
    private var stdin: OutputStream? = null

    val isRunning: Boolean get() = process?.isAlive == true

    fun paths(context: Context): Map<String, String> {
        val files = context.filesDir
        val home = File(files, "home")
        return mapOf(
            "home" to home.path,
            "agentDir" to File(home, ".pi/agent").path,
            "workspace" to File(home, "workspace").path,
            "hostDir" to File(files, "agent").path,
            "nativeLibDir" to context.applicationInfo.nativeLibraryDir,
        )
    }

    /**
     * Prepares the on-device toolchain (bundle, symlinks, CA file) and returns
     * the environment every process the app launches should run with: the
     * agent host, and later shells and terminals.
     */
    @Synchronized
    fun prepareEnvironment(context: Context): Map<String, String> {
        val p = paths(context)
        val nativeDir = File(p.getValue("nativeLibDir"))
        val agentDir = File(p.getValue("agentDir"))
        val workspace = File(p.getValue("workspace"))
        val home = File(p.getValue("home"))
        val tmp = File(context.cacheDir, "tmp")
        val bin = File(agentDir, "bin")
        val gitExec = File(agentDir, "libexec/git-core")
        val gitTemplates = File(agentDir, "share/git-core/templates")

        extractAssets(context, File(p.getValue("hostDir")))
        listOf(agentDir, workspace, tmp, gitTemplates, File(home, ".ssh")).forEach { it.mkdirs() }
        linkBinaries(nativeDir, bin, gitExec)
        val caFile = File(context.filesDir, "cacerts.pem")
        exportTrustedCerts(caFile)

        val env = linkedMapOf(
            "HOME" to home.path,
            "PI_CODING_AGENT_DIR" to agentDir.path,
            "ANDROPI_WORKSPACE" to workspace.path,
            "TMPDIR" to tmp.path,
            "PATH" to "${bin.path}:/system/bin:/system/xbin",
            "LD_LIBRARY_PATH" to nativeDir.path,
            "SHELL" to "/system/bin/sh",
            "TERM" to "dumb",
            "LANG" to "en_US.UTF-8",
            "PI_SKIP_VERSION_CHECK" to "1",
            // AndroPI sends no telemetry; keep pi's install ping off even if a future version bundles it.
            "PI_TELEMETRY" to "0",
            "NODE_OPTIONS" to "--max-old-space-size=1024",
            // The Termux builds look under /data/data/com.termux; point them at ours.
            "GIT_EXEC_PATH" to gitExec.path,
            "GIT_TEMPLATE_DIR" to gitTemplates.path,
            "GIT_CONFIG_NOSYSTEM" to "1",
            "GIT_PAGER" to "cat",
            "PAGER" to "cat",
            "GIT_SSH_COMMAND" to "ssh -o UserKnownHostsFile=${home.path}/.ssh/known_hosts",
            // Linux container (see tool/box.sh); the rootfs is installed on demand.
            "ANDROPI_HOME" to home.path,
            "ANDROPI_FILES" to context.filesDir.path,
            "ANDROPI_ROOTFS" to File(context.filesDir, "linux/rootfs").path,
            "ANDROPI_PROOT" to File(nativeDir, "libproot.so").path,
            "ANDROPI_PROOT_LOADER" to File(nativeDir, "libproot_loader.so").path,
        )
        if (caFile.length() > 0) {
            env["NODE_EXTRA_CA_CERTS"] = caFile.path
            env["SSL_CERT_FILE"] = caFile.path
            env["GIT_SSL_CAINFO"] = caFile.path
            env["CURL_CA_BUNDLE"] = caFile.path
        }
        return env
    }

    @Synchronized
    fun start(context: Context, extraEnv: Map<String, String> = emptyMap()) {
        if (isRunning) return
        val p = paths(context)
        val env = prepareEnvironment(context)
        val pb = ProcessBuilder(
            File(p.getValue("nativeLibDir"), "libnode.so").path,
            File(p.getValue("hostDir"), "host.mjs").path,
        ).directory(File(p.getValue("workspace")))
        pb.environment().apply {
            putAll(env)
            putAll(extraEnv)
        }

        val proc = pb.start()
        process = proc
        stdin = proc.outputStream
        io.execute { pumpLines(proc.inputStream) { line -> main.post { listener?.onStdout(line) } } }
        io.execute { pumpLines(proc.errorStream) { line -> Log.w(TAG, line); main.post { listener?.onStderr(line) } } }
        io.execute {
            val code = proc.waitFor()
            main.post {
                if (process === proc) {
                    process = null
                    stdin = null
                }
                listener?.onExit(code)
            }
        }
    }

    fun send(line: String) {
        val out = stdin ?: throw IllegalStateException("agent is not running")
        io.execute {
            try {
                synchronized(out) {
                    out.write((line + "\n").toByteArray())
                    out.flush()
                }
            } catch (e: Exception) {
                Log.e(TAG, "write failed", e)
            }
        }
    }

    @Synchronized
    fun stop() {
        val proc = process ?: return
        try { stdin?.close() } catch (_: Exception) {}
        io.execute {
            // Closing stdin asks the host to dispose and exit; force it if it hangs.
            Thread.sleep(1500)
            if (proc.isAlive) proc.destroyForcibly()
        }
    }

    /** Splits on LF only: pi's JSON may contain U+2028/U+2029 inside strings. */
    private fun pumpLines(input: InputStream, onLine: (String) -> Unit) {
        val buf = ByteArray(64 * 1024)
        val pending = java.io.ByteArrayOutputStream()
        try {
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                var start = 0
                for (i in 0 until n) {
                    if (buf[i] == '\n'.code.toByte()) {
                        pending.write(buf, start, i - start)
                        onLine(pending.toString(Charsets.UTF_8.name()).removeSuffix("\r"))
                        pending.reset()
                        start = i + 1
                    }
                }
                pending.write(buf, start, n - start)
            }
            if (pending.size() > 0) onLine(pending.toString(Charsets.UTF_8.name()))
        } catch (_: Exception) {
        }
    }

    /** Unpacks assets/agent.zip into [dest] whenever assets/agent.stamp changes. */
    private fun extractAssets(context: Context, dest: File) {
        val stamp = context.assets.open("agent.stamp").use { it.readBytes().decodeToString() }
        val current = File(dest, ".stamp")
        if (current.exists() && current.readText() == stamp) return
        // Unpack beside dest and swap, so a killed extraction never leaves a half tree.
        val staging = File(dest.parentFile, "${dest.name}.new")
        staging.deleteRecursively()
        staging.mkdirs()
        val root = staging.canonicalPath + File.separator
        ZipInputStream(context.assets.open("agent.zip").buffered(256 * 1024)).use { zip ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val entry = zip.nextEntry ?: break
                val file = File(staging, entry.name)
                if (!file.canonicalPath.startsWith(root)) throw SecurityException("bad zip entry ${entry.name}")
                if (entry.isDirectory) {
                    file.mkdirs()
                } else {
                    file.parentFile?.mkdirs()
                    file.outputStream().use { out ->
                        while (true) {
                            val n = zip.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                        }
                    }
                }
            }
        }
        File(staging, ".stamp").writeText(stamp)
        dest.deleteRecursively()
        if (!staging.renameTo(dest)) throw IllegalStateException("could not install agent bundle")
    }

    /**
     * Node only trusts its bundled Mozilla roots. Hand it everything Android
     * trusts too (system and user-installed CAs), so TLS works behind the
     * same proxies and VPNs the rest of the phone works behind.
     */
    private fun exportTrustedCerts(dest: File) {
        try {
            val store = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
            val encoder = Base64.getMimeEncoder(64, "\n".toByteArray())
            val pem = StringBuilder()
            for (alias in store.aliases()) {
                val cert = store.getCertificate(alias) as? X509Certificate ?: continue
                pem.append("-----BEGIN CERTIFICATE-----\n")
                    .append(encoder.encodeToString(cert.encoded))
                    .append("\n-----END CERTIFICATE-----\n")
            }
            dest.writeText(pem.toString())
        } catch (e: Exception) {
            Log.e(TAG, "could not export CA certificates", e)
        }
    }

    /** Exposes lib<name>.so under its real name so pi and the shell find it on PATH. */
    private fun linkBinaries(nativeDir: File, binDir: File, gitExecDir: File) {
        val bins = mapOf(
            "node" to "libnode.so",
            "rg" to "librg.so",
            "fd" to "libfd.so",
            "git" to "libgit.so",
            "ssh" to "libssh_cli.so",
            "ssh-keygen" to "libssh_keygen.so",
            "scp" to "libscp_cli.so",
            "rsync" to "librsync_cli.so",
            "curl" to "libcurl_cli.so",
            "proot" to "libproot.so",
            "box" to "libbox.so",
            "llama-server" to "libllama-server.so",
        )
        // git runs these by name from GIT_EXEC_PATH; the dashed builtins are
        // git itself, dispatched on argv[0].
        val gitExec = mapOf(
            "git" to "libgit.so",
            "git-remote-http" to "libgit_remote_http.so",
            "git-remote-https" to "libgit_remote_http.so",
            "git-remote-ftp" to "libgit_remote_http.so",
            "git-remote-ftps" to "libgit_remote_http.so",
            "git-upload-pack" to "libgit.so",
            "git-receive-pack" to "libgit.so",
            "git-upload-archive" to "libgit.so",
        )
        for ((dir, names) in listOf(binDir to bins, gitExecDir to gitExec)) {
            dir.mkdirs()
            for ((name, lib) in names) {
                val target = File(nativeDir, lib)
                val link = File(dir, name)
                link.delete()
                if (target.exists()) Os.symlink(target.path, link.path)
            }
        }
    }
}
