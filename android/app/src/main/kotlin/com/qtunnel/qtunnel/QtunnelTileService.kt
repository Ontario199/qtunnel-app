package com.qtunnel.qtunnel

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.signbox.singbox_mm.SignboxLibboxVpnService

class QtunnelTileService : TileService() {
    companion object {
        private const val PREFS = "qtunnel_quick_tile"
        private const val KEY_CONNECTED = "connected"
        private const val KEY_CONNECT_REQUESTED = "connect_requested"
        private const val ACTION_STOP = "com.signbox.singbox_mm.action.STOP"

        fun setConnected(context: Context, connected: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_CONNECTED, connected)
                .apply()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                requestListeningState(
                    context,
                    ComponentName(context, QtunnelTileService::class.java),
                )
            }
        }

        fun requestConnect(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_CONNECT_REQUESTED, true)
                .apply()
        }

        fun consumeConnectRequest(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val requested = prefs.getBoolean(KEY_CONNECT_REQUESTED, false)
            if (requested) {
                prefs.edit().putBoolean(KEY_CONNECT_REQUESTED, false).apply()
            }
            return requested
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        val connected = isConnected()
        if (connected) {
            forceStopVpn()
            setConnected(this, false)
            updateTile()
        } else {
            requestConnect(this)
            openApp()
        }
    }

    private fun isConnected(): Boolean {
        return getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_CONNECTED, false)
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val connected = isConnected()
        tile.label = "QTunnel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (connected) "VPN включен" else "Открыть"
        }
        tile.state = if (connected) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }

    private fun openApp() {
        val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra("fromQuickTile", true)
        } ?: return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pendingIntent = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
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
