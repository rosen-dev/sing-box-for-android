package io.nekohasekai.sfa.gateway

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

object ConfigGenerator {

    private val NON_PHYSICAL_TYPES = setOf(
        "selector",
        "urltest",
        "direct",
        "block",
        "dns",
        "anytls",
        "bypass",
        "drop",
    )

    fun generate(context: Context, original: JSONObject): String {
        val result = JSONObject()

        // 1. 继承或默认 log
        val logObj = original.optJSONObject("log") ?: JSONObject().apply {
            put("level", "info")
            put("timestamp", true)
        }
        result.put("log", logObj)

        // 2. 继承 dns (若有)
        original.optJSONObject("dns")?.let {
            result.put("dns", it)
        }

        // 3. 继承 ntp (若有)
        original.optJSONObject("ntp")?.let {
            result.put("ntp", it)
        }

        // 4. 构建 inbounds (保留原有并追加 8899 mixed 端口)
        result.put("inbounds", buildInbounds(original))

        // 5. 构建 outbounds (提取实体节点 -> 唯一 PROXY 组)
        result.put("outbounds", buildOutbounds(original))

        // 6. 自定义 6 层路由与本地 RuleSet 绑定
        result.put("route", buildRoute(context))

        // 7. 继承 experimental (确保 Clash API 开启以便 SFA 切换 PROXY 组的节点)
        val experimental = original.optJSONObject("experimental") ?: JSONObject()
        if (!experimental.has("clash_api")) {
            experimental.put("clash_api", JSONObject().put("external_controller", "127.0.0.1:9090"))
        }
        result.put("experimental", experimental)

        val finalConfigStr = result.toString(2)
        Log.d(GatewayConstants.TAG, "[ConfigGenerator] 生成的完整配置 JSON:\n$finalConfigStr")
        return finalConfigStr
    }

    private fun buildInbounds(original: JSONObject): JSONArray {
        val inboundsArray = JSONArray()
        val originalInbounds = original.optJSONArray("inbounds")
        if (originalInbounds != null) {
            for (i in 0 until originalInbounds.length()) {
                val item = originalInbounds.optJSONObject(i) ?: continue
                val tag = item.optString("tag")
                val port = item.optInt("listen_port", -1)
                // 避免重复添加 8899 入站
                if (tag == GatewayConstants.GATEWAY_MIXED_TAG || port == GatewayConstants.GATEWAY_MIXED_PORT) {
                    continue
                }
                inboundsArray.put(item)
            }
        }

        // 追加 0.0.0.0:8899 mixed 入站
        val mixedInbound = JSONObject().apply {
            put("type", "mixed")
            put("tag", GatewayConstants.GATEWAY_MIXED_TAG)
            put("listen", "0.0.0.0")
            put("listen_port", GatewayConstants.GATEWAY_MIXED_PORT)
        }
        inboundsArray.put(mixedInbound)
        Log.i(GatewayConstants.TAG, "[ConfigGenerator] 已配置入站: 包含网关混合端口 0.0.0.0:${GatewayConstants.GATEWAY_MIXED_PORT}")

        return inboundsArray
    }

    private fun buildOutbounds(original: JSONObject): JSONArray {
        val outboundsArray = JSONArray()
        val originalOutbounds = original.optJSONArray("outbounds") ?: JSONArray()

        val physicalNodeTags = mutableListOf<String>()
        val physicalNodes = mutableListOf<JSONObject>()
        val specialOutbounds = mutableListOf<JSONObject>()

        for (i in 0 until originalOutbounds.length()) {
            val item = originalOutbounds.optJSONObject(i) ?: continue
            val type = item.optString("type")
            val tag = item.optString("tag")

            if (tag.equals(GatewayConstants.TAG_DIRECT, ignoreCase = true) || type == "direct") {
                continue
            }
            if (tag.equals(GatewayConstants.TAG_BLOCK, ignoreCase = true) || type == "block") {
                continue
            }

            if (!NON_PHYSICAL_TYPES.contains(type.lowercase()) && tag != GatewayConstants.TAG_PROXY) {
                physicalNodeTags.add(tag)
                physicalNodes.add(item)
            } else if (type == "dns") {
                specialOutbounds.add(item)
            }
        }

        // 1. 创建唯一主 PROXY 选择组
        val proxySelector = JSONObject().apply {
            put("type", "selector")
            put("tag", GatewayConstants.TAG_PROXY)
            val tagsArray = JSONArray()
            if (physicalNodeTags.isNotEmpty()) {
                physicalNodeTags.forEach { tagsArray.put(it) }
            } else {
                // 无实体节点，默认回退 block (防止直接裸连泄露)
                tagsArray.put(GatewayConstants.TAG_BLOCK)
            }
            put("outbounds", tagsArray)
        }
        outboundsArray.put(proxySelector)

        // 2. 补齐规范化 direct 和 block 出口
        outboundsArray.put(JSONObject().apply {
            put("type", "direct")
            put("tag", GatewayConstants.TAG_DIRECT)
        })
        outboundsArray.put(JSONObject().apply {
            put("type", "block")
            put("tag", GatewayConstants.TAG_BLOCK)
        })

        // 3. 追加特殊出口 (如 dns-out)
        specialOutbounds.forEach { outboundsArray.put(it) }

        // 4. 追加全部实体物理节点
        physicalNodes.forEach { outboundsArray.put(it) }

        Log.i(GatewayConstants.TAG, "[ConfigGenerator] 成功提取物理代理节点共 ${physicalNodeTags.size} 个至 [${GatewayConstants.TAG_PROXY}] 代理组: $physicalNodeTags")

        return outboundsArray
    }

