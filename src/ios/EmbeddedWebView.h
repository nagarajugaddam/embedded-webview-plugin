#import <Cordova/CDVPlugin.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

@interface EmbeddedWebView : CDVPlugin <WKNavigationDelegate, WKUIDelegate>

@property (nonatomic, strong) WKWebView *embeddedWebView;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UIView *webViewContainer;
@property (nonatomic, assign) BOOL canGoBack;
@property (nonatomic, assign) BOOL canGoForward;
@property (nonatomic, strong) NSString *currentCallbackId;

// Public methods
- (void)create:(CDVInvokedUrlCommand*)command;
- (void)destroy:(CDVInvokedUrlCommand*)command;
- (void)loadUrl:(CDVInvokedUrlCommand*)command;
- (void)executeScript:(CDVInvokedUrlCommand*)command;
- (void)setVisible:(CDVInvokedUrlCommand*)command;
- (void)reload:(CDVInvokedUrlCommand*)command;
- (void)goBack:(CDVInvokedUrlCommand*)command;
- (void)goForward:(CDVInvokedUrlCommand*)command;

@end
