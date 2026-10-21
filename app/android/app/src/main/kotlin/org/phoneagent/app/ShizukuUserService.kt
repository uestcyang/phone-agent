package org.phoneagent.app

import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit


class ShizukuUserService : IShizukuUserService.Stub() {


    private val deny = Regex(
        "(\\brm\\s+(?=[^\\n]*(?:-[a-zA-Z]*r[a-zA-Z]*\\b|--recursive\\b))" +
            "(?=[^\\n]*(?:-[a-zA-Z]*f[a-zA-Z]*\\b|--force\\b))[^\\n]*?\\s/|" +
            "\\breboot\\b|\\bshutdown\\b|factory|\\bwipe\\b|" +
            "\\bpm\\s+uninstall\\b|\\bpm\\s+clear\\b|\\bsvc\\s+power\\b|\\bmkfs|\\bdd\\s+[^\\n]*\\bif=|" +
            "settings\\s+put\\s+global\\s+http_proxy|svc\\s+wifi\\s+disable|svc\\s+data\\s+disable|" +
            "\\bam\\s+(?:kill|force-stop)\\s+com\\.(?:tailscale|nutomic)|" +
            "\\bsetprop\\s+\\S*powerctl|" +
            "\\bcmd\\s+package\\s+(?:uninstall|clear)\\b|" +
            "\\bfind\\b[^\\n]*-delete|" +
            "master_clear|" +
            "\\bkillall\\b|" +
            "\\bcmd\\s+wifi\\s+set-wifi-enabled\\s+disabled)",
        RegexOption.IGNORE_CASE
    )


    override fun exec(cmd: String?): String {
        if (cmd.isNullOrBlank()) return "-1" + SEP + "empty command"
        if (deny.containsMatchIn(cmd)) {
            return "-1" + SEP + "DENY: 命中破坏性命令硬闸,拒绝执行"
        }
        return try {
            val process = ProcessBuilder("sh", "-c", cmd)
                .redirectErrorStream(true)
                .start()
            val output = BufferedReader(InputStreamReader(process.inputStream)).use { it.readText() }
            val finished = process.waitFor(30, TimeUnit.SECONDS)
            if (!finished) {
                process.destroyForcibly()
                "-1" + SEP + "timeout after 30s\n$output"
            } else {
                "${process.exitValue()}" + SEP + output
            }
        } catch (e: Exception) {
            "-1" + SEP + "exec failed: ${e.message}"
        }
    }

    override fun destroy() {


        android.os.Process.killProcess(android.os.Process.myPid())
    }

    companion object {

        const val SEP = "\u0001"
    }
}
