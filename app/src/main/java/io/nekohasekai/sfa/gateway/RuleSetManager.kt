package io.nekohasekai.sfa.gateway

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream

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

    fun ensureRuleSets(context: Context) {
        val rulesDir = getRulesDir(context)
        for (fileName in GatewayConstants.ALL_RULE_SET_FILES) {
            val targetFile = File(rulesDir, fileName)
            val assetPath = "$ASSETS_RULES_DIR/$fileName"
            try {
                context.assets.open(assetPath).use { input ->
                    val assetBytes = input.readBytes()
                    if (!targetFile.exists() || targetFile.length() != assetBytes.size.toLong()) {
                        FileOutputStream(targetFile).use { output ->
                            output.write(assetBytes)
                        }
                        Log.i(GatewayConstants.TAG, "Synchronized rule set: $fileName")
                    }
                }
            } catch (e: Exception) {
                Log.e(GatewayConstants.TAG, "Failed to copy asset $assetPath to ${targetFile.absolutePath}", e)
            }
        }
    }
}
