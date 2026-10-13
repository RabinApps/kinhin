package com.example.androidnative

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.widget.TextView

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(
            TextView(this).apply {
                text = getString(R.string.hello)
                textSize = 24f
                setTextColor(Color.BLACK)
                gravity = Gravity.CENTER
            }
        )
    }
}
