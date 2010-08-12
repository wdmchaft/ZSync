//
//  ZSyncTouchHandler.m
//  SampleTouch
//
//  Created by Marcus S. Zarra on 11/11/09.
//  Copyright 2009 Zarra Studios, LLC. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.

#import "ZSyncTouchHandler.h"
#import "ZSyncShared.h"
#import "ServerBrowser.h"


#import "Reachability.h"

#define zsUUIDStringLength 55

@interface ZSyncTouchHandler()

- (void)requestDeregistration;
- (void)uploadDataToServer;

@property (nonatomic, assign) id delegate;
@property (nonatomic, retain) NSPersistentStoreCoordinator *persistentStoreCoordinator;

@end

@implementation ZSyncTouchHandler

+ (id)shared;
{
  static ZSyncTouchHandler *sharedTouchHandler;
  if (sharedTouchHandler) return sharedTouchHandler;
  @synchronized(sharedTouchHandler) {
    sharedTouchHandler = [[ZSyncTouchHandler alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:sharedTouchHandler 
                                             selector:@selector(applicationWillTerminate:) 
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
  }
  return sharedTouchHandler;
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
  DLog(@"closing connection");
  if ([self connection]) {
    [[self connection] close];
  }
  if ([self serviceBrowser]) {
    [[self serviceBrowser] setDelegate:nil];
    [[self serviceBrowser] stop];
    [_serviceBrowser release], _serviceBrowser = nil;
  }
}

- (NSString*)cachePath
{
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString *filePath = [paths objectAtIndex:0];
  
  return filePath;
}

- (void)networkTimeout:(NSTimer*)timer
{
  DLog(@"timeout on local network");
  networkTimer = nil;
  [self setServerAction:ZSyncServerActionNoActivity];
  if ([[self delegate] respondsToSelector:@selector(zSyncServerUnavailable:)]) {
    [[self delegate] zSyncServerUnavailable:self];
  }
  [[timer userInfo] stopNotifer];
}

- (void)reachabilityChanged:(NSNotification*)notification
{
  Reachability *reachability = [notification object];
  if ([reachability currentReachabilityStatus] == NotReachable) return;
  DLog(@"local network now available");
  [reachability stopNotifer];
  [networkTimer invalidate], networkTimer = nil;
  NSString *serverUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsServerUUID];
  if (serverUUID) {
    networkTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 
                            target:self 
                            selector:@selector(networkTimeout:) 
                            userInfo:nil
                             repeats:NO];
  }
  [[self serviceBrowser] start];
}

- (void)startServerSearch
{
  if ([self serviceBrowser]) {
    DLog(@"service browser is not nil");
    [[self serviceBrowser] setDelegate:nil];
    [[self serviceBrowser] stop];
    [self setServiceBrowser:nil];
  }
  
  _serviceBrowser = [[ServerBrowser alloc] init];
  _serviceBrowser.delegate = self;
  
  Reachability *reachability = [Reachability reachabilityForLocalWiFi];
  if ([reachability currentReachabilityStatus] == NotReachable) {
    DLog(@"local network not available");
    //start notifying
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(reachabilityChanged:) 
                                                 name:kReachabilityChangedNotification 
                                               object:nil];
    
    [reachability startNotifer];
    networkTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 
                                                    target:self 
                                                  selector:@selector(networkTimeout:) 
                                                  userInfo:reachability
                                                   repeats:NO];
    
    
    return;
  } else {
    NSString *serverUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsServerUUID];
    if (serverUUID) {
      networkTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 
                              target:self 
                            selector:@selector(networkTimeout:) 
                            userInfo:reachability
                             repeats:NO];
    }
    [[self serviceBrowser] start];
  }
}

- (void)requestSync;
{
  ZAssert([self serverAction] == ZSyncServerActionNoActivity, @"Attempt to sync while another action is active");
  [self setServerAction:ZSyncServerActionSync];
  if ([self connection]) {
    [self uploadDataToServer];
  } else {
    [self startServerSearch];
  }
}

- (void)stopRequestingSync
{
  [[self serviceBrowser] setDelegate:nil];
  [[self serviceBrowser] stop];
  [self setServerAction:ZSyncServerActionNoActivity];
}

