//
//  EmbeddedWebView.m
//  Cordova Plugin - EmbeddedWebView
//

#import "EmbeddedWebView.h"
#import <WebKit/WebKit.h>
#import <Cordova/CDV.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

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

#pragma mark - Plugin Interface

// Define the class extension with Protocols AND Private Method Signatures
@interface EmbeddedWebView () <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>

@property (nonatomic, strong) NSMutableDictionary *instances;
@property (nonatomic, strong) NSString *lastCreatedId;
@property (nonatomic, strong) NSString *currentCallbackId;

// --- CRITICAL FIX: Declare private methods here to prevent build errors ---
- (EmbeddedWebViewInstance *)instanceForId:(NSString *)instanceId command:(CDVInvokedUrlCommand *)command;
- (NSString *)instanceIdForWebView:(WKWebView *)webView;
- (void)destroyInstanceWithId:(NSString *)instanceId sendCallback:(BOOL)sendCallback callbackId:(NSString *)callbackId;
- (void)updateNavigationStateForInstanceId:(NSString *)instanceId;
- (void)fireEvent:(NSString *)eventName forInstanceId:(NSString *)instanceId withData:(NSString *)data;
- (UIColor *)colorFromHexString:(NSString *)hexString;
- (void)handleLoadError:(NSError *)error webView:(WKWebView *)webView;

@end

@implementation EmbeddedWebView

