package com.jadeonmesh.meshcore.atak.engine;

import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/** Recent plugin events for the diagnostics view. */
public final class LogBuffer {
    private static final int MAX = 400;
    private final ArrayDeque<String> lines = new ArrayDeque<>();
    private final SimpleDateFormat fmt = new SimpleDateFormat("HH:mm:ss",
            Locale.US);

    public synchronized void add(String s) {
        lines.addLast(fmt.format(new Date()) + "  " + s);
        while (lines.size() > MAX)
            lines.removeFirst();
        android.util.Log.d("MeshCoreTAK", s);
    }

    public synchronized List<String> snapshot() {
        return new ArrayList<>(lines);
    }

    public synchronized void clear() {
        lines.clear();
    }
}
