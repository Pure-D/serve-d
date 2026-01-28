/// Windows Job Objects implementation for automatic child process cleanup
/// This module provides lifecycle management for child processes using Windows Job Objects
module served.utils.jobs;

version(Windows):

import core.sys.windows.windows;
import std.process : ProcessPipes, Pid;
import std.experimental.logger;

// Windows API declarations not in core.sys.windows.windows
extern(Windows) nothrow @nogc
{
	alias PHANDLER_ROUTINE = BOOL function(DWORD dwCtrlType);
	BOOL SetConsoleCtrlHandler(PHANDLER_ROUTINE HandlerRoutine, BOOL Add);
	BOOL IsProcessInJob(HANDLE ProcessHandle, HANDLE JobHandle, PBOOL Result);
}

// Console control event types
enum : DWORD
{
	CTRL_C_EVENT = 0,
	CTRL_BREAK_EVENT = 1,
	CTRL_CLOSE_EVENT = 2,
	CTRL_LOGOFF_EVENT = 5,
	CTRL_SHUTDOWN_EVENT = 6,
}

// Job object limit flags
enum : DWORD
{
	JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000,
}

// Job object information classes
enum JOBOBJECTINFOCLASS
{
	JobObjectBasicLimitInformation = 2,
	JobObjectExtendedLimitInformation = 9,
}

// Job object structures
struct JOBOBJECT_BASIC_LIMIT_INFORMATION
{
	LARGE_INTEGER PerProcessUserTimeLimit;
	LARGE_INTEGER PerJobUserTimeLimit;
	DWORD LimitFlags;
	SIZE_T MinimumWorkingSetSize;
	SIZE_T MaximumWorkingSetSize;
	DWORD ActiveProcessLimit;
	ULONG_PTR Affinity;
	DWORD PriorityClass;
	DWORD SchedulingClass;
}

struct IO_COUNTERS
{
	ULONGLONG ReadOperationCount;
	ULONGLONG WriteOperationCount;
	ULONGLONG OtherOperationCount;
	ULONGLONG ReadTransferCount;
	ULONGLONG WriteTransferCount;
	ULONGLONG OtherTransferCount;
}

struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
{
	JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
	IO_COUNTERS IoInfo;
	SIZE_T ProcessMemoryLimit;
	SIZE_T JobMemoryLimit;
	SIZE_T PeakProcessMemoryUsed;
	SIZE_T PeakJobMemoryUsed;
}

extern(Windows) BOOL SetInformationJobObject(
	HANDLE hJob,
	JOBOBJECTINFOCLASS JobObjectInformationClass,
	LPVOID lpJobObjectInformation,
	DWORD cbJobObjectInformationLength
) nothrow @nogc;

extern(Windows) BOOL AssignProcessToJobObject(HANDLE hJob, HANDLE hProcess) nothrow @nogc;

// Global state
private __gshared
{
	HANDLE g_jobObject = null;
	bool g_consoleHandlerInstalled = false;
	bool g_selfInJob = false;
}

/// Console control handler - catches CTRL+C, CTRL+BREAK, and window close (red X)
extern(Windows) BOOL consoleCtrlHandler(DWORD dwCtrlType) nothrow @nogc
{
	switch (dwCtrlType)
	{
		case CTRL_CLOSE_EVENT:
			// Window is being closed (red X button)
			// Cannot log here due to @nogc requirement
			
			// Close the job object handle immediately
			// This will cause Windows to kill all processes in the job
			if (g_jobObject !is null)
			{
				CloseHandle(g_jobObject);
				g_jobObject = null;
			}
			
			// Return TRUE to indicate we handled this event
			// This prevents the default handler from running
			return TRUE;
			
		case CTRL_C_EVENT:
		case CTRL_BREAK_EVENT:
			// Let these fall through to normal handling
			return FALSE;
			
		default:
			return FALSE;
	}
}

