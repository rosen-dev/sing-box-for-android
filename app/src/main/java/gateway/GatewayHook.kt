package gateway

import android.content.Context
import android.util.Log
import org.json.JSONObject

object GatewayHook {

    fun transformConfig(context: Context, rawJson: String, remoteUrl: String? = null): String {
        return try {
            RuleSetManager.ensureRuleSetsExtracted(context)

            val original = JSONObject(rawJson)
            Log.i(GatewayConstants.TAG, "[GatewayHook] 拦截到配置生成请求，开始执行旁路由与 5 层规则重构... (remoteUrl: $remoteUrl)")

            val transformed = ConfigGenerator.generate(context, original, remoteUrl)
            Log.i(GatewayConstants.TAG, "[GatewayHook] 配置重构成功！")
            transformed
        } catch (e: Throwable) {
            Log.e(GatewayConstants.TAG, "[GatewayHook] 配置重构发生异常，回退至原始配置: ${e.message}", e)
            rawJson
        }
    }
}
