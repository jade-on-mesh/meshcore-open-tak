package com.jadeonmesh.meshcore.atak.media;

import com.jadeonmesh.meshcore.atak.core.TeamWire;
import com.jadeonmesh.meshcore.atak.core.VoiceWire;

/**
 * Voice clips and photos. Direct mode runs codecs and the VE3 fetch/serve
 * protocol in the plugin ({@link LocalMedia}); app mode asks the MeshCore
 * Open TAK app to do it ({@link AppMedia}), since the app already holds the
 * radio and serves the clips it sent.
 */
public interface MediaBackend {

    /** Where a clip is announced. Exactly one of channel / contactKey. */
    final class Target {
        public final int channel;
        public final byte[] contactKey;

        private Target(int channel, byte[] contactKey) {
            this.channel = channel;
            this.contactKey = contactKey;
        }

        public static Target channel(int ch) {
            return new Target(ch, null);
        }

        public static Target contact(byte[] key) {
            return new Target(-1, key);
        }

        public boolean isChannel() {
            return contactKey == null;
        }
    }

    enum Status {
        IDLE, REQUESTING, RECEIVING, COMPLETE, UNAVAILABLE
    }

    interface Listener {
        void onClipChanged(String sid, Status status, int have, int total,
                String message);
    }

    interface SendDone {
        /** env is null on failure, with a reason in message. */
        void done(VoiceWire.Envelope env, String message);
    }

    interface AttachDone {
        void done(TeamWire.Attachment att, String message);
    }

    interface AudioDone {
        /** Mono PCM at [rate] Hz, or null. */
        void done(short[] pcm, int rate, String message);
    }

    interface ImageDone {
        /** JPEG bytes, or null. */
        void done(byte[] jpeg, String message);
    }

    void setListener(Listener l);

    void start();

    void stop();

    boolean canSendVoice();

    boolean canSendImages();

    /** Codecs this side can decode. */
    boolean canPlay(VoiceWire.Mode mode);

    /** Encodes a 48 kHz mono recording and announces it to [t]. */
    void sendVoice(short[] pcm48k, Target t, SendDone done);

    /** Encodes a JPEG/PNG and announces it to [t]. */
    void sendImage(byte[] imageBytes, Target t, int detail, SendDone done);

    /** Encodes and keeps a clip ready to serve, for a pin attachment. */
    void registerImage(byte[] imageBytes, int detail, AttachDone done);

    void registerVoice(short[] pcm48k, AttachDone done);

    /**
     * An envelope seen in chat (or on a pin). senderKey may be a 6-byte
     * prefix or null; channel is -1 for DMs.
     */
    void onEnvelope(VoiceWire.Envelope env, String senderKeyHex, int channel);

    /** Starts or retries downloading the clip. */
    void fetch(VoiceWire.Envelope env, String senderKeyHex, int channel);

    Status status(String sid);

    void audio(VoiceWire.Envelope env, AudioDone done);

    void image(VoiceWire.Envelope env, ImageDone done);

    // Direct-mode plumbing (no-ops in app mode).

    void onRawData(byte[] payload);

    void onChannelData(int channel, byte[] payload);

    /** True if the text was a VR3 request (consumed, not shown). */
    boolean onDirectControlText(String senderPrefixHex, String text);
}
