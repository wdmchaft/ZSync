//
//  ZSyncConnectionDelegate.h
//  ZSyncDaemon
//
//  Created by Marcus S. Zarra on 1/17/10.
//  Copyright 2010 Zarra Studios LLC. All rights reserved.
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
//

#import <SyncServices/SyncServices.h>
#import "ZSyncShared.h"
#import "PairingCodeWindowController.h"

@interface ZSyncConnectionDelegate : NSObject <BLIPConnectionDelegate, NSPersistentStoreCoordinatorSyncing, PairingCodeDelegate>
{
  PairingCodeWindowController *pairingCodeWindowController;
  BLIPConnection *_connection;
  NSString *pairingCode;
  NSInteger pairingCodeEntryCount;
  
  NSMutableArray *storeFileIdentifiers;
  
  NSManagedObject *syncApplication;
  
  NSManagedObjectModel *managedObjectModel;
  NSPersistentStoreCoordinator *persistentStoreCoordinator;
  NSManagedObjectContext *managedObjectContext;
}

@property (retain) NSMutableArray *storeFileIdentifiers;
@property (retain) NSManagedObjectModel *managedObjectModel;
@property (retain) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (retain) NSManagedObjectContext *managedObjectContext;
@property (retain) NSManagedObject *syncApplication;
@property (retain) BLIPConnection *connection;
@property (retain) NSString *pairingCode;
@property (assign) NSInteger pairingCodeEntryCount;

@property (retain) id pairingCodeWindowController;

@end