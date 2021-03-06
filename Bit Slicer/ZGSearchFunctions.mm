/*
 * Created by Mayur Pawashe on 8/29/13.
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

#import "ZGSearchFunctions.h"
#import "ZGSearchData.h"
#import "ZGSearchProgress.h"
#import "ZGRegion.h"
#import "ZGVirtualMemory.h"
#import "ZGVirtualMemoryHelpers.h"
#import "NSArrayAdditions.h"
#import "ZGSearchResults.h"
#import <stdint.h>

#pragma mark Boyer Moore Function

// Fast string-searching function from HexFiend's framework
extern "C" unsigned char* boyer_moore_helper(const unsigned char *haystack, const unsigned char *needle, unsigned long haystack_length, unsigned long needle_length, const unsigned long *char_jump, const unsigned long *match_jump);

// This portion of code is mostly stripped from a function in Hex Fiend's framework; it's wicked fast.
void ZGPrepareBoyerMooreSearch(const unsigned char *needle, const unsigned long needle_length, const unsigned char *haystack, unsigned long haystack_length, unsigned long *char_jump, unsigned long *match_jump)
{
	unsigned long *backup;
	unsigned long u, ua, ub;
	backup = match_jump + needle_length + 1;
	
	// heuristic #1 setup, simple text search
	for (u=0; u < sizeof char_jump / sizeof *char_jump; u++)
	{
		char_jump[u] = needle_length;
	}
	
	for (u = 0; u < needle_length; u++)
	{
		char_jump[((unsigned char) needle[u])] = needle_length - u - 1;
	}
	
	// heuristic #2 setup, repeating pattern search
	for (u = 1; u <= needle_length; u++)
	{
		match_jump[u] = 2 * needle_length - u;
	}
	
	u = needle_length;
	ua = needle_length + 1;
	while (u > 0)
	{
		backup[u] = ua;
		while (ua <= needle_length && needle[u - 1] != needle[ua - 1])
		{
			if (match_jump[ua] > needle_length - u) match_jump[ua] = needle_length - u;
			ua = backup[ua];
		}
		u--; ua--;
	}
	
	for (u = 1; u <= ua; u++)
	{
		if (match_jump[u] > needle_length + ua - u) match_jump[u] = needle_length + ua - u;
	}
	
	ub = ua;
	while (ua <= needle_length)
	{
		ub = backup[ub];
		while (ua <= ub)
		{
			if (match_jump[ua] > ub - ua + needle_length)
			{
				match_jump[ua] = ub - ua + needle_length;
			}
			ua++;
		}
	}
}

#pragma mark Generic Searching

typedef void (^zg_search_for_data_helper_t)(ZGMemorySize dataIndex, ZGMemoryAddress address, ZGMemorySize size, NSMutableData * __unsafe_unretained resultSet, void *bytes, void *regionBytes);

ZGSearchResults *ZGSearchForDataHelper(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, zg_search_for_data_helper_t helper)
{
	ZGMemorySize dataAlignment = searchData.dataAlignment;
	ZGMemorySize dataSize = searchData.dataSize;
	ZGMemorySize pointerSize = searchData.pointerSize;
	
	BOOL shouldCompareStoredValues = searchData.shouldCompareStoredValues;
	
	ZGMemoryAddress dataBeginAddress = searchData.beginAddress;
	ZGMemoryAddress dataEndAddress = searchData.endAddress;
	BOOL shouldScanUnwritableValues = searchData.shouldScanUnwritableValues;
	
	NSArray *regions;
	if (!shouldCompareStoredValues)
	{
		regions = [ZGRegionsForProcessTask(processTask) zgFilterUsingBlock:(zg_array_filter_t)^(ZGRegion *region) {
			return region.address < dataEndAddress && region.address + region.size > dataBeginAddress && region.protection & VM_PROT_READ && (shouldScanUnwritableValues || (region.protection & VM_PROT_WRITE));
		}];
	}
	else
	{
		regions = searchData.savedData;
	}
	
	dispatch_async(dispatch_get_main_queue(), ^{
		searchProgress.initiatedSearch = YES;
		searchProgress.progressType = ZGSearchProgressMemoryScanning;
		searchProgress.maxProgress = regions.count;
	});
	
	NSMutableArray *allResultSets = [[NSMutableArray alloc] init];
	for (NSUInteger regionIndex = 0; regionIndex < regions.count; regionIndex++)
	{
		[allResultSets addObject:[[NSMutableData alloc] init]];
	}
	
	dispatch_apply(regions.count, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t regionIndex) {
		@autoreleasepool
		{
			ZGRegion *region = [regions objectAtIndex:regionIndex];
			ZGMemoryAddress address = region.address;
			ZGMemorySize size = region.size;
			void *regionBytes = region.bytes;
			
			NSMutableData *resultSet = [allResultSets objectAtIndex:regionIndex];
			
			ZGMemorySize dataIndex = 0;
			char *bytes = NULL;
			if (dataBeginAddress < address + size && dataEndAddress > address)
			{
				if (dataBeginAddress > address)
				{
					dataIndex = (dataBeginAddress - address);
					if (dataIndex % dataAlignment > 0)
					{
						dataIndex += dataAlignment - (dataIndex % dataAlignment);
					}
				}
				if (dataEndAddress < address + size)
				{
					size = dataEndAddress - address;
				}
				
				if (!searchProgress.shouldCancelSearch && ZGReadBytes(processTask, address, (void **)&bytes, &size))
				{
					helper(dataIndex, address, size, resultSet, bytes, regionBytes);
					
					ZGFreeBytes(processTask, bytes, size);
				}
			}
			
			dispatch_async(dispatch_get_main_queue(), ^{
				searchProgress.numberOfVariablesFound += resultSet.length / pointerSize;
				searchProgress.progress++;
			});
		}
	});
	
	NSArray *resultSets;
	
	if (searchProgress.shouldCancelSearch)
	{
		resultSets = [NSArray array];
		
		// Deallocate results into separate queue since this could take some time
		__block id oldResultSets = allResultSets;
		allResultSets = nil;
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			oldResultSets = nil;
		});
	}
	else
	{
		resultSets = [allResultSets zgFilterUsingBlock:(zg_array_filter_t)^(NSMutableData *resultSet) {
			return resultSet.length != 0;
		}];
	}
	
	return [[ZGSearchResults alloc] initWithResultSets:resultSets dataSize:dataSize pointerSize:pointerSize];
}

#define ADD_VARIABLE_ADDRESS(addressExpression, pointerSize, resultSet) \
switch (pointerSize) \
{ \
case sizeof(ZGMemoryAddress): \
	{ \
		ZGMemoryAddress memoryAddress = (addressExpression); \
		[resultSet appendBytes:&memoryAddress length:sizeof(memoryAddress)]; \
		break; \
	} \
case sizeof(ZG32BitMemoryAddress): \
	{ \
		ZG32BitMemoryAddress memoryAddress = (ZG32BitMemoryAddress)(addressExpression); \
		[resultSet appendBytes:&memoryAddress length:sizeof(memoryAddress)]; \
		break; \
	} \
}

template <typename T, typename P>
void ZGSearchWithFunctionHelperRegular(T *searchValue, bool (*comparisonFunction)(ZGSearchData *, T *, T *), ZGSearchData * __unsafe_unretained searchData, ZGMemorySize dataIndex, ZGMemorySize dataAlignment, ZGMemorySize endLimit, P pointerSize, NSMutableData * __unsafe_unretained resultSet, ZGMemoryAddress address, void *bytes)
{
	const ZGMemorySize maxSteps = 4096;
	while (dataIndex <= endLimit)
	{
		ZGMemorySize numberOfVariablesFound = 0;
		P memoryAddresses[maxSteps];
		
		ZGMemorySize numberOfStepsToTake = MIN(maxSteps, (endLimit + dataAlignment - dataIndex) / dataAlignment);
		for (ZGMemorySize stepIndex = 0; stepIndex < numberOfStepsToTake; stepIndex++)
		{
			if (comparisonFunction(searchData, (T *)((int8_t *)bytes + dataIndex), searchValue))
			{
				memoryAddresses[numberOfVariablesFound] = (P)(address + dataIndex);
				numberOfVariablesFound++;
			}
			
			dataIndex += dataAlignment;
		}
		
		[resultSet appendBytes:memoryAddresses length:sizeof(P) * numberOfVariablesFound];
	}
}

// like ZGSearchWithFunctionHelperRegular above except against stored values
template <typename T, typename P>
void ZGSearchWithFunctionHelperStored(T *regionBytes, bool (*comparisonFunction)(ZGSearchData *, T *, T *), ZGSearchData * __unsafe_unretained searchData, ZGMemorySize dataIndex, ZGMemorySize dataAlignment, ZGMemorySize endLimit, P pointerSize, NSMutableData * __unsafe_unretained resultSet, ZGMemoryAddress address, void *bytes)
{
	const ZGMemorySize maxSteps = 4096;
	while (dataIndex <= endLimit)
	{
		ZGMemorySize numberOfVariablesFound = 0;
		P memoryAddresses[maxSteps];
		
		ZGMemorySize numberOfStepsToTake = MIN(maxSteps, (endLimit + dataAlignment - dataIndex) / dataAlignment);
		for (ZGMemorySize stepIndex = 0; stepIndex < numberOfStepsToTake; stepIndex++)
		{
			if (comparisonFunction(searchData, (T *)((int8_t *)bytes + dataIndex), (T *)((int8_t *)regionBytes + dataIndex)))
			{
				memoryAddresses[numberOfVariablesFound] = (P)(address + dataIndex);
				numberOfVariablesFound++;
			}
			
			dataIndex += dataAlignment;
		}
		
		[resultSet appendBytes:memoryAddresses length:sizeof(P) * numberOfVariablesFound];
	}
}

template <typename T>
ZGSearchResults *ZGSearchWithFunction(bool (*comparisonFunction)(ZGSearchData *, T *, T *), ZGMemoryMap processTask, T *searchValue, ZGSearchData * __unsafe_unretained searchData, ZGSearchProgress * __unsafe_unretained searchProgress)
{
	ZGMemorySize dataAlignment = searchData.dataAlignment;
	ZGMemorySize pointerSize = searchData.pointerSize;
	ZGMemorySize dataSize = searchData.dataSize;
	BOOL shouldCompareStoredValues = searchData.shouldCompareStoredValues;
	
	return ZGSearchForDataHelper(processTask, searchData, searchProgress, ^(ZGMemorySize dataIndex, ZGMemoryAddress address, ZGMemorySize size, NSMutableData * __unsafe_unretained resultSet, void *bytes, void *regionBytes) {
		ZGMemorySize endLimit = size - dataSize;
		
		if (!shouldCompareStoredValues)
		{
			if (pointerSize == sizeof(ZGMemoryAddress))
			{
				ZGSearchWithFunctionHelperRegular(searchValue, comparisonFunction, searchData, dataIndex, dataAlignment, endLimit, pointerSize, resultSet, address, bytes);
			}
			else
			{
				ZGSearchWithFunctionHelperRegular(searchValue, comparisonFunction, searchData, dataIndex, dataAlignment, endLimit, (ZG32BitMemoryAddress)pointerSize, resultSet, address, bytes);
			}
		}
		else
		{
			if (pointerSize == sizeof(ZGMemoryAddress))
			{
				ZGSearchWithFunctionHelperStored((T *)regionBytes, comparisonFunction, searchData, dataIndex, dataAlignment, endLimit, pointerSize, resultSet, address, bytes);
			}
			else
			{
				ZGSearchWithFunctionHelperStored((T *)regionBytes, comparisonFunction, searchData, dataIndex, dataAlignment, endLimit, (ZG32BitMemoryAddress)pointerSize, resultSet, address, bytes);
			}
		}
	});
}

ZGSearchResults *ZGSearchForBytes(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress)
{
	const unsigned long dataSize = searchData.dataSize;
	const unsigned char *searchValue = (const unsigned char *)searchData.searchValue;
	ZGMemorySize pointerSize = searchData.pointerSize;
	ZGMemorySize dataAlignment = searchData.dataAlignment;
	
	return ZGSearchForDataHelper(processTask, searchData, searchProgress, ^(ZGMemorySize dataIndex, ZGMemoryAddress address, ZGMemorySize size, NSMutableData * __unsafe_unretained resultSet, void *bytes, void *regionBytes) {
		// generate the two Boyer-Moore auxiliary buffers
		unsigned long charJump[UCHAR_MAX + 1] = {0};
		unsigned long *matchJump = (unsigned long *)malloc(2 * (dataSize + 1) * sizeof(*matchJump));
		
		ZGPrepareBoyerMooreSearch(searchValue, dataSize, (const unsigned char *)bytes, size, charJump, matchJump);
		
		unsigned char *foundSubstring = (unsigned char *)bytes;
		unsigned long haystackLengthLeft = size;
		
		while (haystackLengthLeft >= dataSize)
		{
			foundSubstring = boyer_moore_helper((const unsigned char *)foundSubstring, searchValue, haystackLengthLeft, (unsigned long)dataSize, (const unsigned long *)charJump, (const unsigned long *)matchJump);
			if (foundSubstring == NULL) break;
			
			ZGMemoryAddress foundAddress = foundSubstring - (unsigned char *)bytes + address;
			// boyer_moore_helper is only checking 0 .. dataSize-1 characters, so make a check to see if the last characters are equal
			if (foundAddress % dataAlignment == 0 && foundSubstring[dataSize-1] == searchValue[dataSize-1])
			{
				ADD_VARIABLE_ADDRESS(foundAddress, pointerSize, resultSet);
			}
			
			foundSubstring++;
			haystackLengthLeft = (unsigned char *)bytes + size - foundSubstring;
		}
		
		free(matchJump);
	});
}

#pragma mark Integers

template <typename T>
bool ZGIntegerEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return *variableValue == *compareValue;
}

template <typename T>
bool ZGIntegerNotEquals(ZGSearchData * __unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return !ZGIntegerEquals(searchData, variableValue, compareValue);
}

template <typename T>
bool ZGIntegerGreaterThan(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return (*variableValue > *compareValue) && (searchData->_rangeValue == NULL || *variableValue < *(T *)(searchData->_rangeValue));
}

template <typename T>
bool ZGIntegerLesserThan(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return (*variableValue < *compareValue) && (searchData->_rangeValue == NULL || *variableValue > *(T *)(searchData->_rangeValue));
}

template <typename T>
bool ZGIntegerEqualsPlus(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	T newCompareValue = *((T *)compareValue) + *((T *)searchData->_compareOffset);
	return ZGIntegerEquals(searchData, variableValue, &newCompareValue);
}

template <typename T>
bool ZGIntegerNotEqualsPlus(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	T newCompareValue = *compareValue + *((T *)searchData->_compareOffset);
	return ZGIntegerNotEquals(searchData, variableValue, &newCompareValue);
}

#define ZGHandleIntegerType(functionType, type, integerQualifier, dataType, processTask, searchData, searchProgress) \
	case dataType: \
		if (integerQualifier == ZGSigned) \
			retValue = ZGSearchWithFunction(functionType, processTask, (type *)searchData.searchValue, searchData, searchProgress); \
		else \
			retValue = ZGSearchWithFunction(functionType, processTask, (u##type *)searchData.searchValue, searchData, searchProgress); \
		break

#define ZGHandleIntegerCase(dataType, function) \
if (dataType == ZGPointer) {\
	switch (searchData.dataSize) {\
		case sizeof(ZGMemoryAddress):\
			retValue = ZGSearchWithFunction(function, processTask, (uint64_t *)searchData.searchValue, searchData, searchProgress);\
			break;\
		case sizeof(ZG32BitMemoryAddress):\
			retValue = ZGSearchWithFunction(function, processTask, (uint32_t *)searchData.searchValue, searchData, searchProgress);\
			break;\
	}\
}\
else {\
	switch (dataType) {\
		ZGHandleIntegerType(function, int8_t, integerQualifier, ZGInt8, processTask, searchData, searchProgress);\
		ZGHandleIntegerType(function, int16_t, integerQualifier, ZGInt16, processTask, searchData, searchProgress);\
		ZGHandleIntegerType(function, int32_t, integerQualifier, ZGInt32, processTask, searchData, searchProgress);\
		ZGHandleIntegerType(function, int64_t, integerQualifier, ZGInt64, processTask, searchData, searchProgress);\
		default: break;\
	}\
}\

ZGSearchResults *ZGSearchForIntegers(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, ZGVariableType dataType, ZGVariableQualifier integerQualifier, ZGFunctionType functionType)
{
	id retValue = nil;
	
	switch (functionType)
	{
		case ZGEquals:
		case ZGEqualsStored:
			ZGHandleIntegerCase(dataType, ZGIntegerEquals);
			break;
		case ZGNotEquals:
		case ZGNotEqualsStored:
			ZGHandleIntegerCase(dataType, ZGIntegerNotEquals);
			break;
		case ZGGreaterThan:
		case ZGGreaterThanStored:
			ZGHandleIntegerCase(dataType, ZGIntegerGreaterThan);
			break;
		case ZGLessThan:
		case ZGLessThanStored:
			ZGHandleIntegerCase(dataType, ZGIntegerLesserThan);
			break;
		case ZGEqualsStoredPlus:
			ZGHandleIntegerCase(dataType, ZGIntegerEqualsPlus);
			break;
		case ZGNotEqualsStoredPlus:
			ZGHandleIntegerCase(dataType, ZGIntegerNotEqualsPlus);
			break;
		case ZGStoreAllValues:
			break;
	}
	
	return retValue;
}

#pragma mark Floating Points

template <typename T>
bool ZGFloatingPointEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return ABS(*((T *)variableValue) - *((T *)compareValue)) <= searchData->_epsilon;
}

template <typename T>
bool ZGFloatingPointNotEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return !ZGFloatingPointEquals(searchData, variableValue, compareValue);
}

template <typename T>
bool ZGFloatingPointGreaterThan(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return *variableValue > *compareValue && (searchData->_rangeValue == NULL || *variableValue < *(T *)(searchData->_rangeValue));
}

template <typename T>
bool ZGFloatingPointLesserThan(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return *variableValue < *compareValue && (searchData->_rangeValue == NULL || *variableValue > *(T *)(searchData->_rangeValue));
}

template <typename T>
bool ZGFloatingPointEqualsPlus(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	T newCompareValue = *((T *)compareValue) + *((T *)searchData->_compareOffset);
	return ZGFloatingPointEquals(searchData, variableValue, &newCompareValue);
}

template <typename T>
bool ZGFloatingPointNotEqualsPlus(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	T newCompareValue = *((T *)compareValue) + *((T *)searchData->_compareOffset);
	return ZGFloatingPointNotEquals(searchData, variableValue, &newCompareValue);
}

#define ZGHandleType(functionType, type, dataType, processTask, searchData, searchProgress) \
	case dataType: \
		retValue = ZGSearchWithFunction(functionType, processTask, (type *)searchData.searchValue, searchData, searchProgress); \
	break

#define ZGHandleFloatingPointCase(case, function) \
switch (case) {\
	ZGHandleType(function, float, ZGFloat, processTask, searchData, searchProgress);\
	ZGHandleType(function, double, ZGDouble, processTask, searchData, searchProgress);\
	default: break;\
}

ZGSearchResults *ZGSearchForFloatingPoints(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, ZGVariableType dataType, ZGFunctionType functionType)
{
	id retValue = nil;
	
	switch (functionType)
	{
		case ZGEquals:
		case ZGEqualsStored:
			ZGHandleFloatingPointCase(dataType, ZGFloatingPointEquals);
			break;
		case ZGNotEquals:
		case ZGNotEqualsStored:
			ZGHandleFloatingPointCase(dataType, ZGFloatingPointNotEquals);
			break;
		case ZGGreaterThan:
		case ZGGreaterThanStored:
			ZGHandleFloatingPointCase(dataType, ZGFloatingPointGreaterThan);
			break;
		case ZGLessThan:
		case ZGLessThanStored:
			ZGHandleFloatingPointCase(dataType, ZGFloatingPointLesserThan);
			break;
		case ZGEqualsStoredPlus:
			ZGHandleFloatingPointCase(dataType, ZGFloatingPointEqualsPlus);
			break;
		case ZGNotEqualsStoredPlus:
			ZGHandleFloatingPointCase(dataType, ZGFloatingPointNotEqualsPlus);
			break;
		case ZGStoreAllValues:
			break;
	}
	
	return retValue;
}

#pragma mark Strings

template <typename T>
bool ZGString8CaseInsensitiveEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return strncasecmp(variableValue, compareValue, searchData->_dataSize) == 0;
}

template <typename T>
bool ZGString16CaseInsensitiveEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	Boolean isEqual = false;
	UCCompareText(searchData->_collator, variableValue, ((size_t)searchData->_dataSize) / sizeof(T), compareValue, ((size_t)searchData->_dataSize) / sizeof(T), (Boolean *)&isEqual, NULL);
	return isEqual;
}

template <typename T>
bool ZGString8CaseInsensitiveNotEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return !ZGString8CaseInsensitiveEquals(searchData, variableValue, compareValue);
}

template <typename T>
bool ZGString16CaseInsensitiveNotEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return !ZGString16CaseInsensitiveEquals(searchData, variableValue, compareValue);
}

#define ZGHandleStringCase(case, function1, function2) \
	switch (case) {\
		ZGHandleType(function1, char, ZGString8, processTask, searchData, searchProgress);\
		ZGHandleType(function2, unichar, ZGString16, processTask, searchData, searchProgress);\
		default: break;\
	}\

ZGSearchResults *ZGSearchForCaseInsensitiveStrings(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, ZGVariableType dataType, ZGFunctionType functionType)
{
	id retValue = nil;
	
	switch (functionType)
	{
		case ZGEquals:
			ZGHandleStringCase(dataType, ZGString8CaseInsensitiveEquals, ZGString16CaseInsensitiveEquals);
			break;
		case ZGNotEquals:
			ZGHandleStringCase(dataType, ZGString8CaseInsensitiveNotEquals, ZGString16CaseInsensitiveNotEquals);
			break;
		default:
			break;
	}
	
	return retValue;
}

#pragma mark Byte Arrays

template <typename T>
bool ZGByteArrayWithWildcardsEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	const unsigned char *variableValueArray = (const unsigned char *)variableValue;
	const unsigned char *compareValueArray = (const unsigned char *)compareValue;
	
	bool isEqual = true;
	
	for (unsigned int byteIndex = 0; byteIndex < searchData->_dataSize; byteIndex++)
	{
		if (!(searchData->_byteArrayFlags[byteIndex] & 0xF0) && ((variableValueArray[byteIndex] & 0xF0) != (compareValueArray[byteIndex] & 0xF0)))
		{
			isEqual = false;
			break;
		}
		
		if (!(searchData->_byteArrayFlags[byteIndex] & 0x0F) && ((variableValueArray[byteIndex] & 0x0F) != (compareValueArray[byteIndex] & 0x0F)))
		{
			isEqual = false;
			break;
		}
	}
	
	return isEqual;
}

template <typename T>
bool ZGByteArrayWithWildcardsNotEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return !ZGByteArrayWithWildcardsEquals(searchData, (void *)variableValue, (void *)compareValue);
}

ZGSearchResults *ZGSearchForByteArraysWithWildcards(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, ZGVariableType dataType, ZGFunctionType functionType)
{
	id retValue = nil;
	
	switch (functionType)
	{
		case ZGEquals:
			retValue = ZGSearchWithFunction(ZGByteArrayWithWildcardsEquals, processTask, searchData.searchValue, searchData, searchProgress);
			break;
		case ZGNotEquals:
			retValue = ZGSearchWithFunction(ZGByteArrayWithWildcardsNotEquals, processTask, searchData.searchValue, searchData, searchProgress);
			break;
		default:
			break;
	}
	
	return retValue;
}

#pragma mark Searching for Data

ZGSearchResults *ZGSearchForData(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, ZGVariableType dataType, ZGVariableQualifier integerQualifier, ZGFunctionType functionType)
{
	id retValue = nil;
	if (((dataType == ZGByteArray && searchData.byteArrayFlags == NULL) || ((dataType == ZGString8 || dataType == ZGString16) && !searchData.shouldIgnoreStringCase)) && !searchData.shouldCompareStoredValues && functionType == ZGEquals)
	{
		// use fast boyer moore
		retValue = ZGSearchForBytes(processTask, searchData, searchProgress);
	}
	else if ([@[@(ZGInt8), @(ZGInt16), @(ZGInt32), @(ZGInt64), @(ZGPointer)] containsObject:@(dataType)])
	{
		retValue = ZGSearchForIntegers(processTask, searchData, searchProgress, dataType, integerQualifier, functionType);
	}
	else if ([@[@(ZGFloat), @(ZGDouble)] containsObject:@(dataType)])
	{
		retValue = ZGSearchForFloatingPoints(processTask, searchData, searchProgress, dataType, functionType);
	}
	else if ([@[@(ZGString8), @(ZGString16)] containsObject:@(dataType)])
	{
		retValue = ZGSearchForCaseInsensitiveStrings(processTask, searchData, searchProgress, dataType, functionType);
	}
	else if (dataType == ZGByteArray)
	{
		retValue = ZGSearchForByteArraysWithWildcards(processTask, searchData, searchProgress, dataType, functionType);
	}
	return retValue;
}

#pragma mark Generic Narrowing Searching

typedef void (^zg_narrow_search_for_data_helper_t)(size_t resultSetIndex, NSUInteger oldResultSetStartIndex, NSData * __unsafe_unretained oldResultSet, NSMutableData * __unsafe_unretained newResultSet);

ZGSearchResults *ZGNarrowSearchForDataHelper(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, ZGSearchResults *firstSearchResults, ZGSearchResults *laterSearchResults, zg_narrow_search_for_data_helper_t helper)
{
	ZGMemorySize dataSize = searchData.dataSize;
	
	ZGMemorySize pointerSize = searchData.pointerSize;
	
	ZGMemorySize newResultSetCount = firstSearchResults.resultSets.count + laterSearchResults.resultSets.count;
	
	dispatch_async(dispatch_get_main_queue(), ^{
		searchProgress.initiatedSearch = YES;
		searchProgress.progressType = ZGSearchProgressMemoryScanning;
		searchProgress.maxProgress = newResultSetCount;
	});
	
	ZGMemorySize *laterResultSetsAbsoluteIndexes = (ZGMemorySize *)malloc(sizeof(*laterResultSetsAbsoluteIndexes) * laterSearchResults.resultSets.count);
	ZGMemorySize laterResultSetsAbsoluteIndexAccumulator = 0;
	
	NSMutableArray *newResultSets = [[NSMutableArray alloc] init];
	for (NSUInteger regionIndex = 0; regionIndex < newResultSetCount; regionIndex++)
	{
		[newResultSets addObject:[[NSMutableData alloc] init]];
		if (regionIndex >= firstSearchResults.resultSets.count)
		{
			laterResultSetsAbsoluteIndexes[regionIndex - firstSearchResults.resultSets.count] = laterResultSetsAbsoluteIndexAccumulator;
			laterResultSetsAbsoluteIndexAccumulator += [[laterSearchResults.resultSets objectAtIndex:regionIndex - firstSearchResults.resultSets.count] length];
		}
	}
	
	dispatch_apply(newResultSetCount, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t resultSetIndex) {
		@autoreleasepool
		{
			if (!searchProgress.shouldCancelSearch)
			{
				NSMutableData *newResultSet = [newResultSets objectAtIndex:resultSetIndex];
				NSData *oldResultSet = resultSetIndex < firstSearchResults.resultSets.count ? [firstSearchResults.resultSets objectAtIndex:resultSetIndex] : [laterSearchResults.resultSets objectAtIndex:resultSetIndex - firstSearchResults.resultSets.count];
				
				// Don't scan addresses that have been popped out from laterSearchResults
				NSUInteger startIndex = 0;
				if (resultSetIndex >= firstSearchResults.resultSets.count)
				{
					ZGMemorySize absoluteIndex = laterResultSetsAbsoluteIndexes[resultSetIndex - firstSearchResults.resultSets.count];
					if (absoluteIndex < laterSearchResults.addressIndex * pointerSize)
					{
						startIndex = (laterSearchResults.addressIndex * pointerSize - absoluteIndex);
					}
				}
				
				helper(resultSetIndex, startIndex, oldResultSet, newResultSet);
				
				dispatch_async(dispatch_get_main_queue(), ^{
					searchProgress.numberOfVariablesFound += newResultSet.length / pointerSize;
					searchProgress.progress++;
				});
			}
		}
	});
	
	free(laterResultSetsAbsoluteIndexes);
	
	NSArray *resultSets;
	
	if (searchProgress.shouldCancelSearch)
	{
		resultSets = [NSArray array];
		
		// Deallocate results into separate queue since this could take some time
		__block id oldResultSets = newResultSets;
		newResultSets = nil;
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			oldResultSets = nil;
		});
	}
	else
	{
		resultSets = [newResultSets zgFilterUsingBlock:(zg_array_filter_t)^(NSMutableData *resultSet) {
			return resultSet.length != 0;
		}];
	}
	
	return [[ZGSearchResults alloc] initWithResultSets:resultSets dataSize:dataSize pointerSize:pointerSize];
}

template <typename T, typename P>
void ZGNarrowSearchWithFunctionRegularCompare(ZGRegion **lastUsedSavedRegionReference, ZGRegion * __unsafe_unretained lastUsedRegion, P variableAddress, ZGMemorySize dataSize, NSDictionary * __unsafe_unretained savedPageToRegionTable, NSArray * __unsafe_unretained savedRegions, ZGMemorySize pageSize, bool (*comparisonFunction)(ZGSearchData *, T *, T *), P *memoryAddresses, ZGMemorySize &numberOfVariablesFound, ZGSearchData * __unsafe_unretained searchData, T *searchValue)
{
	T *currentValue = (T *)((int8_t *)lastUsedRegion->_bytes + (variableAddress - lastUsedRegion->_address));
	if (comparisonFunction(searchData, currentValue, searchValue))
	{
		memoryAddresses[numberOfVariablesFound] = variableAddress;
		numberOfVariablesFound++;
	}
}

template <typename T, typename P>
void ZGNarrowSearchWithFunctionStoredCompare(ZGRegion **lastUsedSavedRegionReference, ZGRegion * __unsafe_unretained lastUsedRegion, P variableAddress, ZGMemorySize dataSize, NSDictionary * __unsafe_unretained savedPageToRegionTable, NSArray * __unsafe_unretained savedRegions, ZGMemorySize pageSize, bool (*comparisonFunction)(ZGSearchData *, T *, T *), P *memoryAddresses, ZGMemorySize &numberOfVariablesFound, ZGSearchData * __unsafe_unretained searchData, T *searchValue)
{
	if (*lastUsedSavedRegionReference == nil || (variableAddress < (*lastUsedSavedRegionReference)->_address || variableAddress + dataSize > (*lastUsedSavedRegionReference)->_address + (*lastUsedSavedRegionReference)->_size))
	{
		ZGRegion *newRegion = nil;
		if (savedPageToRegionTable != nil)
		{
			newRegion = [savedPageToRegionTable objectForKey:@(variableAddress - (variableAddress % pageSize))];
		}
		else
		{
			NSUInteger maxIndex = savedRegions.count - 1;
			NSUInteger minIndex = 0;
			
			while (maxIndex >= minIndex)
			{
				NSUInteger middleIndex = (minIndex + maxIndex) / 2;
				ZGRegion *region = [savedRegions objectAtIndex:middleIndex];
				if (variableAddress < region.address)
				{
					if (middleIndex == 0) break;
					maxIndex = middleIndex - 1;
				}
				else if (variableAddress >= region.address + region.size)
				{
					minIndex = middleIndex + 1;
				}
				else
				{
					newRegion = region;
					break;
				}
			}
		}
		
		if (newRegion != nil && variableAddress >= newRegion->_address && variableAddress + dataSize <= newRegion->_address + newRegion->_size)
		{
			*lastUsedSavedRegionReference = newRegion;
		}
		else
		{
			*lastUsedSavedRegionReference = nil;
		}
	}
	
	if (*lastUsedSavedRegionReference != nil)
	{
		T *currentValue = (T *)((int8_t *)lastUsedRegion->_bytes + (variableAddress - lastUsedRegion->_address));
		T *compareValue = (T *)((int8_t *)(*lastUsedSavedRegionReference)->_bytes + (variableAddress - (*lastUsedSavedRegionReference)->_address));
		if (comparisonFunction(searchData, currentValue, compareValue))
		{
			memoryAddresses[numberOfVariablesFound] = variableAddress;
			numberOfVariablesFound++;
		}
	}
}

#define zg_define_compare_function(name) void (*name)(ZGRegion **, ZGRegion *, P, ZGMemorySize, NSDictionary *, NSArray *, ZGMemorySize, bool (*)(ZGSearchData *, T *, T *), P *, ZGMemorySize &, ZGSearchData *, T *)

template <typename T, typename P>
void ZGNarrowSearchWithFunctionType(bool (*comparisonFunction)(ZGSearchData *, T *, T *), ZGMemoryMap processTask, T *searchValue, ZGSearchData * __unsafe_unretained searchData, P pointerSize, ZGMemorySize dataSize, NSUInteger oldResultSetStartIndex, NSData * __unsafe_unretained oldResultSet, NSMutableData * __unsafe_unretained newResultSet, NSDictionary * __unsafe_unretained pageToRegionTable, NSDictionary * __unsafe_unretained savedPageToRegionTable, NSArray * __unsafe_unretained savedRegions, ZGMemorySize pageSize, zg_define_compare_function(compareHelperFunction))
{
	ZGRegion *lastUsedRegion = nil;
	ZGRegion *lastUsedSavedRegion = nil;
	
	ZGMemorySize oldDataLength = oldResultSet.length;
	const int8_t *oldResultSetBytes = (const int8_t *)oldResultSet.bytes;
	
	const ZGMemorySize maxSteps = 4096;
	ZGMemoryAddress dataIndex = oldResultSetStartIndex;
	while (dataIndex < oldDataLength)
	{
		P memoryAddresses[maxSteps];
		ZGMemorySize numberOfVariablesFound = 0;
		ZGMemorySize numberOfStepsToTake = MIN(maxSteps, (oldDataLength - dataIndex) / sizeof(P));
		for (ZGMemorySize stepIndex = 0; stepIndex < numberOfStepsToTake; stepIndex++)
		{
			P variableAddress = *(P *)(oldResultSetBytes + dataIndex);
			
			if (lastUsedRegion == nil || (variableAddress < lastUsedRegion->_address || variableAddress + dataSize > lastUsedRegion->_address + lastUsedRegion->_size))
			{
				if (lastUsedRegion != nil)
				{
					ZGFreeBytes(processTask, lastUsedRegion->_bytes, lastUsedRegion->_size);
				}
				
				ZGRegion *newRegion = nil;

				if (pageToRegionTable == nil)
				{
					ZGMemoryAddress regionAddress = variableAddress;
					ZGMemorySize regionSize = dataSize;
					ZGMemoryBasicInfo basicInfo;
					if (ZGRegionInfo(processTask, &regionAddress, &regionSize, &basicInfo))
					{
						newRegion = [[ZGRegion alloc] initWithAddress:regionAddress size:regionSize];
					}
				}
				else
				{
					newRegion = [pageToRegionTable objectForKey:@(variableAddress - (variableAddress % pageSize))];
				}
				
				if (newRegion != nil && variableAddress >= newRegion->_address && variableAddress + dataSize <= newRegion->_address + newRegion->_size)
				{
					lastUsedRegion = [[ZGRegion alloc] initWithAddress:newRegion->_address size:newRegion->_size];
					
					void *bytes = NULL;
					if (ZGReadBytes(processTask, lastUsedRegion->_address, &bytes, &lastUsedRegion->_size))
					{
						lastUsedRegion->_bytes = bytes;
					}
					else
					{
						lastUsedRegion = nil;
					}
				}
				else
				{
					lastUsedRegion = nil;
				}
			}
			
			if (lastUsedRegion != nil)
			{
				compareHelperFunction(&lastUsedSavedRegion, lastUsedRegion, variableAddress, dataSize, savedPageToRegionTable, savedRegions, pageSize, comparisonFunction, memoryAddresses, numberOfVariablesFound, searchData, searchValue);
			}
			
			dataIndex += sizeof(P);
		}
		
		[newResultSet appendBytes:memoryAddresses length:sizeof(P) * numberOfVariablesFound];
	}
	
	if (lastUsedRegion != nil)
	{
		ZGFreeBytes(processTask, lastUsedRegion->_bytes, lastUsedRegion->_size);
	}
}

template <typename T>
ZGSearchResults *ZGNarrowSearchWithFunction(bool (*comparisonFunction)(ZGSearchData *, T *, T *), ZGMemoryMap processTask, T *searchValue, ZGSearchData * __unsafe_unretained searchData, ZGSearchProgress * __unsafe_unretained searchProgress, ZGSearchResults * __unsafe_unretained firstSearchResults, ZGSearchResults * __unsafe_unretained laterSearchResults)
{
	ZGMemorySize pointerSize = searchData.pointerSize;
	ZGMemorySize dataSize = searchData.dataSize;
	BOOL shouldCompareStoredValues = searchData.shouldCompareStoredValues;
	
	ZGMemorySize pageSize = NSPageSize(); // sane default
	ZGPageSize(processTask, &pageSize);
	
	NSArray *allRegions = ZGRegionsForProcessTask(processTask);
	
	return ZGNarrowSearchForDataHelper(processTask, searchData, searchProgress, firstSearchResults, laterSearchResults, ^(size_t resultSetIndex, NSUInteger oldResultSetStartIndex, NSData * __unsafe_unretained oldResultSet, NSMutableData * __unsafe_unretained newResultSet) {
		NSMutableDictionary *pageToRegionTable = nil;
		
		// Adding __block only so clang's analyzer won't complain about values being unused
		__block ZGMemoryAddress firstAddress = 0;
		__block ZGMemoryAddress lastAddress = 0;
		
		if (resultSetIndex >= firstSearchResults.resultSets.count)
		{
			pageToRegionTable = [[NSMutableDictionary alloc] init];
			
			if (pointerSize == sizeof(ZGMemoryAddress))
			{
				firstAddress = *(ZGMemoryAddress *)((uint8_t *)oldResultSet.bytes + oldResultSetStartIndex);
				lastAddress = *(ZGMemoryAddress *)((uint8_t *)oldResultSet.bytes + oldResultSet.length - sizeof(ZGMemoryAddress)) + dataSize;
			}
			else
			{
				firstAddress = *(ZG32BitMemoryAddress *)((uint8_t *)oldResultSet.bytes + oldResultSetStartIndex);
				lastAddress = *(ZG32BitMemoryAddress *)((uint8_t *)oldResultSet.bytes + oldResultSet.length - sizeof(ZG32BitMemoryAddress)) + dataSize;
			}
			
			NSArray *regions = [allRegions zgFilterUsingBlock:(zg_array_filter_t)^(ZGRegion *region) {
				return region.address < lastAddress && region.address + region.size > firstAddress && region.protection & VM_PROT_READ && (searchData.shouldScanUnwritableValues || (region.protection & VM_PROT_WRITE));
			}];
			
			for (ZGRegion *region in regions)
			{
				ZGMemoryAddress regionAddress = region.address;
				ZGMemorySize regionSize = region.size;
				for (NSUInteger dataIndex = 0; dataIndex < regionSize; dataIndex += pageSize)
				{
					[pageToRegionTable setObject:region forKey:@(dataIndex + regionAddress)];
				}
			}
		}
		
		if (!shouldCompareStoredValues)
		{
			if (pointerSize == sizeof(ZGMemoryAddress))
			{
				ZGNarrowSearchWithFunctionType(comparisonFunction, processTask, searchValue, searchData, (ZGMemoryAddress)pointerSize, dataSize, oldResultSetStartIndex, oldResultSet, newResultSet, pageToRegionTable, nil, nil, pageSize, ZGNarrowSearchWithFunctionRegularCompare);
			}
			else
			{
				ZGNarrowSearchWithFunctionType(comparisonFunction, processTask, searchValue, searchData, (ZG32BitMemoryAddress)pointerSize, dataSize, oldResultSetStartIndex, oldResultSet, newResultSet, pageToRegionTable, nil, nil, pageSize, ZGNarrowSearchWithFunctionRegularCompare);
			}
		}
		else
		{
			NSArray *savedData = searchData.savedData;
			
			NSMutableDictionary *pageToSavedRegionTable = nil;
			
			if (pageToRegionTable != nil)
			{
				pageToSavedRegionTable = [[NSMutableDictionary alloc] init];
				
				NSArray *regions = [savedData zgFilterUsingBlock:(zg_array_filter_t)^(ZGRegion *region) {
					return region.address < lastAddress && region.address + region.size > firstAddress && region.protection & VM_PROT_READ && (searchData.shouldScanUnwritableValues || (region.protection & VM_PROT_WRITE));
				}];
				
				for (ZGRegion *region in regions)
				{
					ZGMemoryAddress regionAddress = region.address;
					ZGMemorySize regionSize = region.size;
					for (NSUInteger dataIndex = 0; dataIndex < regionSize; dataIndex += pageSize)
					{
						[pageToSavedRegionTable setObject:region forKey:@(dataIndex + regionAddress)];
					}
				}
			}
			
			if (pointerSize == sizeof(ZGMemoryAddress))
			{
				ZGNarrowSearchWithFunctionType(comparisonFunction, processTask, searchValue, searchData, (ZGMemoryAddress)pointerSize, dataSize, oldResultSetStartIndex, oldResultSet, newResultSet, pageToRegionTable, pageToSavedRegionTable, savedData, pageSize, ZGNarrowSearchWithFunctionStoredCompare);
			}
			else
			{
				ZGNarrowSearchWithFunctionType(comparisonFunction, processTask, searchValue, searchData, (ZG32BitMemoryAddress)pointerSize, dataSize, oldResultSetStartIndex, oldResultSet, newResultSet, pageToRegionTable, pageToSavedRegionTable, savedData, pageSize, ZGNarrowSearchWithFunctionStoredCompare);
			}
		}
	});
}

#pragma mark Narrowing Integers

#define ZGHandleNarrowIntegerType(functionType, type, integerQualifier, dataType, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults) \
case dataType: \
if (integerQualifier == ZGSigned) \
	retValue = ZGNarrowSearchWithFunction(functionType, processTask, (type *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults); \
else \
	retValue = ZGNarrowSearchWithFunction(functionType, processTask, (u##type *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults); \
break

#define ZGHandleNarrowIntegerCase(dataType, function) \
if (dataType == ZGPointer) {\
	switch (searchData.dataSize) {\
		case sizeof(ZGMemoryAddress):\
			retValue = ZGNarrowSearchWithFunction(function, processTask, (uint64_t *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults);\
			break;\
		case sizeof(ZG32BitMemoryAddress):\
			retValue = ZGNarrowSearchWithFunction(function, processTask, (uint32_t *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults);\
			break;\
	}\
}\
else {\
	switch (dataType) {\
		ZGHandleNarrowIntegerType(function, int8_t, integerQualifier, ZGInt8, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults);\
		ZGHandleNarrowIntegerType(function, int16_t, integerQualifier, ZGInt16, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults);\
		ZGHandleNarrowIntegerType(function, int32_t, integerQualifier, ZGInt32, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults);\
		ZGHandleNarrowIntegerType(function, int64_t, integerQualifier, ZGInt64, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults);\
		default: break;\
	}\
}\

ZGSearchResults *ZGNarrowSearchForIntegers(ZGMemoryMap processTask, ZGSearchData * __unsafe_unretained searchData, ZGSearchProgress * __unsafe_unretained searchProgress, ZGVariableType dataType, ZGVariableQualifier integerQualifier, ZGFunctionType functionType, ZGSearchResults * __unsafe_unretained firstSearchResults, ZGSearchResults * __unsafe_unretained laterSearchResults)
{
	id retValue = nil;
	switch (functionType)
	{
		case ZGEquals:
		case ZGEqualsStored:
			ZGHandleNarrowIntegerCase(dataType, ZGIntegerEquals);
			break;
		case ZGNotEquals:
		case ZGNotEqualsStored:
			ZGHandleNarrowIntegerCase(dataType, ZGIntegerNotEquals);
			break;
		case ZGGreaterThan:
		case ZGGreaterThanStored:
			ZGHandleNarrowIntegerCase(dataType, ZGIntegerGreaterThan);
			break;
		case ZGLessThan:
		case ZGLessThanStored:
			ZGHandleNarrowIntegerCase(dataType, ZGIntegerLesserThan);
			break;
		case ZGEqualsStoredPlus:
			ZGHandleNarrowIntegerCase(dataType, ZGIntegerEqualsPlus);
			break;
		case ZGNotEqualsStoredPlus:
			ZGHandleNarrowIntegerCase(dataType, ZGIntegerNotEqualsPlus);
			break;
		case ZGStoreAllValues:
			break;
	}
	return retValue;
}

#define ZGHandleNarrowType(functionType, type, dataType, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults) \
	case dataType: \
		retValue = ZGNarrowSearchWithFunction(functionType, processTask, (type *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults);\
		break

#define ZGHandleNarrowFloatingPointCase(case, function) \
switch (case) {\
	ZGHandleNarrowType(function, float, ZGFloat, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults);\
	ZGHandleNarrowType(function, double, ZGDouble, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults);\
	default: break;\
}

#pragma mark Narrowing Floating Points

ZGSearchResults *ZGNarrowSearchForFloatingPoints(ZGMemoryMap processTask, ZGSearchData * __unsafe_unretained searchData, ZGSearchProgress * __unsafe_unretained searchProgress, ZGVariableType dataType, ZGFunctionType functionType, ZGSearchResults * __unsafe_unretained firstSearchResults, ZGSearchResults * __unsafe_unretained laterSearchResults)
{
	id retValue = nil;
	switch (functionType)
	{
		case ZGEquals:
		case ZGEqualsStored:
			ZGHandleNarrowFloatingPointCase(dataType, ZGFloatingPointEquals);
			break;
		case ZGNotEquals:
		case ZGNotEqualsStored:
			ZGHandleNarrowFloatingPointCase(dataType, ZGFloatingPointNotEquals);
			break;
		case ZGGreaterThan:
		case ZGGreaterThanStored:
			ZGHandleNarrowFloatingPointCase(dataType, ZGFloatingPointGreaterThan);
			break;
		case ZGLessThan:
		case ZGLessThanStored:
			ZGHandleNarrowFloatingPointCase(dataType, ZGFloatingPointLesserThan);
			break;
		case ZGEqualsStoredPlus:
			ZGHandleNarrowFloatingPointCase(dataType, ZGFloatingPointEqualsPlus);
			break;
		case ZGNotEqualsStoredPlus:
			ZGHandleNarrowFloatingPointCase(dataType, ZGFloatingPointNotEqualsPlus);
			break;
		case ZGStoreAllValues:
			break;
	}
	return retValue;
}

#pragma mark Narrowing Byte Arrays

template <typename T>
bool ZGByteArrayEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return (memcmp((void *)variableValue, (void *)compareValue, searchData->_dataSize) == 0);
}

template <typename T>
bool ZGByteArrayNotEquals(ZGSearchData *__unsafe_unretained searchData, T *variableValue, T *compareValue)
{
	return !ZGByteArrayEquals(searchData, variableValue, compareValue);
}

ZGSearchResults *ZGNarrowSearchForByteArrays(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, ZGVariableType dataType, ZGFunctionType functionType, ZGSearchResults *firstSearchResults, ZGSearchResults *laterSearchResults)
{
	id retValue = nil;
	
	switch (functionType)
	{
		case ZGEquals:
			if (searchData.byteArrayFlags != NULL)
			{
				retValue = ZGNarrowSearchWithFunction(ZGByteArrayWithWildcardsEquals, processTask, (void *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults);
			}
			else
			{
				retValue = ZGNarrowSearchWithFunction(ZGByteArrayEquals, processTask, (void *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults);
			}
			break;
		case ZGNotEquals:
			if (searchData.byteArrayFlags != NULL)
			{
				retValue = ZGNarrowSearchWithFunction(ZGByteArrayWithWildcardsNotEquals, processTask, (void *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults);
			}
			else
			{
				retValue = ZGNarrowSearchWithFunction(ZGByteArrayNotEquals, processTask, (void *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults);
			}
			break;
		default:
			break;
	}
	
	return retValue;
}

#pragma mark Narrowing Strings

#define ZGHandleNarrowStringCase(case, function1, function2) \
switch (case) {\
	ZGHandleNarrowType(function1, char, ZGString8, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults);\
	ZGHandleNarrowType(function2, unichar, ZGString16, processTask, searchData, searchProgress, firstSearchResults, laterSearchResults);\
	default: break;\
}\

ZGSearchResults *ZGNarrowSearchForStrings(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, ZGVariableType dataType, ZGFunctionType functionType, ZGSearchResults *firstSearchResults, ZGSearchResults *laterSearchResults)
{
	id retValue = nil;
	
	if (!searchData.shouldIgnoreStringCase)
	{
		switch (functionType)
		{
			case ZGEquals:
				retValue = ZGNarrowSearchWithFunction(ZGByteArrayEquals, processTask, (void *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults);
				break;
			case ZGNotEquals:
				retValue = ZGNarrowSearchWithFunction(ZGByteArrayNotEquals, processTask, (void *)searchData.searchValue, searchData, searchProgress, firstSearchResults, laterSearchResults);
				break;
			default:
				break;
		}
	}
	else
	{
		switch (functionType)
		{
			case ZGEquals:
				ZGHandleNarrowStringCase(dataType, ZGString8CaseInsensitiveEquals, ZGString16CaseInsensitiveEquals);
				break;
			case ZGNotEquals:
				ZGHandleNarrowStringCase(dataType, ZGString8CaseInsensitiveNotEquals, ZGString16CaseInsensitiveNotEquals);
				break;
			default:
				break;
		}
	}
	
	return retValue;
}

#pragma mark Narrow Search for Data

ZGSearchResults *ZGNarrowSearchForData(ZGMemoryMap processTask, ZGSearchData *searchData, ZGSearchProgress *searchProgress, ZGVariableType dataType, ZGVariableQualifier integerQualifier, ZGFunctionType functionType, ZGSearchResults *firstSearchResults, ZGSearchResults *laterSearchResults)
{
	id retValue = nil;
	
	if ([@[@(ZGInt8), @(ZGInt16), @(ZGInt32), @(ZGInt64), @(ZGPointer)] containsObject:@(dataType)])
	{
		retValue = ZGNarrowSearchForIntegers(processTask, searchData, searchProgress, dataType, integerQualifier, functionType, firstSearchResults, laterSearchResults);
	}
	else if ([@[@(ZGFloat), @(ZGDouble)] containsObject:@(dataType)])
	{
		retValue = ZGNarrowSearchForFloatingPoints(processTask, searchData, searchProgress, dataType, functionType, firstSearchResults, laterSearchResults);
	}
	else if ([@[@(ZGString8), @(ZGString16)] containsObject:@(dataType)])
	{
		retValue = ZGNarrowSearchForStrings(processTask, searchData, searchProgress, dataType, functionType, firstSearchResults, laterSearchResults);
	}
	else if (dataType == ZGByteArray)
	{
		retValue = ZGNarrowSearchForByteArrays(processTask, searchData, searchProgress, dataType, functionType, firstSearchResults, laterSearchResults);
	}
	
	return retValue;
}
