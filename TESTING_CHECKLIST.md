# Installation & Testing Checklist

## 📋 Pre-Installation

- [ ] Back up your current Android project
- [ ] Have the updated EmbeddedWebView.java file ready
- [ ] Have Android Studio or your build tool ready
- [ ] Have a test device connected (for APK testing)

---

## 🔧 Installation Steps

### Step 1: Update Java Code
- [ ] Open `src/android/EmbeddedWebView.java`
- [ ] Ensure changes are present:
  - [ ] `fireEvent()` method uses `instance.webView` (NOT `cordovaWebView`)
  - [ ] `WebChromeClient` has `onCreateWindow()` method
  - [ ] Methods have proper logging

### Step 2: Update JavaScript (Optional but Recommended)
- [ ] Update `www/EmbeddedWebView.js` with new JSDoc comments
- [ ] Or keep existing if no changes needed (backward compatible)

### Step 3: Clean Build
```bash
# Clean previous build
./gradlew clean

# Build new APK
./gradlew assembleDebug  # or assembleRelease

# Or in Android Studio:
# Build > Clean Project
# Build > Build Bundle/APK
```

### Step 4: Deploy APK
- [ ] Deploy to test device using Android Studio or adb:
  ```bash
  adb install -r app-debug.apk
  ```

---

## 🧪 Verification Steps

### Step 1: Start App & Navigate to WebView Screen
- [ ] Launch the app
- [ ] Navigate to screen that has the embedded WebView
- [ ] Verify WebView loads correctly
- [ ] Verify other events (loadStart, loadStop) work

### Step 2: Check Event Listener is Added
```javascript
// Add debug logging
document.addEventListener('embeddedwebview.mainscreen.loadBlocked', (event) => {
    console.log('✅ loadBlocked received:', event.detail);
});
```

### Step 3: Test Blocked URL Click
1. Find the "Apply Now" button or any blocked URL
2. Click on the button
3. Page should NOT navigate (blocked)
4. Check for signs of success:
   - [ ] Android logcat shows success messages
   - [ ] Browser console shows `loadBlocked` event
   - [ ] Your app action was triggered

### Step 4: Android Logcat Verification
```bash
# In terminal, start logcat
adb logcat | grep "EmbeddedWebView"

# Or in Android Studio: View > Tool Windows > Logcat
```

**Expected logs when clicking blocked URL:**
```
[D/EmbeddedWebView] New window URL (target=_blank): https://login.apus.edu/...
[D/EmbeddedWebView] Navigation blocked (target=_blank) for: https://login.apus.edu/...
[D/EmbeddedWebView] Event fired in embedded WebView: embeddedwebview.mainscreen.loadBlocked
```

✅ If you see ALL THREE logs, the fix is working!

### Step 5: Browser Console Verification
1. Open browser developer tools (F12)
2. Go to Console tab
3. Click Apply Now button again
4. Should see:
   ```
   [Native] Firing: embeddedwebview.mainscreen.loadBlocked
   loadBlocked: https://login.apus.edu/...
   ```

✅ If you see these messages, JavaScript received the event!

### Step 6: Action Verification
1. Check if your action was triggered
2. Did `TriggerOnLoadToScreenNav()` run?
3. Did it receive the correct URL as parameter?
4. Did your app perform the expected action?

✅ If yes, the fix is completely working!

---

## 🚨 Troubleshooting

### ❌ No Logcat Messages
**Possible Causes:**
- APK wasn't properly deployed
- Device disconnected
- Logcat filter is wrong
- WebView ID doesn't match

**Solutions:**
```bash
# Verify APK is installed
adb shell pm list packages | grep com.yourapp

# Reinstall APK
adb uninstall com.yourapp
adb install -r app-debug.apk

# Clear logcat and try again
adb logcat -c
# Click button
adb logcat | grep "EmbeddedWebView"
```

### ❌ Logcat Shows Success but No Browser Console Message
**Possible Causes:**
- Event fired but listener not attached
- Wrong WebView ID used
- JavaScript error in listener

**Solutions:**
```javascript
// Add more detailed logging
console.log('About to add listener...');
document.addEventListener('embeddedwebview.mainscreen.loadBlocked', (e) => {
    console.log('EVENT RECEIVED:', e);
    console.log('Event detail:', e.detail);
    console.log('Event type:', e.type);
});
console.log('Listener added!');
```

### ❌ Browser Shows "loadBlocked: undefined" (Wrong Detail)
**Possible Causes:**
- Event.detail is not the URL
- Payload construction issue

