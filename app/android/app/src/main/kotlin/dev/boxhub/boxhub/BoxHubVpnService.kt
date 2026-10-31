package dev.boxhub.boxhub

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import com.boxhub.boxhubmobile.Boxhubmobile
import com.boxhub.boxhubmobile.FDProtector
import io.flutter.plugin.common.MethodChannel

/**
 * BoxHub VPN 服务：创建 TUN（VpnService.Builder）并把 fd 交给 Go 内核。
 *
 * - mihomo：fd 经 mobile 桥注入 YAML `tun.file-descriptor`，
 *   出站 socket 经 dialer.DefaultSocketHook → FDProtector → protect()
 * - sing-box：fd 经自定义 PlatformInterface.OpenInterface 注入 sing-tun，
 *   出站保护走 AutoDetectInterfaceControl → FDProtector → protect()
 *
 * TUN 参数约定（与 Go 侧 applyTunFD / Dart 编译器保持一致）：
 *   mihomo   198.18.0.1/30，DNS 198.18.0.2，MTU 9000
 *   sing-box 172.19.0.1/30，DNS 172.19.0.1，MTU 9000
 */
class BoxHubVpnService : VpnService() {

    companion object {
        const val EXTRA_CORE = "core"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_HOME = "homeDir"
        const val EXTRA_CONTROLLER = "controller"
        const val EXTRA_SECRET = "secret"
        const val EXTRA_TUN = "tun"

        @Volatile
        var eventChannel: MethodChannel? = null

        @Volatile
        private var tunInterface: ParcelFileDescriptor? = null

        @Volatile
        private var runningCore: String? = null

        fun notifyEvent(ok: Boolean, error: String?) {
            eventChannel?.invokeMethod(
                "onCoreEvent",
                mapOf("ok" to ok, "error" to (error ?: ""))
            )
        }

        /** 停止内核（MethodChannel 线程调用；返回错误信息或 null）。 */
        @Synchronized
        fun stopCore(core: String): String? {
            return try {
                when (core) {
                    "mihomo" -> Boxhubmobile.mihomoStop()
                    "singbox" -> Boxhubmobile.singboxStop()
                }
                tunInterface?.close()
                tunInterface = null
                runningCore = null
                null
            } catch (e: Exception) {
                e.message ?: e.toString()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val core = intent?.getStringExtra(EXTRA_CORE) ?: return START_NOT_STICKY
        val config = intent.getStringExtra(EXTRA_CONFIG) ?: return START_NOT_STICKY
        val homeDir = intent.getStringExtra(EXTRA_HOME) ?: filesDir.absolutePath
        val controller = intent.getStringExtra(EXTRA_CONTROLLER) ?: ""
        val secret = intent.getStringExtra(EXTRA_SECRET) ?: ""
        val tun = intent.getBooleanExtra(EXTRA_TUN, false)

        Thread {
            var err: String? = null
            var tunFd = -1
            try {
                if (tun) {
                    val pfd = establishTun(core)
                    if (pfd == null) {
                        err = "创建 TUN 接口失败（establish 返回 null）"
                    } else {
                        tunInterface = pfd
                        tunFd = pfd.fd
                    }
                }
                if (err == null) {
                    runningCore = core
                    val protector = FDProtector { fd -> protect(fd) }
                    when (core) {
                        "mihomo" -> Boxhubmobile.mihomoStart(
                            config, homeDir, controller, secret, tunFd, protector
                        )
                        "singbox" -> Boxhubmobile.singboxStart(
                            config, homeDir, controller, secret, tunFd, protector
                        )
                    }
                }
            } catch (e: Exception) {
                err = e.message ?: e.toString()
            }
            if (err != null) {
                tunInterface?.close()
                tunInterface = null
                runningCore = null
            }
            notifyEvent(err == null, err)
        }.start()
        return START_NOT_STICKY
    }

    /** 按内核建立 TUN 接口（地址/DNS 约定见类注释）。 */
    private fun establishTun(core: String): ParcelFileDescriptor? {
        val builder = Builder()
        if (core == "mihomo") {
            builder.addAddress("198.18.0.1", 30)
            builder.addDnsServer("198.18.0.2")
        } else {
            builder.addAddress("172.19.0.1", 30)
            builder.addDnsServer("172.19.0.1")
        }
        builder.addRoute("0.0.0.0", 0)
        builder.setMtu(9000)
        builder.setSession("BoxHub")
        return builder.establish()
    }

    override fun onRevoke() {
        // 用户在系统设置里断开 VPN：停掉内核并通知 Dart
        runningCore?.let { stopCore(it) }
        notifyEvent(false, "VPN 连接已被系统断开")
        super.onRevoke()
    }
}
