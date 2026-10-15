package com.jadeonmesh.meshcore.atak.core;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Keys seen recently: at most [capacity], each forgotten after [maxAgeMs].
 * Used to drop a direct message the sender re-sent because its
 * acknowledgement was lost (same sender, timestamp and text). Not
 * thread-safe.
 */
public final class RecentKeys {

    public interface Clock {
        long nowMs();
    }

    private final int capacity;
    private final long maxAgeMs;
    private final Clock clock;
    private final LinkedHashMap<String, Long> seen = new LinkedHashMap<>();

    public RecentKeys(int capacity, long maxAgeMs, Clock clock) {
        this.capacity = capacity;
        this.maxAgeMs = maxAgeMs;
        this.clock = clock;
    }

    public RecentKeys(int capacity, long maxAgeMs) {
        this(capacity, maxAgeMs, System::currentTimeMillis);
    }

    /** True the first time [key] is seen within the window; records it. */
    public boolean firstTime(String key) {
        trim();
        if (seen.containsKey(key))
            return false;
        seen.put(key, clock.nowMs());
        trim();
        return true;
    }

    public int size() {
        trim();
        return seen.size();
    }

    private void trim() {
        long oldest = clock.nowMs() - maxAgeMs;
        Iterator<Map.Entry<String, Long>> it = seen.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<String, Long> e = it.next();
            if (seen.size() > capacity || e.getValue() < oldest)
                it.remove();
            else
                break;
        }
    }
}
