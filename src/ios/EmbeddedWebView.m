//
//  EmbeddedWebView.m
//  Cordova Plugin - EmbeddedWebView
//

#import "EmbeddedWebView.h"
#import <WebKit/WebKit.h>
#import <Cordova/CDV.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#pragma mark - Instance holder

@interface EmbeddedWebViewInstance : NSObject
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UIView *container;
@property (nonatomic, assign) BOOL canGoBack;
@property (nonatomic, assign) BOOL canGoForward;
@property (nonatomic, assign) BOOL historyCleared;
@property (nonatomic, strong) NSDictionary *cookies;
@property (nonatomic, strong) NSArray *blockedUrls; 
@property (nonatomic, strong) NSArray *historySkipUrls; 
@property (nonatomic, copy) NSString *lastReportedUrl;
@end

@implementation EmbeddedWebViewInstance
@end

#pragma mark - Plugin Interface

@interface EmbeddedWebView () <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>

@property (nonatomic, strong) NSMutableDictionary *instances;
@property (nonatomic, strong) NSString *lastCreatedId;
@property (nonatomic, strong) NSString *currentCallbackId;

- (EmbeddedWebViewInstance *)instanceForId:(NSString *)instanceId command:(CDVInvokedUrlCommand *)command;
- (NSString *)instanceIdForWebView:(WKWebView *)webView;
- (void)destroyInstanceWithId:(NSString *)instanceId sendCallback:(BOOL)sendCallback callbackId:(NSString *)callbackId;
- (void)updateNavigationStateForInstanceId:(NSString *)instanceId;
- (void)fireEvent:(NSString *)eventName forInstanceId:(NSString *)instanceId withData:(NSString *)data;
- (UIColor *)colorFromHexString:(NSString *)hexString;
- (void)handleLoadError:(NSError *)error webView:(WKWebView *)webView;
- (NSString *)jsonStringFromDictionary:(NSDictionary *)dict; 
- (UIWindow *)activeWindow;

@end

@implementation EmbeddedWebView

+ (WKProcessPool *)sharedProcessPool {
    static WKProcessPool *_sharedPool = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedPool = [[WKProcessPool alloc] init];
    });
    return _sharedPool;
}

- (UIWindow *)activeWindow {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            for (UIWindow *candidate in windowScene.windows) {
                if (candidate.isKeyWindow) {
                    return candidate;
                }
                if (!window) {
                    window = candidate;
                }
            }
        }
    }

    if (!window) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        window = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    }
    return window;
}

- (void)pluginInitialize {
    [super pluginInitialize];
    self.instances = [NSMutableDictionary dictionary];
    self.lastCreatedId = nil;
    self.currentCallbackId = nil;
    NSLog(@"[EmbeddedWebView] Plugin initialized");
}

#pragma mark - Helper: instance lookup

- (EmbeddedWebViewInstance *)instanceForId:(NSString *)instanceId
                                   command:(CDVInvokedUrlCommand *)command {
    EmbeddedWebViewInstance *instance = self.instances[instanceId];
    if (!instance || !instance.webView) {
        if (command) {
            NSString *msg = [NSString stringWithFormat:@"WebView instance not found for id: %@", instanceId];
            CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                     messageAsString:msg];
            [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        }
        return nil;
    }
    return instance;
}

- (NSString *)instanceIdForWebView:(WKWebView *)webView {
    for (NSString *key in self.instances) {
        EmbeddedWebViewInstance *inst = self.instances[key];
        if (inst.webView == webView) {
            return key;
        }
    }
    return nil;
}

