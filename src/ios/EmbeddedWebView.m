//
//  EmbeddedWebView.m
//  Cordova Plugin - EmbeddedWebView
//

#import "EmbeddedWebView.h"
#import <WebKit/WebKit.h>
#import <Cordova/CDV.h>
#import <UIKit/UIKit.h>

#pragma mark - Instance holder

@interface EmbeddedWebViewInstance : NSObject
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UIView *container;
@property (nonatomic, assign) BOOL canGoBack;
@property (nonatomic, assign) BOOL canGoForward;
@property (nonatomic, strong) NSDictionary *cookies;
@end

@implementation EmbeddedWebViewInstance
@end

#pragma mark - Plugin

@implementation EmbeddedWebView

// -----------------------------------------------------------------------
// FIX 1: SHARED PROCESS POOL (Singleton)
// -----------------------------------------------------------------------
// This ensures all WebViews share the same cookie/cache process.
// Without this, cookies set in Native often don't appear in JS immediately.
+ (WKProcessPool *)sharedProcessPool {
    static WKProcessPool *_sharedPool = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedPool = [[WKProcessPool alloc] init];
    });
    return _sharedPool;
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

#pragma mark - Create

- (void)create:(CDVInvokedUrlCommand*)command {
    NSLog(@"[EmbeddedWebView] Creating WebView");

    NSString *instanceId = [command argumentAtIndex:0];
    NSString *url = [command argumentAtIndex:1];
    NSDictionary *options = [command argumentAtIndex:2 withDefault:@{}];

    EmbeddedWebViewInstance *instance = [[EmbeddedWebViewInstance alloc] init];
    
    // 1. Enable Inspection (Best effort for iOS 16.4+)
    if (@available(iOS 16.4, *)) {
        instance.webView.inspectable = YES; 
    }

    instance.canGoBack = NO;
    instance.canGoForward = NO;
    if ([options[@"cookies"] isKindOfClass:[NSDictionary class]]) {
        instance.cookies = options[@"cookies"];
    }

    if (!instanceId || !url) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR] callbackId:command.callbackId];
        return;
    }

    if (self.instances[instanceId]) {
        [self destroyInstanceWithId:instanceId sendCallback:NO callbackId:nil];
    }

    [self.commandDelegate runInBackground:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                // ... Layout logic (kept same) ...
                NSNumber *topOffset = options[@"top"] ?: @0;
                NSNumber *bottomOffset = options[@"bottom"] ?: @0;
                CGFloat safeTop = 0, safeBottom = 0;
                if (@available(iOS 11.0, *)) {
                    UIWindow *w = UIApplication.sharedApplication.keyWindow;
                    safeTop = w.safeAreaInsets.top; safeBottom = w.safeAreaInsets.bottom;
                }
                CGFloat finalTop = safeTop + [topOffset floatValue];
                CGFloat finalBottom = safeBottom + [bottomOffset floatValue];

                instance.container = [[UIView alloc] init];
                instance.container.backgroundColor = [UIColor clearColor];

                // --- Configuration ---
                WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
                config.processPool = [EmbeddedWebView sharedProcessPool];
                config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
                config.allowsInlineMediaPlayback = YES;

                // --- DEBUGGING: Inject Console & Error Bridge ---
                // This script captures console.log/error inside the webview and sends it to Native
                NSString *debugScript = 
                    @"window.onerror = function(msg, url, line) {"
                    @"  window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-fatal', msg: msg, line: line, url: url});"
                    @"};"
                    @"var origLog = console.log; var origWarn = console.warn; var origErr = console.error;"
                    @"console.log = function() { origLog.apply(console, arguments); var msg = Array.from(arguments).join(' '); window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-log', msg: msg}); };"
                    @"console.warn = function() { origWarn.apply(console, arguments); var msg = Array.from(arguments).join(' '); window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-warn', msg: msg}); };"
                    @"console.error = function() { origErr.apply(console, arguments); var msg = Array.from(arguments).join(' '); window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-error', msg: msg}); };";

                WKUserScript *debugUserScript = [[WKUserScript alloc] initWithSource:debugScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
                [config.userContentController addUserScript:debugUserScript];
                
                // Register the handler to receive these messages
                [config.userContentController addScriptMessageHandler:self name:@"consoleHandler"];

                // --- Cookie Injection (JS Backup) ---
                if (instance.cookies && instance.cookies.count > 0) {
                    NSMutableString *cookieJs = [NSMutableString string];
                    for (NSString *name in instance.cookies) {
                        NSString *val = [[instance.cookies[name] description] stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
                        [cookieJs appendFormat:@"document.cookie='%@=%@; path=/';", name, val];
                    }
                    WKUserScript *cookieScript = [[WKUserScript alloc] initWithSource:cookieJs injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
                    [config.userContentController addUserScript:cookieScript];
                }

                WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
                instance.webView = webView;
                webView.navigationDelegate = self;
                webView.UIDelegate = self;
                
                // ... (Layout Code & Progress Bar - Kept Same) ...
                instance.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                instance.progressBar.hidden = YES;
                [instance.container addSubview:webView];
                [instance.container addSubview:instance.progressBar];
                
                UIView *mainView = self.webView.superview ?: [UIApplication sharedApplication].keyWindow;
                [mainView addSubview:instance.container];

                // Constraints (Simplified for brevity, use your existing constraints logic)
                instance.container.translatesAutoresizingMaskIntoConstraints = NO;
                webView.translatesAutoresizingMaskIntoConstraints = NO;
                instance.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
                [NSLayoutConstraint activateConstraints:@[
                    [instance.container.topAnchor constraintEqualToAnchor:mainView.topAnchor constant:finalTop],
                    [instance.container.bottomAnchor constraintEqualToAnchor:mainView.bottomAnchor constant:-finalBottom],
                    [instance.container.leadingAnchor constraintEqualToAnchor:mainView.leadingAnchor],
                    [instance.container.trailingAnchor constraintEqualToAnchor:mainView.trailingAnchor],
                    [webView.topAnchor constraintEqualToAnchor:instance.container.topAnchor],
                    [webView.bottomAnchor constraintEqualToAnchor:instance.container.bottomAnchor],
                    [webView.leadingAnchor constraintEqualToAnchor:instance.container.leadingAnchor],
                    [webView.trailingAnchor constraintEqualToAnchor:instance.container.trailingAnchor]
                ]];

                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
                if (options[@"headers"]) {
                    for (NSString *key in options[@"headers"]) [request setValue:options[@"headers"][key] forHTTPHeaderField:key];
                }

                // Manual Header (Raw Value)
                if (instance.cookies && instance.cookies.count > 0) {
                    NSMutableString *cookieHeader = [NSMutableString string];
                    for (NSString *name in instance.cookies) {
                        if (cookieHeader.length > 0) [cookieHeader appendString:@"; "];
                        [cookieHeader appendFormat:@"%@=%@", name, instance.cookies[name]];
                    }
                    [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
                }

                // --- Cookie Store Logic (Async) ---
                WKHTTPCookieStore *cookieStore = config.websiteDataStore.httpCookieStore;
                NSURL *pageURL = [NSURL URLWithString:url];
                NSString *rawHost = pageURL.host;
                BOOL isSecure = [url.lowercaseString hasPrefix:@"https"];
                
                NSString *cookieDomain = nil;
                // Check if IP
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$" options:0 error:nil];
                if ([regex numberOfMatchesInString:rawHost options:0 range:NSMakeRange(0, rawHost.length)] == 0 && ![rawHost isEqualToString:@"localhost"]) {
                    cookieDomain = [rawHost hasPrefix:@"www."] ? [rawHost substringFromIndex:3] : rawHost;
                }

                dispatch_group_t cookieGroup = dispatch_group_create();
                for (NSString *name in instance.cookies) {
                    dispatch_group_enter(cookieGroup);
                    NSMutableDictionary *props = [NSMutableDictionary dictionary];
                    props[NSHTTPCookieName] = name;
                    props[NSHTTPCookieValue] = [instance.cookies[name] description];
                    props[NSHTTPCookiePath] = @"/";
                    if (cookieDomain) props[NSHTTPCookieDomain] = cookieDomain;
                    if (isSecure) props[NSHTTPCookieSecure] = @"TRUE";
                    if (@available(iOS 13.0, *)) props[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteLax;

                    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
                    if (cookie) [cookieStore setCookie:cookie completionHandler:^{ dispatch_group_leave(cookieGroup); }];
                    else dispatch_group_leave(cookieGroup);
                }

                self.instances[instanceId] = instance;
                
                dispatch_group_notify(cookieGroup, dispatch_get_main_queue(), ^{
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [webView loadRequest:request];
                        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"WebView created"] callbackId:command.callbackId];
                    });
                });

            } @catch (NSException *exception) {
                [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:exception.reason] callbackId:command.callbackId];
            }
        });
    }];
}


