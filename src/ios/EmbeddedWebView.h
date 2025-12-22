#import <Cordova/CDVPlugin.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

@interface EmbeddedWebView : CDVPlugin <WKNavigationDelegate, WKUIDelegate>
@interface EmbeddedWebView () <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler> 


// Map of instanceId -> instance holder (managed in .m)
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *instances;
@property (nonatomic, strong) NSString *lastCreatedId;
@property (nonatomic, strong) NSString *currentCallbackId;

// Public methods (now expect id as first argument from JS)
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
