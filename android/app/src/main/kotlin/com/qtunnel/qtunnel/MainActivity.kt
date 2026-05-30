package com.qtunnel.qtunnel

import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowInsetsController
import com.signbox.singbox_mm.SignboxLibboxVpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "qtunnel/vpn_control"
        private const val ACTION_STOP = "com.signbox.singbox_mm.action.STOP"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyDarkSystemBars()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "forceStopVpn" -> {
                        forceStopVpn()
                        result.success(null)
                    }
                    "setQuickTileConnected" -> {
                        val connected = call.argument<Boolean>("connected") ?: false
                        QtunnelTileService.setConnected(this, connected)
                        result.success(null)
                    }
                    "consumeQuickTileConnectRequest" -> {
                        result.success(QtunnelTileService.consumeConnectRequest(this))
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun applyDarkSystemBars() {
        window.navigationBarColor = Color.rgb(15, 15, 26)
        window.statusBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.setSystemBarsAppearance(
                0,
                WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS or
                    WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS,
            )
        }
    }

    private fun forceStopVpn() {
        val stopIntent = Intent(this, SignboxLibboxVpnService::class.java).apply {
            action = ACTION_STOP
        }
        runCatching { startService(stopIntent) }

        Handler(Looper.getMainLooper()).postDelayed({
            runCatching {
                stopService(Intent(this, SignboxLibboxVpnService::class.java))
            }
        }, 700L)
    }
}
