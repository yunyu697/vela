package dev.boxhub.boxhub

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter ↔ 原生桥：内核启停（gomobile aar）+ VpnService 编排。
 *
 * 通道 `dev.boxhub.boxhub/core`：
 *   - getPaths                    → {filesDir, cacheDir}
 *   - startCore {core, config, homeDir, controller, secret, tun}
 *                                 → {status: starting | permission_required}
 *                                   最终结果经 onCoreEvent 回调
 *   - stopCore {core}             → {status: stopped}
 *   - checkNotifications          → {granted: Boolean}（Android 13+ 通知权限）
 *   - requestNotifications        → 拉起系统通知权限对话框
 *   - onCoreEvent（原生 → Dart）  {ok, error}
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "dev.boxhub.boxhub/core"
        const val REQ_VPN_PERMISSION = 7001
        const val REQ_NOTIFICATIONS = 7002
        @Volatile var pendingStartArgs: Map<String, Any?>? = null
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /// Android 13+ 前台服务通知需要运行时授权；低版本恒为 true。
    private fun notificationsGranted(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        BoxHubVpnService.eventChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPaths" -> result.success(
                        mapOf(
                            "filesDir" to filesDir.absolutePath,
                            "cacheDir" to cacheDir.absolutePath,
                        )
                    )
                    "startCore" -> handleStartCore(call.arguments() ?: emptyMap(), result)
                    "stopCore" -> handleStopCore(call.arguments() ?: emptyMap(), result)
                    "checkNotifications" -> result.success(
                        mapOf("granted" to notificationsGranted())
                    )
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            !notificationsGranted()
                        ) {
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQ_NOTIFICATIONS
                            )
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleStartCore(args: Map<String, Any?>, result: MethodChannel.Result) {
        val tun = args["tun"] == true
        if (tun) {
            // VpnService.prepare 返回非空说明尚未授权：拉起系统授权对话框，
            // 用户同意后 onActivityResult 里真正启动服务
            val consent = VpnService.prepare(this)
            if (consent != null) {
                pendingStartArgs = args
                startActivityForResult(consent, REQ_VPN_PERMISSION)
                result.success(mapOf("status" to "permission_required"))
                return
            }
        }
        startCoreService(args)
        result.success(mapOf("status" to "starting"))
    }

    private fun startCoreService(args: Map<String, Any?>) {
        val intent = Intent(this, BoxHubVpnService::class.java).apply {
            putExtra(BoxHubVpnService.EXTRA_CORE, args["core"] as? String)
            putExtra(BoxHubVpnService.EXTRA_CONFIG, args["config"] as? String)
            putExtra(BoxHubVpnService.EXTRA_HOME, args["homeDir"] as? String)
            putExtra(BoxHubVpnService.EXTRA_CONTROLLER, args["controller"] as? String)
            putExtra(BoxHubVpnService.EXTRA_SECRET, args["secret"] as? String)
            putExtra(BoxHubVpnService.EXTRA_TUN, args["tun"] == true)
        }
        // 核心逻辑在服务内部线程执行，结果经 eventChannel.onCoreEvent 回传
        startService(intent)
    }

    private fun handleStopCore(args: Map<String, Any?>, result: MethodChannel.Result) {
        val core = args["core"] as? String ?: "mihomo"
        Thread {
            val err = BoxHubVpnService.stopCore(core)
            mainHandler.post {
                if (err == null) {
                    result.success(mapOf("status" to "stopped"))
                } else {
                    result.error("stop_failed", err, null)
                }
            }
        }.start()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN_PERMISSION) {
            val args = pendingStartArgs
            pendingStartArgs = null
            if (resultCode == Activity.RESULT_OK && args != null) {
                startCoreService(args)
            } else {
                BoxHubVpnService.notifyEvent(false, "VPN 权限被拒绝")
            }
        }
    }
}