// Handles messages sent from the JavaScript console bridge
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"consoleHandler"]) {
        NSDictionary *body = message.body;
        NSString *instanceId = [self instanceIdForWebView:message.webView];
        
        if (instanceId) {
            // Create a JSON string to pass back to Cordova
            NSString *type = body[@"type"] ?: @"unknown";
            NSString *msg = body[@"msg"] ?: @"";
            
            // Format: {"type":"js-error", "message":"ReferenceError...", "url": "..."}
            NSString *json = [NSString stringWithFormat:@"{\"type\":\"%@\", \"message\":\"%@\"}", type, [msg stringByReplacingOccurrencesOfString:@"\"" withString:@"\\'"]];
            
            // Fire event: 'embeddedwebview.consoleLog'
            [self fireEvent:@"consoleLog" forInstanceId:instanceId withData:json];
        }
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    
    if ([navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)navigationResponse.response;
        NSInteger statusCode = httpResponse.statusCode;
        
        // If 4xx or 5xx error
        if (statusCode >= 400) {
            NSString *instanceId = [self instanceIdForWebView:webView];
            NSString *url = httpResponse.URL.absoluteString;
            NSString *errData = [NSString stringWithFormat:@"{\"url\":\"%@\", \"code\":%ld, \"message\":\"HTTP Server Error\"}", url, (long)statusCode];
            
            NSLog(@"[EmbeddedWebView] HTTP Error %ld for URL: %@", (long)statusCode, url);
            
            if (instanceId) {
                [self fireEvent:@"loadError" forInstanceId:instanceId withData:errData];
            }
        }
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

#pragma mark - Destroy

// JS: EmbeddedWebView.destroy(id, ...)
- (void)destroy:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    if (!instanceId) return;
    [self destroyInstanceWithId:instanceId sendCallback:YES callbackId:command.callbackId];
}

- (void)destroyInstanceWithId:(NSString *)instanceId sendCallback:(BOOL)sendCallback callbackId:(NSString *)callbackId {
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = self.instances[instanceId];
        if (!instance) {
             if (sendCallback) [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:callbackId];
             return;
        }
        
        if (instance.webView) {
            @try { [instance.webView removeObserver:self forKeyPath:@"estimatedProgress"]; } @catch(NSException *e){}
            [instance.webView stopLoading];
            [instance.webView removeFromSuperview];
            instance.webView.navigationDelegate = nil;
            instance.webView.UIDelegate = nil;
            instance.webView = nil;
        }
        [instance.progressBar removeFromSuperview];
        [instance.container removeFromSuperview];
        [self.instances removeObjectForKey:instanceId];
        
        if (sendCallback) {
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Destroyed"] callbackId:callbackId];
        }
    });
}


