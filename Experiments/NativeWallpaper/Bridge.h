#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>
@interface NSXPCConnection (ProbeIdentity)
@property(nonatomic,readonly) audit_token_t auditToken;
@end

#import <QuartzCore/QuartzCore.h>
// Private remote-layer API, isolated to this non-shipping experiment.
@interface CAContext : NSObject
@property(nonatomic, readonly) unsigned int contextId;
@property(nonatomic, retain) CALayer *layer;
+ (id)remoteContextWithOptions:(id)options;
@end
