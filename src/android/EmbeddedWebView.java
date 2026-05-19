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
import android.os.Handler; 
import android.os.Looper;

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
        List<String> historySkipUrls;
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

    // --- HELPER: CHECK IF URL IS BLOCKED ---
    private boolean isUrlBlocked(String url, List<String> blockedUrls) {
        if (blockedUrls != null && !blockedUrls.isEmpty()) {
            for (String blocked : blockedUrls) {
                if (url.contains(blocked)) {
                    return true;
                }
            }
        }
        return false;
    }

 private void create(
        final String id,
        final String url,
        final JSONObject options,
        final CallbackContext callbackContext
) {
    Log.d(TAG, "Creating WebView (id=" + id + ")");

    if (instances.containsKey(id)) {
        destroy(id, null);
    }

    cordova.getActivity().runOnUiThread(() -> {
        try {
            // 1. Convert CSS px → Android px
            float density = cordova.getActivity()
                    .getResources()
                    .getDisplayMetrics()
                    .density;

            int topOffsetPx = (int) (options.optInt("top", 0) * density);
            int bottomOffsetPx = (int) (options.optInt("bottom", 0) * density);

            Log.d(TAG, "Offsets -> topPx=" + topOffsetPx + " bottomPx=" + bottomOffsetPx);

            // Parse blockedUrls from options so navigation checks can reference it
            final List<String> blockedUrls = new ArrayList<>();
            if (options.has("blockedUrls")) {
                JSONArray blockedArr = options.getJSONArray("blockedUrls");
                for (int i = 0; i < blockedArr.length(); i++) {
                    blockedUrls.add(blockedArr.getString(i));
                }
            }
+
+            // Parse historySkipUrls if provided (used by navigation helpers)
+            final List<String> historySkipUrls = new ArrayList<>();
+            if (options.has("historySkipUrls")) {
+                JSONArray skipArr = options.getJSONArray("historySkipUrls");
+                for (int i = 0; i < skipArr.length(); i++) {
+                    historySkipUrls.add(skipArr.getString(i));
+                }
+            }

            // 2. Get root view (same parent as Cordova WebView)
            View cordovaView = cordovaWebView.getView();
            ViewGroup rootGroup = (ViewGroup) cordovaView.getParent();

            // 3. Create container
            FrameLayout container = new FrameLayout(cordova.getActivity());
            container.setBackgroundColor(Color.TRANSPARENT);

            // 4. Create WebView
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

            // Respect option to allow external app launches (default: false)
            final boolean allowExternalApp = options.optBoolean("allowExternalApp", false);

            // Intercept navigations to prevent opening external apps unintentionally
            webView.setWebViewClient(new WebViewClient() {
                @Override
                public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                    return handleUrl(request.getUrl().toString());
                }

                @Override
                public boolean shouldOverrideUrlLoading(WebView view, String url) {
                    return handleUrl(url);
                }

                private boolean handleUrl(String url) {
                    if (url == null) return false;
                    // Block configured blocked URLs
                    if (isUrlBlocked(url, blockedUrls)) {
                        Log.d(TAG, "Blocked navigation: " + url);
                        fireEvent(id, "loadBlocked", url);
                        return true;
                    }

                    // Handle intent:// URIs
                    if (url.startsWith("intent:")) {
                        if (!allowExternalApp) {
                            Log.d(TAG, "Blocked intent URI (external apps disabled): " + url);
                            fireEvent(id, "externalBlocked", url);
                            return true;
                        }
                        try {
                            Intent intent = Intent.parseUri(url, Intent.URI_INTENT_SCHEME);
                            cordova.getActivity().startActivity(intent);
                        } catch (Exception e) {
                            Log.e(TAG, "Failed to handle intent URI", e);
                        }
                        return true;
                    }

                    // Common external schemes
                    if (url.startsWith("tel:") || url.startsWith("mailto:") || url.startsWith("sms:") || url.startsWith("geo:") || url.startsWith("whatsapp:") || url.startsWith("market:")) {
                        if (!allowExternalApp) {
                            Log.d(TAG, "Blocked external scheme (external apps disabled): " + url);
                            fireEvent(id, "externalBlocked", url);
                            return true;
                        }
                        try {
                            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
                            cordova.getActivity().startActivity(intent);
                        } catch (Exception e) {
                            Log.e(TAG, "Error opening external app for url: " + url, e);
                        }
                        return true;
                    }

                    // Allow WebView to load the URL normally
                    return false;
                }
            });

            // Handle target="_blank" by loading in the existing webView instead of launching external browser
            webView.setWebChromeClient(new WebChromeClient() {
                @Override
                public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, android.os.Message resultMsg) {
                    android.webkit.WebView.WebViewTransport transport = (android.webkit.WebView.WebViewTransport) resultMsg.obj;
                    WebView newWebView = new WebView(cordova.getActivity());
                    newWebView.setWebViewClient(new WebViewClient() {
                        @Override
                        public boolean shouldOverrideUrlLoading(WebView view, String url) {
                            try {
                                if (url != null) webView.loadUrl(url);
                            } catch (Exception e) { Log.e(TAG, "Error loading url from new window", e); }
                            return true;
                        }
                    });
                    transport.setWebView(newWebView);
                    resultMsg.sendToTarget();
                    return true;
                }
            });

            webView.setBackgroundColor(Color.TRANSPARENT);
            webView.setLayerType(View.LAYER_TYPE_HARDWARE, null);

            // 5. Add WebView to container
            container.addView(webView, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
            ));

            // 6. Apply margins (THIS creates the correct layout window)
            FrameLayout.LayoutParams containerParams =
                    new FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT
                    );

            containerParams.topMargin = topOffsetPx;
            // containerParams.bottomMargin = bottomOffsetPx;

            // containerParams.topMargin = 0;
            containerParams.bottomMargin = bottomOffsetPx;

            // 7. Attach to root
            rootGroup.addView(container, containerParams);
            container.bringToFront();

            // 8. Store instance
            WebViewInstance instance = new WebViewInstance();
            instance.webView = webView;
            instance.container = container;
            instance.blockedUrls = blockedUrls;
            instance.historySkipUrls = historySkipUrls;
            instances.put(id, instance);
            lastCreatedId = id;

            // 9. Load URL
            webView.loadUrl(url);

            callbackContext.success("WebView created. top=" + topOffsetPx + " bottom=" + bottomOffsetPx);

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
            
            // --- FIX 2: CHECK BLOCKED URL BEFORE PROGRAMMATIC LOAD ---
            if (isUrlBlocked(url, instance.blockedUrls)) {
                 Log.d(TAG, "Navigation blocked (loadUrl) for: " + url);
                 fireEvent(id, "loadBlocked", url);
                 if (callbackContext != null) callbackContext.success("Navigation blocked");
                 return;
            }
            // ---------------------------------------------------------

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
    
    // --- SMART BACK LOGIC ---

    private void goBack(final String id, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = getInstance(id, callbackContext);
            if (instance == null) return;

            instance.webView.stopLoading();

            if (instance.historySkipUrls != null && !instance.historySkipUrls.isEmpty()) {
                android.webkit.WebBackForwardList history = instance.webView.copyBackForwardList();
                int currIndex = history.getCurrentIndex();
                int stepsToGoBack = 0;
                boolean foundSafePage = false;

                for (int i = currIndex - 1; i >= 0; i--) {
                    String url = history.getItemAtIndex(i).getUrl();
                    boolean isSkipped = false;
                    for (String skip : instance.historySkipUrls) {
                        if (url.contains(skip)) {
                            isSkipped = true;
                            break;
                        }
                    }

                    if (!isSkipped) {
                        stepsToGoBack = i - currIndex;
                        foundSafePage = true;
                        break;
                    }
                }

                if (foundSafePage) {
                    instance.webView.goBackOrForward(stepsToGoBack);
                    Log.d(TAG, "Smart Skip - Jumping back " + stepsToGoBack + " steps.");
                    final String finalId = id; 
                    instance.webView.postDelayed(() -> updateNavigationState(finalId), 200);
                    if (callbackContext != null) callbackContext.success("Navigated back (Smart)");
                    return;
                }
            }

            if (instance.webView.canGoBack()) {
                instance.webView.goBack();
                instance.webView.postDelayed(() -> updateNavigationState(id), 100);
                if (callbackContext != null) callbackContext.success("Navigated back");
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

    // --- HELPER: CHECK EFFECTIVE BACK STATUS ---
    private boolean isEffectiveGoBackAvailable(WebViewInstance instance) {
        if (instance == null || instance.webView == null) return false;
        
        if (!instance.webView.canGoBack()) return false;
        
        if (instance.historySkipUrls == null || instance.historySkipUrls.isEmpty()) return true;
        
        android.webkit.WebBackForwardList history = instance.webView.copyBackForwardList();
        int currIndex = history.getCurrentIndex();
        
        for (int i = currIndex - 1; i >= 0; i--) {
            String url = history.getItemAtIndex(i).getUrl();
            boolean isSkipped = false;
            for (String skip : instance.historySkipUrls) {
                if (url.contains(skip)) {
                    isSkipped = true;
                    break;
                }
            }
            if (!isSkipped) return true;
        }
        
        return false;
    }

    private void canGoBack(final String id, final CallbackContext callbackContext) {
        cordova.getActivity().runOnUiThread(() -> {
            WebViewInstance instance = getInstance(id, callbackContext);
            if (instance != null) { 
                boolean effective = isEffectiveGoBackAvailable(instance);
                if (callbackContext != null) callbackContext.success(effective ? 1 : 0); 
            }
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
            
            boolean newCanGoBack = isEffectiveGoBackAvailable(instance);
            boolean newCanGoForward = instance.webView.canGoForward();
            
            String currentUrl = instance.webView.getUrl();
            if (currentUrl == null) currentUrl = "";

            if (newCanGoBack != instance.canGoBack) { 
                instance.canGoBack = newCanGoBack; 
                try {
                    JSONObject data = new JSONObject();
                    data.put("value", instance.canGoBack);
                    data.put("url", currentUrl);
                    fireEvent(id, "canGoBackChanged", data.toString()); 
                } catch (JSONException ignored) {}
            }

            if (newCanGoForward != instance.canGoForward) { 
                instance.canGoForward = newCanGoForward; 
                try {
                    JSONObject data = new JSONObject();
                    data.put("value", instance.canGoForward);
                    data.put("url", currentUrl);
                    fireEvent(id, "canGoForwardChanged", data.toString()); 
                } catch (JSONException ignored) {}
            }
            
            try {
                JSONObject nav = new JSONObject();
                nav.put("canGoBack", instance.canGoBack);
                nav.put("canGoForward", instance.canGoForward);
                nav.put("url", currentUrl);
                fireEvent(id, "navigationStateChanged", nav.toString());
            } catch (JSONException ignored) {}
        });
    }
    
    // --- UPDATED FIRE EVENT METHOD (Final Robust Version) ---
    private void fireEvent(String id, String eventName, String data) {
        final String fullEventName = "embeddedwebview." + id + "." + eventName;
        
        String payload;
        if (data != null && data.trim().startsWith("{")) {
            payload = data; 
        } else if (data == null) {
            payload = "null";
        } else {
            payload = "\"" + data.replace("\"", "\\\"") + "\"";
        }

        final String js = "window.setTimeout(function(){ " +
                "try { " +
                "  console.log('[Native] Firing: " + fullEventName + "'); " +
                "  var evt = new CustomEvent('" + fullEventName + "', { detail: " + payload + ", bubbles: true, cancelable: true }); " +
                "  document.dispatchEvent(evt); " +
                "} catch(e) { console.error('Error firing native event', e); } " +
                "}, 0);";

        cordova.getActivity().runOnUiThread(() -> {
            try {
                if (cordovaWebView != null && cordovaWebView.getEngine() != null) {
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.KITKAT) {
                        cordovaWebView.getEngine().evaluateJavascript(js, null);
                    } else {
                        cordovaWebView.loadUrl("javascript:" + js);
                    }
                } else {
                    Log.e(TAG, "CordovaWebView is null, cannot fire event: " + fullEventName);
                }
            } catch (Exception e) {
                Log.e(TAG, "Failed to fire event: " + fullEventName, e);
            }
        });
    }
    
    @Override public void onDestroy() { for (String id : new HashMap<>(instances).keySet()) destroy(id, null); instances.clear(); super.onDestroy(); }
    @Override public void onReset() { for (String id : new HashMap<>(instances).keySet()) destroy(id, null); instances.clear(); super.onReset(); }
}