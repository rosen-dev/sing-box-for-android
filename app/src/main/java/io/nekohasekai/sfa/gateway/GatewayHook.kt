package io.nekohasekai.sfa.gateway

import android.content.Context
import android.util.Log
import org.json.JSONObject

object GatewayHook {
    fun transformConfig(context: Context, originalContent: String): String {
        if (originalContent.isBlank()) return originalContent
        Log.i(GatewayConstants.TAG, ">>> [GatewayHook] 拦截到配置启动请求，开始执行 Gateway 规则与 PROXY 代理组注入...")
        return try {
            RuleSetManager.ensureRuleSets(context)
            val json = JSONObject(originalContent)
            val generated = ConfigGenerator.generate(context, json)
            Log.i(GatewayConstants.TAG, ">>> [GatewayHook] Gateway 配置重构成功，已交付 Sing-box 核心引擎启动！")
            generated
        } catch (e: Throwable) {
            Log.e(GatewayConstants.TAG, ">>> [GatewayHook] 配置重构发生异常，回退至原始配置启动", e)
            originalContent
        }
    }
}
