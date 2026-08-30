package io.nekohasekai.sfa.gateway

import android.content.Context
import android.util.Log
import org.json.JSONObject

object GatewayHook {
    fun transformConfig(context: Context, originalContent: String): String {
        if (originalContent.isBlank()) return originalContent
        return try {
            RuleSetManager.ensureRuleSets(context)
            val json = JSONObject(originalContent)
            ConfigGenerator.generate(context, json)
        } catch (e: Throwable) {
            Log.e(GatewayConstants.TAG, "Failed to transform config to custom gateway format, fallback to original", e)
            originalContent
        }
    }
}
