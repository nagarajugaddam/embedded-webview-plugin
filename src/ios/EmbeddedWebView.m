//
//  EmbeddedWebView.m
//  Cordova Plugin - EmbeddedWebView
//

#import "EmbeddedWebView.h"
#import <WebKit/WebKit.h>
#import <Cordova/CDV.h>
#import <UIKit/UIKit.h>

@interface EmbeddedWebView () <WKNavigationDelegate, WKUIDelegate>

@property (nonatomic, strong) WKWebView *embeddedWebView;
@property (nonatomic, strong) UIView *webViewContainer;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, assign) BOOL canGoBack;
@property (nonatomic, assign) BOOL canGoForward;

@end

@implementation EmbeddedWebView

- (void)pluginInitialize {
    [super pluginInitialize];
    self.canGoBack = NO;
    self.canGoForward = NO;
    NSLog(@"[EmbeddedWebView] Plugin initialized");
}

- (void)create:(CDVInvokedUrlCommand*)command {
    NSLog(@"[EmbeddedWebView] Creating WebView");
    
    NSString *url = [command argumentAtIndex:0];
    NSDictionary *options = [command argumentAtIndex:1 withDefault:@{}];
    
    if (!url || url.length == 0) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                    messageAsString:@"URL must be a non-empty string"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }
    
    [self.commandDelegate runInBackground:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (self.embeddedWebView != nil) {
                    NSLog(@"[EmbeddedWebView] WebView already exists, destroying before creating new one");
                    [self destroyWebView];
                }
                
                NSNumber *topOffset = options[@"top"] ?: @0;
                NSNumber *bottomOffset = options[@"bottom"] ?: @0;
                
                NSLog(@"[EmbeddedWebView] WebView config - URL: %@", url);
                NSLog(@"[EmbeddedWebView] User offsets - Top: %@px, Bottom: %@px", topOffset, bottomOffset);
                
                CGFloat safeTop = 0;
                CGFloat safeBottom = 0;
                
                if (@available(iOS 11.0, *)) {
                    UIWindow *window = UIApplication.sharedApplication.keyWindow;
                    if (window) {
                        safeTop = window.safeAreaInsets.top;
                        safeBottom = window.safeAreaInsets.bottom;
                    }
                }
                
                NSLog(@"[EmbeddedWebView] Safe area insets - Top: %.0fpx, Bottom: %.0fpx", safeTop, safeBottom);
                
                CGFloat finalTopMargin = safeTop + [topOffset floatValue];
                CGFloat finalBottomMargin = safeBottom + [bottomOffset floatValue];
                
                NSLog(@"[EmbeddedWebView] Final margins - Top: %.0fpx, Bottom: %.0fpx", finalTopMargin, finalBottomMargin);
                
                self.webViewContainer = [[UIView alloc] init];
                self.webViewContainer.backgroundColor = [UIColor clearColor];
                
                // Configure WKWebView
                WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
                config.allowsInlineMediaPlayback = YES;
                config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
                
                // IMPORTANT: allow JS to open windows so delegate methods get called
                config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
                config.preferences.javaScriptEnabled = YES;
                
                if ([options[@"enableZoom"] boolValue]) {
                    NSString *viewport = @"var meta = document.createElement('meta'); meta.name = 'viewport'; meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes'; document.getElementsByTagName('head')[0].appendChild(meta);";
                    WKUserScript *script = [[WKUserScript alloc] initWithSource:viewport
                                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                               forMainFrameOnly:YES];
                    [config.userContentController addUserScript:script];
                }
                
                self.embeddedWebView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
                self.embeddedWebView.navigationDelegate = self;
                self.embeddedWebView.UIDelegate = self;
                self.embeddedWebView.scrollView.bounces = YES;
                self.embeddedWebView.scrollView.showsVerticalScrollIndicator = NO;
                self.embeddedWebView.scrollView.showsHorizontalScrollIndicator = NO;
                self.embeddedWebView.backgroundColor = [UIColor clearColor];
                self.embeddedWebView.opaque = NO;
                
                if (options[@"userAgent"]) {
                    self.embeddedWebView.customUserAgent = options[@"userAgent"];
                }
                
                if ([options[@"clearCache"] boolValue]) {
                    NSSet *websiteDataTypes = [NSSet setWithArray:@[
                        WKWebsiteDataTypeDiskCache,
                        WKWebsiteDataTypeMemoryCache
                    ]];
                    NSDate *dateFrom = [NSDate dateWithTimeIntervalSince1970:0];
                    [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:websiteDataTypes
                                                               modifiedSince:dateFrom
                                                           completionHandler:^{}];
                }
                
                [self.embeddedWebView addObserver:self
                                       forKeyPath:@"estimatedProgress"
                                          options:NSKeyValueObservingOptionNew
                                          context:nil];
                
                // Create progress bar
                self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                
                NSString *progressColor = options[@"progressColor"] ?: @"#2196F3";
                self.progressBar.progressTintColor = [self colorFromHexString:progressColor];
                
                NSNumber *progressHeight = options[@"progressHeight"] ?: @5;
                CGFloat progressHeightValue = [progressHeight floatValue];
                
                self.progressBar.hidden = YES;
                
                [self.webViewContainer addSubview:self.embeddedWebView];
                [self.webViewContainer addSubview:self.progressBar];
                
                UIView *mainView = self.webView.superview ?: [UIApplication sharedApplication].keyWindow;
                if (!mainView) {
                    mainView = self.webView; // fallback
                }
                [mainView addSubview:self.webViewContainer];
                
                // Setup constraints
                self.webViewContainer.translatesAutoresizingMaskIntoConstraints = NO;
                self.embeddedWebView.translatesAutoresizingMaskIntoConstraints = NO;
                self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
                
                [NSLayoutConstraint activateConstraints:@[
                    // Container constraints
                    [self.webViewContainer.leadingAnchor constraintEqualToAnchor:mainView.leadingAnchor],
                    [self.webViewContainer.trailingAnchor constraintEqualToAnchor:mainView.trailingAnchor],
                    [self.webViewContainer.topAnchor constraintEqualToAnchor:mainView.topAnchor constant:finalTopMargin],
                    [self.webViewContainer.bottomAnchor constraintEqualToAnchor:mainView.bottomAnchor constant:-finalBottomMargin],
                    
                    // WebView constraints
                    [self.embeddedWebView.leadingAnchor constraintEqualToAnchor:self.webViewContainer.leadingAnchor],
                    [self.embeddedWebView.trailingAnchor constraintEqualToAnchor:self.webViewContainer.trailingAnchor],
                    [self.embeddedWebView.topAnchor constraintEqualToAnchor:self.webViewContainer.topAnchor],
                    [self.embeddedWebView.bottomAnchor constraintEqualToAnchor:self.webViewContainer.bottomAnchor],
                    
                    // Progress bar constraints
                    [self.progressBar.leadingAnchor constraintEqualToAnchor:self.webViewContainer.leadingAnchor],
                    [self.progressBar.trailingAnchor constraintEqualToAnchor:self.webViewContainer.trailingAnchor],
                    [self.progressBar.bottomAnchor constraintEqualToAnchor:self.webViewContainer.bottomAnchor],
                    [self.progressBar.heightAnchor constraintEqualToConstant:progressHeightValue]
                ]];
                
                // Load URL
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
                
                if (options[@"headers"]) {
                    NSDictionary *headers = options[@"headers"];
                    for (NSString *key in headers) {
                        [request setValue:headers[key] forHTTPHeaderField:key];
                    }
                }
                
                [self.embeddedWebView loadRequest:request];
                
                NSLog(@"[EmbeddedWebView] WebView created successfully with progress bar");
                
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                            messageAsString:@"WebView created successfully"];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
                
            } @catch (NSException *exception) {
                NSLog(@"[EmbeddedWebView] Error creating WebView: %@", exception.reason);
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                            messageAsString:[NSString stringWithFormat:@"Error creating WebView: %@", exception.reason]];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            }
        });
    }];
}

