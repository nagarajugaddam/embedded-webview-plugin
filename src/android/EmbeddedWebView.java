package com.cb4rr.cordova.plugin;

import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaInterface;
import org.apache.cordova.CordovaWebView;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebSettings;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.os.Message;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.util.Log;

import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

public class EmbeddedWebView extends CordovaPlugin {

    private static final String TAG = "EmbeddedWebView";
    private WebView embeddedWebView;
    private ProgressBar progressBar;
    private org.apache.cordova.CordovaWebView cordovaWebView;
    private boolean canGoBack = false;
    private boolean canGoForward = false;

    @Override
    public void initialize(CordovaInterface cordova, CordovaWebView webView) {
        super.initialize(cordova, webView);
        this.cordovaWebView = webView;
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext)
            throws JSONException {

        if (action.equals("create")) {
            String url = args.getString(0);
            JSONObject options = args.getJSONObject(1);
            this.create(url, options, callbackContext);
            return true;
        }

        if (action.equals("destroy")) {
            this.destroy(callbackContext);
            return true;
        }

        if (action.equals("loadUrl")) {
            String url = args.getString(0);
            JSONObject headers = args.optJSONObject(1);
            this.loadUrl(url, headers, callbackContext);
            return true;
        }

        if (action.equals("executeScript")) {
            String script = args.getString(0);
            this.executeScript(script, callbackContext);
            return true;
        }

        if (action.equals("setVisible")) {
            boolean visible = args.getBoolean(0);
            this.setVisible(visible, callbackContext);
            return true;
        }

        if (action.equals("reload")) {
            this.reload(callbackContext);
            return true;
        }

        if (action.equals("goBack")) {
            this.goBack(callbackContext);
            return true;
        }

        if (action.equals("goForward")) {
            this.goForward(callbackContext);
            return true;
        }

        return false;
    }

    public boolean onBackPressed() {
        if (embeddedWebView != null && embeddedWebView.canGoBack()) {
            cordova.getActivity().runOnUiThread(() -> {
                embeddedWebView.goBack();
                Log.d(TAG, "Back button intercepted - navigated back in WebView");
            });
            return true;
        }
        return false;
    }