- (void)deregister;
{
  DLog(@"deregister request received");
  if ([self serverAction] != ZSyncServerActionNoActivity) {
    if ([[self delegate] respondsToSelector:@selector(zSync:errorOccurred:)]) {
      NSString *errorString = [NSString stringWithFormat:@"Another activity in progress: %i", [self serverAction]];
      NSDictionary *dict = [NSDictionary dictionaryWithObject:errorString forKey:NSLocalizedDescriptionKey];
      NSError *error = [NSError errorWithDomain:zsErrorDomain code:zsErrorAnotherActivityInProgress userInfo:dict];
      [[self delegate] zSync:self errorOccurred:error];
      return;
    }
  }
  if (![[NSUserDefaults standardUserDefaults] valueForKey:zsServerUUID] || ![[NSUserDefaults standardUserDefaults] valueForKey:zsDeviceID]) {
    if ([[self delegate] respondsToSelector:@selector(zSync:errorOccurred:)]) {
      NSString *errorString = [NSString stringWithFormat:@"Client is not registered with a server", [self serverAction]];
      NSDictionary *dict = [NSDictionary dictionaryWithObject:errorString forKey:NSLocalizedDescriptionKey];
      NSError *error = [NSError errorWithDomain:zsErrorDomain code:zsErrorNoSyncClientRegistered userInfo:dict];
      [[self delegate] zSync:self errorOccurred:error];
      return;
    }
  }
  [self setServerAction:ZSyncServerActionDeregister];
  if ([self connection]) {
    DLog(@"requesting deregister");
    [self requestDeregistration];
  } else {
    DLog(@"searching for server");
    [self startServerSearch];
  }
}

- (void)disconnectPairing;
{
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:zsServerName];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:zsServerUUID];
  if ([self connection]) {
    [[self connection] close];
    [self setConnection:nil];
  }
  [self setServerAction:ZSyncServerActionNoActivity];
}

- (NSString*)serverName;
{
  return [[NSUserDefaults standardUserDefaults] valueForKey:zsServerName];
}

- (void)cancelPairing;
{
  if (![self connection]) return;
  
  //Start a pairing request
  DLog(@"sending a pairing cancel");
  NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
  [dictionary setValue:zsActID(zsActionCancelPairing) forKey:zsAction];
  
  NSString *deviceUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsDeviceID];
  if (!deviceUUID) {
    deviceUUID = [[NSProcessInfo processInfo] globallyUniqueString];
    [[NSUserDefaults standardUserDefaults] setValue:deviceUUID forKey:zsDeviceID];
  }
  
  [dictionary setValue:deviceUUID forKey:zsDeviceID];
  
  BLIPRequest *request = [BLIPRequest requestWithBody:nil properties:dictionary];
  [[self connection] sendRequest:request];
}

- (void)requestPairing:(ZSyncService*)server;
{
  NSNetService *service = [server service];
  BLIPConnection *conn = [[BLIPConnection alloc] initToNetService:service];
  [self setConnection:conn];
  [conn setDelegate:self];
  [conn open];
  [conn release], conn = nil;
}

- (void)authenticatePairing:(NSString*)code;
{
  if (![self connection]) return;
  
  //Start a pairing request
  DLog(@"sending a pairing code");
  NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
  [dictionary setValue:zsActID(zsActionAuthenticatePairing) forKey:zsAction];
  
  NSString *deviceUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsDeviceID];
  if (!deviceUUID) {
    deviceUUID = [[NSProcessInfo processInfo] globallyUniqueString];
    [[NSUserDefaults standardUserDefaults] setValue:deviceUUID forKey:zsDeviceID];
  }
  [dictionary setValue:deviceUUID forKey:zsDeviceID];

  NSData *codeData = [code dataUsingEncoding:NSUTF8StringEncoding];
  BLIPRequest *request = [BLIPRequest requestWithBody:codeData properties:dictionary];
  [[self connection] sendRequest:request];
}

- (void)beginSyncWithService:(NSNetService*)service
{
  BLIPConnection *conn = [[BLIPConnection alloc] initToNetService:service];
  [self setConnection:conn];
  [conn setDelegate:self];
  [conn open];
  [conn release], conn = nil;
}

#pragma mark -
#pragma mark Overridden getters/setter

- (NSMutableArray *)availableServers
{
  if (!availableServers) {
    availableServers = [[NSMutableArray alloc] init];
  }
  
  return availableServers;
}

- (NSMutableArray *)discoveredServers
{
  if (!discoveredServers) {
    discoveredServers = [[NSMutableArray alloc] init];
  }
  
  return discoveredServers;
}

- (NSObject *)lock
{
  if (!lock) {
    lock = [[NSObject alloc] init];
  }
  
  return lock;
}

#pragma mark -
#pragma mark ServerBrowserDelegate methods

- (void)updateServerList
{
  [lock lock];
  NSLog(@"START %s", __PRETTY_FUNCTION__);
  [networkTimer invalidate], networkTimer = nil;
  [[self availableServers] removeAllObjects];
    for (NSNetService *service in [self discoveredServers]) {
    [service setDelegate:nil];
    [service stop];
  }
  [[self discoveredServers] removeAllObjects];

  [[self discoveredServers] addObjectsFromArray:[_serviceBrowser servers]];
    for (NSNetService *service in [self discoveredServers]) {
    NSLog(@"%@", [service name]);
    [service setDelegate:self];
    [service resolveWithTimeout:15.0];
  }
  
  if (![self discoveredServers] || [[self discoveredServers] count] == 0) {
    NSString *serverUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsServerUUID];
    if (!serverUUID) {
      [[self delegate] zSyncNoServerPaired:[self availableServers]];
    }
  } else {
    NSString *serverUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsServerUUID];
    if (serverUUID) {
      networkTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 
                              target:self 
                              selector:@selector(networkTimeout:) 
                              userInfo:nil
                               repeats:NO];
    }
    
  }

  NSLog(@"END   %s", __PRETTY_FUNCTION__);
  [lock unlock];
}