- (void)destroy:(CDVInvokedUrlCommand*)command {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.embeddedWebView != nil) {
            [self destroyWebView];
            NSLog(@"[EmbeddedWebView] WebView destroyed");
            
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                        messageAsString:@"WebView destroyed"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"No WebView to destroy"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

- (void)destroyWebView {
    if (self.embeddedWebView) {
        @try {
            [self.embeddedWebView removeObserver:self forKeyPath:@"estimatedProgress"];
        } @catch (NSException *ex) {
            // ignore if observer not attached
        }
        [self.embeddedWebView stopLoading];
        [self.embeddedWebView removeFromSuperview];
        self.embeddedWebView.navigationDelegate = nil;
        self.embeddedWebView.UIDelegate = nil;
        self.embeddedWebView = nil;
    }
    
    if (self.progressBar) {
        [self.progressBar removeFromSuperview];
        self.progressBar = nil;
    }
    
    if (self.webViewContainer) {
        [self.webViewContainer removeFromSuperview];
        self.webViewContainer = nil;
    }
}

- (void)loadUrl:(CDVInvokedUrlCommand*)command {
    NSString *url = [command argumentAtIndex:0];
    NSDictionary *headers = [command argumentAtIndex:1 withDefault:nil];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.embeddedWebView != nil) {
            @try {
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
                
                if (headers) {
                    for (NSString *key in headers) {
                        [request setValue:headers[key] forHTTPHeaderField:key];
                    }
                }
                
                [self.embeddedWebView loadRequest:request];
                
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                            messageAsString:[NSString stringWithFormat:@"URL loaded: %@", url]];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            } @catch (NSException *exception) {
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                            messageAsString:[NSString stringWithFormat:@"Error loading URL: %@", exception.reason]];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            }
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"WebView not initialized"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

