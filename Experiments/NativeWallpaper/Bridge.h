#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>
@interface NSXPCConnection (ProbeIdentity)
@property(nonatomic,readonly) audit_token_t auditToken;
@end
