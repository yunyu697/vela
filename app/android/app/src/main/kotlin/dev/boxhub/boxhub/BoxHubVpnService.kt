package dev.boxhub.boxhub

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
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
        const val TAG = "VelaVpn"
        const val EXTRA_CORE = "core"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_HOME = "homeDir"
        const val EXTRA_CONTROLLER = "controller"
        const val EXTRA_SECRET = "secret"
        const val EXTRA_TUN = "tun"

        /** 前台服务通知：渠道 id / 通知 id（固定值，避免重复挂出多条）。 */
        private const val CHANNEL_ID = "vela_core"
        private const val NOTIFICATION_ID = 0x5645 // 'VE'

        @Volatile
        var eventChannel: MethodChannel? = null

        @Volatile
        private var tunInterface: ParcelFileDescriptor? = null

        @Volatile
        private var runningCore: String? = null

        /** 服务实例，供静态的 stopCore 撤掉前台通知。 */
        @Volatile
        private var instance: BoxHubVpnService? = null

        private val mainHandler = Handler(Looper.getMainLooper())

        /**
         * 通知 Dart 侧内核事件。
         *
         * 必须切回主线程：MethodChannel.invokeMethod 内部会走
         * FlutterJNI.dispatchPlatformMessage，该方法标注 @UiThread，
         * 在子线程调用会直接抛 RuntimeException 让整个进程崩溃
         * （onStartCommand 的内核启动线程就是子线程）。
         */
        fun notifyEvent(ok: Boolean, error: String?) {
            val channel = eventChannel ?: return
            mainHandler.post {
                channel.invokeMethod(
                    "onCoreEvent",
                    mapOf("ok" to ok, "error" to (error ?: ""))
                )
            }
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
                // 撤掉常驻通知并结束服务：内核已停，服务没有存在意义，
                // 留着只会占一个后台槽位等着被系统回收。
                instance?.let {
                    it.stopForegroundCompat()
                    it.stopSelf()
                }
                null
            } catch (e: Exception) {
                e.message ?: e.toString()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val core = intent?.getStringExtra(EXTRA_CORE) ?: return START_NOT_STICKY
        val config = intent.getStringExtra(EXTRA_CONFIG) ?: return START_NOT_STICKY
        val homeDir = intent.getStringExtra(EXTRA_HOME) ?: filesDir.absolutePath
        val controller = intent.getStringExtra(EXTRA_CONTROLLER) ?: ""
        val secret = intent.getStringExtra(EXTRA_SECRET) ?: ""
        val tun = intent.getBooleanExtra(EXTRA_TUN, false)

        // 必须先转前台：Android 8+ 的后台执行限制会在应用退到后台后
        // 回收普通服务，VPN 一断用户就会看到「开着开着就断了」。而且
        // manifest 已声明 foregroundServiceType=systemExempted，不调用
        // startForeground 的话该声明毫无作用，系统仍按普通服务对待。
        startForegroundNotice(core)

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
                    // 只有 TUN 模式才需要 protect：非 TUN（mixed 本地代理）时
                    // 本进程根本没有 VPN，protect() 必然返回 false，而 Go 侧
                    // 的 socketHook 一旦返回错误，所有出站连接都会失败——
                    // 表现为「内核起来了但完全不通」。
                    val protector = if (tun) {
                        FDProtector { fd ->
                            val ok = protect(fd)
                            if (!ok) {
                                Log.w(TAG, "protect(fd=$fd) 返回 false（出站连接会被 VPN 自身捕获）")
                            }
                            ok
                        }
                    } else {
                        null
                    }
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
                // 启动失败不要留下「正在运行」的假通知
                stopForegroundCompat()
                stopSelf()
            }
            notifyEvent(err == null, err)
        }.start()
        return START_NOT_STICKY
    }

    // MARK: - 前台服务通知

    private fun ensureChannel(): NotificationChannel? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val nm = getSystemService(NotificationManager::class.java) ?: return null
        nm.getNotificationChannel(CHANNEL_ID)?.let { return it }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "内核运行状态",
            NotificationManager.IMPORTANCE_LOW, // 静音：常驻通知不该响铃
        ).apply {
            description = "显示代理内核是否正在运行"
            setShowBadge(false)
            enableVibration(false)
        }
        nm.createNotificationChannel(channel)
        return channel
    }

    private fun buildNotification(core: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val name = if (core == "singbox") "sing-box" else "mihomo"
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ensureChannel()
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_vela)
            .setContentTitle("Vela 正在运行")
            .setContentText("$name · 流量已接管")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    /** 进入前台（失败不致命：只是没有常驻通知，内核仍可运行）。 */
    private fun startForegroundNotice(core: String) {
        try {
            startForeground(NOTIFICATION_ID, buildNotification(core))
        } catch (e: Exception) {
            Log.w(TAG, "startForeground 失败：$e")
        }
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Exception) {
            Log.w(TAG, "stopForeground 失败：$e")
        }
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
        val pfd = builder.establish()
        Log.i(TAG, "establish($core) fd=${pfd?.fd}")
        if (pfd != null && !awaitProtectReady()) {
            Log.w(TAG, "protect 通道 5s 内未就绪：内核出站连接可能全部失败")
        }
        return pfd
    }

    /**
     * 等 protect 通道可用。
     *
     * establish() 返回时 VPN 还处于 CONNECTING，netd 尚未把这个 uid 的
     * VPN 注册进去，此刻调用 protect() 返回 false（netd 日志：
     * `uid xxxx protect from VPN failed`）。如果这时就启动内核，它的每条
     * 出站连接都会因为「保护失败」被放弃——表现为「内核起来了但完全
     * 不通」。所以先用一个临时 socket 探测，直到 protect 成功再放行。
     */
    private fun awaitProtectReady(timeoutMs: Long = 5000): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            try {
                java.net.Socket().use { socket ->
                    if (protect(socket)) return true
                }
            } catch (_: Exception) {
                // 探测失败继续重试
            }
            Thread.sleep(80)
        }
        return false
    }

    override fun onRevoke() {
        // 用户在系统设置里断开 VPN：停掉内核并通知 Dart
        runningCore?.let { stopCore(it) }
        stopForegroundCompat()
        notifyEvent(false, "VPN 连接已被系统断开")
        super.onRevoke()
    }
}
