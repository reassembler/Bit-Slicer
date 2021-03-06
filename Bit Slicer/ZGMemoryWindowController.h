/*
 * Created by Mayur Pawashe on 3/8/13.
 *
 * Copyright (c) 2013 zgcoder
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// This is the superclass of ZGDebugController and ZGMemoryViewerController, which contains a lot of functionality that both classes use

#import <Cocoa/Cocoa.h>
#import "ZGMemoryTypes.h"

@class ZGProcess;
@class ZGProcessList;

enum ZGNavigation
{
	ZGNavigationBack,
	ZGNavigationForward
};

@interface ZGMemoryWindowController : NSWindowController
{
	ZGProcess *_currentProcess;
}

@property (assign) IBOutlet NSPopUpButton *runningApplicationsPopUpButton;
@property (assign) IBOutlet NSSegmentedControl *navigationSegmentedControl;
@property (assign) IBOutlet NSTextField *addressTextField;

@property (nonatomic, strong) NSUndoManager *undoManager;
@property (nonatomic, strong) NSUndoManager *navigationManager;

@property (readwrite) ZGMemoryAddress currentMemoryAddress;
@property (readwrite) ZGMemorySize currentMemorySize;

@property (readonly) ZGProcess *currentProcess;
@property (nonatomic, copy) NSString *desiredProcessName;

@property (readwrite, nonatomic) BOOL windowDidAppear;

@property (readwrite, strong) NSTimer *updateDisplayTimer;

- (IBAction)pauseOrUnpauseProcess:(id)sender;

- (void)windowDidAppearForFirstTime:(id)sender;
- (void)windowDidShow:(id)sender;

- (void)markChanges;
- (void)setWindowAttributesWithIdentifier:(NSString *)windowIdentifier;

- (void)setupProcessListNotificationsAndPopUpButton;

- (void)processListChanged:(NSDictionary *)change;
- (void)updateRunningProcesses;
- (void)runningApplicationsPopUpButtonWillPopUp:(NSNotification *)notification;

- (void)switchProcess;

- (IBAction)goBack:(id)sender;
- (IBAction)goForward:(id)sender;
- (IBAction)navigate:(id)sender;

- (BOOL)canEnableNavigationButtons;
- (void)updateNavigationButtons;

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)userInterfaceItem;

@end
