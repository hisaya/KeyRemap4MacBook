#import <Carbon/Carbon.h>
#import "AppDelegate.h"
#import "ClientForKernelspace.h"
#import "KeyRemap4MacBookKeys.h"
#import "NotificationKeys.h"
#import "PowerKeyObserver.h"
#import "PreferencesController.h"
#import "PreferencesKeys.h"
#import "PreferencesManager.h"
#import "ServerForUserspace.h"
#import "StatusBar.h"
#import "StatusWindow.h"
#import "Updater.h"
#import "WorkSpaceData.h"
#include <stdlib.h>

@implementation AppDelegate

@synthesize window;
@synthesize clientForKernelspace;

// ----------------------------------------
- (void) send_workspacedata_to_kext
{
  [clientForKernelspace send_workspacedata_to_kext:&bridgeworkspacedata_];
}

// ------------------------------------------------------------
- (void) observer_NSWorkspaceDidActivateApplicationNotification:(NSNotification*)notification
{
  dispatch_async(dispatch_get_main_queue(), ^{
                   NSString* name = [WorkSpaceData getActiveApplicationName];
                   if (name) {
                     // We ignore our investigation application.
                     if (! [name isEqualToString:@"org.pqrs.KeyRemap4MacBook.EventViewer"]) {
                       bridgeworkspacedata_.applicationtype = [workSpaceData_ getApplicationType:name];
                       [self send_workspacedata_to_kext];

                       @synchronized (self) {
                         [applicationInformation_ release];
                         applicationInformation_ = [@ { @"name":name } retain];
                       }

                       [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kKeyRemap4MacBookApplicationChangedNotification
                                                                                      object:nil];
                     }
                   }
                 });
}

- (void) distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:(NSNotification*)notification
{
  dispatch_async(dispatch_get_main_queue(), ^{
                   [WorkSpaceData refreshEnabledInputSources];
                 });
}

- (void) distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:(NSNotification*)notification
{
  dispatch_async(dispatch_get_main_queue(), ^{
                   InputSource* inputSource = [WorkSpaceData getCurrentInputSource];
                   [workSpaceData_ getInputSourceID:inputSource
                                 output_inputSource:(&(bridgeworkspacedata_.inputsource))
                           output_inputSourceDetail:(&(bridgeworkspacedata_.inputsourcedetail))];
                   [self send_workspacedata_to_kext];

                   @synchronized (self) {
                     [inputSourceInformation_ release];
                     inputSourceInformation_ = [NSMutableDictionary new];
                     if ([inputSource languagecode]) {
                       [inputSourceInformation_ setObject:[inputSource languagecode] forKey:@"languageCode"];
                     }
                     if ([inputSource inputSourceID]) {
                       [inputSourceInformation_ setObject:[inputSource inputSourceID] forKey:@"inputSourceID"];
                     }
                     if ([inputSource inputModeID]) {
                       [inputSourceInformation_ setObject:[inputSource inputModeID] forKey:@"inputModeID"];
                     }
                   }

                   [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kKeyRemap4MacBookInputSourceChangedNotification
                                                                                  object:nil];
                 });
}

- (void) observer_ConfigXMLReloaded:(NSNotification*)notification
{
  dispatch_async(dispatch_get_main_queue(), ^{
                   // If <appdef> or <inputsourcedef> is updated,
                   // the following values might be changed.
                   // Therefore, we need to resend values to kext.
                   //
                   // - bridgeworkspacedata_.applicationtype
                   // - bridgeworkspacedata_.inputsource
                   // - bridgeworkspacedata_.inputsourcedetail

                   [self observer_NSWorkspaceDidActivateApplicationNotification:nil];
                   [self distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:nil];
                   [self distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:nil];
                 });
}

// ------------------------------------------------------------
- (void) observer_NSWorkspaceDidWakeNotification:(NSNotification*)notification
{
  dispatch_async(dispatch_get_main_queue(), ^{
                   NSLog (@"observer_NSWorkspaceDidWakeNotification");

                   [preferencesManager_ clearNotSave];
                 });
}

- (void) registerWakeNotification
{
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceDidWakeNotification:)
                                                             name:NSWorkspaceDidWakeNotification
                                                           object:nil];
}

- (void) unregisterWakeNotification
{
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
                                                                name:NSWorkspaceDidWakeNotification
                                                              object:nil];
}

