/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * Copyright (c) 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * Use of this source code is governed by the MIT license in media_kit_video.
 */
package com.alexmercerind.media_kit_video;

import android.os.Handler;
import android.os.Looper;
import android.view.Surface;

import java.lang.reflect.Method;

import io.flutter.view.TextureRegistry;

public final class VideoOutput {
    private static final Method newGlobalObjectRef;
    private static final Method deleteGlobalObjectRef;
    private static final Handler handler = new Handler(Looper.getMainLooper());

    static {
        try {
            Class<?> helper = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRef = helper.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRef = helper.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRef.setAccessible(true);
            deleteGlobalObjectRef.setAccessible(true);
        } catch (ReflectiveOperationException exception) {
            throw new IllegalStateException("media_kit_libs_android_video is required", exception);
        }
    }

    private final TextureUpdateCallback callback;
    private final TextureRegistry.SurfaceTextureEntry texture;
    private final Surface surface;
    private long wid;
    private int width;
    private int height;

    VideoOutput(TextureRegistry registry, TextureUpdateCallback callback) {
        this.callback = callback;
        // Retain the paused frame across backgrounding and Flutter view reattachment.
        texture = registry.createSurfaceTexture();
        surface = new Surface(texture.surfaceTexture());
    }

    public void setSurfaceSize(int width, int height) {
        if (this.width == width && this.height == height) return;
        texture.surfaceTexture().setDefaultBufferSize(width, height);
        final long next;
        try {
            // A new reference notifies the existing Dart wid listener of resize.
            next = (long) newGlobalObjectRef.invoke(null, surface);
        } catch (ReflectiveOperationException exception) {
            throw new IllegalStateException("Could not retain the video Surface", exception);
        }
        final long previous = wid;
        wid = next;
        this.width = width;
        this.height = height;
        callback.onTextureUpdate(texture.id(), wid, width, height);
        releaseReference(previous);
    }

    public void dispose() {
        // Player.dispose has stopped playback before invoking the output release.
        surface.release();
        texture.release();
        releaseReference(wid);
        wid = 0;
    }

    private static void releaseReference(long reference) {
        if (reference == 0) return;
        // Keep the dependency's grace period for mpv's native reference.
        handler.postDelayed(() -> {
            try {
                deleteGlobalObjectRef.invoke(null, reference);
            } catch (ReflectiveOperationException exception) {
                android.util.Log.e("VideoOutput", "Could not release the video Surface reference", exception);
            }
        }, 5000);
    }
}
