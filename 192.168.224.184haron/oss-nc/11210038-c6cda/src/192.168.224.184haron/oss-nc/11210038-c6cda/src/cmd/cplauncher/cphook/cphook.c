// SPDX-FileCopyrightText: © 2025 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

// CompartmentHook.cpp - C++ helper DLL to set thread network compartment.
// Exported function: DWORD WINAPI SetTargetCompartmentId(LPVOID param)
// Returns 0 on success (mirrors SetCurrentThreadCompartmentId), or Win32 error code.

#include <windows.h>
#include <iphlpapi.h>
#include <strsafe.h>
#include <tlhelp32.h> // For CreateToolhelp32Snapshot / THREADENTRY32 / Thread32First / Thread32Next

// Optional logging:
// If the environment variable COMPARTMENT_HOOK_LOGFILE is set to a path,
// the DLL will append diagnostic output to that file. No file is created
// if the variable is absent or empty.

namespace
{
    HANDLE gLogHandle = INVALID_HANDLE_VALUE;
    bool gTriedOpen = false;

    void OpenLogIfNeeded()
    {
        if (gTriedOpen)
            return;
        gTriedOpen = true;
        wchar_t path[1024];
        DWORD len = GetEnvironmentVariableW(L"COMPARTMENT_HOOK_LOGFILE", path, (DWORD)(sizeof(path) / sizeof(path[0])));
        if (len == 0 || len >= sizeof(path) / sizeof(path[0]))
        {
            // Not set or truncated -> no logging.
            return;
        }
        gLogHandle = CreateFileW(path,
                                 FILE_APPEND_DATA,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 nullptr,
                                 OPEN_ALWAYS,
                                 FILE_ATTRIBUTE_NORMAL,
                                 nullptr);
        if (gLogHandle == INVALID_HANDLE_VALUE)
        {
            gLogHandle = NULL; // Mark as unusable
        }
    }

