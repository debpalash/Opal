package com.debpalash.opal;

import android.content.Intent;
import android.database.Cursor;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.view.DisplayCutout;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowManager;

import org.libsdl.app.SDLActivity;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.UUID;

public class OpalActivity extends SDLActivity {
    private static final int REQUEST_PICK = 0x0a11;

    static native void nativeSetInsets(float top, float bottom, float left, float right, float ime);
    static native boolean nativeOpenMedia(String pathOrUrl);

    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL3", "main" };
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Window window = getWindow();
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (Build.VERSION.SDK_INT >= 28) {
            window.getAttributes().layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        }
        if (Build.VERSION.SDK_INT >= 30) window.setDecorFitsSystemWindows(false);
        hideBars();
        final View decor = window.getDecorView();
        decor.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                float top = 0, bottom = 0, left = 0, right = 0, ime = 0;
                if (Build.VERSION.SDK_INT >= 28) {
                    DisplayCutout cutout = insets.getDisplayCutout();
                    if (cutout != null) {
                        top = cutout.getSafeInsetTop();
                        bottom = cutout.getSafeInsetBottom();
                        left = cutout.getSafeInsetLeft();
                        right = cutout.getSafeInsetRight();
                    }
                }
                if (Build.VERSION.SDK_INT >= 30) {
                    Insets i = insets.getInsets(WindowInsets.Type.ime());
                    ime = i.bottom;
                }
                try {
                    nativeSetInsets(top, bottom, left, right, ime);
                } catch (UnsatisfiedLinkError ignored) {
                    // Native library not loaded yet; the next insets pass reports again.
                }
                return v.onApplyWindowInsets(insets);
            }
        });
        decor.requestApplyInsets();
        handleIntent(getIntent());
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideBars();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleIntent(intent);
    }

    @SuppressWarnings("deprecation")
    private void hideBars() {
        getWindow().getDecorView().setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    private void handleIntent(Intent intent) {
        if (intent == null || !Intent.ACTION_VIEW.equals(intent.getAction())) return;
        final Uri uri = intent.getData();
        if (uri == null) return;
        String scheme = uri.getScheme();
        if (scheme == null) return;
        if (scheme.equals("magnet") || scheme.equals("http") || scheme.equals("https")) {
            deliver(uri.toString());
        } else if (scheme.equals("file")) {
            String path = uri.getPath();
            if (path != null) deliver(path);
        } else if (scheme.equals("content")) {
            copyAndDeliver(uri);
        }
    }

    private void deliver(final String location) {
        // Retry briefly: native code may still be loading on a cold start.
        new Thread(new Runnable() {
            @Override
            public void run() {
                for (int i = 0; i < 50; i++) {
                    try {
                        if (nativeOpenMedia(location)) return;
                    } catch (UnsatisfiedLinkError ignored) {
                    }
                    try { Thread.sleep(200); } catch (InterruptedException e) { return; }
                }
            }
        }, "opal-open-media").start();
    }

    /** Called from native code (JNI instance call) to show the system file picker. */
    public void pickFile() {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                intent.addCategory(Intent.CATEGORY_OPENABLE);
                intent.setType("*/*");
                intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[] {
                    "video/*", "audio/*", "application/pdf", "application/epub+zip",
                    "application/zip", "application/x-bittorrent",
                    "application/vnd.comicbook+zip", "application/vnd.comicbook-rar",
                    "application/x-cbz", "application/x-cbr",
                    "application/vnd.apple.mpegurl", "application/x-mpegURL", "audio/x-mpegurl"
                });
                try {
                    startActivityForResult(intent, REQUEST_PICK);
                } catch (Exception ignored) {
                }
            }
        });
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_PICK) {
            super.onActivityResult(requestCode, resultCode, data);
            return;
        }
        if (resultCode != RESULT_OK || data == null || data.getData() == null) return;
        copyAndDeliver(data.getData());
    }

    private void copyAndDeliver(final Uri uri) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                String path = copyToMedia(uri);
                if (path != null) deliver(path);
            }
        }, "opal-import").start();
    }

    private String displayName(Uri uri) {
        String name = null;
        try (Cursor c = getContentResolver().query(uri, new String[] { OpenableColumns.DISPLAY_NAME }, null, null, null)) {
            if (c != null && c.moveToFirst()) name = c.getString(0);
        } catch (Exception ignored) {
        }
        if (name == null || name.isEmpty()) name = uri.getLastPathSegment();
        if (name == null || name.isEmpty()) name = "media";
        return name.replaceAll("[\\\\/:*?\"<>|\\x00-\\x1f]", "_");
    }

    private String copyToMedia(Uri uri) {
        File base = getExternalFilesDir("Media");
        if (base == null) base = new File(getFilesDir(), "Media");
        if (!base.exists() && !base.mkdirs()) return null;
        File out = new File(base, UUID.randomUUID() + "-" + displayName(uri));
        try (InputStream in = getContentResolver().openInputStream(uri);
             OutputStream os = new FileOutputStream(out)) {
            if (in == null) return null;
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
        } catch (Exception e) {
            out.delete();
            return null;
        }
        return out.getAbsolutePath();
    }
}