- (void)executeScript:(CDVInvokedUrlCommand*)command {
    NSString *script = [command argumentAtIndex:0];
    
    if (!script || script.length == 0) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                    messageAsString:@"script must be a non-empty string"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.embeddedWebView != nil) {
            [self.embeddedWebView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
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
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"WebView not initialized"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

- (void)setVisible:(CDVInvokedUrlCommand*)command {
    BOOL visible = [[command argumentAtIndex:0] boolValue];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.webViewContainer != nil) {
            self.webViewContainer.hidden = !visible;
            
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

- (void)reload:(CDVInvokedUrlCommand*)command {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.embeddedWebView != nil) {
            [self.embeddedWebView reload];
            
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                        messageAsString:@"WebView reloaded"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"WebView not initialized"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

- (void)goBack:(CDVInvokedUrlCommand*)command {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.embeddedWebView != nil) {
            if ([self.embeddedWebView canGoBack]) {
                [self.embeddedWebView goBack];
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self updateNavigationState];
                });
                
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                            messageAsString:@"Navigated back"];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            } else {
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                            messageAsString:@"Cannot go back"];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            }
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"WebView not initialized"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

- (void)goForward:(CDVInvokedUrlCommand*)command {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.embeddedWebView != nil) {
            if ([self.embeddedWebView canGoForward]) {
                [self.embeddedWebView goForward];
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self updateNavigationState];
                });
                
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                            messageAsString:@"Navigated forward"];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            } else {
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                            messageAsString:@"Cannot go forward"];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            }
        } else {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"WebView not initialized"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }
    });
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBar) {
            self.progressBar.hidden = NO;
            [self.progressBar setProgress:0.0 animated:NO];
        }
        
        NSString *url = webView.URL.absoluteString;
        NSLog(@"[EmbeddedWebView] Page started loading: %@", url);
        [self fireEvent:@"loadStart" withData:url];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressBar) {
            [self.progressBar setProgress:1.0 animated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.progressBar.hidden = YES;
            });
        }
        
        // Inject smooth scrolling CSS
        NSString *css = @"html, body { scroll-behavior: smooth !important; -webkit-overflow-scrolling: touch; }";
        NSString *js = [NSString stringWithFormat:@"var style = document.createElement('style'); style.innerHTML = `%@`; document.head.appendChild(style);", css];
        [webView evaluateJavaScript:js completionHandler:nil];
        
        // Fallback: rewrite target="_blank" anchors and override window.open + delegated click capture (SPA)
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
        
        NSString *url = webView.URL.absoluteString;
        NSLog(@"[EmbeddedWebView] Page finished loading: %@", url);
        
        [self updateNavigationState];
        [self fireEvent:@"loadStop" withData:url];
    });
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSString *url = webView.URL.absoluteString;
    NSString *errorData = [NSString stringWithFormat:@"{\"url\":\"%@\",\"code\":%ld,\"message\":\"%@\"}",
                           url, (long)error.code, error.localizedDescription];
    
    NSLog(@"[EmbeddedWebView] Error loading page: %@", error.localizedDescription);
    [self fireEvent:@"loadError" withData:errorData];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSString *url = webView.URL.absoluteString;
    NSString *errorData = [NSString stringWithFormat:@"{\"url\":\"%@\",\"code\":%ld,\"message\":\"%@\"}",
                           url, (long)error.code, error.localizedDescription];
    
    NSLog(@"[EmbeddedWebView] Navigation error: %@", error.localizedDescription);
    [self fireEvent:@"loadError" withData:errorData];
}

