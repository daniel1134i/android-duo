package com.androidduo.client;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

@SuppressWarnings("deprecation")
public class MainActivity extends Activity {

    private static final String DEFAULT_URL = "http://127.0.0.1:3000/?pwa=1";
    private static final long RETRY_INTERVAL_MS = 1500;
    private static final long BACK_PRESS_EXIT_WINDOW_MS = 2000;

    private WebView webView;
    private FrameLayout rootLayout;
    private FrameLayout customViewContainer;
    private LinearLayout connectingOverlay;
    private TextView statusTextView;
    private TextView subStatusTextView;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean isConnected = false;
    private boolean hasError = false;
    private boolean isRetrying = false;
    private long lastBackPressedTime = 0;
    private Toast exitToast;
    private String serverUrl = DEFAULT_URL;

    private final Runnable retryRunnable = new Runnable() {
        @Override
        public void run() {
            if (isFinishing() || isDestroyed()) return;
            if (!isConnected) {
                if (subStatusTextView != null) {
                    subStatusTextView.setText("Retrying connection to " + serverUrl + "...");
                }
                webView.loadUrl(serverUrl);
                // Reschedule next attempt in case network hangs without triggering error callback immediately
                handler.postDelayed(this, RETRY_INTERVAL_MS);
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // Keep screen on continuously for display streaming
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        // Render under display notch / camera cutout on Android P+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WindowManager.LayoutParams layoutParams = getWindow().getAttributes();
            layoutParams.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            getWindow().setAttributes(layoutParams);
        }

        // Apply sticky immersive fullscreen
        applyImmersiveSticky();

        // Check for custom URL passed via Intent extra
        if (getIntent() != null && getIntent().hasExtra("url")) {
            String passedUrl = getIntent().getStringExtra("url");
            if (passedUrl != null && !passedUrl.trim().isEmpty()) {
                serverUrl = passedUrl.trim();
            }
        }

        buildUserInterface();
        configureWebView();

        // Start loading server
        showConnectingScreen("Connecting to Mac…");
        startReconnecting();
    }

    private void buildUserInterface() {
        rootLayout = new FrameLayout(this);
        rootLayout.setLayoutParams(new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
        ));
        rootLayout.setBackgroundColor(Color.parseColor("#090d16"));

        // 1. Hardware-accelerated WebView
        webView = new WebView(this);
        webView.setLayoutParams(new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
        ));
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null);
        webView.setBackgroundColor(Color.parseColor("#090d16"));
        webView.setOverScrollMode(View.OVER_SCROLL_NEVER);
        rootLayout.addView(webView);

        // 2. Fullscreen custom view container (for WebChromeClient)
        customViewContainer = new FrameLayout(this);
        customViewContainer.setLayoutParams(new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
        ));
        customViewContainer.setBackgroundColor(Color.BLACK);
        customViewContainer.setVisibility(View.GONE);
        rootLayout.addView(customViewContainer);

        // 3. Sleek high-tech dark overlay for connecting / reconnecting
        connectingOverlay = new LinearLayout(this);
        connectingOverlay.setLayoutParams(new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
        ));
        connectingOverlay.setOrientation(LinearLayout.VERTICAL);
        connectingOverlay.setGravity(Gravity.CENTER);
        connectingOverlay.setBackgroundColor(Color.parseColor("#0b0f19"));
        connectingOverlay.setClickable(true); // Prevent clicks passing to webview while disconnected

        // App Icon
        ImageView iconView = new ImageView(this);
        int iconSize = dpToPx(72);
        LinearLayout.LayoutParams iconParams = new LinearLayout.LayoutParams(iconSize, iconSize);
        iconParams.bottomMargin = dpToPx(20);
        iconView.setLayoutParams(iconParams);
        iconView.setImageResource(R.drawable.icon);
        connectingOverlay.addView(iconView);

        // Title: Android Duo
        TextView titleView = new TextView(this);
        titleView.setText("Android Duo");
        titleView.setTextColor(Color.WHITE);
        titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
        titleView.setTypeface(Typeface.create("sans-serif-medium", Typeface.BOLD));
        titleView.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        titleParams.bottomMargin = dpToPx(8);
        connectingOverlay.addView(titleView, titleParams);

        // Connecting Status label
        statusTextView = new TextView(this);
        statusTextView.setText("Connecting to Mac…");
        statusTextView.setTextColor(Color.parseColor("#00e5ff")); // Neon cyan accent
        statusTextView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        statusTextView.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
        statusTextView.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams statusParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        statusParams.bottomMargin = dpToPx(24);
        connectingOverlay.addView(statusTextView, statusParams);

        // Sleek subtle spinner
        ProgressBar spinner = new ProgressBar(this);
        int spinnerSize = dpToPx(36);
        LinearLayout.LayoutParams spinnerParams = new LinearLayout.LayoutParams(spinnerSize, spinnerSize);
        spinnerParams.bottomMargin = dpToPx(20);
        spinner.setLayoutParams(spinnerParams);
        spinner.setIndeterminate(true);
        connectingOverlay.addView(spinner);

        // Sub-status / helper text
        subStatusTextView = new TextView(this);
        subStatusTextView.setText("Searching for host on " + serverUrl);
        subStatusTextView.setTextColor(Color.parseColor("#6e7681"));
        subStatusTextView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        subStatusTextView.setGravity(Gravity.CENTER);
        connectingOverlay.addView(subStatusTextView);

        rootLayout.addView(connectingOverlay);
        setContentView(rootLayout);
    }

    private void configureWebView() {
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setMediaPlaybackRequiresUserGesture(false);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            settings.setOffscreenPreRaster(true);
        }

        // Additional performance & compatibility tunings
        settings.setAllowFileAccess(true);
        settings.setAllowContentAccess(true);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);
        settings.setDisplayZoomControls(false);
        settings.setSupportZoom(false);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            settings.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        }

        // WebViewClient with auto-reconnect logic
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                super.onPageStarted(view, url, favicon);
                hasError = false;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                if (!hasError) {
                    isConnected = true;
                    stopReconnecting();
                    hideConnectingScreen();
                }
            }

            @Override
            public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
                super.onReceivedError(view, errorCode, description, failingUrl);
                handlePageError();
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                super.onReceivedError(view, request, error);
                if (request.isForMainFrame()) {
                    handlePageError();
                }
            }
        });

        // WebChromeClient to handle fullscreen video/canvas requests
        webView.setWebChromeClient(new WebChromeClient() {
            private View activeCustomView;
            private CustomViewCallback activeCustomViewCallback;

            @Override
            public void onShowCustomView(View view, CustomViewCallback callback) {
                if (activeCustomView != null) {
                    callback.onCustomViewHidden();
                    return;
                }
                activeCustomView = view;
                activeCustomViewCallback = callback;
                customViewContainer.addView(view, new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                ));
                customViewContainer.setVisibility(View.VISIBLE);
                webView.setVisibility(View.GONE);
                applyImmersiveSticky();
            }

            @Override
            public void onHideCustomView() {
                if (activeCustomView == null) return;
                customViewContainer.removeView(activeCustomView);
                customViewContainer.setVisibility(View.GONE);
                webView.setVisibility(View.VISIBLE);
                if (activeCustomViewCallback != null) {
                    activeCustomViewCallback.onCustomViewHidden();
                    activeCustomViewCallback = null;
                }
                activeCustomView = null;
                applyImmersiveSticky();
            }
        });
    }

    private void handlePageError() {
        hasError = true;
        isConnected = false;
        showConnectingScreen("Reconnecting to Mac…");
        startReconnecting();
    }

    private void startReconnecting() {
        if (!isRetrying) {
            isRetrying = true;
            handler.removeCallbacks(retryRunnable);
            handler.post(retryRunnable);
        }
    }

    private void stopReconnecting() {
        isRetrying = false;
        handler.removeCallbacks(retryRunnable);
    }

    private void showConnectingScreen(String message) {
        if (statusTextView != null) {
            statusTextView.setText(message);
        }
        if (connectingOverlay != null) {
            connectingOverlay.setVisibility(View.VISIBLE);
            connectingOverlay.setAlpha(1.0f);
        }
    }

    private void hideConnectingScreen() {
        if (connectingOverlay != null && connectingOverlay.getVisibility() == View.VISIBLE) {
            connectingOverlay.animate()
                    .alpha(0.0f)
                    .setDuration(280)
                    .withEndAction(new Runnable() {
                        @Override
                        public void run() {
                            connectingOverlay.setVisibility(View.GONE);
                        }
                    })
                    .start();
        }
    }

    private void applyImmersiveSticky() {
        View decorView = getWindow().getDecorView();
        int flags = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_FULLSCREEN;
        decorView.setSystemUiVisibility(flags);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            applyImmersiveSticky();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        applyImmersiveSticky();
        if (webView != null) {
            webView.onResume();
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (webView != null) {
            webView.onPause();
        }
    }

    @Override
    protected void onDestroy() {
        stopReconnecting();
        handler.removeCallbacksAndMessages(null);
        if (webView != null) {
            webView.destroy();
        }
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        // Double-tap back button to exit (prevents accidental gestures from terminating display stream)
        long currentTime = System.currentTimeMillis();
        if (currentTime - lastBackPressedTime < BACK_PRESS_EXIT_WINDOW_MS) {
            if (exitToast != null) {
                exitToast.cancel();
            }
            super.onBackPressed();
            return;
        }

        lastBackPressedTime = currentTime;
        exitToast = Toast.makeText(this, "Press back again to exit Android Duo", Toast.LENGTH_SHORT);
        exitToast.show();
    }

    private int dpToPx(int dp) {
        return (int) TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP,
                dp,
                getResources().getDisplayMetrics()
        );
    }
}
