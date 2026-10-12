package com.jadeonmesh.meshcore.atak.ui;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.CompoundButton;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.TextView;

/** Small helpers for building the pane in code (no layout XML to keep in sync). */
final class Ui {
    private Ui() {
    }

    static final int TEXT = 0xFFEEEEEE, DIM = 0xFFB0B0B0, ACCENT = 0xFF4FC3F7,
            CARD = 0xFF2A2F36, BUTTON = 0xFF37474F;

    static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP,
                v, c.getResources().getDisplayMetrics()));
    }

    static LinearLayout column(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    static LinearLayout row(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.HORIZONTAL);
        l.setGravity(Gravity.CENTER_VERTICAL);
        return l;
    }

    static LinearLayout card(Context c, String title) {
        LinearLayout l = column(c);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(CARD);
        bg.setCornerRadius(dp(c, 8));
        l.setBackground(bg);
        int p = dp(c, 10);
        l.setPadding(p, p, p, p);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, 0, 0, dp(c, 8));
        l.setLayoutParams(lp);
        if (title != null) {
            TextView t = text(c, title, 15, ACCENT);
            t.setTypeface(Typeface.DEFAULT_BOLD);
            t.setPadding(0, 0, 0, dp(c, 6));
            l.addView(t);
        }
        return l;
    }

    static TextView text(Context c, String s, float sp, int color) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        return t;
    }

    static TextView body(Context c, String s) {
        return text(c, s, 13, TEXT);
    }

    static TextView dim(Context c, String s) {
        return text(c, s, 12, DIM);
    }

    static Button button(Context c, String label, View.OnClickListener l) {
        Button b = new Button(c);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextColor(TEXT);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(BUTTON);
        bg.setCornerRadius(dp(c, 6));
        b.setBackground(bg);
        b.setMinHeight(dp(c, 40));
        b.setMinimumHeight(dp(c, 40));
        b.setPadding(dp(c, 10), 0, dp(c, 10), 0);
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, dp(c, 3), dp(c, 6), dp(c, 3));
        b.setLayoutParams(lp);
        return b;
    }

    static Switch toggle(Context c, String label, boolean on,
            CompoundButton.OnCheckedChangeListener l) {
        Switch s = new Switch(c);
        s.setText(label);
        s.setTextColor(TEXT);
        s.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        s.setChecked(on);
        s.setOnCheckedChangeListener(l);
        s.setPadding(0, dp(c, 4), 0, dp(c, 4));
        return s;
    }

    static View dot(Context c, int color) {
        View v = new View(c);
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        d.setColor(color);
        v.setBackground(d);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(c, 12),
                dp(c, 12));
        lp.setMargins(0, 0, dp(c, 8), 0);
        v.setLayoutParams(lp);
        return v;
    }

    static int mix(int color, float alpha) {
        return Color.argb(Math.round(alpha * 255), Color.red(color),
                Color.green(color), Color.blue(color));
    }
}
