//
//  EmbeddedWebView.h
//  Cordova Plugin - EmbeddedWebView
//

#import <Cordova/CDVPlugin.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

@interface EmbeddedWebView : CDVPlugin

// Public API methods called from JavaScript
- (void)create:(CDVInvokedUrlCommand*)command;
- (void)destroy:(CDVInvokedUrlCommand*)command;
- (void)loadUrl:(CDVInvokedUrlCommand*)command;
- (void)executeScript:(CDVInvokedUrlCommand*)command;
- (void)setVisible:(CDVInvokedUrlCommand*)command;
- (void)reload:(CDVInvokedUrlCommand*)command;
- (void)goBack:(CDVInvokedUrlCommand*)command;
- (void)goForward:(CDVInvokedUrlCommand*)command;
- (void)canGoBack:(CDVInvokedUrlCommand*)command;

@end