#pragma mark -
#pragma mark NSNetServiceDelegate methods

/* Sent to the NSNetService instance's delegate prior to resolving a service on the network. If for some reason the resolution cannot occur, the delegate will not receive this message, and an error will be delivered to the delegate via the delegate's -netService:didNotResolve: method.
 */
- (void)netServiceWillResolve:(NSNetService *)sender
{
  NSLog(@"%s", __PRETTY_FUNCTION__);
}

/* Sent to the NSNetService instance's delegate when one or more addresses have been resolved for an NSNetService instance. Some NSNetService methods will return different results before and after a successful resolution. An NSNetService instance may get resolved more than once; truly robust clients may wish to resolve again after an error, or to resolve more than once.
 */
- (void)netServiceDidResolveAddress:(NSNetService *)bonjourService
{
	NSLog(@"%s", __PRETTY_FUNCTION__);
	
	NSString *registeredServerUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsServerUUID];
	NSString *registeredServerName = [[NSUserDefaults standardUserDefaults] valueForKey:zsServerName];
	
	@try {
		if (!registeredServerUUID) { //See if the server is in this list
			NSString *incomingServerName = [bonjourService name];
			DLog(@"[bonjourService TXTRecordData] %@", [bonjourService TXTRecordData]);
			NSDictionary *txtRecordDictionary = [NSNetService dictionaryFromTXTRecordData:[bonjourService TXTRecordData]];
			if (!txtRecordDictionary) {
				DLog(@"The NSNetService named %@ did not contain a TXT record", incomingServerName);
				return;
			}
			
			NSData *serverUUIDData = [txtRecordDictionary objectForKey:zsServerUUID];
			if (!serverUUIDData) {
				DLog(@"The TXT record did not contain a UUID.");
				return;
			}
			NSString *incomingServerUUID = [[NSString alloc] initWithData:serverUUIDData encoding:NSUTF8StringEncoding];
			if (!incomingServerUUID || [incomingServerUUID length] == 0) {
				DLog(@"The TXT record UUID was zero length.");
				[incomingServerUUID release], incomingServerUUID = nil;
				return;
			}
			
			ZSyncService *zSyncService = [[ZSyncService alloc] init];
			[zSyncService setService:bonjourService];
			[zSyncService setName:incomingServerName];
			[zSyncService setUuid:incomingServerUUID];
			[[self availableServers] addObject:zSyncService];
			[zSyncService release], zSyncService = nil;
			
			[[self delegate] zSyncNoServerPaired:[self availableServers]];
			
			[incomingServerUUID release], incomingServerUUID = nil;
			
			return;
		}
		
		NSDictionary *txtRecordDictionary = [NSNetService dictionaryFromTXTRecordData:[bonjourService TXTRecordData]];
		if (!txtRecordDictionary) {
			DLog(@"Found a serverUUID, but the NSNetService named %@ did not contain a TXT record", [bonjourService name]);
			return;
		}
		
		NSData *incomingServerUUIDData = [txtRecordDictionary objectForKey:zsServerUUID];
		if (!incomingServerUUIDData) {
			DLog(@"TXT record did not contain server UUID data");
			return;
		}
		
		NSString *incomingServerUUID = [[NSString alloc] initWithData:incomingServerUUIDData encoding:NSUTF8StringEncoding];
		if (![incomingServerUUID isEqualToString:registeredServerUUID]) {
			NSData *incomingServerNameData = [txtRecordDictionary objectForKey:zsServerName];
			if (!incomingServerNameData) {
				DLog(@"TXT record did not contain server name data");
				[incomingServerUUID release], incomingServerUUID = nil;
				return;	
			}
			NSString *incomingServerName = [[NSString alloc] initWithData:incomingServerNameData encoding:NSUTF8StringEncoding];
			if (![incomingServerName isEqualToString:registeredServerName]) {
				DLog(@"Incoming server name did not match registered server name, %@ != %@", incomingServerName, registeredServerName);
				[incomingServerUUID release], incomingServerUUID = nil;
				[incomingServerName release], incomingServerName = nil;
				return;
			}
			
			if ([incomingServerUUID hasPrefix:registeredServerUUID]) {
				DLog(@"Found an instance of an old UUID that we will upgrade");
				[[NSUserDefaults standardUserDefaults] setValue:incomingServerUUID forKey:zsServerUUID];
				[incomingServerUUID release], incomingServerUUID = nil;
				[incomingServerName release], incomingServerName = nil;
			} else {
				DLog(@"Incoming server UUID did not have a prefix of the registered server UUID, %@ does not start with %@", incomingServerUUID, registeredServerUUID);
				[incomingServerUUID release], incomingServerUUID = nil;
				[incomingServerName release], incomingServerName = nil;
				
				return;
			}
		}
		
		[networkTimer invalidate], networkTimer = nil;
		DLog(@"our server found");
		//Found our server, start the sync
		[self beginSyncWithService:bonjourService];
		return;
	} @finally {
		// Not sure what to put in here, we don't need to stop the service browser each time anymore.
	}
}

