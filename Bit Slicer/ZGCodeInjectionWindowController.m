/*
 * Created by Mayur Pawashe on 8/19/13.
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

#import "ZGCodeInjectionWindowController.h"

@interface ZGCodeInjectionWindowController ()

@property (copy, nonatomic) code_injection_completion_t completionHandler;

@end

@implementation ZGCodeInjectionWindowController

- (NSString *)windowNibName
{
	return NSStringFromClass([self class]);
}

- (void)attachToWindow:(NSWindow *)parentWindow completionHandler:(code_injection_completion_t)completionHandler
{
	self.completionHandler = completionHandler;
	
	[self window]; // Ensure window is loaded
	
	[self.textView.textStorage.mutableString setString:self.suggestedCode];
	
	[NSApp
	 beginSheet:self.window
	 modalForWindow:parentWindow
	 modalDelegate:nil
	 didEndSelector:nil
	 contextInfo:NULL];
}

- (IBAction)injectCode:(id)sender
{
	BOOL succeeded = YES;
	self.completionHandler([self.textView.textStorage.mutableString copy], NO, &succeeded);
	
	if (succeeded)
	{
		[NSApp endSheet:self.window];
		[self.window close];
	}
}

- (IBAction)cancel:(id)sender
{
	self.completionHandler(nil, YES, NULL);
	[NSApp endSheet:self.window];
	[self.window close];
}

@end