- (void)destroyAllInstances {
    NSArray<NSString *> *keys = [self.instances.allKeys copy];
    for (NSString *instanceId in keys) {
        [self destroyInstanceWithId:instanceId sendCallback:NO callbackId:nil];
    }
    [self.instances removeAllObjects];
    self.lastCreatedId = nil;
}

#pragma mark - loadUrl

// JS: EmbeddedWebView.loadUrl(id, url, headers?, ...)
- (void)loadUrl:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    NSString *url = [command argumentAtIndex:1];
    NSDictionary *headers = [command argumentAtIndex:2 withDefault:nil];

    if (!instanceId || instanceId.length == 0) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                 messageAsString:@"id must be a non-empty string"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    if (!url || url.length == 0) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                 messageAsString:@"URL must be a non-empty string"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;

        @try {
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];

            if (headers) {
                for (NSString *key in headers) {
                    [request setValue:headers[key] forHTTPHeaderField:key];
                }
            }

            [instance.webView loadRequest:request];

            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                        messageAsString:[NSString stringWithFormat:@"URL loaded: %@", url]];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        } @catch (NSException *exception) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:[NSString stringWithFormat:@"Error loading URL: %@", exception.reason]];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

#pragma mark - executeScript

// JS: EmbeddedWebView.executeScript(id, script, ...)
- (void)executeScript:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    NSString *script = [command argumentAtIndex:1];

    if (!instanceId || instanceId.length == 0) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                 messageAsString:@"id must be a non-empty string"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    if (!script || script.length == 0) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                    messageAsString:@"script must be a non-empty string"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;

        [instance.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) {
                CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                                 messageAsString:error.localizedDescription];
                [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            } else {
                NSString *resultString = result ? [NSString stringWithFormat:@"%@", result] : @"";
                CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                                 messageAsString:resultString];
                [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
            }
        }];
    });
}

