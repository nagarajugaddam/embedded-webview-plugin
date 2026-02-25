# Blocked URLs Event - Complete Guide

## Overview
The `loadBlocked` event fires whenever a navigation to a blocked URL is attempted in the embedded WebView. This includes:
- Direct link clicks (`<a href>`)
- Links with `target="_blank"`
- `window.open()` calls
- Form submissions to blocked URLs

## Setup

### 1. Create WebView with Blocked URLs

```javascript
EmbeddedWebView.create(
    'myscreen',
    'https://example.com/page',
    {
        top: 0,
        height: window.innerHeight,
        blockedUrls: [
            'login.apus.edu',
            'apply',
            'signup'
        ]
    },
    function(success) {
        console.log('WebView created:', success);
    },
    function(error) {
        console.error('WebView error:', error);
    }
);
```

### 2. Listen for the Event

```javascript
// Add event listener for blocked URLs
document.addEventListener('embeddedwebview.myscreen.loadBlocked', function(event) {
    const blockedUrl = event.detail;
    console.log('URL was blocked:', blockedUrl);
    
    // Perform your custom actions
    TriggerOnLoadToScreenNav(blockedUrl);
});
```

### 3. Example with Multiple Events

```javascript
function setupWebViewListeners(screenId) {
    // Load Start
    document.addEventListener(`embeddedwebview.${screenId}.loadStart`, function(event) {
        console.log('Page loading started:', event.detail);
    });
    
    // Load Stop
    document.addEventListener(`embeddedwebview.${screenId}.loadStop`, function(event) {
        console.log('Page loading finished:', event.detail);
    });
    
    // Load Error
    document.addEventListener(`embeddedwebview.${screenId}.loadError`, function(event) {
        console.error('Page loading error:', event.detail);
    });
    
    // Load Blocked - THIS IS THE KEY EVENT FOR YOUR USE CASE
    document.addEventListener(`embeddedwebview.${screenId}.loadBlocked`, function(event) {
        console.log('Navigation blocked for URL:', event.detail);
        // Call your action here
        safeTrigger('TriggerOnLoadToScreenNav', event.detail);
    });
}
```

## How It Works

### Blocked URL Detection
The plugin checks if a URL **contains** any of the blocked URL strings. For example:

```javascript
blockedUrls: ['login.apus.edu']
```

Will block URLs like:
- `https://login.apus.edu/padsts/profile/create?s=amu-app`
- `https://login.apus.edu/auth/login`
- Any URL containing `login.apus.edu`

### When Events Fire

| Scenario | Event Fired |
|----------|-------------|
| Direct link click to blocked URL | ✅ `loadBlocked` |
| Link with `target="_blank"` to blocked URL | ✅ `loadBlocked` |
| Form submission to blocked URL | ✅ `loadBlocked` |
| `window.open()` with blocked URL | ✅ `loadBlocked` |
| XHR/Fetch to blocked domain | ❌ Not blocked (API calls allowed) |

## Your Specific Case

For the "Apply Now" button:

```html
<a href="https://login.apus.edu/padsts/profile/create?s=amu-app" 
   class="btn btn-primary" 
   target="_blank" 
   data-id="main-contents">
    Apply Now
</a>
```

Setup code:

```javascript
// Create WebView with blocked URLs
EmbeddedWebView.create(
    'main',
    'https://myapp.com/page',
    {
        blockedUrls: ['login.apus.edu']  // Block the Apply Now URL
    }
);

// Listen for blocked navigation
document.addEventListener('embeddedwebview.main.loadBlocked', function(event) {
    console.log('Apply Now clicked (blocked):', event.detail);
    
    // Now you can:
    // 1. Show a custom dialog
    // 2. Handle login flow
    // 3. Trigger app-specific actions
    // 4. etc.
    
    window.TriggerOnLoadToScreenNav(event.detail);
});
```

## Event Object Structure

```javascript
event.detail === "https://login.apus.edu/padsts/profile/create?s=amu-app"
```

The `event.detail` contains the full URL string that was blocked.

## Important Notes

1. **Event fires even though navigation is blocked** - The page doesn't navigate, only the event is fired
2. **Works with `target="_blank"`** - Fixed in latest version to handle new window requests
3. **Case-sensitive matching** - `blockedUrls: ['Login']` won't match `https://login.apus.edu`
4. **Substring matching** - `blockedUrls: ['apus.edu']` will block any URL containing that string
5. **Event fires in the embedded WebView** - Not in the main app WebView

## Troubleshooting

If the event is not firing:

1. **Check the WebView ID matches**:
   ```javascript
   // Create with ID 'myscreen'
   EmbeddedWebView.create('myscreen', url, options);
   
   // Listen with same ID
   document.addEventListener('embeddedwebview.myscreen.loadBlocked', ...);
   ```

2. **Check blockedUrls is an array**:
   ```javascript
   blockedUrls: ['login.apus.edu']  // ✅ Correct
   blockedUrls: 'login.apus.edu'    // ❌ Wrong
   ```

3. **Check URL substring matches**:
   ```javascript
   // Both will block the Apply Now URL
   blockedUrls: ['login.apus.edu']
   blockedUrls: ['apus.edu']
   blockedUrls: ['padsts/profile']
   ```

4. **Enable logging to debug**:
   ```javascript
   document.addEventListener('embeddedwebview.myscreen.loadBlocked', function(event) {
       console.log('[DEBUG] Blocked URL:', event.detail);
       console.log('[DEBUG] Event received at:', new Date().toISOString());
   });
   ```

## Android Implementation Details

The plugin now handles blocked URLs in THREE scenarios:

1. **Direct navigation** - Handled by `WebViewClient.shouldOverrideUrlLoading()`
2. **Programmatic loads** - Handled by checking in `loadUrl()` method
3. **New window requests** - Handled by `WebChromeClient.onCreateWindow()` ← This is new for `target="_blank"`

All three scenarios fire the `loadBlocked` event and return the blocked URL as `event.detail`.
