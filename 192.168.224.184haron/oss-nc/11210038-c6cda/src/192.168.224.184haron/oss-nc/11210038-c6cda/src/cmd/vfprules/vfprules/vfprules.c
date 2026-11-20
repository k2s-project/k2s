// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

#define _UNICODE
#define UNICODE
#include <windows.h>
#include <stdio.h>
#include <initguid.h>
#include <ip2string.h>
#include <in6addr.h>
#include "vfprules.h"

BOOL WINAPI DllMain(
    HINSTANCE hinstDLL, // handle to DLL module
    DWORD fdwReason,    // reason for calling function
    LPVOID lpvReserved) // reserved
{
    // Perform actions based on the reason for calling.
    switch (fdwReason)
    {
    case DLL_PROCESS_ATTACH:
        // Initialize once for each new process.
        // Return FALSE to fail DLL load.
        break;

    case DLL_THREAD_ATTACH:
        // Do thread-specific initialization.
        break;

    case DLL_THREAD_DETACH:
        // Do thread-specific cleanup.
        break;

    case DLL_PROCESS_DETACH:

        if (lpvReserved != NULL)
        {
            break; // do not do cleanup if process termination scenario
        }

        // Perform any necessary cleanup.
        break;
    }
    return TRUE; // Successful DLL_PROCESS_ATTACH.
}

DWORD ParseIpv4Address(__in PWSTR Ipv4String, __out P_IPV4_ADDR Ipv4Long)
{
    PWSTR term;
    struct in_addr addr;
    if (RtlIpv4StringToAddressW((PCWSTR)Ipv4String, FALSE, (LPCWSTR *)&term, &addr) != NO_ERROR)
    {
        return ERROR_INVALID_PARAMETER;
    }
    *Ipv4Long = addr.s_addr;
    return ERROR_SUCCESS;
}

DWORD HexCharToInteger(__in WCHAR Char, __out PUCHAR Integer)
{
    DWORD error;
    if ((Char >= L'0') && (Char <= L'9'))
    {
        *Integer = (UCHAR)(Char - L'0');
        error = ERROR_SUCCESS;
    }
    else if ((Char >= L'a') && (Char <= L'f'))
    {
        *Integer = (UCHAR)(Char - L'a' + 10);
        error = ERROR_SUCCESS;
    }
    else if ((Char >= L'A') && (Char <= L'F'))
    {
        *Integer = (UCHAR)(Char - L'A' + 10);
        error = ERROR_SUCCESS;
    }
    else
    {
        error = ERROR_INVALID_PARAMETER;
    }
    return error;
}

DWORD ParseMacAddress(__in PWSTR MacAddressString, __out_bcount(6) PVMS_MAC_ADDR MacAddress)
{
    PWSTR cur;
    DWORD error;
    ULONG index;
    PUCHAR mac;
    PWSTR nextToken;
    UCHAR segment;

    const UINT size = CHAR_MAX * sizeof(WCHAR);
    WCHAR stringValue[CHAR_MAX];
    memset(stringValue, 0, size);
    wcscpy_s(&stringValue[0], CHAR_MAX, MacAddressString);

    mac = (PUCHAR)MacAddress;
    nextToken = NULL;
    cur = wcstok_s(stringValue, L"-", &nextToken);
    for (index = 0; index < 6; index += 1)
    {
        if ((cur == NULL) || (cur[0] == 0) || (cur[1] == 0) || (cur[2] != 0))
        {
            error = ERROR_INVALID_PARAMETER;
            goto Cleanup;
        }

        error = HexCharToInteger(cur[0], &segment);
        if (error != ERROR_SUCCESS)
        {
            goto Cleanup;
        }

        mac[index] = segment;

        error = HexCharToInteger(cur[1], &segment);
        if (error != ERROR_SUCCESS)
        {
            goto Cleanup;
        }

        mac[index] = mac[index] * 16 + segment;
        cur = wcstok_s(NULL, L"-", &nextToken);
    }

    error = ERROR_SUCCESS;

Cleanup:
    return error;
}