/* Sent to the NSNetService instance's delegate when an error in resolving the instance occurs. The error dictionary will contain two key/value pairs representing the error domain and code (see the NSNetServicesError enumeration above for error code constants).
 */
- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict
{
  NSLog(@"%s", __PRETTY_FUNCTION__);
  [[self discoveredServers] removeObject:sender];

  //Did not find our registered server.  Fail
  if ([[self discoveredServers] count] == 0) {
    [[self delegate] zSyncServerUnavailable:self];
    [self setServerAction:ZSyncServerActionNoActivity];
  }
}

/* Sent to the NSNetService instance's delegate when the instance's previously running publication or resolution request has stopped.
 */
- (void)netServiceDidStop:(NSNetService *)sender
{
  NSLog(@"%s", __PRETTY_FUNCTION__);
//  if ([[self discoveredServers] count] == 0) {
//    [[self delegate] zSyncServerUnavailable:self];
//    [self setServerAction:ZSyncServerActionNoActivity];
//  }
}

/* Sent to the NSNetService instance's delegate when the instance is being monitored and the instance's TXT record has been updated. The new record is contained in the data parameter.
 */
- (void)netService:(NSNetService *)sender didUpdateTXTRecordData:(NSData *)data
{
  NSLog(@"%s", __PRETTY_FUNCTION__);
}

#pragma mark -

- (void)registerDelegate:(id<ZSyncDelegate>)delegate withPersistentStoreCoordinator:(NSPersistentStoreCoordinator*)coordinator;
{
  [self setDelegate:delegate];
  [self setPersistentStoreCoordinator:coordinator];
}

- (void)receiveFile:(BLIPRequest*)request
{
  ZAssert([request complete], @"Message is incomplete");
  DLog(@"file received");
  if (!receivedFileLookupDictionary) {
    receivedFileLookupDictionary = [[NSMutableDictionary alloc] init];
  }
  NSMutableDictionary *fileDict = [[NSMutableDictionary alloc] init];
  [fileDict setValue:[request valueOfProperty:zsStoreIdentifier] forKey:zsStoreIdentifier];
  if (![[request valueOfProperty:zsStoreConfiguration] isEqualToString:@"PF_DEFAULT_CONFIGURATION_NAME"]) {
    [fileDict setValue:[request valueOfProperty:zsStoreConfiguration] forKey:zsStoreConfiguration];
  }
  [fileDict setValue:[request valueOfProperty:zsStoreType] forKey:zsStoreType];
  
  NSString *tempFilename = [[NSProcessInfo processInfo] globallyUniqueString];
  NSString *tempPath = [[self cachePath] stringByAppendingPathComponent:tempFilename];
  DLog(@"file written to \n%@", tempPath);
  
  DLog(@"request length: %i", [[request body] length]);
  [[request body] writeToFile:tempPath atomically:YES];
  [fileDict setValue:tempPath forKey:zsTempFilePath];
  
  [receivedFileLookupDictionary setValue:fileDict forKey:[request valueOfProperty:zsStoreIdentifier]];
  [fileDict release], fileDict = nil;
  
  BLIPResponse *response = [request response];
  [response setValue:zsActID(zsActionFileReceived) ofProperty:zsAction];
  [response setValue:[request valueOfProperty:zsStoreIdentifier] ofProperty:zsStoreIdentifier];
  [response send];
}

- (BOOL)switchStore:(NSPersistentStore*)store withReplacement:(NSDictionary*)replacement error:(NSError**)error
{
  NSDictionary *storeOptions = [[[store options] copy] autorelease];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSPersistentStoreCoordinator *psc = [self persistentStoreCoordinator];
  
  NSString *newFileTempPath = [replacement valueForKey:zsTempFilePath];
  NSString *fileOriginalPath = [[store URL] path];
  NSString *originalFileTempPath = [fileOriginalPath stringByAppendingPathExtension:@"zsync_"];
  
  if (![psc removePersistentStore:store error:error]) return NO;
  
  if ([fileManager fileExistsAtPath:originalFileTempPath]) {
    DLog(@"deleting stored file");
    if (![fileManager removeItemAtPath:originalFileTempPath error:error]) return NO;
  }
  
  if ([fileManager fileExistsAtPath:fileOriginalPath]) {
    if (![fileManager moveItemAtPath:fileOriginalPath toPath:originalFileTempPath error:error]) return NO;
  }
  
  if (![fileManager moveItemAtPath:newFileTempPath toPath:fileOriginalPath error:error]) return NO;
  
  NSURL *fileURL = [NSURL fileURLWithPath:fileOriginalPath];
  if (![psc addPersistentStoreWithType:[replacement valueForKey:zsStoreType] configuration:[replacement valueForKey:zsStoreConfiguration] URL:fileURL options:storeOptions error:error]) return NO;
  
  DLog(@"store switched");
  return YES;
}

