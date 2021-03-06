/* =============================================================================
	FILE:		UKFSEventsWatcher.m
    
    COPYRIGHT:  (c) 2008 Peter Baumgartner, all rights reserved.
    
	AUTHORS:	Peter Baumgartner
    
    LICENSES:   MIT License

	REVISIONS:
		2008-06-09	PB Created.
   ========================================================================== */

// -----------------------------------------------------------------------------
//  Headers:
// -----------------------------------------------------------------------------

#import "UKFSEventsWatcher.h"
#import <CoreServices/CoreServices.h>

// -----------------------------------------------------------------------------
//  FSEventCallback
//		Private callback that is called by the FSEvents framework
// -----------------------------------------------------------------------------

#if MAC_OS_X_VERSION_MAX_ALLOWED > MAC_OS_X_VERSION_10_4

static void FSEventCallback(ConstFSEventStreamRef inStreamRef, 
							void* inClientCallBackInfo, 
							size_t inNumEvents, 
							void* inEventPaths, 
							const FSEventStreamEventFlags inEventFlags[], 
							const FSEventStreamEventId inEventIds[])
{
	UKFSEventsWatcher* watcher = (UKFSEventsWatcher*)inClientCallBackInfo;
	
	if (watcher != nil && [watcher delegate] != nil)
	{
		id delegate = [watcher delegate];
		
		if ([delegate respondsToSelector:@selector(watcher:receivedNotification:forPath:)])
		{
			NSEnumerator* paths = [(NSArray*)inEventPaths objectEnumerator];
			NSString* path;
			
			while (path = [paths nextObject])
			{
				[delegate watcher:watcher receivedNotification:UKFileWatcherWriteNotification forPath:path];
				
				[[[NSWorkspace sharedWorkspace] notificationCenter] 
					postNotificationName: UKFileWatcherWriteNotification
					object:watcher
					userInfo:[NSDictionary dictionaryWithObjectsAndKeys:path,@"path",nil]];
			}	
		}
	}
}

@implementation UKFSEventsWatcher

// -----------------------------------------------------------------------------
//  sharedFileWatcher:
//		Singleton accessor.
// -----------------------------------------------------------------------------

+ (id) sharedFileWatcher
{
	static UKFSEventsWatcher* sSharedFileWatcher = nil;
	static NSString* sSharedFileWatcherMutex = @"UKFSEventsWatcher";
	
	@synchronized(sSharedFileWatcherMutex)
	{
		if (sSharedFileWatcher == nil)
		{
			sSharedFileWatcher = [[UKFSEventsWatcher alloc] init];	// This is a singleton, and thus an intentional "leak".
		}	
    }
	
    return sSharedFileWatcher;
}

// -----------------------------------------------------------------------------
//  * CONSTRUCTOR:
// -----------------------------------------------------------------------------

- (id) init
{
    if (self = [super init])
	{
		latency = 1.0;
		flags = kFSEventStreamCreateFlagUseCFTypes;
		eventStreams = [[NSMutableDictionary alloc] init];
		eventStreamPaths = [[NSCountedSet alloc] init];
    }
	
    return self;
}

// -----------------------------------------------------------------------------
//  * DESTRUCTOR:
// -----------------------------------------------------------------------------

- (void) dealloc
{
	[self removeAllPaths];
    [eventStreams release];
	[eventStreamPaths release];
    [super dealloc];
}

- (void) finalize
{
	[self removeAllPaths];
    [super finalize];
}

// -----------------------------------------------------------------------------
//  setLatency:
//		Time that must pass before events are being sent.
// -----------------------------------------------------------------------------

- (void) setLatency:(CFTimeInterval)inLatency
{
	latency = inLatency;
}

// -----------------------------------------------------------------------------
//  latency
//		Time that must pass before events are being sent.
// -----------------------------------------------------------------------------

- (CFTimeInterval) latency
{
	return latency;
}

// -----------------------------------------------------------------------------
//  setFSEventStreamCreateFlags:
//		See FSEvents.h for meaning of these flags.
// -----------------------------------------------------------------------------

- (void) setFSEventStreamCreateFlags:(FSEventStreamCreateFlags)inFlags
{
	flags = inFlags;
}

// -----------------------------------------------------------------------------
//  fsEventStreamCreateFlags
//		See FSEvents.h for meaning of these flags.
// -----------------------------------------------------------------------------

- (FSEventStreamCreateFlags) fsEventStreamCreateFlags
{
	return flags;
}

// -----------------------------------------------------------------------------
//  setDelegate:
//		Mutator for file watcher delegate.
// -----------------------------------------------------------------------------

- (void) setDelegate:(id)newDelegate
{
    delegate = newDelegate;
}

// -----------------------------------------------------------------------------
//  delegate:
//		Accessor for file watcher delegate.
// -----------------------------------------------------------------------------

- (id) delegate
{
    return delegate;
}

// -----------------------------------------------------------------------------
//  pathToParentFolderOfFile:error:
//		We need to supply a folder to FSEvents, so if we were passed a path  
//		to a file, then convert it to the parent folder path...
// -----------------------------------------------------------------------------

- (NSString*) pathToParentFolderOfFile:(NSURL *)url error:(NSError **)error;
{
    NSDictionary *properties = [url resourceValuesForKeys:[NSArray arrayWithObjects:NSURLIsDirectoryKey, NSURLIsPackageKey, nil] error:error];
    if (!properties) return nil;
    
    if (![[properties objectForKey:NSURLIsDirectoryKey] boolValue] || [[properties objectForKey:NSURLIsPackageKey] boolValue])
	{
		NSURL *parent;
        if ([url getResourceValue:&parent forKey:NSURLParentDirectoryURLKey error:error])
        {
            return [self pathToParentFolderOfFile:parent error:error];
        }
        else
        {
            return nil;
        }
	}
	
    NSAssert([url isFileURL], @"Somehow a non-file URL slipped past -resourceValuesForKeys:error:");
	NSString *result = [url path];
    NSAssert(result, @"Somehow we have a file URL with nil path: %@", url); // I think this might be possible with file ref URLs
    return result;
}

