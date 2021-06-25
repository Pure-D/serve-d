module served.linters.diagnosticmanager;

import std.array : array;
import std.algorithm : map, sort;

import served.utils.memory;
import served.types;

import painlessjson;

enum NumDiagnosticProviders = 3;
alias DiagnosticCollection = PublishDiagnosticsParams[];
DiagnosticCollection[NumDiagnosticProviders] diagnostics;

DiagnosticCollection combinedDiagnostics;
DocumentUri[] publishedUris;

void combineDiagnostics()
{
	combinedDiagnostics.length = 0;
	foreach (provider; diagnostics)
	{
		foreach (errors; provider)
		{
			size_t index = combinedDiagnostics.length;
			foreach (i, existing; combinedDiagnostics)
			{
				if (existing.uri == errors.uri)
				{
					index = i;
					break;
				}
			}
			if (index == combinedDiagnostics.length)
				combinedDiagnostics ~= PublishDiagnosticsParams(errors.uri);
			combinedDiagnostics[index].diagnostics ~= errors.diagnostics;
		}
	}
}

/// Returns a reference to existing diagnostics for a given url in a given slot or creates a new array for them and returns the reference for it.
/// Params:
///   slot = the diagnostic provider slot to edit
///   uri = the document uri to attach the diagnostics array for
ref auto createDiagnosticsFor(int slot)(string uri)
{
	static assert(slot < NumDiagnosticProviders);
	foreach (ref existing; diagnostics[slot])
		if (existing.uri == uri)
			return existing.diagnostics;

	return pushRef(diagnostics[slot], PublishDiagnosticsParams(uri, null)).diagnostics;
}

private ref T pushRef(T)(ref T[] arr, T value)
{
	auto len = arr.length++;
	return arr[len] = value;
}

void updateDiagnostics(string uriHint = "")
{
	combineDiagnostics();
	foreach (diagnostics; combinedDiagnostics)
	{
		if (!uriHint.length || diagnostics.uri == uriHint)
		{
			// TODO: related information
			RequestMessage request;
			request.method = "textDocument/publishDiagnostics";
			request.params = diagnostics.toJSON;
			rpc.send(request);
		}
	}

	// clear old diagnostics
	auto diags = combinedDiagnostics.map!"a.uri".array;
	auto sorted = diags.sort!"a<b";
	foreach (submitted; publishedUris)
	{
		if (!sorted.contains(submitted))
		{
			RequestMessage request;
			request.method = "textDocument/publishDiagnostics";
			request.params = PublishDiagnosticsParams(submitted, null).toJSON;
			rpc.send(request);
		}
	}
	destroyUnset(publishedUris);
	publishedUris = diags;
}