- (void)completeSync
{
  [[self persistentStoreCoordinator] lock];
  
  //First we need to verify that we received every file.  Otherwise we fail
  for (NSPersistentStore *store in [[self persistentStoreCoordinator] persistentStores]) {
    if ([receivedFileLookupDictionary objectForKey:[store identifier]]) continue;
    
    DLog(@"Store ID: %@\n%@", [store identifier], [receivedFileLookupDictionary allKeys]);
    //Fail
    if ([[self delegate] respondsToSelector:@selector(zSync:errorOccurred:)]) {
      //Flush the temp files
      for (NSDictionary *fileDict in [receivedFileLookupDictionary allValues]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:[fileDict valueForKey:zsTempFilePath] error:&error];
        // We want to explode on this failure in dev but in prod just note it
        ZAssert(error == nil, @"Error deleting temp file: %@", [error localizedDescription]);
      }
      NSDictionary *userInfo = [NSDictionary dictionaryWithObject:[store identifier] forKey:zsStoreIdentifier];
      NSError *error = [NSError errorWithDomain:zsErrorDomain code:zsErrorFailedToReceiveAllFiles userInfo:userInfo];
      [[self delegate] zSync:self errorOccurred:error];
      [receivedFileLookupDictionary release], receivedFileLookupDictionary = nil;
    }
    [[self persistentStoreCoordinator] unlock];
    return;
  }
  
  //We have all of the files now we need to swap them out.
  for (NSPersistentStore *store in [[self persistentStoreCoordinator] persistentStores]) {
    NSDictionary *replacement = [receivedFileLookupDictionary valueForKey:[store identifier]];
    ZAssert(replacement != nil, @"Missing the replacement file for %@\n%@", [store identifier], [receivedFileLookupDictionary allKeys]);
    NSError *error = nil;
    if ([self switchStore:store withReplacement:replacement error:&error]) continue;
    ZAssert(error == nil, @"Error switching stores: %@\n%@", [error localizedDescription], [error userInfo]);
    
    //TODO: We failed in the migration and need to roll back
  }
  
  [receivedFileLookupDictionary release], receivedFileLookupDictionary = nil;
  
  [[self connection] close];
  [self setConnection:nil];
  
  if ([[self delegate] respondsToSelector:@selector(zSyncFinished:)]) {
    [[self delegate] zSyncFinished:self];
  }
  
  [[self persistentStoreCoordinator] unlock];
  
  [self setServerAction:ZSyncServerActionNoActivity];
}

/*
 * We want to start looking for desktops to sync with here.  Once started
 * We want to maintain a list of computers found and also send out a notification
 * for every server that we discover
 */
- (void)startBrowser;
{
  if (_serviceBrowser) return;
  _serviceBrowser = [[ServerBrowser alloc] init];
  _serviceBrowser.delegate = self;
 [_serviceBrowser start];
}

//- (NSArray*)availableServers;
//{
//  NSMutableSet *set = [NSMutableSet set];
//  for (NSNetService *bonjourService in [_serviceBrowser servers]) {
//    [bonjourService setDelegate:self];
//    [bonjourService resolveWithTimeout:3.0];
//    NSString *serverName = [bonjourService name];
////    NSArray *components = [serverName componentsSeparatedByString:zsServerNameSeperator];
////    if (!components || [components count] != 2) {
////      NSLog(@"Wrong number of components: %i\n%@", [components count], serverName);
////      continue;
////    }
////
////    ZAssert([components count] == 2,@"Wrong number of components: %i\n%@", [components count], serverName);
////    NSString *serverUUID = [components objectAtIndex:1];
//    DLog(@"[bonjourService TXTRecordData] %@", [bonjourService TXTRecordData]);
//    NSDictionary *txtRecordDictionary = [NSNetService dictionaryFromTXTRecordData:[bonjourService TXTRecordData]];
//    if (!txtRecordDictionary) {
//      DLog(@"The NSNetService named %@ did not contain a TXT record", [bonjourService name]);
//      continue;
//    }
//    
//    for (NSString *key in [txtRecordDictionary allKeys]) {
//      DLog(@"key: %@ object: %@", key, [txtRecordDictionary objectForKey:key]);
//    }
//    
//    NSLog(@"zsServerUUID: %@ zsServerName: %@", zsServerUUID, zsServerName);
//    
//    NSString *serverUUID = [txtRecordDictionary objectForKey:zsServerUUID];
//    if (!serverUUID || [serverUUID length] == 0) {
//      DLog(@"The TXT record did not contain a UUID.");
//    }
//    //    serverName = [components objectAtIndex:0];
//    
//    ZSyncService *zSyncService = [[ZSyncService alloc] init];
//    [zSyncService setService:bonjourService];
//    [zSyncService setName:serverName];
//    [zSyncService setUuid:serverUUID];
//    [set addObject:zSyncService];
//    [zSyncService release], zSyncService = nil;
//  }
//  
//  NSSortDescriptor *sort = [[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES];
//  NSArray *result = [set allObjects];
//  result = [result sortedArrayUsingDescriptors:[NSArray arrayWithObject:sort]];
//  [sort release], sort = nil;
//  
//  return result;
//}