- (BOOL) _registerFSEventsObserverForPath:(NSString*)path error:(NSError **)error
{
	BOOL succeeded = YES;
	FSEventStreamContext context;
	context.version = 0;
	context.info = (void*) self;
	context.retain = NULL;
	context.release = NULL;
	context.copyDescription = NULL;

	NSArray* pathArray = [NSArray arrayWithObject:path];
	FSEventStreamRef stream = FSEventStreamCreate(NULL,&FSEventCallback,&context,(CFArrayRef)pathArray,kFSEventStreamEventIdSinceNow,latency,flags);

	if (stream)
	{
        CFRunLoopRef runLoop = CFRunLoopGetMain();
		FSEventStreamScheduleWithRunLoop(stream, runLoop, kCFRunLoopCommonModes);
		succeeded = FSEventStreamStart(stream);
        
        if (succeeded)
        {
            [eventStreams setObject:[NSValue valueWithPointer:stream] forKey:path];
        }
        else
        {
            FSEventStreamUnscheduleFromRunLoop(stream, runLoop, kCFRunLoopCommonModes);
            FSEventStreamRelease(stream);
            
            if (error)
            {
                NSDictionary *userInfo = [NSDictionary dictionaryWithObject:path forKey:NSFilePathErrorKey];
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:userInfo];
            }
        }
	}
	else
	{
		if (error)
        {
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject:path forKey:NSFilePathErrorKey];
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:userInfo];
        }
        
		succeeded = NO;
	}
	
	return succeeded;
}

// -----------------------------------------------------------------------------
//  addURL:error:
//		Start watching the folder at the specified path, or if we are already watching
//		the path, increase its count in eventStreamPaths
// -----------------------------------------------------------------------------

- (BOOL)addURL:(NSURL *)url error:(NSError **)error;
{
	NSString *path = [self pathToParentFolderOfFile:url error:error];
    if (!path) return NO;

	// Do we already have a stream scheduled for this path?
	// NOTE: Synchronize the whole thing so we don't run the risk of the current count changing while 
	// we're busy updating it with our new addition.
	@synchronized (self)
	{
		BOOL succeeded = YES;
		
		NSUInteger currentRegistrationCount = [eventStreamPaths countForObject:path];
		if (currentRegistrationCount == 0)
		{
			succeeded = [self _registerFSEventsObserverForPath:path error:error];
		}		
		
		if (succeeded)
		{
			[eventStreamPaths addObject:path];
		}
        
        return succeeded;
	}
}

- (void)addPath:(NSString *)path
{
    [self addURL:[NSURL fileURLWithPath:path] error:NULL];
}

- (void) _unregisterFSEventStream:(FSEventStreamRef)stream
{
	FSEventStreamStop(stream);
	FSEventStreamInvalidate(stream);
	FSEventStreamRelease(stream);
}

// -----------------------------------------------------------------------------
//  removePath:
//		Decrease the watch count for the given path, and if the count has gone 
//		to zero, stop watching the given path.
// -----------------------------------------------------------------------------

- (void) removePath:(NSString*)path
{
	// Ensure we are removing a folder, not a file inside the desired folder. This matches
	// the normalization done in addPath to make sure removePath for the same path will succeed.
    // FIXME: There's no guarantee from the filesystem that -pathToParentFolderOfFile:… will return the same result when called again, so really we need a better mechanism for this
	path = [self pathToParentFolderOfFile:[NSURL fileURLWithPath:path] error:NULL];
    if (!path) return;

    NSValue* valueToRemove = nil;
		
    @synchronized (self)
    {
		// We are sometimes asked to removePath on a path that we were never asked to add. That's 
		// OK - it just means they are being extra-certain before (probably) adding it for the 
		// first time...
		NSUInteger currentRegistrationCount = [eventStreamPaths countForObject:path];
		if (currentRegistrationCount > 0)
		{
			[eventStreamPaths removeObject:path];
			
			NSUInteger newRegistrationCount = [eventStreamPaths countForObject:path];
			
			// Clear everything out if we've gone to zero
			if (newRegistrationCount == 0)
			{
				valueToRemove = [[[eventStreams objectForKey:path] retain] autorelease];
				[eventStreams removeObjectForKey:path];				
			}
		}
    }
    
	if (valueToRemove)
	{
		FSEventStreamRef stream = [valueToRemove pointerValue];
		
		if (stream)
		{
			[self _unregisterFSEventStream:stream];
		}
	}
}

// -----------------------------------------------------------------------------
//  removeAllPaths:
//		Stop watching all known paths.
// -----------------------------------------------------------------------------

- (void) removeAllPaths
{
	@synchronized (self)
	{
		// We don't really need the paths, we just need the open FSEventStreamRefs.
		// Unregister them all indiscriminately, then remove all objects from 
		// our tracking collections.
		
		NSEnumerator* eventStreamEnum = [[eventStreams allValues] objectEnumerator];
		NSValue* thisEventStreamPointer = nil;
		
		while (thisEventStreamPointer = [eventStreamEnum nextObject])
		{
			FSEventStreamRef stream = [thisEventStreamPointer pointerValue];

			if (stream)
			{
				[self _unregisterFSEventStream:stream];				
			}
		}
		
		[eventStreams removeAllObjects];
		[eventStreamPaths removeAllObjects];
	}
}

@end

#endif

