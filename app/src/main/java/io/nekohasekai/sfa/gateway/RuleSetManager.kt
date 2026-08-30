package io.nekohasekai.sfa.gateway

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader

object RuleSetManager {
    private const val RULES_DIR_NAME = "gateway_rules"
    private const val ASSETS_RULES_DIR = "gateway_rules"

    fun getRulesDir(context: Context): File {
        val dir = File(context.filesDir, RULES_DIR_NAME)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    /**
     * 读取 assets/gateway_rules/ 下的带注释原生 YAML 规则文件，
     * 在运行时由 Kotlin 直接无损转换为 Sing-box 标准 JSON 规则集并存入应用私有目录。
     */
    fun ensureRuleSets(context: Context) {
        val rulesDir = getRulesDir(context)
        for ((yamlFileName, jsonFileName) in GatewayConstants.RULE_SET_PAIRS) {
            val targetJsonFile = File(rulesDir, jsonFileName)
            val assetPath = "$ASSETS_RULES_DIR/$yamlFileName"
            try {
                val jsonContent = convertYamlAssetToJson(context, assetPath)
                targetJsonFile.writeText(jsonContent)
                Log.i(GatewayConstants.TAG, "[RuleSetManager] 成功将 $yamlFileName 转换为 $jsonFileName (${targetJsonFile.length()} bytes)")
            } catch (e: Exception) {
                Log.e(GatewayConstants.TAG, "[RuleSetManager] 转换规则集失败: $assetPath -> ${targetJsonFile.absolutePath}", e)
            }
        }
        Log.i(GatewayConstants.TAG, "[RuleSetManager] 4 大 RuleSet 规则集全量解析就绪 (路径: ${rulesDir.absolutePath})")
    }

    private fun convertYamlAssetToJson(context: Context, assetPath: String): String {
        val domains = mutableListOf<String>()
        val domainSuffixes = mutableListOf<String>()
        val domainKeywords = mutableListOf<String>()
        val ipCidrs = mutableListOf<String>()

        context.assets.open(assetPath).use { inputStream ->
            BufferedReader(InputStreamReader(inputStream, Charsets.UTF_8)).use { reader ->
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    var trimmed = line!!.trim()
                    if (trimmed.isEmpty() || trimmed.startsWith("#") || trimmed.startsWith("payload:")) {
                        continue
                    }
                    if (trimmed.startsWith("- ")) {
                        trimmed = trimmed.substring(2).trim()
                    }
                    // 剥离行末注释与前后引号
                    val rawClean = trimmed.split("#")[0].trim()
                    val cleanLine = rawClean.removeSurrounding("'").removeSurrounding("\"").trim()
                    if (cleanLine.isEmpty()) continue

                    val parts = cleanLine.split(",").map { it.trim() }.filter { it.isNotEmpty() }
                    if (parts.size < 2) continue

                    val ruleType = parts[0].uppercase()
                    val value = parts[1]

                    when (ruleType) {
                        "DOMAIN" -> domains.add(value)
                        "DOMAIN-SUFFIX" -> domainSuffixes.add(value.removePrefix("."))
                        "DOMAIN-KEYWORD" -> domainKeywords.add(value)
                        "IP-CIDR", "IP-CIDR6" -> ipCidrs.add(value)
                    }
                }
            }
        }

        val headlessRule = JSONObject()
        if (domains.isNotEmpty()) {
            headlessRule.put("domain", JSONArray(domains))
        }
        if (domainSuffixes.isNotEmpty()) {
            headlessRule.put("domain_suffix", JSONArray(domainSuffixes))
        }
        if (domainKeywords.isNotEmpty()) {
            headlessRule.put("domain_keyword", JSONArray(domainKeywords))
        }
        if (ipCidrs.isNotEmpty()) {
            headlessRule.put("ip_cidr", JSONArray(ipCidrs))
        }

        val rulesArray = JSONArray()
        if (headlessRule.length() > 0) {
            rulesArray.put(headlessRule)
        }

        val root = JSONObject().apply {
            put("version", 4)
            put("rules", rulesArray)
        }

        return root.toString(2)
    }
}