// --- HELPER: CHECK IF URL IS BLOCKED ---
- (BOOL)isUrlBlocked:(NSString *)url forInstance:(EmbeddedWebViewInstance *)instance {
    if (instance.blockedUrls && instance.blockedUrls.count > 0) {
        for (NSString *blocked in instance.blockedUrls) {
            if ([url containsString:blocked]) {
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark - Create

- (void)create:(CDVInvokedUrlCommand*)command {
    NSLog(@"[EmbeddedWebView] Creating WebView");

    NSString *instanceId = [command argumentAtIndex:0];
    NSString *url = [command argumentAtIndex:1];
    NSDictionary *options = [command argumentAtIndex:2 withDefault:@{}];

    EmbeddedWebViewInstance *instance = [[EmbeddedWebViewInstance alloc] init];
    instance.canGoBack = NO;
    instance.canGoForward = NO;
    instance.historyCleared = NO;

    if ([options[@"cookies"] isKindOfClass:[NSDictionary class]]) {
        instance.cookies = options[@"cookies"];
    }
    
    if ([options[@"blockedUrls"] isKindOfClass:[NSArray class]]) {
        instance.blockedUrls = options[@"blockedUrls"];
    }

    if ([options[@"historySkipUrls"] isKindOfClass:[NSArray class]]) {
        instance.historySkipUrls = options[@"historySkipUrls"];
    }

    if (!instanceId || instanceId.length == 0) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                    messageAsString:@"id must be a non-empty string"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    if (!url || url.length == 0) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                    messageAsString:@"URL must be a non-empty string"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    if (self.instances[instanceId]) {
        NSLog(@"[EmbeddedWebView] Instance already exists for id: %@, ignoring duplicate create", instanceId);
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"WebView instance already exists"] callbackId:command.callbackId];
        return;
    }

    [self.commandDelegate runInBackground:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                
                // --- OPTIMIZATION: Check block list BEFORE creating view logic if possible, 
                // but we need the instance first. We check before the final loadRequest. ---

                // --- 1. LAYOUT & WINDOW FINDER ---
                NSNumber *topOffset = options[@"top"] ?: @0;
                NSNumber *bottomOffset = options[@"bottom"] ?: @0;

                instance.container = [[UIView alloc] init];
                instance.container.backgroundColor = [UIColor clearColor];

                // --- 2. CONFIGURATION ---
                WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
                config.processPool = [EmbeddedWebView sharedProcessPool];
                config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
                config.allowsInlineMediaPlayback = YES;

                // --- 3. JS INJECTIONS ---
                NSString *resizeObserverFix = 
                    @"var _RO = window.ResizeObserver;"
                    @"if(_RO) { window.ResizeObserver = class extends _RO { constructor(callback) { super((entries, observer) => { window.requestAnimationFrame(() => { callback(entries, observer); }); }); } }; }";
                [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:resizeObserverFix injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
                
            // --- IMPROVED ERROR SUPPRESSION ---
            NSString *debugScript =
                @"function shouldIgnore(msg) { "
                @"  if (!msg) return false; "
                @"  var s = msg.toString().toLowerCase(); "
                @"  return s.indexOf('resizeobserver') !== -1 || s.indexOf('script error') !== -1; "
                @"} "
                // 1. Catch the Event immediately to stop propagation
                @"window.addEventListener('error', function(e) { "
                @"  if (shouldIgnore(e.message)) { "
                @"    e.stopImmediatePropagation(); "
                @"    e.preventDefault(); "
                @"  } "
                @"}); "
                // 2. Catch window.onerror for standard logging
                @"window.onerror = function(msg, url, line) { "
                @"  if (shouldIgnore(msg)) return true; " // returning true prevents default browser error
                @"  window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-fatal', msg: msg, line: line, url: url}); "
                @"}; "
                // 3. Filter Console Logs
                @"var origLog = console.log; "
                @"console.log = function() { "
                @"  var msg = Array.from(arguments).join(' '); "
                @"  if(shouldIgnore(msg)) return; "
                @"  origLog.apply(console, arguments); "
                @"  window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-log', msg: msg}); "
                @"};";

            [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:debugScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
            [config.userContentController addScriptMessageHandler:self name:@"consoleHandler"];

            // --- 3b. SPA URL CHANGE TRACKING ---
            // WKWebView navigation delegate + URL KVO do not reliably fire for client-side
            // (same-document) navigations used by SPAs. Hook history/Navigation APIs to report
            // the full URL back to native, which then fires the `urlChanged` JS event.
            NSString *urlTrackScript =
                @"(function(){"
                @"  if (window.__ewvUrlHookInstalled) return;"
                @"  window.__ewvUrlHookInstalled = true;"
                @"  var post = function(u){"
                @"    try { window.webkit.messageHandlers.urlChangeHandler.postMessage(u || location.href); } catch(e){}"
                @"  };"
                @"  var wrap = function(type){"
                @"    var orig = history[type];"
                @"    if (typeof orig !== 'function') return;"
                @"    history[type] = function(){"
                @"      var rv = orig.apply(this, arguments);"
                @"      post();"
                @"      return rv;"
                @"    };"
                @"  };"
                @"  wrap('pushState');"
                @"  wrap('replaceState');"
                @"  window.addEventListener('popstate', function(){ post(); });"
                @"  window.addEventListener('hashchange', function(){ post(); });"
                // window.navigation may not exist yet at document-start; retry until available.
                @"  var navHooked = false;"
                @"  var hookNav = function(){"
                @"    if (navHooked) return true;"
                @"    if (!(window.navigation && window.navigation.addEventListener)) return false;"
                @"    navHooked = true;"
                @"    window.navigation.addEventListener('navigate', function(e){"
                @"      try { post(e.destination && e.destination.url ? e.destination.url : location.href); } catch(err){ post(); }"
                @"    });"
                @"    window.navigation.addEventListener('navigatesuccess', function(){ post(); });"
                @"    return true;"
                @"  };"
                @"  if (!hookNav()) {"
                @"    var tries = 0;"
                @"    var t = setInterval(function(){"
                @"      if (hookNav() || ++tries > 100) clearInterval(t);"
                @"    }, 100);"
                @"    document.addEventListener('DOMContentLoaded', hookNav);"
                @"    window.addEventListener('load', hookNav);"
                @"  }"
                @"  post();"
                @"})();";
            [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:urlTrackScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
            [config.userContentController addScriptMessageHandler:self name:@"urlChangeHandler"];

            // --- 4. COOKIE PREP ---
            NSURL *pageURL = [NSURL URLWithString:url];
            NSString *rawHost = pageURL.host;
                NSString *cookieDomain = nil;
                
                if (rawHost && ![rawHost isEqualToString:@"localhost"]) {
                    if ([rawHost hasPrefix:@"www."]) rawHost = [rawHost substringFromIndex:4];
                    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$" options:0 error:nil];
                    if ([regex numberOfMatchesInString:rawHost options:0 range:NSMakeRange(0, [rawHost length])] == 0) {
                        cookieDomain = [NSString stringWithFormat:@".%@", rawHost];
                    } else {
                        cookieDomain = rawHost;
                    }
                }
                
                if (instance.cookies && instance.cookies.count > 0) {
                    NSMutableString *cookieJs = [NSMutableString string];
                    for (NSString *name in instance.cookies) {
                        NSString *val = [[instance.cookies[name] description] stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
                        [cookieJs appendFormat:@"document.cookie='%@=%@; path=/';", name, val];
                    }
                    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:cookieJs injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
                }

                // --- 4a. VIEWPORT / ZOOM HANDLING (UPDATED) ---
                BOOL enableZoom = [options[@"enableZoom"] boolValue];
                if (enableZoom) {
                    NSString *viewport = @"var meta = document.createElement('meta'); meta.name = 'viewport'; meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes'; document.getElementsByTagName('head')[0].appendChild(meta);";
                    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:viewport injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
                } else {
                    // Inject strict viewport rules to prevent JS/CSS scaling
                    NSString *noZoomScript = @"var meta = document.createElement('meta'); meta.name = 'viewport'; meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no'; document.getElementsByTagName('head')[0].appendChild(meta);";
                    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:noZoomScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
                }

                // --- 5. VIEW CREATION ---
                WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
                instance.webView = webView;
                webView.navigationDelegate = self;
                webView.UIDelegate = self;
                webView.backgroundColor = [UIColor clearColor];
                webView.opaque = NO;
                if (@available(iOS 16.4, *)) { @try { [webView setValue:@YES forKey:@"inspectable"]; } @catch (NSException *e) {} }
                if (options[@"userAgent"]) webView.customUserAgent = options[@"userAgent"];
                
                // --- 5a. NATIVE ZOOM LOCK (UPDATED) ---
                // Physically lock the scroll view to prevent pinch gestures
                if (!enableZoom) {
                    webView.scrollView.minimumZoomScale = 1.0;
                    webView.scrollView.maximumZoomScale = 1.0;
                    webView.scrollView.zoomScale = 1.0;
                    webView.scrollView.bouncesZoom = NO;
                    // Note: We do not set delegate=nil to avoid breaking other plugin features that might rely on scroll events
                }
                
                if ([options[@"clearCache"] boolValue]) {
                    NSSet *types = [NSSet setWithArray:@[WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]];
                    [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:types modifiedSince:[NSDate dateWithTimeIntervalSince1970:0] completionHandler:^{}];
                }

                [webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:nil];
                [webView addObserver:self forKeyPath:@"canGoBack" options:NSKeyValueObservingOptionNew context:nil];
                [webView addObserver:self forKeyPath:@"canGoForward" options:NSKeyValueObservingOptionNew context:nil];
                [webView addObserver:self forKeyPath:@"loading" options:NSKeyValueObservingOptionNew context:nil];
                // Observe URL directly so SPA route changes (pushState/replaceState/hash) are reported with the full URL
                [webView addObserver:self forKeyPath:@"URL" options:NSKeyValueObservingOptionNew context:nil];


                UIProgressView *progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                instance.progressBar = progressBar;
                progressBar.progressTintColor = [self colorFromHexString:options[@"progressColor"] ?: @"#2196F3"];
                progressBar.hidden = YES;
                
                [instance.container addSubview:webView];
                [instance.container addSubview:progressBar];

                UIView *mainView = self.webView.superview ?: [self activeWindow];
                if (!mainView) mainView = self.webView;
                [mainView addSubview:instance.container];

                instance.container.translatesAutoresizingMaskIntoConstraints = NO;
                webView.translatesAutoresizingMaskIntoConstraints = NO;
                progressBar.translatesAutoresizingMaskIntoConstraints = NO;
                
                CGFloat ph = [options[@"progressHeight"] floatValue] ?: 10.0;

                [NSLayoutConstraint activateConstraints:@[
                    [instance.container.leadingAnchor constraintEqualToAnchor:mainView.leadingAnchor],
                    [instance.container.trailingAnchor constraintEqualToAnchor:mainView.trailingAnchor],
                    // Anchor to the safe-area guide (plus the app-provided header/footer offsets) so the
                    // layout re-adjusts automatically & instantly on orientation changes.
                    [instance.container.topAnchor constraintEqualToAnchor:mainView.safeAreaLayoutGuide.topAnchor constant:[topOffset floatValue]],
                    [instance.container.bottomAnchor constraintEqualToAnchor:mainView.safeAreaLayoutGuide.bottomAnchor constant:-[bottomOffset floatValue]],
                    [webView.leadingAnchor constraintEqualToAnchor:instance.container.leadingAnchor],
                    [webView.trailingAnchor constraintEqualToAnchor:instance.container.trailingAnchor],
                    [webView.topAnchor constraintEqualToAnchor:instance.container.topAnchor],
                    [webView.bottomAnchor constraintEqualToAnchor:instance.container.bottomAnchor],
                    [progressBar.leadingAnchor constraintEqualToAnchor:instance.container.leadingAnchor],
                    [progressBar.trailingAnchor constraintEqualToAnchor:instance.container.trailingAnchor],
                    [progressBar.bottomAnchor constraintEqualToAnchor:instance.container.bottomAnchor],
                    [progressBar.heightAnchor constraintEqualToConstant:ph]
                ]];

                self.instances[instanceId] = instance;
                self.lastCreatedId = instanceId;

                // --- 6. COOKIE INJECTION ---
                WKHTTPCookieStore *cookieStore = config.websiteDataStore.httpCookieStore;
                NSArray *cookieKeys = instance.cookies ? instance.cookies.allKeys : @[];
                dispatch_group_t cookieGroup = dispatch_group_create();

                for (NSString *name in cookieKeys) {
                    dispatch_group_enter(cookieGroup);
                    NSString *value = [[instance.cookies[name] description] copy];
                    NSMutableDictionary *props = [NSMutableDictionary dictionary];
                    props[NSHTTPCookieName] = name;
                    props[NSHTTPCookieValue] = value;
                    props[NSHTTPCookiePath] = @"/";
                    props[NSHTTPCookieOriginURL] = url;
                    if (cookieDomain) props[NSHTTPCookieDomain] = cookieDomain;
                    props[NSHTTPCookieSecure] = @"TRUE";
                    props[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSinceNow:31536000]; 
                    if (@available(iOS 13.0, *)) { props[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteLax; }

                    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
                    [cookieStore setCookie:cookie completionHandler:^{ dispatch_group_leave(cookieGroup); }];
                }

                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
                if (options[@"headers"]) {
                    for (NSString *key in options[@"headers"]) [request setValue:options[@"headers"][key] forHTTPHeaderField:key];
                }

                dispatch_group_notify(cookieGroup, dispatch_get_main_queue(), ^{
                    __block int attempts = 0;
                    __block void (^checkAndLoad)(void) = nil;
                    
                    checkAndLoad = ^{
                        [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> * _Nonnull cookies) {
                            BOOL foundRequiredCookies = NO;
                            if (cookieKeys.count == 0 || cookies.count > 0) {
                                foundRequiredCookies = YES;
                            }
                            
                            if (foundRequiredCookies || attempts >= 10) {
                                
                                // --- FIX: PRE-CHECK BLOCKED URL (Matches Android Logic) ---
                                if ([self isUrlBlocked:url forInstance:instance]) {
                                    NSLog(@"[EmbeddedWebView] Navigation blocked (Initial Load) for: %@", url);
                                    [self fireEvent:@"loadBlocked" forInstanceId:instanceId withData:url];
                                    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"WebView created (navigation blocked)"] callbackId:command.callbackId];
                                    checkAndLoad = nil;
                                    return;
                                }
                                // -----------------------------------------------------------

                                if (attempts >= 10) NSLog(@"[EmbeddedWebView] Warning: Cookie sync timed out, forcing load.");
                                else NSLog(@"[EmbeddedWebView] Cookies verified. Loading URL.");
                                
                                [webView loadRequest:request];
                                [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"WebView created"] callbackId:command.callbackId];
                                
                                checkAndLoad = nil; 
                            } else {
                                attempts++;
                                NSLog(@"[EmbeddedWebView] Waiting for cookie sync... (Attempt %d)", attempts);
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), checkAndLoad);
                            }
                        }];
                    };
                    checkAndLoad();
                });

            } @catch (NSException *exception) {
                [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:exception.reason] callbackId:command.callbackId];
            }
        });
    }];
}

