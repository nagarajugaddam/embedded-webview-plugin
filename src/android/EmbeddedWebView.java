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
import android.webkit.ConsoleMessage; 
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
import android.os.Handler; // Added for the delay loop

import java.net.URL;
import java.net.MalformedURLException;
import android.content.Intent;
import android.net.Uri;

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

                // --- 2. COOKIE SETUP ---
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

                boolean hasCookiesToSet = options.has("cookies");
                if (hasCookiesToSet) {
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
                            // FIX: Android sometimes needs explicit string parsing for expiration
                            // to treat it as persistent, but flush() usually handles it.
                            cookieManager.setCookie(url, cookieVal);
                        }
                        
                        // FIX: FORCE WRITE TO DISK
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                            cookieManager.flush();
                        } else {
                            android.webkit.CookieSyncManager.getInstance().sync();
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
                        return handleNavigation(view, url);
                    }

                    @Override
                    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                        return handleNavigation(view, request.getUrl().toString());
                    }

                    private boolean handleNavigation(WebView view, String url) {
                        if (checkBlocked(url)) return true;
                        if (url.startsWith("tel:") || url.startsWith("mailto:") || url.startsWith("sms:") || url.startsWith("geo:") || url.startsWith("whatsapp:") || url.startsWith("market:")) {
                            try {
                                Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
                                view.getContext().startActivity(intent);
                            } catch (Exception e) {
                                Log.e(TAG, "Error opening external app for url: " + url, e);
                            }
                            return true; 
                        }
                        return false; 
                    }

                    @Override
                    public void onPageStarted(WebView view, String url, Bitmap favicon) {
                        progressBar.setVisibility(View.VISIBLE);
                        progressBar.setProgress(0);
                        String resizeObserverFix = "var _RO = window.ResizeObserver; if(_RO) { window.ResizeObserver = class extends _RO { constructor(callback) { super((entries, observer) => { window.requestAnimationFrame(() => { callback(entries, observer); }); }); } }; }";
                        view.evaluateJavascript(resizeObserverFix, null);
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
                        try {
                            JSONObject err = new JSONObject();
                            err.put("url", failingUrl);
                            err.put("code", errorCode);
                            err.put("message", description);
                            fireEvent(id, "loadError", err.toString());
                        } catch (JSONException ignored) {}
                    }
                });

                webView.setWebChromeClient(new WebChromeClient() {
                    @Override
                    public void onProgressChanged(WebView view, int newProgress) { progressBar.setProgress(newProgress); }
                    @Override
                    public boolean onConsoleMessage(ConsoleMessage cm) {
                        if (cm.message() != null && cm.message().toLowerCase().contains("resizeobserver")) { return true; }
                        return super.onConsoleMessage(cm);
                    }
                });

                container.addView(webView, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
                container.addView(progressBar, progressParams);

                FrameLayout.LayoutParams containerParams = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
                containerParams.topMargin = topOffsetPx;
                containerParams.bottomMargin = bottomOffsetPx;

                rootGroup.addView(container, containerParams);
                container.bringToFront();

                // -------------------------------------------------------------------------
                // FIX START: ANDROID FLUSH & VERIFY LOOP
                // We delay the loadUrl call until we confirm CookieManager has the cookies.
                // -------------------------------------------------------------------------
                
                WebViewInstance instance = new WebViewInstance();
                instance.webView = webView;
                instance.container = container;
                instance.progressBar = progressBar;
                instance.blockedUrls = blockedUrls; 
                instances.put(id, instance);
                lastCreatedId = id;

                // Define the loading logic
                Runnable loadTask = new Runnable() {
                    int attempts = 0;
                    @Override
                    public void run() {
                        String currentCookies = cookieManager.getCookie(url);
                        boolean cookiesSynced = currentCookies != null && !currentCookies.isEmpty();
                        
                        // If we didn't want to set cookies, OR if we found cookies in the jar
                        if (!hasCookiesToSet || cookiesSynced || attempts >= 10) {
                            if (attempts >= 10) Log.w(TAG, "Cookie sync timed out on Android, forcing load.");
                            else Log.d(TAG, "Cookies verified on Android. Loading URL.");
                            
                            // Load the URL
                            if (options.has("headers")) {
                                try {
                                    Map<String, String> headers = jsonToMap(options.getJSONObject("headers"));
                                    
                                    // Manual injection for First Request (Fail-safe)
                                    if (hasCookiesToSet && currentCookies != null) {
                                        headers.put("Cookie", currentCookies);
                                    }
                                    webView.loadUrl(url, headers);
                                } catch (JSONException e) { webView.loadUrl(url); }
                            } else {
                                // Manual injection for First Request (Fail-safe)
                                if (hasCookiesToSet && currentCookies != null) {
                                    Map<String, String> authHeader = new HashMap<>();
                                    authHeader.put("Cookie", currentCookies);
                                    webView.loadUrl(url, authHeader);
                                } else {
                                    webView.loadUrl(url);
                                }
                            }
                            callbackContext.success("WebView created successfully for id=" + id);
                        } else {
                            // Retry
                            attempts++;
                            Log.d(TAG, "Waiting for Android Cookie Sync... Attempt: " + attempts);
                            new Handler().postDelayed(this, 100);
                        }
                    }
                };

                // Trigger the loop
                loadTask.run();

                // -------------------------------------------------------------------------
                // FIX END
                // -------------------------------------------------------------------------

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
                    instance.webView.stopLoading();
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
            
            if (instance.container != null) {
                instance.container.setVisibility(visible ? View.VISIBLE : View.INVISIBLE);
                if (!visible) {
                    instance.webView.onPause(); 
                    String pauseScript = "javascript:(function(){"
                            + "try {"
                            + "  document.querySelectorAll('iframe[src*=\"youtube.com\"]').forEach(function(f){"
                            + "    var clone = f.cloneNode(true);"
                            + "    f.parentNode.replaceChild(clone, f);"
                            + "  });"
                            + "  var v=document.querySelectorAll('video, audio'); for(var i=0;i<v.length;i++){ v[i].pause(); }"
                            + "} catch(e) {}"
                            + "})();";
                    instance.webView.evaluateJavascript(pauseScript, null);
                } else {
                    instance.webView.onResume(); 
                }
            }
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
                if (callbackContext != null) callbackContext.success("Navigated back for id=" + id);
            } else {
                if (callbackContext != null) callbackContext.error("Cannot go back for id=" + id);
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
            try {
                JSONObject nav = new JSONObject();
                nav.put("canGoBack", instance.canGoBack);
                nav.put("canGoForward", instance.canGoForward);
                fireEvent(id, "navigationStateChanged", nav.toString());
            } catch (JSONException ignored) {}
        });
    }
    
    private void fireEvent(String id, String eventName, String data) {
        try {
            String payload;
            if (data != null && data.trim().startsWith("{")) { payload = data; } 
            else if (data == null) { payload = "null"; } 
            else { payload = "\"" + data.replace("\"", "\\\"") + "\""; }
            String fullEventName = "embeddedwebview." + id + "." + eventName;
            String js = "javascript:cordova.fireDocumentEvent('" + fullEventName + "', {detail: " + payload + "});";
            cordova.getActivity().runOnUiThread(() -> { cordovaWebView.getView().post(() -> { try { cordovaWebView.loadUrl(js); } catch (Exception e) {} }); });
        } catch (Exception e) {}
    }
    @Override public void onDestroy() { for (String id : new HashMap<>(instances).keySet()) destroy(id, null); instances.clear(); super.onDestroy(); }
    @Override public void onReset() { for (String id : new HashMap<>(instances).keySet()) destroy(id, null); instances.clear(); super.onReset(); }
}