// Export the function
__declspec(dllexport) DWORD VfpAddRule(
    const wchar_t *name,
    const wchar_t *portid,
    const wchar_t *startip,
    const wchar_t *stopip,
    const wchar_t *priority,
    const wchar_t *gateway)
{
    // Dump the parameters
    wprintf(L"Rule:\n");
    wprintf(L" Name: %ls\n", name);
    wprintf(L" Portid: %ls\n", portid);
    wprintf(L" StartIp: %ls\n", startip);
    wprintf(L" StopIp: %ls\n", stopip);
    wprintf(L" Priority: %ls\n", priority);
    wprintf(L" Gateway: %ls\n", gateway);

    VFP_RULE_STRINGS objectId;
    VFP_SWITCH_PORT parameter;
    VFP_RULE_MAIN desc;
    memset(&parameter, 0, sizeof(VFP_SWITCH_PORT));
    memset(&objectId, 0, sizeof(VFP_RULE_STRINGS));
    memset(&desc, 0, sizeof(VFP_RULE_MAIN));
    parameter.Driver = L"\\\\.\\VfpExtWin";
    parameter.Port = portid;
    parameter.DriverGuid = (GUID *)(&VFP_FILTER_ID_GUID);
    objectId.Count = 35;
    objectId.Id[3] = L"VNET_PA_ROUTE_LAYER";
    objectId.Id[4] = L"VNET_GROUP_PA_ROUTE_IPV4_OUT";

    // load c:\windows\System32\vfpapi.dll and call VfcAddObject
    HMODULE hModule = LoadLibrary(L"C:\\Windows\\System32\\vfpapi.dll");
    if (hModule == NULL)
    {
        printf("Failed to load the DLL\n");
        return ERROR_CODE_FAILED_TO_LOAD_DLL;
    }

    //// Get the address of the VfcAddObject function
    VfcInitializeDescriptorFunc gVfcInitializeDescriptor = (VfcInitializeDescriptorFunc)GetProcAddress(hModule, "VfcInitializeDescriptor");
    if (gVfcInitializeDescriptor == NULL)
    {
        printf("Failed to get the address of VfcInitializeDescriptor\n");
        FreeLibrary(hModule);
        return ERROR_CODE_FAILED_TO_GET_ADDRESS_OF_VFCINITIALIZEDESCRIPTOR;
    }

    // Get the address of the VfcAddObject function
    VfcAddObjectFunc gVfcAddObject = (VfcAddObjectFunc)GetProcAddress(hModule, "VfcAddObject");
    if (gVfcAddObject == NULL)
    {
        printf("Failed to get the address of VfcAddObject\n");
        FreeLibrary(hModule);
        return ERROR_CODE_FAILED_TO_GET_ADDRESS_OF_VFCADDOBJECT;
    }

    // Initialize structure
    DWORD e1 = gVfcInitializeDescriptor(&desc.Main, sizeof(desc), 5, name, name);
    if (e1 != ERROR_SUCCESS)
    {
        printf("Failed to initialize the descriptor\n");
        FreeLibrary(hModule);
        return e1;
    }
    desc.Main.Field3 = (USHORT)128;
    desc.Field1 = 0;
    desc.Main.Prio = _wtoi(priority);
    desc.Main.Field1 = 5;
    desc.Main.Field2 = 20;

    //// copy source and target ip address
    desc.Entry3[0] = 11;
    UCHAR IPBuffer[2 * sizeof(IN_ADDR)];
    DWORD e2 = ParseIpv4Address((PWSTR)startip, (P_IPV4_ADDR)&IPBuffer[0]);
    if (e2 != ERROR_SUCCESS)
    {
        printf("Failed to parse the start ip address parameter\n");
        FreeLibrary(hModule);
        return e2;
    }
    DWORD e3 = ParseIpv4Address((PWSTR)stopip, (P_IPV4_ADDR)&IPBuffer[sizeof(IN_ADDR)]);
    if (e3 != ERROR_SUCCESS)
    {
        printf("Failed to parse the stop ip address parameter\n");
        FreeLibrary(hModule);
        return e3;
    }
    desc.Entry1[0] = &IPBuffer[0];
    desc.Entry2[0] = 2 * sizeof(IN_ADDR);

    //// add MAC address
    VFP_RULE_DATA *transpositionData = (VFP_RULE_DATA *)malloc(sizeof(VFP_RULE_DATA) * sizeof(UCHAR));
    memset(transpositionData, 0, sizeof(VFP_RULE_DATA) * sizeof(UCHAR));
    transpositionData->Number = (USHORT)1U;
    transpositionData->RuleEntries[0].Action = 1;
    transpositionData->RuleEntries[0].Field2 = (int)1;
    transpositionData->RuleEntries[0].Field3 |= 0x00000001ULL;
    transpositionData->RuleEntries[0].Field3 |= 0x00000002ULL;
    DWORD e4 = ParseMacAddress((PWSTR)gateway, &transpositionData->RuleEntries[0].Struct.DestinationMac);
    if (e4 != ERROR_SUCCESS)
    {
        printf("Failed to parse the stop ip address parameter\n");
        FreeLibrary(hModule);
        return e4;
    }
    desc.Data1[0] = transpositionData;
    desc.Data2[0] = sizeof(VFP_RULE_DATA) * sizeof(UCHAR);

    // Call the function
    DWORD e5 = gVfcAddObject(&parameter, &objectId, &desc.Main);
    if (e5 != ERROR_SUCCESS)
    {
        printf("Failed to call the VfcAddObject method, error code: %d\n", e5);
        FreeLibrary(hModule);
        return e5;
    }

    // Free the library
    FreeLibrary(hModule);
    return ERROR_CODE_SUCCESS;
}