- (void)destroy:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    if (!instanceId) return;
    [self destroyInstanceWithId:instanceId sendCallback:YES callbackId:command.callbackId];
}

- (void)destroyInstanceWithId:(NSString *)instanceId sendCallback:(BOOL)sendCallback callbackId:(NSString *)callbackId {
    // We must capture the specific instance logic inside the main queue
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = self.instances[instanceId];
        
        // If the instance is gone, we can't clean up the UI, but we can still send the callback
        if (!instance) {
             if (sendCallback && callbackId) {
                 [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:callbackId];
             }
             return;
        }
        
        // 1. Cleanup WebView
        if (instance.webView) {
            instance.webView.navigationDelegate = nil;
            instance.webView.UIDelegate = nil;

            @try { [instance.webView removeObserver:self forKeyPath:@"estimatedProgress"]; } @catch(NSException *e){}
            @try { [instance.webView removeObserver:self forKeyPath:@"canGoBack"]; } @catch(NSException *e){}
            @try { [instance.webView removeObserver:self forKeyPath:@"canGoForward"]; } @catch(NSException *e){}
            @try { [instance.webView removeObserver:self forKeyPath:@"loading"]; } @catch(NSException *e){}
            @try { [instance.webView removeObserver:self forKeyPath:@"URL"]; } @catch(NSException *e){}

            @try { [instance.webView.configuration.userContentController removeScriptMessageHandlerForName:@"consoleHandler"]; } @catch(NSException *e){}
            @try { [instance.webView.configuration.userContentController removeScriptMessageHandlerForName:@"urlChangeHandler"]; } @catch(NSException *e){}
            
            [instance.webView stopLoading];
            [instance.webView removeFromSuperview]; // <--- Critical: Removes from screen
            instance.webView = nil;
        }
        
        // 2. Cleanup Container & Progress
        [instance.progressBar removeFromSuperview];
        [instance.container removeFromSuperview];
        
        // 3. Remove from Dictionary (Perform this LAST inside the block)
        [self.instances removeObjectForKey:instanceId];
        
        if (sendCallback && callbackId) {
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Destroyed"] callbackId:callbackId];
        }
    });
}