    private fun buildRoute(context: Context): JSONObject {
        val route = JSONObject()
        val rules = JSONArray()

        // 0. 基础嗅探与 DNS 劫持
        rules.put(JSONObject().put("action", "sniff"))
        rules.put(JSONObject().apply {
            put("protocol", "dns")
            put("action", "hijack-dns")
        })

        // 0.1 阻断直接 DNS 请求，防止被 final: block 误杀
        rules.put(JSONObject().apply {
            put("port", JSONArray().put(53).put(853))
            put("outbound", GatewayConstants.TAG_PROXY)
        })

        // 1. 特定设备过滤规则 (192.168.10.50 + googlevideo.com -> block)
        rules.put(JSONObject().apply {
            put("type", "logical")
            put("mode", "and")
            put("rules", JSONArray().apply {
                put(JSONObject().put("source_ip_cidr", JSONArray().put("192.168.10.50/32")))
                put(JSONObject().put("domain_suffix", JSONArray().put("googlevideo.com")))
            })
            put("outbound", GatewayConstants.TAG_BLOCK)
        })

        // 2. 优先级白名单 (极速直连/优先) -> PROXY (或 DIRECT)
        rules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_PRIORITY_WHITELIST)
            put("outbound", GatewayConstants.TAG_PROXY)
        })

        // 3. 黑名单 -> block
        rules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_BLACKLIST)
            put("outbound", GatewayConstants.TAG_BLOCK)
        })

        // 4. 直连名单 -> direct
        rules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_DIRECT)
            put("outbound", GatewayConstants.TAG_DIRECT)
        })

        // 5. 代理名单 -> PROXY
        rules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_WHITELIST)
            put("outbound", GatewayConstants.TAG_PROXY)
        })

        route.put("rules", rules)

        // 4 大本地规则集文件指向
        val rulesDir = RuleSetManager.getRulesDir(context).absolutePath
        val ruleSetArray = JSONArray()

        val ruleSetMappings = listOf(
            GatewayConstants.TAG_RULESET_PRIORITY_WHITELIST to GatewayConstants.FILE_PRIORITY_WHITELIST,
            GatewayConstants.TAG_RULESET_BLACKLIST to GatewayConstants.FILE_BLACKLIST,
            GatewayConstants.TAG_RULESET_DIRECT to GatewayConstants.FILE_DIRECT,
            GatewayConstants.TAG_RULESET_WHITELIST to GatewayConstants.FILE_WHITELIST,
        )

        for ((tag, fileName) in ruleSetMappings) {
            ruleSetArray.put(JSONObject().apply {
                put("type", "local")
                put("tag", tag)
                put("format", "source")
                put("path", File(rulesDir, fileName).absolutePath)
            })
        }

        route.put("rule_set", ruleSetArray)
        route.put("final", GatewayConstants.TAG_BLOCK)
        route.put("auto_detect_interface", true)

        Log.i(GatewayConstants.TAG, "[ConfigGenerator] 成功构建 4 层分流规则链: Priority -> Blacklist -> Direct -> Whitelist (Final: ${GatewayConstants.TAG_BLOCK})")

        return route
    }
}