- (void)sendUploadComplete
{
  DLog(@"sending upload complete");
  NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
  [dictionary setValue:zsActID(zsActionPerformSync) forKey:zsAction];
  BLIPRequest *request = [BLIPRequest requestWithBody:nil properties:dictionary];
  [request setNoReply:YES];
  [[self connection] sendRequest:request];
  [dictionary release], dictionary = nil;
}

- (void)uploadDataToServer;
{
  [[self serviceBrowser] setDelegate:nil];
  [[self serviceBrowser] stop];
  [self setServiceBrowser:nil];
  
  [[self delegate] zSyncStarted:self];
  
  storeFileIdentifiers = [[NSMutableArray alloc] init];
  
  NSAssert([self persistentStoreCoordinator] != nil, @"The persistent store coordinator was nil. Make sure you are calling registerDelegate:withPersistentStoreCoordinator: before trying to sync.");
  
  for (NSPersistentStore *store in [[self persistentStoreCoordinator] persistentStores]) {
    NSData *data = [[NSData alloc] initWithContentsOfMappedFile:[[store URL] path]];
    DLog(@"url %@\nIdentifier: %@\nSize: %i", [store URL], [store identifier], [data length]);
    
    NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
    [dictionary setValue:[store identifier] forKey:zsStoreIdentifier];
    if (![[store configurationName] isEqualToString:@"PF_DEFAULT_CONFIGURATION_NAME"]) {
      [dictionary setValue:[store configurationName] forKey:zsStoreConfiguration];
    }
    [dictionary setValue:[store type] forKey:zsStoreType];
    [dictionary setValue:zsActID(zsActionStoreUpload) forKey:zsAction];
    
    BLIPRequest *request = [BLIPRequest requestWithBody:data properties:dictionary];
    // TODO: Compression is not working.  Need to find out why
    [request setCompressed:YES];
    [[self connection] sendRequest:request];
    [data release], data = nil;
    [dictionary release], dictionary = nil;
    DLog(@"file uploaded");
    
    [storeFileIdentifiers addObject:[store identifier]];
  }
  DLog(@"finished");
}

- (void)processTestFileTransfer:(BLIPRequest*)request
{
  NSData *data = [request body];
  DLog(@"length %i", [data length]);
  NSString *path = [self cachePath];
  path = [path stringByAppendingPathComponent:@"test.jpg"];
  
  NSError *error = nil;
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    DLog(@"deleting old file");
    [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    ZAssert(error == nil, @"error removing test file: %@", [error localizedDescription]);
  }
  
  [data writeToFile:path atomically:YES];
  DLog(@"file written\n%@", path);
}

- (NSString*)generatePairingCode
{
  NSMutableString *string = [NSMutableString string];
  [string appendFormat:@"%i", (arc4random() % 10)];
  [string appendFormat:@"%i", (arc4random() % 10)];
  [string appendFormat:@"%i", (arc4random() % 10)];
  [string appendFormat:@"%i", (arc4random() % 10)];
  return string;
}

- (void)requestDeregistration;
{
  DLog(@"issuing deregister command");
  NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
  [dictionary setValue:zsActID(zsActionDeregisterClient) forKey:zsAction];
  
  NSString *syncUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsSyncGUID];
  
  NSData *body = [syncUUID dataUsingEncoding:NSUTF8StringEncoding];
  
  BLIPRequest *request = [BLIPRequest requestWithBody:body properties:dictionary];
  [[self connection] sendRequest:request];
}

- (void)connectionEstablished
{
  switch ([self serverAction]) {
    case ZSyncServerActionSync:
      if ([[NSUserDefaults standardUserDefaults] valueForKey:zsServerUUID]) {
        //Start a sync by pushing the data file to the server
        [self uploadDataToServer];
      } else {
        //We are not paired so we need to request a pairing session
        NSString *deviceUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsDeviceID];
        if (!deviceUUID) {
          deviceUUID = [[NSProcessInfo processInfo] globallyUniqueString];
          [[NSUserDefaults standardUserDefaults] setValue:deviceUUID forKey:zsDeviceID];
        }
        
        [self setPasscode:[self generatePairingCode]];
        BLIPRequest *request = [BLIPRequest requestWithBodyString:[self passcode]];
        [request setValue:zsActID(zsActionRequestPairing) ofProperty:zsAction];
        [request setValue:deviceUUID ofProperty:zsDeviceID];
        [[self connection] sendRequest:request];
        
        [[self delegate] zSyncHandler:self displayPairingCode:[self passcode]];
      }
      break;
    case ZSyncServerActionDeregister:
      [self requestDeregistration];
      break;
    default:
      ALog(@"Unknown server action: %i", serverAction);
  }
}