    private void create(final String url, final JSONObject options, final CallbackContext callbackContext) {
        Log.d(TAG, "Creating WebView");

        if (embeddedWebView != null) {
            Log.w(TAG, "WebView already exists, destroying before creating a new one");
            destroy(callbackContext);
        }

        cordova.getActivity().runOnUiThread(() -> {
            try {
                int topOffset = options.optInt("top", 0);
                int bottomOffset = options.optInt("bottom", 0);

                Log.d(TAG, "WebView config - URL: " + url);
                Log.d(TAG, "User offsets - Top: " + topOffset + "px, Bottom: " + bottomOffset + "px");

                ViewGroup decorView = (ViewGroup) cordova.getActivity().getWindow().getDecorView();
                int safeTop = 0;
                int safeBottom = 0;

                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                    WindowInsets insets = decorView.getRootWindowInsets();
                    if (insets != null) {
                        View cordovaView = cordovaWebView.getView();
                        boolean cordovaConsumesInsets = cordovaView.getFitsSystemWindows();

                        if (!cordovaConsumesInsets) {
                            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                                android.view.DisplayCutout cutout = insets.getDisplayCutout();
                                if (cutout != null) {
                                    safeTop = cutout.getSafeInsetTop();
                                    safeBottom = cutout.getSafeInsetBottom();
                                }
                            }
                            safeTop = Math.max(safeTop, insets.getSystemWindowInsetTop());
                            safeBottom = Math.max(safeBottom, insets.getSystemWindowInsetBottom());
                        }
                    }
                }

                Log.d(TAG, "Safe area insets - Top: " + safeTop + "px, Bottom: " + safeBottom + "px");

                int finalTopMargin = safeTop + topOffset;
                int finalBottomMargin = safeBottom + bottomOffset;

                Log.d(TAG, "Final margins - Top: " + finalTopMargin + "px, Bottom: " + finalBottomMargin + "px");

                FrameLayout webViewContainer = new FrameLayout(cordova.getActivity());

                embeddedWebView = new WebView(cordova.getActivity());

                WebSettings settings = embeddedWebView.getSettings();
                settings.setJavaScriptEnabled(true);
                settings.setDomStorageEnabled(true);
                settings.setDatabaseEnabled(true);
                settings.setAllowFileAccess(true);
                settings.setAllowContentAccess(true);
                settings.setLoadWithOverviewMode(true);
                settings.setUseWideViewPort(true);
                // allow window.open and multiple windows so onCreateWindow can be called
                settings.setJavaScriptCanOpenWindowsAutomatically(true);
                settings.setSupportMultipleWindows(true);

                if (options.optBoolean("enableZoom", false)) {
                    settings.setBuiltInZoomControls(true);
                    settings.setDisplayZoomControls(false);
                }

                if (options.optBoolean("clearCache", false)) {
                    embeddedWebView.clearCache(true);
                }

                if (options.has("userAgent")) {
                    settings.setUserAgentString(options.getString("userAgent"));
                }

                // Performance
                settings.setRenderPriority(WebSettings.RenderPriority.HIGH);
                settings.setCacheMode(WebSettings.LOAD_DEFAULT);
                settings.setEnableSmoothTransition(true);

                embeddedWebView.setLayerType(View.LAYER_TYPE_HARDWARE, null);

                // Scrollbars
                embeddedWebView.setVerticalScrollBarEnabled(false);
                embeddedWebView.setHorizontalScrollBarEnabled(false);
                embeddedWebView.setScrollbarFadingEnabled(true);
                embeddedWebView.setOverScrollMode(WebView.OVER_SCROLL_NEVER);
                embeddedWebView.setScrollBarStyle(View.SCROLLBARS_INSIDE_OVERLAY);

                progressBar = new ProgressBar(
                        cordova.getActivity(),
                        null,
                        android.R.attr.progressBarStyleHorizontal);

                String progressColor = options.optString("progressColor", "#2196F3");
                try {
                    progressBar.getProgressDrawable().setColorFilter(
                            Color.parseColor(progressColor),
                            PorterDuff.Mode.SRC_IN);
                } catch (Exception e) {
                    Log.w(TAG, "Invalid progress color, using default");
                }

                int progressHeight = options.optInt("progressHeight", 5);
                float density = cordova.getActivity().getResources().getDisplayMetrics().density;
                int progressHeightPx = (int) (progressHeight * density);

                FrameLayout.LayoutParams progressParams = new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        progressHeightPx);
                progressParams.gravity = android.view.Gravity.BOTTOM;
                progressBar.setMax(100);
                progressBar.setProgress(0);
                progressBar.setVisibility(View.GONE);

                embeddedWebView.setWebViewClient(new WebViewClient() {
                    @Override
                    public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                        super.onPageStarted(view, url, favicon);
                        if (progressBar != null) {
                            progressBar.setVisibility(View.VISIBLE);
                            progressBar.setProgress(0);
                        }
                        Log.d(TAG, "Page started loading: " + url);
                        fireEvent("loadStart", url);
                    }

                    @Override
                    public void onPageFinished(WebView view, String url) {
                        super.onPageFinished(view, url);
                        if (progressBar != null) {
                            progressBar.setProgress(100);
                            progressBar.postDelayed(() -> {
                                if (progressBar != null) {
                                    progressBar.setVisibility(View.GONE);
                                }
                            }, 200);
                        }

                        // Smooth scrolling
                        String css = "html, body { scroll-behavior: smooth !important; }";
                        String js = "let style = document.createElement('style');"
                                + "style.innerHTML = `" + css + "`;"
                                + "document.head.appendChild(style);";
                        view.evaluateJavascript(js, null);

                        // Fallback JS: rewrite target="_blank" and override window.open to use same window
                        String rewriteTargets =
                            "(() => { " +
                            "try { " +
                            "document.querySelectorAll('a[target=\"_blank\"]').forEach(a => a.target = '_self');" +
                            "window.open = function(url) { window.location.href = url; };" +
                            // click-capture for delegated anchors (SPA)
                            "document.addEventListener('click', function(e){ " +
                            " var node = e.target; while(node && node.tagName !== 'A') node = node.parentElement; " +
                            " if (node && node.tagName === 'A') { var href = node.getAttribute('href'); var target = node.getAttribute('target'); if (href && target === '_blank') { e.preventDefault(); window.location.href = href; } } " +
                            "}, true);" +
                            "} catch(e) { console.warn('rewriteTargets failed', e); }" +
                            "})();";
                        view.evaluateJavascript(rewriteTargets, null);

                        Log.d(TAG, "Page finished loading: " + url);

                        updateNavigationState();
                        fireEvent("loadStop", url);
                    }

                    @Override
                    public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
                        super.onReceivedError(view, errorCode, description, failingUrl);
                        Log.e(TAG, "Error loading page: " + description);
                        fireEvent("loadError", "{\"url\":\"" + failingUrl + "\",\"code\":" + errorCode
                                + ",\"message\":\"" + description + "\"}");
                    }
                });

                // WebChromeClient with onCreateWindow to capture target=_blank / window.open popups
                embeddedWebView.setWebChromeClient(new WebChromeClient() {
                    @Override
                    public void onProgressChanged(WebView view, int newProgress) {
                        super.onProgressChanged(view, newProgress);
                        if (progressBar != null) {
                            progressBar.setProgress(newProgress);
                            Log.d(TAG, "Loading progress: " + newProgress + "%");
                        }
                    }

                    @Override
                    public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, Message resultMsg) {
                        // temp WebView to capture the popup's request
                        WebView popupWebView = new WebView(view.getContext());
                        WebSettings popupSettings = popupWebView.getSettings();
                        popupSettings.setJavaScriptEnabled(true);
                        popupSettings.setDomStorageEnabled(true);
                        popupSettings.setJavaScriptCanOpenWindowsAutomatically(true);

                        popupWebView.setWebViewClient(new WebViewClient() {
                            @Override
                            public boolean shouldOverrideUrlLoading(WebView wv, String url) {
                                // forward URL to main embeddedWebView
                                cordova.getActivity().runOnUiThread(() -> {
                                    if (embeddedWebView != null) {
                                        embeddedWebView.loadUrl(url);
                                    }
                                });
                                // cleanup
                                try { wv.stopLoading(); wv.destroy(); } catch (Exception ignored) {}
                                return true;
                            }

                            @Override
                            public boolean shouldOverrideUrlLoading(WebView wv, WebResourceRequest request) {
                                final String reqUrl = request.getUrl().toString();
                                cordova.getActivity().runOnUiThread(() -> {
                                    if (embeddedWebView != null) {
                                        embeddedWebView.loadUrl(reqUrl);
                                    }
                                });
                                try { wv.stopLoading(); wv.destroy(); } catch (Exception ignored) {}
                                return true;
                            }
                        });

                        WebView.WebViewTransport transport = (WebView.WebViewTransport) resultMsg.obj;
                        transport.setWebView(popupWebView);
                        resultMsg.sendToTarget();
                        return true;
                    }
                });

                embeddedWebView.setBackgroundColor(Color.TRANSPARENT);

                FrameLayout.LayoutParams webViewParams = new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT);
                webViewContainer.addView(embeddedWebView, webViewParams);

                webViewContainer.addView(progressBar, progressParams);

                ViewGroup contentView = (ViewGroup) decorView.findViewById(android.R.id.content);

                FrameLayout.LayoutParams containerParams = new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT);
                containerParams.topMargin = finalTopMargin;
                containerParams.bottomMargin = finalBottomMargin;

                contentView.addView(webViewContainer, containerParams);

                webViewContainer.bringToFront();

                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                    webViewContainer.setElevation(10f);
                    webViewContainer.setTranslationZ(10f);
                }

                contentView.invalidate();
                contentView.requestLayout();

                if (options.has("headers")) {
                    JSONObject headersJson = options.getJSONObject("headers");
                    Map<String, String> headers = jsonToMap(headersJson);
                    embeddedWebView.loadUrl(url, headers);
                } else {
                    embeddedWebView.loadUrl(url);
                }

                Log.d(TAG, "WebView created successfully with progress bar");
                callbackContext.success("WebView created successfully");

            } catch (Exception e) {
                Log.e(TAG, "Error creating WebView: " + e.getMessage());
                e.printStackTrace();
                callbackContext.error("Error creating WebView: " + e.getMessage());
            }
        });
    }

    private void destroy(final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (embeddedWebView != null) {
                    ViewGroup parent = (ViewGroup) embeddedWebView.getParent();
                    if (parent != null) {
                        ViewGroup grandParent = (ViewGroup) parent.getParent();
                        if (grandParent != null) {
                            grandParent.removeView(parent);
                        }
                    }
                    embeddedWebView.destroy();
                    embeddedWebView = null;
                    progressBar = null;
                    Log.d(TAG, "WebView destroyed");
                    callbackContext.success("WebView destroyed");
                } else {
                    callbackContext.error("No WebView to destroy");
                }
            }
        });
    }

    private void loadUrl(final String url, final JSONObject headers,
            final CallbackContext callbackContext) {

        cordova.getActivity().runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (embeddedWebView != null) {
                    try {
                        if (headers != null && headers.length() > 0) {
                            Map<String, String> headerMap = jsonToMap(headers);
                            embeddedWebView.loadUrl(url, headerMap);
                        } else {
                            embeddedWebView.loadUrl(url);
                        }
                        callbackContext.success("URL loaded: " + url);
                    } catch (Exception e) {
                        callbackContext.error("Error loading URL: " + e.getMessage());
                    }
                } else {
                    callbackContext.error("WebView not initialized");
                }
            }
        });
    }

    private void executeScript(final String script, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (embeddedWebView != null) {
                    embeddedWebView.evaluateJavascript(script, new ValueCallback<String>() {
                        @Override
                        public void onReceiveValue(String result) {
                            callbackContext.success(result);
                        }
                    });
                } else {
                    callbackContext.error("WebView not initialized");
                }
            }
        });
    }

    private void setVisible(final boolean visible, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (embeddedWebView != null) {
                    ViewGroup container = (ViewGroup) embeddedWebView.getParent();
                    if (container != null) {
                        container.setVisibility(visible ? View.VISIBLE : View.GONE);
                    }
                    callbackContext.success("Visibility changed to: " + visible);
                } else {
                    callbackContext.error("WebView not initialized");
                }
            }
        });
    }

    private void reload(final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (embeddedWebView != null) {
                    embeddedWebView.reload();
                    callbackContext.success("WebView reloaded");
                } else {
                    callbackContext.error("WebView not initialized");
                }
            }
        });
    }

    private void goBack(final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (embeddedWebView != null) {
                    if (embeddedWebView.canGoBack()) {
                        embeddedWebView.goBack();
                        embeddedWebView.postDelayed(() -> updateNavigationState(), 100);
                        callbackContext.success("Navigated back");
                    } else {
                        callbackContext.error("Cannot go back");
                    }
                } else {
                    callbackContext.error("WebView not initialized");
                }
            }
        });
    }

    private void canGoBack(final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (embeddedWebView != null) {
                    boolean canGoBack = embeddedWebView.canGoBack();
                    callbackContext.success(canGoBack ? 1 : 0);
                } else {
                    callbackContext.error("WebView not initialized");
                }
            }
        });
    }

    private void goForward(final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (embeddedWebView != null) {
                    if (embeddedWebView.canGoForward()) {
                        embeddedWebView.goForward();
                        embeddedWebView.postDelayed(() -> updateNavigationState(), 100);
                        callbackContext.success("Navigated forward");
                    } else {
                        callbackContext.error("Cannot go forward");
                    }
                } else {
                    callbackContext.error("WebView not initialized");
                }
            }
        });
    }

    private Map<String, String> jsonToMap(JSONObject json) throws JSONException {
        Map<String, String> map = new HashMap<>();
        Iterator<String> keys = json.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            map.put(key, json.getString(key));
        }
        return map;
    }

    private void updateNavigationState() {
        cordova.getActivity().runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (embeddedWebView != null) {
                    boolean newCanGoBack = embeddedWebView.canGoBack();
                    boolean newCanGoForward = embeddedWebView.canGoForward();

                    if (newCanGoBack != canGoBack) {
                        canGoBack = newCanGoBack;
                        fireEvent("canGoBackChanged", String.valueOf(canGoBack));
                    }

                    if (newCanGoForward != canGoForward) {
                        canGoForward = newCanGoForward;
                        fireEvent("canGoForwardChanged", String.valueOf(canGoForward));
                    }

                    String navigationState = "{\"canGoBack\":" + canGoBack + ",\"canGoForward\":" + canGoForward + "}";
                    fireEvent("navigationStateChanged", navigationState);
                }
            }
        });
    }

    private void fireEvent(String eventName, String data) {
        try {
            String js = "javascript:cordova.fireDocumentEvent('embeddedwebview." + eventName + "', " +
                    "{detail: " + (data.startsWith("{") ? data : "'" + data + "'") + "});";

            Log.d(TAG, "Firing event: " + eventName + " with data: " + data);

            cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    cordovaWebView.getView().post(() -> {
                        try {
                            cordovaWebView.loadUrl(js);
                        } catch (Exception e) {
                            Log.e(TAG, "Error firing event: " + e.getMessage());
                        }
                    });
                }
            });
        } catch (Exception e) {
            Log.e(TAG, "Error firing event: " + e.getMessage());
        }
    }

    @Override
    public void onDestroy() {
        if (embeddedWebView != null) {
            embeddedWebView.destroy();
            embeddedWebView = null;
        }
        progressBar = null;
        super.onDestroy();
    }

    @Override
    public void onReset() {
        if (embeddedWebView != null) {
            embeddedWebView.destroy();
            embeddedWebView = null;
        }
        progressBar = null;
        super.onReset();
    }
}