// ... [destroyAllInstances - UNCHANGED] ...

- (void)destroyAllInstances {
    // Create a copy of keys to iterate safely
    NSArray<NSString *> *keys = [self.instances.allKeys copy];
    
    for (NSString *instanceId in keys) {
        // This method already handles removal from self.instances inside its async block
        [self destroyInstanceWithId:instanceId sendCallback:NO callbackId:nil];
    }
    
    // Do NOT call [self.instances removeAllObjects] here.
    // Doing so deletes the objects before the async UI thread can retrieve them to remove the Views.
    
    self.lastCreatedId = nil;
}

- (void)loadUrl:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    NSString *url = [command argumentAtIndex:1];
    NSDictionary *headers = [command argumentAtIndex:2 withDefault:nil];
    if (!instanceId) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;
        
        // --- FIX: PRE-CHECK BLOCKED URL (Matches Android Logic) ---
        if ([self isUrlBlocked:url forInstance:instance]) {
            NSLog(@"[EmbeddedWebView] Navigation blocked (loadUrl) for: %@", url);
            [self fireEvent:@"loadBlocked" forInstanceId:instanceId withData:url];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Navigation blocked"] callbackId:command.callbackId];
            return;
        }
        // ----------------------------------------------------------

        @try {
            instance.historyCleared = NO;
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
            if (headers) {
                for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
            }
            [instance.webView loadRequest:request];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        } @catch (NSException *e) {
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:e.reason] callbackId:command.callbackId];
        }
    });
}

