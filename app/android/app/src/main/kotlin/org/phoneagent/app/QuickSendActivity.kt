package org.phoneagent.app

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.text.InputType
import android.widget.EditText
import android.widget.Toast


class QuickSendActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val agentId = intent.getStringExtra("agent_id") ?: ""
        val agentName = intent.getStringExtra("agent_name")?.takeIf { it.isNotEmpty() } ?: agentId

        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            hint = "发给 $agentName"
        }

        AlertDialog.Builder(this)
            .setTitle("快速发送 · $agentName")
            .setView(input)
            .setPositiveButton("发送") { _, _ ->
                val text = input.text.toString().trim()
                if (text.isNotEmpty() && agentId.isNotEmpty()) {
                    ReplyBridge.send(agentId, text)
                    Toast.makeText(this, "已发送", Toast.LENGTH_SHORT).show()
                }
                finish()
            }
            .setNegativeButton("取消") { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .show()
    }
}
