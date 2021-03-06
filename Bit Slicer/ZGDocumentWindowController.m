/*
 * Created by Mayur Pawashe on 8/9/13.
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

#import "ZGDocumentWindowController.h"
#import "ZGDocumentTableController.h"
#import "ZGDocumentSearchController.h"
#import "ZGDocumentBreakPointController.h"
#import "ZGVariableController.h"
#import "ZGScriptManager.h"
#import "ZGProcessList.h"
#import "ZGProcess.h"
#import "ZGVariableTypes.h"
#import "ZGAppController.h"
#import "ZGRunningProcess.h"
#import "ZGPreferencesController.h"
#import "ZGDocumentData.h"
#import "ZGSearchData.h"
#import "ZGSearchProgress.h"
#import "ZGSearchFunctions.h"
#import "ZGSearchResults.h"
#import "ZGAppController.h"
#import "ZGDebuggerController.h"
#import "ZGMemoryViewerController.h"
#import "ZGDocument.h"
#import "ZGVirtualMemory.h"
#import "ZGVirtualMemoryHelpers.h"

@interface ZGDocumentWindowController ()

@property (assign) IBOutlet NSTextField *generalStatusTextField;

@property (assign) IBOutlet NSLayoutConstraint *variablesTableViewToBottomConstraint;

@end

@implementation ZGDocumentWindowController

- (id)init
{
	self = [super initWithWindowNibName:@"MyDocument"];
	if (self != nil)
	{
		[[ZGProcessList sharedProcessList]
		 addObserver:self
		 forKeyPath:@"runningProcesses"
		 options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
		 context:NULL];
	}
	return self;
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self];
	
	[[ZGProcessList sharedProcessList]
	 removeObserver:self
	 forKeyPath:@"runningProcesses"];
	
	[self.searchController cleanUp];
	[self.tableController cleanUp];
	[self.scriptManager cleanup];
}

- (void)changeBottomBorderByDeletion:(BOOL)shouldRemoveBorder
{
	static CGFloat borderLength;
	if (borderLength == 0)
	{
		borderLength = [self.window contentBorderThicknessForEdge:NSMinYEdge];
	}
	
	[self.window setContentBorderThickness:shouldRemoveBorder ? 0 : borderLength forEdge:NSMinYEdge];
	[self.generalStatusTextField setHidden:shouldRemoveBorder];
	
	CGFloat distanceAffected = 11;
	CGFloat directionAffected = shouldRemoveBorder ? -1 : 1;
	
	for (NSControl *control in @[self.searchButton, self.clearButton, self.deterministicProgressIndicator, self.indeterministicProgressIndicator])
	{
		for (NSLayoutConstraint *constraint in [control constraintsAffectingLayoutForOrientation:NSLayoutConstraintOrientationVertical])
		{
			if (constraint.firstItem == self.window.contentView)
			{
				constraint.constant += distanceAffected * directionAffected;
				break;
			}
		}
	}
	self.variablesTableViewToBottomConstraint.constant += distanceAffected * directionAffected;
}

- (void)windowDidLoad
{
	[super windowDidLoad];
	
	self.documentData = [(ZGDocument *)self.document data];
	self.searchData = [self.document searchData];
	
	self.tableController = [[ZGDocumentTableController alloc] initWithWindowController:self];
	self.variableController = [[ZGVariableController alloc] initWithWindowController:self];
	self.searchController = [[ZGDocumentSearchController alloc] initWithWindowController:self];
	self.documentBreakPointController = [[ZGDocumentBreakPointController alloc] initWithWindowController:self];
	self.scriptManager = [[ZGScriptManager alloc] initWithWindowController:self];
	
	self.tableController.variablesTableView = self.variablesTableView;
	
	[self.generalStatusTextField.cell setBackgroundStyle:NSBackgroundStyleRaised];
	[self.window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
	
	if ([self.window respondsToSelector:@selector(occlusionState)])
	{
		[[NSNotificationCenter defaultCenter]
		 addObserver:self
		 selector:@selector(windowDidChangeOcclusionState:)
		 name:NSWindowDidChangeOcclusionStateNotification
		 object:self.window];
	}
	
	[[NSNotificationCenter defaultCenter]
	 addObserver:self
	 selector:@selector(runningApplicationsPopUpButtonWillPopUp:)
	 name:NSPopUpButtonWillPopUpNotification
	 object:self.runningApplicationsPopUpButton];
	
	[self loadDocumentUserInterface];
}

- (void)updateObservingProcessOcclusionState
{
	if ([self.window respondsToSelector:@selector(occlusionState)])
	{
		BOOL shouldKeepWatchVariablesTimer = [self.tableController updateWatchVariablesTimer];
		if (self.isOccluded && !shouldKeepWatchVariablesTimer && !self.searchController.canCancelTask)
		{
			BOOL foundRunningScript = NO;
			for (ZGVariable *variable in self.documentData.variables)
			{
				if (variable.enabled && variable.type == ZGScript)
				{
					foundRunningScript = YES;
					break;
				}
			}
			
			if (!foundRunningScript)
			{
				if (self.currentProcess.valid)
				{
					[[ZGProcessList sharedProcessList] removePriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
				}
				
				[[ZGProcessList sharedProcessList] unrequestPollingWithObserver:self];
			}
		}
		else if (!self.isOccluded)
		{
			if (self.currentProcess.valid)
			{
				[[ZGProcessList sharedProcessList] addPriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
			}
			else
			{
				[[ZGProcessList sharedProcessList] requestPollingWithObserver:self];
			}
		}
	}
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification
{
	self.isOccluded = (self.window.occlusionState & NSWindowOcclusionStateVisible) == 0;
	if (!self.isOccluded)
	{
		[[ZGProcessList sharedProcessList] retrieveList];
		[self.tableController.variablesTableView reloadData];
	}
	[self updateObservingProcessOcclusionState];
}

- (void)windowWillClose:(NSNotification *)notification
{
	if ([notification object] == self.window)
	{
		if (self.currentProcess.valid)
		{
			[[ZGProcessList sharedProcessList] removePriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
		}
		
		[[ZGProcessList sharedProcessList] unrequestPollingWithObserver:self];
	}
}

- (void)setStatus:(id)status
{
	if (status == nil)
	{
		NSUInteger variableCount = self.documentData.variables.count + self.searchController.searchResults.addressCount;
		
		NSNumberFormatter *numberOfVariablesFormatter = [[NSNumberFormatter alloc] init];
		numberOfVariablesFormatter.format = @"#,###";
		
		NSString *valuesDisplayedString;
		if (variableCount <= self.documentData.variables.count)
		{
			valuesDisplayedString = [NSString stringWithFormat:@"Displaying %@ value", [numberOfVariablesFormatter stringFromNumber:@(variableCount)]];
		}
		else
		{
			valuesDisplayedString = [NSString stringWithFormat:@"Displaying %@ of %@ value", [numberOfVariablesFormatter stringFromNumber:@(self.documentData.variables.count)], [numberOfVariablesFormatter stringFromNumber:@(variableCount)]];
		}
		
		if (variableCount != 1)
		{
			valuesDisplayedString = [valuesDisplayedString stringByAppendingString:@"s"];
		}
		
		[self.generalStatusTextField setStringValue:valuesDisplayedString];
	}
	else if ([status isKindOfClass:[NSString class]])
	{
		[self.generalStatusTextField setStringValue:status];
	}
	else if ([status isKindOfClass:[NSAttributedString class]])
	{
		[self.generalStatusTextField setAttributedStringValue:status];
	}
}

- (void)loadDocumentUserInterface
{
	// don't use the last selected process name if the corresponding process isn't alive
	NSString *lastSelectedProcessName = [[ZGAppController sharedController] lastSelectedProcessName];
	if (!self.documentData.desiredProcessName && lastSelectedProcessName)
	{
		BOOL foundApplication =
		([NSWorkspace.sharedWorkspace.runningApplications
		  indexOfObjectPassingTest:^BOOL (id object, NSUInteger index, BOOL *stop)
		  {
			  return [[object localizedName] isEqualToString:lastSelectedProcessName];
		  }] != NSNotFound);
		
		if (foundApplication)
		{
			self.documentData.desiredProcessName = lastSelectedProcessName;
		}
	}
    
	[self setStatus:nil];
	
	[self addProcessesToPopupButton];
	
	[self.variableController disableHarmfulVariables:self.documentData.variables];
	[self updateVariables:self.documentData.variables searchResults:nil];
	
	[self.variableQualifierMatrix selectCellWithTag:self.documentData.qualifierTag];
	
	self.scanUnwritableValuesCheckBox.state = self.searchData.shouldScanUnwritableValues;
	self.ignoreDataAlignmentCheckBox.state = self.documentData.ignoreDataAlignment;
	self.includeNullTerminatorCheckBox.state = self.searchData.shouldIncludeNullTerminator;
	self.ignoreCaseCheckBox.state = self.searchData.shouldIgnoreStringCase;
	self.beginningAddressTextField.stringValue = self.documentData.beginningAddressStringValue;
	self.endingAddressTextField.stringValue = self.documentData.endingAddressStringValue;
	self.searchValueTextField.stringValue = self.documentData.searchValueString;
	
	[self.dataTypesPopUpButton selectItemWithTag:self.documentData.selectedDatatypeTag];
	[self selectDataTypeWithTag:(ZGVariableType)self.documentData.selectedDatatypeTag recordUndo:NO];
	
	[self.functionPopUpButton selectItemWithTag:self.documentData.functionTypeTag];
	[self functionTypePopUpButtonRequest:nil markChanges:NO];
}

#pragma mark Selected Variables

- (NSIndexSet *)selectedVariableIndexes
{
	NSIndexSet *tableIndexSet = self.tableController.variablesTableView.selectedRowIndexes;
	NSInteger clickedRow = self.tableController.variablesTableView.clickedRow;
	
	return (clickedRow != -1 && ![tableIndexSet containsIndex:clickedRow]) ? [NSIndexSet indexSetWithIndex:clickedRow] : tableIndexSet;
}

- (NSArray *)selectedVariables
{
	return [self.documentData.variables objectsAtIndexes:[self selectedVariableIndexes]];
}

#pragma mark Undo Manager

- (NSUndoManager *)windowWillReturnUndoManager:(id)sender
{
	return [self.document undoManager];
}

- (id)undoManager
{
	return [self.document undoManager];
}

- (void)markDocumentChange
{
	[self.document updateChangeCount:NSChangeDone];
}

#pragma mark Watching other applications

- (void)runningApplicationsPopUpButtonWillPopUp:(NSNotification *)notification
{
	[[ZGProcessList sharedProcessList] retrieveList];
}

- (IBAction)runningApplicationsPopUpButtonRequest:(id)sender
{
	BOOL pointerSizeChanged = YES;
	
	if (self.runningApplicationsPopUpButton.selectedItem.representedObject != self.currentProcess)
	{
		if (self.runningApplicationsPopUpButton.selectedItem.representedObject && self.currentProcess && [self.runningApplicationsPopUpButton.selectedItem.representedObject is64Bit] != self.currentProcess.is64Bit)
		{
			pointerSizeChanged = YES;
		}
		
		for (ZGVariable *variable in self.documentData.variables)
		{
			if (variable.enabled)
			{
				if (variable.type == ZGScript)
				{
					[self.scriptManager stopScriptForVariable:variable];
				}
				else if (variable.isFrozen)
				{
					variable.enabled = NO;
				}
			}
			
			variable.finishedEvaluatingDynamicAddress = NO;
		}
		
		// this is about as far as we go when it comes to undo/redos...
		[self.undoManager removeAllActions];
		
		[self.tableController clearCache];
	}
	
	if (self.currentProcess)
	{
		[[ZGProcessList sharedProcessList] removePriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
	}
	
	self.currentProcess = self.runningApplicationsPopUpButton.selectedItem.representedObject;
	
	if (pointerSizeChanged)
	{
		// Update the pointer variable sizes
		for (ZGVariable *variable in self.documentData.variables)
		{
			if (variable.type == ZGPointer)
			{
				variable.pointerSize = self.currentProcess.pointerSize;
			}
		}
		
		[self.tableController.variablesTableView reloadData];
	}
	
	// keep track of the process the user targeted
	[[ZGAppController sharedController] setLastSelectedProcessName:self.currentProcess.name];
	
	if (sender && ![self.documentData.desiredProcessName isEqualToString:self.currentProcess.name])
	{
		self.documentData.desiredProcessName = self.currentProcess.name;
		[self markDocumentChange];
	}
	else if (!self.documentData.desiredProcessName)
	{
		self.documentData.desiredProcessName = self.currentProcess.name;
	}
	
	if (self.currentProcess && self.currentProcess.valid)
	{
		[[ZGProcessList sharedProcessList] addPriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
		
		if (!self.currentProcess.hasGrantedAccess && ![self.currentProcess grantUsAccess])
		{
			NSAttributedString *errorMessage =
			[[NSAttributedString alloc]
			 initWithString:[NSString stringWithFormat:@"Failed accessing %@", self.currentProcess.name]
			 attributes:@{NSForegroundColorAttributeName : NSColor.redColor}];
			
			[self setStatus:errorMessage];
		}
		else
		{
			[self setStatus:nil];
		}
	}
	
	[self.tableController updateWatchVariablesTimer];
	
	// Trash all other menu items if they're dead
	NSMutableArray *itemsToRemove = [[NSMutableArray alloc] init];
	for (NSMenuItem *menuItem in self.runningApplicationsPopUpButton.itemArray)
	{
		ZGRunningProcess *runningProcess = [[ZGRunningProcess alloc] init];
		runningProcess.processIdentifier = [[menuItem representedObject] processID];
		if (menuItem != self.runningApplicationsPopUpButton.selectedItem &&
			(![menuItem.representedObject valid] ||
			 ![[[ZGProcessList sharedProcessList] runningProcesses] containsObject:runningProcess]))
		{
			[itemsToRemove addObject:menuItem];
		}
	}
	
	for (id item in itemsToRemove)
	{
		[self.runningApplicationsPopUpButton removeItemAtIndex:[self.runningApplicationsPopUpButton indexOfItem:item]];
	}
	
	// If we're switching to a process, search button should be enabled if it's alive and if we have access to it
	self.searchButton.enabled = (self.currentProcess.valid && self.currentProcess.hasGrantedAccess);
}

- (void)addProcessesToPopupButton
{
	// Add running applications to popup button ; we want activiation policy for NSApplicationActivationPolicyRegular to appear first, since they're more likely to be targetted and more likely to have sufficient privillages for accessing virtual memory
	NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"activationPolicy" ascending:YES];
	for (ZGRunningProcess *runningProcess in [[[ZGProcessList sharedProcessList] runningProcesses] sortedArrayUsingDescriptors:@[sortDescriptor]])
	{
		[self addRunningProcessToPopupButton:runningProcess];
	}
	
	if (self.documentData.desiredProcessName && ![self.currentProcess.name isEqualToString:self.documentData.desiredProcessName])
	{
		ZGProcess *deadProcess =
		[[ZGProcess alloc]
		 initWithName:self.documentData.desiredProcessName
		 set64Bit:YES];
		
		NSMenuItem *menuItem = [[NSMenuItem alloc] init];
		menuItem.title = [NSString stringWithFormat:@"%@ (none)", deadProcess.name];
		menuItem.representedObject = deadProcess;
		
		[self.runningApplicationsPopUpButton.menu addItem:menuItem];
		
		[self.runningApplicationsPopUpButton selectItem:menuItem];
		
		[self runningApplicationsPopUpButtonRequest:nil];
		[self removeRunningProcessFromPopupButton:nil];
	}
	else
	{
		[self runningApplicationsPopUpButtonRequest:nil];
	}
}

- (void)removeRunningProcessFromPopupButton:(ZGRunningProcess *)oldRunningProcess
{
	// Just to be sure
	if (oldRunningProcess.processIdentifier != NSRunningApplication.currentApplication.processIdentifier)
	{
		// oldRunningProcess == nil, means remove 'current process'
		if (self.currentProcess.processID == oldRunningProcess.processIdentifier || !oldRunningProcess)
		{
			// Don't remove the item, just indicate it's terminated
			NSAttributedString *status =
			[[NSAttributedString alloc]
			 initWithString:[NSString stringWithFormat:@"%@ is not running", self.currentProcess.name]
			 attributes:@{NSForegroundColorAttributeName : NSColor.redColor}];
			
			[self setStatus:status];
			
			self.searchButton.enabled = NO;
			
			if (self.searchController.canCancelTask && !self.searchController.searchProgress.shouldCancelSearch)
			{
				[self.searchController cancelTask];
			}
			
			[[ZGProcessList sharedProcessList] removePriorityToProcessIdentifier:self.currentProcess.processID withObserver:self];
			
			[self.tableController clearCache];
			for (ZGVariable *variable in self.documentData.variables)
			{
				variable.finishedEvaluatingDynamicAddress = NO;
				variable.value = NULL;
			}
			
			[self.currentProcess markInvalid];
			[self.tableController updateWatchVariablesTimer];
			[self.variablesTableView reloadData];
			
			[[NSNotificationCenter defaultCenter]
			 postNotificationName:ZGTargetProcessDiedNotification
			 object:self.currentProcess];
			
			self.runningApplicationsPopUpButton.selectedItem.title = [NSString stringWithFormat:@"%@ (none)", self.currentProcess.name];
			
			// Set the icon to the standard one
			NSImage *regularAppIcon = [[NSImage imageNamed:@"NSDefaultApplicationIcon"] copy];
			if (regularAppIcon)
			{
				regularAppIcon.size = NSMakeSize(16, 16);
				self.runningApplicationsPopUpButton.selectedItem.image = regularAppIcon;
			}
			
			[[ZGProcessList sharedProcessList] requestPollingWithObserver:self];
		}
		else if (oldRunningProcess.processIdentifier != -1)
		{
			// Find the menu item, and remove it
			NSMenuItem *itemToRemove = nil;
			for (NSMenuItem *item in self.runningApplicationsPopUpButton.itemArray)
			{
				if ([item.representedObject processID] == oldRunningProcess.processIdentifier)
				{
					itemToRemove = item;
					break;
				}
			}
			
			if (itemToRemove)
			{
				[self.runningApplicationsPopUpButton removeItemAtIndex:[self.runningApplicationsPopUpButton indexOfItem:itemToRemove]];
			}
		}
	}
}

- (void)addRunningProcessToPopupButton:(ZGRunningProcess *)newRunningProcess
{
	// Don't add ourselves
	if (newRunningProcess.processIdentifier != NSRunningApplication.currentApplication.processIdentifier)
	{
		// Check if a dead application can be 'revived'
		for (NSMenuItem *menuItem in self.runningApplicationsPopUpButton.itemArray)
		{
			ZGProcess *process = menuItem.representedObject;
			if (process == self.currentProcess &&
				!self.currentProcess.valid &&
				[self.currentProcess.name isEqualToString:newRunningProcess.name])
			{
				self.currentProcess.processID = newRunningProcess.processIdentifier;
				
				self.currentProcess.is64Bit = newRunningProcess.is64Bit;
				menuItem.title = [NSString stringWithFormat:@"%@ (%d)", self.currentProcess.name, self.currentProcess.processID];
				
				NSImage *iconImage = [[newRunningProcess icon] copy];
				iconImage.size = NSMakeSize(16, 16);
				menuItem.image = iconImage;
				
				[self runningApplicationsPopUpButtonRequest:nil];
				self.searchButton.enabled = YES;
				
				[[ZGProcessList sharedProcessList] unrequestPollingWithObserver:self];
				
				return;
			}
		}
		
		// Otherwise add the new application
		NSMenuItem *menuItem = [[NSMenuItem alloc] init];
		menuItem.title = [NSString stringWithFormat:@"%@ (%d)", newRunningProcess.name, newRunningProcess.processIdentifier];
		
		NSImage *iconImage = [[newRunningProcess icon] copy];
		iconImage.size = NSMakeSize(16, 16);
		menuItem.image = iconImage;
		
		ZGProcess *representedProcess =
		[[ZGProcess alloc]
		 initWithName:newRunningProcess.name
		 processID:newRunningProcess.processIdentifier
		 set64Bit:newRunningProcess.is64Bit];
		
		menuItem.representedObject = representedProcess;
		
		[self.runningApplicationsPopUpButton.menu addItem:menuItem];
		
		// If we found desired process name, select it
		if (![self.currentProcess.name isEqualToString:self.documentData.desiredProcessName] &&
			[self.documentData.desiredProcessName isEqualToString:newRunningProcess.name])
		{
			[self.runningApplicationsPopUpButton selectItem:menuItem];
			[self runningApplicationsPopUpButtonRequest:nil];
		}
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (self.document != nil && object == [ZGProcessList sharedProcessList] && self.runningApplicationsPopUpButton.itemArray.count > 0)
	{
		NSArray *newRunningProcesses = [change objectForKey:NSKeyValueChangeNewKey];
		NSArray *oldRunningProcesses = [change objectForKey:NSKeyValueChangeOldKey];
		
		if (newRunningProcesses)
		{
			for (ZGRunningProcess *runningProcess in newRunningProcesses)
			{
				[self addRunningProcessToPopupButton:runningProcess];
			}
		}
		
		if (oldRunningProcesses)
		{
			for (ZGRunningProcess *runningProcess in oldRunningProcesses)
			{
				[self removeRunningProcessFromPopupButton:runningProcess];
			}
		}
	}
}

- (void)updateClearButton
{
	self.clearButton.enabled = (self.documentData.variables.count > 0 && [self.searchController canStartTask]);
}

- (IBAction)qualifierMatrixButtonRequest:(id)sender
{
	ZGVariableQualifier oldQualifier = (ZGVariableQualifier)self.documentData.qualifierTag;
	ZGVariableQualifier newQualifier = (ZGVariableQualifier)[self.variableQualifierMatrix.selectedCell tag];
	
	if (oldQualifier != newQualifier)
	{
		for (ZGVariable *variable in self.documentData.variables)
		{
			switch (variable.type)
			{
				case ZGInt8:
				case ZGInt16:
				case ZGInt32:
				case ZGInt64:
					variable.qualifier = newQualifier;
					[variable updateStringValue];
					break;
				default:
					break;
			}
		}
		
		[self.tableController.variablesTableView reloadData];
		[self markDocumentChange];
		
		self.documentData.qualifierTag = newQualifier;
	}
}

- (void)updateFlagsRangeTextField
{
	ZGFunctionType functionType = (ZGFunctionType)self.functionPopUpButton.selectedItem.tag;
	
	if (functionType == ZGGreaterThan || functionType == ZGGreaterThanStored)
	{
		self.flagsLabel.stringValue = @"Below:";
		
		if (self.documentData.lastBelowRangeValue)
		{
			self.flagsTextField.stringValue = self.documentData.lastBelowRangeValue;
		}
		else
		{
			self.flagsTextField.stringValue = @"";
		}
	}
	else if (functionType == ZGLessThan || functionType == ZGLessThanStored)
	{
		self.flagsLabel.stringValue = @"Above:";
		
		if (self.documentData.lastAboveRangeValue)
		{
			self.flagsTextField.stringValue = self.documentData.lastAboveRangeValue;
		}
		else
		{
			self.flagsTextField.stringValue = @"";
		}
	}
}

- (void)updateFlagsAndSearchButtonTitle
{
	ZGVariableType dataType = (ZGVariableType)self.dataTypesPopUpButton.selectedItem.tag;
	ZGFunctionType functionType = (ZGFunctionType)self.functionPopUpButton.selectedItem.tag;
	
	if (dataType == ZGString8 || dataType == ZGString16 || functionType == ZGStoreAllValues)
	{
		self.flagsTextField.enabled = NO;
		self.flagsTextField.stringValue = @"";
		self.flagsLabel.stringValue = @"";
		self.flagsLabel.textColor = NSColor.disabledControlTextColor;
	}
	else if (dataType == ZGFloat || dataType == ZGDouble)
	{
		self.flagsTextField.enabled = YES;
		self.flagsLabel.textColor = NSColor.controlTextColor;
		
		if (functionType == ZGEquals || functionType == ZGNotEquals || functionType == ZGEqualsStored || functionType == ZGNotEqualsStored || functionType == ZGEqualsStoredPlus || functionType == ZGNotEqualsStoredPlus)
		{
			// epsilon
			self.flagsLabel.stringValue = @"Epsilon:";
			if (self.documentData.lastEpsilonValue)
			{
				self.flagsTextField.stringValue = self.documentData.lastEpsilonValue;
			}
			else
			{
				self.flagsTextField.stringValue = @"";
			}
		}
		else
		{
			// range
			[self updateFlagsRangeTextField];
		}
	}
	else /* if data type is an integer type */
	{
		if (functionType == ZGEquals || functionType == ZGNotEquals || functionType == ZGEqualsStored || functionType == ZGNotEqualsStored || functionType == ZGEqualsStoredPlus || functionType == ZGNotEqualsStoredPlus)
		{
			self.flagsTextField.enabled = NO;
			self.flagsTextField.stringValue = @"";
			self.flagsLabel.stringValue = @"";
			self.flagsLabel.textColor = NSColor.disabledControlTextColor;
		}
		else
		{
			// range
			[self updateFlagsRangeTextField];
			
			self.flagsTextField.enabled = YES;
			self.flagsLabel.textColor = NSColor.controlTextColor;
		}
	}
	
	if (functionType == ZGStoreAllValues)
	{
		self.searchButton.title = @"Store";
	}
	else
	{
		self.searchButton.title = @"Search";
	}
}