// ... [Rest of the file is standard, but keeping `decidePolicy` as safety net] ...

- (void)executeScript:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    NSString *script = [command argumentAtIndex:1];
    if (!instanceId || !script) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;
        [instance.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            NSString *res = result ? [NSString stringWithFormat:@"%@", result] : @"";
            if(error) res = error.localizedDescription;
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:res] callbackId:command.callbackId];
        }];
    });
}

- (void)setVisible:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    BOOL visible = [[command argumentAtIndex:1] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (instance && instance.container) {
            
            if (visible) {
                instance.container.hidden = NO;
                instance.container.alpha = 1.0;
                instance.container.userInteractionEnabled = YES;
                [instance.container.superview bringSubviewToFront:instance.container];
            } else {
                instance.container.alpha = 0.0;
                instance.container.userInteractionEnabled = NO;
                [instance.container.superview sendSubviewToBack:instance.container];
                
                NSString *pauseScript =
                    @"(function(){"
                    @"  try {"
                    @"    document.querySelectorAll('iframe[src*=\"youtube.com\"]').forEach(function(f){"
                    @"      var clone = f.cloneNode(true);"
                    @"      f.parentNode.replaceChild(clone, f);"
                    @"    });"
                    @"    var v=document.querySelectorAll('video, audio'); for(var i=0;i<v.length;i++){ v[i].pause(); }"
                    @"  } catch(e) {}"
                    @"})();";
                [instance.webView evaluateJavaScript:pauseScript completionHandler:nil];
            }
            
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        }
    });
}

- (void)reload:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (instance) {
            [instance.webView reload];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        }
    });
}

- (void)goBack:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        
        if (instance && instance.webView) {
            if (instance.historyCleared) {
                [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
                return;
            }

            if ([instance.webView isLoading]) {
                [instance.webView stopLoading];
            }

            WKBackForwardList *historyList = instance.webView.backForwardList;
            
            if (!instance.historySkipUrls || instance.historySkipUrls.count == 0) {
                if ([instance.webView canGoBack]) {
                    [instance.webView goBack];
                }
                [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
                return;
            }

            WKBackForwardListItem *targetItem = nil;
            for (NSInteger i = historyList.backList.count - 1; i >= 0; i--) {
                WKBackForwardListItem *item = historyList.backList[i];
                NSString *urlStr = item.URL.absoluteString;
                
                BOOL shouldSkip = NO;
                for (NSString *skipUrl in instance.historySkipUrls) {
                    if ([urlStr containsString:skipUrl]) {
                        shouldSkip = YES;
                        break;
                    }
                }
                
                if (!shouldSkip) {
                    targetItem = item;
                    break; 
                }
            }

            if (targetItem) {
                [instance.webView goToBackForwardListItem:targetItem];
            } else {
                if ([instance.webView canGoBack]) {
                    [instance.webView goBack];
                }
            }

            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        }
    });
}

- (void)clearHistory:(CDVInvokedUrlCommand *)command {

    NSString *instanceId = [command argumentAtIndex:0];

    dispatch_async(dispatch_get_main_queue(), ^{

        EmbeddedWebViewInstance *instance =
            [self instanceForId:instanceId command:command];

        if (!instance) return;

        // Stop loading
        [instance.webView stopLoading];

        // Reset navigation state
        instance.historyCleared = YES;
        instance.canGoBack = NO;
        instance.canGoForward = NO;
        instance.lastReportedUrl = instance.webView.URL.absoluteString;

        [self updateNavigationStateForInstanceId:instanceId];

        CDVPluginResult *result =
            [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                              messageAsString:@"History reset"];

        [self.commandDelegate sendPluginResult:result
                                    callbackId:command.callbackId];
    });
}

