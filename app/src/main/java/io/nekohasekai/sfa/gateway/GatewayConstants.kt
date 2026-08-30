package io.nekohasekai.sfa.gateway

object GatewayConstants {
    const val TAG = "GatewayManager"
    const val GATEWAY_MIXED_PORT = 8899
    const val GATEWAY_MIXED_TAG = "gateway-mixed-in"

    const val TAG_PROXY = "PROXY"
    const val TAG_DIRECT = "direct"
    const val TAG_BLOCK = "block"

    const val TAG_RULESET_PRIORITY_WHITELIST = "priority-whitelist"
    const val TAG_RULESET_BLACKLIST = "blacklist"
    const val TAG_RULESET_DIRECT = "direct-rules"
    const val TAG_RULESET_WHITELIST = "whitelist"

    const val FILE_BLACKLIST = "RuleSet_Blacklist.json"
    const val FILE_PRIORITY_WHITELIST = "RuleSet_Priority_Whitelist.json"
    const val FILE_DIRECT = "RuleSet_Direct.json"
    const val FILE_WHITELIST = "RuleSet_Whitelist.json"

    val ALL_RULE_SET_FILES = listOf(
        FILE_BLACKLIST,
        FILE_PRIORITY_WHITELIST,
        FILE_DIRECT,
        FILE_WHITELIST,
    )
}