- (void)selectDataTypeWithTag:(ZGVariableType)newTag recordUndo:(BOOL)recordUndo
{
	ZGVariableType oldVariableType = (ZGVariableType)self.documentData.selectedDatatypeTag;
	
	self.documentData.selectedDatatypeTag = newTag;
	[self.dataTypesPopUpButton selectItemWithTag:newTag];
	
	self.functionPopUpButton.enabled = YES;
	self.variableQualifierMatrix.enabled = YES;
	
	if (newTag == ZGString8 || newTag == ZGString16)
	{
		self.ignoreCaseCheckBox.enabled = YES;
		self.includeNullTerminatorCheckBox.enabled = YES;
	}
	else
	{
		self.ignoreCaseCheckBox.enabled = NO;
		self.ignoreCaseCheckBox.state = NSOffState;
		
		self.includeNullTerminatorCheckBox.enabled = NO;
		self.includeNullTerminatorCheckBox.state = NSOffState;
	}
	
	if (newTag == ZGString8 || newTag == ZGInt8 || newTag == ZGByteArray)
	{
		self.ignoreDataAlignmentCheckBox.enabled = NO;
		self.ignoreDataAlignmentCheckBox.state = NSOffState;
	}
	else
	{
		self.ignoreDataAlignmentCheckBox.enabled = YES;
		self.ignoreDataAlignmentCheckBox.state = self.documentData.ignoreDataAlignment;
	}
	
	[self updateFlagsAndSearchButtonTitle];
	
	if (recordUndo && oldVariableType != newTag)
	{
		[self.undoManager setActionName:@"Data Type Change"];
		[[self.undoManager prepareWithInvocationTarget:self]
		 selectDataTypeWithTag:oldVariableType
		 recordUndo:YES];
	}
}

