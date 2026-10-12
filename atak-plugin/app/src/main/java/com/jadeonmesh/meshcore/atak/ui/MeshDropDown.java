package com.jadeonmesh.meshcore.atak.ui;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import android.annotation.SuppressLint;
import android.app.AlertDialog;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.view.MotionEvent;
import android.view.View;
import android.widget.Button;
import android.widget.GridView;
import android.widget.ImageView;
import android.widget.BaseAdapter;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.atakmap.android.dropdown.DropDown;
import com.atakmap.android.dropdown.DropDownReceiver;
import com.atakmap.android.importexport.CotEventFactory;
import com.atakmap.android.ipc.AtakBroadcast;
import com.atakmap.android.maps.MapEvent;
import com.atakmap.android.maps.MapEventDispatcher;
import com.atakmap.android.maps.MapItem;
import com.atakmap.android.maps.MapView;
import com.atakmap.coremap.cot.event.CotEvent;

import com.jadeonmesh.meshcore.atak.core.Companion;
import com.jadeonmesh.meshcore.atak.core.TeamWire;
import com.jadeonmesh.meshcore.atak.engine.MeshTakEngine;
import com.jadeonmesh.meshcore.atak.engine.Settings;
import com.jadeonmesh.meshcore.atak.media.AudioIO;
import com.jadeonmesh.meshcore.atak.media.LocalMedia;
import com.jadeonmesh.meshcore.atak.media.MediaBackend;
import com.jadeonmesh.meshcore.atak.media.MimiCodec;
import com.jadeonmesh.meshcore.atak.radio.AppRadio;
import com.jadeonmesh.meshcore.atak.radio.BleScanner;
import com.jadeonmesh.meshcore.atak.radio.MeshRadio;
import com.jadeonmesh.meshcore.atak.radio.UsbTransport;

