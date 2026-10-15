package com.jadeonmesh.meshcore.atak.engine;

import android.content.Context;
import android.content.SharedPreferences;

/** Plugin settings, stored in ATAK's process under the plugin's own file. */
public final class Settings {

    public enum LinkMode {
        AUTO, APP, BLUETOOTH, USB, OFF
    }

    private final SharedPreferences p;

    public Settings(Context ctx) {
        p = ctx.getSharedPreferences("meshcore_tak", Context.MODE_PRIVATE);
    }

    public LinkMode linkMode() {
        try {
            return LinkMode.valueOf(p.getString("link_mode", LinkMode.AUTO.name()));
        } catch (IllegalArgumentException e) {
            return LinkMode.AUTO;
        }
    }

    public void setLinkMode(LinkMode m) {
        p.edit().putString("link_mode", m.name()).apply();
    }

    public String bleAddress() {
        return p.getString("ble_address", "");
    }

    public String bleName() {
        return p.getString("ble_name", "");
    }

    public void setBle(String address, String name) {
        p.edit().putString("ble_address", address).putString("ble_name", name)
                .apply();
    }

    public String usbDevice() {
        return p.getString("usb_device", "");
    }

    public void setUsbDevice(String name) {
        p.edit().putString("usb_device", name).apply();
    }

    public String appPackage() {
        return p.getString("app_package", "");
    }

    /** Team channel name chosen for the radio with this key (direct mode). */
    public String teamChannelName(String selfKeyHex) {
        return p.getString("team_ch_" + prefix(selfKeyHex), "");
    }

    public void setTeamChannelName(String selfKeyHex, String name) {
        p.edit().putString("team_ch_" + prefix(selfKeyHex), name).apply();
    }

    private static String prefix(String key) {
        return key == null ? "" : key.substring(0, Math.min(10, key.length()));
    }

    public boolean sharePosition() {
        return p.getBoolean("share_position", true);
    }

    public void setSharePosition(boolean v) {
        p.edit().putBoolean("share_position", v).apply();
    }

    /** Team status index sent with every beacon (TeamWire.STATUSES). */
    public int status() {
        return p.getInt("status", 0);
    }

    public void setStatus(int s) {
        p.edit().putInt("status", s).apply();
    }

    /** Forward GeoChat "All Chat Rooms" to the team channel. */
    public boolean bridgeAllChat() {
        return p.getBoolean("bridge_all_chat", true);
    }

    public void setBridgeAllChat(boolean v) {
        p.edit().putBoolean("bridge_all_chat", v).apply();
    }

    /** Share markers, shapes and routes the user sends in ATAK. */
    public boolean shareItems() {
        return p.getBoolean("share_items", true);
    }

    public void setShareItems(boolean v) {
        p.edit().putBoolean("share_items", v).apply();
    }

    /** Relay CoT types the compact formats can't carry, whole and compressed. */
    public boolean relayOtherCot() {
        return p.getBoolean("relay_other_cot", true);
    }

    public void setRelayOtherCot(boolean v) {
        p.edit().putBoolean("relay_other_cot", v).apply();
    }

    /** Most packets one relayed CoT event may take. */
    public int maxCotPackets() {
        return p.getInt("max_cot_packets", 6);
    }

    /** Show mesh nodes the radio knows (with a position) on the map. */
    public boolean showMeshNodes() {
        return p.getBoolean("show_mesh_nodes", true);
    }

    public void setShowMeshNodes(boolean v) {
        p.edit().putBoolean("show_mesh_nodes", v).apply();
    }

    /** Node types on the map, as bits: 1 companions, 2 repeaters, 4 rooms, 8 sensors. */
    public int meshNodeTypes() {
        return p.getInt("mesh_node_types", 15);
    }

    public void setMeshNodeTypes(int bits) {
        p.edit().putInt("mesh_node_types", bits).apply();
    }

    /** Hide nodes not heard for this many days; 0 shows all. */
    public int meshNodeMaxAgeDays() {
        return p.getInt("mesh_node_max_age_days", 7);
    }

    public void setMeshNodeMaxAgeDays(int days) {
        p.edit().putInt("mesh_node_max_age_days", days).apply();
    }

    /** Every channel on the radio (except the team channel) as an ATAK contact. */
    public boolean channelContacts() {
        return p.getBoolean("channel_contacts", true);
    }

    public void setChannelContacts(boolean v) {
        p.edit().putBoolean("channel_contacts", v).apply();
    }

    public boolean autoPlayVoice() {
        return p.getBoolean("auto_play_voice", true);
    }

    public void setAutoPlayVoice(boolean v) {
        p.edit().putBoolean("auto_play_voice", v).apply();
    }

    /** Fetch photos and clips posted on the team channel as they arrive. */
    public boolean autoFetchTeamMedia() {
        return p.getBoolean("auto_fetch_team_media", false);
    }

    public void setAutoFetchTeamMedia(boolean v) {
        p.edit().putBoolean("auto_fetch_team_media", v).apply();
    }

    /** Send voice with Mimi when available (else Codec2 1200). */
    public boolean preferMimi() {
        return p.getBoolean("prefer_mimi", true);
    }

    public void setPreferMimi(boolean v) {
        p.edit().putBoolean("prefer_mimi", v).apply();
    }

    /** Photo detail: 0 small (fewest packets) .. 2 large. */
    public int photoDetail() {
        return p.getInt("photo_detail", 1);
    }

    public void setPhotoDetail(int v) {
        p.edit().putInt("photo_detail", v).apply();
    }

    public SharedPreferences raw() {
        return p;
    }
}