#pragma mark -
#pragma mark BLIP Delegate

/* Two possible states at this point. If we have a server UUID
 * then we are ready to start a sync.  If we do not have a server UUID
 * then we need to start a pairing.
 */
- (void)connectionDidOpen:(BLIPConnection*)connection 
{
  DLog(@"entered");
  //Start by confirming that the server still supports our schema and version
  
  NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
  [dict setValue:zsActID(zsActionVerifySchema) forKey:zsAction];
  [dict setValue:zsActID([self majorVersionNumber]) forKey:zsSchemaMajorVersion];
  [dict setValue:zsActID([self minorVersionNumber]) forKey:zsSchemaMinorVersion];
  [dict setValue:[[UIDevice currentDevice] name] forKey:zsDeviceName];
  [dict setValue:[[UIDevice currentDevice] uniqueIdentifier] forKey:zsDeviceGUID];
  NSString *deviceGUID = [[[NSBundle mainBundle] infoDictionary] objectForKey:zsSchemaIdentifier];
  [dict setValue:deviceGUID forKey:zsSchemaIdentifier];
  
  NSString *syncGUID = [[NSUserDefaults standardUserDefaults] stringForKey:zsSyncGUID];
  if (!syncGUID) {
    syncGUID = [[NSProcessInfo processInfo] globallyUniqueString];
    [[NSUserDefaults standardUserDefaults] setValue:syncGUID forKey:zsSyncGUID];
  }
  NSData *data = [syncGUID dataUsingEncoding:NSUTF8StringEncoding];
  BLIPRequest *request = [connection requestWithBody:data properties:dict];
  [request send];
  [dict release], dict = nil;
  DLog(@"initial send complete");
}

/* We had an error talking to the server.  Push this error on to our delegate
 * and close the connection
 */
- (void)connection:(TCPConnection*)connection failedToOpen:(NSError*)error
{
  DLog(@"entered");
  [_connection close], [_connection release], _connection = nil;
  [[self delegate] zSync:self errorOccurred:error];
}

- (void)connection:(BLIPConnection*)connection receivedResponse:(BLIPResponse*)response;
{
  if (![[response properties] valueOfProperty:zsAction]) {
    DLog(@"received empty response, ignoring");
    return;
  }
  DLog(@"entered\n%@", [[response properties] allProperties]);
  NSInteger action = [[[response properties] valueOfProperty:zsAction] integerValue];
  switch (action) {
    case zsActionDeregisterClient:
      if ([[self delegate] respondsToSelector:@selector(zSyncDeregisterComplete:)]) {
        [[self delegate] zSyncDeregisterComplete:self];
      }
      [self setServerAction:ZSyncServerActionNoActivity];
      [[self connection] close];
      [self setConnection:nil];
      return;
    case zsActionFileReceived:
      ZAssert(storeFileIdentifiers != nil, @"zsActionFileReceived with a nil storeFileIdentifiers");
      [storeFileIdentifiers removeObject:[[response properties] valueOfProperty:zsStoreIdentifier]];
      if ([storeFileIdentifiers count] == 0) {
        [self sendUploadComplete];
        [storeFileIdentifiers release], storeFileIdentifiers = nil;
      }
      return;
    case zsActionRequestPairing:
      //Server has accepted the pairing request
      //Notify the delegate to present a pairing dialog
      if ([[self delegate] respondsToSelector:@selector(zSyncPairingRequestAccepted:)]) {
        // ???: This does nothing currently!
        //[[self delegate] zSyncPairingRequestAccepted:self];
      }
      return;
    case zsActionAuthenticatePassed:
      ALog(@"%s server UUID accepted: %@", [response valueOfProperty:zsServerUUID]);
//      [[NSUserDefaults standardUserDefaults] setValue:[response valueOfProperty:zsServerUUID] forKey:zsServerUUID];
//      [[NSUserDefaults standardUserDefaults] setValue:[response valueOfProperty:zsServerName] forKey:zsServerName];
//      if ([[self delegate] respondsToSelector:@selector(zSyncPairingCodeApproved:)]) {
//        [[self delegate] zSyncPairingCodeApproved:self];
//      }
//      [[self serviceBrowser] stop];
//      [_serviceBrowser release], _serviceBrowser = nil;
//      [self uploadDataToServer];
      return;
    case zsActionSchemaUnsupported:
      if ([[self delegate] respondsToSelector:@selector(zSync:serverVersionUnsupported:)]) {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:[response bodyString] forKey:NSLocalizedDescriptionKey];
        NSError *error = [NSError errorWithDomain:zsErrorDomain code:[[response valueOfProperty:zsErrorCode] integerValue] userInfo:userInfo];
        
        [[self delegate] zSync:self serverVersionUnsupported:error];
      }
      [[self connection] close];
      [self setConnection:nil];
      [self setServerAction:ZSyncServerActionNoActivity];
      return;
    case zsActionSchemaSupported:
      [self connectionEstablished];
      return;
    default:
      ALog(@"%s unknown action received %i", action);
  }
}