- (IBAction)dataTypePopUpButtonRequest:(id)sender
{
	[self selectDataTypeWithTag:(ZGVariableType)[[sender selectedItem] tag] recordUndo:YES];
}

- (BOOL)functionTypeAllowsSearchInput
{
	BOOL allows;
	switch (self.documentData.functionTypeTag)
	{
		case ZGEquals:
		case ZGNotEquals:
		case ZGGreaterThan:
		case ZGLessThan:
		case ZGEqualsStoredPlus:
		case ZGNotEqualsStoredPlus:
			allows = YES;
			break;
		default:
			allows = NO;
			break;
	}
	
	return allows;
}

- (BOOL)isFunctionTypeStore:(NSInteger)functionTypeTag
{
	BOOL isFunctionTypeStore;
	
	switch (functionTypeTag)
	{
		case ZGEqualsStored:
		case ZGNotEqualsStored:
		case ZGGreaterThanStored:
		case ZGLessThanStored:
		case ZGEqualsStoredPlus:
		case ZGNotEqualsStoredPlus:
			isFunctionTypeStore = YES;
			break;
		default:
			isFunctionTypeStore = NO;
	}
	
	return isFunctionTypeStore;
}

- (BOOL)isFunctionTypeStore
{
	return [self isFunctionTypeStore:self.documentData.functionTypeTag];
}