#pragma mark - setVisible

// JS: EmbeddedWebView.setVisible(id, visible, ...)
- (void)setVisible:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    BOOL visible = [[command argumentAtIndex:1] boolValue];

    if (!instanceId || instanceId.length == 0) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                 messageAsString:@"id must be a non-empty string"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;

        if (instance.container != nil) {
            instance.container.hidden = !visible;

            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                        messageAsString:[NSString stringWithFormat:@"Visibility changed to: %@", visible ? @"true" : @"false"]];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"WebView not initialized"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

#pragma mark - reload

// JS: EmbeddedWebView.reload(id, ...)
- (void)reload:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];

    if (!instanceId || instanceId.length == 0) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                 messageAsString:@"id must be a non-empty string"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;

        [instance.webView reload];

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                    messageAsString:@"WebView reloaded"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    });
}

#pragma mark - goBack

// JS: EmbeddedWebView.goBack(id, ...)
- (void)goBack:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];

    if (!instanceId || instanceId.length == 0) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                 messageAsString:@"id must be a non-empty string"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;

        if ([instance.webView canGoBack]) {
            [instance.webView goBack];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self updateNavigationStateForInstanceId:instanceId];
            });

            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                        messageAsString:@"Navigated back"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"Cannot go back"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

#pragma mark - goForward

// JS: EmbeddedWebView.goForward(id, ...)
- (void)goForward:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];

    if (!instanceId || instanceId.length == 0) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                 messageAsString:@"id must be a non-empty string"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;

        if ([instance.webView canGoForward]) {
            [instance.webView goForward];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self updateNavigationStateForInstanceId:instanceId];
            });

            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                        messageAsString:@"Navigated forward"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"Cannot go forward"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

#pragma mark - canGoBack