- (void)goForward:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;
        if (instance.historyCleared) {
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
            return;
        }
        if ([instance.webView canGoForward]) {
            [instance.webView goForward];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        }
    });
}

- (void)canGoBack:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (instance) {
            BOOL effectiveCanGoBack = [self isEffectiveGoBackAvailable:instance];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:effectiveCanGoBack] callbackId:command.callbackId];
        }
    });
}

- (BOOL)isEffectiveGoBackAvailable:(EmbeddedWebViewInstance *)instance {
    if (!instance || !instance.webView) return NO;
    if (instance.historyCleared) return NO;
    if (![instance.webView canGoBack]) return NO;
    if (!instance.historySkipUrls || instance.historySkipUrls.count == 0) return YES;
    
    WKBackForwardList *list = instance.webView.backForwardList;
    for (WKBackForwardListItem *item in list.backList) {
        NSString *url = item.URL.absoluteString;
        BOOL isSkipped = NO;
        for (NSString *skip in instance.historySkipUrls) {
            if ([url containsString:skip]) {
                isSkipped = YES;
                break;
            }
        }
        if (!isSkipped) return YES;
    }
    return NO;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"urlChangeHandler"]) {
        NSString *newUrl = [message.body isKindOfClass:[NSString class]] ? (NSString *)message.body : nil;
        if (!newUrl.length) return;

        WKWebView *messageWebView = nil;
        if ([message respondsToSelector:@selector(webView)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            messageWebView = [message performSelector:@selector(webView)];
#pragma clang diagnostic pop
        }

        NSString *instanceId = messageWebView ? [self instanceIdForWebView:messageWebView] : self.lastCreatedId;
        if (!instanceId) return;

        EmbeddedWebViewInstance *instance = self.instances[instanceId];
        if (!instance) return;

        // De-dupe: ignore if URL hasn't actually changed since last report
        if ([instance.lastReportedUrl isEqualToString:newUrl]) return;
        instance.lastReportedUrl = newUrl;

        [self fireEvent:@"urlChanged" forInstanceId:instanceId withData:newUrl];
        [self updateNavigationStateForInstanceId:instanceId];
        return;
    }
    if ([message.name isEqualToString:@"consoleHandler"]) {
        NSDictionary *body = message.body;
        NSString *msg = body[@"msg"] ?: @"";
        if ([msg rangeOfString:@"ResizeObserver" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return;
        }

        WKWebView *messageWebView = nil;
        if ([message respondsToSelector:@selector(webView)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            messageWebView = [message performSelector:@selector(webView)];
#pragma clang diagnostic pop
        }

        NSString *instanceId = messageWebView ? [self instanceIdForWebView:messageWebView] : self.lastCreatedId;
        if (instanceId) {
            NSString *json = [self jsonStringFromDictionary:body];
            [self fireEvent:@"consoleLog" forInstanceId:instanceId withData:json];
        }
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    
    NSString *instanceId = [self instanceIdForWebView:webView];
    NSURL *url = navigationAction.request.URL;
    NSString *urlString = url.absoluteString;
    NSString *scheme = [url.scheme lowercaseString];

    if (instanceId) {
        EmbeddedWebViewInstance *instance = self.instances[instanceId];
        
        // FIX: Only check blocked URLs if the view is actually visible
        if (instance && !instance.container.hidden) {
            if (instance.blockedUrls && instance.blockedUrls.count > 0) {
                for (NSString *blocked in instance.blockedUrls) {
                    if ([urlString containsString:blocked]) {
                        NSLog(@"[EmbeddedWebView] Navigation blocked for: %@", urlString);
                        [self fireEvent:@"loadBlocked" forInstanceId:instanceId withData:urlString];
                        decisionHandler(WKNavigationActionPolicyCancel);
                        return;
                    }
                }
            }
        }
    }

    // ... (Keep the rest of your standard scheme handling tel/mailto etc) ...
    if ([scheme isEqualToString:@"tel"] ||
        [scheme isEqualToString:@"mailto"] ||
        [scheme isEqualToString:@"sms"] ||
        [scheme isEqualToString:@"facetime"] ||
        [scheme isEqualToString:@"maps"]) {
        
        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    if (navigationAction.targetFrame == nil) {
        [webView loadRequest:navigationAction.request];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    if ([navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)navigationResponse.response;
        NSInteger statusCode = httpResponse.statusCode;
        if (statusCode >= 400) {
            NSString *instanceId = [self instanceIdForWebView:webView];
            NSString *url = httpResponse.URL.absoluteString;
            
            NSDictionary *errDict = @{
                @"url": url ?: [NSNull null],
                @"code": @(statusCode),
                @"message": @"HTTP Server Error"
            };
            NSString *errData = [self jsonStringFromDictionary:errDict];
            
            if (instanceId) [self fireEvent:@"loadError" forInstanceId:instanceId withData:errData];
        }
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;
        
        // FIX: Do not fire events if instance is missing OR hidden
        if (instance && !instance.container.hidden) {
            [instance.progressBar setProgress:0.0 animated:NO];
            [instance.progressBar setProgress:0.15 animated:NO];
            instance.progressBar.hidden = NO;
            [self fireEvent:@"loadStart" forInstanceId:instanceId withData:webView.URL.absoluteString];
        }
    });
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;
        
        if (instance) {
            // UI updates (Progress bar) can still happen
            [instance.progressBar setProgress:1.0 animated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ instance.progressBar.hidden = YES; });
            
            // FIX: Only fire JS events if visible
            if (!instance.container.hidden) {
                [self updateNavigationStateForInstanceId:instanceId];
                [self fireEvent:@"loadStop" forInstanceId:instanceId withData:webView.URL.absoluteString];
            }
        }
    });
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self handleLoadError:error webView:webView];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self handleLoadError:error webView:webView];
}
- (void)handleLoadError:(NSError *)error webView:(WKWebView *)webView {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil; // Lookup instance to check visibility
        
        // FIX: Do not fire error events if hidden or destroyed
        if (!instanceId || (instance && instance.container.hidden)) {
            return;
        }

        NSString *url = webView.URL.absoluteString ?: @"";
        
        NSDictionary *errDict = @{
            @"url": url,
            @"code": @(error.code),
            @"message": error.localizedDescription ?: @"Unknown error"
        };
        NSString *errorData = [self jsonStringFromDictionary:errDict];
        
        [self fireEvent:@"loadError" forInstanceId:instanceId withData:errorData];
    });
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (navigationAction.request && navigationAction.targetFrame == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ [webView loadRequest:navigationAction.request]; });
    }
    return nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"estimatedProgress"]) {
        WKWebView *webView = (WKWebView *)object;
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;
        if (instance && instance.progressBar) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (webView.estimatedProgress < instance.progressBar.progress) {
                    [instance.progressBar setProgress:webView.estimatedProgress animated:NO];
                } else {
                    [instance.progressBar setProgress:webView.estimatedProgress animated:YES];
                }
                
                if (webView.estimatedProgress >= 1.0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        instance.progressBar.hidden = YES;
                    });
                }
            });
        }
    } 
    else if ([keyPath isEqualToString:@"loading"]) {
        WKWebView *webView = (WKWebView *)object;
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;
        
        if (instance && !webView.loading) {
            dispatch_async(dispatch_get_main_queue(), ^{
                instance.progressBar.hidden = YES;
                [instance.progressBar setProgress:0.0 animated:NO]; 
            });
        }
    }
    else if ([keyPath isEqualToString:@"canGoBack"] || [keyPath isEqualToString:@"canGoForward"]) {
        WKWebView *webView = (WKWebView *)object;
        NSString *instanceId = [self instanceIdForWebView:webView];
        if (instanceId) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateNavigationStateForInstanceId:instanceId];
            });
        }
    } 
    else if ([keyPath isEqualToString:@"URL"]) {
        // Fallback for same-document navigations. The injected history/Navigation hook is the
        // primary source; this only fires if that URL wasn't already reported (de-duped).
        WKWebView *webView = (WKWebView *)object;
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;
        if (instance && !instance.container.hidden) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *currentUrl = webView.URL.absoluteString ?: @"";
                if (currentUrl.length && ![instance.lastReportedUrl isEqualToString:currentUrl]) {
                    instance.lastReportedUrl = currentUrl;
                    [self fireEvent:@"urlChanged" forInstanceId:instanceId withData:currentUrl];
                    [self updateNavigationStateForInstanceId:instanceId];
                }
            });
        }
    } 
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)updateNavigationStateForInstanceId:(NSString *)instanceId {
    EmbeddedWebViewInstance *instance = self.instances[instanceId];
    if (!instance || !instance.webView) return;
    
    BOOL newCanGoBack = [self isEffectiveGoBackAvailable:instance];
    BOOL newCanGoForward = instance.historyCleared ? NO : [instance.webView canGoForward];
    NSString *currentUrl = instance.webView.URL.absoluteString ?: @"";
    
    if (newCanGoBack != instance.canGoBack) {
        instance.canGoBack = newCanGoBack;
        NSDictionary *eventData = @{ @"value": @(instance.canGoBack), @"url": currentUrl };
        NSString *jsonData = [self jsonStringFromDictionary:eventData];
        [self fireEvent:@"canGoBackChanged" forInstanceId:instanceId withData:jsonData];
    }
    
    if (newCanGoForward != instance.canGoForward) {
        instance.canGoForward = newCanGoForward;
        NSDictionary *eventData = @{ @"value": @(instance.canGoForward), @"url": currentUrl };
        NSString *jsonData = [self jsonStringFromDictionary:eventData];
        [self fireEvent:@"canGoForwardChanged" forInstanceId:instanceId withData:jsonData];
    }
    
    NSDictionary *navDict = @{ @"canGoBack": @(instance.canGoBack), @"canGoForward": @(instance.canGoForward), @"url": currentUrl };
    NSString *navState = [self jsonStringFromDictionary:navDict];
    [self fireEvent:@"navigationStateChanged" forInstanceId:instanceId withData:navState];
}