// ------------------------------------------------------------
static void observer_IONotification(void* refcon, io_iterator_t iterator)
{
  dispatch_async(dispatch_get_main_queue(), ^{
                   NSLog (@"observer_IONotification");

                   AppDelegate* self = refcon;
                   if (! self) {
                     NSLog (@"[ERROR] observer_IONotification refcon == nil\n");
                     return;
                   }

                   for (;; ) {
                     io_object_t obj = IOIteratorNext (iterator);
                     if (! obj) break;

                     IOObjectRelease (obj);
                   }
                   // Do not release iterator.

                   // = Documentation of IOKit =
                   // - Introduction to Accessing Hardware From Applications
                   //   - Finding and Accessing Devices
                   //
                   // In the case of IOServiceAddMatchingNotification, make sure you release the iterator only if you’re also ready to stop receiving notifications:
                   // When you release the iterator you receive from IOServiceAddMatchingNotification, you also disable the notification.

                   // ------------------------------------------------------------
                   [[self clientForKernelspace] refresh_connection_with_retry];
                   [self send_workspacedata_to_kext];
                 });
}

- (void) unregisterIONotification
{
  if (notifyport_) {
    if (loopsource_) {
      CFRunLoopSourceInvalidate(loopsource_);
      loopsource_ = nil;
    }
    IONotificationPortDestroy(notifyport_);
    notifyport_ = nil;
  }
}

- (void) registerIONotification
{
  [self unregisterIONotification];

  notifyport_ = IONotificationPortCreate(kIOMasterPortDefault);
  if (! notifyport_) {
    NSLog(@"[ERROR] IONotificationPortCreate failed\n");
    return;
  }

  // ----------------------------------------------------------------------
  io_iterator_t it;
  kern_return_t kernResult;

  kernResult = IOServiceAddMatchingNotification(notifyport_,
                                                kIOMatchedNotification,
                                                IOServiceNameMatching("org_pqrs_driver_KeyRemap4MacBook"),
                                                &observer_IONotification,
                                                self,
                                                &it);
  if (kernResult != kIOReturnSuccess) {
    NSLog(@"[ERROR] IOServiceAddMatchingNotification failed");
    return;
  }
  observer_IONotification(self, it);

  // ----------------------------------------------------------------------
  loopsource_ = IONotificationPortGetRunLoopSource(notifyport_);
  if (! loopsource_) {
    NSLog(@"[ERROR] IONotificationPortGetRunLoopSource failed");
    return;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), loopsource_, kCFRunLoopDefaultMode);
}

// ------------------------------------------------------------
- (void) observer_NSWorkspaceSessionDidBecomeActiveNotification:(NSNotification*)notification
{
  dispatch_async(dispatch_get_main_queue(), ^{
                   NSLog (@"observer_NSWorkspaceSessionDidBecomeActiveNotification");

                   [statusWindow_ resetStatusMessage];

                   [self registerIONotification];
                   [self registerWakeNotification];
                 });
}

- (void) observer_NSWorkspaceSessionDidResignActiveNotification:(NSNotification*)notification
{
  dispatch_async(dispatch_get_main_queue(), ^{
                   NSLog (@"observer_NSWorkspaceSessionDidResignActiveNotification");

                   [statusWindow_ resetStatusMessage];

                   [self unregisterIONotification];
                   [self unregisterWakeNotification];
                   [clientForKernelspace disconnect_from_kext];
                 });
}

