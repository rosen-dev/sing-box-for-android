package io.nekohasekai.sfa.gateway

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

object ConfigGenerator {

    private val NON_PHYSICAL_TYPES = setOf("selector", "urltest", "direct", "block", "dns")

    fun generate(context: Context, original: JSONObject): String {
        val result = JSONObject()

        // 1. 继承 log (若有)
        original.optJSONObject("log")?.let {
            result.put("log", it)
        }

        // 2. 严格按 sing-box 1.12/1.13 新版 DNS 规范 (type: udp / type: https, 不对空 direct outbound 做冗余 detour)
        result.put("dns", buildFastDNS(original))

        // 3. 继承 ntp (若有)
        original.optJSONObject("ntp")?.let {
            result.put("ntp", it)
        }

        // 4. 重构 inbounds (保留原生并追加 8899 mixed 旁路由端口)
        result.put("inbounds", buildInbounds(original))

        // 5. 重构 outbounds (归并物理节点 -> 唯一 PROXY 选择器组)
        result.put("outbounds", buildOutbounds(original))

        // 6. 自定义 5 层路由规则与本地 RuleSet 绑定 (声明 default_domain_resolver)
        result.put("route", buildRoute(context))

        // 7. 继承 experimental (按 1.13.21 标准仅启用 cache_file 与 clash_api)
        val experimental = original.optJSONObject("experimental") ?: JSONObject()
        if (!experimental.has("clash_api")) {
            experimental.put("clash_api", JSONObject().put("external_controller", "127.0.0.1:9090"))
        }
        val cacheFile = experimental.optJSONObject("cache_file") ?: JSONObject()
        cacheFile.put("enabled", true)
        experimental.put("cache_file", cacheFile)
        result.put("experimental", experimental)

        val finalConfigStr = result.toString(2)
        Log.d(GatewayConstants.TAG, "[ConfigGenerator] 生成的配置 JSON:\n$finalConfigStr")
        return finalConfigStr
    }

