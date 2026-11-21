// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

typedef enum ERROR_CODE_RETURNS
{
    ERROR_CODE_SUCCESS = 0,
    ERROR_CODE_FAILED_TO_LOAD_DLL = -1,
    ERROR_CODE_FAILED_TO_GET_ADDRESS_OF_VFCINITIALIZEDESCRIPTOR = -2,
    ERROR_CODE_FAILED_TO_GET_ADDRESS_OF_VFCADDOBJECT = -3
} ERROR_CODE_RETURNS;

typedef ULONG *P_IPV4_ADDR;
typedef UCHAR VMS_MAC_ADDR[6];
typedef VMS_MAC_ADDR *PVMS_MAC_ADDR;

typedef struct _VFP_RULE_IP_HEADER
{
    UCHAR Field1;
    UCHAR Field2;
    USHORT Field3;

} VFP_RULE_IP_HEADER;

typedef enum _VFP_RULE_IP_ENUM
{
    NdisGftHeaderGroupTranspositionActionUndefined,
    NdisGftHeaderGroupTranspositionActionModify,
    NdisGftHeaderGroupTranspositionActionIgnore,
    NdisGftHeaderGroupTranspositionActionPush,
    NdisGftHeaderGroupTranspositionActionPop,
    NdisGftHeaderGroupTranspositionActionMax
} VFP_RULE_IP_ENUM;

typedef struct _VFP_RULE_IP_STRUCT
{
    UINT8 DestinationMac[6];
    UINT8 SourceMac[6];
    UINT16 Field1;
    UINT16 Field2;
    UINT16 Field3;
    UINT8 Field4;
} VFP_RULE_IP_STRUCT;

typedef struct _VFP_RULE_IP
{
    VFP_RULE_IP_HEADER Header;
    ULONG Field1;
    VFP_RULE_IP_ENUM Action;
    ULONG Field2;
    ULONG64 Field3;
    VFP_RULE_IP_STRUCT Struct;
    union
    {
        struct
        {
            IN_ADDR SourceIP;
            IN_ADDR DestinationIP;
        } IPv4;

        struct
        {
            IN6_ADDR SourceIP;
            IN6_ADDR DestinationIP;
        } IPv6;
    } IPAddress;
    UINT8 Field4;
    UINT8 Field5;
    UINT8 Field6;
    struct
    {
        USHORT Field1;
        USHORT Field2;
    } Reserved1;

} VFP_RULE_IP;

// New packing format
#pragma pack(push, 8)

typedef struct _VFP_SWITCH_PORT
{
    PCWSTR Driver;
    GUID *DriverGuid;
    PVOID Field1;
    PCWSTR Switch;
    PCWSTR Port;
    PVOID Reserved;
} VFP_SWITCH_PORT, *PVFP_SWITCH_PORT;

typedef union _VFP_RULE_STRINGS
{
    ULONG Count;
    PCWSTR Id[35];
} VFP_RULE_STRINGS, *PVFP_RULE_STRINGS;

typedef struct _VFP_RULE_MAIN_PART
{
    USHORT Size;
    UCHAR Field1;
    UCHAR Field2;
    USHORT Field3;
    USHORT Size1;
    USHORT Size2;
    USHORT Size3;
    USHORT Prio;
    USHORT Reserved1;
    ULONG64 Reserved2;
    PVOID Id;
    PVOID Name;
    PVOID Reserved3;
} VFP_RULE_MAIN_PART, *PVFP_RULE_MAIN_PART;

typedef DWORD (*VfcAddObjectFunc)(
    __in PVFP_SWITCH_PORT Parameters,
    __in PVFP_RULE_STRINGS ObjectId,
    __in PVOID Descriptor);

typedef DWORD (*VfcInitializeDescriptorFunc)(
    __out PVFP_RULE_MAIN_PART Desc,
    __in USHORT DescSize,
    __in UCHAR Type,
    __in_opt PCWSTR Id,
    __in_opt PCWSTR Name);

#define VFP_MAXENTRY 5
#define VFP_MAXDATA 2

typedef struct _VFP_RULE_MAIN
{
    VFP_RULE_MAIN_PART Main;
    PVOID Entry1[VFP_MAXENTRY];
    USHORT Entry2[VFP_MAXENTRY];
    UCHAR Entry3[VFP_MAXENTRY];
    PVOID Data1[VFP_MAXDATA];
    USHORT Data2[VFP_MAXDATA];
    USHORT Field1;
    CHAR Field2;
    CHAR Field3;
    ULONG64 Field4;
    PVOID Count1;
    USHORT Count2;
} VFP_RULE_MAIN;

DEFINE_GUID(VFP_FILTER_ID_GUID,
            0x2c3888d9, 0x5580, 0x460e, 0xb8, 0x9f, 0xf, 0x2, 0x9, 0xcd, 0x6c, 0x91);

#pragma pack(pop)

// New packing format
#pragma pack(push)
#pragma pack(1)

typedef struct _VFP_RULE_DATA_PARTX
{
    UCHAR Field1;
    UCHAR Field2;
    UCHAR Field3;
    UCHAR Field4;
} VFP_RULE_DATA_PARTX;

#define VFP_NAME_SIZE 128

typedef struct _VFP_RULE_DATA
{
    USHORT Number;
    BOOLEAN Field1;
    UCHAR Reserved1;
    WCHAR SwitchName[VFP_NAME_SIZE];
    WCHAR PortName[VFP_NAME_SIZE];
    ULONG Field2;
    USHORT Field3;
    BOOLEAN Field4;
    BOOLEAN Field5;
    ULONG64 Field6;
    ULONG64 Field7;
    BOOLEAN Field8;
    VFP_RULE_DATA_PARTX Group[4];
    UCHAR Reserved2[7];
    ULONG64 Reserved[34];
    VFP_RULE_IP RuleEntries[4];
} VFP_RULE_DATA;

#pragma pack(pop)