- (void)functionTypePopUpButtonRequest:(id)sender markChanges:(BOOL)shouldMarkChanges
{
	[self updateFlagsAndSearchButtonTitle];
	
	if (![self functionTypeAllowsSearchInput])
	{
		self.searchValueTextField.enabled = NO;
		self.searchValueLabel.textColor = NSColor.disabledControlTextColor;
	}
	else
	{
		self.searchValueTextField.enabled = YES;
		self.searchValueLabel.textColor = NSColor.controlTextColor;
		[self.window makeFirstResponder:self.searchValueTextField];
	}
	
	self.searchData.shouldCompareStoredValues = self.isFunctionTypeStore;
	
	if (shouldMarkChanges)
	{
		[self markDocumentChange];
	}
}

- (IBAction)functionTypePopUpButtonRequest:(id)sender
{
	self.documentData.functionTypeTag = [sender selectedTag];
	[self functionTypePopUpButtonRequest:sender markChanges:YES];
}

#pragma mark Useful Methods

- (void)updateVariables:(NSArray *)newWatchVariablesArray searchResults:(ZGSearchResults *)searchResults
{
	if (self.undoManager.isUndoing || self.undoManager.isRedoing)
	{
		[[self.undoManager prepareWithInvocationTarget:self] updateVariables:self.documentData.variables searchResults:self.searchController.searchResults];
	}
	
	self.documentData.variables = newWatchVariablesArray;
	self.searchController.searchResults = searchResults;
	
	[self.tableController updateWatchVariablesTimer];
	[self.tableController.variablesTableView reloadData];
	
	[self setStatus:nil];
	
	// Make sure the search value field is enabled if we aren't doing a store comparison
	if ([self functionTypeAllowsSearchInput])
	{
		self.searchValueTextField.enabled = YES;
		self.searchValueLabel.textColor = [NSColor controlTextColor];
	}
	
	[self updateClearButton];
}