    private fun buildFastDNS(original: JSONObject): JSONObject {
        val dns = JSONObject()
        val servers = JSONArray()

        // 1. 节点域名与国内直连极速 DNS (type: "udp", server: "223.5.5.5", 移除无意义的 detour to direct)
        servers.put(JSONObject().apply {
            put("tag", "dns-direct")
            put("type", "udp")
            put("server", "223.5.5.5")
        })

        // 2. 远端防污染 DNS (type: "https", server: "1.1.1.1", path: "/dns-query", domain_resolver: "dns-direct")
        servers.put(JSONObject().apply {
            put("tag", "dns-remote")
            put("type", "https")
            put("server", "1.1.1.1")
            put("path", "/dns-query")
            put("domain_resolver", "dns-direct")
        })

        dns.put("servers", servers)

        val dnsRules = JSONArray()
        // 直连规则走国内 DNS
        dnsRules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_DIRECT)
            put("server", "dns-direct")
        })
        // 黑名单走拒绝动作 (action: reject)
        dnsRules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_BLACKLIST)
            put("action", "reject")
        })

        dns.put("rules", dnsRules)
        dns.put("final", "dns-remote")
        dns.put("strategy", "prefer_ipv4")

        Log.i(GatewayConstants.TAG, "[ConfigGenerator] 注入现代标准 DNS 引擎 (type: udp / type: https)")
        return dns
    }

    private fun buildInbounds(original: JSONObject): JSONArray {
        val inboundsArray = JSONArray()
        val originalInbounds = original.optJSONArray("inbounds")
        if (originalInbounds != null) {
            for (i in 0 until originalInbounds.length()) {
                val item = originalInbounds.optJSONObject(i) ?: continue
                val tag = item.optString("tag")
                val port = item.optInt("listen_port", -1)
                if (tag == GatewayConstants.GATEWAY_MIXED_TAG || port == GatewayConstants.GATEWAY_MIXED_PORT) {
                    continue
                }
                inboundsArray.put(item)
            }
        }

        val mixedInbound = JSONObject().apply {
            put("type", "mixed")
            put("tag", GatewayConstants.GATEWAY_MIXED_TAG)
            put("listen", "0.0.0.0")
            put("listen_port", GatewayConstants.GATEWAY_MIXED_PORT)
        }
        inboundsArray.put(mixedInbound)
        Log.i(GatewayConstants.TAG, "[ConfigGenerator] 入站重构: 开启网关混合端口 0.0.0.0:${GatewayConstants.GATEWAY_MIXED_PORT}")

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

        // 1. 构建唯一的 PROXY 选择器组
        val proxySelector = JSONObject().apply {
            put("type", "selector")
            put("tag", GatewayConstants.TAG_PROXY)
            val tagsArray = JSONArray()
            if (physicalNodeTags.isNotEmpty()) {
                physicalNodeTags.forEach { tagsArray.put(it) }
            } else {
                tagsArray.put(GatewayConstants.TAG_BLOCK)
            }
            put("outbounds", tagsArray)
        }
        outboundsArray.put(proxySelector)

        // 2. 规范化 direct 与 block
        outboundsArray.put(JSONObject().apply {
            put("type", "direct")
            put("tag", GatewayConstants.TAG_DIRECT)
        })
        outboundsArray.put(JSONObject().apply {
            put("type", "block")
            put("tag", GatewayConstants.TAG_BLOCK)
        })

        // 3. 追加特殊出站 (如 dns-out)
        specialOutbounds.forEach { outboundsArray.put(it) }

        // 4. 追加全体物理节点
        physicalNodes.forEach { outboundsArray.put(it) }

        Log.i(GatewayConstants.TAG, "[ConfigGenerator] 成功提取节点共 ${physicalNodeTags.size} 个至 [${GatewayConstants.TAG_PROXY}] 组")

        return outboundsArray
    }

    private fun buildRoute(context: Context): JSONObject {
        val route = JSONObject()
        val rules = JSONArray()

        // 0. 嗅探 (Sniff)
        rules.put(JSONObject().put("action", "sniff"))

        // 0.1 DNS 劫持 (Hijack DNS)
        rules.put(JSONObject().apply {
            put("protocol", "dns")
            put("action", "hijack-dns")
        })

        // 0.2 DNS 端口直通 (Port 53, 853)
        rules.put(JSONObject().apply {
            put("port", JSONArray().put(53).put(853))
            put("outbound", GatewayConstants.TAG_PROXY)
        })

        // 1. 特定设备过滤规则 (192.168.10.50 + googlevideo.com -> reject)
        rules.put(JSONObject().apply {
            put("type", "logical")
            put("mode", "and")
            put("rules", JSONArray().apply {
                put(JSONObject().put("source_ip_cidr", JSONArray().put("192.168.10.50/32")))
                put(JSONObject().put("domain_suffix", JSONArray().put("googlevideo.com")))
            })
            put("action", "reject")
        })

        // 2. 优先级白名单 (直接放行/直连) -> PROXY
        rules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_PRIORITY_WHITELIST)
            put("outbound", GatewayConstants.TAG_PROXY)
        })

        // 3. 黑名单 -> reject
        rules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_BLACKLIST)
            put("action", "reject")
        })

        // 4. 直连名单 -> direct
        rules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_DIRECT)
            put("outbound", GatewayConstants.TAG_DIRECT)
        })

        // 5. 白名单 -> PROXY
        rules.put(JSONObject().apply {
            put("rule_set", GatewayConstants.TAG_RULESET_WHITELIST)
            put("outbound", GatewayConstants.TAG_PROXY)
        })

        route.put("rules", rules)

        // 4 大本地规则文件指针
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
        // 关键: 指定 default_domain_resolver 为 dns-direct
        route.put("default_domain_resolver", "dns-direct")
        route.put("final", GatewayConstants.TAG_BLOCK)
        route.put("auto_detect_interface", true)

        Log.i(GatewayConstants.TAG, "[ConfigGenerator] 组装 5 层路由规则完成 (default_domain_resolver: dns-direct)")

        return route
    }
}
