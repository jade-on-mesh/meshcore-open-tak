package com.jadeonmesh.meshcore.atak.radio;

import java.util.List;

import com.jadeonmesh.meshcore.atak.core.Companion;

/**
 * What the plugin needs from a MeshCore radio, whichever way it is reached:
 * directly over BLE/USB ({@link DirectRadio}) or through the MeshCore Open TAK
 * app ({@link AppRadio}). Methods may be called from any thread; listener
 * callbacks arrive on the radio's own worker thread.
 */
public interface MeshRadio {

    enum State {
        OFF, CONNECTING, CONNECTED, ERROR
    }

    interface Listener {
        void onStateChanged(State state, String detail);

        /** Self info, contacts or channels changed. */
        void onRadioInfoChanged();

        /** GRP_DATA on any channel. hops is -1 when unknown. */
        void onChannelData(int channel, int dataType, byte[] payload, int hops);

        /** "name: text" channel message, already split. */
        void onChannelText(int channel, String senderName, String text,
                long timestampSec, int hops);

        /** A direct (DM) text. senderPrefix is the first 6 key bytes, hex. */
        void onDirectText(String senderPrefixHex, String text, long timestampSec);

        /** Raw data on a direct path (voice packets, fetch requests). */
        void onRawData(byte[] payload);

        /**
         * App mode only: a team payload the app already handled (received or
         * sent by the app itself). own = this phone's radio sent it.
         */
        void onTeamPayload(byte[] payload, boolean own);
    }

    /** Result callback. message is null on success. */
    interface Done {
        void done(boolean ok, String message);
    }

    String name();

    void setListener(Listener l);

    void start();

    void stop();

    State state();

    String stateDetail();

    boolean isConnected();

    /** Null until known. */
    Companion.SelfInfo self();

    List<Companion.Channel> channels();

    List<Companion.Contact> contacts();

    boolean supportsChannelData();

    /** The team channel index, or -1. */
    int teamChannel();

    /**
     * True when the app handles this phone's team identity: it beacons the
     * position and stores own items, so the plugin hands them over instead.
     */
    boolean appOwnsTeam();

    /** Sends blobs as GRP_DATA, one at a time, gapMs apart. */
    void sendChannelData(int channel, int dataType, List<byte[]> blobs,
            long gapMs, Done done);

    void sendChannelText(int channel, String text, Done done);

    void sendDirectText(byte[] pubKey, String text, Done done);

    /** How a chat message from {@link #sendChatText} ended. */
    enum ChatOutcome {
        /** The recipient acknowledged it. */
        DELIVERED,
        /** Handed to the MeshCore Open TAK app, which retries on its own. */
        SENT,
        /** Sent, but no acknowledgement after every try; it may still have arrived. */
        UNCONFIRMED,
        /** Not sent: not connected, too many waiting, or not a radio contact. */
        REFUSED
    }

    interface ChatResult {
        /** Called once. message explains REFUSED and UNCONFIRMED. */
        void onResult(ChatOutcome outcome, String message);
    }

    /**
     * A typed chat message to a contact. Direct mode waits for the
     * recipient's acknowledgement and tries up to three times (the last as
     * a flood), as the MeshCore apps do; app mode hands it to the app.
     */
    default void sendChatText(byte[] pubKey, String text, ChatResult result) {
        sendDirectText(pubKey, text, (ok, msg) -> result.onResult(
                ok ? ChatOutcome.SENT : ChatOutcome.REFUSED, msg));
    }

    /**
     * Nodes the radio heard advertise but hasn't saved as contacts (radios
     * set to add contacts manually). For the map only: they can't be
     * messaged until saved.
     */
    default List<Companion.Contact> heard() {
        return java.util.Collections.emptyList();
    }

    /** Direct-path raw data. Unsupported in app mode. */
    void sendRawData(byte[] path, byte[] payload, Done done);

    /** Forget the stored route so the next DM floods. */
    void resetPath(byte[] pubKey, Done done);

    /**
     * Team payload(s) for the team channel. Direct mode sends them as
     * GRP_DATA; app mode hands them to the app, which records own items.
     */
    void sendTeam(List<byte[]> blobs, long gapMs, Done done);

    /** App mode: the ATAK user's identity and fix for the app's beacon. */
    void publishSelf(byte[] positionPayload);

    /** Re-read contacts from the radio. */
    void refreshContacts();
}
