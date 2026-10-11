package com.jadeonmesh.meshcore.atak.radio;

/** Moves whole companion frames to and from a radio (BLE or USB serial). */
public interface FrameTransport {

    interface Listener {
        void onTransportUp();

        void onFrame(byte[] frame);

        void onTransportDown(String reason);
    }

    void open(Listener l);

    /** Queues a frame; frames go out in order. */
    void send(byte[] frame);

    void close();

    String describe();
}
