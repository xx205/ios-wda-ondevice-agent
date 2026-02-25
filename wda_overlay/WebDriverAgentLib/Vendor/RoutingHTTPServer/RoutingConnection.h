#import <Foundation/Foundation.h>
#import "HTTPConnection.h"

@interface RoutingConnection : HTTPConnection
- (NSString *)peerHost;
@end
