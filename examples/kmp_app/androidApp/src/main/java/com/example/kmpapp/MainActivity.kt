package com.example.kmpapp

import android.app.Activity
import android.os.Bundle
import android.widget.TextView
import java.util.Locale

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = TextView(this).apply {
            text = greeting(Locale.getDefault().language)
            textSize = 24f
            setPadding(48, 48, 48, 48)
        }
        setContentView(text)
    }
}