// Shared Process Pool (Singleton)
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
    instance.canGoBack = NO;
    instance.canGoForward = NO;

    if ([options[@"cookies"] isKindOfClass:[NSDictionary class]]) {
        instance.cookies = options[@"cookies"];
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
        [self destroyInstanceWithId:instanceId sendCallback:NO callbackId:nil];
    }

    [self.commandDelegate runInBackground:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                // Layout
                NSNumber *topOffset = options[@"top"] ?: @0;
                NSNumber *bottomOffset = options[@"bottom"] ?: @0;
                CGFloat safeTop = 0;
                CGFloat safeBottom = 0;
                if (@available(iOS 11.0, *)) {
                    UIWindow *window = UIApplication.sharedApplication.keyWindow;
                    if (window) {
                        safeTop = window.safeAreaInsets.top;
                        safeBottom = window.safeAreaInsets.bottom;
                    }
                }
                CGFloat finalTopMargin = safeTop + [topOffset floatValue];
                CGFloat finalBottomMargin = safeBottom + [bottomOffset floatValue];

                instance.container = [[UIView alloc] init];
                instance.container.backgroundColor = [UIColor clearColor];

                // Configuration
                WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
                config.processPool = [EmbeddedWebView sharedProcessPool];
                config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
                config.allowsInlineMediaPlayback = YES;
                
                // --- LOGGING BRIDGE ---
                NSString *debugScript =
                    @"window.onerror = function(msg, url, line) { window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-fatal', msg: msg, line: line, url: url}); };"
                    @"var origLog = console.log; console.log = function() { origLog.apply(console, arguments); var msg = Array.from(arguments).join(' '); window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-log', msg: msg}); };"
                    @"var origWarn = console.warn; console.warn = function() { origWarn.apply(console, arguments); var msg = Array.from(arguments).join(' '); window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-warn', msg: msg}); };"
                    @"var origErr = console.error; console.error = function() { origErr.apply(console, arguments); var msg = Array.from(arguments).join(' '); window.webkit.messageHandlers.consoleHandler.postMessage({type: 'js-error', msg: msg}); };";

                WKUserScript *debugUserScript = [[WKUserScript alloc] initWithSource:debugScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
                [config.userContentController addUserScript:debugUserScript];
                
                // Register Handler
                [config.userContentController addScriptMessageHandler:self name:@"consoleHandler"];
                
                // Cookie Script Injection (Backup)
                if (instance.cookies && instance.cookies.count > 0) {
                    NSMutableString *cookieJs = [NSMutableString string];
                    for (NSString *name in instance.cookies) {
                        NSString *rawVal = [instance.cookies[name] description];
                        NSString *val = [rawVal stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
                        [cookieJs appendFormat:@"document.cookie='%@=%@; path=/';", name, val];
                    }
                    WKUserScript *cookieScript = [[WKUserScript alloc]
                        initWithSource:cookieJs
                        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                        forMainFrameOnly:NO];
                    [config.userContentController addUserScript:cookieScript];
                }

                if ([options[@"enableZoom"] boolValue]) {
                    NSString *viewport = @"var meta = document.createElement('meta'); meta.name = 'viewport'; meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes'; document.getElementsByTagName('head')[0].appendChild(meta);";
                    WKUserScript *script = [[WKUserScript alloc] initWithSource:viewport injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
                    [config.userContentController addUserScript:script];
                }

                WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
                instance.webView = webView;
                webView.navigationDelegate = self;
                webView.UIDelegate = self;
                webView.scrollView.bounces = YES;
                webView.backgroundColor = [UIColor clearColor];
                webView.opaque = NO;
                
                // Safe Inspectable check
                if (@available(iOS 16.4, *)) {
                    @try { [webView setValue:@YES forKey:@"inspectable"]; } @catch (NSException *e) {}
                }

                if (options[@"userAgent"]) {
                    webView.customUserAgent = options[@"userAgent"];
                }
                
                if ([options[@"clearCache"] boolValue]) {
                    NSSet *types = [NSSet setWithArray:@[WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]];
                    [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:types modifiedSince:[NSDate dateWithTimeIntervalSince1970:0] completionHandler:^{}];
                }

                [webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:nil];

                // UI Layout
                UIProgressView *progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                instance.progressBar = progressBar;
                progressBar.progressTintColor = [self colorFromHexString:options[@"progressColor"] ?: @"#2196F3"];
                progressBar.hidden = YES;
                
                [instance.container addSubview:webView];
                [instance.container addSubview:progressBar];

                UIView *mainView = self.webView.superview ?: [UIApplication sharedApplication].keyWindow;
                if (!mainView) mainView = self.webView;
                [mainView addSubview:instance.container];

                instance.container.translatesAutoresizingMaskIntoConstraints = NO;
                webView.translatesAutoresizingMaskIntoConstraints = NO;
                progressBar.translatesAutoresizingMaskIntoConstraints = NO;
                CGFloat ph = [options[@"progressHeight"] floatValue] ?: 5.0;

                [NSLayoutConstraint activateConstraints:@[
                    [instance.container.leadingAnchor constraintEqualToAnchor:mainView.leadingAnchor],
                    [instance.container.trailingAnchor constraintEqualToAnchor:mainView.trailingAnchor],
                    [instance.container.topAnchor constraintEqualToAnchor:mainView.topAnchor constant:finalTopMargin],
                    [instance.container.bottomAnchor constraintEqualToAnchor:mainView.bottomAnchor constant:-finalBottomMargin],
                    [webView.leadingAnchor constraintEqualToAnchor:instance.container.leadingAnchor],
                    [webView.trailingAnchor constraintEqualToAnchor:instance.container.trailingAnchor],
                    [webView.topAnchor constraintEqualToAnchor:instance.container.topAnchor],
                    [webView.bottomAnchor constraintEqualToAnchor:instance.container.bottomAnchor],
                    [progressBar.leadingAnchor constraintEqualToAnchor:instance.container.leadingAnchor],
                    [progressBar.trailingAnchor constraintEqualToAnchor:instance.container.trailingAnchor],
                    [progressBar.bottomAnchor constraintEqualToAnchor:instance.container.bottomAnchor],
                    [progressBar.heightAnchor constraintEqualToConstant:ph]
                ]];

                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
                if (options[@"headers"]) {
                    for (NSString *key in options[@"headers"]) {
                        [request setValue:options[@"headers"][key] forHTTPHeaderField:key];
                    }
                }

                if (instance.cookies && instance.cookies.count > 0) {
                    NSMutableString *cookieHeader = [NSMutableString string];
                    for (NSString *name in instance.cookies) {
                        NSString *val = [instance.cookies[name] description];
                        if (cookieHeader.length > 0) [cookieHeader appendString:@"; "];
                        [cookieHeader appendFormat:@"%@=%@", name, val];
                    }
                    [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
                }

                // Cookie Store
                WKHTTPCookieStore *cookieStore = config.websiteDataStore.httpCookieStore;
                NSURL *pageURL = [NSURL URLWithString:url];
                NSString *rawHost = pageURL.host;
                BOOL isSecure = [url.lowercaseString hasPrefix:@"https"];
                
                NSString *cookieDomain = nil;
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$" options:0 error:nil];
                NSUInteger numberOfMatches = [regex numberOfMatchesInString:rawHost options:0 range:NSMakeRange(0, [rawHost length])];
                
                if (numberOfMatches == 0 && ![rawHost isEqualToString:@"localhost"]) {
                    if ([rawHost hasPrefix:@"www."]) {
                        cookieDomain = [rawHost substringFromIndex:3];
                    } else {
                        cookieDomain = rawHost;
                    }
                }

                NSArray *cookieKeys = instance.cookies ? instance.cookies.allKeys : @[];
                dispatch_group_t cookieGroup = dispatch_group_create();

                for (NSString *name in cookieKeys) {
                    dispatch_group_enter(cookieGroup);
                    NSString *value = [[instance.cookies[name] description] copy];
                    NSMutableDictionary *props = [NSMutableDictionary dictionary];
                    props[NSHTTPCookieName] = name;
                    props[NSHTTPCookieValue] = value;
                    props[NSHTTPCookiePath] = @"/";
                    if (cookieDomain) props[NSHTTPCookieDomain] = cookieDomain;
                    if (isSecure) props[NSHTTPCookieSecure] = @"TRUE";
                    if (@available(iOS 13.0, *)) {
                        props[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteLax;
                    }

                    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
                    if (cookie) {
                        [cookieStore setCookie:cookie completionHandler:^{
                            dispatch_group_leave(cookieGroup);
                        }];
                    } else {
                        dispatch_group_leave(cookieGroup);
                    }
                }

                self.instances[instanceId] = instance;
                self.lastCreatedId = instanceId;

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

#pragma mark - Destroy

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
            @try { [instance.webView.configuration.userContentController removeScriptMessageHandlerForName:@"consoleHandler"]; } @catch(NSException *e){}
            
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

#pragma mark - Methods

- (void)loadUrl:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    NSString *url = [command argumentAtIndex:1];
    NSDictionary *headers = [command argumentAtIndex:2 withDefault:nil];

    if (!instanceId) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (!instance) return;

        @try {
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
            instance.container.hidden = !visible;
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
        if (instance && [instance.webView canGoBack]) {
            [instance.webView goBack];
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        }
    });
}

- (void)goForward:(CDVInvokedUrlCommand*)command {
    NSString *instanceId = [command argumentAtIndex:0];
    dispatch_async(dispatch_get_main_queue(), ^{
        EmbeddedWebViewInstance *instance = [self instanceForId:instanceId command:command];
        if (instance && [instance.webView canGoForward]) {
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
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:[instance.webView canGoBack]] callbackId:command.callbackId];
        }
    });
}

#pragma mark - Log Handler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"consoleHandler"]) {
        NSDictionary *body = message.body;
        NSString *instanceId = [self instanceIdForWebView:message.webView];
        if (instanceId) {
            NSString *type = body[@"type"] ?: @"unknown";
            NSString *msg = body[@"msg"] ?: @"";
            NSString *json = [NSString stringWithFormat:@"{\"type\":\"%@\", \"message\":\"%@\"}", type, [msg stringByReplacingOccurrencesOfString:@"\"" withString:@"\\'"]];
            [self fireEvent:@"consoleLog" forInstanceId:instanceId withData:json];
        }
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    if ([navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)navigationResponse.response;
        NSInteger statusCode = httpResponse.statusCode;
        if (statusCode >= 400) {
            NSString *instanceId = [self instanceIdForWebView:webView];
            NSString *url = httpResponse.URL.absoluteString;
            NSString *errData = [NSString stringWithFormat:@"{\"url\":\"%@\", \"code\":%ld, \"message\":\"HTTP Server Error\"}", url, (long)statusCode];
            if (instanceId) [self fireEvent:@"loadError" forInstanceId:instanceId withData:errData];
        }
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;
        if (instance) {
            instance.progressBar.hidden = NO;
            [instance.progressBar setProgress:0.0 animated:NO];
            [self fireEvent:@"loadStart" forInstanceId:instanceId withData:webView.URL.absoluteString];
        }
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *instanceId = [self instanceIdForWebView:webView];
        EmbeddedWebViewInstance *instance = instanceId ? self.instances[instanceId] : nil;
        if (instance) {
            [instance.progressBar setProgress:1.0 animated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ instance.progressBar.hidden = YES; });
            [self updateNavigationStateForInstanceId:instanceId];
            [self fireEvent:@"loadStop" forInstanceId:instanceId withData:webView.URL.absoluteString];
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
        NSString *url = webView.URL.absoluteString ?: @"";
        NSString *errorData = [NSString stringWithFormat:@"{\"url\":\"%@\",\"code\":%ld,\"message\":\"%@\"}", url, (long)error.code, error.localizedDescription];
        if (instanceId) [self fireEvent:@"loadError" forInstanceId:instanceId withData:errorData];
    });
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = [url.scheme lowercaseString];

    // List of schemes to open externally (Phone, Mail, SMS, FaceTime, Maps)
    if ([scheme isEqualToString:@"tel"] ||
        [scheme isEqualToString:@"mailto"] ||
        [scheme isEqualToString:@"sms"] ||
        [scheme isEqualToString:@"facetime"] ||
        [scheme isEqualToString:@"maps"]) {
        
        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            // Open in system app (Phone, Mail, etc.)
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
        
        // Cancel the load in the WebView so it doesn't show an error page
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    // Handle target="_blank" (Links that want to open in a new window)
    if (navigationAction.targetFrame == nil) {
        [webView loadRequest:navigationAction.request];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
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
                [instance.progressBar setProgress:webView.estimatedProgress animated:YES];
            });
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Helpers

- (void)updateNavigationStateForInstanceId:(NSString *)instanceId {
    EmbeddedWebViewInstance *instance = self.instances[instanceId];
    if (!instance || !instance.webView) return;

    BOOL newCanGoBack = [instance.webView canGoBack];
    BOOL newCanGoForward = [instance.webView canGoForward];

    if (newCanGoBack != instance.canGoBack) {
        instance.canGoBack = newCanGoBack;
        [self fireEvent:@"canGoBackChanged" forInstanceId:instanceId withData:instance.canGoBack ? @"true" : @"false"];
    }
    if (newCanGoForward != instance.canGoForward) {
        instance.canGoForward = newCanGoForward;
        [self fireEvent:@"canGoForwardChanged" forInstanceId:instanceId withData:instance.canGoForward ? @"true" : @"false"];
    }
    NSString *navState = [NSString stringWithFormat:@"{\"canGoBack\":%@,\"canGoForward\":%@}", instance.canGoBack ? @"true" : @"false", instance.canGoForward ? @"true" : @"false"];
    [self fireEvent:@"navigationStateChanged" forInstanceId:instanceId withData:navState];
}

- (void)fireEvent:(NSString *)eventName forInstanceId:(NSString *)instanceId withData:(NSString *)data {
    if (!instanceId) return;
    @try {
        NSString *dataFormatted = (!data) ? @"null" : ([data hasPrefix:@"{"] ? data : [NSString stringWithFormat:@"'%@'", [data stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]]);
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

#pragma mark - WKUIDelegate (Alerts & Confirms)

// Handles JavaScript alert('message')
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:nil
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *action) {
        completionHandler();
    }]];
    
    // Find the best view controller to present from
    UIViewController *presentingVC = self.viewController;
    while (presentingVC.presentedViewController) {
        presentingVC = presentingVC.presentedViewController;
    }
    [presentingVC presentViewController:alertController animated:YES completion:nil];
}

// Handles JavaScript confirm('message')
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:nil
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                        style:UIAlertActionStyleCancel
                                                      handler:^(UIAlertAction *action) {
        completionHandler(NO);
    }]];
    
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *action) {
        completionHandler(YES);
    }]];
    
    UIViewController *presentingVC = self.viewController;
    while (presentingVC.presentedViewController) {
        presentingVC = presentingVC.presentedViewController;
    }
    [presentingVC presentViewController:alertController animated:YES completion:nil];
}

@end