    void Logf(const wchar_t *fmt, ...)
    {
        OpenLogIfNeeded();
        if (gLogHandle == NULL || gLogHandle == INVALID_HANDLE_VALUE)
            return;

        SYSTEMTIME st;
        GetLocalTime(&st);
        wchar_t prefix[64];
        StringCchPrintfW(prefix, _countof(prefix), L"[%02u:%02u:%02u.%03u] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);

        wchar_t msg[1024];
        va_list ap;
        va_start(ap, fmt);
        StringCchVPrintfW(msg, _countof(msg), fmt, ap);
        va_end(ap);

        wchar_t line[1200];
        StringCchPrintfW(line, _countof(line), L"%s%s\r\n", prefix, msg);

        // Convert to UTF-8 for file (keep it simple) or write UTF-16 LE BOM-less.
        // We'll write UTF-16 LE directly.
        DWORD bytesToWrite = (DWORD)(lstrlenW(line) * sizeof(wchar_t));
        DWORD written = 0;
        WriteFile(gLogHandle, line, bytesToWrite, &written, nullptr);
    }
}

// Function pointer types for dynamic loading
typedef DWORD(WINAPI *FnSetCurrentThreadCompartmentId)(DWORD);
typedef DWORD(WINAPI *FnGetCurrentThreadCompartmentId)(void);

extern "C" __declspec(dllexport) DWORD WINAPI SetTargetCompartmentId(LPVOID param)
{
    DWORD compartmentId = static_cast<DWORD>(reinterpret_cast<ULONG_PTR>(param));
    Logf(L"SetTargetCompartmentId called with compartmentId=%lu", compartmentId);

    HMODULE hIphlp = LoadLibraryW(L"iphlpapi.dll");
    if (!hIphlp)
    {
        DWORD err = GetLastError();
        Logf(L"LoadLibraryW(iphlpapi.dll) failed err=%lu", err);
        return err;
    }

    auto fnSet = reinterpret_cast<FnSetCurrentThreadCompartmentId>(GetProcAddress(hIphlp, "SetCurrentThreadCompartmentId"));
    if (!fnSet)
    {
        Logf(L"GetProcAddress(SetCurrentThreadCompartmentId) failed (symbol missing)");
        return ERROR_PROC_NOT_FOUND;
    }

    DWORD setResult = fnSet(compartmentId);
    if (setResult == 0)
    {
        Logf(L"SetCurrentThreadCompartmentId succeeded for id=%lu", compartmentId);
    }
    else
    {
        Logf(L"SetCurrentThreadCompartmentId FAILED id=%lu code=%lu", compartmentId, setResult);
    }

    // Attempt to query current compartment if available
    auto fnGet = reinterpret_cast<FnGetCurrentThreadCompartmentId>(GetProcAddress(hIphlp, "GetCurrentThreadCompartmentId"));
    if (fnGet)
    {
        DWORD cur = fnGet();
        Logf(L"GetCurrentThreadCompartmentId returned %lu", cur);
    }
    else
    {
        Logf(L"GetCurrentThreadCompartmentId symbol not found (cannot verify)");
    }

    // Free the library handle
    FreeLibrary(hIphlp);

    return setResult;
}

// Lightweight context passed to APC
struct APC_CTX
{
    FnSetCurrentThreadCompartmentId fn;
    DWORD id;
};

// APC callback (NTAPI signature). Runs in target thread context.
static VOID CALLBACK CompartmentAPCProc(ULONG_PTR param)
{
    APC_CTX *ctx = reinterpret_cast<APC_CTX *>(param);
    if (!ctx)
        return;
    DWORD r = ctx->fn ? ctx->fn(ctx->id) : (DWORD)-1;
    Logf(L"[APC] Thread %lu SetCurrentThreadCompartmentId(%lu) => %lu", GetCurrentThreadId(), ctx->id, r);
    // fnGet optional verification per thread
    HMODULE hIphlp = GetModuleHandleW(L"iphlpapi.dll");
    if (hIphlp)
    {
        auto fnGet = reinterpret_cast<FnGetCurrentThreadCompartmentId>(GetProcAddress(hIphlp, "GetCurrentThreadCompartmentId"));
        if (fnGet)
        {
            DWORD cur = fnGet();
            Logf(L"[APC] Thread %lu current compartment now %lu", GetCurrentThreadId(), cur);
        }
    }
}

// Enumerate threads in this process and queue an APC to each alertable thread.
static void QueueCompartmentAPCs(FnSetCurrentThreadCompartmentId setter, DWORD id)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE)
    {
        Logf(L"Thread snapshot failed err=%lu", GetLastError());
        return;
    }
    THREADENTRY32 te;
    te.dwSize = sizeof(te);
    if (!Thread32First(snap, &te))
    {
        CloseHandle(snap);
        return;
    }
    DWORD selfPid = GetCurrentProcessId();
    int queued = 0, skipped = 0;
    while (true)
    {
        if (te.th32OwnerProcessID == selfPid)
        {
            if (te.th32ThreadID == GetCurrentThreadId())
            {
                // Current thread: set directly (already in attach context)
                DWORD r = setter(id);
                Logf(L"[Direct] Attach thread %lu SetCurrentThreadCompartmentId(%lu) => %lu", te.th32ThreadID, id, r);
            }
            else
            {
                HANDLE hThread = OpenThread(THREAD_SET_CONTEXT | THREAD_QUERY_INFORMATION | THREAD_SUSPEND_RESUME, FALSE, te.th32ThreadID);
                if (hThread)
                {
                    // Allocate context in process heap (will persist; small leak acceptable or free via APC?)
                    APC_CTX *ctx = (APC_CTX *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(APC_CTX));
                    if (ctx)
                    {
                        ctx->fn = setter;
                        ctx->id = id;
                        ULONG r = QueueUserAPC(CompartmentAPCProc, hThread, (ULONG_PTR)ctx);
                        if (r == 0)
                        {
                            Logf(L"[APC] QueueUserAPC failed thread=%lu err=%lu", te.th32ThreadID, GetLastError());
                            HeapFree(GetProcessHeap(), 0, ctx);
                        }
                        else
                        {
                            queued++;
                        }
                    }
                    CloseHandle(hThread);
                }
                else
                {
                    skipped++;
                }
            }
        }
        if (!Thread32Next(snap, &te))
            break;
    }
    CloseHandle(snap);
    Logf(L"APC queue summary: queued=%d skipped=%d (threads must enter alertable wait to run APCs)", queued, skipped);
}

// Get desired compartment id: precedence order -> explicit export call param, else env var COMPARTMENT_ID_ATTACH
static DWORD ResolveDesiredCompartment()
{
    wchar_t buf[32];
    DWORD n = GetEnvironmentVariableW(L"COMPARTMENT_ID_ATTACH", buf, _countof(buf));
    if (n && n < _countof(buf))
    {
        return (DWORD)_wtoi(buf);
    }
    return 0; // 0 means leave unchanged
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(hModule);
        DWORD desired = ResolveDesiredCompartment();
        if (desired == 0)
        {
            Logf(L"[Attach] No COMPARTMENT_ID_ATTACH set; skipping automatic per-thread switch.");
            return TRUE;
        }
        HMODULE hIphlp = LoadLibraryW(L"iphlpapi.dll");
        if (!hIphlp)
        {
            Logf(L"[Attach] LoadLibrary iphlpapi.dll failed err=%lu", GetLastError());
            return TRUE;
        }
        auto fnSet = reinterpret_cast<FnSetCurrentThreadCompartmentId>(GetProcAddress(hIphlp, "SetCurrentThreadCompartmentId"));
        if (!fnSet)
        {
            Logf(L"[Attach] SetCurrentThreadCompartmentId export missing");
            return TRUE;
        }
        Logf(L"[Attach] Queuing compartment switch to %lu for all process threads via APC", desired);
        QueueCompartmentAPCs(fnSet, desired);
    }
    else if (reason == DLL_PROCESS_DETACH)
    {
        if (gLogHandle && gLogHandle != INVALID_HANDLE_VALUE)
        {
            Logf(L"DLL_PROCESS_DETACH closing log.");
            CloseHandle(gLogHandle);
            gLogHandle = NULL;
        }
    }
    return TRUE;
}
