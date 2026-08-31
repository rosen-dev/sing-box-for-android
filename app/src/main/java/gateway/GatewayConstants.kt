package gateway

object GatewayConstants {
    const val TAG = "SFA-Gateway"

    // 旁路由 Inbound 混合监听端口 (0.0.0.0:8899)
    const val GATEWAY_MIXED_TAG = "gateway-mixed-in"
    const val GATEWAY_MIXED_PORT = 8899

    // 4 大规则集源文件名 (YAML 格式，存放于 assets/gateway_rules/)
    const val FILE_PRIORITY_WHITELIST = "RuleSet_Priority_Whitelist.yaml"
    const val FILE_BLACKLIST = "RuleSet_Blacklist.yaml"
    const val FILE_DIRECT = "RuleSet_Direct.yaml"
    const val FILE_WHITELIST = "RuleSet_Whitelist.yaml"

    // 4 大规则集转换后的 Sing-box 规范 JSON 文件名
    const val JSON_PRIORITY_WHITELIST = "RuleSet_Priority_Whitelist.json"
    const val JSON_BLACKLIST = "RuleSet_Blacklist.json"
    const val JSON_DIRECT = "RuleSet_Direct.json"
    const val JSON_WHITELIST = "RuleSet_Whitelist.json"

    // 4 大规则集 Tag (与 sing-box route.rule_set 绑定)
    const val TAG_RULESET_PRIORITY_WHITELIST = "RuleSet_Priority_Whitelist"
    const val TAG_RULESET_BLACKLIST = "RuleSet_Blacklist"
    const val TAG_RULESET_DIRECT = "RuleSet_Direct"
    const val TAG_RULESET_WHITELIST = "RuleSet_Whitelist"

    // 统一出站组 Tag
    const val TAG_PROXY = "PROXY"
    const val TAG_DIRECT = "direct"
    const val TAG_BLOCK = "block"
}