// JS: EmbeddedWebView.canGoBack(id, ...)
- (void)canGoBack:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];

    if (!instanceId || instanceId.length == 0) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                 messageAsString:@"id must be a non-empty string"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;

        BOOL canGoBack = [instance.webView canGoBack];
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                  messageAsBool:canGoBack];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
    });
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;

        if (instance && instance.progressBar) {
            instance.progressBar.hidden = NO;
            [instance.progressBar setProgress:0.0 animated:NO];
        }

        NSString *url = webView.URL.absoluteString ?: @"";
        NSLog(@"[EmbeddedWebView] Page started loading (id=%@): %@", instanceId, url);

        if (instanceId) {
            [self fireEvent:@"loadStart" forInstanceId:instanceId withData:url];
        }
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    dispatch_async(dispatch_get_main_queue(), ^{

        NSString *instanceId = [self instanceIdForWebView:webView];

        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;

        if (instance && instance.progressBar) {
            [instance.progressBar setProgress:1.0 animated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                instance.progressBar.hidden = YES;
            });
        }

        if (instance.cookies.count > 0) {
            for (NSString *name in instance.cookies) {
                NSString *val = [[instance.cookies[name] description]
                    stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];

                NSString *js =
                    [NSString stringWithFormat:@"document.cookie='%@=%@; path=/';",
                    name, val];

                [webView evaluateJavaScript:js completionHandler:nil];
            }
        }

        // Smooth scrolling CSS
        NSString *css = @"html, body { scroll-behavior: smooth !important; -webkit-overflow-scrolling: touch; }";
        NSString *js = [NSString stringWithFormat:@"var style = document.createElement('style'); style.innerHTML = '%@'; document.head.appendChild(style);", css];
        [webView evaluateJavaScript:js completionHandler:nil];

        // Rewrite target=_blank and window.open
        NSString *rewriteJS =
        @"(function() { \
            try { \
                document.querySelectorAll('a[target=\"_blank\"]').forEach(function(a){ a.target = '_self'; }); \
                window.open = function(url) { if (typeof url === 'string') { window.location.href = url; } return null; }; \
                document.addEventListener('click', function(e){ \
                    var node = e.target; while(node && node.tagName !== 'A') node = node.parentElement; \
                    if (node && node.tagName === 'A') { var href = node.getAttribute('href'); var target = node.getAttribute('target'); if (href && target === '_blank') { e.preventDefault(); window.location.href = href; } } \
                }, true); \
            } catch(err) { console.warn('embeddedwebview rewrite error', err); } \
        })();";
        [webView evaluateJavaScript:rewriteJS completionHandler:nil];

        NSString *url = webView.URL.absoluteString ?: @"";
        NSLog(@"[EmbeddedWebView] Page finished loading (id=%@): %@", instanceId, url);

        if (instanceId) {
            [self updateNavigationStateForInstanceId:instanceId];
            [self fireEvent:@"loadStop" forInstanceId:instanceId withData:url];
        }
    });
}

- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *instanceId = [self instanceIdForWebView:webView];
        NSString *url = webView.URL.absoluteString ?: @"";
        NSString *errorData = [NSString stringWithFormat:@"{\"url\":\"%@\",\"code\":%ld,\"message\":\"%@\"}",
                               url, (long)error.code, error.localizedDescription];

        NSLog(@"[EmbeddedWebView] Error loading page (id=%@): %@", instanceId, error.localizedDescription);

        if (instanceId) {
            [self fireEvent:@"loadError" forInstanceId:instanceId withData:errorData];
        }
    });
}

- (void)webView:(WKWebView *)webView
didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *instanceId = [self instanceIdForWebView:webView];
        NSString *url = webView.URL.absoluteString ?: @"";
        NSString *errorData = [NSString stringWithFormat:@"{\"url\":\"%@\",\"code\":%ld,\"message\":\"%@\"}",
                               url, (long)error.code, error.localizedDescription];

        NSLog(@"[EmbeddedWebView] Navigation error (id=%@): %@", instanceId, error.localizedDescription);

        if (instanceId) {
            [self fireEvent:@"loadError" forInstanceId:instanceId withData:errorData];
        }
    });
}