/** The MeshCore pane: link, team, voice, photos, files, inbox, options, log. */
public final class MeshDropDown extends DropDownReceiver
        implements DropDown.OnStateListener {

    public static final String SHOW = "com.jadeonmesh.meshcore.atak.SHOW_PANE";

    private final Context c; // ATAK's activity context, for views and dialogs
    private final MeshTakEngine engine;
    private final Settings settings;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService bg = Executors.newSingleThreadExecutor();
    private final BleScanner scanner;

    private final ScrollView root;
    private final LinearLayout content;
    private View statusDot;
    private TextView statusText, statusDetail, linkLabel, teamLabel, voiceTarget,
            mimiLabel, pttLabel;
    private LinearLayout scanResults, inboxList, memberList, logList,
            statusRow;
    private Button pttButton;
    private boolean visible;
    private boolean logOpen;
    private MediaBackend.Target target; // null = team channel
    private String targetName = "Team channel";
    private AudioIO.Recorder recorder;

    public MeshDropDown(MapView mapView, MeshTakEngine engine) {
        super(mapView);
        this.c = mapView.getContext();
        this.engine = engine;
        this.settings = engine.settings();
        this.scanner = new BleScanner(c);
        root = new ScrollView(c);
        content = Ui.column(c);
        int p = Ui.dp(c, 10);
        content.setPadding(p, p, p, p);
        root.addView(content);
        build();
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        if (SHOW.equals(intent.getAction())) {
            refresh();
            showDropDown(root, THREE_EIGHTHS_WIDTH, FULL_HEIGHT, FULL_WIDTH,
                    HALF_HEIGHT, false, this);
        }
    }

    @Override
    protected void disposeImpl() {
        scanner.stop();
        bg.shutdown();
    }

    @Override
    public void onDropDownSelectionRemoved() {
    }

    @Override
    public void onDropDownVisible(boolean v) {
        visible = v;
        if (v)
            refresh();
    }

    @Override
    public void onDropDownSizeChanged(double w, double h) {
    }

    @Override
    public void onDropDownClose() {
        visible = false;
        scanner.stop();
    }

    // -------------------------------------------------------------- build

    private void build() {
        // Status
        LinearLayout head = Ui.card(c, null);
        LinearLayout r = Ui.row(c);
        statusDot = Ui.dot(c, StatusWidget.GREY);
        r.addView(statusDot);
        statusText = Ui.text(c, "", 16, Ui.TEXT);
        statusText.setTypeface(Typeface.DEFAULT_BOLD);
        r.addView(statusText);
        head.addView(r);
        statusDetail = Ui.dim(c, "");
        head.addView(statusDetail);
        content.addView(head);

        // Link
        LinearLayout link = Ui.card(c, "Radio link");
        linkLabel = Ui.body(c, "");
        link.addView(linkLabel);
        LinearLayout modes = Ui.row(c);
        for (Settings.LinkMode m : Settings.LinkMode.values()) {
            String label = m == Settings.LinkMode.APP ? "App"
                    : m.name().charAt(0) + m.name().substring(1).toLowerCase(Locale.US);
            modes.addView(Ui.button(c, label, v -> {
                settings.setLinkMode(m);
                engine.reconnect();
                refresh();
            }));
        }
        android.widget.HorizontalScrollView hs = new android.widget.HorizontalScrollView(c);
        hs.addView(modes);
        link.addView(hs);
        LinearLayout actions = Ui.row(c);
        actions.addView(Ui.button(c, "Find Bluetooth radios", v -> scanBle()));
        actions.addView(Ui.button(c, "USB", v -> pickUsb()));
        actions.addView(Ui.button(c, "Reconnect", v -> engine.reconnect()));
        link.addView(actions);
        scanResults = Ui.column(c);
        link.addView(scanResults);
        link.addView(Ui.dim(c, "Auto uses the MeshCore Open TAK app when it's"
                + " installed (it keeps the radio), else the radio you pick here."));
        content.addView(link);

        // Team
        LinearLayout team = Ui.card(c, "Team");
        teamLabel = Ui.body(c, "");
        team.addView(teamLabel);
        LinearLayout tr = Ui.row(c);
        tr.addView(Ui.button(c, "Team channel…", v -> pickTeamChannel()));
        tr.addView(Ui.button(c, "Send position now", v -> engine.beaconNow()));
        team.addView(tr);
        team.addView(Ui.dim(c, "My status (sent with every position):"));
        statusRow = Ui.row(c);
        android.widget.HorizontalScrollView ss = new android.widget.HorizontalScrollView(c);
        ss.addView(statusRow);
        team.addView(ss);
        memberList = Ui.column(c);
        team.addView(memberList);
        content.addView(team);

        // Voice
        LinearLayout voice = Ui.card(c, "Voice");
        voiceTarget = Ui.body(c, "");
        voice.addView(voiceTarget);
        LinearLayout vr = Ui.row(c);
        pttButton = Ui.button(c, "Hold to talk", null);
        pttButton.setOnTouchListener(this::onPtt);
        vr.addView(pttButton);
        vr.addView(Ui.button(c, "To…", v -> pickTarget()));
        vr.addView(Ui.button(c, "Stop audio", v -> AudioIO.stopPlayback()));
        voice.addView(vr);
        pttLabel = Ui.dim(c, "Up to " + LocalMedia.MAX_CLIP_SECONDS
                + " s. Clips are fetched by each listener when they play them.");
        voice.addView(pttLabel);
        mimiLabel = Ui.dim(c, "");
        voice.addView(mimiLabel);
        content.addView(voice);

        // Photos and files
        LinearLayout photos = Ui.card(c, "Photos and files");
        LinearLayout pr = Ui.row(c);
        pr.addView(Ui.button(c, "Send photo…", v -> pickPhoto(false)));
        pr.addView(Ui.button(c, "Photo on a map item…", v -> pickPhoto(true)));
        photos.addView(pr);
        LinearLayout fr = Ui.row(c);
        fr.addView(Ui.button(c, "Send small file…", v -> pickFile()));
        photos.addView(fr);
        photos.addView(Ui.dim(c, "Photos are AV1 stills sized to one or two voice"
                + " clips of airtime. Files up to ~4 KB compressed."));
        content.addView(photos);

        // Inbox
        LinearLayout inbox = Ui.card(c, "Received clips and photos");
        inboxList = Ui.column(c);
        inbox.addView(inboxList);
        content.addView(inbox);

        // Options
        LinearLayout opt = Ui.card(c, "Options");
        opt.addView(Ui.toggle(c, "Share my position", settings.sharePosition(),
                (b, on) -> settings.setSharePosition(on)));
        opt.addView(Ui.toggle(c, "All Chat ↔ team channel", settings.bridgeAllChat(),
                (b, on) -> settings.setBridgeAllChat(on)));
        opt.addView(Ui.toggle(c, "Share markers, shapes and routes I send",
                settings.shareItems(), (b, on) -> settings.setShareItems(on)));
        opt.addView(Ui.toggle(c, "Relay other CoT (casevac, etc.) compressed",
                settings.relayOtherCot(), (b, on) -> settings.setRelayOtherCot(on)));
        opt.addView(Ui.toggle(c, "Show radio contacts on the map",
                settings.showRadioContacts(),
                (b, on) -> settings.setShowRadioContacts(on)));
        opt.addView(Ui.toggle(c, "Download team clips and photos as they arrive",
                settings.autoFetchTeamMedia(),
                (b, on) -> settings.setAutoFetchTeamMedia(on)));
        opt.addView(Ui.toggle(c, "Auto-play voice", settings.autoPlayVoice(),
                (b, on) -> settings.setAutoPlayVoice(on)));
        opt.addView(Ui.toggle(c, "Send voice with Mimi (when available)",
                settings.preferMimi(), (b, on) -> settings.setPreferMimi(on)));
        opt.addView(Ui.toggle(c, "More photo detail (twice the airtime)",
                settings.photoDetail() >= 1,
                (b, on) -> settings.setPhotoDetail(on ? 1 : 0)));
        content.addView(opt);

        // Log
        LinearLayout log = Ui.card(c, "Log");
        LinearLayout lr = Ui.row(c);
        lr.addView(Ui.button(c, "Show / hide", v -> {
            logOpen = !logOpen;
            refresh();
        }));
        lr.addView(Ui.button(c, "Clear", v -> {
            engine.log.clear();
            refresh();
        }));
        log.addView(lr);
        logList = Ui.column(c);
        log.addView(logList);
        content.addView(log);
    }

    // ------------------------------------------------------------ refresh

    /** Re-reads engine state. Called on engine changes (main thread). */
    public void refresh() {
        String problem = engine.problem();
        MeshRadio r = engine.radio();
        int color = problem == null ? StatusWidget.GREEN
                : r == null ? StatusWidget.GREY
                        : r.state() == MeshRadio.State.ERROR ? StatusWidget.RED
                                : StatusWidget.AMBER;
        statusDot.setBackground(dotDrawable(color));
        statusText.setText(problem == null ? "Mesh ready" : problem);
        Companion.SelfInfo self = r == null ? null : r.self();
        statusDetail.setText(r == null ? ""
                : r.name() + (self == null ? "" : " · " + self.name)
                        + " · " + engine.beaconsSent() + " beacons sent · "
                        + engine.teamMessagesReceived() + " team messages heard");

        linkLabel.setText("Mode: " + settings.linkMode().name().toLowerCase(Locale.US)
                + (settings.bleAddress().isEmpty() ? ""
                        : " · Bluetooth: " + (settings.bleName().isEmpty()
                                ? settings.bleAddress() : settings.bleName()))
                + (settings.usbDevice().isEmpty() ? "" : " · USB: " + settings.usbDevice()));

        String ch = "none";
        if (r != null && r.teamChannel() >= 0)
            for (Companion.Channel cc : r.channels())
                if (cc.index == r.teamChannel())
                    ch = cc.name;
        teamLabel.setText("Team channel: " + ch
                + (r instanceof AppRadio ? " (set in MeshCore Open TAK)" : ""));

        statusRow.removeAllViews();
        for (int i = 0; i < TeamWire.STATUSES.length; i++) {
            final int s = i;
            String label = i == 0 ? "None" : TeamWire.STATUSES[i];
            Button b = Ui.button(c, (settings.status() == i ? "● " : "") + label, v -> {
                settings.setStatus(s);
                engine.beaconNow();
                refresh();
            });
            statusRow.addView(b);
        }

        memberList.removeAllViews();
        List<MeshTakEngine.Member> ms = engine.members();
        if (ms.isEmpty())
            memberList.addView(Ui.dim(c, "No teammates heard yet."));
        long now = System.currentTimeMillis();
        for (MeshTakEngine.Member m : ms) {
            long age = (now - m.heardMs) / 60000;
            String st = m.position.status == 0 ? "" : " · " + TeamWire.STATUSES[m.position.status];
            memberList.addView(Ui.body(c, (m.position.sosActive ? "🆘 " : "")
                    + m.callsign() + " · " + TeamWire.ROLES[m.position.role]
                    + st + " · " + (age < 1 ? "now" : age + " min ago")));
        }

        voiceTarget.setText("Voice and photos go to: " + targetName);
        MediaBackend media = engine.media();
        if (media instanceof LocalMedia) {
            MimiCodec mimi = ((LocalMedia) media).mimi();
            mimiLabel.setText(!MimiCodec.runtimeAvailable() ? "Mimi needs ONNX Runtime (not in this build); Codec2 is used."
                    : mimi.isReady() ? "Mimi voice model ready."
                            : mimi.isDownloading() ? "Downloading the Mimi model…"
                                    : "Mimi model not downloaded (" + MimiCodec.downloadMb()
                                            + " MB). Long-press here to download.");
            mimiLabel.setOnLongClickListener(v -> {
                downloadMimi((LocalMedia) media);
                return true;
            });
        } else {
            mimiLabel.setText(media == null ? "" : "Voice and photos are encoded by the MeshCore Open TAK app.");
            mimiLabel.setOnLongClickListener(null);
        }

        refreshInbox();

        logList.removeAllViews();
        if (logOpen) {
            List<String> lines = engine.log.snapshot();
            for (int i = Math.max(0, lines.size() - 80); i < lines.size(); i++)
                logList.addView(Ui.dim(c, lines.get(i)));
        }
    }

    private android.graphics.drawable.Drawable dotDrawable(int color) {
        android.graphics.drawable.GradientDrawable d = new android.graphics.drawable.GradientDrawable();
        d.setShape(android.graphics.drawable.GradientDrawable.OVAL);
        d.setColor(color);
        return d;
    }

    private void refreshInbox() {
        inboxList.removeAllViews();
        List<MeshTakEngine.MediaItem> items = engine.inbox();
        if (items.isEmpty())
            inboxList.addView(Ui.dim(c, "Nothing yet."));
        for (MeshTakEngine.MediaItem it : items) {
            LinearLayout row = Ui.row(c);
            String what = it.env.isImage() ? "📷 Photo" : "🎙 " + it.env.durationSeconds + " s";
            String state;
            switch (it.status) {
                case COMPLETE:
                    state = it.env.isImage() ? "tap to view" : "tap to play";
                    break;
                case REQUESTING:
                    state = it.message == null ? "requesting…" : it.message;
                    break;
                case RECEIVING:
                    state = it.have + "/" + it.total + " packets";
                    break;
                case UNAVAILABLE:
                    state = it.message == null ? "unavailable, tap to retry" : it.message;
                    break;
                default:
                    state = "tap to download (" + it.env.totalPackets + " packets)";
            }
            TextView t = Ui.body(c, what + (it.outgoing ? " to " : " from ")
                    + it.fromCallsign + (it.itemUid != null ? " (on a map item)" : "")
                    + "\n" + state);
            row.addView(t);
            row.setPadding(0, Ui.dp(c, 4), 0, Ui.dp(c, 4));
            row.setOnClickListener(v -> openItem(it));
            inboxList.addView(row);
        }
    }

    private void openItem(MeshTakEngine.MediaItem it) {
        if (it.status != MediaBackend.Status.COMPLETE) {
            engine.fetch(it);
            return;
        }
        if (!it.env.isImage()) {
            engine.play(it);
            return;
        }
        if (it.savedFile == null) {
            engine.fetch(it); // decodes and saves when complete
            return;
        }
        Intent i = new Intent("com.atakmap.maps.images.DISPLAY");
        i.putExtra("imageURI", Uri.fromFile(it.savedFile).toString());
        i.putExtra("title", "Photo from " + it.fromCallsign);
        if (it.itemUid != null)
            i.putExtra("uid", it.itemUid);
        AtakBroadcast.getInstance().sendBroadcast(i);
    }

    // -------------------------------------------------------------- link

    private void scanBle() {
        scanResults.removeAllViews();
        scanResults.addView(Ui.dim(c, "Scanning…"));
        scanner.scan(8000, (list, finished, error) -> main.post(() -> {
            scanResults.removeAllViews();
            if (error != null)
                scanResults.addView(Ui.dim(c, error));
            for (String[] d : list) {
                Button b = Ui.button(c, d[1] + "\n" + d[0], v -> {
                    scanner.stop();
                    settings.setBle(d[0], d[1].replace(" (paired)", "")
                            .replaceAll("\\s+-?\\d+ dBm$", ""));
                    settings.setLinkMode(Settings.LinkMode.BLUETOOTH);
                    scanResults.removeAllViews();
                    engine.reconnect();
                    refresh();
                });
                scanResults.addView(b);
            }
            if (finished && list.isEmpty() && error == null)
                scanResults.addView(Ui.dim(c, "No MeshCore radios found. Is the"
                        + " radio in companion (BLE) mode and not connected to"
                        + " another phone?"));
        }));
    }

    private void pickUsb() {
        List<String[]> devs = UsbTransport.listDevices(c);
        if (devs.isEmpty()) {
            engine.log.add("No USB devices attached");
            toast("Plug the radio into this phone's USB port (OTG) first");
            return;
        }
        String[] labels = new String[devs.size()];
        for (int i = 0; i < labels.length; i++)
            labels[i] = devs.get(i)[1] + "\n" + devs.get(i)[0];
        new AlertDialog.Builder(c).setTitle("USB radio").setItems(labels, (d, w) -> {
            settings.setUsbDevice(devs.get(w)[0]);
            settings.setLinkMode(Settings.LinkMode.USB);
            engine.reconnect();
            refresh();
        }).show();
    }

    private void pickTeamChannel() {
        MeshRadio r = engine.radio();
        if (r == null || !r.isConnected()) {
            toast("Connect a radio first");
            return;
        }
        if (r instanceof AppRadio) {
            toast("Pick the team channel in MeshCore Open TAK (Team screen)");
            return;
        }
        List<Companion.Channel> chs = new ArrayList<>();
        for (Companion.Channel ch : r.channels())
            if (ch.isPrivate())
                chs.add(ch);
        if (chs.isEmpty()) {
            toast("The radio has no private channel. Add one (with a shared"
                    + " key) in a MeshCore app first; public and #hashtag"
                    + " channels would broadcast positions to everyone.");
            return;
        }
        String[] names = new String[chs.size()];
        for (int i = 0; i < names.length; i++)
            names[i] = chs.get(i).name;
        new AlertDialog.Builder(c).setTitle("Team channel").setItems(names,
                (d, w) -> {
                    engine.setTeamChannel(chs.get(w).name);
                    main.postDelayed(this::refresh, 500);
                }).show();
    }

    // ------------------------------------------------------------- voice

    @SuppressLint("ClickableViewAccessibility")
    private boolean onPtt(View v, MotionEvent e) {
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                if (!engine.ready()) {
                    toast(engine.problem());
                    return true;
                }
                AudioIO.stopPlayback();
                recorder = new AudioIO.Recorder(LocalMedia.MAX_CLIP_SECONDS);
                String err = recorder.start();
                if (err != null) {
                    recorder = null;
                    toast(err);
                    return true;
                }
                pttButton.setText("Recording… release to send");
                tickPtt();
                return true;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                AudioIO.Recorder rec = recorder;
                recorder = null;
                pttButton.setText("Hold to talk");
                if (rec == null)
                    return true;
                short[] pcm = rec.stop();
                if (e.getActionMasked() == MotionEvent.ACTION_CANCEL
                        || pcm.length < AudioIO.RATE / 2) {
                    toast("Too short; hold the button while you talk");
                    return true;
                }
                engine.sendVoice(pcm, target);
                toast("Sending voice to " + targetName);
                return true;
            default:
                return true;
        }
    }

    private void tickPtt() {
        AudioIO.Recorder rec = recorder;
        if (rec == null)
            return;
        pttButton.setText(String.format(Locale.US, "Recording %.0f s… release to send",
                rec.seconds()));
        if (!rec.isRunning()) {
            // Hit the length limit: send what we have.
            recorder = null;
            pttButton.setText("Hold to talk");
            engine.sendVoice(rec.stop(), target);
            return;
        }
        main.postDelayed(this::tickPtt, 250);
    }

    private void pickTarget() {
        MeshRadio r = engine.radio();
        List<String> names = new ArrayList<>();
        List<MediaBackend.Target> targets = new ArrayList<>();
        names.add("Team channel");
        targets.add(null);
        if (r != null)
            for (Companion.Contact ct : r.contacts())
                if (ct.type == Companion.ADV_CHAT) {
                    names.add(ct.name + (engine.members().isEmpty() ? "" : ""));
                    targets.add(MediaBackend.Target.contact(ct.publicKey));
                }
        new AlertDialog.Builder(c).setTitle("Send voice and photos to")
                .setItems(names.toArray(new String[0]), (d, w) -> {
                    target = targets.get(w);
                    targetName = names.get(w);
                    refresh();
                }).show();
    }

    private void downloadMimi(LocalMedia lm) {
        MimiCodec mimi = lm.mimi();
        if (!MimiCodec.runtimeAvailable() || mimi.isReady() || mimi.isDownloading())
            return;
        new AlertDialog.Builder(c).setTitle("Download Mimi voice model?")
                .setMessage("About " + MimiCodec.downloadMb() + " MB from GitHub. Mimi"
                        + " sounds far better than Codec2 at the same airtime and is"
                        + " what MeshCore Open TAK sends by default.")
                .setPositiveButton("Download", (d, w) -> bg.execute(() -> {
                    String err = mimi.download(f -> main.post(() -> mimiLabel.setText(
                            String.format(Locale.US, "Downloading Mimi… %.0f%%", f * 100))));
                    main.post(() -> {
                        toast(err == null ? "Mimi model ready" : "Mimi download failed: " + err);
                        refresh();
                    });
                })).setNegativeButton("Cancel", null).show();
    }

    // ------------------------------------------------------------ photos

    private void pickPhoto(boolean attach) {
        bg.execute(() -> {
            List<Uri> uris = recentImages(c.getContentResolver(), 40);
            List<Bitmap> thumbs = new ArrayList<>();
            for (Uri u : uris)
                thumbs.add(thumbnail(c.getContentResolver(), u, 160));
            main.post(() -> showPhotoGrid(uris, thumbs, attach));
        });
    }

    private void showPhotoGrid(List<Uri> uris, List<Bitmap> thumbs, boolean attach) {
        if (uris.isEmpty()) {
            toast("No photos found on this phone");
            return;
        }
        GridView g = new GridView(c);
        g.setNumColumns(3);
        int size = Ui.dp(c, 96);
        g.setAdapter(new BaseAdapter() {
            public int getCount() {
                return uris.size();
            }

            public Object getItem(int i) {
                return uris.get(i);
            }

            public long getItemId(int i) {
                return i;
            }

            public View getView(int i, View conv, android.view.ViewGroup parent) {
                ImageView iv = conv instanceof ImageView ? (ImageView) conv : new ImageView(c);
                iv.setLayoutParams(new GridView.LayoutParams(size, size));
                iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
                iv.setImageBitmap(thumbs.get(i));
                return iv;
            }
        });
        AlertDialog dlg = new AlertDialog.Builder(c)
                .setTitle(attach ? "Photo to attach" : "Photo to send to " + targetName)
                .setView(g).setNegativeButton("Cancel", null).create();
        g.setOnItemClickListener((p, v, i, id) -> {
            dlg.dismiss();
            bg.execute(() -> {
                byte[] bytes = readAll(c.getContentResolver(), uris.get(i));
                main.post(() -> {
                    if (bytes == null) {
                        toast("Couldn't read that photo");
                        return;
                    }
                    if (attach)
                        attachToItem(bytes);
                    else {
                        engine.sendImage(bytes, target);
                        toast("Encoding photo for the mesh…");
                    }
                });
            });
        });
        dlg.show();
    }

    private void attachToItem(byte[] image) {
        MapEventDispatcher d = getMapView().getMapEventDispatcher();
        toast("Tap the marker to attach the photo to");
        d.pushListeners();
        d.clearListeners(MapEvent.ITEM_CLICK);
        d.clearListeners(MapEvent.MAP_CLICK);
        MapEventDispatcher.MapEventDispatchListener l = event -> {
            d.popListeners();
            if (!MapEvent.ITEM_CLICK.equals(event.getType()))
                return;
            MapItem item = event.getItem();
            if (item == null)
                return;
            CotEvent ev = CotEventFactory.createCotEvent(item);
            if (ev == null || !ev.isValid()) {
                toast("That item can't be shared");
                return;
            }
            engine.sharePointWithPhoto(item.getUID(), ev.toString(), image);
            toast("Sharing " + item.getTitle() + " with the photo attached");
        };
        d.addMapEventListener(MapEvent.ITEM_CLICK, l);
        d.addMapEventListener(MapEvent.MAP_CLICK, l);
    }

    static List<Uri> recentImages(ContentResolver cr, int max) {
        List<Uri> out = new ArrayList<>();
        String[] cols = { MediaStore.Images.Media._ID };
        try (Cursor cur = cr.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                cols, null, null, MediaStore.Images.Media.DATE_ADDED + " DESC")) {
            while (cur != null && cur.moveToNext() && out.size() < max)
                out.add(Uri.withAppendedPath(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        String.valueOf(cur.getLong(0))));
        } catch (RuntimeException ignored) {
        }
        return out;
    }

    static Bitmap thumbnail(ContentResolver cr, Uri u, int side) {
        try {
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            try (InputStream in = cr.openInputStream(u)) {
                BitmapFactory.decodeStream(in, null, o);
            }
            int s = 1;
            while (Math.max(o.outWidth, o.outHeight) / (s * 2) >= side)
                s *= 2;
            BitmapFactory.Options d = new BitmapFactory.Options();
            d.inSampleSize = s;
            try (InputStream in = cr.openInputStream(u)) {
                return BitmapFactory.decodeStream(in, null, d);
            }
        } catch (Exception e) {
            return null;
        }
    }

    static byte[] readAll(ContentResolver cr, Uri u) {
        try (InputStream in = cr.openInputStream(u)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
                if (out.size() > 40 * 1024 * 1024)
                    return null;
            }
            return out.toByteArray();
        } catch (Exception e) {
            return null;
        }
    }

    // ------------------------------------------------------------- files

    private void pickFile() {
        List<File> files = new ArrayList<>();
        File[] dirs = { Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS),
                com.atakmap.coremap.filesystem.FileSystemUtils.getItem("export"),
                com.atakmap.coremap.filesystem.FileSystemUtils.getItem("tools/meshcore/outbox") };
        for (File d : dirs) {
            File[] fs = d == null ? null : d.listFiles();
            if (fs == null)
                continue;
            for (File f : fs)
                if (f.isFile() && f.length() > 0 && f.length() <= 64 * 1024)
                    files.add(f);
        }
        if (files.isEmpty()) {
            toast("No small files in Download, atak/export or atak/tools/meshcore/outbox");
            return;
        }
        String[] names = new String[files.size()];
        for (int i = 0; i < names.length; i++)
            names[i] = files.get(i).getName() + "  (" + files.get(i).length() + " B)";
        new AlertDialog.Builder(c).setTitle("Send to the team").setItems(names,
                (d, w) -> engine.sendFile(files.get(w))).show();
    }

    private void toast(String s) {
        android.widget.Toast.makeText(c, s, android.widget.Toast.LENGTH_LONG).show();
    }

    public boolean isShowing() {
        return visible;
    }
}
