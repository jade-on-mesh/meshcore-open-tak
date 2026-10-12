package com.jadeonmesh.meshcore.atak.engine;

import java.io.File;

import com.jadeonmesh.meshcore.atak.core.XNode;

/** What the engine needs from ATAK. Implemented by tak.AtakBridge. */
public interface TakSink {

    /** Injects an event into ATAK as if it had been received. */
    void dispatch(XNode event);

    void toast(String message);

    String selfUid();

    /** ATAK's own position and identity right now, or null without a fix. */
    SelfFix selfFix();

    /** Folder ATAK shows as a map item's attachments. */
    File attachmentsDir(String uid);

    /** Folder for received photos, clips and files. */
    File mediaDir();

    /** Hands a received file to ATAK's importers (data packages, KML...). */
    void importFile(File f);

    /** Engine state changed (radio, members, media): refresh widget and pane. */
    void onEngineChanged();

    final class SelfFix {
        public double lat, lon;
        public Double hae, ce, speedMps, courseDeg;
        public String callsign = "";
        public String team = "Cyan";
        public String role = "Team Member";
        public Integer battery;
        public long timeMs;
    }
}