- (NSString *)jsonStringFromDictionary:(NSDictionary *)dict {
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (!jsonData) return @"{}";
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (void)fireEvent:(NSString *)eventName forInstanceId:(NSString *)instanceId withData:(NSString *)data {
    if (!instanceId) return;
    @try {
        NSString *dataFormatted = @"null";
        if (data) {
            if ([data hasPrefix:@"{"] || [data hasPrefix:@"["] || [data isEqualToString:@"true"] || [data isEqualToString:@"false"]) {
                dataFormatted = data;
            } else {
                 dataFormatted = [NSString stringWithFormat:@"\"%@\"", [data stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
            }
        }
        
        NSString *js = [NSString stringWithFormat:@"cordova.fireDocumentEvent('embeddedwebview.%@.%@', {detail: %@});", instanceId, eventName, dataFormatted];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.commandDelegate evalJs:js]; });
    } @catch (NSException *exception) {
        NSLog(@"[EmbeddedWebView] Error firing event: %@", exception.reason);
    }
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    if (!hexString || hexString.length == 0) return [UIColor blueColor];
    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    if ([hexString hasPrefix:@"#"]) [scanner setScanLocation:1];
    [scanner scanHexInt:&rgbValue];
    return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0 green:((rgbValue & 0xFF00) >> 8)/255.0 blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
}
- (void)dispose { [self destroyAllInstances]; }
- (void)onReset { [self destroyAllInstances]; }
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { completionHandler(); }]];
    UIViewController *presentingVC = self.viewController;
    while (presentingVC.presentedViewController) { presentingVC = presentingVC.presentedViewController; }
    [presentingVC presentViewController:alertController animated:YES completion:nil];
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { completionHandler(NO); }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { completionHandler(YES); }]];
    UIViewController *presentingVC = self.viewController;
    while (presentingVC.presentedViewController) { presentingVC = presentingVC.presentedViewController; }
    [presentingVC presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Permission Handling for Microphone and Speech Recognition

#if defined(__IPHONE_15_0)
- (void)webView:(WKWebView *)webView requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin initiatedByFrame:(WKFrameInfo *)frame type:(WKMediaCaptureType)type decisionHandler:(void (^)(WKPermissionDecision))decisionHandler {
    NSString *typeStr = @"unknown";
    switch (type) {
        case WKMediaCaptureTypeMicrophone:
            typeStr = @"microphone";
            NSLog(@"[EmbeddedWebView] Permission requested for microphone (audio)");
            break;
        case WKMediaCaptureTypeCamera:
            typeStr = @"camera";
            NSLog(@"[EmbeddedWebView] Permission requested for camera (video)");
            break;
        case WKMediaCaptureTypeCameraAndMicrophone:
            typeStr = @"microphone and camera";
            NSLog(@"[EmbeddedWebView] Permission requested for microphone and camera");
            break;
    }
    
    // Handle microphone and audio permissions
    if (type == WKMediaCaptureTypeMicrophone || type == WKMediaCaptureTypeCameraAndMicrophone) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // Check current permission status
        AVAudioSessionRecordPermission permissionStatus = [AVAudioSession sharedInstance].recordPermission;
        
        switch (permissionStatus) {
            case AVAudioSessionRecordPermissionGranted: {
                NSLog(@"[EmbeddedWebView] Audio permission already granted");
                [self configureAudioSession];
                decisionHandler(WKPermissionDecisionGrant);
                break;
            }
            case AVAudioSessionRecordPermissionDenied: {
                NSLog(@"[EmbeddedWebView] Audio permission denied by user");
                decisionHandler(WKPermissionDecisionDeny);
                break;
            }
            case AVAudioSessionRecordPermissionUndetermined: {
                NSLog(@"[EmbeddedWebView] Requesting audio permission from user");
                [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) {
                            NSLog(@"[EmbeddedWebView] Audio permission granted by user");
                            [self configureAudioSession];
                            decisionHandler(WKPermissionDecisionGrant);
                        } else {
                            NSLog(@"[EmbeddedWebView] Audio permission denied by user");
                            decisionHandler(WKPermissionDecisionDeny);
                        }
                    });
                }];
                break;
            }
        }
#pragma clang diagnostic pop
    } else {
        NSLog(@"[EmbeddedWebView] Denying %@ permission", typeStr);
        decisionHandler(WKPermissionDecisionDeny);
    }
}
#endif

/**
 * Configure the audio session for recording
 */
- (void)configureAudioSession {
    @try {
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        
          // Use PlayAndRecord so capture works reliably with WebRTC/getUserMedia.
        NSError *categoryError = nil;
          [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord 
                      withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker 
                            error:&categoryError];
        
        if (categoryError) {
            NSLog(@"[EmbeddedWebView] Error setting audio session category: %@", categoryError.localizedDescription);
        } else {
            NSLog(@"[EmbeddedWebView] Audio session category set to PlayAndRecord");
        }
        
        // Activate the audio session
        NSError *activationError = nil;
        [audioSession setActive:YES 
                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation 
                         error:&activationError];
        
        if (activationError) {
            NSLog(@"[EmbeddedWebView] Error activating audio session: %@", activationError.localizedDescription);
        } else {
            NSLog(@"[EmbeddedWebView] Audio session activated successfully");
        }
    } @catch (NSException *exception) {
        NSLog(@"[EmbeddedWebView] Exception configuring audio session: %@", exception.reason);
    }
}

@end