// ------------------------------------------------------------
- (void) applicationDidFinishLaunching:(NSNotification*)aNotification
{
  for (NSString* argument in [[NSProcessInfo processInfo] arguments]) {
    if ([argument isEqualToString:@"--fromLaunchAgents"]) {
      if ([[NSUserDefaults standardUserDefaults] boolForKey:kIsQuitByHand]) {
        [NSApp terminate:nil];
      }
    }
  }
  [PreferencesManager setIsQuitByHand:@NO];

  // ------------------------------------------------------------
  if (! [serverForUserspace_ register]) {
    // Relaunch when register is failed.
    NSLog(@"[ServerForUserspace register] is failed. Restarting process.");
    [NSThread sleepForTimeInterval:2];
    [self relaunch];
  }
  [self setRelaunchedCount:0];

  // Wait until other apps connect to me.
  [NSThread sleepForTimeInterval:1];

  [preferencesManager_ load];

  [self registerIONotification];
  [self registerWakeNotification];

  [powerKeyObserver_ start];
  [statusWindow_ setupStatusWindow];
  [statusbar_ refresh];
  [xmlCompiler_ reload];

  // ------------------------------------------------------------
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceDidActivateApplicationNotification:)
                                                             name:NSWorkspaceDidActivateApplicationNotification
                                                           object:nil];

  // We need to speficy NSNotificationSuspensionBehaviorDeliverImmediately for NSDistributedNotificationCenter
  // because kTISNotify* will be dropped sometimes without this.
  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:)
                                                          name:(NSString*)(kTISNotifyEnabledKeyboardInputSourcesChanged)
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:)
                                                          name:(NSString*)(kTISNotifySelectedKeyboardInputSourceChanged)
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(observer_ConfigXMLReloaded:)
                                               name:kConfigXMLReloadedNotification
                                             object:nil];

  // ------------------------------
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceSessionDidBecomeActiveNotification:)
                                                             name:NSWorkspaceSessionDidBecomeActiveNotification
                                                           object:nil];

  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceSessionDidResignActiveNotification:)
                                                             name:NSWorkspaceSessionDidResignActiveNotification
                                                           object:nil];

  // ------------------------------------------------------------
  [self observer_NSWorkspaceDidActivateApplicationNotification:nil];
  [self distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:nil];
  [self distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:nil];

  [updater_ checkForUpdatesInBackground:nil];
}

- (BOOL) applicationShouldHandleReopen:(NSApplication*)theApplication hasVisibleWindows:(BOOL)flag
{
  [preferencesController_ show];
  return YES;
}

- (void) dealloc
{
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];

  [applicationInformation_ release];
  [inputSourceInformation_ release];

  [super dealloc];
}

// ------------------------------------------------------------
#define kRelaunchedCount @"org.pqrs.KeyRemap4MacBook.RelaunchedCount"

- (void) setRelaunchedCount:(int)newvalue
{
  setenv([kRelaunchedCount UTF8String],
         [[NSString stringWithFormat:@"%d", newvalue] UTF8String],
         1);
}

- (NSInteger) getRelaunchedCount
{
  return [[[[NSProcessInfo processInfo] environment] objectForKey:kRelaunchedCount] integerValue];
}

- (void) relaunch
{
  const int RETRY_COUNT = 5;

  NSInteger count = [self getRelaunchedCount];
  if (count < RETRY_COUNT) {
    NSLog(@"Relaunching (count:%d)", (int)(count));
    [self setRelaunchedCount:(int)(count + 1)];
    [NSTask launchedTaskWithLaunchPath:[[NSBundle mainBundle] executablePath] arguments:[NSArray array]];
  } else {
    NSLog(@"Give up relaunching.");
  }

  [NSApp terminate:self];
}

// ------------------------------------------------------------
- (NSDictionary*) getApplicationInformation
{
  return [[applicationInformation_ retain] autorelease];
}
- (NSDictionary*) getInputSourceInformation
{
  return [[inputSourceInformation_ retain] autorelease];
}

// ------------------------------------------------------------
- (IBAction) launchEventViewer:(id)sender
{
  NSString* path = @"/Applications/KeyRemap4MacBook.app/Contents/Applications/EventViewer.app";
  [[NSWorkspace sharedWorkspace] launchApplication:path];
}

- (IBAction) launchMultiTouchExtension:(id)sender
{
  [[NSWorkspace sharedWorkspace] launchApplication:@"/Applications/KeyRemap4MacBook.app/Contents/Applications/KeyRemap4MacBook_multitouchextension.app"];
}

- (IBAction) launchUninstaller:(id)sender
{
  system("/Applications/KeyRemap4MacBook.app/Contents/Library/extra/launchUninstaller.sh");
}

- (IBAction) openPreferences:(id)sender
{
  [preferencesController_ show];
}

- (IBAction) openPrivateXML:(id)sender
{
  // Open a directory which contains private.xml.
  NSString* path = [XMLCompiler get_private_xml_path];
  if ([path length] > 0) {
    [[NSWorkspace sharedWorkspace] openFile:[path stringByDeletingLastPathComponent]];
  }
}

- (IBAction) quit:(id)sender
{
  NSAlert* alert = [NSAlert alertWithMessageText:@"Quit KeyRemap4MacBook?"
                                   defaultButton:@"Quit"
                                 alternateButton:@"Cancel"
                                     otherButton:nil
                       informativeTextWithFormat:@"Are you sure you want to quit KeyRemap4MacBook?"];
  if ([alert runModal] != NSAlertDefaultReturn) return;

  [PreferencesManager setIsQuitByHand:@YES];
  [NSApp terminate:nil];
}

@end
