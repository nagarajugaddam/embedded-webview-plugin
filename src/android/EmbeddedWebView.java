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
import android.webkit.CookieManager;
import android.webkit.ConsoleMessage; // <--- ADDED IMPORT
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.util.Log;

import java.util.ArrayList; 
import java.util.List; 
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import android.graphics.Bitmap;
import android.view.Gravity;

import java.net.URL;
import java.net.MalformedURLException;

public class EmbeddedWebView extends CordovaPlugin {

    private static final String TAG = "EmbeddedWebView";

    private static class WebViewInstance {
        WebView webView;
        FrameLayout container;
        ProgressBar progressBar;
        boolean canGoBack = false;
        boolean canGoForward = false;
        List<String> blockedUrls;
    }

    private final Map<String, WebViewInstance> instances = new HashMap<>();
    private String lastCreatedId = null;

    private CordovaWebView cordovaWebView;

    @Override
    public void initialize(CordovaInterface cordova, CordovaWebView webView) {
        super.initialize(cordova, webView);
        this.cordovaWebView = webView;
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext)
            throws JSONException {
        if ("create".equals(action)) {
            String id = args.getString(0);
            String url = args.getString(1);
            JSONObject options = args.getJSONObject(2);
            this.create(id, url, options, callbackContext);
            return true;
        }
        if ("destroy".equals(action)) {
            String id = args.getString(0);
            this.destroy(id, callbackContext);
            return true;
        }
        if ("loadUrl".equals(action)) {
            String id = args.getString(0);
            String url = args.getString(1);
            JSONObject headers = args.optJSONObject(2);
            this.loadUrl(id, url, headers, callbackContext);
            return true;
        }
        if ("executeScript".equals(action)) {
            String id = args.getString(0);
            String script = args.getString(1);
            this.executeScript(id, script, callbackContext);
            return true;
        }
        if ("setVisible".equals(action)) {
            String id = args.getString(0);
            boolean visible = args.getBoolean(1);
            this.setVisible(id, visible, callbackContext);
            return true;
        }
        if ("reload".equals(action)) {
            String id = args.getString(0);
            this.reload(id, callbackContext);
            return true;
        }
        if ("goBack".equals(action)) {
            String id = args.getString(0);
            this.goBack(id, callbackContext);
            return true;
        }
        if ("goForward".equals(action)) {
            String id = args.getString(0);
            this.goForward(id, callbackContext);
            return true;
        }
        if ("canGoBack".equals(action)) {
            String id = args.getString(0);
            this.canGoBack(id, callbackContext);
            return true;
        }
        return false;
    }

    public boolean onBackPressed() {
        if (lastCreatedId == null) {
            return false;
        }
        WebViewInstance instance = instances.get(lastCreatedId);
        if (instance != null && instance.webView != null && instance.webView.canGoBack()) {
            cordova.getActivity().runOnUiThread(() -> {
                instance.webView.goBack();
                Log.d(TAG, "Back button intercepted - navigated back in WebView (id=" + lastCreatedId + ")");
                updateNavigationState(lastCreatedId);
            });
            return true;
        }
        return false;
    }

    private WebViewInstance getInstance(String id, CallbackContext callbackContext) {
        WebViewInstance instance = instances.get(id);
        if (instance == null || instance.webView == null) {
            if (callbackContext != null) {
                callbackContext.error("WebView instance not found for id: " + id);
            }
            return null;
        }
        return instance;
    }

