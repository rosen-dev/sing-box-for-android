package gateway

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

object RuleSetManager {

    private const val ASSETS_RULES_DIR = "gateway_rules"
    private const val APP_RULES_DIR_NAME = "gateway_rules"

    private val RULESET_YAML_FILES = listOf(
        GatewayConstants.FILE_PRIORITY_WHITELIST to GatewayConstants.JSON_PRIORITY_WHITELIST,
        GatewayConstants.FILE_BLACKLIST to GatewayConstants.JSON_BLACKLIST,
        GatewayConstants.FILE_DIRECT to GatewayConstants.JSON_DIRECT,
        GatewayConstants.FILE_WHITELIST to GatewayConstants.JSON_WHITELIST
    )

    fun getRulesDir(context: Context): File {
        val dir = File(context.filesDir, APP_RULES_DIR_NAME)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    @Synchronized
    fun ensureRuleSetsExtracted(context: Context) {
        val targetDir = getRulesDir(context)
        val assetManager = context.assets

        for ((yamlName, jsonName) in RULESET_YAML_FILES) {
            val targetJsonFile = File(targetDir, jsonName)
            try {
                val assetPath = "$ASSETS_RULES_DIR/$yamlName"
                val lines = assetManager.open(assetPath).bufferedReader().readLines()
                val jsonContent = convertYamlToSingboxRuleSetJson(lines)

                targetJsonFile.writeText(jsonContent)
                Log.i(GatewayConstants.TAG, "[RuleSetManager] 成功转换并释放 Sing-box 规范规则集: $jsonName (${targetJsonFile.length()} bytes)")
            } catch (e: Exception) {
                Log.e(GatewayConstants.TAG, "[RuleSetManager] 转换规则文件失败: $yamlName -> $jsonName", e)
            }
        }
    }

    fun convertYamlToSingboxRuleSetJson(lines: List<String>): String {
        val domainSuffix = mutableListOf<String>()
        val domainKeyword = mutableListOf<String>()
        val domainExact = mutableListOf<String>()
        val ipCidr = mutableListOf<String>()

        for (rawLine in lines) {
            var line = rawLine.trim()
            if (line.isEmpty() || line.startsWith("#") || line == "payload:") {
                continue
            }
            if (line.startsWith("- ")) {
                line = line.substring(2).trim()
            }
            // 剥离行尾注释
            if (line.contains("#")) {
                line = line.substringBefore("#").trim()
            }
            val parts = line.split(",").map { it.trim() }.filter { it.isNotEmpty() }
            if (parts.size < 2) continue

            val type = parts[0].uppercase()
            val value = parts[1]

            when (type) {
                "DOMAIN-SUFFIX" -> domainSuffix.add(value)
                "DOMAIN-KEYWORD" -> domainKeyword.add(value)
                "DOMAIN" -> domainExact.add(value)
                "IP-CIDR", "IP-CIDR6" -> ipCidr.add(value)
            }
        }

        val ruleObj = JSONObject()
        if (domainSuffix.isNotEmpty()) {
            ruleObj.put("domain_suffix", JSONArray(domainSuffix))
        }
        if (domainKeyword.isNotEmpty()) {
            ruleObj.put("domain_keyword", JSONArray(domainKeyword))
        }
        if (domainExact.isNotEmpty()) {
            ruleObj.put("domain", JSONArray(domainExact))
        }
        if (ipCidr.isNotEmpty()) {
            ruleObj.put("ip_cidr", JSONArray(ipCidr))
        }

        val root = JSONObject().apply {
            put("version", 2)
            put("rules", JSONArray().put(ruleObj))
        }

        return root.toString(2)
    }
}