- (BOOL)connection:(BLIPConnection*)connection receivedRequest:(BLIPRequest*)request
{
  NSInteger action = [[[request properties] valueOfProperty:zsAction] integerValue];
  switch (action) {
    case zsActionAuthenticateFailed:
      /* 
       * The pairing code was not entered correctly so we reset back to a default state
       * so that the user can start all over again.
       */
      [[self connection] close];
      [self setConnection:nil];
      if ([[self delegate] respondsToSelector:@selector(zSyncPairingCodeRejected:)]) {
        [[self delegate] zSyncPairingCodeRejected:self];
      }
      [self setServerAction:ZSyncServerActionNoActivity];
      [[NSUserDefaults standardUserDefaults] removeObjectForKey:zsServerUUID];
      [[NSUserDefaults standardUserDefaults] removeObjectForKey:zsServerName];
      return YES;
    case zsActionAuthenticatePairing:
      if ([[request bodyString] isEqualToString:[self passcode]]) {
        [[request response] setValue:zsActID(zsActionAuthenticatePassed) ofProperty:zsAction];
        [[NSUserDefaults standardUserDefaults] setValue:[request valueOfProperty:zsServerUUID] forKey:zsServerUUID];
        [self performSelector:@selector(uploadDataToServer) withObject:nil afterDelay:0.1];
      } else {
        [[request response] setValue:zsActID(zsActionAuthenticateFailed) ofProperty:zsAction];
      }
      [[self delegate] zSyncPairingCodeCompleted:self];
      return YES;
    case zsActionTestFileTransfer:
      [self processTestFileTransfer:request];
      return YES;
    case zsActionCompleteSync:
      DLog(@"completeSync");
      [self performSelector:@selector(completeSync) withObject:nil afterDelay:0.01];
      return YES;
    case zsActionStoreUpload:
      DLog(@"receiveFile");
      [self receiveFile:request];
      return YES;
    case zsActionCancelPairing:
      DLog(@"Cancel Pairing request received");
      [[self connection] close];
      [self setConnection:nil];
      if ([[self delegate] respondsToSelector:@selector(zSyncPairingCodeCancelled:)]) {
        [[self delegate] zSyncPairingCodeCancelled:self];
      }
      [self setServerAction:ZSyncServerActionNoActivity];
      [[NSUserDefaults standardUserDefaults] removeObjectForKey:zsServerUUID];
      [[NSUserDefaults standardUserDefaults] removeObjectForKey:zsServerName];
      return YES;
    default:
      ALog(@"Unknown action received: %i", action);
      return NO;
  }
}

- (void)connectionDidClose:(TCPConnection*)connection;
{
  if (![self connection]) return;
  
  //premature closing
  [self setConnection:nil];
  [self setServerAction:ZSyncServerActionNoActivity];
  
  if (![[self delegate] respondsToSelector:@selector(zSync:errorOccurred:)]) return;

  NSDictionary *userInfo = [NSDictionary dictionaryWithObject:NSLocalizedString(@"Server Hung Up", @"Server Hung Up message text") forKey:NSLocalizedDescriptionKey];
  NSError *error = [NSError errorWithDomain:zsErrorDomain code:zsErrorServerHungUp userInfo:userInfo];
  [[self delegate] zSync:self errorOccurred:error];
}

@synthesize delegate = _delegate;

@synthesize serviceBrowser = _serviceBrowser;
@synthesize connection = _connection;
@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

@synthesize majorVersionNumber;
@synthesize minorVersionNumber;
@synthesize passcode;
@synthesize serverAction;
@synthesize availableServers;
@synthesize discoveredServers;
@synthesize lock;

@end

@implementation ZSyncService

@synthesize name;
@synthesize uuid;
@synthesize service;

- (NSString*)description
{
  return [NSString stringWithFormat:@"[%@:%@]", [self name], [self uuid]];
}

- (NSUInteger)hash
{
  return [[self description] hash];
}

- (BOOL)isEqual:(id)object
{
  if (!object || ![object isKindOfClass:[ZSyncService class]]) return NO;
  
  if (![[object name] isEqualToString:[self name]]) return NO;
  if (![[object uuid] isEqualToString:[self uuid]]) return NO;
  
  return YES;
}

@end