    private void create(
            final String id,
            final String url,
            final JSONObject options,
            final CallbackContext callbackContext
    ) {

        Log.d(TAG, "Creating WebView (id=" + id + ")");

        if (instances.containsKey(id)) {
            Log.w(TAG, "WebView already exists for id=" + id + ", destroying first");
            destroy(id, null);
        }

        cordova.getActivity().runOnUiThread(() -> {
            try {
                // Layout
                float density = cordova.getActivity().getResources().getDisplayMetrics().density;
                int topOffsetDp = options.optInt("top", 0);
                int bottomOffsetDp = options.optInt("bottom", 0);
                int topOffsetPx = (int) (topOffsetDp * density);
                int bottomOffsetPx = (int) (bottomOffsetDp * density);

                View webViewView = cordovaWebView.getView();
                ViewGroup rootGroup = (ViewGroup) webViewView.getParent();

                FrameLayout container = new FrameLayout(cordova.getActivity());
                container.setBackgroundColor(Color.TRANSPARENT);

                WebView webView = new WebView(cordova.getActivity());
                WebSettings settings = webView.getSettings();
                settings.setJavaScriptEnabled(true);
                settings.setDomStorageEnabled(true);
                settings.setDatabaseEnabled(true);
                settings.setAllowFileAccess(true);
                settings.setAllowContentAccess(true);
                settings.setLoadWithOverviewMode(true);
                settings.setUseWideViewPort(true);
                settings.setJavaScriptCanOpenWindowsAutomatically(true);
                settings.setSupportMultipleWindows(true);

                if (options.optBoolean("enableZoom", false)) {
                    settings.setBuiltInZoomControls(true);
                    settings.setDisplayZoomControls(false);
                }
                if (options.optBoolean("clearCache", false)) {
                    webView.clearCache(true);
                }
                if (options.has("userAgent")) {
                    settings.setUserAgentString(options.getString("userAgent"));
                }

                webView.setVerticalScrollBarEnabled(false);
                webView.setHorizontalScrollBarEnabled(false);
                webView.setOverScrollMode(WebView.OVER_SCROLL_NEVER);
                webView.setBackgroundColor(Color.TRANSPARENT);
                webView.setLayerType(View.LAYER_TYPE_HARDWARE, null);

                // --- 1. PARSE BLOCKED URLS ---
                final List<String> blockedUrls = new ArrayList<>();
                if (options.has("blockedUrls")) {
                    JSONArray blockedArr = options.getJSONArray("blockedUrls");
                    for (int i = 0; i < blockedArr.length(); i++) {
                        blockedUrls.add(blockedArr.getString(i));
                    }
                }

                // Cookie Logic
                String calculatedCookieDomain = null;
                try {
                    URL uri = new URL(url);
                    String host = uri.getHost();
                    if (host != null && !host.equals("localhost") && !host.matches("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$")) {
                        if (host.startsWith("www.")) {
                            host = host.substring(4);
                        }
                        if (!host.startsWith(".")) {
                            calculatedCookieDomain = "." + host;
                        } else {
                            calculatedCookieDomain = host;
                        }
                    }
                } catch (MalformedURLException e) {
                    Log.e(TAG, "Error parsing URL for cookie domain", e);
                }
                final String cookieDomain = calculatedCookieDomain;

                CookieManager cookieManager = CookieManager.getInstance();
                cookieManager.setAcceptCookie(true);
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                    cookieManager.setAcceptThirdPartyCookies(webView, true);
                }

                if (options.has("cookies")) {
                    try {
                        JSONObject cookies = options.getJSONObject("cookies");
                        Iterator<String> keys = cookies.keys();
                        while (keys.hasNext()) {
                            String name = keys.next();
                            String value = cookies.getString(name);
                            String cookieVal = name + "=" + value + "; path=/";
                            if (cookieDomain != null) {
                                cookieVal += "; domain=" + cookieDomain;
                            }
                            cookieManager.setCookie(url, cookieVal);
                        }
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                            cookieManager.flush();
                        }
                    } catch (Exception e) {
                        Log.e(TAG, "Error setting native cookies", e);
                    }
                }

                // UI
                ProgressBar progressBar = new ProgressBar(cordova.getActivity(), null, android.R.attr.progressBarStyleHorizontal);
                String progressColor = options.optString("progressColor", "#2196F3");
                try {
                    progressBar.getProgressDrawable().setColorFilter(Color.parseColor(progressColor), PorterDuff.Mode.SRC_IN);
                } catch (Exception ignored) {}

                int progressHeightDp = options.optInt("progressHeight", 5);
                int progressHeightPx = (int) (progressHeightDp * density);

                FrameLayout.LayoutParams progressParams = new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        progressHeightPx,
                        Gravity.BOTTOM
                );
                progressBar.setMax(100);
                progressBar.setVisibility(View.GONE);

                // --- 2. SETUP WEBVIEW CLIENT WITH INTERCEPTION ---
                webView.setWebViewClient(new WebViewClient() {
                    
                    private boolean checkBlocked(String url) {
                        if (blockedUrls != null && !blockedUrls.isEmpty()) {
                            for (String blocked : blockedUrls) {
                                if (url.contains(blocked)) {
                                    Log.d(TAG, "Navigation blocked for: " + url);
                                    fireEvent(id, "loadBlocked", url);
                                    return true;
                                }
                            }
                        }
                        return false;
                    }

                    @Override
                    public boolean shouldOverrideUrlLoading(WebView view, String url) {
                        if (checkBlocked(url)) return true;
                        return super.shouldOverrideUrlLoading(view, url);
                    }

                    @Override
                    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                        String url = request.getUrl().toString();
                        if (checkBlocked(url)) return true;
                        return super.shouldOverrideUrlLoading(view, request);
                    }

                    @Override
                    public void onPageStarted(WebView view, String url, Bitmap favicon) {
                        progressBar.setVisibility(View.VISIBLE);
                        progressBar.setProgress(0);
                        
                        // -------------------------------------------------------------
                        // FIX: ResizeObserver loop completed with undelivered notifications
                        // Inject JS immediately when page starts
                        // -------------------------------------------------------------
                        String resizeObserverFix = "window.addEventListener('error', function(event) { if (event.message === 'ResizeObserver loop completed with undelivered notifications.') { event.stopImmediatePropagation(); } });";
                        view.evaluateJavascript(resizeObserverFix, null);
                        // -------------------------------------------------------------

                        injectCookies(view, options, cookieDomain);
                        fireEvent(id, "loadStart", url);
                        updateNavigationState(id); 
                    }

                    @Override
                    public void doUpdateVisitedHistory(WebView view, String url, boolean isReload) {
                        super.doUpdateVisitedHistory(view, url, isReload);
                        updateNavigationState(id);
                    }

                    @Override
                    public void onPageFinished(WebView view, String url) {
                        progressBar.setProgress(100);
                        progressBar.postDelayed(() -> progressBar.setVisibility(View.GONE), 200);
                        injectCookies(view, options, cookieDomain);
                        updateNavigationState(id);
                        fireEvent(id, "loadStop", url);
                    }
                    @Override
                    public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
                        String errorJson = "{\"url\":\"" + failingUrl + "\",\"code\":" + errorCode + ",\"message\":\"" + description + "\"}";
                        fireEvent(id, "loadError", errorJson);
                    }
                });

                // --- 3. WEB CHROME CLIENT ---
                webView.setWebChromeClient(new WebChromeClient() {
                    @Override
                    public void onProgressChanged(WebView view, int newProgress) {
                        progressBar.setProgress(newProgress);
                    }

                    // -------------------------------------------------------------
                    // FIX: Filter console logs on Android to prevent spam
                    // -------------------------------------------------------------
                    @Override
                    public boolean onConsoleMessage(ConsoleMessage cm) {
                        if (cm.message() != null && cm.message().contains("ResizeObserver loop")) {
                            return true; // Return true to say "we handled it", suppressing the log
                        }
                        return super.onConsoleMessage(cm);
                    }
                    // -------------------------------------------------------------
                });

                container.addView(webView, new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                ));
                container.addView(progressBar, progressParams);

                FrameLayout.LayoutParams containerParams = new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                );

                containerParams.topMargin = topOffsetPx;
                containerParams.bottomMargin = bottomOffsetPx;

                rootGroup.addView(container, containerParams);
                container.bringToFront();

                if (options.has("headers")) {
                    Map<String, String> headers = jsonToMap(options.getJSONObject("headers"));
                    webView.loadUrl(url, headers);
                } else {
                    webView.loadUrl(url);
                }

                WebViewInstance instance = new WebViewInstance();
                instance.webView = webView;
                instance.container = container;
                instance.progressBar = progressBar;
                instance.blockedUrls = blockedUrls; 

                instances.put(id, instance);
                lastCreatedId = id;

                callbackContext.success("WebView created successfully for id=" + id);

            } catch (Exception e) {
                Log.e(TAG, "Error creating WebView", e);
                callbackContext.error(e.getMessage());
            }
        });
    }

    private void injectCookies(WebView webView, JSONObject options, String domain) {
        if (options.has("cookies")) {
            try {
                JSONObject cookies = options.getJSONObject("cookies");
                Iterator<String> keys = cookies.keys();
                while (keys.hasNext()) {
                    String name = keys.next();
                    String value = cookies.getString(name);
                    String safeValue = value.replace("'", "\\'");
                    String js = "document.cookie = '" + name + "=" + safeValue + "; path=/";
                    if (domain != null) {
                        js += "; domain=" + domain;
                    }
                    js += "';";
                    webView.evaluateJavascript(js, null);
                }
            } catch (Exception e) {
                Log.e(TAG, "JS cookie injection failed", e);
            }
        }
    }

    private void destroy(final String id, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = instances.remove(id);
            if (instance != null && instance.webView != null) {
                try {
                    if (instance.container != null) {
                        ViewGroup parent = (ViewGroup) instance.container.getParent();
                        if (parent != null) parent.removeView(instance.container);
                    }
                    instance.webView.destroy();
                    instance.webView = null;
                    if (id.equals(lastCreatedId)) lastCreatedId = instances.isEmpty() ? null : instances.keySet().iterator().next();
                    if (callbackContext != null) callbackContext.success("WebView destroyed for id=" + id);
                } catch (Exception e) {
                    if (callbackContext != null) callbackContext.error("Error: " + e.getMessage());
                }
            } else {
                if (callbackContext != null) callbackContext.error("No WebView to destroy for id=" + id);
            }
        });
    }
    private void loadUrl(final String id, final String url, final JSONObject headers, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = getInstance(id, callbackContext);
            if (instance == null) return;
            try {
                if (headers != null && headers.length() > 0) instance.webView.loadUrl(url, jsonToMap(headers));
                else instance.webView.loadUrl(url);
                if (callbackContext != null) callbackContext.success("URL loaded");
            } catch (Exception e) { if (callbackContext != null) callbackContext.error(e.getMessage()); }
        });
    }
    private void executeScript(final String id, final String script, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = getInstance(id, callbackContext);
            if (instance == null) return;
            instance.webView.evaluateJavascript(script, result -> { if (callbackContext != null) callbackContext.success(result); });
        });
    }
    private void setVisible(final String id, final boolean visible, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = getInstance(id, callbackContext);
            if (instance == null) return;
            if (instance.container != null) instance.container.setVisibility(visible ? View.VISIBLE : View.GONE);
            if (callbackContext != null) callbackContext.success("Visibility: " + visible);
        });
    }
    private void reload(final String id, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = getInstance(id, callbackContext);
            if (instance != null) { instance.webView.reload(); if (callbackContext != null) callbackContext.success("Reloaded"); }
        });
    }
   private void goBack(final String id, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = getInstance(id, callbackContext);
            if (instance == null) return;

            instance.webView.stopLoading();

            if (instance.webView.canGoBack()) {
                instance.webView.goBack();
                instance.webView.postDelayed(() -> updateNavigationState(id), 100);
                
                if (callbackContext != null) {
                    callbackContext.success("Navigated back for id=" + id);
                }
            } else {
                if (callbackContext != null) {
                    callbackContext.error("Cannot go back for id=" + id);
                }
            }
        });
    }
    private void goForward(final String id, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = getInstance(id, callbackContext);
            if (instance != null && instance.webView.canGoForward()) { instance.webView.goForward(); if (callbackContext != null) callbackContext.success("Forward"); }
            else if (callbackContext != null) callbackContext.error("Cannot go forward");
        });
    }
    private void canGoBack(final String id, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = getInstance(id, callbackContext);
            if (instance != null) { if (callbackContext != null) callbackContext.success(instance.webView.canGoBack() ? 1 : 0); }
        });
    }
    private Map<String, String> jsonToMap(JSONObject json) throws JSONException {
        Map<String, String> map = new HashMap<>();
        Iterator<String> keys = json.keys();
        while (keys.hasNext()) { String key = keys.next(); map.put(key, json.getString(key)); }
        return map;
    }
    private void updateNavigationState(final String id) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = instances.get(id);
            if (instance == null || instance.webView == null) return;
            boolean newCanGoBack = instance.webView.canGoBack();
            boolean newCanGoForward = instance.webView.canGoForward();
            if (newCanGoBack != instance.canGoBack) { instance.canGoBack = newCanGoBack; fireEvent(id, "canGoBackChanged", String.valueOf(instance.canGoBack)); }
            if (newCanGoForward != instance.canGoForward) { instance.canGoForward = newCanGoForward; fireEvent(id, "canGoForwardChanged", String.valueOf(instance.canGoForward)); }
            String navigationState = "{\"canGoBack\":" + instance.canGoBack + ",\"canGoForward\":" + instance.canGoForward + "}";
            fireEvent(id, "navigationStateChanged", navigationState);
        });
    }
    private void fireEvent(String id, String eventName, String data) {
        try {
            String payload;
            if (data != null && data.trim().startsWith("{")) payload = data;
            else if (data == null) payload = "null";
            else payload = "'" + data.replace("'", "\\'") + "'";
            String fullEventName = "embeddedwebview." + id + "." + eventName;
            String js = "javascript:cordova.fireDocumentEvent('" + fullEventName + "', {detail: " + payload + "});";
            cordova.getActivity().runOnUiThread(() -> { cordovaWebView.getView().post(() -> { try { cordovaWebView.loadUrl(js); } catch (Exception e) {} }); });
        } catch (Exception e) {}
    }
    @Override public void onDestroy() { for (String id : new HashMap<>(instances).keySet()) destroy(id, null); instances.clear(); super.onDestroy(); }
    @Override public void onReset() { for (String id : new HashMap<>(instances).keySet()) destroy(id, null); instances.clear(); super.onReset(); }
}