/// Initialize the global job object for child process management
/// This should be called early in application startup
void initializeJobObject()
{
	if (g_jobObject !is null)
	{
		trace("[JOB] Job object already initialized");
		return;
	}
	
	try
	{
		// Install console control handler FIRST
		// This catches CTRL_CLOSE_EVENT (red X button)
		if (!g_consoleHandlerInstalled)
		{
			if (SetConsoleCtrlHandler(&consoleCtrlHandler, TRUE))
			{
				g_consoleHandlerInstalled = true;
				info("[JOB] Console control handler installed successfully");
				trace("[JOB] This will catch CTRL+C, CTRL+BREAK, and red X clicks");
			}
			else
			{
				warning("[JOB] Failed to install console control handler - red X may not work properly");
			}
		}
		
		// Create the job object
		g_jobObject = CreateJobObjectA(null, null);
		if (g_jobObject is null)
		{
			error("[JOB] Failed to create job object. Error: ", GetLastError());
			return;
		}
		
		// Set the job to kill all processes when the last handle is closed
		JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli;
		jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
		
		if (!SetInformationJobObject(
			g_jobObject,
			JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation,
			&jeli,
			jeli.sizeof))
		{
			auto err = GetLastError();
			error("[JOB] Failed to set job object limits. Error: ", err);
			CloseHandle(g_jobObject);
			g_jobObject = null;
			return;
		}
		
		info("[JOB] Job object initialized successfully with KILL_ON_JOB_CLOSE");
		
		// Add serve-d itself to the job object (self-in-job)
		// This is critical for ensuring children are killed even if serve-d crashes
		auto currentProcess = GetCurrentProcess();
		
		// First check if we're already in a job (some environments do this)
		BOOL inJob = FALSE;
		if (IsProcessInJob(currentProcess, null, &inJob))
		{
			if (inJob)
			{
				warning("[JOB] serve-d is already in a job object (possibly created by parent process)");
				warning("[JOB] Will attempt to add to our job anyway, but may fail");
			}
		}
		
		if (AssignProcessToJobObject(g_jobObject, currentProcess))
		{
			g_selfInJob = true;
			trace("[JOB] serve-d added itself to job object");
			trace("[JOB] This ensures children are killed even if serve-d crashes");
		}
		else
		{
			auto err = GetLastError();
			if (err == 5) // ERROR_ACCESS_DENIED
			{
				warning("[JOB] Could not add serve-d to job - already in another job (Error 5)");
				warning("[JOB] Children may not be cleaned up if serve-d crashes");
			}
			else if (err == 1164) // ERROR_ALREADY_ASSIGNED
			{
				// This is actually success - we're already in the job
				g_selfInJob = true;
				trace("[JOB] serve-d already in this job object");
			}
			else
			{
				warning("[JOB] Failed to add serve-d to job. Error: ", err);
				warning("[JOB] Children may not be cleaned up if serve-d crashes");
			}
		}
	}
	catch (Exception e)
	{
		error("[JOB] Exception during job object initialization: ", e.msg);
		if (g_jobObject !is null)
		{
			CloseHandle(g_jobObject);
			g_jobObject = null;
		}
	}
}

/// Clean up the job object
/// This should be called during application shutdown
void cleanupJobObject()
{
	if (g_jobObject !is null)
	{
		trace("[JOB] Closing job object handle");
		CloseHandle(g_jobObject);
		g_jobObject = null;
		trace("[JOB] Job object handle closed - Windows will kill all child processes");
	}
}

/// Check if the job object is initialized
@property bool isJobObjectInitialized()
{
	return g_jobObject !is null;
}

/// Check if serve-d successfully added itself to the job
@property bool isSelfInJob()
{
	return g_selfInJob;
}

/// Add a process to the global job object by PID
/// This method is less reliable than addProcessToJobByProcessPipes
/// but kept for backward compatibility
bool addProcessToJobByPid(DWORD pid)
{
	if (g_jobObject is null)
	{
		warning("[JOB] Job object not initialized, cannot add process");
		return false;
	}
	
	// Open the process with required permissions
	auto processHandle = OpenProcess(
		PROCESS_SET_QUOTA | PROCESS_TERMINATE | SYNCHRONIZE,
		FALSE,
		pid);
	
	if (processHandle is null)
	{
		auto err = GetLastError();
		warning("[JOB] Failed to open process ", pid, " for job assignment. Error: ", err);
		return false;
	}
	
	scope(exit) CloseHandle(processHandle);
	
	if (!AssignProcessToJobObject(g_jobObject, processHandle))
	{
		auto err = GetLastError();
		if (err == 5)
		{
			warning("[JOB] Failed to add process to job - process may already be in another job. Error: ", err);
		}
		else if (err == 1164)
		{
			trace("[JOB] Process already assigned to this job");
			return true;
		}
		else
		{
			error("[JOB] Failed to add process to job. Error: ", err);
		}
		return false;
	}
	
	trace("[JOB] Successfully added process ", pid, " to job");
	return true;
}

/// Add a process to the global job object using std.process.ProcessPipes
/// This is the preferred method as it uses the existing process handle
/// and avoids permission/timing issues with reopening by PID
bool addProcessToJobByProcessPipes(ProcessPipes)(ProcessPipes pipes)
{
	if (g_jobObject is null)
	{
		warning("[JOB] Job object not initialized, cannot add process");
		return false;
	}

	if (pipes.pid is null)
	{
		warning("[JOB] ProcessPipes has no pid");
		return false;
	}

	// Get the Windows process handle from the Pid object
	// Pid.osHandle on Windows returns the native HANDLE
	auto processHandle = pipes.pid.osHandle;
	
	if (processHandle is null || processHandle == INVALID_HANDLE_VALUE)
	{
		warning("[JOB] Invalid process handle from Pid");
		return false;
	}

	if (!AssignProcessToJobObject(g_jobObject, processHandle))
	{
		auto err = GetLastError();
		if (err == 5)
		{
			warning("[JOB] Failed to add process to job - process may already be in another job. Error: ", err);
		}
		else if (err == 1164)
		{
			trace("[JOB] Process already assigned to this job");
			return true;
		}
		else
		{
			error("[JOB] Failed to add process to job. Error: ", err);
		}
		return false;
	}

	info("[JOB] Successfully added process to job using ProcessPipes handle");
	return true;
}