#pragma mark Menu item validation

- (BOOL)validateUserInterfaceItem:(NSMenuItem *)menuItem
{
	if (menuItem.action == @selector(clearSearchValues:))
	{
		if (!self.clearButton.isEnabled)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(storeAllValues:))
	{
		if (!self.currentProcess.valid || ![self.searchController canStartTask])
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(removeSelectedSearchValues:))
	{
		if (self.selectedVariables.count == 0 || self.window.firstResponder != self.tableController.variablesTableView)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(freezeVariables:))
	{
		if (self.selectedVariables.count > 0)
		{
			// All the variables selected need to either be all unfrozen or all frozen
			BOOL isFrozen = [[self.selectedVariables objectAtIndex:0] isFrozen];
			BOOL isInconsistent = NO;
			
			for (ZGVariable *variable in [self.selectedVariables subarrayWithRange:NSMakeRange(1, self.selectedVariables.count-1)])
			{
				if (variable.isFrozen != isFrozen || !variable.value)
				{
					isInconsistent = YES;
					break;
				}
			}
			
			menuItem.title = [NSString stringWithFormat:@"%@ Variable%@", isFrozen ? @"Unfreeze" : @"Freeze", self.selectedVariables.count != 1 ? @"s" : @""];
			
			if (isInconsistent || !self.clearButton.isEnabled)
			{
				return NO;
			}
		}
		else
		{
			menuItem.title = @"Freeze Variables";
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(addVariable:))
	{
		if (![self.searchController canStartTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(undo:))
	{
		if ([self.searchController canCancelTask])
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(copy:))
	{
		if (self.selectedVariables.count == 0)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(copyAddress:))
	{
		if (self.selectedVariables.count != 1)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(paste:))
	{
		if ([self.searchController canCancelTask] || ![NSPasteboard.generalPasteboard dataForType:ZGVariablePboardType])
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(pauseOrUnpauseProcess:))
	{
		if (!self.currentProcess || !self.currentProcess.valid)
		{
			return NO;
		}
		
		integer_t suspendCount;
		if (!ZGSuspendCount(self.currentProcess.processTask, &suspendCount))
		{
			return NO;
		}
		else
		{
			menuItem.title = [NSString stringWithFormat:@"%@ Target", suspendCount > 0 ? @"Unpause" : @"Pause"];
		}
		
		if ([[[ZGAppController sharedController] debuggerController] isProcessIdentifierHalted:self.currentProcess.processID])
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(editVariablesValue:))
	{
		menuItem.title = [NSString stringWithFormat:@"Edit Variable Value%@…", self.selectedVariables.count != 1 ? @"s" : @""];
		
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || self.selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(editVariablesAddress:))
	{
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || self.selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
	}
    
    else if (menuItem.action == @selector(editVariablesSize:))
    {
		NSArray *selectedVariables = [self selectedVariables];
		menuItem.title = [NSString stringWithFormat:@"Edit Variable Size%@…", selectedVariables.count != 1 ? @"s" : @""];
		
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
		
		// All selected variables must be Byte Array's
		for (ZGVariable *variable in selectedVariables)
		{
			if (variable.type != ZGByteArray)
			{
				return NO;
			}
		}
	}
	
	else if (menuItem.action == @selector(relativizeVariablesAddress:))
	{
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || self.selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
		
		NSArray *selectedVariables = [self selectedVariables];
		menuItem.title = [NSString stringWithFormat:@"Relativize Variable%@", selectedVariables.count != 1 ? @"s" : @""];
		
		for (ZGVariable *variable in selectedVariables)
		{
			ZGMemoryAddress relativeOffset = 0;
			ZGMemoryAddress slide = 0;
			if (variable.usesDynamicAddress || ZGSectionName(self.currentProcess.processTask, self.currentProcess.pointerSize, self.currentProcess.dylinkerBinary, variable.address, variable.size, NULL, &relativeOffset, &slide) == nil || (slide == 0 && variable.address - relativeOffset == self.currentProcess.baseAddress))
			{
				return NO;
			}
		}
	}
	
	else if (menuItem.action == @selector(functionTypePopUpButtonRequest:))
	{
		if ([self isFunctionTypeStore:menuItem.tag] && !self.searchController.searchData.savedData)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(watchVariable:))
	{
		if ([self.searchController canCancelTask] || !self.currentProcess.valid || self.selectedVariables.count != 1)
		{
			return NO;
		}
		
		ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
		
		ZGMemoryAddress memoryAddress = selectedVariable.address;
		ZGMemorySize memorySize = selectedVariable.size;
		ZGMemoryProtection memoryProtection;
		
		if (!ZGMemoryProtectionInRegion(self.currentProcess.processTask, &memoryAddress, &memorySize, &memoryProtection))
		{
			return NO;
		}
		
		if (memoryAddress + memorySize < selectedVariable.address || memoryAddress > selectedVariable.address + selectedVariable.size)
		{
			return NO;
		}
	}
	
	else if (menuItem.action == @selector(nopVariables:))
	{
		menuItem.title = [NSString stringWithFormat:@"NOP Variable%@", self.selectedVariables.count != 1 ? @"s" : @""];
		
		if (([self.searchController canCancelTask] && self.searchController.searchProgress.progressType != ZGSearchProgressMemoryWatching) || self.selectedVariables.count == 0 || !self.currentProcess.valid)
		{
			return NO;
		}
		
		BOOL isValid = YES;
		for (ZGVariable *variable in self.selectedVariables)
		{
			if (variable.type != ZGByteArray || !variable.value)
			{
				isValid = NO;
				break;
			}
		}
		
		return isValid;
	}
	
	else if (menuItem.action == @selector(showMemoryViewer:) || menuItem.action == @selector(showDebugger:))
	{
		if (self.selectedVariables.count != 1 || !self.currentProcess.valid)
		{
			return NO;
		}
		
		ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
		
		ZGMemoryAddress memoryAddress = selectedVariable.address;
		ZGMemorySize memorySize = selectedVariable.size;
		ZGMemoryProtection memoryProtection;
		
		if (!ZGMemoryProtectionInRegion(self.currentProcess.processTask, &memoryAddress, &memorySize, &memoryProtection))
		{
			return NO;
		}
		
		if (memoryAddress > selectedVariable.address || memoryAddress + memorySize < selectedVariable.address + selectedVariable.size)
		{
			return NO;
		}
		
		if (!(memoryProtection & VM_PROT_READ))
		{
			return NO;
		}
	}
	
	return YES;
}

#pragma mark Search Handling

- (IBAction)clearSearchValues:(id)sender
{
	[self.variableController clear];
}

- (IBAction)searchValue:(id)sender
{
	// Make sure our fields are up to date
	[self changeSearchValueString:self.searchValueTextField];
	
	[self.searchController searchOrCancel];
}

- (IBAction)storeAllValues:(id)sender
{
	[self.searchController storeAllValues];
}

#pragma mark Bindings

- (IBAction)changeStringCaseOption:(id)sender
{
	self.searchData.shouldIgnoreStringCase = [sender state];
	[self markDocumentChange];
}

- (IBAction)ignoreDataAlignment:(id)sender
{
	self.documentData.ignoreDataAlignment = [sender state];
	[self markDocumentChange];
}

- (IBAction)changeNullTerminatorInclusion:(id)sender
{
	self.searchData.shouldIncludeNullTerminator = [sender state];
	[self markDocumentChange];
}

- (IBAction)changeSearchValueString:(id)sender
{
	self.documentData.searchValueString = [sender stringValue];
	[self markDocumentChange];
}

- (IBAction)changeBeginningAddressString:(id)sender
{
	self.documentData.beginningAddressStringValue = [sender stringValue];
	[self markDocumentChange];
}

- (IBAction)changeEndingAddressString:(id)sender
{
	self.documentData.endingAddressStringValue = [sender stringValue];
	[self markDocumentChange];
}

- (IBAction)changeUnwritableValuesOption:(id)sender
{
	self.searchData.shouldScanUnwritableValues = [sender state];
	[self markDocumentChange];
}

#pragma mark Variables Handling

- (IBAction)freezeVariables:(id)sender
{
	[self.variableController freezeVariables];
}

- (IBAction)copy:(id)sender
{
	[self.variableController copyVariables];
}

- (IBAction)copyAddress:(id)sender
{
	[self.variableController copyAddress];
}

- (IBAction)paste:(id)sender
{
	[self.variableController pasteVariables];
}

- (IBAction)cut:(id)sender
{
	[self.variableController copyVariables];
	[self removeSelectedSearchValues:nil];
}

- (IBAction)removeSelectedSearchValues:(id)sender
{
	[self.variableController removeSelectedSearchValues];
}

- (IBAction)addVariable:(id)sender
{
	[self.variableController addVariable:sender];
}

- (IBAction)nopVariables:(id)sender
{
	[self.variableController nopVariables:[self selectedVariables]];
}

- (IBAction)editVariablesValue:(id)sender
{
	[self.variableController editVariablesValueRequest];
}

- (IBAction)editVariablesValueOKButton:(id)sender
{
	[self.variableController editVariablesValueOkayButton];
}

- (IBAction)editVariablesValueCancelButton:(id)sender
{
	[self.variableController editVariablesValueCancelButton];
}

- (IBAction)editVariablesAddress:(id)sender
{
	[self.variableController editVariablesAddressRequest];
}

- (IBAction)editVariablesAddressOKButton:(id)sender
{
	[self.variableController editVariablesAddressOkayButton];
}

- (IBAction)editVariablesAddressCancelButton:(id)sender
{
	[self.variableController editVariablesAddressCancelButton];
}

- (IBAction)editVariablesSize:(id)sender
{
	[self.variableController editVariablesSizeRequest];
}

- (IBAction)editVariablesSizeOKButton:(id)sender
{
	[self.variableController editVariablesSizeOkayButton];
}

- (IBAction)editVariablesSizeCancelButton:(id)sender
{
	[self.variableController editVariablesSizeCancelButton];
}

- (IBAction)relativizeVariablesAddress:(id)sender
{
	[self.variableController relativizeVariables:[self selectedVariables]];
}

#pragma mark Variable Watching Handling

- (IBAction)watchVariable:(id)sender
{
	[self.documentBreakPointController requestVariableWatch:(ZGWatchPointType)[sender tag]];
}

#pragma mark Showing Other Controllers

- (IBAction)showMemoryViewer:(id)sender
{
	ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
	[[[ZGAppController sharedController] memoryViewer] jumpToMemoryAddress:selectedVariable.address withSelectionLength:selectedVariable.size > 0 ? selectedVariable.size : DEFAULT_MEMORY_VIEWER_SELECTION_LENGTH inProcess:self.currentProcess];
}

- (IBAction)showDebugger:(id)sender
{
	ZGVariable *selectedVariable = [[self selectedVariables] objectAtIndex:0];
	[[[ZGAppController sharedController] debuggerController] showWindow:self];
	[[[ZGAppController sharedController] debuggerController] jumpToMemoryAddress:selectedVariable.address inProcess:self.currentProcess];
}

#pragma mark Pausing and Unpausing Processes

- (IBAction)pauseOrUnpauseProcess:(id)sender
{
	[ZGProcess pauseOrUnpauseProcessTask:self.currentProcess.processTask];
}

@end