#pragma mark - WKNavigationDelegate (policy)

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {

    if (navigationAction.targetFrame == nil) {
        [webView loadRequest:navigationAction.request];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

#pragma mark - WKUIDelegate

- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
    forNavigationAction:(WKNavigationAction *)navigationAction
         windowFeatures:(WKWindowFeatures *)windowFeatures {

    if (navigationAction.request && navigationAction.targetFrame == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [webView loadRequest:navigationAction.request];
        });
    }
    return nil;
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {

    if ([keyPath isEqualToString:@"estimatedProgress"]) {
        WKWebView *webView = (WKWebView *)object;
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;

        if (instance && instance.progressBar) {
            dispatch_async(dispatch_get_main_queue(), ^{
                float progress = webView.estimatedProgress;
                [instance.progressBar setProgress:progress animated:YES];
                NSLog(@"[EmbeddedWebView] Loading progress (id=%@): %.0f%%", instanceId, progress * 100);
            });
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Helper methods

- (void)updateNavigationStateForInstanceId:(NSString *)instanceId {
    EmbeddedWebViewInstance *instance = self.instances[instanceId];
    if (!instance || !instance.webView) return;

    BOOL newCanGoBack = [instance.webView canGoBack];
    BOOL newCanGoForward = [instance.webView canGoForward];

    if (newCanGoBack != instance.canGoBack) {
        instance.canGoBack = newCanGoBack;
        [self fireEvent:@"canGoBackChanged"
         forInstanceId:instanceId
              withData:instance.canGoBack ? @"true" : @"false"];
    }

    if (newCanGoForward != instance.canGoForward) {
        instance.canGoForward = newCanGoForward;
        [self fireEvent:@"canGoForwardChanged"
         forInstanceId:instanceId
              withData:instance.canGoForward ? @"true" : @"false"];
    }

    NSString *navigationState = [NSString stringWithFormat:@"{\"canGoBack\":%@,\"canGoForward\":%@}",
                                 instance.canGoBack ? @"true" : @"false",
                                 instance.canGoForward ? @"true" : @"false"];

    [self fireEvent:@"navigationStateChanged"
     forInstanceId:instanceId
          withData:navigationState];
}

- (void)fireEvent:(NSString *)eventName
   forInstanceId:(NSString *)instanceId
        withData:(NSString *)data {

    if (!instanceId || instanceId.length == 0) {
        NSLog(@"[EmbeddedWebView] Skipping event %@ because instanceId is nil", eventName);
        return;
    }

    @try {
        NSString *dataFormatted;

        if (!data) {
            dataFormatted = @"null";
        } else if ([data hasPrefix:@"{"]) {
            // JSON payload
            dataFormatted = data;
        } else {
            // escape single quotes
            NSString *escaped = [data stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
            dataFormatted = [NSString stringWithFormat:@"'%@'", escaped];
        }

        NSString *js = [NSString stringWithFormat:
                        @"cordova.fireDocumentEvent('embeddedwebview.%@.%@', {detail: %@});",
                        instanceId, eventName, dataFormatted];

        NSLog(@"[EmbeddedWebView] Firing event %@ for id=%@ with data: %@",
              eventName, instanceId, data);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.commandDelegate evalJs:js];
        });
    } @catch (NSException *exception) {
        NSLog(@"[EmbeddedWebView] Error firing event: %@", exception.reason);
    }
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    if (!hexString || hexString.length == 0) {
        return [UIColor blueColor];
    }
    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    if ([hexString hasPrefix:@"#"]) {
        [scanner setScanLocation:1];
    } else {
        [scanner setScanLocation:0];
    }
    [scanner scanHexInt:&rgbValue];
    return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0
                           green:((rgbValue & 0xFF00) >> 8)/255.0
                            blue:(rgbValue & 0xFF)/255.0
                           alpha:1.0];
}

#pragma mark - Lifecycle

- (void)dispose {
    [self destroyAllInstances];
}

- (void)onReset {
    [self destroyAllInstances];
}

@end
