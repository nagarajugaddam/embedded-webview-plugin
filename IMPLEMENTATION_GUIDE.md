# Implementation Example for Your App

Based on the code you provided, here's how to integrate the blocked URL event handling:

## Your Current Setup

```javascript
function addWebViewListeners(screen) {
    screen = screen || sessionStorage.getItem("WebView_lastscreen_name");
    if (!screen) return;

    if (!window.webViewListenerMap) {
        window.webViewListenerMap = {};
    }

    if (window.webViewListenerMap[screen]) {
        console.log("Listeners already added for:", screen);
        return;
    }

    // Standard Events
    document.addEventListener(`embeddedwebview.${screen}.loadError`, loadError);
    document.addEventListener(`embeddedwebview.${screen}.loadStart`, loadStart);
    document.addEventListener(`embeddedwebview.${screen}.loadStop`, loadStop);
    // ❌ MISSING: loadBlocked listener!
    
    window.webViewListenerMap[screen] = true;
}
```

## Fixed Version with Blocked Event

```javascript
function addWebViewListeners(screen) {
    screen = screen || sessionStorage.getItem("WebView_lastscreen_name");
    if (!screen) return;

    if (!window.webViewListenerMap) {
        window.webViewListenerMap = {};
    }

    if (window.webViewListenerMap[screen]) {
        console.log("Listeners already added for:", screen);
        return;
    }

    // Standard Events
    document.addEventListener(`embeddedwebview.${screen}.loadError`, loadError);
    document.addEventListener(`embeddedwebview.${screen}.loadStart`, loadStart);
    document.addEventListener(`embeddedwebview.${screen}.loadStop`, loadStop);
    document.addEventListener(`embeddedwebview.${screen}.loadBlocked`, loadBlocked); // ✅ ADD THIS

    // ... rest of your code ...
    
    window.webViewListenerMap[screen] = true;
}
```

## Updated Event Handlers

```javascript
// --- Global References and Execution ---

window.removeWebViewListenersGlobal = removeWebViewListeners;

// Clean up previous listeners (best practice in SPAs)
removeWebViewListeners($parameters.ScreenName);
// Add new listeners
addWebViewListeners($parameters.ScreenName);


// --- Event Handlers ---

function consoleLog(e){
    var data = e.detail;
    // console.log("REMOTE WEBVIEW LOG:", data); 
}

function safeTrigger(actionName, data) {
    try {
        // 1. Check if the specific action exists
        if (typeof window[actionName] !== 'function') {
            console.warn("EmbeddedWebView: Action " + actionName + " not found.");
            return;
        }

        // 2. Attempt to call the action
        window[actionName](data);

    } catch (err) {
        // 3. Catch errors gracefully
        var msg = err.message || "";
        if (msg.indexOf("not currently active") !== -1) {
            console.warn("EmbeddedWebView: Ignored " + actionName + " because the screen is closing/destroyed.");
        } else {
            console.error("EmbeddedWebView: Error calling " + actionName, err);
        }
    }
}

function loadError(e){
    var data = e.detail;
    console.error("loadError:", data);
    safeTrigger("TriggerOnError", data);
}

function loadStart(e){
    var data = e.detail;
    console.log("loadStart:", data);
    safeTrigger("TriggerOnLoadStart", data);
}

function loadStop(e){
    var data = e.detail;
    console.log("loadStop:", data);
    safeTrigger("TriggerOnLoadStop", data);
}

function loadBlocked(e){
    var data = e.detail;
    console.log("loadBlocked:", data);  // This will now work!
    safeTrigger("TriggerOnLoadToScreenNav", data);
}
```

## When Creating the WebView

Make sure you're passing the `blockedUrls` option:

```javascript
EmbeddedWebView.create(
    'mainscreen',  // Your screen ID
    'https://myapp.com/page',
    {
        top: 0,
        height: window.innerHeight,
        blockedUrls: [
            'login.apus.edu',      // Block the Apply Now button URL
            'apply',               // Or any other URLs you want to block
            'padsts/profile'
        ]
    },
    function(success) {
        console.log('WebView created:', success);
        // Now add listeners
        addWebViewListeners('mainscreen');
    },
    function(error) {
        console.error('Failed to create WebView:', error);
    }
);
```

## What Happens Now When User Clicks "Apply Now"

1. **User clicks**: 
   ```html
   <a href="https://login.apus.edu/padsts/profile/create?s=amu-app" 
      target="_blank">
       Apply Now
   </a>
   ```

2. **Native code detects**:
   - URL contains "login.apus.edu" (matches blockedUrls)
   - URL has `target="_blank"` (intercepted by WebChromeClient.onCreateWindow)

3. **Native code blocks navigation** and fires event:
   ```javascript
   fireEvent(id, "loadBlocked", "https://login.apus.edu/padsts/profile/create?s=amu-app");
   ```

4. **Your JavaScript receives event**:
   ```javascript
   // Event: embeddedwebview.mainscreen.loadBlocked
   // event.detail = "https://login.apus.edu/padsts/profile/create?s=amu-app"
   ```

5. **Event handler runs**:
   ```javascript
   function loadBlocked(e) {
       console.log("loadBlocked:", e.detail);
       safeTrigger("TriggerOnLoadToScreenNav", e.detail);  // ✅ Calls your action
   }
   ```

6. **Your app action runs**:
   ```javascript
   function TriggerOnLoadToScreenNav(url) {
       console.log("Apply Now was clicked and blocked. URL:", url);
       // Now you can:
       // - Show a dialog to user
       // - Handle custom login flow
       // - Navigate to a different screen
       // - etc.
   }
   ```

## Checklist Before Testing

- [ ] Updated Android APK with the latest code
- [ ] `blockedUrls` includes `'login.apus.edu'` or `'apus.edu'`
- [ ] `loadBlocked` event listener is added in `addWebViewListeners()`
- [ ] The `loadBlocked()` event handler function is defined
- [ ] `TriggerOnLoadToScreenNav()` action is defined in your app
- [ ] Check Android logcat for logs like: `[Native] Firing: embeddedwebview.xxx.loadBlocked`

## Debugging Tips

Add detailed logging to see what's happening:

```javascript
function loadBlocked(e){
    var data = e.detail;
    console.log("=== BLOCKED URL EVENT ===");
    console.log("Blocked URL:", data);
    console.log("Event type:", e.type);
    console.log("Event detail:", e.detail);
    console.log("Current time:", new Date().toISOString());
    console.log("========================");
    safeTrigger("TriggerOnLoadToScreenNav", data);
}
```

Check Android logs:
```bash
adb logcat | grep "EmbeddedWebView"
```

Look for lines like:
```
[Native] Firing: embeddedwebview.mainscreen.loadBlocked
Navigation blocked (target=_blank) for: https://login.apus.edu/padsts/profile/create?s=amu-app
Event fired in embedded WebView: embeddedwebview.mainscreen.loadBlocked
```

All three log messages should appear when the Apply Now button is clicked.
