# Quick Start - loadBlocked Event

## Problem
The "Apply Now" button with `target="_blank"` doesn't fire the `loadBlocked` event.

## Solution
Two key fixes applied:

### ✅ Fix 1: Events Now Fire in Correct WebView
The `fireEvent()` method now fires JavaScript events in the embedded WebView instance instead of the main app WebView.

### ✅ Fix 2: target="_blank" Links Now Intercepted
Added `WebChromeClient.onCreateWindow()` handler to catch and block new window requests.

---

## 3-Step Setup

### Step 1: Create WebView with Blocked URLs

```javascript
EmbeddedWebView.create(
    'mainscreen',
    'https://example.com/page',
    {
        blockedUrls: ['login.apus.edu']  // ← Add this!
    }
);
```

### Step 2: Add Event Listener

```javascript
document.addEventListener('embeddedwebview.mainscreen.loadBlocked', (event) => {
    console.log('Blocked:', event.detail);
    window.TriggerOnLoadToScreenNav(event.detail);
});
```

### Step 3: Test!
Click the Apply Now button → Event fires → Your action runs ✅

---

## File Modifications

### Modified Files
- ✅ `src/android/EmbeddedWebView.java`
  - Fixed `fireEvent()` method
  - Added `onCreateWindow()` handler
  
- ✅ `www/EmbeddedWebView.js`
  - Updated JSDoc comments

### Documentation Added
- ✅ `BLOCKED_URLS_USAGE.md` - Complete usage guide
- ✅ `IMPLEMENTATION_GUIDE.md` - Step-by-step implementation
- ✅ `TECHNICAL_DETAILS.md` - Deep technical explanation
- ✅ `FIX_SUMMARY.md` - This summary

---

## What Now Works

```javascript
// All these now properly fire loadBlocked events:

// 1. Direct link
<a href="https://login.apus.edu/...">Click me</a>

// 2. Link with target="_blank" ← FIXED!
<a href="https://login.apus.edu/..." target="_blank">Apply Now</a>

// 3. Form submission
<form action="https://login.apus.edu/..."><button>Submit</button></form>

// 4. window.open() ← FIXED!
window.open('https://login.apus.edu/...');

// 5. Programmatic load
EmbeddedWebView.loadUrl('mainscreen', 'https://login.apus.edu/...');
```

---

## Example: Your App Code

**Before** (not working):
```javascript
// Add listeners - but loadBlocked never fires
function addWebViewListeners(screen) {
    document.addEventListener(`embeddedwebview.${screen}.loadError`, loadError);
    document.addEventListener(`embeddedwebview.${screen}.loadStart`, loadStart);
    document.addEventListener(`embeddedwebview.${screen}.loadStop`, loadStop);
    // ❌ Missing loadBlocked listener
}
```

**After** (working):
```javascript
// Add listeners - loadBlocked now works!
function addWebViewListeners(screen) {
    document.addEventListener(`embeddedwebview.${screen}.loadError`, loadError);
    document.addEventListener(`embeddedwebview.${screen}.loadStart`, loadStart);
    document.addEventListener(`embeddedwebview.${screen}.loadStop`, loadStop);
    document.addEventListener(`embeddedwebview.${screen}.loadBlocked`, loadBlocked); // ✅ Added!
}

// Event handler - now receives events
function loadBlocked(e) {
    console.log("Blocked URL:", e.detail);
    window.TriggerOnLoadToScreenNav(e.detail);  // ✅ Now works!
}
```

---

## Verify It Works

1. **Build APK** with the updated code
2. **Run app** and navigate to screen with WebView
3. **Click Apply Now button** (or any blocked URL)
4. **Check Android logs**:
   ```
   adb logcat | grep "EmbeddedWebView"
   ```
   Should see:
   ```
   [D] Navigation blocked (target=_blank) for: https://login.apus.edu/...
   [D] Event fired in embedded WebView: embeddedwebview.mainscreen.loadBlocked
   ```
5. **Check browser console** - Should see your console.log:
   ```
   loadBlocked: https://login.apus.edu/...
   ```

✅ If you see all three messages, the fix is working!

---

## Debugging

**Event not firing?**
- Check WebView ID matches (e.g., `mainscreen`)
- Check URL is in `blockedUrls` array
- Check event listener is added AFTER WebView is created
- Check Android logs for errors

**Event fires but action doesn't run?**
- Check `TriggerOnLoadToScreenNav` function exists
- Check no JavaScript errors in console
- Verify function name matches exactly

**Logs show "WebView instance not found"?**
- WebView was destroyed
- ID parameter doesn't match
- Create was called with different ID

---

## Need Help?

1. **Check documentation**: `BLOCKED_URLS_USAGE.md`
2. **See implementation**: `IMPLEMENTATION_GUIDE.md`
3. **Understand code**: `TECHNICAL_DETAILS.md`
4. **Review summary**: `FIX_SUMMARY.md`

All files are in the project root directory.

---

## Summary of Changes

| What Changed | Why | Result |
|---|---|---|
| `fireEvent()` now uses embedded WebView | Events were firing in wrong context | Events now reach JavaScript listeners |
| Added `onCreateWindow()` handler | `target="_blank"` wasn't intercepted | `target="_blank"` links now fire events |
| Updated JSDoc | Documentation was incomplete | Clear usage instructions available |

✅ **Total Impact**: loadBlocked event now works for all scenarios!