**Solutions:**
```javascript
// Check what's in the event
document.addEventListener('embeddedwebview.mainscreen.loadBlocked', (e) => {
    console.log('Full event:', JSON.stringify(e, null, 2));
    console.log('e.detail type:', typeof e.detail);
    console.log('e.detail value:', e.detail);
});
```

### ❌ Action Runs but with Wrong URL
**Possible Causes:**
- URL is being escaped
- Event detail format changed

**Solutions:**
```javascript
function loadBlocked(e) {
    var data = e.detail;
    console.log('Raw data:', data);
    console.log('Data type:', typeof data);
    console.log('Data length:', data.length);
    
    // Make sure it's a string
    if (typeof data === 'string') {
        console.log('✅ Data is correct string');
        window.TriggerOnLoadToScreenNav(data);
    } else {
        console.error('❌ Data is not a string:', typeof data);
    }
}
```

---

## ✅ Success Indicators

You'll know the fix is working when you see:

### In Android Logcat:
```
✅ [D/EmbeddedWebView] New window URL (target=_blank): https://login.apus.edu/...
✅ [D/EmbeddedWebView] Navigation blocked (target=_blank) for: https://login.apus.edu/...
✅ [D/EmbeddedWebView] Event fired in embedded WebView: embeddedwebview.mainscreen.loadBlocked
```

### In Browser Console:
```
✅ [Native] Firing: embeddedwebview.mainscreen.loadBlocked
✅ loadBlocked: https://login.apus.edu/...
```

### In Your App:
```
✅ Action TriggerOnLoadToScreenNav was called
✅ URL parameter was correct
✅ App performed expected action
```

### In Your UI:
```
✅ Button click doesn't navigate away
✅ Custom dialog/action appears instead
✅ User can proceed with app flow
```

---

## 📊 Testing Matrix

### Test Case 1: Direct Link Click
```html
<a href="https://login.apus.edu/profile">Click</a>
```
- Expected: ✅ loadBlocked fires
- Action: App specific

### Test Case 2: target="_blank" Link (MAIN FIX)
```html
<a href="https://login.apus.edu/profile" target="_blank">Apply Now</a>
```
- Expected: ✅ loadBlocked fires
- Action: App specific

### Test Case 3: Form Submission
```html
<form action="https://login.apus.edu/profile"><button>Submit</button></form>
```
- Expected: ✅ loadBlocked fires
- Action: App specific

### Test Case 4: window.open() (BONUS FIX)
```javascript
window.open('https://login.apus.edu/profile');
```
- Expected: ✅ loadBlocked fires
- Action: App specific

### Test Case 5: Allowed URL Click
```html
<a href="https://myapp.com/page">Continue</a>
```
- Expected: ✅ Normal navigation (NO loadBlocked)
- Result: Page loads normally

---

## 📈 Performance Checklist

- [ ] App doesn't crash on blocked URL
- [ ] Event fires immediately (no lag)
- [ ] Action executes smoothly
- [ ] No memory leaks
- [ ] No battery drain
- [ ] Smooth scrolling unaffected
- [ ] Other WebView features work normally

---

## 🔄 Rollback Plan (If Needed)

If something goes wrong:

1. Restore original `EmbeddedWebView.java`
2. Rebuild APK
3. Reinstall on device
4. Check if issue resolves

But we believe the fix is solid! ✅

---

## 📞 Support Resources

1. **QUICK_START.md** - Fast getting started
2. **BLOCKED_URLS_USAGE.md** - Complete usage docs
3. **IMPLEMENTATION_GUIDE.md** - Integration help
4. **TECHNICAL_DETAILS.md** - Deep dive
5. **FIX_SUMMARY.md** - What changed

---

## ✨ Final Checklist

- [ ] APK deployed successfully
- [ ] App launches without crashes
- [ ] WebView loads and displays content
- [ ] Other events (loadStart, loadStop) work
- [ ] Apply Now button click is detected
- [ ] Android logs show expected messages
- [ ] Browser console shows event received
- [ ] App action is triggered
- [ ] User can proceed with app flow

**If all checked ✅ = Fix is working!**

---

## 🎉 You're Done!

The `loadBlocked` event is now fully functional for:
- ✅ Direct links
- ✅ target="_blank" links  
- ✅ Form submissions
- ✅ window.open() calls
- ✅ Programmatic loads

Enjoy your fixed WebView plugin! 🚀