#pragma mark - WKNavigationDelegate (policy)

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    
    // If targetFrame == nil, it's a new-window request (target=_blank or window.open)
    if (navigationAction.targetFrame == nil) {
        // Load in same webview and cancel the system new-window behavior
        [webView loadRequest:navigationAction.request];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    
    decisionHandler(WKNavigationActionPolicyAllow);
}

#pragma mark - WKUIDelegate

// Invoked when page requests a new window (target=_blank or window.open)
// We'll capture and load in same webview and return nil (no new webview)
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
    if ([keyPath isEqualToString:@"estimatedProgress"] && object == self.embeddedWebView) {
        dispatch_async(dispatch_get_main_queue(), ^{
            float progress = self.embeddedWebView.estimatedProgress;
            if (self.progressBar) {
                [self.progressBar setProgress:progress animated:YES];
                NSLog(@"[EmbeddedWebView] Loading progress: %.0f%%", progress * 100);
            }
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Helper Methods

- (void)updateNavigationState {
    if (self.embeddedWebView) {
        BOOL newCanGoBack = [self.embeddedWebView canGoBack];
        BOOL newCanGoForward = [self.embeddedWebView canGoForward];
        
        if (newCanGoBack != self.canGoBack) {
            self.canGoBack = newCanGoBack;
            [self fireEvent:@"canGoBackChanged" withData:self.canGoBack ? @"true" : @"false"];
        }
        
        if (newCanGoForward != self.canGoForward) {
            self.canGoForward = newCanGoForward;
            [self fireEvent:@"canGoForwardChanged" withData:self.canGoForward ? @"true" : @"false"];
        }
        
        NSString *navigationState = [NSString stringWithFormat:@"{\"canGoBack\":%@,\"canGoForward\":%@}",
                                     self.canGoBack ? @"true" : @"false",
                                     self.canGoForward ? @"true" : @"false"];
        [self fireEvent:@"navigationStateChanged" withData:navigationState];
    }
}

- (void)fireEvent:(NSString *)eventName withData:(NSString *)data {
    @try {
        NSString *dataFormatted = data;
        if (![data hasPrefix:@"{"]) {
            dataFormatted = [NSString stringWithFormat:@"'%@'", data];
        }
        
        NSString *js = [NSString stringWithFormat:@"cordova.fireDocumentEvent('embeddedwebview.%@', {detail: %@});",
                        eventName, dataFormatted];
        
        NSLog(@"[EmbeddedWebView] Firing event: %@ with data: %@", eventName, data);
        
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
        [scanner setScanLocation:1]; // Skip '#'
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
    [self destroyWebView];
}

- (void)onReset {
    [self destroyWebView];
}

@end
